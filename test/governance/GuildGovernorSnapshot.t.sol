// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GuildXP} from "../../src/governance/GuildXP.sol";
import {GuildGovernor} from "../../src/governance/GuildGovernor.sol";
import {GuildGovernorSimple} from "../../src/governance/GuildGovernorSimple.sol";
import {GuildTimelock} from "../../src/governance/GuildTimelock.sol";
import {GuildXPVotes} from "../../src/governance/GuildXPVotes.sol";

/**
 * @title GuildGovernorSnapshotTest
 * @notice Audit H6 (issue #820): guild governance was not snapshot-safe.
 *
 *         Before the fix `_getVotes` ignored the timepoint and returned LIVE
 *         `GuildXP.getGuildXP`, and the MED-06 quorum snapshot was keyed by proposalId while
 *         OZ v5 calls `quorum(proposalSnapshot(id))` with a block number — so quorum was LIVE
 *         total XP too. Whoever can write XP (global relayer, guild relayer, guild admin)
 *         could mint weight to themselves after a proposal snapshot and decide the vote, or
 *         inflate/deflate total XP to move quorum.
 *
 *         Each `test_H6_*` exploit below passed against the old code (see the FAILED BEFORE
 *         FIX notes) and is closed now.
 */
contract GuildGovernorSnapshotTest is Test {
    GuildXP xp;
    GuildGovernorSimple gov;

    address admin = makeAddr("admin");
    address relayer = makeAddr("relayer"); // the XP-write authority (or a compromised key)
    address guild = makeAddr("guild");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint48 constant VOTING_DELAY = 1;
    uint32 constant VOTING_PERIOD = 10;
    uint256 constant QUORUM_PCT = 20;

    function setUp() public {
        vm.roll(100);
        xp = new GuildXP(admin, relayer);
        gov = new GuildGovernorSimple(guild, address(xp), VOTING_DELAY, VOTING_PERIOD, 0, QUORUM_PCT);

        // Honest state: alice 600, bob 400 → total 1,000, quorum 200.
        vm.startPrank(relayer);
        xp.updateXP(guild, alice, 600);
        xp.updateXP(guild, bob, 400);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _propose(address proposer, string memory desc) internal returns (uint256 id) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = guild;
        vm.prank(proposer);
        id = gov.propose(targets, values, calldatas, desc);
    }

    function _activate(uint256 id) internal {
        vm.roll(gov.proposalSnapshot(id) + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Active));
    }

    // =========================================================================
    // Exploit 1 — mint XP after the snapshot and outvote the guild
    // =========================================================================

    function test_H6_MintXPAfterSnapshot_DoesNotAddVotingPower() public {
        uint256 id = _propose(alice, "send treasury to attacker");
        _activate(id);

        // Alice (600) votes Against, bob (400) votes For → honest outcome: Defeated.
        vm.prank(alice);
        gov.castVote(id, 0);
        vm.prank(bob);
        gov.castVote(id, 1);

        // The XP authority mints 10,000 XP to the attacker AFTER the snapshot.
        vm.prank(relayer);
        xp.updateXP(guild, attacker, 10_000);
        assertEq(xp.getGuildXP(guild, attacker), 10_000, "live XP did change");

        // FAILED BEFORE FIX: castVote returned 10,000 and the proposal Succeeded.
        vm.prank(attacker);
        uint256 weight = gov.castVote(id, 1);
        assertEq(weight, 0, "post-snapshot XP must carry no weight");

        (uint256 against, uint256 forVotes,) = gov.proposalVotes(id);
        assertEq(against, 600);
        assertEq(forVotes, 400);

        vm.roll(gov.proposalDeadline(id) + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    /// @notice Same attack in the voting-delay window (after propose, before the snapshot
    ///         block ends) — the mint lands after the snapshot block is sealed.
    function test_H6_MintXPDuringVotingDelay_AfterSnapshotBlock_NoWeight() public {
        uint256 id = _propose(alice, "p");
        uint256 snap = gov.proposalSnapshot(id);
        vm.roll(snap + 1);
        vm.prank(relayer);
        xp.updateXP(guild, attacker, 5_000);
        assertEq(gov.getVotes(attacker, snap), 0);
        vm.prank(attacker);
        assertEq(gov.castVote(id, 1), 0);
    }

    // =========================================================================
    // Exploit 2 — strip a voter's XP before they vote
    // =========================================================================

    function test_H6_SlashXPAfterSnapshot_DoesNotRemoveVotingPower() public {
        uint256 id = _propose(alice, "p");
        _activate(id);

        vm.prank(relayer);
        xp.updateXP(guild, alice, 0);

        // FAILED BEFORE FIX: alice's vote counted 0.
        vm.prank(alice);
        assertEq(gov.castVote(id, 0), 600);
    }

    // =========================================================================
    // Exploit 3 — move quorum after the snapshot
    // =========================================================================

    function test_H6_InflateTotalXP_DoesNotRaiseQuorum() public {
        uint256 id = _propose(alice, "p");
        _activate(id);
        uint256 snap = gov.proposalSnapshot(id);

        // Bob (400 ≥ 200 quorum) votes For alone → should succeed.
        vm.prank(bob);
        gov.castVote(id, 1);

        // Inflate total XP 100x after the snapshot to make quorum unreachable.
        vm.prank(relayer);
        xp.updateXP(guild, attacker, 99_000);

        // FAILED BEFORE FIX: quorum(snapshot) read live total → 20,000; proposal Defeated.
        assertEq(gov.quorum(snap), 200, "quorum frozen at snapshot");
        vm.roll(gov.proposalDeadline(id) + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_H6_DeflateTotalXP_DoesNotLowerQuorum() public {
        uint256 id = _propose(alice, "p");
        _activate(id);
        uint256 snap = gov.proposalSnapshot(id);

        // Wipe everyone's XP so a tiny vote would meet a live quorum of ~0.
        vm.startPrank(relayer);
        xp.updateXP(guild, alice, 0);
        xp.updateXP(guild, bob, 0);
        vm.stopPrank();

        assertEq(gov.quorum(snap), 200);
    }

    /// @notice The old MED-06 mitigation stored a value keyed by proposalId, but OZ asks
    ///         for quorum at a block number. Prove the governor's own state machine now
    ///         uses the snapshot value.
    function test_H6_OZQuorumPath_UsesSnapshotTimepoint() public {
        uint256 id = _propose(alice, "p");
        _activate(id);
        uint256 snap = gov.proposalSnapshot(id);

        vm.prank(relayer);
        xp.updateXP(guild, attacker, 1_000_000);

        // Exactly-at-quorum vote: 200 needed. Bob's 400 reaches it only with the snapshot quorum.
        vm.prank(bob);
        gov.castVote(id, 1);
        assertEq(gov.quorum(snap), (1000 * QUORUM_PCT) / 100);
        vm.roll(gov.proposalDeadline(id) + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    // =========================================================================
    // Exploit 4 — change quorum % / XP source via another proposal mid-vote
    // =========================================================================

    function test_H6_SetQuorumMidVote_DoesNotAffectSnapshottedProposal() public {
        // Proposal A: raise quorum to 100%.
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(gov);
        calldatas[0] = abi.encodeCall(GuildXPVotes.setQuorum, (100));
        vm.prank(alice);
        uint256 a = gov.propose(targets, values, calldatas, "quorum 100");

        // Proposal B created in the same block — snapshot shares A's timepoint.
        uint256 b = _propose(bob, "b");
        uint256 snapB = gov.proposalSnapshot(b);

        _activate(a);
        vm.prank(alice);
        gov.castVote(a, 1);
        vm.prank(bob);
        gov.castVote(b, 1); // 400 ≥ 20% of 1,000

        vm.roll(gov.proposalDeadline(a) + 1);
        gov.execute(targets, values, calldatas, keccak256(bytes("quorum 100")));
        assertEq(gov.quorumNumerator(), 100);

        // FAILED BEFORE FIX (live quorumNumerator): B needed 100% = 1,000 → Defeated.
        assertEq(gov.quorumNumerator(snapB), QUORUM_PCT);
        assertEq(gov.quorum(snapB), 200);
        assertEq(uint8(gov.state(b)), uint8(IGovernor.ProposalState.Succeeded));

        // New proposals do pick up the new quorum.
        uint256 c = _propose(alice, "c");
        vm.roll(gov.proposalSnapshot(c) + 1);
        assertEq(gov.quorum(gov.proposalSnapshot(c)), 1000);
    }

    function test_H6_SetXPContract_OnlyAffectsLaterSnapshots() public {
        GuildXP rogue = new GuildXP(admin, attacker);
        vm.prank(attacker);
        rogue.updateXP(guild, attacker, 1_000_000);

        // Governance itself swaps the XP source.
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(gov);
        calldatas[0] = abi.encodeCall(GuildXPVotes.setXPContract, (address(rogue)));
        vm.prank(alice);
        uint256 swap = gov.propose(targets, values, calldatas, "swap xp");
        uint256 victim = _propose(bob, "victim");

        _activate(swap);
        vm.prank(alice);
        gov.castVote(swap, 1);
        vm.roll(gov.proposalDeadline(swap) + 1);
        gov.execute(targets, values, calldatas, keccak256(bytes("swap xp")));
        assertEq(address(gov.xpContract()), address(rogue));

        // `victim` was snapshotted under the honest XP source — but its voting window has
        // closed; check the read path directly at its snapshot.
        uint256 snap = gov.proposalSnapshot(victim);
        assertEq(gov.getVotes(attacker, snap), 0, "old snapshot still reads honest source");
        assertEq(gov.getVotes(alice, snap), 600);
    }

    // =========================================================================
    // Lookups and the timelock variant
    // =========================================================================

    function test_H6_FutureLookup_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(GuildXP.FutureLookup.selector, block.number, uint48(block.number))
        );
        xp.getPastGuildXP(guild, alice, block.number);
        vm.expectRevert();
        xp.getPastTotalGuildXP(guild, block.number + 5);
    }

    function test_H6_PastLookups_TrackHistory() public {
        // Literal block numbers: under via_ir a cached `block.number` local can be re-read
        // after vm.roll. setUp leaves the chain at block 101.
        uint256 b0 = 101;
        vm.prank(relayer);
        xp.updateXP(guild, alice, 900);
        vm.roll(b0 + 1);
        vm.prank(relayer);
        xp.updateXP(guild, alice, 100);
        vm.roll(b0 + 2);

        assertEq(xp.getPastGuildXP(guild, alice, b0 - 1), 600);
        assertEq(xp.getPastGuildXP(guild, alice, b0), 900);
        assertEq(xp.getPastGuildXP(guild, alice, b0 + 1), 100);
        assertEq(xp.getPastTotalGuildXP(guild, b0 - 1), 1000);
        assertEq(xp.getPastTotalGuildXP(guild, b0), 1300);
        assertEq(xp.getPastTotalGuildXP(guild, b0 + 1), 500);
    }

    function test_H6_SameBlockWrites_LastValueWins() public {
        uint256 b0 = 101;
        vm.startPrank(relayer);
        xp.updateXP(guild, attacker, 50);
        xp.updateXP(guild, attacker, 7);
        vm.stopPrank();
        vm.roll(b0 + 1);
        assertEq(xp.getPastGuildXP(guild, attacker, b0), 7);
        assertEq(xp.getPastTotalGuildXP(guild, b0), 1007);
    }

    function test_H6_ProposalThreshold_UsesPastXP() public {
        GuildGovernorSimple g = new GuildGovernorSimple(guild, address(xp), 1, 10, 500, 20);
        // attacker gets 10,000 XP in the current block — not yet visible at clock()-1.
        vm.prank(relayer);
        xp.updateXP(guild, attacker, 10_000);
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        vm.prank(attacker);
        vm.expectRevert();
        g.propose(targets, values, calldatas, "x");
    }

    function test_H6_TimelockGovernor_MintAfterSnapshot_NoWeight() public {
        address[] memory none = new address[](0);
        GuildTimelock tl = new GuildTimelock(1 hours, none, none, address(this), guild);
        GuildGovernor tg = new GuildGovernor(
            guild, TimelockController(payable(address(tl))), address(xp), 1, 10, 0, 20
        );

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = guild;
        vm.prank(alice);
        uint256 id = tg.propose(targets, values, calldatas, "t");
        vm.roll(tg.proposalSnapshot(id) + 1);

        vm.prank(relayer);
        xp.updateXP(guild, attacker, 10_000);

        // FAILED BEFORE FIX: 10,000.
        vm.prank(attacker);
        assertEq(tg.castVote(id, 1), 0);
        vm.prank(alice);
        assertEq(tg.castVote(id, 1), 600);
        assertEq(tg.quorum(tg.proposalSnapshot(id)), 200);
    }

    function test_H6_Constructor_RejectsZeroXPAndBadQuorum() public {
        vm.expectRevert(GuildXPVotes.InvalidXPContract.selector);
        new GuildGovernorSimple(guild, address(0), 1, 10, 0, 20);
        vm.expectRevert(GuildXPVotes.InvalidQuorum.selector);
        new GuildGovernorSimple(guild, address(xp), 1, 10, 0, 101);
    }
}
