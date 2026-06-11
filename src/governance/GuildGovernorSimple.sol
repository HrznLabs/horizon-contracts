// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

/**
 * @title GuildGovernorSimple
 * @notice Simplified Governor for Guild governance without timelock
 * @dev Uses Guild XP as voting power - ideal for testnet deployment
 *
 * For production, use GuildGovernor with TimelockControl instead.
 */
contract GuildGovernorSimple is Governor, GovernorSettings, GovernorCountingSimple {
    // =============================================================================
    // TYPES
    // =============================================================================

    enum ProposalType {
        Zone,
        Governance,
        Feature,
        Treasury
    }

    // =============================================================================
    // STATE
    // =============================================================================

    /// @notice The Guild DAO this governor is attached to
    address public immutable guildDAO;

    /// @notice Contract that tracks Guild XP for voting power
    IGuildXPSimple public xpContract;

    /// @notice Quorum as percentage of total XP (0-100)
    uint256 public quorumNumerator;

    /// @notice Proposal type metadata
    mapping(uint256 => ProposalType) public proposalTypes;

    /**
     * @notice Snapshot of totalGuildXP recorded at proposal creation time.
     * @dev Security (MED-06): Reading live totalGuildXP in quorum() allows an attacker
     *      to manipulate the quorum threshold between proposal creation and vote tallying
     *      by temporarily inflating or deflating XP. Snapshotting at propose time locks
     *      the quorum denominator for the lifetime of that proposal.
     */
    mapping(uint256 => uint256) public proposalQuorumSnapshot;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event XPContractUpdated(address oldContract, address newContract);
    event ProposalCreatedWithType(uint256 indexed proposalId, ProposalType proposalType, address proposer);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidQuorum();
    error InvalidXPContract();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(
        address _guildDAO,
        address _xpContract,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    )
        Governor("GuildGovernor")
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
    {
        if (_quorumNumerator > 100) revert InvalidQuorum();
        guildDAO = _guildDAO;
        xpContract = IGuildXPSimple(_xpContract);
        quorumNumerator = _quorumNumerator;
    }

    // =============================================================================
    // GOVERNANCE SETTINGS
    // =============================================================================

    function setQuorum(uint256 newQuorum) external onlyGovernance {
        if (newQuorum > 100) revert InvalidQuorum();
        uint256 oldQuorum = quorumNumerator;
        quorumNumerator = newQuorum;
        emit QuorumUpdated(oldQuorum, newQuorum);
    }

    function setXPContract(address newXPContract) external onlyGovernance {
        if (newXPContract == address(0)) revert InvalidXPContract();
        address oldContract = address(xpContract);
        xpContract = IGuildXPSimple(newXPContract);
        emit XPContractUpdated(oldContract, newXPContract);
    }

    // =============================================================================
    // PROPOSAL CREATION
    // =============================================================================

    function proposeWithType(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        ProposalType proposalType
    ) public returns (uint256) {
        uint256 proposalId = propose(targets, values, calldatas, description);
        proposalTypes[proposalId] = proposalType;
        emit ProposalCreatedWithType(proposalId, proposalType, msg.sender);
        return proposalId;
    }

    /**
     * @notice Internal propose hook — records total XP snapshot at proposal creation.
     * @dev Security (MED-06): Overrides Governor._propose to capture totalGuildXP before
     *      any votes are cast. This snapshot is used by quorum() so that XP changes after
     *      proposal creation cannot retroactively manipulate the quorum threshold.
     */
    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override returns (uint256 proposalId) {
        proposalId = super._propose(targets, values, calldatas, description, proposer);
        proposalQuorumSnapshot[proposalId] = xpContract.getTotalGuildXP(guildDAO);
    }

    // =============================================================================
    // VOTING POWER (XP-based)
    // =============================================================================

    function _getVotes(address account, uint256, bytes memory) internal view override returns (uint256) {
        return xpContract.getGuildXP(guildDAO, account);
    }

    // =============================================================================
    // QUORUM
    // =============================================================================

    /**
     * @notice Calculate quorum for a given proposal.
     * @param proposalId The proposal ID whose snapshot to use.
     * @dev Security (MED-06): Reads from proposalQuorumSnapshot[proposalId] instead of live
     *      totalGuildXP to prevent quorum manipulation between proposal creation and vote tallying.
     *      Falls back to live XP only when the snapshot is zero (e.g., compatibility calls).
     */
    function quorum(uint256 proposalId) public view override returns (uint256) {
        uint256 snapshotXP = proposalQuorumSnapshot[proposalId];
        uint256 totalXP = snapshotXP > 0 ? snapshotXP : xpContract.getTotalGuildXP(guildDAO);
        return (totalXP * quorumNumerator) / 100;
    }

    // =============================================================================
    // CLOCK (IERC6372)
    // =============================================================================

    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    // =============================================================================
    // REQUIRED OVERRIDES
    // =============================================================================

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }
}

interface IGuildXPSimple {
    function getGuildXP(address guild, address account) external view returns (uint256);
    function getTotalGuildXP(address guild) external view returns (uint256);
}
