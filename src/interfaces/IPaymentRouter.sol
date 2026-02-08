// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPaymentRouter
 * @notice Interface for the payment routing contract
 * @dev
 * Fee Structure:
 * - Fixed: Protocol (4%), Labs (4%), Resolver (2%) = 10% total
 * - Variable: Guild fee (0-15%) set when mission is curated
 * - Performer: 90% - guildFee
 */
interface IPaymentRouter {
    // =============================================================================
    // STRUCTS
    // =============================================================================

    /// @notice Breakdown of payment distribution
    struct FeeSplit {
        uint256 performerAmount; // Base 90% minus guild fee
        uint256 protocolAmount; // Fixed 4%
        uint256 guildAmount; // Variable (0-15%)
        uint256 resolverAmount; // Fixed 2%
        uint256 labsAmount; // Fixed 4%
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

    event TreasuryUpdated(string treasuryType, address newAddress);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error InvalidFeeConfig();
    error InvalidTreasury();
    error OnlyMissionEscrow();
    error TransferFailed();

    // =============================================================================
    // FUNCTIONS
    // =============================================================================

    /// @notice Settle payment using default guild fee
    function settlePayment(
        uint256 missionId,
        address performer,
        uint256 rewardAmount,
        address guild
    ) external;

    /// @notice Settle payment with explicit guild fee (for curated missions)
    function settlePaymentWithGuildFee(
        uint256 missionId,
        address performer,
        uint256 rewardAmount,
        address guild,
        uint16 guildFeeBps
    ) external;

    /// @notice Calculate fee split for given parameters
    function getFeeSplit(uint256 rewardAmount, address guild, uint16 guildFeeBps)
        external
        pure
        returns (FeeSplit memory);

    /// @notice Get fee split (backward compatible)
    function getFeeSplit(uint256 rewardAmount, bool hasGuild)
        external
        view
        returns (FeeSplit memory);

    /// @notice Get fixed fee configuration
    function getFixedFees()
        external
        pure
        returns (uint16 protocolFeeBps, uint16 labsFeeBps, uint16 resolverFeeBps);

    /// @notice Get guild's default fee
    function getGuildFeeBps(address guild) external view returns (uint16);
}
