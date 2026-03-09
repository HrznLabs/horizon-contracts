// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMissionEscrow} from "./interfaces/IMissionEscrow.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {MissionEscrow} from "./MissionEscrow.sol";
import {IPauseRegistry} from "./interfaces/IPauseRegistry.sol";
import {IReputationOracle} from "./interfaces/IReputationOracle.sol";

/**
 * @title MissionFactory
 * @notice Factory contract for deploying MissionEscrow clones
 * @dev Uses minimal proxy pattern (EIP-1167) for gas-efficient deployment
 *
 * The factory is the canonical entrypoint for mission creation in Horizon.
 * It validates parameters, deploys escrow clones, and transfers initial funds.
 *
 * Three-layer reputation gating:
 *   Layer 1: Protocol auto-floor for high-value missions (>= 500 USDC → minRep 200)
 *   Layer 2: Guild default minimum (if higher than specified)
 *   Layer 3: Poster override (parameter)
 */
contract MissionFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Clones for address;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Implementation contract for MissionEscrow clones
    address public immutable escrowImplementation;

    /// @notice PaymentRouter contract address
    address public paymentRouter;

    /// @notice DisputeResolver contract address
    address public disputeResolver;

    /// @notice PauseRegistry for emergency pause control
    IPauseRegistry public pauseRegistry;

    /// @notice ReputationOracle for on-chain reputation gating
    address public reputationOracle;

    /// @notice Current mission counter
    uint256 public missionCount;

    /// @notice Mapping from mission ID to escrow address
    mapping(uint256 => address) public missions;

    /// @notice Reverse mapping from escrow address to mission ID (for PaymentRouter auth)
    mapping(address => uint256) public escrowToMission;

    /// @notice Guild-level default minimum reputation
    mapping(address => uint256) public guildMinReputation;

    /// @notice Minimum reward amount (1 USDC = 1e6)
    uint256 public constant MIN_REWARD = 1e6;

    /// @notice Maximum reward amount (100,000 USDC)
    uint256 public constant MAX_REWARD = 100_000e6;

    /// @notice Minimum mission duration (1 hour)
    uint256 public constant MIN_DURATION = 1 hours;

    /// @notice Maximum mission duration (30 days)
    uint256 public constant MAX_DURATION = 30 days;

    /// @notice Protocol auto-floor: missions >= this reward get minReputation 200
    uint256 public constant PREMIUM_MISSION_THRESHOLD = 500e6; // 500 USDC

    /// @notice Protocol auto-floor reputation minimum for premium missions
    uint256 public constant PROTOCOL_FLOOR_REPUTATION = 200;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event MissionCreated(
        uint256 indexed id,
        address indexed poster,
        address escrow,
        uint256 reward,
        uint256 expiresAt,
        bytes32 metadataHash,
        address guild,
        bytes32 locationHash
    );

    event PaymentRouterUpdated(address indexed newRouter);
    event GuildMinReputationUpdated(address indexed guild, uint256 minReputation);
    event ReputationOracleUpdated(address indexed oracle);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidRewardAmount();
    error InvalidDuration();
    error InvalidPaymentRouter();
    error TransferFailed();
    error MissionNotFound();
    error Paused();
    error TokenNotAccepted();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /**
     * @notice Deploy the MissionFactory
     * @param _paymentRouter PaymentRouter contract address (token whitelist lives there)
     */
    constructor(
        address _paymentRouter
    ) Ownable(msg.sender) {
        paymentRouter = _paymentRouter;

        // Deploy the implementation contract
        escrowImplementation = address(new MissionEscrow());
    }

    // =============================================================================
    // MISSION CREATION
    // =============================================================================

    /**
     * @notice Create a new mission
     * @param paymentToken Payment token address (USDC or EURC — must be accepted by PaymentRouter)
     * @param rewardAmount Token reward amount (6 decimals)
     * @param expiresAt Timestamp when mission expires
     * @param guild Optional guild address (address(0) if none)
     * @param metadataHash IPFS hash of mission metadata
     * @param locationHash IPFS hash of location data
     * @param minReputation Minimum reputation score for performers (0 = no restriction)
     * @return missionId The ID of the created mission
     */
    function createMission(
        address paymentToken,
        uint256 rewardAmount,
        uint256 expiresAt,
        address guild,
        bytes32 metadataHash,
        bytes32 locationHash,
        uint256 minReputation
    ) external nonReentrant returns (uint256 missionId) {
        // Validate token is accepted by the PaymentRouter
        if (!IPaymentRouter(paymentRouter).acceptedTokens(paymentToken)) revert TokenNotAccepted();
        // Check pause state — no new missions when paused
        if (address(pauseRegistry) != address(0) && pauseRegistry.isPaused(address(this))) {
            revert Paused();
        }

        // Validate reward amount
        if (rewardAmount < MIN_REWARD || rewardAmount > MAX_REWARD) {
            revert InvalidRewardAmount();
        }

        // Validate duration
        uint256 duration = expiresAt - block.timestamp;
        if (duration < MIN_DURATION || duration > MAX_DURATION) {
            revert InvalidDuration();
        }

        // =====================================================================
        // Three-layer reputation gating
        // =====================================================================

        uint256 effectiveMinRep = minReputation;

        // Layer 1: Protocol auto-floor for high-value missions (>= 500 USDC)
        if (rewardAmount >= PREMIUM_MISSION_THRESHOLD && effectiveMinRep < PROTOCOL_FLOOR_REPUTATION) {
            effectiveMinRep = PROTOCOL_FLOOR_REPUTATION;
        }

        // Layer 2: Guild default (if higher than specified)
        if (guild != address(0)) {
            uint256 guildMin = guildMinReputation[guild];
            if (guildMin > effectiveMinRep) {
                effectiveMinRep = guildMin;
            }
        }

        // Layer 3: Poster override already applied via `minReputation` parameter
        // (only applies if poster specified higher — already captured above)

        // Increment mission counter
        missionId = ++missionCount;

        // Deploy escrow clone
        address escrow = escrowImplementation.clone();

        // Initialize escrow with reputation gating params
        IMissionEscrow(escrow).initialize(
            missionId,
            msg.sender,
            rewardAmount,
            expiresAt,
            guild,
            metadataHash,
            locationHash,
            paymentRouter,
            paymentToken,
            disputeResolver,
            address(pauseRegistry),
            effectiveMinRep,
            reputationOracle
        );

        // Store mission mapping (both directions)
        missions[missionId] = escrow;
        escrowToMission[escrow] = missionId;

        // Transfer payment token from poster to escrow
        IERC20(paymentToken).safeTransferFrom(msg.sender, escrow, rewardAmount);

        emit MissionCreated(
            missionId,
            msg.sender,
            escrow,
            rewardAmount,
            expiresAt,
            metadataHash,
            guild,
            locationHash
        );
    }

    /**
     * @notice Backward-compatible createMission without minReputation
     * @dev Calls the full version with minReputation=0
     */
    function createMission(
        address paymentToken,
        uint256 rewardAmount,
        uint256 expiresAt,
        address guild,
        bytes32 metadataHash,
        bytes32 locationHash
    ) external nonReentrant returns (uint256 missionId) {
        // Validate token is accepted by the PaymentRouter
        if (!IPaymentRouter(paymentRouter).acceptedTokens(paymentToken)) revert TokenNotAccepted();
        // Check pause state — no new missions when paused
        if (address(pauseRegistry) != address(0) && pauseRegistry.isPaused(address(this))) {
            revert Paused();
        }

        // Validate reward amount
        if (rewardAmount < MIN_REWARD || rewardAmount > MAX_REWARD) {
            revert InvalidRewardAmount();
        }

        // Validate duration
        uint256 duration = expiresAt - block.timestamp;
        if (duration < MIN_DURATION || duration > MAX_DURATION) {
            revert InvalidDuration();
        }

        // Three-layer gating with minReputation=0 (poster default)
        uint256 effectiveMinRep = 0;

        // Layer 1: Protocol auto-floor
        if (rewardAmount >= PREMIUM_MISSION_THRESHOLD) {
            effectiveMinRep = PROTOCOL_FLOOR_REPUTATION;
        }

        // Layer 2: Guild default
        if (guild != address(0)) {
            uint256 guildMin = guildMinReputation[guild];
            if (guildMin > effectiveMinRep) {
                effectiveMinRep = guildMin;
            }
        }

        // Increment mission counter
        missionId = ++missionCount;

        // Deploy escrow clone
        address escrow = escrowImplementation.clone();

        // Initialize escrow
        IMissionEscrow(escrow).initialize(
            missionId,
            msg.sender,
            rewardAmount,
            expiresAt,
            guild,
            metadataHash,
            locationHash,
            paymentRouter,
            paymentToken,
            disputeResolver,
            address(pauseRegistry),
            effectiveMinRep,
            reputationOracle
        );

        // Store mission mapping (both directions)
        missions[missionId] = escrow;
        escrowToMission[escrow] = missionId;

        // Transfer payment token from poster to escrow
        IERC20(paymentToken).safeTransferFrom(msg.sender, escrow, rewardAmount);

        emit MissionCreated(
            missionId,
            msg.sender,
            escrow,
            rewardAmount,
            expiresAt,
            metadataHash,
            guild,
            locationHash
        );
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Get escrow address for a mission
     * @param missionId The mission ID
     * @return escrow The escrow contract address
     */
    function getMission(uint256 missionId) external view returns (address escrow) {
        escrow = missions[missionId];
        if (escrow == address(0)) revert MissionNotFound();
    }

    /**
     * @notice Get mission ID by escrow address (returns 0 if not found)
     * @param escrow The escrow contract address
     * @return missionId The mission ID (0 if not a known escrow)
     */
    function getMissionByEscrow(address escrow) external view returns (uint256) {
        return escrowToMission[escrow];
    }

    /**
     * @notice Get mission parameters
     * @param missionId The mission ID
     * @return params The mission parameters
     */
    function getMissionParams(uint256 missionId) 
        external 
        view 
        returns (IMissionEscrow.MissionParams memory params) 
    {
        address escrow = missions[missionId];
        if (escrow == address(0)) revert MissionNotFound();
        return IMissionEscrow(escrow).getParams();
    }

    /**
     * @notice Get mission runtime state
     * @param missionId The mission ID
     * @return runtime The mission runtime state
     */
    function getMissionRuntime(uint256 missionId) 
        external 
        view 
        returns (IMissionEscrow.MissionRuntime memory runtime) 
    {
        address escrow = missions[missionId];
        if (escrow == address(0)) revert MissionNotFound();
        return IMissionEscrow(escrow).getRuntime();
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Update the payment router address
     * @param _paymentRouter New payment router address
     */
    function setPaymentRouter(address _paymentRouter) external onlyOwner {
        if (_paymentRouter == address(0)) revert InvalidPaymentRouter();
        paymentRouter = _paymentRouter;
        emit PaymentRouterUpdated(_paymentRouter);
    }

    /**
     * @notice Update the dispute resolver address
     * @param _disputeResolver New dispute resolver address
     */
    function setDisputeResolver(address _disputeResolver) external onlyOwner {
        disputeResolver = _disputeResolver;
    }

    /**
     * @notice Set the pause registry address
     * @param _pauseRegistry PauseRegistry contract address
     */
    function setPauseRegistry(address _pauseRegistry) external onlyOwner {
        pauseRegistry = IPauseRegistry(_pauseRegistry);
    }

    /**
     * @notice Set the reputation oracle address
     * @param _reputationOracle ReputationOracle contract address
     */
    function setReputationOracle(address _reputationOracle) external onlyOwner {
        reputationOracle = _reputationOracle;
        emit ReputationOracleUpdated(_reputationOracle);
    }    /**
     * @notice Set the default minimum reputation for a guild
     * @param guild The guild address
     * @param minReputation The minimum reputation score (0-1000)
     */
    function setGuildMinReputation(address guild, uint256 minReputation) external onlyOwner {
        guildMinReputation[guild] = minReputation;
        emit GuildMinReputationUpdated(guild, minReputation);
    }
}
