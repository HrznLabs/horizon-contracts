// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IsHRZNVault {
    function notifyRewardAmount(uint256 usdcAmount) external;
    function totalSupply() external view returns (uint256);
}

/// @title FeeDistributor
/// @notice Splits accumulated protocol USDC fees: 40% stakers / 30% guilds / 20% treasury / 10% resolvers.
/// @dev Guild allocation is proportional to their recorded mission volume for the period.
contract FeeDistributor is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant VOLUME_RECORDER_ROLE = keccak256("VOLUME_RECORDER_ROLE");

    IERC20 public immutable usdc;
    IsHRZNVault public immutable vault;
    address public immutable protocolTreasury;
    address public immutable resolverPool;

    // Fee split in basis points (must sum to 10_000)
    uint256 public constant STAKER_BPS   = 4000; // 40%
    uint256 public constant GUILD_BPS    = 3000; // 30%
    uint256 public constant TREASURY_BPS = 2000; // 20%
    uint256 public constant RESOLVER_BPS = 1000; // 10%

    /// @notice Maximum number of guilds that can be registered.
    /// @dev Prevents the guild distribution loop from consuming unbounded gas.
    ///      At 200 guilds the distribute() loop costs ~400k gas, well within block limits.
    uint256 public constant MAX_GUILDS = 200;

    // Guild registry
    address[] public guilds;
    mapping(address => bool) public isRegistered;
    mapping(address => uint256) public guildVolume; // USDC volume this period (6 decimals)
    uint256 public totalGuildVolume;

    // Period tracking
    uint256 public lastDistributionAt;
    uint256 public constant MIN_PERIOD = 7 days;

    event FeesDistributed(
        uint256 totalAmount,
        uint256 stakerAmount,
        uint256 guildTotal,
        uint256 treasuryAmount,
        uint256 resolverAmount
    );
    event GuildPaid(address indexed guild, uint256 amount);
    event GuildVolumeRecorded(address indexed guild, uint256 volume);
    event GuildRegistered(address indexed guild);
    event GuildRemoved(address indexed guild);

    constructor(
        address _usdc,
        address _vault,
        address _protocolTreasury,
        address _resolverPool,
        address _admin
    ) {
        usdc = IERC20(_usdc);
        vault = IsHRZNVault(_vault);
        protocolTreasury = _protocolTreasury;
        resolverPool = _resolverPool;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // -------------------------------------------------------------------------
    // Volume recording (called by PaymentRouter/indexer backend)
    // -------------------------------------------------------------------------

    /// @notice Record USDC mission volume for a guild in the current period
    function recordGuildVolume(address guild, uint256 usdcVolume)
        external onlyRole(VOLUME_RECORDER_ROLE)
    {
        require(isRegistered[guild], "FeeDistributor: guild not registered");
        guildVolume[guild] += usdcVolume;
        totalGuildVolume += usdcVolume;
        emit GuildVolumeRecorded(guild, usdcVolume);
    }

    // -------------------------------------------------------------------------
    // Distribution
    // -------------------------------------------------------------------------

    /// @notice Pull `amount` USDC from treasury and distribute it
    /// @dev Requires prior approval: protocolTreasury must approve this contract
    function distribute(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "FeeDistributor: zero amount");
        require(
            lastDistributionAt == 0 || block.timestamp >= lastDistributionAt + MIN_PERIOD,
            "FeeDistributor: too soon"
        );

        // Pull from treasury
        usdc.safeTransferFrom(protocolTreasury, address(this), amount);
        lastDistributionAt = block.timestamp;

        // Calculate splits
        uint256 stakerAmount   = (amount * STAKER_BPS)   / 10_000;
        uint256 guildTotal     = (amount * GUILD_BPS)    / 10_000;
        uint256 treasuryAmount = (amount * TREASURY_BPS) / 10_000;
        uint256 resolverAmount = amount - stakerAmount - guildTotal - treasuryAmount; // remainder

        // 1. Stakers: transfer USDC to vault and notify.
        //    Audit M3(c): sHRZNVault.notifyRewardAmount() requires totalSupply() > 0, so
        //    with no stakers the whole distribution used to revert and stay blocked until
        //    somebody staked. Fall back to the treasury instead of bricking distribution.
        uint256 stakerPaid = 0;
        if (stakerAmount > 0 && vault.totalSupply() > 0) {
            usdc.safeTransfer(address(vault), stakerAmount);
            vault.notifyRewardAmount(stakerAmount);
            stakerPaid = stakerAmount;
        } else {
            treasuryAmount += stakerAmount;
        }

        // 2. Guilds: proportional to volume
        uint256 guildPaid = 0;
        if (totalGuildVolume > 0) {
            for (uint256 i = 0; i < guilds.length; i++) {
                address guild = guilds[i];
                uint256 vol = guildVolume[guild];
                if (vol == 0) continue;
                uint256 guildShare = (guildTotal * vol) / totalGuildVolume;
                if (guildShare > 0) {
                    guildPaid += guildShare;
                    usdc.safeTransfer(guild, guildShare);
                    emit GuildPaid(guild, guildShare);
                }
            }
            // Audit M3(b): per-guild integer flooring leaves dust behind. Forward the
            // remainder to the treasury instead of letting it accumulate in this contract.
            treasuryAmount += guildTotal - guildPaid;
        } else {
            // No guild volume — send guild portion to treasury
            treasuryAmount += guildTotal;
        }

        // 3. Treasury
        usdc.safeTransfer(protocolTreasury, treasuryAmount);

        // 4. Resolvers
        usdc.safeTransfer(resolverPool, resolverAmount);

        // Reset period volumes
        for (uint256 i = 0; i < guilds.length; i++) {
            delete guildVolume[guilds[i]];
        }
        totalGuildVolume = 0;

        // Report the amounts actually paid out, not the nominal splits: the staker and
        // guild slices may have been redirected to the treasury above.
        emit FeesDistributed(amount, stakerPaid, guildPaid, treasuryAmount, resolverAmount);
    }

    // -------------------------------------------------------------------------
    // Guild management
    // -------------------------------------------------------------------------

    function registerGuild(address guild) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!isRegistered[guild], "FeeDistributor: already registered");
        /// @dev Guard against unbounded loop gas griefing in distribute().
        ///      Capped at MAX_GUILDS to keep per-distribution gas predictable.
        require(guilds.length < MAX_GUILDS, "FeeDistributor: max guilds");
        isRegistered[guild] = true;
        /// @dev Audit M3(a): defensive reset so a re-registered guild can never inherit
        ///      volume recorded during a previous registration.
        delete guildVolume[guild];
        guilds.push(guild);
        emit GuildRegistered(guild);
    }

    function removeGuild(address guild) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isRegistered[guild], "FeeDistributor: not registered");
        isRegistered[guild] = false;

        /// @dev Audit M3(a): the removed guild's volume must leave the denominator too.
        ///      Otherwise `totalGuildVolume` still counts a slice that the distribute()
        ///      loop (which only walks *registered* guilds) can never pay out, stranding
        ///      that USDC in this contract.
        uint256 vol = guildVolume[guild];
        if (vol > 0) {
            totalGuildVolume -= vol;
            delete guildVolume[guild];
        }

        for (uint256 i = 0; i < guilds.length; i++) {
            if (guilds[i] == guild) {
                guilds[i] = guilds[guilds.length - 1];
                guilds.pop();
                break;
            }
        }
        emit GuildRemoved(guild);
    }

    function guildCount() external view returns (uint256) {
        return guilds.length;
    }
}
