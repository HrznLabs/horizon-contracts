// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IMissionEscrow} from "./interfaces/IMissionEscrow.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";

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
    // PACKED STRUCTS
    // =============================================================================

    struct MissionParamsPacked {
        address poster;         // 20
        uint64 createdAt;       // 8
        address guild;          // 20
        uint64 expiresAt;       // 8
        uint256 rewardAmount;   // 32
        bytes32 metadataHash;   // 32
        bytes32 locationHash;   // 32
    }

    struct MissionRuntimePacked {
        address performer;    // 20
        MissionState state;   // 1
        bool disputeRaised;   // 1
        bytes32 proofHash;    // 32
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    uint256 private _missionId;
    MissionParamsPacked private _params;
    MissionRuntimePacked private _runtime;

    IPaymentRouter private _paymentRouter;
    IERC20 private _usdc;
    address private _disputeResolver;

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier onlyPoster() {
        if (msg.sender != _params.poster) revert NotPoster();
        _;
    }

    modifier onlyPerformer() {
        if (msg.sender != _runtime.performer) revert NotPerformer();
        _;
    }

    modifier inState(MissionState state) {
        if (_runtime.state != state) revert InvalidState();
        _;
    }

    modifier notExpired() {
        if (block.timestamp > _params.expiresAt) revert MissionExpired();
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
        _missionId = missionId;
        
        if (expiresAt > type(uint64).max) revert MissionExpired();

        _params = MissionParamsPacked({
            poster: poster,
            rewardAmount: rewardAmount,
            createdAt: uint64(block.timestamp),
            expiresAt: uint64(expiresAt),
            guild: guild,
            metadataHash: metadataHash,
            locationHash: locationHash
        });

        _runtime = MissionRuntimePacked({
            performer: address(0),
            state: MissionState.Open,
            proofHash: bytes32(0),
            disputeRaised: false
        });

        _paymentRouter = IPaymentRouter(paymentRouter);
        _usdc = IERC20(usdc);
        _disputeResolver = disputeResolver;
    }

    // =============================================================================
    // MISSION ACTIONS
    // =============================================================================

    /**
     * @notice Accept the mission as a performer
     * @dev Transitions from Open to Accepted
     */
    function acceptMission() external inState(MissionState.Open) notExpired {
        if (_runtime.performer != address(0)) revert AlreadyAccepted();

        _runtime.performer = msg.sender;
        _runtime.state = MissionState.Accepted;

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
    {
        _runtime.proofHash = proofHash;
        _runtime.state = MissionState.Submitted;

        emit MissionSubmitted(_missionId, proofHash);
    }

    /**
     * @notice Approve mission completion and trigger payment
     * @dev Transitions from Submitted to Completed
     */
    function approveCompletion() 
        external 
        onlyPoster 
        inState(MissionState.Submitted) 
    {
        _runtime.state = MissionState.Completed;

        // Transfer USDC to PaymentRouter for distribution
        _usdc.safeTransfer(address(_paymentRouter), _params.rewardAmount);

        // Settle payment through router
        _paymentRouter.settlePayment(
            _missionId,
            _runtime.performer,
            _params.rewardAmount,
            _params.guild
        );

        emit MissionCompleted(_missionId);
    }

    /**
     * @notice Cancel mission and refund poster
     * @dev Only allowed if not yet accepted
     */
    function cancelMission() 
        external 
        onlyPoster 
        inState(MissionState.Open) 
    {
        _runtime.state = MissionState.Cancelled;

        // Refund poster
        _usdc.safeTransfer(_params.poster, _params.rewardAmount);

        emit MissionCancelled(_missionId);
    }

    /**
     * @notice Raise a dispute
     * @param disputeHash IPFS hash of dispute evidence
     * @dev Can be called by poster or performer after acceptance
     */
    function raiseDispute(bytes32 disputeHash) external {
        if (_runtime.state != MissionState.Accepted && 
            _runtime.state != MissionState.Submitted) {
            revert InvalidState();
        }
        
        if (msg.sender != _params.poster && msg.sender != _runtime.performer) {
            revert InvalidState();
        }

        if (_runtime.disputeRaised) revert DisputeAlreadyRaised();

        _runtime.disputeRaised = true;
        _runtime.state = MissionState.Disputed;

        emit MissionDisputed(_missionId, msg.sender, disputeHash);
    }

    /**
     * @notice Claim funds after mission expiry
     * @dev Poster can reclaim if mission expired without being completed
     */
    function claimExpired() external onlyPoster {
        if (block.timestamp <= _params.expiresAt) revert MissionNotExpired();
        
        if (_runtime.state == MissionState.Completed || 
            _runtime.state == MissionState.Cancelled) {
            revert InvalidState();
        }

        _runtime.state = MissionState.Cancelled;
        _usdc.safeTransfer(_params.poster, _params.rewardAmount);

        emit MissionCancelled(_missionId);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    function getParams() external view returns (MissionParams memory) {
        return MissionParams({
            poster: _params.poster,
            rewardAmount: _params.rewardAmount,
            createdAt: uint256(_params.createdAt),
            expiresAt: uint256(_params.expiresAt),
            guild: _params.guild,
            metadataHash: _params.metadataHash,
            locationHash: _params.locationHash
        });
    }

    function getRuntime() external view returns (MissionRuntime memory) {
        return MissionRuntime({
            performer: _runtime.performer,
            state: _runtime.state,
            proofHash: _runtime.proofHash,
            disputeRaised: _runtime.disputeRaised
        });
    }

    function getMissionId() external view returns (uint256) {
        return _missionId;
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
        if (_runtime.state != MissionState.Disputed) revert InvalidState();
        
        uint256 posterAmount = 0;
        uint256 performerAmount = 0;
        
        if (outcome == 1) {
            // PosterWins: Poster gets full refund
            posterAmount = _params.rewardAmount;
        } else if (outcome == 2) {
            // PerformerWins: Performer gets full reward (through PaymentRouter)
            performerAmount = _params.rewardAmount;
        } else if (outcome == 3) {
            // Split: Distribute based on splitPercentage
            performerAmount = (_params.rewardAmount * splitPercentage) / 10000;
            posterAmount = _params.rewardAmount - performerAmount;
        } else if (outcome == 4) {
            // Cancelled: Poster gets refund
            posterAmount = _params.rewardAmount;
        } else {
            revert InvalidState();
        }
        
        // Update state
        _runtime.state = MissionState.Completed;
        
        // Transfer funds
        if (posterAmount > 0) {
            _usdc.safeTransfer(_params.poster, posterAmount);
        }
        if (performerAmount > 0) {
            // Transfer to performer directly (simple version)
            // In production, could use PaymentRouter for fee distribution
            _usdc.safeTransfer(_runtime.performer, performerAmount);
        }
        
        emit DisputeSettled(_missionId, outcome, posterAmount, performerAmount);
    }
}
<<<<<<< bolt/optimize-mission-escrow-storage-11154790348603479756
=======

>>>>>>> main
