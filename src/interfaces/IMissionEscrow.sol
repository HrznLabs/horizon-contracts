// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IMissionEscrow
 * @notice Interface for individual mission escrow contracts
 */
interface IMissionEscrow {
    // =============================================================================
    // ENUMS
    // =============================================================================

    enum MissionState {
        None,
        Open,
        Accepted,
        Submitted,
        Completed,
        Cancelled,
        Disputed
    }

    // =============================================================================
    // STRUCTS
    // =============================================================================

    struct MissionParams {
        address poster;
        uint256 rewardAmount;
        uint256 createdAt;
        uint256 expiresAt;
        address guild;
        bytes32 metadataHash;
        bytes32 locationHash;
    }

    struct MissionRuntime {
        address performer;
        MissionState state;
        bytes32 proofHash;
        bool disputeRaised;
    }

    // =============================================================================
    // EVENTS
    // =============================================================================

    event MissionAccepted(uint256 indexed id, address indexed performer);
    event MissionSubmitted(uint256 indexed id, bytes32 proofHash);
    event MissionCompleted(uint256 indexed id);
    event MissionCancelled(uint256 indexed id);
    event MissionDisputed(uint256 indexed id, address indexed by, bytes32 disputeHash);
    event DisputeSettled(
        uint256 indexed id, uint8 outcome, uint256 posterAmount, uint256 performerAmount
    );

    event ReputationUpdateFailed(uint256 indexed id);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidState();
    error NotPoster();
    error NotPerformer();
    error NotParty();
    error NotDisputeResolver();
    error MissionExpired();
    error MissionNotExpired();
    error AlreadyAccepted();
    error DisputeAlreadyRaised();

    // =============================================================================
    // FUNCTIONS
    // =============================================================================

    function initialize(
        uint96 missionId,
        address poster,
        uint96 rewardAmount,
        uint64 expiresAt,
        address guild,
        bytes32 metadataHash,
        bytes32 locationHash,
        address paymentRouter,
        address usdc,
        address disputeResolver,
        address reputationAttestations
    ) external;

    function acceptMission() external;
    function submitProof(bytes32 proofHash) external;
    function approveCompletion() external;
    function cancelMission() external;
    function raiseDispute(bytes32 disputeHash) external;
    function claimExpired() external;

    /// @notice Settle escrow based on dispute outcome (called by DisputeResolver)
    /// @param outcome 0=None, 1=PosterWins, 2=PerformerWins, 3=Split, 4=Cancelled
    /// @param splitPercentage For Split outcome, performer's share in basis points (0-10000)
    function settleDispute(uint8 outcome, uint256 splitPercentage) external;

    function getParams() external view returns (MissionParams memory);
    function getRuntime() external view returns (MissionRuntime memory);
    function getMissionId() external view returns (uint256);
    function getDisputeResolver() external view returns (address);
}
