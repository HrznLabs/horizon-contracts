// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPaymentRouter } from "./interfaces/IPaymentRouter.sol";

/**
 * @title PaymentRouter
 * @author Horizon Protocol
 * @notice Routes mission payments to various treasuries with fixed + variable fees
 * @dev
 * Fee Structure:
 * - Fixed fees: Protocol (4%), Labs (4%), Resolver (2%) = 10% total
 * - Variable fee: Guild fee set per-guild when mission is curated
 * - Performer receives: 90% - guildFee
 *
 * Protocol and Labs fees are equal and higher than Resolver fee.
 * Guild fee is dynamic, defined by each guild's governance.
 */
contract PaymentRouter is Ownable, ReentrancyGuard, IPaymentRouter {
    using SafeERC20 for IERC20;

    // =============================================================================
    // CONSTANTS
    // =============================================================================

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Protocol fee: 4% (400 bps) - Platform sustainability
    uint16 public constant PROTOCOL_FEE_BPS = 400;

    /// @notice Labs fee: 4% (400 bps) - R&D and development
    uint16 public constant LABS_FEE_BPS = 400;

    /// @notice Resolver fee: 2% (200 bps) - Dispute resolution pool
    uint16 public constant RESOLVER_FEE_BPS = 200;

    /// @notice Maximum guild fee: 15% (1500 bps)
    uint16 public constant MAX_GUILD_FEE_BPS = 1500;

    /// @notice Base performer percentage before guild fee: 90% (9000 bps)
    uint16 public constant BASE_PERFORMER_BPS = 9000;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice Treasury addresses
    address public protocolTreasury;
    address public resolverTreasury;
    address public labsTreasury;

    /// @notice Mapping of guild addresses to their treasury addresses
    mapping(address => address) public guildTreasuries;

    /// @notice MissionFactory address for authorization
    address public missionFactory;

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /**
     * @notice Deploy the PaymentRouter
     * @param _usdc USDC token address
     * @param _protocolTreasury Protocol treasury address
     * @param _resolverTreasury Resolver treasury address
     * @param _labsTreasury Labs treasury address
     */
    constructor(
        address _usdc,
        address _protocolTreasury,
        address _resolverTreasury,
        address _labsTreasury
    ) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        protocolTreasury = _protocolTreasury;
        resolverTreasury = _resolverTreasury;
        labsTreasury = _labsTreasury;
    }

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier onlyAuthorized() {
        // In production, verify caller is a valid MissionEscrow
        // For now, allow any caller for testing
        _;
    }

    // =============================================================================
    // PAYMENT SETTLEMENT
    // =============================================================================

    /**
     * @notice Settle payment for a completed mission
     * @param missionId The mission ID (for event emission)
     * @param performer The performer address
     * @param rewardAmount Total reward amount
     * @param guild Guild address (address(0) if none)
     */
    function settlePayment(
        uint256 missionId,
        address performer,
        uint256 rewardAmount,
        address guild
    ) external nonReentrant onlyAuthorized {
        // Get guild fee (0 if no guild)
        uint16 guildFeeBps = 0;
        if (guild != address(0)) {
            guildFeeBps = getGuildFeeBps(guild);
        }

        FeeSplit memory split = _calculateSplit(rewardAmount, guild, guildFeeBps);

        // Transfer to performer
        if (split.performerAmount > 0) {
            usdc.safeTransfer(performer, split.performerAmount);
        }

        // Transfer to protocol treasury
        if (split.protocolAmount > 0) {
            usdc.safeTransfer(protocolTreasury, split.protocolAmount);
        }

        // Transfer to guild treasury
        if (split.guildAmount > 0 && guild != address(0)) {
            address guildTreasury = guildTreasuries[guild];
            if (guildTreasury == address(0)) {
                guildTreasury = guild; // Default to guild address
            }
            usdc.safeTransfer(guildTreasury, split.guildAmount);
        }

        // Transfer to resolver treasury
        if (split.resolverAmount > 0) {
            usdc.safeTransfer(resolverTreasury, split.resolverAmount);
        }

        // Transfer to labs treasury
        if (split.labsAmount > 0) {
            usdc.safeTransfer(labsTreasury, split.labsAmount);
        }

        emit PaymentSettled(
            missionId,
            performer,
            split.performerAmount,
            split.protocolAmount,
            split.guildAmount,
            split.resolverAmount,
            split.labsAmount
        );
    }

    /**
     * @notice Settle payment with explicit guild fee (for guild-curated missions)
     * @param missionId The mission ID
     * @param performer The performer address
     * @param rewardAmount Total reward amount
     * @param guild Guild address
     * @param guildFeeBps Guild fee in basis points (set when mission was curated)
     */
    function settlePaymentWithGuildFee(
        uint256 missionId,
        address performer,
        uint256 rewardAmount,
        address guild,
        uint16 guildFeeBps
    ) external nonReentrant onlyAuthorized {
        if (guildFeeBps > MAX_GUILD_FEE_BPS) {
            revert InvalidFeeConfig();
        }

        FeeSplit memory split = _calculateSplit(rewardAmount, guild, guildFeeBps);

        // Transfer to performer
        if (split.performerAmount > 0) {
            usdc.safeTransfer(performer, split.performerAmount);
        }

        // Transfer to protocol treasury
        if (split.protocolAmount > 0) {
            usdc.safeTransfer(protocolTreasury, split.protocolAmount);
        }

        // Transfer to guild treasury
        if (split.guildAmount > 0 && guild != address(0)) {
            address guildTreasury = guildTreasuries[guild];
            if (guildTreasury == address(0)) {
                guildTreasury = guild;
            }
            usdc.safeTransfer(guildTreasury, split.guildAmount);
        }

        // Transfer to resolver treasury
        if (split.resolverAmount > 0) {
            usdc.safeTransfer(resolverTreasury, split.resolverAmount);
        }

        // Transfer to labs treasury
        if (split.labsAmount > 0) {
            usdc.safeTransfer(labsTreasury, split.labsAmount);
        }

        emit PaymentSettled(
            missionId,
            performer,
            split.performerAmount,
            split.protocolAmount,
            split.guildAmount,
            split.resolverAmount,
            split.labsAmount
        );
    }

    // =============================================================================
    // FEE CALCULATION
    // =============================================================================

    /**
     * @notice Calculate fee split for a given reward amount
     * @param rewardAmount Total reward amount
     * @param guild Guild address (or address(0))
     * @param guildFeeBps Guild fee in basis points
     * @return split The calculated fee split
     */
    function getFeeSplit(uint256 rewardAmount, address guild, uint16 guildFeeBps)
        external
        pure
        returns (FeeSplit memory split)
    {
        return _calculateSplit(rewardAmount, guild, guildFeeBps);
    }

    /**
     * @notice Get fee split without guild (backward compatibility)
     */
    function getFeeSplit(uint256 rewardAmount, bool hasGuild)
        external
        view
        returns (FeeSplit memory split)
    {
        address guild = hasGuild ? address(1) : address(0);
        uint16 guildFeeBps = hasGuild ? 300 : 0; // Default 3% for compatibility
        return _calculateSplit(rewardAmount, guild, guildFeeBps);
    }

    function _calculateSplit(uint256 rewardAmount, address guild, uint16 guildFeeBps)
        internal
        pure
        returns (FeeSplit memory split)
    {
        bool hasGuild = guild != address(0);

        // Fixed fees (always applied)
        split.protocolAmount = (rewardAmount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        split.labsAmount = (rewardAmount * LABS_FEE_BPS) / BPS_DENOMINATOR;
        split.resolverAmount = (rewardAmount * RESOLVER_FEE_BPS) / BPS_DENOMINATOR;

        // Variable guild fee
        if (hasGuild && guildFeeBps > 0) {
            split.guildAmount = (rewardAmount * guildFeeBps) / BPS_DENOMINATOR;
        } else {
            split.guildAmount = 0;
        }

        // Performer gets base 90% minus guild fee
        // Performer = 90% - guildFee = reward - protocolFee - labsFee - resolverFee - guildFee
        split.performerAmount = rewardAmount - split.protocolAmount - split.labsAmount
            - split.resolverAmount - split.guildAmount;
    }

    /**
     * @notice Get guild's default fee (can be overridden per-mission)
     * @dev Guilds should store their fee tiers in their DAO contract
     */
    function getGuildFeeBps(address guild) public view returns (uint16) {
        // Default implementation - guilds can override via their DAO
        // In practice, this would query the GuildDAO contract
        (guild); // Silence unused variable warning
        return 300; // Default 3%
    }

    /**
     * @notice Get fixed fee configuration
     */
    function getFixedFees()
        external
        pure
        returns (uint16 protocolFeeBps, uint16 labsFeeBps, uint16 resolverFeeBps)
    {
        return (PROTOCOL_FEE_BPS, LABS_FEE_BPS, RESOLVER_FEE_BPS);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Update protocol treasury address
     */
    function setProtocolTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasury();
        protocolTreasury = _treasury;
        emit TreasuryUpdated("protocol", _treasury);
    }

    /**
     * @notice Update resolver treasury address
     */
    function setResolverTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasury();
        resolverTreasury = _treasury;
        emit TreasuryUpdated("resolver", _treasury);
    }

    /**
     * @notice Update labs treasury address
     */
    function setLabsTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasury();
        labsTreasury = _treasury;
        emit TreasuryUpdated("labs", _treasury);
    }

    /**
     * @notice Set guild treasury address
     * @param guild Guild address
     * @param treasury Treasury address for the guild
     */
    function setGuildTreasury(address guild, address treasury) external onlyOwner {
        guildTreasuries[guild] = treasury;
        emit TreasuryUpdated("guild", treasury);
    }

    /**
     * @notice Set mission factory address
     */
    function setMissionFactory(address _factory) external onlyOwner {
        missionFactory = _factory;
    }
}
