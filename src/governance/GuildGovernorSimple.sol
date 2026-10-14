// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GuildXPVotes, IGuildXPCheckpointed} from "./GuildXPVotes.sol";

/**
 * @title GuildGovernorSimple
 * @notice Simplified Governor for Guild governance without timelock
 * @dev Uses Guild XP as voting power - ideal for testnet deployment. Voting power, total XP
 *      and the quorum percentage are all read as of the proposal snapshot (GuildXPVotes,
 *      audit H6).
 *
 * For production, use GuildGovernor with TimelockControl instead.
 */
contract GuildGovernorSimple is GuildXPVotes, GovernorSettings, GovernorCountingSimple {
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

    event ProposalCreatedWithType(uint256 indexed proposalId, ProposalType proposalType, address proposer);

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
        GuildXPVotes(_guildDAO, _xpContract, _quorumNumerator)
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
    {}

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

/// @notice Kept for compatibility; the governor requires the checkpointed reads.
interface IGuildXPSimple is IGuildXPCheckpointed {}
