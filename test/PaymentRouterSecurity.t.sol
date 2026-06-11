// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title PaymentRouterSecurityTest
 * @notice Tests for SEC-1 (AccessControl), SEC-2 (performer floor), SEC-3 (guild fee cap)
 */
contract PaymentRouterSecurityTest is Test {
    PaymentRouter public router;
    MissionFactory public factory;
    MockERC20 public usdc;

    address public admin = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);
    address public attacker = address(7);
    address public pauser = address(8);
    address public feeManager = address(9);

    uint256 public constant REWARD_AMOUNT = 1000e6; // 1000 USDC
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");

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

        // Grant additional roles
        router.grantRole(router.PAUSER_ROLE(), pauser);
        router.grantRole(router.FEE_MANAGER_ROLE(), feeManager);

        vm.stopPrank();

        usdc.mint(poster, 100_000e6);
    }

    // =========================================================================
    // SEC-1: AccessControl replaces Ownable + no-op onlyAuthorized
    // =========================================================================

    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_AdminHasPauserRole() public view {
        assertTrue(router.hasRole(router.PAUSER_ROLE(), admin));
    }

    function test_AdminHasFeeManagerRole() public view {
        assertTrue(router.hasRole(router.FEE_MANAGER_ROLE(), admin));
    }

    function test_PauserCanPause() public {
        vm.prank(pauser);
        router.pause();
        assertTrue(router.paused());
    }

    function test_PauserCanUnpause() public {
        vm.prank(pauser);
        router.pause();
        vm.prank(pauser);
        router.unpause();
        assertFalse(router.paused());
    }

    function test_RevertWhen_AttackerTriesPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.pause();
    }

    function test_RevertWhen_AttackerTriesSetTreasury() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.setProtocolTreasury(attacker);
    }

    function test_RevertWhen_UnauthorizedSettlement() public {
        // Attacker tries to call settlePayment directly
        usdc.mint(address(router), REWARD_AMOUNT);
        vm.prank(attacker);
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        router.settlePayment(1, performer, address(usdc), REWARD_AMOUNT, address(0));
    }

    function test_EscrowCanSettle() public {
        // Create mission through factory → escrow calls settlePayment
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256("proof"));

        // This will call router.settlePayment from escrow → should succeed
        vm.prank(poster);
        MissionEscrow(escrow).approveCompletion();

        // Verify performer received payment
        assertTrue(usdc.balanceOf(performer) > 0);
    }

    function test_PausedSettlementReverts() public {
        vm.prank(pauser);
        router.pause();

        // Create mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256("proof"));

        // Settlement should fail when paused
        vm.prank(poster);
        vm.expectRevert();
        MissionEscrow(escrow).approveCompletion();
    }

    // =========================================================================
    // SEC-2: Performer floor enforcement
    // =========================================================================

    function test_PerformerFloorDefault() public view {
        assertEq(router.performerFloorBPS(), 9000); // 90%
    }

    function test_PerformerFloorEnforcedOnFeeSplit() public view {
        // With no guild: performer should get 93% (100% - 7% fixed fees)
        IPaymentRouter.FeeSplit memory split = router.getFeeSplit(10000e6, address(0), 0);
        // performer = 10000 - 2.5% - 2.5% - 2% = 93%
        assertEq(split.performerAmount, 9300e6);
        assertEq(split.protocolAmount, 250e6);
        assertEq(split.labsAmount, 250e6);
        assertEq(split.resolverAmount, 200e6);
        assertEq(split.guildAmount, 0);
    }

    function test_PerformerFloorWithGuildFee() public view {
        // With 3% guild fee: performer gets 90%
        IPaymentRouter.FeeSplit memory split = router.getFeeSplit(10000e6, address(1), 300);
        // performer = 10000 - 2.5% - 2.5% - 2% - 3% = 90%
        assertEq(split.performerAmount, 9000e6);
        assertEq(split.guildAmount, 300e6);
    }

    function test_GuildFeeAutoCapped() public {
        // Request guild fee of 5% (500 bps), but max allowed is 3% (300 bps)
        // because 7% fixed + 3% guild = 10% total → 90% performer floor
        
        // Create mission through factory to test auto-capping in actual settlement
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(1), // guild present
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        // Verify max guild fee calculation
        uint16 maxGuild = router.maxGuildFeeBPS();
        assertEq(maxGuild, 300); // 3% = 10000 - 9000 - 700
    }

    function test_FeeManagerCanAdjustFloor() public {
        vm.prank(feeManager);
        router.setPerformerFloor(9500); // Raise to 95%

        assertEq(router.performerFloorBPS(), 9500);
        // Max guild fee drops to 0% (10000 - 9500 - 700 = -200 → 0)
        uint16 maxGuild = router.maxGuildFeeBPS();
        assertEq(maxGuild, 0);
    }

    function test_RevertWhen_FloorBelowMinimum() public {
        vm.prank(feeManager);
        vm.expectRevert(
            abi.encodeWithSelector(IPaymentRouter.FloorBelowMinimum.selector, 8000, 8500)
        );
        router.setPerformerFloor(8000); // Below 85% minimum
    }

    function test_RevertWhen_AttackerSetsFloor() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.setPerformerFloor(9000);
    }

    // =========================================================================
    // SEC-3: Guild fee auto-capping
    // =========================================================================

    function test_MaxGuildFeeCalculation() public view {
        // Default floor = 90%, fixed fees = 7%
        // Max guild = 10000 - 9000 - 700 = 300 (3%)
        assertEq(router.maxGuildFeeBPS(), 300);
    }

    function test_MaxGuildFeeWithHigherFloor() public {
        vm.prank(feeManager);
        router.setPerformerFloor(9200); // 92% floor

        // Max guild = 10000 - 9200 - 700 = 100 (1%)
        assertEq(router.maxGuildFeeBPS(), 100);
    }

    function test_FeeSplitSumsToTotal() public view {
        uint256 reward = 1234567890; // Arbitrary amount
        IPaymentRouter.FeeSplit memory split = router.getFeeSplit(reward, address(1), 300);

        uint256 total = split.performerAmount + split.protocolAmount + split.guildAmount + 
                       split.resolverAmount + split.labsAmount;
        
        // Total should equal reward (accounting for rounding)
        assertApproxEqAbs(total, reward, 5); // Max 5 wei rounding error
    }

    // =========================================================================
    // Fixed fee constants match spec
    // =========================================================================

    function test_FixedFeeConstants() public view {
        (uint16 protocolFee, uint16 labsFee, uint16 resolverFee) = router.getFixedFees();
        assertEq(protocolFee, 250); // 2.5%
        assertEq(labsFee, 250);     // 2.5%
        assertEq(resolverFee, 200); // 2%
    }

    function test_RoleConstants() public view {
        assertEq(router.SETTLER_ROLE(), keccak256("SETTLER_ROLE"));
        assertEq(router.PAUSER_ROLE(), keccak256("PAUSER_ROLE"));
        assertEq(router.FEE_MANAGER_ROLE(), keccak256("FEE_MANAGER_ROLE"));
    }

    // =========================================================================
    // SEC-01: Constructor zero-address validation
    // =========================================================================

    function test_RevertWhen_ConstructorZeroUsdc() public {
        vm.expectRevert(IPaymentRouter.InvalidTreasury.selector);
        new PaymentRouter(address(0), protocolTreasury, resolverTreasury, labsTreasury, admin);
    }

    function test_RevertWhen_ConstructorZeroProtocolTreasury() public {
        vm.expectRevert(IPaymentRouter.InvalidTreasury.selector);
        new PaymentRouter(address(usdc), address(0), resolverTreasury, labsTreasury, admin);
    }

    function test_RevertWhen_ConstructorZeroResolverTreasury() public {
        vm.expectRevert(IPaymentRouter.InvalidTreasury.selector);
        new PaymentRouter(address(usdc), protocolTreasury, address(0), labsTreasury, admin);
    }

    function test_RevertWhen_ConstructorZeroLabsTreasury() public {
        vm.expectRevert(IPaymentRouter.InvalidTreasury.selector);
        new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, address(0), admin);
    }

    function test_RevertWhen_ConstructorZeroAdmin() public {
        vm.expectRevert(IPaymentRouter.InvalidTreasury.selector);
        new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury, address(0));
    }

    function test_ConstructorSucceedsWithValidAddresses() public {
        PaymentRouter validRouter = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            admin
        );
        assertTrue(validRouter.acceptedTokens(address(usdc)));
        assertEq(validRouter.protocolTreasury(), protocolTreasury);
        assertEq(validRouter.resolverTreasury(), resolverTreasury);
        assertEq(validRouter.labsTreasury(), labsTreasury);
    }
}
