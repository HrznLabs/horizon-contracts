// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IMissionFactory } from "./interfaces/IMissionFactory.sol";
import { IMissionEscrow } from "./interfaces/IMissionEscrow.sol";

/**
 * @title ReputationAttestations
 * @notice On-chain reputation and rating storage
 * @dev Emits events for Horizon Service indexing
 *
 * Ratings are stored on-chain for transparency and immutability.
 * The actual reputation calculation is done off-chain by Horizon Service.
 */
contract ReputationAttestations is Ownable {
    // =============================================================================
    // STRUCTS
    // =============================================================================

    struct Rating {
        uint8 score; // 1-5
        bytes32 commentHash; // IPFS hash of comment
        uint256 timestamp;
    }

    struct RatingStats {
        uint128 count;
        uint128 sum;
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Mapping: missionId => rater => ratee => Rating
    mapping(uint256 => mapping(address => mapping(address => Rating))) public ratings;

    /// @notice Mapping: user => rating stats (count and sum packed)
    mapping(address => RatingStats) private _ratingStats;

    /// @notice Authorized mission escrow contracts
    mapping(address => bool) public authorizedContracts;

    /// @notice MissionFactory address
    address public missionFactory;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event RatingSubmitted(
        uint256 indexed missionId,
        address indexed rater,
        address indexed ratee,
        uint8 score,
        bytes32 commentHash
    );

    event MissionOutcomeRecorded(
        uint256 indexed missionId,
        address indexed poster,
        address indexed performer,
        bool completed,
        uint256 rewardAmount
    );

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidScore();
    error AlreadyRated();
    error SelfRating();
    error NotAuthorized();
    error MissionNotCompleted();
    error NotParticipant();
    error InvalidCounterparty();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor() Ownable(msg.sender) { }

    // =============================================================================
    // RATING FUNCTIONS
    // =============================================================================

    /**
     * @notice Submit a rating for a mission participant
     * @param missionId The mission ID
     * @param ratee The address being rated
     * @param score Rating score (1-5)
     * @param commentHash IPFS hash of rating comment
     */
    function submitRating(uint256 missionId, address ratee, uint8 score, bytes32 commentHash)
        external
    {
        if (score < 1 || score > 5) revert InvalidScore();
        if (msg.sender == ratee) revert SelfRating();

        // Validate mission and participation
        if (missionFactory == address(0)) revert NotAuthorized();

        address escrow = IMissionFactory(missionFactory).getMission(missionId);
        IMissionEscrow mission = IMissionEscrow(escrow);

        // Check if mission is completed
        IMissionEscrow.MissionRuntime memory runtime = mission.getRuntime();
        if (runtime.state != IMissionEscrow.MissionState.Completed) {
            revert MissionNotCompleted();
        }

        // Check if rater is a participant
        IMissionEscrow.MissionParams memory params = mission.getParams();

        bool isPoster = msg.sender == params.poster;
        bool isPerformer = msg.sender == runtime.performer;

        if (!isPoster && !isPerformer) revert NotParticipant();

        // Check if ratee is the counterparty
        if (isPoster && ratee != runtime.performer) revert InvalidCounterparty();
        if (isPerformer && ratee != params.poster) revert InvalidCounterparty();

        // Check if already rated
        if (ratings[missionId][msg.sender][ratee].score != 0) {
            revert AlreadyRated();
        }

        // Store rating
        ratings[missionId][msg.sender][ratee] =
            Rating({ score: score, commentHash: commentHash, timestamp: block.timestamp });

        // Update ratee's statistics
        RatingStats memory stats = _ratingStats[ratee];
        stats.count++;
        stats.sum += score;
        _ratingStats[ratee] = stats;

        emit RatingSubmitted(missionId, msg.sender, ratee, score, commentHash);
    }

    /**
     * @notice Record mission outcome (called by MissionEscrow)
     * @param missionId The mission ID
     * @param poster Poster address
     * @param performer Performer address
     * @param completed Whether mission was completed successfully
     * @param rewardAmount The reward amount
     */
    function recordOutcome(
        uint256 missionId,
        address poster,
        address performer,
        bool completed,
        uint256 rewardAmount
    ) external {
        if (missionFactory == address(0)) revert NotAuthorized();
        if (msg.sender != IMissionFactory(missionFactory).getMission(missionId)) {
            revert NotAuthorized();
        }

        emit MissionOutcomeRecorded(missionId, poster, performer, completed, rewardAmount);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Get rating for a specific mission/rater/ratee combination
     */
    function getRating(uint256 missionId, address rater, address ratee)
        external
        view
        returns (Rating memory)
    {
        return ratings[missionId][rater][ratee];
    }

    /**
     * @notice Get total ratings received by a user
     * @param user User address
     * @return Total number of ratings
     */
    function ratingCounts(address user) external view returns (uint256) {
        return _ratingStats[user].count;
    }

    /**
     * @notice Get sum of all ratings received by a user
     * @param user User address
     * @return Sum of ratings
     */
    function ratingSums(address user) external view returns (uint256) {
        return _ratingStats[user].sum;
    }

    /**
     * @notice Get average rating for a user
     * @param user User address
     * @return average Average rating (multiplied by 100 for precision)
     * @return count Number of ratings
     */
    function getAverageRating(address user) external view returns (uint256 average, uint256 count) {
        RatingStats memory stats = _ratingStats[user];
        count = stats.count;
        if (count == 0) return (0, 0);

        average = (uint256(stats.sum) * 100) / count;
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Set mission factory address
     */
    function setMissionFactory(address _factory) external onlyOwner {
        missionFactory = _factory;
    }

    /**
     * @notice Authorize a contract to record outcomes
     */
    function authorizeContract(address _contract) external onlyOwner {
        authorizedContracts[_contract] = true;
    }

    /**
     * @notice Revoke authorization from a contract
     */
    function revokeAuthorization(address _contract) external onlyOwner {
        authorizedContracts[_contract] = false;
    }
}

