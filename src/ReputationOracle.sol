// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IReputationOracle} from "./interfaces/IReputationOracle.sol";

/**
 * @title ReputationOracle
 * @notice On-chain reputation score storage for guild-scoped and global reputation
 * @dev Follows the same relayer pattern as GuildXP.sol.
 *      Scores are computed off-chain (composite index) and pushed here by an
 *      authorized RELAYER_ROLE address. MissionEscrow reads scores for gating.
 *
 *      Score range: 0-1000 (enforced on write)
 *
 *      Tier thresholds:
 *        0 = Newcomer  (0-199)
 *        1 = Bronze    (200-399)
 *        2 = Silver    (400-599)
 *        3 = Gold      (600-799)
 *        4 = Diamond   (800-1000)
 */
contract ReputationOracle is AccessControl, IReputationOracle {
    // =========================================================================
    // CONSTANTS
    // =========================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    uint256 public constant MAX_SCORE = 1000;

    uint256 public constant BRONZE_THRESHOLD = 200;
    uint256 public constant SILVER_THRESHOLD = 400;
    uint256 public constant GOLD_THRESHOLD = 600;
    uint256 public constant DIAMOND_THRESHOLD = 800;

    // =========================================================================
    // STATE
    // =========================================================================

    /// @notice Per-guild scores: user => guild => score
    mapping(address => mapping(address => uint256)) public guildScores;

    /// @notice Global scores: user => score
    mapping(address => uint256) public globalScores;

    /// @notice Pause state for emergency
    bool public paused;

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier whenNotPaused() {
        require(!paused, "ReputationOracle: paused");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @param admin     Address that receives DEFAULT_ADMIN_ROLE + ADMIN_ROLE
     * @param relayer   Initial relayer (backend service wallet)
     */
    constructor(address admin, address relayer) {
        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        if (relayer != address(0)) {
            _grantRole(RELAYER_ROLE, relayer);
        }
    }

    // =========================================================================
    // WRITE — RELAYER_ROLE
    // =========================================================================

    /// @inheritdoc IReputationOracle
    function updateScore(
        address user,
        address guild,
        uint256 score
    ) external override whenNotPaused onlyRole(RELAYER_ROLE) {
        if (score > MAX_SCORE) revert ScoreOutOfRange(score);

        uint256 oldScore = guildScores[user][guild];
        if (oldScore == score) return;

        guildScores[user][guild] = score;
        emit ScoreUpdated(user, guild, oldScore, score);
    }

    /// @inheritdoc IReputationOracle
    function updateGlobalScore(
        address user,
        uint256 score
    ) external override whenNotPaused onlyRole(RELAYER_ROLE) {
        if (score > MAX_SCORE) revert ScoreOutOfRange(score);

        uint256 oldScore = globalScores[user];
        if (oldScore == score) return;

        globalScores[user] = score;
        emit GlobalScoreUpdated(user, oldScore, score);
    }

    /// @inheritdoc IReputationOracle
    function batchUpdateScores(
        address[] calldata users,
        address guild,
        uint256[] calldata scores
    ) external override whenNotPaused onlyRole(RELAYER_ROLE) {
        if (users.length != scores.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < users.length; i++) {
            if (scores[i] > MAX_SCORE) revert ScoreOutOfRange(scores[i]);

            uint256 oldScore = guildScores[users[i]][guild];
            if (oldScore == scores[i]) continue;

            guildScores[users[i]][guild] = scores[i];
            emit ScoreUpdated(users[i], guild, oldScore, scores[i]);
        }

        emit BatchScoresUpdated(guild, users.length);
    }

    // =========================================================================
    // VIEW
    // =========================================================================

    /// @inheritdoc IReputationOracle
    function getScore(
        address user,
        address guild
    ) external view override returns (uint256) {
        return guildScores[user][guild];
    }

    /// @inheritdoc IReputationOracle
    function getGlobalScore(
        address user
    ) external view override returns (uint256) {
        return globalScores[user];
    }

    /// @inheritdoc IReputationOracle
    function getTier(uint256 score) external pure override returns (uint8) {
        return _deriveTier(score);
    }

    /// @inheritdoc IReputationOracle
    function getScoreWithTier(
        address user,
        address guild
    ) external view override returns (uint256 score, uint8 tier) {
        score = guildScores[user][guild];
        tier = _deriveTier(score);
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    /// @notice Pause all score updates (emergency)
    function pause() external onlyRole(ADMIN_ROLE) {
        paused = true;
    }

    /// @notice Unpause score updates
    function unpause() external onlyRole(ADMIN_ROLE) {
        paused = false;
    }

    /// @notice Add a new relayer address
    function addRelayer(address relayer) external onlyRole(ADMIN_ROLE) {
        _grantRole(RELAYER_ROLE, relayer);
    }

    /// @notice Remove a relayer address
    function removeRelayer(address relayer) external onlyRole(ADMIN_ROLE) {
        _revokeRole(RELAYER_ROLE, relayer);
    }

    // =========================================================================
    // INTERNAL
    // =========================================================================

    function _deriveTier(uint256 score) internal pure returns (uint8) {
        if (score >= DIAMOND_THRESHOLD) return 4; // Diamond
        if (score >= GOLD_THRESHOLD) return 3;    // Gold
        if (score >= SILVER_THRESHOLD) return 2;  // Silver
        if (score >= BRONZE_THRESHOLD) return 1;  // Bronze
        return 0;                                  // Newcomer
    }
}
