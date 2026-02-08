// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

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

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Mapping: missionId => rater => ratee => Rating
    mapping(uint256 => mapping(address => mapping(address => Rating))) public ratings;

    /// @notice Mapping: user => total ratings received
    mapping(address => uint256) public ratingCounts;

    /// @notice Mapping: user => sum of all ratings (for average calculation)
    mapping(address => uint256) public ratingSums;

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

        // Check if already rated
        if (ratings[missionId][msg.sender][ratee].score != 0) {
            revert AlreadyRated();
        }

        // Store rating
        ratings[missionId][msg.sender][ratee] =
            Rating({ score: score, commentHash: commentHash, timestamp: block.timestamp });

        // Update ratee's statistics
        ratingCounts[ratee]++;
        ratingSums[ratee] += score;

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
        // In production, verify caller is authorized MissionEscrow
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
     * @notice Get average rating for a user
     * @param user User address
     * @return average Average rating (multiplied by 100 for precision)
     * @return count Number of ratings
     */
    function getAverageRating(address user) external view returns (uint256 average, uint256 count) {
        count = ratingCounts[user];
        if (count == 0) return (0, 0);

        average = (ratingSums[user] * 100) / count;
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

