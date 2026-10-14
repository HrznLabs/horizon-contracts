// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GuildXPVotes, IGuildXPCheckpointed} from "./GuildXPVotes.sol";

/**
 * @title GuildGovernor
 * @notice OpenZeppelin Governor implementation for Guild governance
 * @dev Uses Guild XP as voting power instead of ERC20Votes tokens
 *
 * Features:
 * - XP-based voting power, read as of the proposal snapshot (GuildXPVotes, audit H6)
 * - Quorum from total guild XP and the quorum percentage as of the proposal snapshot
 * - Configurable voting delay, period, and proposal threshold
 * - Timelock for execution delay
 * - Support for Zone, Governance, Feature, and Treasury proposals
 */
contract GuildGovernor is
    GuildXPVotes,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorTimelockControl
{
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

    /// @notice Proposal type metadata
    mapping(uint256 => ProposalType) public proposalTypes;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event ProposalCreatedWithType(
        uint256 indexed proposalId,
        ProposalType proposalType,
        address proposer
    );

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /**
     * @notice Deploy a new GuildGovernor
     * @param _guildDAO Address of the GuildDAO contract
     * @param _timelock Address of the TimelockController
     * @param _xpContract Address of the (checkpointed) XP tracking contract
     * @param _votingDelay Delay before voting starts (in blocks)
     * @param _votingPeriod Duration of voting (in blocks)
     * @param _proposalThreshold Minimum XP to create a proposal
     * @param _quorumNumerator Quorum percentage (0-100)
     */
    constructor(
        address _guildDAO,
        TimelockController _timelock,
        address _xpContract,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    )
        Governor("GuildGovernor")
        GuildXPVotes(_guildDAO, _xpContract, _quorumNumerator)
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
        GovernorTimelockControl(_timelock)
    {}

    // =============================================================================
    // PROPOSAL CREATION
    // =============================================================================

    /**
     * @notice Create a proposal with type metadata
     * @param targets Target addresses for calls
     * @param values ETH values for calls
     * @param calldatas Encoded function calls
     * @param description Proposal description
     * @param proposalType Type of proposal (Zone, Governance, Feature, Treasury)
     */
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

    function state(
        uint256 proposalId
    ) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(
        uint256 proposalId
    ) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}

// =============================================================================
// INTERFACE FOR XP CONTRACT
// =============================================================================

/**
 * @title IGuildXP
 * @notice Interface for the Guild XP tracking contract (kept for compatibility; the
 *         governor requires the checkpointed reads, see IGuildXPCheckpointed).
 */
interface IGuildXP is IGuildXPCheckpointed {}
