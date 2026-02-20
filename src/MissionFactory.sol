// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IMissionEscrow } from "./interfaces/IMissionEscrow.sol";
import { MissionEscrow } from "./MissionEscrow.sol";

/**
 * @title MissionFactory
 * @notice Factory contract for deploying MissionEscrow clones
 * @dev Uses minimal proxy pattern (EIP-1167) for gas-efficient deployment
 *
 * The factory is the canonical entrypoint for mission creation in Horizon.
 * It validates parameters, deploys escrow clones, and transfers initial funds.
 */
contract MissionFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Clones for address;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Implementation contract for MissionEscrow clones
    address public immutable escrowImplementation;

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice PaymentRouter contract address
    address public paymentRouter;

    /// @notice DisputeResolver contract address
    address public disputeResolver;

    /// @notice Current mission counter
    /// @dev Packed with disputeResolver (20 bytes + 12 bytes = 32 bytes)
    uint96 public missionCount;

    /// @notice Mapping from mission ID to escrow address
    mapping(uint256 => address) public missions;

    /// @notice Minimum reward amount (1 USDC = 1e6)
    uint256 public constant MIN_REWARD = 1e6;

    /// @notice Maximum reward amount (100,000 USDC)
    uint256 public constant MAX_REWARD = 100_000e6;

    /// @notice Minimum mission duration (1 hour)
    uint256 public constant MIN_DURATION = 1 hours;

    /// @notice Maximum mission duration (30 days)
    uint256 public constant MAX_DURATION = 30 days;

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
    event DisputeResolverUpdated(address indexed resolver);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidRewardAmount(uint256 amount, uint256 min, uint256 max);
    error InvalidDuration(uint256 duration, uint256 min, uint256 max);
    error InvalidPaymentRouter();
    error InvalidDisputeResolver();
    error TransferFailed();
    error MissionNotFound();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /**
     * @notice Deploy the MissionFactory
     * @param _usdc USDC token address
     * @param _paymentRouter PaymentRouter contract address
     */
    constructor(address _usdc, address _paymentRouter) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        paymentRouter = _paymentRouter;

        // Deploy the implementation contract
        escrowImplementation = address(new MissionEscrow());
    }

    // =============================================================================
    // MISSION CREATION
    // =============================================================================

    /**
     * @notice Create a new mission with USDC escrow
     * @param rewardAmount USDC reward amount (6 decimals)
     * @param expiresAt Timestamp when mission expires
     * @param guild Optional guild address (address(0) if none)
     * @param metadataHash IPFS hash of mission metadata
     * @param locationHash IPFS hash of location data
     * @return missionId The ID of the created mission
     */
    function createMission(
        uint256 rewardAmount,
        uint256 expiresAt,
        address guild,
        bytes32 metadataHash,
        bytes32 locationHash
    ) external nonReentrant returns (uint256 missionId) {
        // Validate reward amount
        if (rewardAmount < MIN_REWARD || rewardAmount > MAX_REWARD) {
            revert InvalidRewardAmount(rewardAmount, MIN_REWARD, MAX_REWARD);
        }

        // Validate duration
        uint256 duration = expiresAt - block.timestamp;
        if (duration < MIN_DURATION || duration > MAX_DURATION) {
            revert InvalidDuration(duration, MIN_DURATION, MAX_DURATION);
        }

        // Validate dispute resolver
        if (disputeResolver == address(0)) revert InvalidDisputeResolver();

        // Increment mission counter
        // Safe cast: missionCount is uint96, so missionId fits in uint96
        missionId = ++missionCount;

        // Deploy escrow clone
        address escrow = escrowImplementation.clone();

        // Initialize escrow
        // Safe casts:
        // - missionId is from uint96 counter
        // - rewardAmount is validated <= MAX_REWARD (fits in uint96)
        // - expiresAt is validated via duration <= MAX_DURATION (fits in uint64)
        IMissionEscrow(escrow)
            .initialize(
                uint96(missionId),
                msg.sender,
                uint96(rewardAmount),
                uint64(expiresAt),
                guild,
                metadataHash,
                locationHash,
                paymentRouter,
                address(usdc),
                disputeResolver
            );

        // Store mission mapping
        missions[missionId] = escrow;

        // Transfer USDC from poster to escrow
        usdc.safeTransferFrom(msg.sender, escrow, rewardAmount);

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
        if (_disputeResolver == address(0)) revert InvalidDisputeResolver();
        disputeResolver = _disputeResolver;
        emit DisputeResolverUpdated(_disputeResolver);
    }
}

