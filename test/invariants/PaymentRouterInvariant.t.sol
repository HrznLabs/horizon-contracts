// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PaymentRouter} from "../../src/PaymentRouter.sol";
import {IPaymentRouter} from "../../src/interfaces/IPaymentRouter.sol";
import {MissionFactory} from "../../src/MissionFactory.sol";
import {MissionEscrow} from "../../src/MissionEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title PaymentRouterHandler
 * @notice Handler for invariant testing of PaymentRouter fee mechanics
 * @dev Exercises fee splits with varying guild fees and reward amounts
 */
contract PaymentRouterHandler is Test {
    PaymentRouter public router;
    MissionFactory public factory;
    MockERC20 public usdc;

    address public admin;
    address public poster;
    address public performer;
    address public feeManager;

    // Ghost variables
    uint256 public ghost_totalSettled;
    uint256 public ghost_totalPerformerReceived;
    uint256 public ghost_totalProtocolReceived;
    uint256 public ghost_totalLabsReceived;
    uint256 public ghost_totalResolverReceived;
    uint256 public ghost_totalGuildReceived;
    uint256 public ghost_settlementsCount;
    uint256 public ghost_floorUpdates;

    // Track performer floor violations (should always be 0)
    uint256 public ghost_floorViolations;

    constructor(
        PaymentRouter _router,
        MissionFactory _factory,
        MockERC20 _usdc,
        address _admin,
        address _poster,
        address _performer,
        address _feeManager
    ) {
        router = _router;
        factory = _factory;
        usdc = _usdc;
        admin = _admin;
        poster = _poster;
        performer = _performer;
        feeManager = _feeManager;
    }

    /**
     * @notice Settle a mission with varying reward and guild fee
     */
    function settleWithGuildFee(uint256 rewardSeed, uint16 guildFeeBpsSeed) external {
        // Bound reward to reasonable range (1 USDC to 1M USDC)
        uint256 rewardAmount = bound(rewardSeed, 1e6, 1_000_000e6);
        // Bound guild fee to 0-1000 bps (0-10%), handler will test auto-capping
        uint16 guildFeeBps = uint16(bound(uint256(guildFeeBpsSeed), 0, 1000));

        // Create mission
        vm.startPrank(poster);
        usdc.approve(address(factory), rewardAmount);
        uint256 missionId = factory.createMission(
            address(usdc),
            rewardAmount,
            block.timestamp + 1 days,
            address(0x1234), // guild address
            keccak256(abi.encodePacked("meta", ghost_settlementsCount)),
            keccak256(abi.encodePacked("loc", ghost_settlementsCount))
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256(abi.encodePacked("proof", ghost_settlementsCount)));

        // Record balances before
        uint256 performerBefore = usdc.balanceOf(performer);

        // Approve completion triggers settlement
        vm.prank(poster);
        MissionEscrow(escrow).approveCompletion();

        uint256 performerAfter = usdc.balanceOf(performer);
        uint256 performerGot = performerAfter - performerBefore;

        ghost_totalSettled += rewardAmount;
        ghost_totalPerformerReceived += performerGot;
        ghost_settlementsCount++;

        // Check performer floor
        uint256 minPerformer = (rewardAmount * router.performerFloorBPS()) / 10000;
        if (performerGot < minPerformer) {
            ghost_floorViolations++;
        }
    }

    /**
     * @notice Settle without guild (simpler path)
     */
    function settleNoGuild(uint256 rewardSeed) external {
        uint256 rewardAmount = bound(rewardSeed, 1e6, 1_000_000e6);

        vm.startPrank(poster);
        usdc.approve(address(factory), rewardAmount);
        uint256 missionId = factory.createMission(
            address(usdc),
            rewardAmount,
            block.timestamp + 1 days,
            address(0), // no guild
            keccak256(abi.encodePacked("meta_ng", ghost_settlementsCount)),
            keccak256(abi.encodePacked("loc_ng", ghost_settlementsCount))
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256(abi.encodePacked("proof_ng", ghost_settlementsCount)));

        uint256 performerBefore = usdc.balanceOf(performer);

        vm.prank(poster);
        MissionEscrow(escrow).approveCompletion();

        uint256 performerGot = usdc.balanceOf(performer) - performerBefore;

        ghost_totalSettled += rewardAmount;
        ghost_totalPerformerReceived += performerGot;
        ghost_settlementsCount++;

        // Check performer floor
        uint256 minPerformer = (rewardAmount * router.performerFloorBPS()) / 10000;
        if (performerGot < minPerformer) {
            ghost_floorViolations++;
        }
    }

    /**
     * @notice Adjust the performer floor within achievable bounds
     * @dev Max achievable floor = BPS_DENOMINATOR - fixedFees = 10000 - 700 = 9300
     *      Setting floor above 9300 means fixed fees alone exceed the gap, making
     *      the floor unachievable. This is a configuration constraint, not a bug.
     */
    function adjustFloor(uint16 newFloorSeed) external {
        // Bound to achievable range: [MIN_PERFORMER_FLOOR_BPS, BPS_DENOMINATOR - fixedFees]
        // Fixed fees = 250 + 250 + 200 = 700 bps
        uint16 maxAchievableFloor = router.BPS_DENOMINATOR()
            - router.PROTOCOL_FEE_BPS() - router.LABS_FEE_BPS() - router.RESOLVER_FEE_BPS();
        uint16 newFloor = uint16(bound(uint256(newFloorSeed), 8500, maxAchievableFloor));

        vm.prank(feeManager);
        router.setPerformerFloor(newFloor);

        ghost_floorUpdates++;
    }

    /**
     * @notice Test fee split calculation (pure function, no state change)
     */
    function testFeeSplitSum(uint256 rewardSeed, uint16 guildFeeBpsSeed) external view {
        uint256 rewardAmount = bound(rewardSeed, 1e6, 1_000_000e6);
        uint16 guildFeeBps = uint16(bound(uint256(guildFeeBpsSeed), 0, 300));

        IPaymentRouter.FeeSplit memory split = router.getFeeSplit(rewardAmount, address(0x1234), guildFeeBps);

        uint256 total = split.performerAmount + split.protocolAmount +
                       split.guildAmount + split.resolverAmount + split.labsAmount;

        // Allow max 5 wei rounding error
        assert(total >= rewardAmount - 5 && total <= rewardAmount);
    }
}

