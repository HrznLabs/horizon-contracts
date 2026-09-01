// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GuildGovernor} from "./GuildGovernor.sol";
import {GuildTimelock} from "./GuildTimelock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal view of GuildDAO used to authorise governance deployment.
interface IGuildAdminCheck {
    function isAdmin(address account) external view returns (bool);
}

/**
 * @title GuildGovernorFactory
 * @notice Factory for deploying GuildGovernor and GuildTimelock contracts
 * @dev Deploys a matched pair of Governor + Timelock for each guild
 *
 *      Audit M7: `deployGovernance*` writes a ONE-SHOT mapping entry per guild. When it
 *      was permissionless, anybody could front-run a guild and permanently occupy its
 *      slot with adversarial parameters (quorum 0, zero timelock delay). Deployment is
 *      now gated to the factory owner or the guild's own admin, and the parameters are
 *      bounded by hard minimums.
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

    /// @notice Hard floor on quorum so a governor can never be deployed with 0% quorum.
    uint256 public constant MIN_QUORUM_PERCENT = 4;

    /// @notice Hard floor on the timelock delay so execution is never instant.
    uint256 public constant MIN_TIMELOCK_DELAY = 1 hours;

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
    /// @notice Caller is neither the factory owner nor an admin of the target guild.
    error NotGuildAdmin();

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
        _requireGuildAuthorised(guildDAO);
        if (guildGovernors[guildDAO] != address(0)) revert GovernanceAlreadyDeployed();
        if (quorumPercent > 100 || quorumPercent < MIN_QUORUM_PERCENT) revert InvalidParameters();
        if (timelockDelay < MIN_TIMELOCK_DELAY) revert InvalidParameters();
        if (votingPeriod == 0) revert InvalidParameters();

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
    // INTERNAL
    // =============================================================================

    /**
     * @notice Revert unless the caller may claim `guildDAO`'s one-shot governance slot.
     * @dev Allowed: the factory owner, or an ADMIN_ROLE holder on the GuildDAO itself.
     *      A guildDAO that does not implement `isAdmin` can only be deployed by the owner.
     */
    function _requireGuildAuthorised(address guildDAO) internal view {
        if (guildDAO == address(0)) revert InvalidParameters();
        if (msg.sender == owner()) return;

        try IGuildAdminCheck(guildDAO).isAdmin(msg.sender) returns (bool ok) {
            if (ok) return;
        } catch {
            // Fall through to the revert below.
        }
        revert NotGuildAdmin();
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
        if (quorum > 100 || quorum < MIN_QUORUM_PERCENT) revert InvalidParameters();
        if (timelockDelay < MIN_TIMELOCK_DELAY) revert InvalidParameters();
        if (votingPeriod == 0) revert InvalidParameters();

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
