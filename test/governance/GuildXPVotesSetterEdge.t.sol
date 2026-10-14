// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GuildXP} from "../../src/governance/GuildXP.sol";
import {GuildGovernor} from "../../src/governance/GuildGovernor.sol";
import {GuildGovernorSimple} from "../../src/governance/GuildGovernorSimple.sol";
import {GuildXPVotes} from "../../src/governance/GuildXPVotes.sol";

/// @notice PR #963 review follow-up: H6 edge cases ported from the adversarial review.
///         The setter-in-snapshot-block tests FAILED before the fix (setter checkpoints were
///         keyed at clock(), and snapshot lookups are inclusive).
contract GuildXPVotesSetterEdgeTest is Test {
    GuildXP xp;
    GuildGovernorSimple gov;
    GuildGovernor tgov;
    TimelockController timelock;

    address admin = makeAddr("admin");
    address relayer = makeAddr("relayer");
    address guild = makeAddr("guild");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint48 constant VOTING_DELAY = 1;
    uint32 constant VOTING_PERIOD = 10;
    uint256 constant THRESHOLD = 100;
    uint256 constant QUORUM_PCT = 20;

    function setUp() public {
        vm.roll(100);
        xp = new GuildXP(admin, relayer);
        gov = new GuildGovernorSimple(guild, address(xp), VOTING_DELAY, VOTING_PERIOD, THRESHOLD, QUORUM_PCT);

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0);
        executors[0] = address(0);
        timelock = new TimelockController(1, proposers, executors, address(this));
        tgov = new GuildGovernor(guild, timelock, address(xp), VOTING_DELAY, VOTING_PERIOD, THRESHOLD, QUORUM_PCT);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(tgov));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(tgov));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(tgov));

        vm.startPrank(relayer);
        xp.updateXP(guild, alice, 600);
        xp.updateXP(guild, bob, 400);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _calls() internal view returns (address[] memory t, uint256[] memory v, bytes[] memory c) {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = guild;
    }

    // -------------------------------------------------------------------------
    // Flash-XP in the propose block: threshold is read at clock()-1 so XP written in
    // the same block as propose() (relayer tx ordered before it) does not count.
    // -------------------------------------------------------------------------
    function test_H6_FlashXPInProposeBlock_CannotMeetProposalThreshold() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _calls();
        vm.prank(relayer);
        xp.updateXP(guild, attacker, THRESHOLD); // same block
        assertEq(xp.getGuildXP(guild, attacker), THRESHOLD);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, attacker, 0, THRESHOLD
            )
        );
        gov.propose(t, v, c, "flash");

        vm.roll(block.number + 1);
        vm.prank(attacker);
        uint256 id = gov.propose(t, v, c, "flash");
        assertGt(id, 0);
    }

    // -------------------------------------------------------------------------
    // Authorization: the checkpointed setters are governance-only on both governors.
    // -------------------------------------------------------------------------
    function _assertSettersRevertFor(address caller) internal {
        bytes memory err = abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(err);
        gov.setQuorum(1);
        vm.expectRevert(err);
        gov.setXPContract(address(0xBEEF));
        vm.expectRevert(err);
        tgov.setQuorum(1);
        vm.expectRevert(err);
        tgov.setXPContract(address(0xBEEF));
        vm.stopPrank();
    }

    function test_H6_DirectSetQuorumAndXPContract_RevertForEveryone() public {
        _assertSettersRevertFor(admin);
        _assertSettersRevertFor(relayer);
        _assertSettersRevertFor(attacker);
        // The timelock itself (executor of tgov) cannot bypass the governance-call queue.
        vm.prank(address(timelock));
        vm.expectRevert();
        tgov.setQuorum(1);
        assertEq(gov.quorumNumerator(), QUORUM_PCT);
        assertEq(tgov.quorumNumerator(), QUORUM_PCT);
    }

    // -------------------------------------------------------------------------
    // Snapshot sealing: a vote cast in the first Active block for XP minted in the
    // snapshot block counts (prior lens), but XP minted one block later does not, and
    // the attacker cannot re-vote to pick up weight (one vote per account).
    // -------------------------------------------------------------------------
    function test_H6_NoRevoteAfterLateMint() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _calls();
        vm.prank(alice);
        uint256 id = gov.propose(t, v, c, "p");
        vm.roll(gov.proposalSnapshot(id) + 1);
        vm.prank(attacker);
        assertEq(gov.castVote(id, 1), 0);
        vm.prank(relayer);
        xp.updateXP(guild, attacker, 10_000);
        vm.roll(block.number + 1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, attacker));
        gov.castVote(id, 1);
        assertEq(gov.getVotes(attacker, gov.proposalSnapshot(id)), 0);
    }

    // -------------------------------------------------------------------------
    // XP-source swap landing in a block that is also some proposal's snapshot block.
    // Before the fix that proposal read the NEW source at its snapshot (inclusive), so an
    // empty-history replacement zeroed every voter's weight and the quorum. Now the change
    // is keyed at execution block + 1 and the concurrent proposal keeps its weight.
    // -------------------------------------------------------------------------
    function _govCall(bytes memory data)
        internal
        view
        returns (address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = address(gov);
        c[0] = data;
    }

    function _passGovernanceCall(bytes memory data, string memory desc) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _govCall(data);
        vm.prank(alice);
        uint256 id = gov.propose(t, v, c, desc);
        vm.roll(gov.proposalSnapshot(id) + 1);
        vm.prank(alice);
        gov.castVote(id, 1);
        vm.prank(bob);
        gov.castVote(id, 1);
        vm.roll(gov.proposalDeadline(id) + 1);
        assertEq(uint8(gov.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function _executeGovernanceCall(bytes memory data, string memory desc) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _govCall(data);
        gov.execute(t, v, c, keccak256(bytes(desc)));
    }

    /// @dev Alice proposes in block E-1 so the victim's snapshot is E; returns (id, E).
    function _victim(string memory desc) internal returns (uint256 victim, uint256 snap) {
        vm.roll(block.number + 1);
        (address[] memory t2, uint256[] memory v2, bytes[] memory c2) = _calls();
        vm.prank(alice);
        victim = gov.propose(t2, v2, c2, desc);
        snap = gov.proposalSnapshot(victim);
    }

    function test_H6_SetXPContract_InSnapshotBlock_ConcurrentProposalKeepsWeight() public {
        GuildXP rogue = new GuildXP(admin, relayer); // no history for `guild`
        bytes memory data = abi.encodeWithSelector(GuildXPVotes.setXPContract.selector, address(rogue));
        _passGovernanceCall(data, "swap");
        (uint256 victim, uint256 snap) = _victim("victim");

        // Swap executes in block E (== snap): anyone can call execute.
        vm.roll(snap);
        _executeGovernanceCall(data, "swap");
        assertEq(address(gov.xpContract()), address(rogue), "latest setting reported");

        vm.roll(snap + 1);
        assertEq(uint8(gov.state(victim)), uint8(IGovernor.ProposalState.Active));
        vm.prank(alice);
        uint256 w = gov.castVote(victim, 1);
        assertEq(w, 600, "snapshot-block voter keeps the XP of the old source");
        assertEq(gov.quorum(snap), 200, "quorum still read from the old source");
        vm.roll(gov.proposalDeadline(victim) + 1);
        assertEq(uint8(gov.state(victim)), uint8(IGovernor.ProposalState.Succeeded));

        // The new source does apply to every snapshot after the execution block.
        assertEq(gov.quorum(snap + 1), 0);
        assertEq(gov.getVotes(alice, snap + 1), 0);
    }

    function test_H6_SetQuorum_InSnapshotBlock_ConcurrentProposalKeepsQuorum() public {
        bytes memory data = abi.encodeWithSelector(GuildXPVotes.setQuorum.selector, uint256(100));
        _passGovernanceCall(data, "q100");
        (uint256 victim, uint256 snap) = _victim("victim-q");

        vm.roll(snap);
        _executeGovernanceCall(data, "q100");
        assertEq(gov.quorumNumerator(), 100, "latest setting reported");
        assertEq(gov.quorumNumerator(snap), QUORUM_PCT, "not retroactive to the execution block");
        assertEq(gov.quorumNumerator(snap + 1), 100);

        vm.roll(snap + 1);
        vm.prank(alice);
        gov.castVote(victim, 1); // 600 of 1000 XP: meets 20%, would miss 100%
        vm.roll(gov.proposalDeadline(victim) + 1);
        assertEq(gov.quorum(snap), 200);
        assertEq(uint8(gov.state(victim)), uint8(IGovernor.ProposalState.Succeeded));
    }
}
