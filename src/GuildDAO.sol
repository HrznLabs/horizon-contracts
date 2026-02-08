// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title GuildDAO
 * @notice Guild governance contract for mission curation and member management
 * @dev Deployed as minimal proxy for gas efficiency
 *
 * Guild Roles:
 * - Admin: Full control over guild configuration
 * - Officer: Can update eligibility schemas
 * - Curator: Can publish missions to Guild Board
 * - Member: Basic guild membership
 */
contract GuildDAO is Initializable, AccessControlUpgradeable {
    // =============================================================================
    // ROLES
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER_ROLE");
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");

    // =============================================================================
    // STRUCTS
    // =============================================================================

    struct GuildConfig {
        string name;
        address admin;
        address treasury;
        uint16 guildFeeBps;
    }

    struct GuildMember {
        bool isMember;
        uint256 joinedAt;
        uint256 leftAt;
    }

    struct GuildEligibilitySchema {
        uint256 minGuildXP;
        uint256 minGlobalXP;
        uint256 minReputation;
        bytes32 requiredBadge;
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    GuildConfig public config;
    GuildEligibilitySchema public defaultEligibility;

    mapping(address => GuildMember) public members;
    uint256 public memberCount;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event GuildMemberAdded(address indexed guild, address indexed member);
    event GuildMemberRemoved(address indexed guild, address indexed member);
    event GuildRoleGranted(address indexed guild, address indexed member, string role);
    event GuildConfigUpdated(address indexed guild);
    event GuildBoardEntryAdded(
        address indexed guild, uint256 indexed missionId, address indexed curator
    );

    // =============================================================================
    // ERRORS
    // =============================================================================

    error AlreadyMember();
    error NotMember();
    error InvalidFee();

    // =============================================================================
    // INITIALIZATION
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the guild with configuration
     * @param name Guild name
     * @param admin Guild admin address
     * @param treasury Guild treasury address
     * @param guildFeeBps Guild fee in basis points
     */
    function initialize(string calldata name, address admin, address treasury, uint16 guildFeeBps)
        external
        initializer
    {
        __AccessControl_init();

        if (guildFeeBps > 1000) revert InvalidFee(); // Max 10%

        config =
            GuildConfig({ name: name, admin: admin, treasury: treasury, guildFeeBps: guildFeeBps });

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(OFFICER_ROLE, admin);
        _grantRole(CURATOR_ROLE, admin);

        // Add admin as first member
        _addMember(admin);
    }

    // =============================================================================
    // MEMBER MANAGEMENT
    // =============================================================================

    /**
     * @notice Add a new member to the guild
     * @param member Address to add
     */
    function addMember(address member) external onlyRole(OFFICER_ROLE) {
        _addMember(member);
    }

    function _addMember(address member) internal {
        if (members[member].isMember) revert AlreadyMember();

        members[member] = GuildMember({ isMember: true, joinedAt: block.timestamp, leftAt: 0 });

        memberCount++;
        emit GuildMemberAdded(address(this), member);
    }

    /**
     * @notice Remove a member from the guild
     * @param member Address to remove
     */
    function removeMember(address member) external onlyRole(OFFICER_ROLE) {
        if (!members[member].isMember) revert NotMember();

        members[member].isMember = false;
        members[member].leftAt = block.timestamp;

        memberCount--;
        emit GuildMemberRemoved(address(this), member);
    }

    /**
     * @notice Grant curator role to a member
     * @param member Address to grant role
     */
    function grantCuratorRole(address member) external onlyRole(ADMIN_ROLE) {
        if (!members[member].isMember) revert NotMember();
        _grantRole(CURATOR_ROLE, member);
        emit GuildRoleGranted(address(this), member, "curator");
    }

    /**
     * @notice Grant officer role to a member
     * @param member Address to grant role
     */
    function grantOfficerRole(address member) external onlyRole(ADMIN_ROLE) {
        if (!members[member].isMember) revert NotMember();
        _grantRole(OFFICER_ROLE, member);
        emit GuildRoleGranted(address(this), member, "officer");
    }

    // =============================================================================
    // GUILD BOARD
    // =============================================================================

    /**
     * @notice Publish a mission to the guild board
     * @param missionId The mission ID to publish
     * @dev Emits event for Horizon Service to index
     */
    function publishToBoard(uint256 missionId) external onlyRole(CURATOR_ROLE) {
        emit GuildBoardEntryAdded(address(this), missionId, msg.sender);
    }

    // =============================================================================
    // CONFIGURATION
    // =============================================================================

    /**
     * @notice Update guild configuration
     * @param name New guild name
     * @param treasury New treasury address
     * @param guildFeeBps New fee in basis points
     */
    function updateConfig(string calldata name, address treasury, uint16 guildFeeBps)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (guildFeeBps > 1000) revert InvalidFee();

        config.name = name;
        config.treasury = treasury;
        config.guildFeeBps = guildFeeBps;

        emit GuildConfigUpdated(address(this));
    }

    /**
     * @notice Update default eligibility schema
     * @param minGuildXP Minimum guild XP required
     * @param minGlobalXP Minimum global XP required
     * @param minReputation Minimum reputation required
     * @param requiredBadge Required badge hash
     */
    function updateEligibility(
        uint256 minGuildXP,
        uint256 minGlobalXP,
        uint256 minReputation,
        bytes32 requiredBadge
    ) external onlyRole(OFFICER_ROLE) {
        defaultEligibility = GuildEligibilitySchema({
            minGuildXP: minGuildXP,
            minGlobalXP: minGlobalXP,
            minReputation: minReputation,
            requiredBadge: requiredBadge
        });

        emit GuildConfigUpdated(address(this));
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    function isMember(address account) external view returns (bool) {
        return members[account].isMember;
    }

    function isCurator(address account) external view returns (bool) {
        return hasRole(CURATOR_ROLE, account);
    }

    function isOfficer(address account) external view returns (bool) {
        return hasRole(OFFICER_ROLE, account);
    }

    function isAdmin(address account) external view returns (bool) {
        return hasRole(ADMIN_ROLE, account);
    }

    function getConfig() external view returns (GuildConfig memory) {
        return config;
    }

    function getDefaultEligibility() external view returns (GuildEligibilitySchema memory) {
        return defaultEligibility;
    }
}

