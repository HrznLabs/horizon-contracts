// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeliveryEscrow} from "./DeliveryEscrow.sol";
import {IMissionEscrow} from "./interfaces/IMissionEscrow.sol";

/**
 * @title DeliveryMissionFactory
 * @notice Factory for creating delivery mission escrows using minimal proxy pattern (EIP-1167)
 * @dev Deploys clones of DeliveryEscrow for gas efficiency
 */
contract DeliveryMissionFactory is Ownable {
    using SafeERC20 for IERC20;
    using Clones for address;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    address public immutable deliveryEscrowImplementation;
    address public immutable paymentRouter;

    uint256 public missionCount;
    mapping(uint256 => address) public missions;

    // Minimum values
    uint256 public constant MIN_REWARD = 1e6; // 1 USDC
    uint256 public constant MIN_DURATION = 1 hours;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event DeliveryMissionCreated(
        uint256 indexed id,
        address indexed poster,
        address escrow,
        uint256 reward,
        uint256 expiresAt,
        bytes32 metadataHash,
        address guild,
        bytes32 locationHash
    );

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidRewardAmount();
    error InvalidDuration();
    error InsufficientBalance();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(
        address _paymentRouter
    ) Ownable(msg.sender) {
        paymentRouter = _paymentRouter;

        // Deploy implementation contract
        deliveryEscrowImplementation = address(new DeliveryEscrow());
    }

    // =============================================================================
    // MISSION CREATION
    // =============================================================================

    /**
     * @notice Create a new delivery mission
     * @param paymentToken Payment token address (USDC or EURC)
     * @param rewardAmount Token reward amount (scaled by 1e6)
     * @param expiresAt Mission expiration timestamp
     * @param guild Optional guild address
     * @param metadataHash IPFS hash of mission metadata
     * @param locationHash IPFS hash of location data
     * @return missionId The ID of the created mission
     */
    function createDeliveryMission(
        address paymentToken,
        uint256 rewardAmount,
        uint256 expiresAt,
        address guild,
        bytes32 metadataHash,
        bytes32 locationHash
    ) external returns (uint256 missionId) {
        // Validate inputs
        if (rewardAmount < MIN_REWARD) revert InvalidRewardAmount();
        if (expiresAt < block.timestamp + MIN_DURATION) revert InvalidDuration();

        // Increment mission count
        missionId = ++missionCount;

        // Deploy escrow clone
        address escrow = deliveryEscrowImplementation.clone();

        // Initialize escrow
        DeliveryEscrow(payable(escrow)).initialize(
            missionId,
            msg.sender,
            rewardAmount,
            expiresAt,
            guild,
            metadataHash,
            locationHash,
            paymentRouter,
            paymentToken,
            address(0), // disputeResolver - set later via factory admin
            address(0), // pauseRegistry - set later via factory admin
            0,          // minReputation - no gating for delivery missions
            address(0)  // reputationOracle - not used
        );

        // Store mission
        missions[missionId] = escrow;

        // Transfer payment token from poster to escrow
        IERC20(paymentToken).safeTransferFrom(msg.sender, escrow, rewardAmount);

        emit DeliveryMissionCreated(
            missionId,
            msg.sender,
            escrow,
            rewardAmount,
            expiresAt,
            metadataHash,
            guild,
            locationHash
        );

        return missionId;
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Get mission parameters
     * @param missionId Mission ID
     * @return Mission parameters
     */
    function getMissionParams(uint256 missionId) 
        external 
        view 
        returns (IMissionEscrow.MissionParams memory) 
    {
        return DeliveryEscrow(payable(missions[missionId])).getParams();
    }

    /**
     * @notice Get mission runtime state
     * @param missionId Mission ID
     * @return Mission runtime state
     */
    function getMissionRuntime(uint256 missionId) 
        external 
        view 
        returns (IMissionEscrow.MissionRuntime memory) 
    {
        return DeliveryEscrow(payable(missions[missionId])).getRuntime();
    }

    /**
     * @notice Get delivery-specific parameters
     * @param missionId Mission ID
     * @return Delivery parameters
     */
    function getDeliveryParams(uint256 missionId)
        external
        view
        returns (DeliveryEscrow.DeliveryParams memory)
    {
        return DeliveryEscrow(payable(missions[missionId])).getDeliveryParams();
    }

    /**
     * @notice Get waypoints for a delivery mission
     * @param missionId Mission ID
     * @return Array of waypoints
     */
    function getWaypoints(uint256 missionId)
        external
        view
        returns (DeliveryEscrow.DeliveryWaypoint[] memory)
    {
        return DeliveryEscrow(payable(missions[missionId])).getWaypoints();
    }
}
