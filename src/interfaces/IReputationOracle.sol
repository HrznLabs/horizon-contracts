// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IReputationOracle
 * @notice Interface for on-chain reputation score storage
 * @dev Scores are pushed by a backend relayer (same pattern as GuildXP.sol).
 *      MissionEscrow reads scores to enforce reputation-based access gating.
 *
 *      Score range: 0-1000
 *      Tier thresholds:
 *        Newcomer  0-199
 *        Bronze    200-399
 *        Silver    400-599
 *        Gold      600-799
 *        Diamond   800-1000
 */
interface IReputationOracle {
    // =========================================================================
    // EVENTS
    // =========================================================================

    event ScoreUpdated(
        address indexed user,
        address indexed guild,
        uint256 oldScore,
        uint256 newScore
    );

    event GlobalScoreUpdated(
        address indexed user,
        uint256 oldScore,
        uint256 newScore
    );

    event BatchScoresUpdated(address indexed guild, uint256 usersUpdated);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error ScoreOutOfRange(uint256 score);
    error ArrayLengthMismatch();
    error ZeroAddress();

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    /// @notice Get a user's reputation score within a specific guild
    function getScore(address user, address guild) external view returns (uint256);

    /// @notice Get a user's global reputation score (aggregated across all guilds)
    function getGlobalScore(address user) external view returns (uint256);

    /// @notice Derive the tier enum from a raw score
    function getTier(uint256 score) external pure returns (uint8);

    /// @notice Convenience: score + tier in one call
    function getScoreWithTier(
        address user,
        address guild
    ) external view returns (uint256 score, uint8 tier);

    // =========================================================================
    // WRITE FUNCTIONS (RELAYER_ROLE only)
    // =========================================================================

    /// @notice Update a single user's per-guild score
    function updateScore(address user, address guild, uint256 score) external;

    /// @notice Update a single user's global score
    function updateGlobalScore(address user, uint256 score) external;

    /// @notice Gas-efficient batch update for a guild
    function batchUpdateScores(
        address[] calldata users,
        address guild,
        uint256[] calldata scores
    ) external;
}