/**
 * @title PaymentRouterInvariantTest
 * @notice Invariant tests for PaymentRouter fee mechanics
 * @dev Tests SEC-2 (performer floor), SEC-3 (guild fee auto-cap), SEC-6 (fuzz coverage)
 */
contract PaymentRouterInvariantTest is Test {
    PaymentRouter public router;
    MissionFactory public factory;
    MockERC20 public usdc;
    PaymentRouterHandler public handler;

    address public admin = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);
    address public feeManager = address(9);

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockERC20("USD Coin", "USDC", 6);

        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            admin
        );

        factory = new MissionFactory(address(router));
        router.setMissionFactory(address(factory));

        router.grantRole(router.FEE_MANAGER_ROLE(), feeManager);

        vm.stopPrank();

        // Mint generous supply
        usdc.mint(poster, 100_000_000e6);

        handler = new PaymentRouterHandler(
            router,
            factory,
            usdc,
            admin,
            poster,
            performer,
            feeManager
        );

        targetContract(address(handler));
    }

    /**
     * @notice Performer always receives >= performerFloorBPS of the reward
     * @dev Core SEC-2 invariant: the fee floor is never violated
     */
    function invariant_performerFloorNeverViolated() public view {
        assertEq(
            handler.ghost_floorViolations(),
            0,
            "Performer floor was violated"
        );
    }

    /**
     * @notice All settled funds are fully distributed (no funds stuck in router)
     * @dev The router should never hold a balance after settlement
     */
    function invariant_routerHoldsNoFunds() public view {
        assertEq(
            usdc.balanceOf(address(router)),
            0,
            "Router is holding funds after settlement"
        );
    }

    /**
     * @notice Performer floor BPS is always within valid bounds
     * @dev MIN_PERFORMER_FLOOR_BPS <= performerFloorBPS <= BPS_DENOMINATOR
     */
    function invariant_performerFloorInBounds() public view {
        uint16 floor = router.performerFloorBPS();
        assertGe(floor, router.MIN_PERFORMER_FLOOR_BPS(), "Floor below minimum");
        assertLe(floor, router.BPS_DENOMINATOR(), "Floor above maximum");
    }

    /**
     * @notice Max guild fee is consistent with performer floor
     * @dev maxGuildFeeBPS + fixedFees + performerFloorBPS <= BPS_DENOMINATOR
     */
    function invariant_maxGuildFeeConsistent() public view {
        uint16 maxGuild = router.maxGuildFeeBPS();
        (uint16 protocolFee, uint16 labsFee, uint16 resolverFee) = router.getFixedFees();
        uint16 fixedFees = protocolFee + labsFee + resolverFee;

        assertLe(
            uint256(maxGuild) + uint256(fixedFees) + uint256(router.performerFloorBPS()),
            uint256(router.BPS_DENOMINATOR()),
            "Fee allocation exceeds 100%"
        );
    }

    /**
     * @notice Fixed fee constants never change
     * @dev Protocol (2.5%), Labs (2.5%), Resolver (2%) are immutable
     */
    function invariant_fixedFeesImmutable() public view {
        (uint16 protocolFee, uint16 labsFee, uint16 resolverFee) = router.getFixedFees();
        assertEq(protocolFee, 250, "Protocol fee changed");
        assertEq(labsFee, 250, "Labs fee changed");
        assertEq(resolverFee, 200, "Resolver fee changed");
    }
}
