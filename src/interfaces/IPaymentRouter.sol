// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPaymentRouter
 * @notice Interface for the payment routing contract
 * @dev
 * Fee Structure (v2 - Inclusive Model):
 * - Fixed: Protocol (2.5%), Labs (2.5%), Resolver (2%) = 7% base
 * - Hierarchy: MetaDAO (0-1%), SubDAO (0-2%) = up to 3%
 * - Total: Always 10% maximum
 * - Performer: Always 90% minimum (governable floor)
 *
 * Multi-token: USDC and EURC are both accepted. Every settle function receives
 * the token address explicitly — the router distributes whatever token it holds.
 */
interface IPaymentRouter {
    // =============================================================================
    // STRUCTS
    // =============================================================================

    /// @notice Breakdown of payment distribution
    struct FeeSplit {
        uint256 performerAmount;  // >= performerFloorBPS of reward
        uint256 protocolAmount;   // Fixed 2.5%
        uint256 guildAmount;      // Variable (auto-capped to protect floor)
        uint256 resolverAmount;   // Fixed 2%
        uint256 labsAmount;       // Fixed 2.5%
    }

    /// @notice Breakdown with MetaDAO hierarchy
    struct FeeSplitWithHierarchy {
        uint256 performerAmount;  // Base minus all fees
        uint256 protocolAmount;   // Fixed 2.5%
        uint256 labsAmount;       // Fixed 2.5%
        uint256 resolverAmount;   // Fixed 2%
        uint256 metaDAOAmount;    // MetaDAO fee (e.g., iTake)
        uint256 subDAOAmount;     // SubDAO fee (e.g., restaurant)
    }

    // =============================================================================
    // EVENTS
    // =============================================================================

    event PaymentSettled(
        uint256 indexed missionId,
        address indexed performer,
        uint256 performerAmount,
        uint256 protocolAmount,
        uint256 guildAmount,
        uint256 resolverAmount,
        uint256 labsAmount
    );

    event PaymentSettledWithHierarchy(
        uint256 indexed missionId,
        address indexed performer,
        uint256 performerAmount,
        uint256 protocolAmount,
        uint256 labsAmount,
        uint256 resolverAmount,
        uint256 metaDAOAmount,
        uint256 subDAOAmount
    );

    /// @notice Emitted when a restaurant order is settled (food cost + delivery fee split)
    event RestaurantOrderSettled(
        uint256 indexed missionId,
        address indexed performer,
        uint256 foodCostToRestaurant,
        uint256 performerAmount,
        uint256 protocolAmount,
        uint256 labsAmount,
        uint256 resolverAmount,
        uint256 metaDAOAmount,
        uint256 subDAOAmount
    );

    event TreasuryUpdated(string treasuryType, address newAddress);

    /// @notice Emitted when guild fee is auto-capped to protect performer floor
    event GuildFeeCapped(uint16 requested, uint16 effective);

    /// @notice Emitted when performer floor BPS is updated
    event PerformerFloorUpdated(uint16 oldFloor, uint16 newFloor);

    /// @notice Emitted when a token is added or removed from the accepted list
    event AcceptedTokenUpdated(address indexed token, bool accepted);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidFeeConfig();
    error InvalidTreasury();
    error OnlyMissionEscrow();
    error TransferFailed();
    error TokenNotAccepted(address token);

    /// @notice Fixed fees alone exceed complement of performer floor (config error)
    error PerformerFloorViolation(uint16 actual, uint16 minimum);

    /// @notice Attempted to set floor below absolute minimum
    error FloorBelowMinimum(uint16 requested, uint16 minimum);

    // =============================================================================
    // FUNCTIONS
    // =============================================================================

    /// @notice Returns true if the given token is accepted by this router
    function acceptedTokens(address token) external view returns (bool);

    /// @notice Settle payment using default guild fee
    function settlePayment(
        uint256 missionId,
        address performer,
        address token,
        uint256 rewardAmount,
        address guild
    ) external;

    /// @notice Settle payment with explicit guild fee (for curated missions)
    function settlePaymentWithGuildFee(
        uint256 missionId,
        address performer,
        address token,
        uint256 rewardAmount,
        address guild,
        uint16 guildFeeBps
    ) external;

    /// @notice Calculate fee split for given parameters
    function getFeeSplit(
        uint256 rewardAmount,
        address guild,
        uint16 guildFeeBps
    ) external pure returns (FeeSplit memory);

    /// @notice Get fee split (backward compatible)
    function getFeeSplit(
        uint256 rewardAmount,
        bool hasGuild
    ) external view returns (FeeSplit memory);

    /// @notice Get fixed fee configuration
    function getFixedFees() external pure returns (
        uint16 protocolFeeBps,
        uint16 labsFeeBps,
        uint16 resolverFeeBps
    );

    /// @notice Get guild's default fee
    function getGuildFeeBps(address guild) external view returns (uint16);

    /// @notice Settle payment with full MetaDAO/SubDAO hierarchy
    function settlePaymentWithHierarchy(
        uint256 missionId,
        address performer,
        address token,
        uint256 rewardAmount,
        address subDAO,
        address metaDAO,
        uint16 subDAOFeeBps,
        uint16 metaDAOFeeBps
    ) external;

    /// @notice Settle a restaurant order: food cost goes directly to restaurant, delivery fee splits through hierarchy
    function settleRestaurantOrder(
        uint256 missionId,
        address performer,
        address token,
        uint256 foodCost,
        uint256 deliveryFee,
        address restaurantDAO,
        address metaDAO,
        uint16 subDAOFeeBps,
        uint16 metaDAOFeeBps
    ) external;
}
