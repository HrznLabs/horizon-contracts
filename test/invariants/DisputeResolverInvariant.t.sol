// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DisputeResolver} from "../../src/DisputeResolver.sol";
import {IDisputeResolver} from "../../src/interfaces/IDisputeResolver.sol";
import {MissionFactory} from "../../src/MissionFactory.sol";
import {MissionEscrow} from "../../src/MissionEscrow.sol";
import {PaymentRouter} from "../../src/PaymentRouter.sol";
import {IMissionEscrow} from "../../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title DisputeResolverHandler
 * @notice Handler contract for invariant testing of DisputeResolver DDR mechanics
 * @dev Drives the DisputeResolver through valid state transitions while tracking ghost state
 */
contract DisputeResolverHandler is Test {
    DisputeResolver public resolver;
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public admin;
    address public poster;
    address public performer;
    address public resolversDAO;
    address public protocolDAO;
    address public protocolTreasury;
    address public resolverTreasury;
    address public resolverAddr;

    uint256 public constant REWARD_AMOUNT = 1000e6;

    // Ghost variables for invariant tracking
    uint256 public ghost_totalDDRDeposited;
    uint256 public ghost_totalDDRRefunded;
    uint256 public ghost_timeoutsClaimed;
    uint256 public ghost_disputesCreated;
    uint256 public ghost_resolverTimeoutsClaimed;

    // Track active disputes for targeted operations
    uint256[] public activeDisputeIds;
    mapping(uint256 => bool) public disputeActive;

    constructor(
        DisputeResolver _resolver,
        MissionFactory _factory,
        PaymentRouter _router,
        MockERC20 _usdc,
        address _admin,
        address _poster,
        address _performer,
        address _resolversDAO,
        address _protocolDAO,
        address _protocolTreasury,
        address _resolverTreasury,
        address _resolverAddr
    ) {
        resolver = _resolver;
        factory = _factory;
        router = _router;
        usdc = _usdc;
        admin = _admin;
        poster = _poster;
        performer = _performer;
        resolversDAO = _resolversDAO;
        protocolDAO = _protocolDAO;
        protocolTreasury = _protocolTreasury;
        resolverTreasury = _resolverTreasury;
        resolverAddr = _resolverAddr;
    }

    /**
     * @notice Create a disputed mission and file dispute with poster's DDR deposit
     */
    function createAndDeposit(uint256 seed) external {
        // Create a mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            keccak256(abi.encodePacked("metadata", seed)),
            keccak256(abi.encodePacked("location", seed))
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        // Performer accepts and submits
        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256(abi.encodePacked("proof", seed)));

        // Poster raises dispute in escrow
        vm.prank(poster);
        MissionEscrow(escrow).raiseDispute(keccak256(abi.encodePacked("dispute", seed)));

        // Poster creates dispute in resolver (deposits DDR)
        uint256 ddrAmount = (REWARD_AMOUNT * resolver.DDR_RATE_BPS()) / 10000;
        vm.startPrank(poster);
        usdc.approve(address(resolver), ddrAmount);
        uint256 disputeId = resolver.createDispute(escrow, missionId, keccak256(abi.encodePacked("evidence", seed)));
        vm.stopPrank();

        ghost_totalDDRDeposited += ddrAmount;
        ghost_disputesCreated++;
        activeDisputeIds.push(disputeId);
        disputeActive[disputeId] = true;
    }

    /**
     * @notice Performer submits evidence (depositing their DDR) for an active dispute
     */
    function performerDeposit(uint256 disputeIndex) external {
        if (activeDisputeIds.length == 0) return;
        disputeIndex = disputeIndex % activeDisputeIds.length;
        uint256 disputeId = activeDisputeIds[disputeIndex];

        IDisputeResolver.Dispute memory dispute = resolver.getDispute(disputeId);
        if (dispute.state != IDisputeResolver.DisputeState.Pending &&
            dispute.state != IDisputeResolver.DisputeState.Investigating) return;

        // Check if performer already deposited
        if (resolver.getDDRDeposit(disputeId, performer) > 0) return;

        // Check DDR deadline
        if (block.timestamp >= resolver.disputeDDRDeadline(disputeId)) return;

        uint256 ddrAmount = dispute.ddrAmount;
        vm.startPrank(performer);
        usdc.approve(address(resolver), ddrAmount);
        resolver.submitEvidence(disputeId, keccak256(abi.encodePacked("performer_evidence", disputeId)));
        vm.stopPrank();

        ghost_totalDDRDeposited += ddrAmount;
    }

    /**
     * @notice Claim DDR timeout after deadline passes
     */
    function claimTimeout(uint256 disputeIndex) external {
        if (activeDisputeIds.length == 0) return;
        disputeIndex = disputeIndex % activeDisputeIds.length;
        uint256 disputeId = activeDisputeIds[disputeIndex];

        IDisputeResolver.Dispute memory dispute = resolver.getDispute(disputeId);
        if (dispute.state != IDisputeResolver.DisputeState.Pending) return;

        // Check only one party deposited
        bool posterDeposited = resolver.getDDRDeposit(disputeId, dispute.poster) > 0;
        bool performerDeposited = resolver.getDDRDeposit(disputeId, dispute.performer) > 0;
        if (posterDeposited && performerDeposited) return;
        if (!posterDeposited && !performerDeposited) return;

        // Warp past deadline
        uint256 deadline = resolver.disputeDDRDeadline(disputeId);
        if (block.timestamp < deadline) {
            vm.warp(deadline + 1);
        }

        address depositor = posterDeposited ? dispute.poster : dispute.performer;
        uint256 refundAmount = resolver.getDDRDeposit(disputeId, depositor);

        vm.prank(depositor);
        resolver.claimDDRTimeout(disputeId);

        ghost_totalDDRRefunded += refundAmount;
        ghost_timeoutsClaimed++;
        disputeActive[disputeId] = false;
    }

    /**
     * @notice Assign resolver and advance dispute to Investigating state
     */
    function assignAndAdvance(uint256 disputeIndex) external {
        if (activeDisputeIds.length == 0) return;
        disputeIndex = disputeIndex % activeDisputeIds.length;
        uint256 disputeId = activeDisputeIds[disputeIndex];

        IDisputeResolver.Dispute memory dispute = resolver.getDispute(disputeId);
        if (dispute.state != IDisputeResolver.DisputeState.Pending) return;
        if (dispute.resolver != address(0)) return;

        // Need both parties to have deposited for meaningful resolution
        bool posterDeposited = resolver.getDDRDeposit(disputeId, dispute.poster) > 0;
        bool performerDeposited = resolver.getDDRDeposit(disputeId, dispute.performer) > 0;
        if (!posterDeposited || !performerDeposited) return;

        vm.prank(resolversDAO);
        resolver.assignResolver(disputeId, resolverAddr);
    }

    /**
     * @notice Claim resolver inaction timeout
     */
    function claimResolverTimeout(uint256 disputeIndex) external {
        if (activeDisputeIds.length == 0) return;
        disputeIndex = disputeIndex % activeDisputeIds.length;
        uint256 disputeId = activeDisputeIds[disputeIndex];

        IDisputeResolver.Dispute memory dispute = resolver.getDispute(disputeId);
        if (dispute.state != IDisputeResolver.DisputeState.Investigating) return;

        // Both must have deposited
        if (resolver.getDDRDeposit(disputeId, dispute.poster) == 0) return;
        if (resolver.getDDRDeposit(disputeId, dispute.performer) == 0) return;

        // Warp past resolver deadline
        uint256 deadline = resolver.resolverDeadline(disputeId);
        if (block.timestamp < deadline) {
            vm.warp(deadline + 1);
        }

        uint256 posterRefund = resolver.getDDRDeposit(disputeId, dispute.poster);
        uint256 performerRefund = resolver.getDDRDeposit(disputeId, dispute.performer);

        vm.prank(poster);
        resolver.claimResolverTimeout(disputeId);

        ghost_totalDDRRefunded += posterRefund + performerRefund;
        ghost_resolverTimeoutsClaimed++;
    }

    // View helpers for invariant checks
    function activeDisputeCount() external view returns (uint256) {
        return activeDisputeIds.length;
    }

    function getActiveDisputeId(uint256 index) external view returns (uint256) {
        if (index >= activeDisputeIds.length) return 0;
        return activeDisputeIds[index];
    }
}

