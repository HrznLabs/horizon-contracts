// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GuildGovernorSimple} from "./GuildGovernorSimple.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GuildGovernorFactorySimple
 * @notice Factory for deploying simplified GuildGovernor contracts (no timelock)
 * @dev Ideal for testnet deployment where contract size limits are an issue
 */
contract GuildGovernorFactorySimple is Ownable {
    // =============================================================================
    // STATE
    // =============================================================================

    address public xpContract;
    mapping(address => address) public guildGovernors;

    uint48 public defaultVotingDelay = 1; // 1 block
    uint32 public defaultVotingPeriod = 50_400; // ~1 week
    uint256 public defaultProposalThreshold = 100; // 100 XP
    uint256 public defaultQuorum = 10; // 10%

    // =============================================================================
    // EVENTS
    // =============================================================================

    event GovernanceDeployed(address indexed guild, address indexed governor);
    event DefaultsUpdated(uint48 votingDelay, uint32 votingPeriod, uint256 proposalThreshold, uint256 quorum);
    event XPContractUpdated(address oldContract, address newContract);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error GovernanceAlreadyDeployed();
    error InvalidXPContract();
    error InvalidParameters();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(address _xpContract) Ownable(msg.sender) {
        if (_xpContract == address(0)) revert InvalidXPContract();
        xpContract = _xpContract;
    }

    // =============================================================================
    // DEPLOYMENT
    // =============================================================================

    function deployGovernance(address guildDAO) external returns (address governor) {
        return deployGovernanceWithParams(
            guildDAO,
            defaultVotingDelay,
            defaultVotingPeriod,
            defaultProposalThreshold,
            defaultQuorum
        );
    }

    function deployGovernanceWithParams(
        address guildDAO,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumPercent
    ) public returns (address governor) {
        if (guildGovernors[guildDAO] != address(0)) revert GovernanceAlreadyDeployed();
        if (quorumPercent > 100) revert InvalidParameters();

        GuildGovernorSimple governorContract = new GuildGovernorSimple(
            guildDAO,
            xpContract,
            votingDelay,
            votingPeriod,
            proposalThreshold,
            quorumPercent
        );
        governor = address(governorContract);
        guildGovernors[guildDAO] = governor;

        emit GovernanceDeployed(guildDAO, governor);
        return governor;
    }

    // =============================================================================
    // ADMIN
    // =============================================================================

    function setDefaults(
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorum
    ) external onlyOwner {
        if (quorum > 100) revert InvalidParameters();
        defaultVotingDelay = votingDelay;
        defaultVotingPeriod = votingPeriod;
        defaultProposalThreshold = proposalThreshold;
        defaultQuorum = quorum;
        emit DefaultsUpdated(votingDelay, votingPeriod, proposalThreshold, quorum);
    }

    function setXPContract(address newXPContract) external onlyOwner {
        if (newXPContract == address(0)) revert InvalidXPContract();
        address oldContract = xpContract;
        xpContract = newXPContract;
        emit XPContractUpdated(oldContract, newXPContract);
    }

    // =============================================================================
    // VIEW
    // =============================================================================

    function hasGovernance(address guildDAO) external view returns (bool) {
        return guildGovernors[guildDAO] != address(0);
    }

    function getGovernance(address guildDAO) external view returns (address) {
        return guildGovernors[guildDAO];
    }
}
