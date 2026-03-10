// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {IMissionFactory} from "./interfaces/IMissionFactory.sol";
import {HorizonToken} from "./token/HorizonToken.sol";

/**
 * @title PaymentRouter
 * @author Horizon Protocol
 * @notice Routes mission payments to various treasuries with inclusive 10% total fee
 * @dev
 * Fee Structure (v2 - Inclusive Model):
 * - Fixed fees: Protocol (2.5%), Labs (2.5%), Resolver (2%) = 7% base
 * - Hierarchy fees: MetaDAO (0-1%), SubDAO (0-2%) = up to 3%
 * - Total platform fee: Always 10% maximum
 * - Performer receives: Always >= performerFloorBPS (default 90%)
 *
 * Multi-token:
 * - USDC and EURC are both accepted (whitelisted in acceptedTokens)
 * - Every settle function takes an explicit `token` address
 * - The caller (MissionEscrow or SETTLER_ROLE holder) specifies which token to distribute
 * - Admin can add/remove accepted tokens via setAcceptedToken()
 *
 * Security model:
 * - SETTLER_ROLE: Required to call settle* functions (granted to MissionEscrow clones)
 * - PAUSER_ROLE: Can pause/unpause settlements (multi-sig)
 * - FEE_MANAGER_ROLE: Can adjust performerFloorBPS within bounds
 * - DEFAULT_ADMIN_ROLE: Can manage roles, treasury addresses, and accepted tokens
 *
 * ⚠️ SYNC: Fee constants must match packages/shared/src/constants/fees.ts
 * Run: forge test --match-test testConstantsMatch
 */