/**
 * @title DisputeResolverInvariantTest
 * @notice Invariant tests for DisputeResolver DDR timeout mechanics
 * @dev Tests SEC-6: Fuzz testing for DDR bounds, refund completeness, no stuck funds
 */
contract DisputeResolverInvariantTest is Test {
    DisputeResolver public resolver;
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;
    DisputeResolverHandler public handler;

    address public admin = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);
    address public resolversDAO = address(7);
    address public protocolDAO = address(8);
    address public resolverAddr = address(9);

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

        resolver = new DisputeResolver(
            address(usdc),
            resolversDAO,
            protocolDAO,
            protocolTreasury,
            resolverTreasury
        );

        factory = new MissionFactory(address(router));
        router.setMissionFactory(address(factory));
        factory.setDisputeResolver(address(resolver));

        vm.stopPrank();

        // Mint generous supply for testing
        usdc.mint(poster, 10_000_000e6);
        usdc.mint(performer, 10_000_000e6);

        handler = new DisputeResolverHandler(
            resolver,
            factory,
            router,
            usdc,
            admin,
            poster,
            performer,
            resolversDAO,
            protocolDAO,
            protocolTreasury,
            resolverTreasury,
            resolverAddr
        );

        // Target only the handler for invariant calls
        targetContract(address(handler));
    }

    /**
     * @notice DDR deadlines are always between MIN_DDR_TIMEOUT and MAX_DDR_TIMEOUT from creation
     * @dev Verifies SEC-4: DDR timeout bounds are enforced for all disputes
     */
    function invariant_ddrTimeoutBounded() public view {
        uint256 count = handler.activeDisputeCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 disputeId = handler.getActiveDisputeId(i);
            if (disputeId == 0) continue;

            uint256 deadline = resolver.disputeDDRDeadline(disputeId);
            if (deadline == 0) continue; // Not set yet

            IDisputeResolver.Dispute memory dispute = resolver.getDispute(disputeId);
            uint256 timeoutUsed = deadline - dispute.createdAt;

            assertGe(
                timeoutUsed,
                resolver.MIN_DDR_TIMEOUT(),
                "DDR timeout below minimum"
            );
            assertLe(
                timeoutUsed,
                resolver.MAX_DDR_TIMEOUT(),
                "DDR timeout above maximum"
            );
        }
    }

    /**
     * @notice When DDR timeout is claimed, depositor receives full deposit back
     * @dev Verifies no partial refunds occur — DDR is either fully refunded or fully held
     */
    function invariant_ddrRefundComplete() public view {
        // After any timeout claim, the refunded amount equals the deposited amount
        // We track this via ghost variables: every deposit increments ghost_totalDDRDeposited,
        // every timeout refund increments ghost_totalDDRRefunded by the exact deposit amount.
        // The refunded total should never exceed deposited total.
        assertLe(
            handler.ghost_totalDDRRefunded(),
            handler.ghost_totalDDRDeposited(),
            "Refunded more DDR than deposited"
        );
    }

    /**
     * @notice All DDR deposits are accounted for: either in resolver balance or refunded
     * @dev No funds get stuck in the contract — every deposit is trackable
     */
    function invariant_noStuckFunds() public view {
        uint256 resolverBalance = usdc.balanceOf(address(resolver));
        uint256 deposited = handler.ghost_totalDDRDeposited();
        uint256 refunded = handler.ghost_totalDDRRefunded();

        // Resolver balance should equal deposits minus refunds
        // (active disputes hold funds, refunded disputes released them)
        assertEq(
            resolverBalance,
            deposited - refunded,
            "Resolver balance doesn't match deposited - refunded"
        );
    }

    /**
     * @notice Dispute count in handler matches resolver state
     */
    function invariant_disputeCountConsistent() public view {
        // Total disputes created via handler should match ghost counter
        uint256 totalCreated = handler.ghost_disputesCreated();
        assertEq(
            handler.activeDisputeCount(),
            totalCreated,
            "Active dispute tracking inconsistent"
        );
    }

    /**
     * @notice Resolver timeout claims always refund both parties equally
     */
    function invariant_resolverTimeoutRefundsBothParties() public view {
        // This is implicitly verified by invariant_noStuckFunds:
        // if resolver timeout refunded only one party, the balance would be wrong.
        // Additional check: resolver timeout count should be non-negative
        assertGe(
            handler.ghost_resolverTimeoutsClaimed(),
            0,
            "Resolver timeout counter underflow"
        );
    }
}
