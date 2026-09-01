// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";
import {IDisputeResolver} from "../src/interfaces/IDisputeResolver.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title DisputeResolverTimeout test
 * @notice Tests for SEC-4 (DDR timeout), MissionEscrow.settleDispute access control
 */
contract DisputeResolverTimeoutTest is Test {
    DisputeResolver public resolver;
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public admin = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);
    address public resolversDAO = address(7);
    address public protocolDAO = address(8);
    address public resolverAddr = address(9);
    address public attacker = address(10);
    address public guild = address(11);

    uint256 public constant REWARD_AMOUNT = 1000e6;
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");
    bytes32 public constant EVIDENCE_HASH = keccak256("evidence");

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

        usdc.mint(poster, 100_000e6);
        usdc.mint(performer, 100_000e6);
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    function _createDisputedMission() internal returns (uint256 missionId, address escrow) {
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256("proof"));

        // Poster raises dispute
        vm.prank(poster);
        MissionEscrow(escrow).raiseDispute(keccak256("dispute"));
    }

    // =========================================================================
    // DDR Timeout Constants
    // =========================================================================

    function test_DDRTimeoutConstants() public view {
        assertEq(resolver.DEFAULT_DDR_TIMEOUT(), 24 hours);
        assertEq(resolver.MIN_DDR_TIMEOUT(), 12 hours);
        assertEq(resolver.MAX_DDR_TIMEOUT(), 7 days);
        assertEq(resolver.RESOLVER_TIMEOUT_MULTIPLIER(), 2);
    }

    // =========================================================================
    // SEC-4: DDR Deposit Timeout
    // =========================================================================

    function test_CreateDisputeSetsDDRDeadline() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        // Poster creates dispute in DisputeResolver
        uint256 ddrAmount = (REWARD_AMOUNT * resolver.DDR_RATE_BPS()) / 10000;
        vm.startPrank(poster);
        usdc.approve(address(resolver), ddrAmount);
        uint256 disputeId = resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        // Verify deadline was set
        uint256 deadline = resolver.disputeDDRDeadline(disputeId);
        assertEq(deadline, block.timestamp + 24 hours);
    }

    function test_ClaimDDRTimeout_PerformerForfeits() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        uint256 ddrAmount = (REWARD_AMOUNT * resolver.DDR_RATE_BPS()) / 10000;

        // Poster creates dispute and deposits DDR
        vm.startPrank(poster);
        usdc.approve(address(resolver), ddrAmount);
        uint256 disputeId = resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        uint256 posterBalanceBefore = usdc.balanceOf(poster);

        // Fast forward past DDR deadline
        vm.warp(block.timestamp + 25 hours);

        // Poster claims DDR timeout
        vm.prank(poster);
        resolver.claimDDRTimeout(disputeId);

        // Poster should get full DDR refund
        assertEq(usdc.balanceOf(poster), posterBalanceBefore + ddrAmount);

        // Dispute should be finalized as Cancelled
        IDisputeResolver.Dispute memory dispute = resolver.getDispute(disputeId);
        assertEq(uint8(dispute.state), uint8(IDisputeResolver.DisputeState.Finalized));
        assertEq(uint8(dispute.outcome), uint8(IDisputeResolver.DisputeOutcome.Cancelled));
    }

    function test_RevertWhen_ClaimTimeoutBeforeDeadline() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        uint256 ddrAmount = (REWARD_AMOUNT * resolver.DDR_RATE_BPS()) / 10000;

        vm.startPrank(poster);
        usdc.approve(address(resolver), ddrAmount);
        uint256 disputeId = resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        // Try to claim before deadline
        vm.prank(poster);
        vm.expectRevert(IDisputeResolver.TimeoutNotReached.selector);
        resolver.claimDDRTimeout(disputeId);
    }

    function test_RevertWhen_NonDepositorClaimsTimeout() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        uint256 ddrAmount = (REWARD_AMOUNT * resolver.DDR_RATE_BPS()) / 10000;

        vm.startPrank(poster);
        usdc.approve(address(resolver), ddrAmount);
        uint256 disputeId = resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);

        // Performer (non-depositor) tries to claim
        vm.prank(performer);
        vm.expectRevert(IDisputeResolver.NotDepositor.selector);
        resolver.claimDDRTimeout(disputeId);
    }

    function test_DDRDeadlineBlocksLateDeposit() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        uint256 ddrAmount = (REWARD_AMOUNT * resolver.DDR_RATE_BPS()) / 10000;

        vm.startPrank(poster);
        usdc.approve(address(resolver), ddrAmount);
        uint256 disputeId = resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        // Fast forward past deadline
        vm.warp(block.timestamp + 25 hours);

        // Performer tries to submit evidence (which triggers DDR deposit)
        vm.startPrank(performer);
        usdc.approve(address(resolver), ddrAmount);
        vm.expectRevert(IDisputeResolver.DDRDeadlinePassed.selector);
        resolver.submitEvidence(disputeId, keccak256("late evidence"));
        vm.stopPrank();
    }

    // =========================================================================
    // Guild DDR Timeout Override
    // =========================================================================

    function test_SetGuildDDRTimeout() public {
        vm.prank(admin);
        resolver.setGuildDDRTimeout(guild, 48 hours);

        assertEq(resolver.guildDDRTimeout(guild), 48 hours);
    }

    function test_RevertWhen_GuildTimeoutBelowMin() public {
        vm.prank(admin);
        vm.expectRevert(IDisputeResolver.InvalidTimeout.selector);
        resolver.setGuildDDRTimeout(guild, 6 hours); // Below 12h minimum
    }

    function test_RevertWhen_GuildTimeoutAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(IDisputeResolver.InvalidTimeout.selector);
        resolver.setGuildDDRTimeout(guild, 8 days); // Above 7d maximum
    }

    // =========================================================================
    // MissionEscrow.settleDispute Access Control
    // =========================================================================

    function test_SettleDisputeOnlyByResolver() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        // Attacker tries to call settleDispute directly
        vm.prank(attacker);
        vm.expectRevert(IMissionEscrow.NotDisputeResolver.selector);
        MissionEscrow(escrow).settleDispute(1, 0); // PosterWins
    }

    function test_SettleDisputeOnlyByRegisteredResolver() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        // Even poster can't call settleDispute
        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.NotDisputeResolver.selector);
        MissionEscrow(escrow).settleDispute(1, 0);

        // Performer can't either
        vm.prank(performer);
        vm.expectRevert(IMissionEscrow.NotDisputeResolver.selector);
        MissionEscrow(escrow).settleDispute(2, 0);
    }

    function test_ResolverCanSettleDispute() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        // DisputeResolver address can call settleDispute
        vm.prank(address(resolver));
        MissionEscrow(escrow).settleDispute(1, 0); // PosterWins

        // Verify state changed
        IMissionEscrow.MissionRuntime memory runtime = MissionEscrow(escrow).getRuntime();
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Completed));
    }

    // =========================================================================
    // Resolver Timeout (inaction)
    // =========================================================================

    function test_ResolverTimeoutSetOnAssignment() public {
        (uint256 missionId, address escrow) = _createDisputedMission();

        uint256 ddrAmount = (REWARD_AMOUNT * resolver.DDR_RATE_BPS()) / 10000;

        // Create dispute
        vm.startPrank(poster);
        usdc.approve(address(resolver), ddrAmount);
        uint256 disputeId = resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        // Performer deposits DDR via evidence
        vm.startPrank(performer);
        usdc.approve(address(resolver), ddrAmount);
        resolver.submitEvidence(disputeId, keccak256("performer evidence"));
        vm.stopPrank();

        // Assign resolver
        vm.prank(resolversDAO);
        resolver.assignResolver(disputeId, resolverAddr);

        // Verify resolver deadline was set
        uint256 deadline = resolver.resolverDeadline(disputeId);
        assertTrue(deadline > block.timestamp);
    }

    // =========================================================================
    // AUDIT 2026-08-11 — H2 / H3 / H4 regressions
    // =========================================================================

    function _ddr() internal view returns (uint256) {
        return (REWARD_AMOUNT * resolver.DDR_RATE_BPS()) / 10000;
    }

    /// @dev Disputed escrow + both parties' DDR posted + resolver assigned + resolved.
    function _resolvedDispute() internal returns (uint256 disputeId, address escrow) {
        uint256 missionId;
        (missionId, escrow) = _createDisputedMission();
        uint256 d = _ddr();

        vm.startPrank(poster);
        usdc.approve(address(resolver), d);
        disputeId = resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        vm.startPrank(performer);
        usdc.approve(address(resolver), d);
        resolver.submitEvidence(disputeId, keccak256("perf evidence"));
        vm.stopPrank();

        vm.prank(resolversDAO);
        resolver.assignResolver(disputeId, resolverAddr);

        vm.prank(resolverAddr);
        resolver.resolveDispute(disputeId, IDisputeResolver.DisputeOutcome.PerformerWins, keccak256("res"), 0);
    }

    /// @notice H2: an APPEALED dispute cannot be finalized by anyone via finalizeDispute
    /// (that would lock in the pre-appeal outcome and neutralize the appeal). Only the
    /// DAO's overrideResolution may finalize an appealed dispute.
    function test_H2_AppealedDisputeCannotBeFinalizedByAnyone() public {
        (uint256 disputeId,) = _resolvedDispute();

        // A party appeals.
        vm.prank(poster);
        resolver.appealResolution(disputeId);

        // Wait past the appeal window and try to finalize — must revert.
        vm.warp(block.timestamp + resolver.APPEAL_PERIOD() + 1);
        vm.prank(attacker);
        vm.expectRevert(IDisputeResolver.InvalidDisputeState.selector);
        resolver.finalizeDispute(disputeId);

        // The DAO override is the only path for an appealed dispute.
        vm.prank(protocolDAO);
        resolver.overrideResolution(disputeId, IDisputeResolver.DisputeOutcome.PosterWins, keccak256("dao"), 0);
    }

    /// @notice H2 (positive): a Resolved, un-appealed dispute finalizes after the window.
    function test_H2_ResolvedDisputeFinalizesAfterWindow() public {
        (uint256 disputeId,) = _resolvedDispute();
        vm.warp(block.timestamp + resolver.APPEAL_PERIOD() + 1);
        resolver.finalizeDispute(disputeId); // no revert
    }

    /// @notice H3: a resolver cannot be assigned until BOTH parties have posted DDR —
    /// otherwise the sole depositor's DDR is stranded (resolve needs both, and
    /// claimDDRTimeout only refunds while Pending).
    function test_H3_AssignResolverRequiresBothDDR() public {
        (uint256 missionId, address escrow) = _createDisputedMission();
        uint256 d = _ddr();

        vm.startPrank(poster);
        usdc.approve(address(resolver), d);
        uint256 disputeId = resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        // Performer has NOT deposited — assignment must revert.
        vm.prank(resolversDAO);
        vm.expectRevert(IDisputeResolver.InsufficientDDR.selector);
        resolver.assignResolver(disputeId, resolverAddr);

        // Sole depositor can still recover via the Pending timeout path.
        vm.warp(block.timestamp + resolver.MAX_DDR_TIMEOUT() + 1);
        uint256 before = usdc.balanceOf(poster);
        vm.prank(poster);
        resolver.claimDDRTimeout(disputeId);
        assertEq(usdc.balanceOf(poster), before + d);
    }

    /// @notice H4: createDispute requires the escrow to already be Disputed. A Submitted
    /// escrow that was never raised would make finalize's settleDispute revert forever.
    function test_H4_CreateDisputeRequiresDisputedEscrow() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc), REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );
        vm.stopPrank();
        address escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();
        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256("proof"));
        // NOTE: no raiseDispute — escrow stays Submitted.

        uint256 d = _ddr();
        vm.startPrank(poster);
        usdc.approve(address(resolver), d);
        vm.expectRevert(IDisputeResolver.InvalidDisputeState.selector);
        resolver.createDispute(escrow, missionId, EVIDENCE_HASH);
        vm.stopPrank();
    }
}

