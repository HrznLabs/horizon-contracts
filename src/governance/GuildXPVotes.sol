// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title IGuildXPCheckpointed
 * @notice Snapshot-capable XP source used for guild voting power (audit H6).
 */
interface IGuildXPCheckpointed {
    function getGuildXP(address guild, address account) external view returns (uint256);
    function getTotalGuildXP(address guild) external view returns (uint256);
    /// @notice XP of `account` in `guild` as of the end of past block `timepoint`.
    function getPastGuildXP(
        address guild,
        address account,
        uint256 timepoint
    ) external view returns (uint256);
    /// @notice Total XP of `guild` as of the end of past block `timepoint`.
    function getPastTotalGuildXP(address guild, uint256 timepoint) external view returns (uint256);
}

/**
 * @title GuildXPVotes
 * @notice Snapshot-safe XP voting power and quorum for the guild governors.
 * @dev Audit H6. Before this, `_getVotes` ignored the timepoint OZ passes and read LIVE XP,
 *      and the MED-06 "quorum snapshot" was keyed by proposalId while OZ v5 calls
 *      `quorum(proposalSnapshot(proposalId))` — a block number — so the lookup always
 *      missed and quorum fell back to LIVE total XP. Anyone able to write XP (relayer,
 *      guild admin, or a compromised key) could therefore rewrite both the weight and the
 *      quorum of an open vote.
 *
 *      Now every input to a vote is read as of the proposal's snapshot timepoint:
 *      - voting power:   `xp.getPastGuildXP(guild, account, timepoint)`
 *      - quorum base:    `xp.getPastTotalGuildXP(guild, timepoint)`
 *      - quorum percent: checkpointed history of `quorumNumerator` (like OZ
 *        GovernorVotesQuorumFraction), so a `setQuorum` passed by another proposal does not
 *        move the bar for proposals already snapshotted
 *      - XP source:      checkpointed history of `xpContract`, so `setXPContract` cannot swap
 *        the voting-power source under an open proposal
 *
 *      Setter checkpoints are written at `clock() + 1` (PR #963 review): lookups are
 *      inclusive (`upperLookupRecent(snapshot)`), so a change checkpointed at `clock()` and
 *      executed in block E would retroactively apply to a proposal whose snapshot is E
 *      (created at E - votingDelay). Keying it at E + 1 means a change never affects any
 *      proposal whose snapshot is at or before its execution block.
 */
abstract contract GuildXPVotes is Governor {
    using Checkpoints for Checkpoints.Trace208;

    /// @notice The Guild DAO this governor is attached to
    address public immutable guildDAO;

    Checkpoints.Trace208 private _xpContractHistory;
    Checkpoints.Trace208 private _quorumNumeratorHistory;

    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event XPContractUpdated(address oldContract, address newContract);

    error InvalidQuorum();
    error InvalidXPContract();

    constructor(address _guildDAO, address _xpContract, uint256 _quorumNumerator) {
        if (_quorumNumerator > 100) revert InvalidQuorum();
        if (_xpContract == address(0)) revert InvalidXPContract();
        guildDAO = _guildDAO;
        // Initial settings are keyed at timepoint 0, not clock() (issue #969): OZ `propose`
        // reads the proposer's votes at `clock() - 1`, so a governor deployed by a factory in
        // block D would look up the XP source at D - 1, find no checkpoint (address(0)) and
        // revert — no proposal could be made in the deployment block. Keying at 0 makes the
        // constructor values the baseline for every past timepoint; later setter changes are
        // still keyed at `clock() + 1` and never move an existing snapshot.
        _xpContractHistory.push(0, uint160(_xpContract));
        _quorumNumeratorHistory.push(0, SafeCast.toUint208(_quorumNumerator));
    }

    // =========================================================================
    // SETTINGS (checkpointed)
    // =========================================================================

    /// @notice Most recently set XP contract (in force for snapshots after the block it was set).
    function xpContract() public view returns (IGuildXPCheckpointed) {
        return IGuildXPCheckpointed(address(uint160(_xpContractHistory.latest())));
    }

    /// @notice Most recently set quorum percentage (0-100), in force for snapshots after the
    ///         block it was set.
    function quorumNumerator() public view returns (uint256) {
        return _quorumNumeratorHistory.latest();
    }

    /// @notice Quorum percentage in force at `timepoint`.
    function quorumNumerator(uint256 timepoint) public view returns (uint256) {
        return _quorumNumeratorHistory.upperLookupRecent(SafeCast.toUint48(timepoint));
    }

    /// @notice Update quorum percentage (0-100). Applies to snapshots after the current block.
    function setQuorum(uint256 newQuorum) external onlyGovernance {
        if (newQuorum > 100) revert InvalidQuorum();
        uint256 oldQuorum = quorumNumerator();
        _quorumNumeratorHistory.push(clock() + 1, SafeCast.toUint208(newQuorum));
        emit QuorumUpdated(oldQuorum, newQuorum);
    }

    /// @notice Update XP contract. Applies to snapshots after the current block.
    function setXPContract(address newXPContract) external onlyGovernance {
        if (newXPContract == address(0)) revert InvalidXPContract();
        address oldContract = address(xpContract());
        _xpContractHistory.push(clock() + 1, uint160(newXPContract));
        emit XPContractUpdated(oldContract, newXPContract);
    }

    // =========================================================================
    // SNAPSHOT READS
    // =========================================================================

    function _xpContractAt(uint256 timepoint) internal view returns (IGuildXPCheckpointed) {
        return IGuildXPCheckpointed(
            address(uint160(_xpContractHistory.upperLookupRecent(SafeCast.toUint48(timepoint))))
        );
    }

    /// @dev Voting power = guild XP as of `timepoint` (the proposal snapshot).
    function _getVotes(
        address account,
        uint256 timepoint,
        bytes memory /* params */
    ) internal view virtual override returns (uint256) {
        return _xpContractAt(timepoint).getPastGuildXP(guildDAO, account, timepoint);
    }

    /**
     * @notice Quorum at `timepoint`. OZ passes `proposalSnapshot(proposalId)` here.
     * @dev Total XP and the quorum percentage are both read as of `timepoint`.
     */
    function quorum(uint256 timepoint) public view virtual override returns (uint256) {
        uint256 totalXP = _xpContractAt(timepoint).getPastTotalGuildXP(guildDAO, timepoint);
        return (totalXP * quorumNumerator(timepoint)) / 100;
    }

    // =========================================================================
    // CLOCK (IERC6372) — block number, matching GuildXP
    // =========================================================================

    function clock() public view virtual override returns (uint48) {
        return SafeCast.toUint48(block.number);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=blocknumber&from=default";
    }
}
