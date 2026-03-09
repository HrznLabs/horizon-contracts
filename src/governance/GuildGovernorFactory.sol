// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GuildGovernor} from "./GuildGovernor.sol";
import {GuildTimelock} from "./GuildTimelock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GuildGovernorFactory
 * @notice Factory for deploying GuildGovernor and GuildTimelock contracts
 * @dev Deploys a matched pair of Governor + Timelock for each guild
 */
contract GuildGovernorFactory is Ownable {
    // =============================================================================
    // STATE
    // =============================================================================

    /// @notice XP contract used for voting power
    address public xpContract;

    /// @notice Deployed governors by guild
    mapping(address => address) public guildGovernors;

    /// @notice Deployed timelocks by guild
    mapping(address => address) public guildTimelocks;

    /// @notice Default governance parameters
    uint48 public defaultVotingDelay = 1; // 1 block (~2 seconds on Base)
    uint32 public defaultVotingPeriod = 50_400; // ~1 week at 12s blocks
    uint256 public defaultProposalThreshold = 100; // 100 XP to propose
    uint256 public defaultQuorum = 10; // 10% quorum
    uint256 public defaultTimelockDelay = 1 days;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event GovernanceDeployed(
        address indexed guild,
        address indexed governor,
        address indexed timelock
    );

    event DefaultsUpdated(
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorum,
        uint256 timelockDelay
    );

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

    /**
     * @notice Deploy the factory
     * @param _xpContract Address of the XP tracking contract
     */
    constructor(address _xpContract) Ownable(msg.sender) {
        if (_xpContract == address(0)) revert InvalidXPContract();
        xpContract = _xpContract;
    }

    // =============================================================================
    // DEPLOYMENT
    // =============================================================================

    /**
     * @notice Deploy governance for a guild with default parameters
     * @param guildDAO Address of the GuildDAO contract
     * @return governor Address of deployed GuildGovernor
     * @return timelock Address of deployed GuildTimelock
     */
    function deployGovernance(address guildDAO) external returns (address governor, address timelock) {
        return deployGovernanceWithParams(
            guildDAO,
            defaultVotingDelay,
            defaultVotingPeriod,
            defaultProposalThreshold,
            defaultQuorum,
            defaultTimelockDelay
        );
    }

    /**
     * @notice Deploy governance for a guild with custom parameters
     * @param guildDAO Address of the GuildDAO contract
     * @param votingDelay Delay before voting starts (blocks)
     * @param votingPeriod Duration of voting (blocks)
     * @param proposalThreshold Minimum XP to propose
     * @param quorumPercent Quorum percentage (0-100)
     * @param timelockDelay Delay before execution (seconds)
     * @return governor Address of deployed GuildGovernor
     * @return timelock Address of deployed GuildTimelock
     */
    function deployGovernanceWithParams(
        address guildDAO,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumPercent,
        uint256 timelockDelay
    ) public returns (address governor, address timelock) {
        if (guildGovernors[guildDAO] != address(0)) revert GovernanceAlreadyDeployed();
        if (quorumPercent > 100) revert InvalidParameters();

        // Deploy timelock first (governor will be proposer)
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // Anyone can execute after delay

        GuildTimelock timelockContract = new GuildTimelock(
            timelockDelay,
            proposers, // Will be updated after governor deployment
            executors,
            address(this), // Temporary admin
            guildDAO
        );
        timelock = address(timelockContract);

        // Deploy governor
        GuildGovernor governorContract = new GuildGovernor(
            guildDAO,
            TimelockController(payable(timelock)),
            xpContract,
            votingDelay,
            votingPeriod,
            proposalThreshold,
            quorumPercent
        );
        governor = address(governorContract);

        // Store references first (checks-effects-interactions)
        guildGovernors[guildDAO] = governor;
        guildTimelocks[guildDAO] = timelock;

        // Grant proposer role to governor
        timelockContract.grantRole(timelockContract.PROPOSER_ROLE(), governor);
        timelockContract.grantRole(timelockContract.CANCELLER_ROLE(), governor);

        // Renounce admin role (timelock becomes self-governed)
        timelockContract.renounceRole(timelockContract.DEFAULT_ADMIN_ROLE(), address(this));

        emit GovernanceDeployed(guildDAO, governor, timelock);

        return (governor, timelock);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Update default governance parameters
     */
    function setDefaults(
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorum,
        uint256 timelockDelay
    ) external onlyOwner {
        if (quorum > 100) revert InvalidParameters();
        
        defaultVotingDelay = votingDelay;
        defaultVotingPeriod = votingPeriod;
        defaultProposalThreshold = proposalThreshold;
        defaultQuorum = quorum;
        defaultTimelockDelay = timelockDelay;

        emit DefaultsUpdated(votingDelay, votingPeriod, proposalThreshold, quorum, timelockDelay);
    }

    /**
     * @notice Update XP contract address
     */
    function setXPContract(address newXPContract) external onlyOwner {
        if (newXPContract == address(0)) revert InvalidXPContract();
        address oldContract = xpContract;
        xpContract = newXPContract;
        emit XPContractUpdated(oldContract, newXPContract);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Check if a guild has governance deployed
     */
    function hasGovernance(address guildDAO) external view returns (bool) {
        return guildGovernors[guildDAO] != address(0);
    }

    /**
     * @notice Get governance addresses for a guild
     */
    function getGovernance(address guildDAO) external view returns (address governor, address timelock) {
        return (guildGovernors[guildDAO], guildTimelocks[guildDAO]);
    }

    /**
     * @notice Get default parameters
     */
    function getDefaults()
        external
        view
        returns (
            uint48 votingDelay,
            uint32 votingPeriod,
            uint256 proposalThreshold,
            uint256 quorum,
            uint256 timelockDelay
        )
    {
        return (
            defaultVotingDelay,
            defaultVotingPeriod,
            defaultProposalThreshold,
            defaultQuorum,
            defaultTimelockDelay
        );
    }
}
