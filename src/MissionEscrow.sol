// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMissionEscrow} from "./interfaces/IMissionEscrow.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {IPauseRegistry} from "./interfaces/IPauseRegistry.sol";
import {IReputationOracle} from "./interfaces/IReputationOracle.sol";

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
contract MissionEscrow is Initializable, ReentrancyGuard, IMissionEscrow {
    using SafeERC20 for IERC20;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    uint256 internal _missionId;
    MissionParams internal _params;
    MissionRuntime internal _runtime;

    IPaymentRouter internal _paymentRouter;
    IERC20 internal _token; // Payment token (USDC or EURC)

    /// @notice DisputeResolver address — only this address can call settleDispute()
    address internal _disputeResolver;

    /// @notice PauseRegistry for graceful wind-down
    IPauseRegistry internal _pauseRegistry;

    /// @notice ReputationOracle for reputation gating
    IReputationOracle internal _reputationOracle;

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

    modifier onlyDisputeResolver() {
        if (msg.sender != _disputeResolver) revert NotDisputeResolver();
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
        address paymentToken,
        address disputeResolver,
        address pauseRegistryAddr,
        uint256 minReputation,
        address reputationOracle
    ) external initializer {
        _missionId = missionId;
        
        _params = MissionParams({
            poster: poster,
            rewardAmount: rewardAmount,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            guild: guild,
            metadataHash: metadataHash,
            locationHash: locationHash,
            minReputation: minReputation
        });

        _runtime = MissionRuntime({
            performer: address(0),
            state: MissionState.Open,
            proofHash: bytes32(0),
            disputeRaised: false
        });

        _paymentRouter = IPaymentRouter(paymentRouter);
        _token = IERC20(paymentToken);
        _disputeResolver = disputeResolver;
        if (pauseRegistryAddr != address(0)) {
            _pauseRegistry = IPauseRegistry(pauseRegistryAddr);
        }
        if (reputationOracle != address(0)) {
            _reputationOracle = IReputationOracle(reputationOracle);
        }
    }

    // =============================================================================
    // MISSION ACTIONS
    // =============================================================================

    /**
     * @notice Accept the mission as a performer
     * @dev Transitions from Open to Accepted
     *      Checks performer reputation against minReputation via ReputationOracle
     */
    function acceptMission() external inState(MissionState.Open) notExpired {
        // Graceful wind-down: block new acceptances when paused
        if (address(_pauseRegistry) != address(0) && _pauseRegistry.isPaused(address(this))) {
            revert Paused();
        }
        if (_runtime.performer != address(0)) revert AlreadyAccepted();

        // Reputation gating: check performer score against minimum
        if (_params.minReputation > 0 && address(_reputationOracle) != address(0)) {
            uint256 performerScore = _reputationOracle.getScore(msg.sender, _params.guild);
            if (performerScore < _params.minReputation) {
                revert InsufficientReputation(performerScore, _params.minReputation);
            }
        }

        _runtime.performer = msg.sender;
        _runtime.state = MissionState.Accepted;

        emit MissionAccepted(_missionId, msg.sender);
    }

    /**
     * @notice Submit proof of mission completion
     * @param proofHash IPFS hash of completion proof
     */
    function submitProof(bytes32 proofHash) 
        external 
        virtual
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

        // Transfer payment token to PaymentRouter for distribution
        _token.safeTransfer(address(_paymentRouter), _params.rewardAmount);

        // Settle payment through router (passes token so router distributes the right asset)
        _paymentRouter.settlePayment(
            _missionId,
            _runtime.performer,
            address(_token),
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
        _token.safeTransfer(_params.poster, _params.rewardAmount);

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
        _token.safeTransfer(_params.poster, _params.rewardAmount);

        emit MissionCancelled(_missionId);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    function getParams() external view returns (MissionParams memory) {
        return _params;
    }

    function getRuntime() external view returns (MissionRuntime memory) {
        return _runtime;
    }

    function getMissionId() external view returns (uint256) {
        return _missionId;
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
    function settleDispute(uint8 outcome, uint256 splitPercentage)
        external
        onlyDisputeResolver
        nonReentrant
    {
        // Must be in Disputed state
        if (_runtime.state != MissionState.Disputed) revert InvalidState();

        uint256 posterAmount = 0;
        uint256 performerAmount = 0;

        if (outcome == 1) {
            // PosterWins: Poster gets full refund (no protocol fees on refunds)
            posterAmount = _params.rewardAmount;
        } else if (outcome == 2) {
            // PerformerWins: Full reward routed through PaymentRouter (protocol fees apply)
            performerAmount = _params.rewardAmount;
        } else if (outcome == 3) {
            // Split: Performer portion through PaymentRouter, poster portion direct
            performerAmount = (_params.rewardAmount * splitPercentage) / 10000;
            posterAmount = _params.rewardAmount - performerAmount;
        } else if (outcome == 4) {
            // Cancelled: Poster gets refund (no protocol fees on refunds)
            posterAmount = _params.rewardAmount;
        } else {
            revert InvalidState();
        }

        // Update state before external calls (CEI pattern)
        _runtime.state = MissionState.Completed;

        // Transfer funds
        // Outcomes 1 & 4: Direct refund to poster (no protocol fees)
        if (posterAmount > 0) {
            _token.safeTransfer(_params.poster, posterAmount);
        }

        // Outcomes 2 & 3: Route performer portion through PaymentRouter for fee distribution
        if (performerAmount > 0) {
            _token.safeTransfer(address(_paymentRouter), performerAmount);
            _paymentRouter.settlePayment(
                _missionId,
                _runtime.performer,
                address(_token),
                performerAmount,
                _params.guild
            );
        }

        emit DisputeSettled(_missionId, outcome, posterAmount, performerAmount);
    }
}
