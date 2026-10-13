// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GuildGovernorSimple} from "./GuildGovernorSimple.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal view of GuildDAO used to authorise governance deployment.
interface IGuildAdminCheckSimple {
    function isAdmin(address account) external view returns (bool);
}

/**
 * @title GuildGovernorFactorySimple
 * @notice Factory for deploying simplified GuildGovernor contracts (no timelock)
 * @dev Ideal for testnet deployment where contract size limits are an issue
 *
 *      Audit M7: deployment writes a ONE-SHOT mapping entry per guild, so it is gated to
 *      the factory owner or the guild's own admin and quorum is floored above zero.
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

    /// @notice Hard floor on quorum so a governor can never be deployed with 0% quorum.
    uint256 public constant MIN_QUORUM_PERCENT = 4;

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
    /// @notice Caller is neither the factory owner nor an admin of the target guild.
    error NotGuildAdmin();

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
        _requireGuildAuthorised(guildDAO);
        if (guildGovernors[guildDAO] != address(0)) revert GovernanceAlreadyDeployed();
        if (quorumPercent > 100 || quorumPercent < MIN_QUORUM_PERCENT) revert InvalidParameters();
        if (votingPeriod == 0) revert InvalidParameters();

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
    // INTERNAL
    // =============================================================================

    /**
     * @notice Revert unless the caller may claim `guildDAO`'s one-shot governance slot.
     * @dev Allowed: the factory owner, or an ADMIN_ROLE holder on the GuildDAO itself.
     */
    function _requireGuildAuthorised(address guildDAO) internal view {
        if (guildDAO == address(0)) revert InvalidParameters();
        if (msg.sender == owner()) return;

        try IGuildAdminCheckSimple(guildDAO).isAdmin(msg.sender) returns (bool ok) {
            if (ok) return;
        } catch {
            // Fall through to the revert below.
        }
        revert NotGuildAdmin();
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
        if (quorum > 100 || quorum < MIN_QUORUM_PERCENT) revert InvalidParameters();
        if (votingPeriod == 0) revert InvalidParameters();
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
