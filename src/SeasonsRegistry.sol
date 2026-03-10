// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SeasonsRegistry
 * @notice On-chain record of Horizon protocol seasons (competitive epochs).
 * @dev Simple admin-managed registry. Seasons must not overlap. Sequential IDs enforced.
 */
contract SeasonsRegistry is Ownable {

    // =============================================================================
    // STRUCTS
    // =============================================================================

    struct Season {
        uint256 id;
        uint64  startTime;
        uint64  endTime;
        bool    active;
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    uint256 public seasonCount;
    mapping(uint256 => Season) public seasons;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event SeasonStarted(uint256 indexed seasonId, uint64 startTime, uint64 endTime);
    event SeasonEnded(uint256 indexed seasonId);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error SeasonNotFound();
    error InvalidSeasonId();
    error InvalidTimeRange();
    error SeasonOverlap();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor() Ownable(msg.sender) {}

    // =============================================================================
    // MUTATIVE FUNCTIONS
    // =============================================================================

    /**
     * @notice Start a new season.
     * @dev Season IDs must be sequential (next = seasonCount + 1).
     *      New season must not overlap with the previous season's endTime.
     * @param seasonId  The new season ID (must equal seasonCount + 1)
     * @param startTime Unix timestamp for season start
     * @param endTime   Unix timestamp for season end (must be > startTime)
     */
    function startSeason(uint256 seasonId, uint64 startTime, uint64 endTime) external onlyOwner {
        if (endTime <= startTime) revert InvalidTimeRange();
        if (seasonId != seasonCount + 1) revert InvalidSeasonId();
        if (seasonCount > 0 && startTime < seasons[seasonCount].endTime) revert SeasonOverlap();

        seasonCount = seasonId;
        seasons[seasonId] = Season({ id: seasonId, startTime: startTime, endTime: endTime, active: true });
        emit SeasonStarted(seasonId, startTime, endTime);
    }

    /**
     * @notice End an active season early, setting endTime to block.timestamp.
     * @param seasonId The season ID to end
     */
    function endSeason(uint256 seasonId) external onlyOwner {
        if (seasons[seasonId].id == 0) revert SeasonNotFound();
        seasons[seasonId].active = false;
        seasons[seasonId].endTime = uint64(block.timestamp);
        emit SeasonEnded(seasonId);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Returns the currently active season, or an empty Season (id=0) if none is active.
     * @dev Iterates from most recent season backwards for efficiency.
     */
    function getCurrentSeason() external view returns (Season memory) {
        for (uint256 i = seasonCount; i >= 1; i--) {
            Season storage s = seasons[i];
            if (s.active && block.timestamp >= s.startTime && block.timestamp < s.endTime) return s;
            if (i == 0) break;
        }
        return Season({ id: 0, startTime: 0, endTime: 0, active: false });
    }

    /**
     * @notice Returns the season that contains a given timestamp, or an empty Season (id=0).
     * @param ts The unix timestamp to look up
     */
    function getSeasonForTimestamp(uint64 ts) external view returns (Season memory) {
        for (uint256 i = seasonCount; i >= 1; i--) {
            Season storage s = seasons[i];
            if (ts >= s.startTime && ts < s.endTime) return s;
            if (i == 0) break;
        }
        return Season({ id: 0, startTime: 0, endTime: 0, active: false });
    }

    /**
     * @notice Returns the season with the given ID.
     * @param seasonId The season ID to look up
     */
    function getSeason(uint256 seasonId) external view returns (Season memory) {
        if (seasons[seasonId].id == 0) revert SeasonNotFound();
        return seasons[seasonId];
    }
}
