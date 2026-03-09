// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MissionEscrow} from "./MissionEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DeliveryEscrow
 * @notice Extended escrow contract for delivery missions with multi-stop support
 * @dev Inherits from MissionEscrow and adds delivery-specific functionality
 */
contract DeliveryEscrow is MissionEscrow {
    using SafeERC20 for IERC20;

    // =============================================================================
    // STRUCTS
    // =============================================================================

    struct DeliveryLocation {
        int256 latitude;       // Scaled by 1e6 (e.g., 37774900 = 37.7749°)
        int256 longitude;      // Scaled by 1e6 (can be negative for west)
        bytes32 addressHash;   // IPFS hash of encrypted full address
        uint8 precision;       // 0=exact, 1=block, 2=neighborhood
        uint256 geofenceRadius; // in meters
        bool requirePresence;  // require geofence check-in
    }

    struct DeliveryWaypoint {
        bytes32 addressHash;
        int256 latitude;
        int256 longitude;
        uint8 waypointType;    // 0=pickup, 1=stop, 2=dropoff
        uint256 arrivalDeadline;
        bool completed;
        uint256 completedAt;
        bytes32 proofHash;     // IPFS hash of proof (photo, signature, etc.)
    }

    struct PackageDetails {
        uint8 itemType;        // 0=document, 1=package, 2=groceries, 3=food, 4=pharmacy, 5=other
        uint8 packageSize;     // 0=envelope, 1=small, 2=medium, 3=large, 4=xl
        uint16 estimatedWeight; // in grams (uint16 max = 65kg)
        uint8 specialHandling; // Bitmap: 1=fragile, 2=keepCold, 4=keepWarm, 8=thisSideUp
    }

    struct TrackingCheckpoint {
        uint256 timestamp;
        int256 latitude;
        int256 longitude;
        uint8 checkpointType;  // 0=enRoute, 1=arrived, 2=departed
    }

    struct DeliveryParams {
        DeliveryLocation pickup;
        DeliveryLocation dropoff;
        PackageDetails package;
        uint256 pickupWindowStart;
        uint256 pickupWindowEnd;
        uint256 deliveryDeadline;
        bool realTimeTrackingEnabled;
        uint256 tipAmount;
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    DeliveryParams private _deliveryParams;
    DeliveryWaypoint[] private _waypoints;
    TrackingCheckpoint[] private _trackingCheckpoints;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event WaypointCompleted(uint256 indexed missionId, uint256 waypointIndex, bytes32 proofHash);
    event TrackingUpdate(uint256 indexed missionId, int256 latitude, int256 longitude, uint8 checkpointType);
    event TipAdded(uint256 indexed missionId, uint256 tipAmount, uint256 totalTip);
    event DeliveryLocationVerified(uint256 indexed missionId, uint8 locationType, bool verified);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidWaypointIndex();
    error WaypointAlreadyCompleted();
    error DeadlineExceeded();
    error TrackingNotEnabled();
    error InvalidTipAmount();
    error NotDeliveryMission();

    // =============================================================================
    // INITIALIZATION
    // =============================================================================

    /**
     * @notice Initialize delivery escrow with delivery-specific parameters
     * @dev Called after base MissionEscrow initialization
     */
    function initializeDelivery(
        DeliveryParams calldata deliveryParams,
        DeliveryWaypoint[] calldata waypoints
    ) external {
        // Can only be called once, right after base initialization
        require(_deliveryParams.pickup.latitude == 0, "Already initialized");
        
        _deliveryParams = deliveryParams;
        
        // Copy waypoints
        for (uint256 i = 0; i < waypoints.length; i++) {
            _waypoints.push(waypoints[i]);
        }
    }

    // =============================================================================
    // WAYPOINT MANAGEMENT
    // =============================================================================

    /**
     * @notice Mark waypoint as completed
     * @param waypointIndex Index in waypoints array
     * @param proofHash IPFS hash of proof (photo, signature, etc.)
     */
    function completeWaypoint(
        uint256 waypointIndex,
        bytes32 proofHash
    ) external onlyPerformer {
        if (waypointIndex >= _waypoints.length) revert InvalidWaypointIndex();
        
        DeliveryWaypoint storage waypoint = _waypoints[waypointIndex];
        
        if (waypoint.completed) revert WaypointAlreadyCompleted();
        
        // Check deadline
        if (block.timestamp > waypoint.arrivalDeadline) {
            revert DeadlineExceeded();
        }
        
        waypoint.completed = true;
        waypoint.completedAt = block.timestamp;
        waypoint.proofHash = proofHash;
        
        emit WaypointCompleted(_missionId, waypointIndex, proofHash);
    }

    /**
     * @notice Get all waypoints for the delivery mission
     * @return Array of delivery waypoints
     */
    function getWaypoints() external view returns (DeliveryWaypoint[] memory) {
        return _waypoints;
    }

    /**
     * @notice Get specific waypoint details
     * @param waypointIndex Index of the waypoint
     * @return Waypoint details
     */
    function getWaypoint(uint256 waypointIndex) external view returns (DeliveryWaypoint memory) {
        if (waypointIndex >= _waypoints.length) revert InvalidWaypointIndex();
        return _waypoints[waypointIndex];
    }

    /**
     * @notice Check if all waypoints are completed
     * @return True if all waypoints completed
     */
    function allWaypointsCompleted() public view returns (bool) {
        for (uint256 i = 0; i < _waypoints.length; i++) {
            if (!_waypoints[i].completed) {
                return false;
            }
        }
        return true;
    }

    // =============================================================================
    // REAL-TIME TRACKING
    // =============================================================================

    /**
     * @notice Add tracking checkpoint (performer shares location)
     * @param latitude Scaled by 1e6
     * @param longitude Scaled by 1e6 (can be negative)
     * @param checkpointType 0=enRoute, 1=arrived, 2=departed
     */
    function addTrackingCheckpoint(
        int256 latitude,
        int256 longitude,
        uint8 checkpointType
    ) external onlyPerformer {
        if (!_deliveryParams.realTimeTrackingEnabled) revert TrackingNotEnabled();
        if (_runtime.state != MissionState.Accepted) revert InvalidState();
        
        _trackingCheckpoints.push(TrackingCheckpoint({
            timestamp: block.timestamp,
            latitude: latitude,
            longitude: longitude,
            checkpointType: checkpointType
        }));
        
        emit TrackingUpdate(_missionId, latitude, longitude, checkpointType);
    }

    /**
     * @notice Get tracking history
     * @return Array of tracking checkpoints
     */
    function getTrackingHistory() external view returns (TrackingCheckpoint[] memory) {
        return _trackingCheckpoints;
    }

    /**
     * @notice Get latest tracking checkpoint
     * @return Latest checkpoint or reverts if none exist
     */
    function getLatestCheckpoint() external view returns (TrackingCheckpoint memory) {
        require(_trackingCheckpoints.length > 0, "No checkpoints");
        return _trackingCheckpoints[_trackingCheckpoints.length - 1];
    }

    // =============================================================================
    // TIPPING
    // =============================================================================

    /**
     * @notice Add tip to mission reward
     * @param tipAmount Additional USDC to add as tip
     * @dev Can be called by poster after mission acceptance
     */
    function addTip(uint256 tipAmount) external onlyPoster {
        if (_runtime.state != MissionState.Accepted && 
            _runtime.state != MissionState.Submitted) {
            revert InvalidState();
        }
        if (tipAmount == 0) revert InvalidTipAmount();
        
        // Transfer tip from poster (uses same token as the mission)
        _token.safeTransferFrom(msg.sender, address(this), tipAmount);
        
        // Update delivery params and total reward
        _deliveryParams.tipAmount += tipAmount;
        _params.rewardAmount += tipAmount;
        
        emit TipAdded(_missionId, tipAmount, _deliveryParams.tipAmount);
    }

    /**
     * @notice Get current tip amount
     * @return Total tips added to this delivery
     */
    function getTipAmount() external view returns (uint256) {
        return _deliveryParams.tipAmount;
    }

    // =============================================================================
    // DELIVERY-SPECIFIC GETTERS
    // =============================================================================

    /**
     * @notice Get delivery parameters
     * @return Delivery-specific parameters
     */
    function getDeliveryParams() external view returns (DeliveryParams memory) {
        return _deliveryParams;
    }

    /**
     * @notice Get package details
     * @return Package information
     */
    function getPackageDetails() external view returns (PackageDetails memory) {
        return _deliveryParams.package;
    }

    /**
     * @notice Get pickup location
     * @return Pickup location details
     */
    function getPickupLocation() external view returns (DeliveryLocation memory) {
        return _deliveryParams.pickup;
    }

    /**
     * @notice Get dropoff location
     * @return Dropoff location details
     */
    function getDropoffLocation() external view returns (DeliveryLocation memory) {
        return _deliveryParams.dropoff;
    }

    /**
     * @notice Check if delivery is within time windows
     * @return True if current time is within valid delivery window
     */
    function isWithinDeliveryWindow() public view returns (bool) {
        return block.timestamp >= _deliveryParams.pickupWindowStart &&
               block.timestamp <= _deliveryParams.deliveryDeadline;
    }

    // =============================================================================
    // OVERRIDES
    // =============================================================================

    /**
     * @notice Override submitProof to require all waypoints completed
     * @param proofHash IPFS hash of final delivery proof
     */
    function submitProof(bytes32 proofHash) external override onlyPerformer {
        // For delivery missions, all waypoints must be completed
        require(allWaypointsCompleted(), "All waypoints must be completed");
        
        // Manually update state (can't call super with modifiers)
        require(_runtime.state == MissionState.Accepted, "Invalid state");
        _runtime.proofHash = proofHash;
        _runtime.state = MissionState.Submitted;
        
        emit MissionSubmitted(_missionId, proofHash);
    }
}