contract PaymentRouter is AccessControl, Pausable, ReentrancyGuard, IPaymentRouter {
    using SafeERC20 for IERC20;

    // =============================================================================
    // ROLES
    // =============================================================================

    /// @notice Role required to call settlement functions
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    /// @notice Role required to pause/unpause the contract
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role required to adjust performer floor
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // =============================================================================
    // CONSTANTS
    // =============================================================================

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Protocol fee: 2.5% (250 bps) - Platform sustainability
    uint16 public constant PROTOCOL_FEE_BPS = 250;

    /// @notice Labs fee: 2.5% (250 bps) - R&D and development
    uint16 public constant LABS_FEE_BPS = 250;

    /// @notice Resolver fee: 2% (200 bps) - Dispute resolution pool
    uint16 public constant RESOLVER_FEE_BPS = 200;

    /// @notice Maximum SubDAO fee: 2% (200 bps)
    uint16 public constant MAX_SUBDAO_FEE_BPS = 200;

    /// @notice Maximum MetaDAO fee: 1% (100 bps)
    uint16 public constant MAX_METADAO_FEE_BPS = 100;

    /// @notice Absolute minimum for performer floor (hardcoded safety net)
    uint16 public constant MIN_PERFORMER_FLOOR_BPS = 8500;

    /// @notice Legacy constant kept for backward compatibility (read-only)
    /// @dev Do NOT use for fee validation — use _maxGuildFeeBPS() instead
    uint16 public constant BASE_PERFORMER_BPS = 9000;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Whitelist of accepted payment tokens (USDC, EURC, etc.)
    mapping(address => bool) public acceptedTokens;

    /// @notice Treasury addresses
    address public protocolTreasury;
    address public resolverTreasury;
    address public labsTreasury;

    /// @notice Mapping of guild addresses to their treasury addresses
    mapping(address => address) public guildTreasuries;

    /// @notice MissionFactory address for authorization
    address public missionFactory;

    /// @notice Governable performer floor (default 90%, adjustable by FEE_MANAGER_ROLE)
    uint16 public performerFloorBPS = 9000;

    // ---- TOKEN-5: HRZN discount integration ----
    /// @notice HRZN governance token (optional — set via setHRZNToken)
    HorizonToken public hrzn;

    /// @notice Protocol fee discount when paying/burning HRZN: 25% off the protocol fee
    uint16 public constant HRZN_DISCOUNT_BPS = 2500;

    event PaymentSettledWithDiscount(
        uint256 indexed missionId,
        address indexed performer,
        uint256 discountAmount,
        uint256 hrznBurned
    );

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /**
     * @notice Deploy the PaymentRouter
     * @param _usdc USDC token address (initial accepted token)
     * @param _protocolTreasury Protocol treasury address
     * @param _resolverTreasury Resolver treasury address
     * @param _labsTreasury Labs treasury address
     * @param _admin Admin address (receives DEFAULT_ADMIN_ROLE and PAUSER_ROLE)
     */
    constructor(
        address _usdc,
        address _protocolTreasury,
        address _resolverTreasury,
        address _labsTreasury,
        address _admin
    ) {
        if (_usdc == address(0)) revert InvalidTreasury();
        if (_protocolTreasury == address(0)) revert InvalidTreasury();
        if (_resolverTreasury == address(0)) revert InvalidTreasury();
        if (_labsTreasury == address(0)) revert InvalidTreasury();
        if (_admin == address(0)) revert InvalidTreasury();

        acceptedTokens[_usdc] = true;
        emit AcceptedTokenUpdated(_usdc, true);

        protocolTreasury = _protocolTreasury;
        resolverTreasury = _resolverTreasury;
        labsTreasury = _labsTreasury;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
    }

    // =============================================================================
    // PAUSE CONTROL
    // =============================================================================

    /// @notice Pause all settlement functions
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause all settlement functions
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =============================================================================
    // PAYMENT SETTLEMENT
    // =============================================================================

    /**
     * @notice Settle payment for a completed mission
     * @param missionId The mission ID (for event emission)
     * @param performer The performer address
     * @param token The payment token (USDC or EURC)
     * @param rewardAmount Total reward amount
     * @param guild Guild address (address(0) if none)
     */
    function settlePayment(
        uint256 missionId,
        address performer,
        address token,
        uint256 rewardAmount,
        address guild
    ) external nonReentrant onlyAuthorizedSettler whenNotPaused {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);

        // Get guild fee (0 if no guild)
        uint16 guildFeeBps = 0;
        if (guild != address(0)) {
            guildFeeBps = getGuildFeeBps(guild);
        }

        // Enforce performer floor (auto-caps guild fee if needed)
        guildFeeBps = _enforcePerformerFloor(guildFeeBps);

        FeeSplit memory split = _calculateSplit(rewardAmount, guild, guildFeeBps);

        _distributeFeeSplit(IERC20(token), performer, guild, split);

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
     * @param token The payment token (USDC or EURC)
     * @param rewardAmount Total reward amount
     * @param guild Guild address
     * @param guildFeeBps Guild fee in basis points (set when mission was curated)
     */
    function settlePaymentWithGuildFee(
        uint256 missionId,
        address performer,
        address token,
        uint256 rewardAmount,
        address guild,
        uint16 guildFeeBps
    ) external nonReentrant onlyAuthorizedSettler whenNotPaused {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);

        // Enforce performer floor (auto-caps guild fee if needed)
        guildFeeBps = _enforcePerformerFloor(guildFeeBps);

        FeeSplit memory split = _calculateSplit(rewardAmount, guild, guildFeeBps);

        _distributeFeeSplit(IERC20(token), performer, guild, split);

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
     * @notice Settle payment with full MetaDAO/SubDAO hierarchy
     * @dev Used for iTake and similar verticals with two-tier guild structure
     * @param missionId The mission ID
     * @param performer The performer address
     * @param token The payment token (USDC or EURC)
     * @param rewardAmount Total reward amount
     * @param subDAO SubDAO address (e.g., restaurant)
     * @param metaDAO MetaDAO address (e.g., iTake)
     * @param subDAOFeeBps SubDAO fee in basis points
     * @param metaDAOFeeBps MetaDAO fee in basis points
     */
    function settlePaymentWithHierarchy(
        uint256 missionId,
        address performer,
        address token,
        uint256 rewardAmount,
        address subDAO,
        address metaDAO,
        uint16 subDAOFeeBps,
        uint16 metaDAOFeeBps
    ) external nonReentrant onlyAuthorizedSettler whenNotPaused {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);
        if (subDAOFeeBps > MAX_SUBDAO_FEE_BPS) {
            revert InvalidFeeConfig();
        }
        if (metaDAOFeeBps > MAX_METADAO_FEE_BPS) {
            revert InvalidFeeConfig();
        }

        // Ensure total fees never exceed complement of performer floor
        uint16 totalFees = PROTOCOL_FEE_BPS + LABS_FEE_BPS + RESOLVER_FEE_BPS
                          + metaDAOFeeBps + subDAOFeeBps;
        uint16 maxFees = BPS_DENOMINATOR - performerFloorBPS;
        if (totalFees > maxFees) {
            revert InvalidFeeConfig();
        }

        IERC20 _token = IERC20(token);
        FeeSplitWithHierarchy memory split = _calculateHierarchySplit(
            rewardAmount,
            subDAOFeeBps,
            metaDAOFeeBps
        );

        if (split.performerAmount > 0) _token.safeTransfer(performer, split.performerAmount);
        if (split.protocolAmount > 0) _token.safeTransfer(protocolTreasury, split.protocolAmount);
        if (split.labsAmount > 0) _token.safeTransfer(labsTreasury, split.labsAmount);
        if (split.resolverAmount > 0) _token.safeTransfer(resolverTreasury, split.resolverAmount);

        if (split.metaDAOAmount > 0 && metaDAO != address(0)) {
            address metaDAOTreasury = guildTreasuries[metaDAO];
            if (metaDAOTreasury == address(0)) metaDAOTreasury = metaDAO;
            _token.safeTransfer(metaDAOTreasury, split.metaDAOAmount);
        }

        if (split.subDAOAmount > 0 && subDAO != address(0)) {
            address subDAOTreasury = guildTreasuries[subDAO];
            if (subDAOTreasury == address(0)) subDAOTreasury = subDAO;
            _token.safeTransfer(subDAOTreasury, split.subDAOAmount);
        }

        emit PaymentSettledWithHierarchy(
            missionId,
            performer,
            split.performerAmount,
            split.protocolAmount,
            split.labsAmount,
            split.resolverAmount,
            split.metaDAOAmount,
            split.subDAOAmount
        );
    }

    /**
     * @notice Settle a restaurant delivery order with correct payment split
     * @dev Food cost is transferred directly to the restaurant treasury.
     *      Only the delivery fee is routed through the fee hierarchy.
     *      This ensures the restaurant is fully paid for food and the courier
     *      earns their share of the delivery fee only.
     * @param missionId The mission ID (for event emission)
     * @param performer The courier address
     * @param token The payment token (USDC or EURC)
     * @param foodCost Amount to transfer directly to the restaurant (full food cost)
     * @param deliveryFee Amount to split through the fee hierarchy (courier earns ~90.5%)
     * @param restaurantDAO Restaurant SubDAO address
     * @param metaDAO MetaDAO address (e.g., iTake)
     * @param subDAOFeeBps Restaurant's share of delivery fee in basis points (max 2%)
     * @param metaDAOFeeBps MetaDAO's share of delivery fee in basis points (max 1%)
     */
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
    ) external nonReentrant onlyAuthorizedSettler whenNotPaused {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);
        if (subDAOFeeBps > MAX_SUBDAO_FEE_BPS) revert InvalidFeeConfig();
        if (metaDAOFeeBps > MAX_METADAO_FEE_BPS) revert InvalidFeeConfig();

        uint16 totalDeliveryFees = PROTOCOL_FEE_BPS + LABS_FEE_BPS + RESOLVER_FEE_BPS
                                  + metaDAOFeeBps + subDAOFeeBps;
        if (totalDeliveryFees > BPS_DENOMINATOR - performerFloorBPS) revert InvalidFeeConfig();

        IERC20 _token = IERC20(token);

        // Step 1: Transfer food cost directly to restaurant treasury
        if (foodCost > 0 && restaurantDAO != address(0)) {
            address restaurantTreasury = guildTreasuries[restaurantDAO];
            if (restaurantTreasury == address(0)) restaurantTreasury = restaurantDAO;
            _token.safeTransfer(restaurantTreasury, foodCost);
        }

        // Step 2: Split delivery fee through hierarchy (courier + protocol + guild fees)
        FeeSplitWithHierarchy memory split = _calculateHierarchySplit(
            deliveryFee,
            subDAOFeeBps,
            metaDAOFeeBps
        );

        if (split.performerAmount > 0) _token.safeTransfer(performer, split.performerAmount);
        if (split.protocolAmount > 0) _token.safeTransfer(protocolTreasury, split.protocolAmount);
        if (split.labsAmount > 0) _token.safeTransfer(labsTreasury, split.labsAmount);
        if (split.resolverAmount > 0) _token.safeTransfer(resolverTreasury, split.resolverAmount);

        if (split.metaDAOAmount > 0 && metaDAO != address(0)) {
            address metaDAOTreasury = guildTreasuries[metaDAO];
            if (metaDAOTreasury == address(0)) metaDAOTreasury = metaDAO;
            _token.safeTransfer(metaDAOTreasury, split.metaDAOAmount);
        }
        if (split.subDAOAmount > 0 && restaurantDAO != address(0)) {
            address subDAOTreasury = guildTreasuries[restaurantDAO];
            if (subDAOTreasury == address(0)) subDAOTreasury = restaurantDAO;
            _token.safeTransfer(subDAOTreasury, split.subDAOAmount);
        }

        emit RestaurantOrderSettled(
            missionId,
            performer,
            foodCost,
            split.performerAmount,
            split.protocolAmount,
            split.labsAmount,
            split.resolverAmount,
            split.metaDAOAmount,
            split.subDAOAmount
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
    function getFeeSplit(
        uint256 rewardAmount,
        address guild,
        uint16 guildFeeBps
    ) external pure returns (FeeSplit memory split) {
        return _calculateSplit(rewardAmount, guild, guildFeeBps);
    }

    /**
     * @notice Get fee split without guild (backward compatibility)
     */
    function getFeeSplit(
        uint256 rewardAmount,
        bool hasGuild
    ) external view returns (FeeSplit memory split) {
        address guild = hasGuild ? address(1) : address(0);
        uint16 guildFeeBps = hasGuild ? 300 : 0; // Default 3% for compatibility
        return _calculateSplit(rewardAmount, guild, guildFeeBps);
    }

    /**
     * @notice Get fixed fee configuration
     */
    function getFixedFees() external pure returns (
        uint16 protocolFeeBps,
        uint16 labsFeeBps,
        uint16 resolverFeeBps
    ) {
        return (PROTOCOL_FEE_BPS, LABS_FEE_BPS, RESOLVER_FEE_BPS);
    }

    /**
     * @notice Get guild's default fee (can be overridden per-mission)
     * @dev Guilds should store their fee tiers in their DAO contract
     */
    function getGuildFeeBps(address guild) public view returns (uint16) {
        // Default implementation - guilds can override via their DAO
        (guild); // Silence unused variable warning
        return 300; // Default 3%
    }

    /**
     * @notice Get maximum allowed guild fee based on current performer floor
     * @return Maximum guild fee BPS that won't violate performer floor
     */
    function maxGuildFeeBPS() external view returns (uint16) {
        return _maxGuildFeeBPS();
    }

    // =============================================================================
    // FEE MANAGER FUNCTIONS
    // =============================================================================

    /**
     * @notice Update the performer floor BPS
     * @param newFloorBPS New performer floor in basis points
     * @dev Must be >= MIN_PERFORMER_FLOOR_BPS (8500) and <= BPS_DENOMINATOR (10000)
     */
    function setPerformerFloor(uint16 newFloorBPS) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFloorBPS < MIN_PERFORMER_FLOOR_BPS) {
            revert FloorBelowMinimum(newFloorBPS, MIN_PERFORMER_FLOOR_BPS);
        }
        if (newFloorBPS > BPS_DENOMINATOR) {
            revert InvalidFeeConfig();
        }

        uint16 oldFloor = performerFloorBPS;
        performerFloorBPS = newFloorBPS;

        emit PerformerFloorUpdated(oldFloor, newFloorBPS);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Add or remove an accepted payment token
     * @param token Token contract address (e.g., USDC or EURC)
     * @param accepted True to accept, false to reject
     */
    function setAcceptedToken(address token, bool accepted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidTreasury();
        acceptedTokens[token] = accepted;
        emit AcceptedTokenUpdated(token, accepted);
    }

    /**
     * @notice Update protocol treasury address
     */
    function setProtocolTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidTreasury();
        protocolTreasury = _treasury;
        emit TreasuryUpdated("protocol", _treasury);
    }

    /**
     * @notice Update resolver treasury address
     */
    function setResolverTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidTreasury();
        resolverTreasury = _treasury;
        emit TreasuryUpdated("resolver", _treasury);
    }

    /**
     * @notice Update labs treasury address
     */
    function setLabsTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidTreasury();
        labsTreasury = _treasury;
        emit TreasuryUpdated("labs", _treasury);
    }

    /**
     * @notice Set guild treasury address
     * @param guild Guild address
     * @param treasury Treasury address for the guild
     */
    function setGuildTreasury(address guild, address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        guildTreasuries[guild] = treasury;
        emit TreasuryUpdated("guild", treasury);
    }

    /**
     * @notice Set mission factory address
     */
    function setMissionFactory(address _factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        missionFactory = _factory;
    }

    // ---- TOKEN-5: HRZN discount functions ----

    /// @notice Set the HRZN token address (admin only)
    function setHRZNToken(address _hrzn) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hrzn = HorizonToken(_hrzn);
    }

    /// @notice Returns the discounted protocol fee (in stablecoin units) when paying with HRZN
    /// @param amount The total reward amount being settled
    /// @return discountedFee The protocol fee after applying the HRZN discount
    /// @return discount      The discount amount that would be saved
    function getHrznDiscountedFee(uint256 amount)
        public
        view
        returns (uint256 discountedFee, uint256 discount)
    {
        uint256 normalFee = (amount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        discount = (normalFee * HRZN_DISCOUNT_BPS) / BPS_DENOMINATOR;
        discountedFee = normalFee - discount;
    }

    // TODO(TOKEN-5): Full settlePaymentWithHRZN() implementation — requires audit before mainnet
    // The discount mechanic: caller burns HRZN = discount amount, protocol fee reduced by 25%
    // See docs/token/tokenomics.md for full design

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    /**
     * @notice Authorize settlement calls from SETTLER_ROLE holders or escrow clones
     * @dev An escrow clone deployed by MissionFactory is auto-authorized.
     *      For direct calls (e.g. from admin tooling), SETTLER_ROLE can be granted.
     */
    modifier onlyAuthorizedSettler() {
        if (!hasRole(SETTLER_ROLE, msg.sender) && !_isFactoryEscrow(msg.sender)) {
            revert OnlyMissionEscrow();
        }
        _;
    }

    /**
     * @notice Check if address is a factory-deployed escrow
     */
    function _isFactoryEscrow(address caller) internal view returns (bool) {
        if (missionFactory == address(0)) return false;
        try IMissionFactory(missionFactory).getMissionByEscrow(caller) returns (uint256 missionId) {
            return missionId > 0;
        } catch {
            return false;
        }
    }

    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================

    /**
     * @notice Calculate max guild fee BPS that protects performer floor
     * @return Maximum guild fee in basis points
     */
    function _maxGuildFeeBPS() internal view returns (uint16) {
        uint16 fixedFees = PROTOCOL_FEE_BPS + LABS_FEE_BPS + RESOLVER_FEE_BPS;
        uint16 maxTotal = BPS_DENOMINATOR - performerFloorBPS;
        if (maxTotal <= fixedFees) {
            return 0;
        }
        return maxTotal - fixedFees;
    }

    /**
     * @notice Enforce performer floor by auto-capping guild fee
     * @param requestedGuildFeeBps Requested guild fee in basis points
     * @return effective Guild fee after enforcement
     * @dev Emits GuildFeeCapped if fee is reduced. Reverts only if fixed fees alone
     *      exceed the complement of the floor (which indicates a config error).
     */
    function _enforcePerformerFloor(uint16 requestedGuildFeeBps) internal returns (uint16 effective) {
        uint16 maxGuild = _maxGuildFeeBPS();

        if (requestedGuildFeeBps <= maxGuild) {
            return requestedGuildFeeBps;
        }

        // Auto-cap guild fee
        emit GuildFeeCapped(requestedGuildFeeBps, maxGuild);
        return maxGuild;
    }

    /**
     * @notice Calculate fee split for standard settlement
     */
    function _calculateSplit(
        uint256 rewardAmount,
        address guild,
        uint16 guildFeeBps
    ) internal pure returns (FeeSplit memory split) {
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

        // Performer gets the rest
        split.performerAmount = rewardAmount - split.protocolAmount - split.labsAmount - split.resolverAmount - split.guildAmount;
    }

    /**
     * @notice Calculate fee split for MetaDAO hierarchy
     */
    function _calculateHierarchySplit(
        uint256 rewardAmount,
        uint16 subDAOFeeBps,
        uint16 metaDAOFeeBps
    ) internal pure returns (FeeSplitWithHierarchy memory split) {
        // Fixed fees
        split.protocolAmount = (rewardAmount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        split.labsAmount = (rewardAmount * LABS_FEE_BPS) / BPS_DENOMINATOR;
        split.resolverAmount = (rewardAmount * RESOLVER_FEE_BPS) / BPS_DENOMINATOR;

        // Hierarchy fees
        split.metaDAOAmount = (rewardAmount * metaDAOFeeBps) / BPS_DENOMINATOR;
        split.subDAOAmount = (rewardAmount * subDAOFeeBps) / BPS_DENOMINATOR;

        // Performer gets the rest
        split.performerAmount = rewardAmount
            - split.protocolAmount
            - split.labsAmount
            - split.resolverAmount
            - split.metaDAOAmount
            - split.subDAOAmount;
    }

    /**
     * @notice Distribute FeeSplit to all recipients
     */
    function _distributeFeeSplit(
        IERC20 token,
        address performer,
        address guild,
        FeeSplit memory split
    ) internal {
        if (split.performerAmount > 0) token.safeTransfer(performer, split.performerAmount);
        if (split.protocolAmount > 0) token.safeTransfer(protocolTreasury, split.protocolAmount);

        if (split.guildAmount > 0 && guild != address(0)) {
            address guildTreasury = guildTreasuries[guild];
            if (guildTreasury == address(0)) guildTreasury = guild;
            token.safeTransfer(guildTreasury, split.guildAmount);
        }

        if (split.resolverAmount > 0) token.safeTransfer(resolverTreasury, split.resolverAmount);
        if (split.labsAmount > 0) token.safeTransfer(labsTreasury, split.labsAmount);
    }
}
