// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDisputeResolver
 * @notice Interface for the dispute resolution system
 * @dev Implements DDR (Dynamic Dispute Reserve) and LPP (Loser-Pays Penalty)
 */
interface IDisputeResolver {
    // =============================================================================
    // ENUMS
    // =============================================================================

    enum DisputeState {
        None,
        Pending, // Dispute raised, awaiting resolver assignment
        Investigating, // Resolver assigned, collecting evidence
        Resolved, // Resolution reached
        Appealed, // Resolution appealed to DAO
        Finalized // Final resolution, funds distributed
    }

    enum DisputeOutcome {
        None,
        PosterWins, // Performer failed to deliver
        PerformerWins, // Performer completed correctly
        Split, // Partial fault on both sides
        Cancelled // Dispute withdrawn or voided
    }

    // =============================================================================
    // STRUCTS
    // =============================================================================

    struct Dispute {
        uint256 disputeId;
        address escrowAddress;
        uint256 missionId;
        address poster;
        address performer;
        address initiator; // Who raised the dispute
        DisputeState state;
        DisputeOutcome outcome;
        address resolver; // Assigned resolver
        uint256 ddrAmount; // DDR deposited
        uint256 lppAmount; // LPP penalty amount
        bytes32 posterEvidenceHash;
        bytes32 performerEvidenceHash;
        bytes32 resolutionHash; // Hash of resolution details
        uint256 createdAt;
        uint256 resolvedAt;
        uint256 appealDeadline;
    }

    // =============================================================================
    // EVENTS
    // =============================================================================

    event DisputeCreated(
        uint256 indexed disputeId,
        address indexed escrowAddress,
        uint256 indexed missionId,
        address initiator,
        uint256 ddrAmount
    );

    event ResolverAssigned(uint256 indexed disputeId, address indexed resolver);

    event EvidenceSubmitted(
        uint256 indexed disputeId, address indexed submitter, bytes32 evidenceHash
    );

    event DisputeResolved(
        uint256 indexed disputeId, DisputeOutcome outcome, bytes32 resolutionHash
    );

    event DisputeAppealed(uint256 indexed disputeId, address indexed appellant);

    event DisputeFinalized(
        uint256 indexed disputeId,
        DisputeOutcome outcome,
        uint256 posterPayout,
        uint256 performerPayout,
        uint256 resolverFee,
        uint256 protocolFee
    );

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidDisputeState();
    error NotParty();
    error NotResolver();
    error NotDAO();
    error DisputeNotFound();
    error InsufficientDDR();
    error AppealPeriodActive();
    error AppealPeriodEnded();
    error ResolverAlreadyAssigned();
    error EvidenceAlreadySubmitted();
    error InvalidOutcome();

    // =============================================================================
    // FUNCTIONS
    // =============================================================================

    /// @notice Create a new dispute for a mission
    function createDispute(address escrowAddress, uint256 missionId, bytes32 evidenceHash)
        external
        returns (uint256 disputeId);

    /// @notice Assign a resolver to a dispute (called by ResolversDAO)
    function assignResolver(uint256 disputeId, address resolver) external;

    /// @notice Submit evidence for a dispute (poster or performer)
    function submitEvidence(uint256 disputeId, bytes32 evidenceHash) external;

    /// @notice Resolve a dispute (called by assigned resolver)
    function resolveDispute(
        uint256 disputeId,
        DisputeOutcome outcome,
        bytes32 resolutionHash,
        uint256 splitPercentage // 0-100, percentage for performer (only used for Split outcome)
    ) external;

    /// @notice Appeal a resolution to the DAO
    function appealResolution(uint256 disputeId) external;

    /// @notice Finalize dispute and distribute funds
    function finalizeDispute(uint256 disputeId) external;

    /// @notice Override resolution (only DAO)
    function overrideResolution(
        uint256 disputeId,
        DisputeOutcome newOutcome,
        bytes32 resolutionHash,
        uint256 splitPercentage
    ) external;

    // View functions
    function getDispute(uint256 disputeId) external view returns (Dispute memory);
    function getDisputesByMission(uint256 missionId) external view returns (uint256[] memory);
    function getDDRRate() external view returns (uint256);
    function getLPPRate() external view returns (uint256);
    function getAppealPeriod() external view returns (uint256);
}

