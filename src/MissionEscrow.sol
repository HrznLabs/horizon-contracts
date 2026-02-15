// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IMissionEscrow } from "./interfaces/IMissionEscrow.sol";
import { IPaymentRouter } from "./interfaces/IPaymentRouter.sol";

/**
 * @title MissionEscrow
 * @notice Individual escrow contract for each mission
 * @dev Deployed as minimal proxy (clone) for gas efficiency
 *
 * Mission Lifecycle:
 * 1. Open -> Performer can accept
 * 2. Accepted -> Performer working on mission
 * 3. Submitted -> Performer submitted proof, awaiting approval
 * 4. Completed -> Mission approved, payment settled
 * 5. Cancelled -> Mission cancelled by poster (if not accepted)
 * 6. Disputed -> Either party raised dispute
 */
contract MissionEscrow is Initializable, IMissionEscrow {
    using SafeERC20 for IERC20;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    // Slot 0: Poster + MissionId
    address private _poster; // 20
    uint96 private _missionId; // 12 (Packed perfectly: 20 + 12 = 32)

    // Slot 1: Guild + State + DisputeRaised + ExpiresAt
    address private _guild; // 20
    MissionState private _state; // 1
    bool private _disputeRaised; // 1
    uint64 private _expiresAt; // 8
    // 2 bytes gap

    // Slot 2: PaymentRouter + RewardAmount
    address private _paymentRouter; // 20
    uint96 private _rewardAmount; // 12
    // Packed perfectly (20 + 12 = 32)

    // Slot 3: USDC
    address private _usdc; // 20
    // 12 bytes gap

    // Slot 4: DisputeResolver
    address private _disputeResolver; // 20
    // 12 bytes gap

    // Slot 5: Performer + CreatedAt
    address private _performer; // 20
    uint64 private _createdAt; // 8
    // 4 bytes gap

    // Slot 6 Removed

    // Slot 7: MetadataHash
    bytes32 private _metadataHash; // 32

    // Slot 8: LocationHash
    bytes32 private _locationHash; // 32

    // Slot 9: ProofHash
    bytes32 private _proofHash; // 32

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier onlyPoster() {
        if (msg.sender != _poster) revert NotPoster();
        _;
    }

    modifier onlyPerformer() {
        if (msg.sender != _performer) revert NotPerformer();
        _;
    }

    modifier inState(MissionState state) {
        if (_state != state) revert InvalidState();
        _;
    }

    modifier notExpired() {
        if (block.timestamp > _expiresAt) revert MissionExpired();
        _;
    }

    // =============================================================================
    // INITIALIZATION
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the escrow with mission parameters
     * @dev Called by MissionFactory after clone deployment
     */
    function initialize(
        uint256 missionId,
        address poster,
        uint256 rewardAmount,
        uint256 expiresAt,
        address guild,
        bytes32 metadataHash,
        bytes32 locationHash,
        address paymentRouter,
        address usdc,
        address disputeResolver
    ) external initializer {
        if (expiresAt > type(uint64).max) revert MissionExpired();
        if (missionId > type(uint96).max) revert InvalidState();
        if (rewardAmount > type(uint96).max) revert InvalidState();

        _missionId = uint96(missionId);
        _poster = poster;

        _guild = guild;
        _state = MissionState.Open;
        _disputeRaised = false;
        _expiresAt = uint64(expiresAt);

        _paymentRouter = paymentRouter;
        _rewardAmount = uint96(rewardAmount);

        _usdc = usdc;
        _disputeResolver = disputeResolver;
        // _performer is 0

        _createdAt = uint64(block.timestamp);

        _metadataHash = metadataHash;
        _locationHash = locationHash;
        // _proofHash is 0
    }

    // =============================================================================
    // MISSION ACTIONS
    // =============================================================================

    /**
     * @notice Accept the mission as a performer
     * @dev Transitions from Open to Accepted
     */
    function acceptMission() external inState(MissionState.Open) notExpired {
        if (_performer != address(0)) revert AlreadyAccepted();

        _performer = msg.sender;
        _state = MissionState.Accepted;

        emit MissionAccepted(_missionId, msg.sender);
    }

    /**
     * @notice Submit proof of completion
     * @param proofHash IPFS hash of proof data
     * @dev Transitions from Accepted to Submitted
     */
    function submitProof(bytes32 proofHash)
        external
        onlyPerformer
        inState(MissionState.Accepted)
        notExpired
    {
        _proofHash = proofHash;
        _state = MissionState.Submitted;

        emit MissionSubmitted(_missionId, proofHash);
    }

    /**
     * @notice Approve mission completion and trigger payment
     * @dev Transitions from Submitted to Completed
     */
    function approveCompletion() external onlyPoster inState(MissionState.Submitted) {
        _state = MissionState.Completed;

        // Transfer USDC to PaymentRouter for distribution
        IERC20(_usdc).safeTransfer(_paymentRouter, _rewardAmount);

        // Settle payment through router
        IPaymentRouter(_paymentRouter).settlePayment(_missionId, _performer, _rewardAmount, _guild);

        emit MissionCompleted(_missionId);
    }

    /**
     * @notice Cancel mission and refund poster
     * @dev Only allowed if not yet accepted
     */
    function cancelMission() external onlyPoster inState(MissionState.Open) {
        _state = MissionState.Cancelled;

        // Refund poster
        IERC20(_usdc).safeTransfer(_poster, _rewardAmount);

        emit MissionCancelled(_missionId);
    }

    /**
     * @notice Raise a dispute
     * @param disputeHash IPFS hash of dispute evidence
     * @dev Can be called by poster or performer after acceptance
     */
    function raiseDispute(bytes32 disputeHash) external {
        if (_state != MissionState.Accepted && _state != MissionState.Submitted) {
            revert InvalidState();
        }

        if (msg.sender != _poster && msg.sender != _performer) {
            revert NotParty();
        }

        if (_disputeRaised) revert DisputeAlreadyRaised();

        _disputeRaised = true;
        _state = MissionState.Disputed;

        emit MissionDisputed(_missionId, msg.sender, disputeHash);
    }

    /**
     * @notice Claim funds after mission expiry
     * @dev Poster can reclaim if mission expired without being completed
     */
    function claimExpired() external onlyPoster {
        if (block.timestamp <= _expiresAt) revert MissionNotExpired();

        if (_state != MissionState.Open && _state != MissionState.Accepted) {
            revert InvalidState();
        }

        _state = MissionState.Cancelled;
        IERC20(_usdc).safeTransfer(_poster, _rewardAmount);

        emit MissionCancelled(_missionId);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    function getParams() external view returns (MissionParams memory) {
        return MissionParams({
            poster: _poster,
            rewardAmount: uint256(_rewardAmount),
            createdAt: uint256(_createdAt),
            expiresAt: uint256(_expiresAt),
            guild: _guild,
            metadataHash: _metadataHash,
            locationHash: _locationHash
        });
    }

    function getRuntime() external view returns (MissionRuntime memory) {
        return MissionRuntime({
            performer: _performer,
            state: _state,
            proofHash: _proofHash,
            disputeRaised: _disputeRaised
        });
    }

    function getMissionId() external view returns (uint256) {
        return uint256(_missionId);
    }

    function getDisputeResolver() external view returns (address) {
        return _disputeResolver;
    }

    // =============================================================================
    // DISPUTE SETTLEMENT
    // =============================================================================

    /**
     * @notice Settle escrow based on dispute outcome
     * @dev Called by DisputeResolver after finalization
     * @param outcome 0=None, 1=PosterWins, 2=PerformerWins, 3=Split, 4=Cancelled
     * @param splitPercentage For Split outcome, performer's share in basis points (0-10000)
     */
    function settleDispute(uint8 outcome, uint256 splitPercentage) external {
        // Only dispute resolver can settle
        if (msg.sender != _disputeResolver) revert NotDisputeResolver();

        // Must be in Disputed state
        if (_state != MissionState.Disputed) revert InvalidState();

        uint256 posterAmount = 0;
        uint256 performerAmount = 0;

        if (outcome == 1) {
            // PosterWins: Poster gets full refund
            posterAmount = _rewardAmount;
        } else if (outcome == 2) {
            // PerformerWins: Performer gets full reward (through PaymentRouter)
            performerAmount = _rewardAmount;
        } else if (outcome == 3) {
            // Split: Distribute based on splitPercentage
            performerAmount = (uint256(_rewardAmount) * splitPercentage) / 10_000;
            posterAmount = uint256(_rewardAmount) - performerAmount;
        } else if (outcome == 4) {
            // Cancelled: Poster gets refund
            posterAmount = _rewardAmount;
        } else {
            revert InvalidState();
        }

        // Update state
        _state = MissionState.Completed;

        // Transfer funds
        if (posterAmount > 0) {
            IERC20(_usdc).safeTransfer(_poster, posterAmount);
        }
        if (performerAmount > 0) {
            // Transfer to performer directly (simple version)
            // In production, could use PaymentRouter for fee distribution
            IERC20(_usdc).safeTransfer(_performer, performerAmount);
        }

        emit DisputeSettled(_missionId, outcome, posterAmount, performerAmount);
    }
}
