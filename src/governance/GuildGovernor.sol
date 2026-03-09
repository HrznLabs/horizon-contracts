// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title GuildGovernor
 * @notice OpenZeppelin Governor implementation for Guild governance
 * @dev Uses Guild XP as voting power instead of ERC20Votes tokens
 *
 * Features:
 * - XP-based voting power (via external IGuildXP contract)
 * - Configurable voting delay, period, and proposal threshold
 * - Timelock for execution delay
 * - Support for Zone, Governance, Feature, and Treasury proposals
 */
contract GuildGovernor is Governor, GovernorSettings, GovernorCountingSimple, GovernorTimelockControl {
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
    IGuildXP public xpContract;

    /// @notice Quorum as percentage of total XP (0-100)
    uint256 public quorumNumerator;

    /// @notice Proposal type metadata
    mapping(uint256 => ProposalType) public proposalTypes;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event XPContractUpdated(address oldContract, address newContract);
    event ProposalCreatedWithType(
        uint256 indexed proposalId,
        ProposalType proposalType,
        address proposer
    );

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidQuorum();
    error InvalidXPContract();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /**
     * @notice Deploy a new GuildGovernor
     * @param _guildDAO Address of the GuildDAO contract
     * @param _timelock Address of the TimelockController
     * @param _xpContract Address of the XP tracking contract
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
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
        GovernorTimelockControl(_timelock)
    {
        if (_quorumNumerator > 100) revert InvalidQuorum();

        guildDAO = _guildDAO;
        xpContract = IGuildXP(_xpContract);
        quorumNumerator = _quorumNumerator;
    }

    // =============================================================================
    // GOVERNANCE SETTINGS
    // =============================================================================

    /**
     * @notice Update quorum percentage
     * @param newQuorum New quorum (0-100)
     */
    function setQuorum(uint256 newQuorum) external onlyGovernance {
        if (newQuorum > 100) revert InvalidQuorum();
        uint256 oldQuorum = quorumNumerator;
        quorumNumerator = newQuorum;
        emit QuorumUpdated(oldQuorum, newQuorum);
    }

    /**
     * @notice Update XP contract address
     * @param newXPContract New XP contract address
     */
    function setXPContract(address newXPContract) external onlyGovernance {
        if (newXPContract == address(0)) revert InvalidXPContract();
        address oldContract = address(xpContract);
        xpContract = IGuildXP(newXPContract);
        emit XPContractUpdated(oldContract, newXPContract);
    }

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
    // VOTING POWER (XP-based)
    // =============================================================================

    /**
     * @notice Get voting power for an account at a specific timepoint
     * @dev Uses Guild XP as voting power
     */
    function _getVotes(
        address account,
        uint256 /* timepoint */,
        bytes memory /* params */
    ) internal view override returns (uint256) {
        // Get user's XP from the XP contract
        return xpContract.getGuildXP(guildDAO, account);
    }

    // =============================================================================
    // QUORUM
    // =============================================================================

    /**
     * @notice Calculate quorum for a timepoint
     * @dev Quorum = (totalXP * quorumNumerator) / 100
     */
    function quorum(uint256 /* timepoint */) public view override returns (uint256) {
        uint256 totalXP = xpContract.getTotalGuildXP(guildDAO);
        return (totalXP * quorumNumerator) / 100;
    }

    // =============================================================================
    // CLOCK (IERC6372)
    // =============================================================================

    /**
     * @notice Returns the current block number as the clock
     */
    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    /**
     * @notice Returns the clock mode description
     */
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
 * @notice Interface for Guild XP tracking contract
 */
interface IGuildXP {
    /**
     * @notice Get a user's XP for a specific guild
     * @param guild Guild address
     * @param account User address
     * @return XP amount
     */
    function getGuildXP(address guild, address account) external view returns (uint256);

    /**
     * @notice Get total XP for a guild
     * @param guild Guild address
     * @return Total XP
     */
    function getTotalGuildXP(address guild) external view returns (uint256);
}
