// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title GuildXP
 * @notice On-chain XP tracking for Guild governance voting power
 * @dev Synced from off-chain database via CDP Server Wallets
 *
 * Architecture:
 * - Each guild can have its own relayer (guild admin's CDP wallet)
 * - Global relayer can update any guild (for protocol-level operations)
 * - Governor reads XP for voting power calculations
 *
 * Roles:
 * - ADMIN_ROLE: Can manage global relayers, pause, and set guild admins
 * - RELAYER_ROLE: Can update XP for ANY guild (global relayer)
 * - Guild admins can update XP for their specific guild only
 *
 * Snapshot safety (audit H6):
 * - Every guild XP write is also checkpointed per block (OZ `Checkpoints.Trace208`),
 *   both per (guild, user) and for the guild total.
 * - `getPastGuildXP` / `getPastTotalGuildXP` return the value as of the end of a past
 *   block. GuildGovernor reads voting power and quorum through these at the proposal's
 *   snapshot timepoint, so XP written after a proposal snapshot (by a relayer, a guild
 *   admin or a compromised key) cannot change the weight or the quorum of an open vote.
 * - Clock is `block.number`, matching GuildGovernor's IERC6372 clock.
 */
contract GuildXP is AccessControl {
    using Checkpoints for Checkpoints.Trace208;
    // =============================================================================
    // ROLES
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // =============================================================================
    // STATE
    // =============================================================================

    /// @notice Guild XP: guild => user => xp
    mapping(address => mapping(address => uint256)) public guildXP;

    /// @notice Total XP per guild: guild => totalXP
    mapping(address => uint256) public totalGuildXP;

    /// @notice Global XP per user (across all guilds): user => globalXP
    mapping(address => uint256) public globalXP;

    /// @notice Total global XP across all users
    uint256 public totalGlobalXP;

    /// @notice Guild-specific relayers: guild => relayer => authorized
    mapping(address => mapping(address => bool)) public guildRelayers;

    /// @notice Guild admin who can manage guild relayers: guild => admin
    mapping(address => address) public guildAdmins;

    /// @notice Pause state for emergency
    bool public paused;

    /// @dev Audit H6: per-block history of guild XP: guild => user => checkpoints
    mapping(address => mapping(address => Checkpoints.Trace208)) private _guildXPCheckpoints;

    /// @dev Audit H6: per-block history of total guild XP: guild => checkpoints
    mapping(address => Checkpoints.Trace208) private _totalGuildXPCheckpoints;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event XPUpdated(
        address indexed guild,
        address indexed user,
        uint256 oldXP,
        uint256 newXP
    );

    event GlobalXPUpdated(address indexed user, uint256 oldXP, uint256 newXP);

    event BatchXPUpdated(address indexed guild, uint256 usersUpdated);

    event GuildRelayerSet(address indexed guild, address indexed relayer, bool authorized);

    event GuildAdminSet(address indexed guild, address indexed admin);

    event Paused(address account);
    event Unpaused(address account);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error ContractPaused();
    error NotAuthorized();
    error ArrayLengthMismatch();
    error ZeroAddress();
    /// @notice Historical lookups must target a block that has already ended.
    error FutureLookup(uint256 timepoint, uint48 currentClock);

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /// @notice Check if caller can update XP for a guild
    modifier canUpdateGuild(address guild) {
        if (
            !hasRole(RELAYER_ROLE, msg.sender) && // Global relayer
            !guildRelayers[guild][msg.sender] && // Guild-specific relayer
            guildAdmins[guild] != msg.sender // Guild admin
        ) {
            revert NotAuthorized();
        }
        _;
    }

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /**
     * @notice Deploy GuildXP contract
     * @param admin Address with admin privileges
     * @param globalRelayer Initial global relayer (can update any guild)
     */
    constructor(address admin, address globalRelayer) {
        if (admin == address(0)) revert ZeroAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        
        if (globalRelayer != address(0)) {
            _grantRole(RELAYER_ROLE, globalRelayer);
        }
    }

    // =============================================================================
    // XP UPDATES
    // =============================================================================

    /**
     * @notice Update XP for a single user in a guild
     * @param guild Guild address
     * @param user User address
     * @param newXP New XP amount
     */
    function updateXP(
        address guild,
        address user,
        uint256 newXP
    ) external whenNotPaused canUpdateGuild(guild) {
        _updateXP(guild, user, newXP);
    }

    /**
     * @notice Batch update XP for multiple users in a guild
     * @param guild Guild address
     * @param users Array of user addresses
     * @param xpAmounts Array of XP amounts
     */
    function batchUpdateXP(
        address guild,
        address[] calldata users,
        uint256[] calldata xpAmounts
    ) external whenNotPaused canUpdateGuild(guild) {
        if (users.length != xpAmounts.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < users.length; i++) {
            _updateXP(guild, users[i], xpAmounts[i]);
        }

        emit BatchXPUpdated(guild, users.length);
    }

    /**
     * @notice Internal XP update logic
     */
    function _updateXP(address guild, address user, uint256 newXP) internal {
        uint256 oldXP = guildXP[guild][user];
        
        if (oldXP == newXP) return; // No change
        
        guildXP[guild][user] = newXP;

        // Update total guild XP
        uint256 newTotal;
        if (newXP > oldXP) {
            newTotal = totalGuildXP[guild] + (newXP - oldXP);
        } else {
            newTotal = totalGuildXP[guild] - (oldXP - newXP);
        }
        totalGuildXP[guild] = newTotal;

        // Audit H6: record history so governance can read XP as of a past block.
        uint48 key = clock();
        _guildXPCheckpoints[guild][user].push(key, SafeCast.toUint208(newXP));
        _totalGuildXPCheckpoints[guild].push(key, SafeCast.toUint208(newTotal));

        emit XPUpdated(guild, user, oldXP, newXP);
    }

    /**
     * @notice Update global XP for a user
     * @dev Only global relayers or admins can update global XP
     */
    function updateGlobalXP(
        address user,
        uint256 newXP
    ) external whenNotPaused onlyRole(RELAYER_ROLE) {
        uint256 oldXP = globalXP[user];
        
        if (oldXP == newXP) return;
        
        globalXP[user] = newXP;

        if (newXP > oldXP) {
            totalGlobalXP += (newXP - oldXP);
        } else {
            totalGlobalXP -= (oldXP - newXP);
        }

        emit GlobalXPUpdated(user, oldXP, newXP);
    }

    /**
     * @notice Batch update global XP
     */
    function batchUpdateGlobalXP(
        address[] calldata users,
        uint256[] calldata xpAmounts
    ) external whenNotPaused onlyRole(RELAYER_ROLE) {
        if (users.length != xpAmounts.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < users.length; i++) {
            uint256 oldXP = globalXP[users[i]];
            uint256 newXP = xpAmounts[i];
            
            if (oldXP == newXP) continue;
            
            globalXP[users[i]] = newXP;

            if (newXP > oldXP) {
                totalGlobalXP += (newXP - oldXP);
            } else {
                totalGlobalXP -= (oldXP - newXP);
            }

            emit GlobalXPUpdated(users[i], oldXP, newXP);
        }
    }

    // =============================================================================
    // VIEW FUNCTIONS (Called by Governor)
    // =============================================================================

    /**
     * @notice Get a user's XP for a specific guild
     */
    function getGuildXP(address guild, address account) external view returns (uint256) {
        return guildXP[guild][account];
    }

    /**
     * @notice Get total XP for a guild
     */
    function getTotalGuildXP(address guild) external view returns (uint256) {
        return totalGuildXP[guild];
    }

    /**
     * @notice A user's guild XP as of the end of block `timepoint` (audit H6).
     * @dev Reverts for the current or a future block, like OZ `Votes.getPastVotes`, so a
     *      value cannot be read before it is final.
     */
    function getPastGuildXP(
        address guild,
        address account,
        uint256 timepoint
    ) external view returns (uint256) {
        return _guildXPCheckpoints[guild][account].upperLookupRecent(_validateTimepoint(timepoint));
    }

    /**
     * @notice Total guild XP as of the end of block `timepoint` (audit H6).
     */
    function getPastTotalGuildXP(address guild, uint256 timepoint) external view returns (uint256) {
        return _totalGuildXPCheckpoints[guild].upperLookupRecent(_validateTimepoint(timepoint));
    }

    /// @notice IERC6372-style clock: block number (matches GuildGovernor).
    function clock() public view returns (uint48) {
        return SafeCast.toUint48(block.number);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function _validateTimepoint(uint256 timepoint) internal view returns (uint48) {
        uint48 currentClock = clock();
        if (timepoint >= currentClock) revert FutureLookup(timepoint, currentClock);
        return SafeCast.toUint48(timepoint);
    }

    /**
     * @notice Get a user's global XP
     */
    function getGlobalXP(address account) external view returns (uint256) {
        return globalXP[account];
    }

    /**
     * @notice Check if an address can update XP for a guild
     */
    function canUpdate(address guild, address account) external view returns (bool) {
        return hasRole(RELAYER_ROLE, account) ||
               guildRelayers[guild][account] ||
               guildAdmins[guild] == account;
    }

    // =============================================================================
    // GUILD ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Set guild admin (called by protocol admin or existing guild admin)
     * @param guild Guild address
     * @param admin New admin address
     */
    function setGuildAdmin(address guild, address admin) external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && guildAdmins[guild] != msg.sender) {
            revert NotAuthorized();
        }
        
        guildAdmins[guild] = admin;
        emit GuildAdminSet(guild, admin);
    }

    /**
     * @notice Set guild-specific relayer (called by guild admin)
     * @param guild Guild address
     * @param relayer Relayer address
     * @param authorized Whether to authorize or revoke
     */
    function setGuildRelayer(address guild, address relayer, bool authorized) external {
        if (guildAdmins[guild] != msg.sender && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        
        guildRelayers[guild][relayer] = authorized;
        emit GuildRelayerSet(guild, relayer, authorized);
    }

    // =============================================================================
    // PROTOCOL ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Pause XP updates (emergency)
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause XP updates
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Add a global relayer
     */
    function addGlobalRelayer(address relayer) external onlyRole(ADMIN_ROLE) {
        _grantRole(RELAYER_ROLE, relayer);
    }

    /**
     * @notice Remove a global relayer
     */
    function removeGlobalRelayer(address relayer) external onlyRole(ADMIN_ROLE) {
        _revokeRole(RELAYER_ROLE, relayer);
    }
}
