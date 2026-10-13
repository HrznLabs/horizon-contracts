// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeliveryEscrow} from "./DeliveryEscrow.sol";
import {IMissionEscrow} from "./interfaces/IMissionEscrow.sol";
import {PaymentRouter} from "./PaymentRouter.sol";

/**
 * @title DeliveryMissionFactory
 * @notice Factory for creating delivery mission escrows using minimal proxy pattern (EIP-1167)
 * @dev Deploys clones of DeliveryEscrow for gas efficiency
 */
contract DeliveryMissionFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Clones for address;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    address public immutable deliveryEscrowImplementation;
    address public immutable paymentRouter;

    /// @notice DisputeResolver passed to every escrow at init. Must be set before any
    /// mission is created — audit C2: escrows were initialized with address(0) and had
    /// no setter, so a disputed delivery could never be settled and funds froze forever.
    address public disputeResolver;

    uint256 public missionCount;
    mapping(uint256 => address) public missions;

    /// @notice Reverse lookup escrow -> mission id. Required by IMissionFactory:
    /// PaymentRouter._isFactoryEscrow() calls getMissionByEscrow() to authorize an
    /// escrow before settling. Without it, delivery settlement reverts OnlyMissionEscrow.
    mapping(address => uint256) public escrowToMission;

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
    error ZeroAddress();
    error DisputeResolverNotSet();
    /// @notice audit H5: SubDAO share of the delivery fee exceeds PaymentRouter.MAX_SUBDAO_FEE_BPS
    error SubDAOFeeTooHigh(uint16 requested, uint16 maximum);
    /// @notice audit H5: MetaDAO share of the delivery fee exceeds PaymentRouter.MAX_METADAO_FEE_BPS
    error MetaDAOFeeTooHigh(uint16 requested, uint16 maximum);
    /// @notice audit H5: total delivery-fee cut would push the courier below the performer floor
    error PerformerFloorViolated(uint16 totalFeeBps, uint16 maxFeeBps);

    event DisputeResolverUpdated(address indexed disputeResolver);

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(
        address _paymentRouter
    ) Ownable(msg.sender) {
        // audit H5: mission creation now reads fee caps + the performer floor from the
        // router, so a zero router would make every createDeliveryMission revert obscurely.
        if (_paymentRouter == address(0)) revert ZeroAddress();
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
     * @param deliveryParams Delivery-specific parameters (pickup/dropoff/package/windows)
     * @param settlement Food/delivery split + restaurant SubDAO / MetaDAO and their fee bps.
     *        `rewardAmount` MUST equal `foodCost + deliveryFee + deliveryParams.tipAmount`
     *        (enforced by DeliveryEscrow.initializeDelivery). For a non-food courier job,
     *        pass foodCost = 0 and restaurantDAO = address(0).
     * @param waypoints Ordered waypoints for this delivery
     * @return missionId The ID of the created mission
     * @dev Delivery params are set atomically here via initializeDelivery — the escrow
     *      can never exist in a half-initialized state where pickup/dropoff/waypoints
     *      were never recorded on-chain.
     * @dev audit H5 (issue #819): the escrow holds the FULL order (food + delivery + tip)
     *      and splits it at settlement. The fee bps are validated here against the live
     *      PaymentRouter configuration so a mission can never be created that would later
     *      revert InvalidFeeConfig inside settleRestaurantOrder and strand the order.
     */
    function createDeliveryMission(
        address paymentToken,
        uint256 rewardAmount,
        uint256 expiresAt,
        address guild,
        bytes32 metadataHash,
        bytes32 locationHash,
        DeliveryEscrow.DeliveryParams calldata deliveryParams,
        DeliveryEscrow.DeliverySettlement calldata settlement,
        DeliveryEscrow.DeliveryWaypoint[] calldata waypoints
    ) external nonReentrant returns (uint256 missionId) {
        // Validate inputs
        if (rewardAmount < MIN_REWARD) revert InvalidRewardAmount();
        if (expiresAt < block.timestamp + MIN_DURATION) revert InvalidDuration();
        // audit C2: never create an escrow that can't be settled in a dispute.
        if (disputeResolver == address(0)) revert DisputeResolverNotSet();

        // audit H5: fail fast on a fee config the router would reject at settlement time.
        _validateSettlementFees(settlement.subDAOFeeBps, settlement.metaDAOFeeBps);

        // Increment mission count
        missionId = ++missionCount;

        // Deploy escrow clone
        address escrow = deliveryEscrowImplementation.clone();

        // Store mission (CEI: state written before external calls)
        missions[missionId] = escrow;
        escrowToMission[escrow] = missionId;

        // Initialize escrow (external call after state write). msg.sender here is this
        // factory, which becomes the escrow's _factory — required for initializeDelivery below.
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
            disputeResolver, // audit C2: real resolver (required non-zero above)
            address(0),      // pauseRegistry - set later via factory admin
            0,               // minReputation - no gating for delivery missions
            address(0)       // reputationOracle - not used
        );

        // Set delivery params + settlement breakdown atomically (onlyFactory on the escrow;
        // this contract is _factory). Reverts if the breakdown doesn't account for every
        // escrowed wei, so a mission is never created with an unsettleable split.
        DeliveryEscrow(payable(escrow)).initializeDelivery(deliveryParams, settlement, waypoints);

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

    /**
     * @notice audit H5: mirror the checks PaymentRouter.settleRestaurantOrder performs.
     * @dev Read from the router rather than hardcoded so a governance change to
     *      `performerFloorBPS` immediately tightens mission creation too.
     * @param subDAOFeeBps Restaurant's share of the delivery fee
     * @param metaDAOFeeBps MetaDAO's share of the delivery fee
     */
    function _validateSettlementFees(uint16 subDAOFeeBps, uint16 metaDAOFeeBps) internal view {
        PaymentRouter router = PaymentRouter(paymentRouter);

        uint16 maxSubDAO = router.MAX_SUBDAO_FEE_BPS();
        if (subDAOFeeBps > maxSubDAO) revert SubDAOFeeTooHigh(subDAOFeeBps, maxSubDAO);

        uint16 maxMetaDAO = router.MAX_METADAO_FEE_BPS();
        if (metaDAOFeeBps > maxMetaDAO) revert MetaDAOFeeTooHigh(metaDAOFeeBps, maxMetaDAO);

        (uint16 protocolFeeBps, uint16 labsFeeBps, uint16 resolverFeeBps) = router.getFixedFees();
        uint16 totalFeeBps = protocolFeeBps + labsFeeBps + resolverFeeBps
                           + subDAOFeeBps + metaDAOFeeBps;
        uint16 maxFeeBps = router.BPS_DENOMINATOR() - router.performerFloorBPS();
        if (totalFeeBps > maxFeeBps) revert PerformerFloorViolated(totalFeeBps, maxFeeBps);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @notice Set the DisputeResolver used for all future delivery missions.
     * @dev Must be called before the first createDeliveryMission (audit C2). Applies
     *      to missions created after this call; existing escrows keep their init value.
     * @param _disputeResolver DisputeResolver contract address (non-zero)
     */
    function setDisputeResolver(address _disputeResolver) external onlyOwner {
        if (_disputeResolver == address(0)) revert ZeroAddress();
        disputeResolver = _disputeResolver;
        emit DisputeResolverUpdated(_disputeResolver);
    }

    /**
     * @notice Get the mission id for a given escrow address (0 if unknown).
     * @dev Implements IMissionFactory.getMissionByEscrow — PaymentRouter uses this to
     *      authorize escrows during settlement.
     * @param escrow Escrow contract address
     * @return Mission ID, or 0 if the escrow was not created by this factory
     */
    function getMissionByEscrow(address escrow) external view returns (uint256) {
        return escrowToMission[escrow];
    }

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
     * @notice Get the food/delivery settlement breakdown for a delivery mission
     * @param missionId Mission ID
     * @return Settlement breakdown recorded at creation
     */
    function getSettlement(uint256 missionId)
        external
        view
        returns (DeliveryEscrow.DeliverySettlement memory)
    {
        return DeliveryEscrow(payable(missions[missionId])).getSettlement();
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
