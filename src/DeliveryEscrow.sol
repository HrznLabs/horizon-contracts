// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MissionEscrow} from "./MissionEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DeliveryEscrow
 * @notice Extended escrow contract for delivery missions with multi-stop support
 * @dev Inherits from MissionEscrow and adds delivery-specific functionality
 *
 * Settlement model (audit H5, option A — issue #819)
 * -------------------------------------------------
 * The escrow holds the FULL order value:
 *
 *     rewardAmount == foodCost + deliveryFee + tipAmount
 *
 * and `approveCompletion()` splits it on-chain:
 *   - `foodCost`    -> restaurant (SubDAO) treasury, in full, no protocol fee
 *   - `deliveryFee` -> PaymentRouter.settleRestaurantOrder, split courier / protocol /
 *                      labs / resolver / MetaDAO / SubDAO (courier >= performer floor)
 *   - `tipAmount`   -> courier, in full, no protocol fee
 *
 * Before this change the inherited `MissionEscrow.approveCompletion()` routed the whole
 * balance through `settlePayment()` as courier reward, so the courier received ~90% of the
 * food cost and the restaurant received nothing.
 *
 * Issue #950: `settleDispute()` is overridden too, so PerformerWins / Split dispute
 * outcomes use the same restaurant-aware payout (shared `_settleOrder`) instead of the
 * inherited `settlePayment()` path.
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

    /**
     * @notice On-chain breakdown of the escrowed order, used at settlement.
     * @dev audit H5 / issue #819. Fields are ordered so each address packs with its
     *      companion uint16 into a single storage slot (4 slots total).
     *
     *      Invariant, enforced at creation and re-checked at settlement:
     *          foodCost + deliveryFee + DeliveryParams.tipAmount == MissionParams.rewardAmount
     *
     *      `addTip()` bumps `rewardAmount` and `tipAmount` by the same value, so the
     *      invariant holds for the whole lifetime of the escrow.
     */
    struct DeliverySettlement {
        /// @notice Paid to the restaurant treasury in full — no protocol fee is taken.
        uint256 foodCost;
        /// @notice Split through the PaymentRouter fee hierarchy; courier gets the remainder.
        uint256 deliveryFee;
        /// @notice Restaurant SubDAO receiving `foodCost` (+ its share of the delivery fee).
        address restaurantDAO;
        /// @notice Restaurant's share of the DELIVERY FEE in bps (<= PaymentRouter.MAX_SUBDAO_FEE_BPS).
        uint16 subDAOFeeBps;
        /// @notice MetaDAO for the vertical (e.g. iTake).
        address metaDAO;
        /// @notice MetaDAO's share of the DELIVERY FEE in bps (<= PaymentRouter.MAX_METADAO_FEE_BPS).
        uint16 metaDAOFeeBps;
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    DeliveryParams private _deliveryParams;
    DeliveryWaypoint[] private _waypoints;
    TrackingCheckpoint[] private _trackingCheckpoints;

    /// @notice audit H5: food/delivery breakdown used by approveCompletion() and settleDispute().
    DeliverySettlement private _settlement;

    /// @notice HIGH-05: Address of the factory that deployed this clone.
    ///         Set during base initialize() by the factory passing itself as caller.
    ///         Used to gate initializeDelivery() so only the factory can call it.
    address private _factory;

    /// @notice HIGH-05: Boolean guard replacing the flawed latitude==0 check.
    ///         latitude can legitimately be 0 (e.g., delivery on the equator/prime meridian),
    ///         so a geographic field is not a safe initialization sentinel.
    bool private _deliveryInitialized;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event WaypointCompleted(uint256 indexed missionId, uint256 waypointIndex, bytes32 proofHash);
    event TrackingUpdate(uint256 indexed missionId, int256 latitude, int256 longitude, uint8 checkpointType);
    event TipAdded(uint256 indexed missionId, uint256 tipAmount, uint256 totalTip);
    event DeliveryLocationVerified(uint256 indexed missionId, uint8 locationType, bool verified);

    /// @notice audit H5: emitted whenever the order is settled through the restaurant path
    ///         (approveCompletion, and settleDispute PerformerWins/Split — issue #950) with the
    ///         exact amounts the escrow moved. For a Split these are the performer-side shares.
    /// @param foodCostToRestaurant Amount routed to the restaurant treasury (no fees taken)
    /// @param deliveryFeeRouted Amount handed to PaymentRouter for the hierarchy split
    /// @param tipToPerformer Tip paid straight to the courier (no fees taken)
    event DeliveryOrderSettled(
        uint256 indexed missionId,
        address indexed performer,
        uint256 foodCostToRestaurant,
        uint256 deliveryFeeRouted,
        uint256 tipToPerformer
    );

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidWaypointIndex();
    error WaypointAlreadyCompleted();
    error DeadlineExceeded();
    error TrackingNotEnabled();
    error InvalidTipAmount();
    error NotDeliveryMission();
    /// @notice HIGH-05: Thrown when a non-factory address calls initializeDelivery()
    error NotFactory();
    /// @notice HIGH-05: Thrown when initializeDelivery() is called a second time
    error DeliveryAlreadyInitialized();
    /// @notice audit H5: foodCost + deliveryFee + tipAmount must equal the escrowed rewardAmount
    error SettlementBreakdownMismatch(uint256 expected, uint256 provided);
    /// @notice audit H5: foodCost > 0 (or a SubDAO fee) with no restaurant to pay
    error MissingRestaurantDAO();
    /// @notice audit H5: a MetaDAO fee was configured with no MetaDAO to pay
    error MissingMetaDAO();
    /// @notice issue #950: a Split dispute outcome with a performer share above 100%
    error InvalidSplitPercentage(uint256 splitPercentage);

    // =============================================================================
    // INITIALIZATION
    // =============================================================================

    /**
     * @notice Override base initialize to capture the deploying factory address.
     * @dev HIGH-05: Records msg.sender (the factory) at clone initialization time so
     *      that initializeDelivery() can restrict access to the factory only.
     *      All other initialization logic is delegated to the parent.
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
    ) external override initializer {
        _factory = msg.sender;

        // Delegate to internal initializer — super.initialize() is not callable because
        // external functions cannot be invoked via super in Solidity 0.8.x.
        _initializeMission(
            missionId,
            poster,
            rewardAmount,
            expiresAt,
            guild,
            metadataHash,
            locationHash,
            paymentRouter,
            paymentToken,
            disputeResolver,
            pauseRegistryAddr,
            minReputation,
            reputationOracle
        );
    }

    /**
     * @notice Initialize delivery escrow with delivery-specific parameters.
     * @dev Security invariants enforced here (HIGH-05, and audit H5 for item 3):
     *      1. Access control: only the factory that deployed this clone may call this
     *         function, preventing front-running by arbitrary callers.
     *      2. Initialization guard: uses a dedicated `_deliveryInitialized` boolean
     *         instead of checking `_deliveryParams.pickup.latitude == 0`. The latitude
     *         field is a geographic value that can legitimately be 0 (equator/prime
     *         meridian), making it an unreliable sentinel.
     *      3. audit H5: records the food/delivery settlement breakdown and enforces that
     *         it accounts for every escrowed wei. Fee-cap validation against the live
     *         PaymentRouter configuration happens in DeliveryMissionFactory (which holds
     *         the router address); the arithmetic invariant is enforced here so the escrow
     *         can never store a breakdown it cannot settle, regardless of the caller.
     * @param deliveryParams Delivery-specific parameters
     * @param settlement Food/delivery/DAO breakdown used at settlement time
     * @param waypoints Array of waypoints for this delivery
     */
    function initializeDelivery(
        DeliveryParams calldata deliveryParams,
        DeliverySettlement calldata settlement,
        DeliveryWaypoint[] calldata waypoints
    ) external {
        if (msg.sender != _factory) revert NotFactory();
        if (_deliveryInitialized) revert DeliveryAlreadyInitialized();

        // audit H5: every escrowed wei must have a destination.
        uint256 breakdown = settlement.foodCost + settlement.deliveryFee + deliveryParams.tipAmount;
        if (breakdown != _params.rewardAmount) {
            revert SettlementBreakdownMismatch(_params.rewardAmount, breakdown);
        }

        // audit H5: a payout with no recipient would be stranded in the PaymentRouter,
        // breaking the "nothing stuck" invariant. Reject at creation instead.
        if (
            (settlement.foodCost > 0 || settlement.subDAOFeeBps > 0)
            && settlement.restaurantDAO == address(0)
        ) {
            revert MissingRestaurantDAO();
        }
        if (settlement.metaDAOFeeBps > 0 && settlement.metaDAO == address(0)) {
            revert MissingMetaDAO();
        }

        _deliveryInitialized = true;
        _deliveryParams = deliveryParams;
        _settlement = settlement;

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
        
        // MED-08: Only enforce the deadline when one has been explicitly set.
        // arrivalDeadline == 0 means "no deadline" — a legitimate default for waypoints
        // that have no time constraint. The original check unconditionally compared
        // block.timestamp > 0, which always evaluated to true and permanently blocked
        // waypoint completion for any waypoint without a deadline.
        if (waypoint.arrivalDeadline != 0 && block.timestamp > waypoint.arrivalDeadline) {
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
    // SETTLEMENT (audit H5 / issue #819)
    // =============================================================================

    /**
     * @notice Get the stored food/delivery settlement breakdown
     * @return The DeliverySettlement recorded at creation
     */
    function getSettlement() external view returns (DeliverySettlement memory) {
        return _settlement;
    }

    /**
     * @notice Approve the delivery and settle the order with the correct on-chain split.
     * @dev audit H5 (issue #819). Replaces the inherited settlement, which routed the whole
     *      escrow balance to the courier as if it were all reward — paying the courier ~90%
     *      of the food cost and the restaurant nothing.
     *
     *      Payout, summing to exactly `rewardAmount`:
     *        tipAmount  -> courier directly (100%, no protocol fee)
     *        foodCost   -> restaurant treasury, in full, via settleRestaurantOrder step 1
     *        deliveryFee-> hierarchy split via settleRestaurantOrder step 2
     *                      (courier >= performer floor, then protocol/labs/resolver/DAOs)
     *
     *      Safety properties are identical to the base function: onlyPoster,
     *      inState(Submitted), nonReentrant, and CEI — the state is set to Completed before
     *      any token transfer. `settleRestaurantOrder` transfers out of the router's own
     *      balance, so the funds are pushed to the router first (same as the base path).
     */
    function approveCompletion()
        external
        override
        onlyPoster
        inState(MissionState.Submitted)
        nonReentrant
    {
        uint256 tip = _deliveryParams.tipAmount;
        uint256 foodCost = _settlement.foodCost;
        uint256 deliveryFee = _settlement.deliveryFee;

        // Defense in depth: the invariant is established at creation and preserved by
        // addTip(), so a mismatch here means storage was corrupted — refuse to pay out.
        _checkBreakdown(foodCost, deliveryFee, tip);

        // CEI: finalize state before any external call.
        _runtime.state = MissionState.Completed;

        _settleOrder(_runtime.performer, foodCost, deliveryFee, tip);

        emit MissionCompleted(_missionId);
    }

    /**
     * @notice Settle a disputed delivery according to the DisputeResolver's outcome.
     * @dev Issue #950. The inherited `MissionEscrow.settleDispute()` routed the WHOLE
     *      `rewardAmount` through `PaymentRouter.settlePayment()` as courier reward for
     *      PerformerWins and Split, so the restaurant's food cost was paid to the courier
     *      (the same bug class as audit H5 / #819, which only fixed `approveCompletion`).
     *
     *      Outcomes (every path moves exactly `rewardAmount` out of the escrow):
     *        1 PosterWins / 4 Cancelled
     *            Full `rewardAmount` refund to the poster, no fees (same as the base).
     *            The restaurant is NOT paid on-chain; if the food was already prepared,
     *            compensating the restaurant is an off-chain operations matter.
     *        2 PerformerWins
     *            Identical to `approveCompletion()`: tip -> courier directly; foodCost ->
     *            restaurant in full and deliveryFee -> hierarchy split, both via
     *            `settleRestaurantOrder`.
     *        3 Split (splitPercentage = performer share in bps, 0..10000)
     *            The restaurant is not a party to the dispute and the food was handed over,
     *            so foodCost -> restaurant in full. Only the courier-attributable pool
     *            (deliveryFee + tip) is split, pro rata:
     *              feeShare = deliveryFee * split / 10000  -> hierarchy split (router)
     *              tipShare = tip * split / 10000          -> courier directly
     *              poster   = rewardAmount - foodCost - feeShare - tipShare (absorbs rounding)
     *        other
     *            Reverts `InvalidState` (same as the base).
     *
     *      `DisputeSettled.performerAmount` is everything not refunded to the poster
     *      (foodCost + feeShare + tipShare), so existing indexer handlers keep working.
     *      Safety properties match the base: onlyDisputeResolver, nonReentrant, Disputed
     *      state required, and CEI — the state is set to Completed before any transfer.
     * @param outcome 0=None, 1=PosterWins, 2=PerformerWins, 3=Split, 4=Cancelled
     * @param splitPercentage For Split, the performer's share in basis points (0-10000)
     */
    function settleDispute(uint8 outcome, uint256 splitPercentage)
        external
        override
        onlyDisputeResolver
        nonReentrant
    {
        if (_runtime.state != MissionState.Disputed) revert InvalidState();

        uint256 total = _params.rewardAmount;
        uint256 foodCost;
        uint256 feeShare;
        uint256 tipShare;

        if (outcome == 1 || outcome == 4) {
            // Full refund to the poster — nothing is routed (foodCost/feeShare/tipShare = 0).
        } else if (outcome == 2 || outcome == 3) {
            uint256 tip = _deliveryParams.tipAmount;
            uint256 deliveryFee = _settlement.deliveryFee;
            foodCost = _settlement.foodCost;
            _checkBreakdown(foodCost, deliveryFee, tip);

            if (outcome == 2) {
                feeShare = deliveryFee;
                tipShare = tip;
            } else {
                if (splitPercentage > 10000) revert InvalidSplitPercentage(splitPercentage);
                feeShare = (deliveryFee * splitPercentage) / 10000;
                tipShare = (tip * splitPercentage) / 10000;
            }
        } else {
            revert InvalidState();
        }

        uint256 performerAmount = foodCost + feeShare + tipShare;
        uint256 posterAmount = total - performerAmount;

        // CEI: finalize state before any external call.
        _runtime.state = MissionState.Completed;

        if (posterAmount > 0) {
            _token.safeTransfer(_params.poster, posterAmount);
        }
        if (performerAmount > 0) {
            _settleOrder(_runtime.performer, foodCost, feeShare, tipShare);
        }

        emit DisputeSettled(_missionId, outcome, posterAmount, performerAmount);
    }

    /**
     * @dev Revert unless foodCost + deliveryFee + tip accounts for every escrowed wei.
     */
    function _checkBreakdown(uint256 foodCost, uint256 deliveryFee, uint256 tip) private view {
        uint256 total = _params.rewardAmount;
        uint256 breakdown = foodCost + deliveryFee + tip;
        if (breakdown != total) revert SettlementBreakdownMismatch(total, breakdown);
    }

    /**
     * @dev Shared payout used by BOTH approveCompletion() and settleDispute() so the two
     *      paths cannot drift again (issue #950). Caller must already have set the state
     *      to Completed (CEI) and validated the amounts.
     *        tip                  -> courier directly (no protocol fee)
     *        foodCost+deliveryFee -> pushed to the router, then settleRestaurantOrder pays
     *                                foodCost to the restaurant in full and splits
     *                                deliveryFee through the fee hierarchy.
     * @param courier Performer receiving the tip and the courier share of the fee
     * @param foodCost Amount paid to the restaurant treasury in full
     * @param deliveryFee Amount split through the PaymentRouter hierarchy
     * @param tip Amount paid to the courier directly
     */
    function _settleOrder(address courier, uint256 foodCost, uint256 deliveryFee, uint256 tip)
        private
    {
        if (tip > 0) {
            _token.safeTransfer(courier, tip);
        }

        uint256 routed = foodCost + deliveryFee;
        if (routed > 0) {
            DeliverySettlement memory settlement = _settlement;
            _token.safeTransfer(address(_paymentRouter), routed);
            _paymentRouter.settleRestaurantOrder(
                _missionId,
                courier,
                address(_token),
                foodCost,
                deliveryFee,
                settlement.restaurantDAO,
                settlement.metaDAO,
                settlement.subDAOFeeBps,
                settlement.metaDAOFeeBps
            );
        }

        emit DeliveryOrderSettled(_missionId, courier, foodCost, deliveryFee, tip);
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

        // Mirror MissionEscrow.withinSubmissionWindow (modifiers aren't inherited here)
        if (block.timestamp > _params.expiresAt + SUBMISSION_GRACE_PERIOD) {
            revert SubmissionWindowClosed();
        }
        _runtime.proofHash = proofHash;
        _runtime.state = MissionState.Submitted;
        
        emit MissionSubmitted(_missionId, proofHash);
    }
}
