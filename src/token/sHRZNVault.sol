// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title sHRZNVault
/// @notice ERC-4626 vault for staking HRZN. Depositors earn USDC fee revenue from the protocol.
/// @dev Reward accounting uses a discrete-push model: rewards are added in lump sums via
///      `notifyRewardAmount` (called by FeeDistributor) rather than streamed per-second.
///      Unstaking has a 7-day cooldown to prevent flash-stake attacks. During the cooldown
///      the pending shares are transferred to this contract and held in escrow so they cannot
///      be double-spent or transferred.
contract sHRZNVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // -------------------------------------------------------------------------
    // Reward state (discrete-push model)
    // -------------------------------------------------------------------------
    IERC20 public immutable usdc;

    /// @dev Accumulated reward per share, scaled by 1e30.
    ///      The 1e30 scalar bridges the 12-decimal gap between USDC (6 decimals)
    ///      and sHRZN shares (18 decimals + 3 virtual from _decimalsOffset),
    ///      preventing precision loss on small reward amounts. See HIGH-02.
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // claimable USDC per user

    // -------------------------------------------------------------------------
    // Cooldown state
    // -------------------------------------------------------------------------
    uint256 public constant COOLDOWN_PERIOD = 7 days;

    struct UnstakeRequest {
        uint256 shares;       // sHRZN shares held in escrow during cooldown
        uint256 requestedAt;  // timestamp of request
    }
    mapping(address => UnstakeRequest) public unstakeRequests;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event RewardAdded(uint256 usdcAmount);
    event RewardClaimed(address indexed user, uint256 usdcAmount);
    event UnstakeRequested(address indexed user, uint256 shares);
    event UnstakeCompleted(address indexed user, uint256 hrznAmount);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor(address _hrzn, address _usdc, address _admin)
        ERC4626(IERC20(_hrzn))
        ERC20("Staked Horizon", "sHRZN")
    {
        usdc = IERC20(_usdc);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // -------------------------------------------------------------------------
    // HIGH-01: ERC-4626 inflation attack protection
    // -------------------------------------------------------------------------

    /// @dev Returns a decimal offset of 3, which injects 1_000 virtual shares and
    ///      1_000 virtual assets into the ERC-4626 share-price calculation.
    ///      This makes the classic first-depositor inflation attack uneconomical:
    ///      an attacker would need to donate ~1_000x the victim's deposit to move
    ///      the share price enough to round their deposit to zero. See HIGH-01.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    // -------------------------------------------------------------------------
    // Reward accounting
    // -------------------------------------------------------------------------

    /// @notice Returns the accumulated reward per share stored at the last push.
    /// @dev This vault uses a **discrete-push** reward model, NOT the time-based
    ///      Synthetix streaming model. `rewardPerTokenStored` is updated atomically
    ///      in `notifyRewardAmount` each time the FeeDistributor sends USDC. There
    ///      is no per-block accrual between pushes — calling this function between
    ///      two pushes returns the same value. This is intentional: rewards accrue
    ///      in discrete batches aligned with fee-distribution events. See CRIT-01.
    function rewardPerToken() public view returns (uint256) {
        return rewardPerTokenStored;
    }

    /// @notice Claimable USDC rewards for an account
    /// @dev Divides by 1e30 to reverse the scaling applied in `notifyRewardAmount`.
    ///      The 1e30 scalar corrects for the 12-decimal mismatch between USDC (6)
    ///      and sHRZN shares (18 + 3 virtual). See HIGH-02.
    function earned(address account) public view returns (uint256) {
        return (balanceOf(account) * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / 1e30
            + rewards[account];
    }

    /// @notice Called by FeeDistributor to add USDC rewards for stakers
    /// @param usdcAmount Amount of USDC being added (already transferred to this contract)
    /// @dev Uses a 1e30 scalar instead of 1e18 to preserve precision across the
    ///      12-decimal gap between USDC (6 decimals) and sHRZN shares (18 decimals).
    ///      Without this correction, small USDC reward amounts would lose all
    ///      precision after integer division. See HIGH-02.
    function notifyRewardAmount(uint256 usdcAmount) external onlyRole(DISTRIBUTOR_ROLE) {
        uint256 supply = totalSupply();
        require(supply > 0, "sHRZNVault: no stakers");
        rewardPerTokenStored += (usdcAmount * 1e30) / supply;
        emit RewardAdded(usdcAmount);
    }

    /// @notice Claim accumulated USDC rewards
    function claimRewards() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "sHRZNVault: no rewards");
        rewards[msg.sender] = 0;
        emit RewardClaimed(msg.sender, reward);
        usdc.safeTransfer(msg.sender, reward);
    }

    // -------------------------------------------------------------------------
    // Cooldown unstaking
    // -------------------------------------------------------------------------

    /// @notice Start a 7-day cooldown to unstake shares
    /// @dev Shares are transferred to `address(this)` (escrowed) at request time.
    ///      This prevents double-spending and blocks transfers of pending shares
    ///      during the cooldown period without needing a separate transfer-lock check.
    ///      See MED-04.
    function requestUnstake(uint256 shares) external updateReward(msg.sender) {
        require(shares > 0, "sHRZNVault: zero shares");
        require(balanceOf(msg.sender) >= shares, "sHRZNVault: insufficient shares");
        require(unstakeRequests[msg.sender].shares == 0, "sHRZNVault: pending request");

        unstakeRequests[msg.sender] = UnstakeRequest({shares: shares, requestedAt: block.timestamp});

        // Transfer shares to escrow (this contract) so they cannot be transferred
        // or used to claim rewards during the cooldown period. See MED-04.
        _transfer(msg.sender, address(this), shares);

        emit UnstakeRequested(msg.sender, shares);
    }

    /// @notice Complete unstaking after cooldown period
    function completeUnstake() external nonReentrant updateReward(msg.sender) {
        UnstakeRequest memory req = unstakeRequests[msg.sender];
        require(req.shares > 0, "sHRZNVault: no request");
        require(block.timestamp >= req.requestedAt + COOLDOWN_PERIOD, "sHRZNVault: cooldown active");

        delete unstakeRequests[msg.sender];
        uint256 assets = previewRedeem(req.shares);
        emit UnstakeCompleted(msg.sender, assets);

        // Burn escrowed shares from this contract and release underlying HRZN to user.
        // We call _withdraw with owner=address(this) since the escrowed shares belong
        // to this contract's balance.
        _withdraw(msg.sender, msg.sender, address(this), assets, req.shares);
    }

    // -------------------------------------------------------------------------
    // ERC-4626 overrides — disable direct withdraw (use requestUnstake flow)
    // -------------------------------------------------------------------------

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("sHRZNVault: use requestUnstake");
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("sHRZNVault: use requestUnstake");
    }

    // -------------------------------------------------------------------------
    // Reward modifier
    // -------------------------------------------------------------------------

    modifier updateReward(address account) {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }

    // -------------------------------------------------------------------------
    // ERC20 _update override — reward snapshot + cooldown transfer lock
    // -------------------------------------------------------------------------

    /// @dev Called on every mint, burn, and transfer of sHRZN shares.
    ///
    ///      Reward snapshotting: ensures new depositors cannot claim rewards that
    ///      accrued before their deposit, and departing stakers crystallise their
    ///      earned amount before their balance drops.
    ///
    ///      Cooldown transfer lock (MED-04): blocks outbound transfers from any
    ///      address that has a pending unstake request. This prevents a user from
    ///      circumventing the cooldown by transferring shares to a fresh wallet
    ///      and immediately redeeming from there.
    ///
    ///      Note: transfers FROM address(this) are allowed — that is the escrow
    ///      release path used by `completeUnstake` → `_withdraw`.
    function _update(address from, address to, uint256 value) internal override {
        // MED-04: block outbound transfers from users with pending unstake requests.
        // Exempt address(this) so that escrow-release in completeUnstake is not blocked.
        if (from != address(0) && from != address(this)) {
            require(
                unstakeRequests[from].shares == 0,
                "sHRZNVault: shares locked in cooldown"
            );
        }

        // Snapshot sender rewards before their balance changes
        if (from != address(0)) {
            rewards[from] = earned(from);
            userRewardPerTokenPaid[from] = rewardPerTokenStored;
        }
        // Snapshot receiver rewards before their balance changes
        if (to != address(0)) {
            rewards[to] = earned(to);
            userRewardPerTokenPaid[to] = rewardPerTokenStored;
        }
        super._update(from, to, value);
    }

    // -------------------------------------------------------------------------
    // ERC4626 required override (totalAssets)
    // -------------------------------------------------------------------------

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}
