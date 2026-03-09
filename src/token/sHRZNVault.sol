// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title sHRZNVault
/// @notice ERC-4626 vault for staking HRZN. Depositors earn USDC fee revenue from the protocol.
/// @dev Reward accounting uses the Synthetix rewardPerToken pattern.
///      Unstaking has a 7-day cooldown to prevent flash-stake attacks.
contract sHRZNVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // -------------------------------------------------------------------------
    // Reward state (Synthetix pattern)
    // -------------------------------------------------------------------------
    IERC20 public immutable usdc;

    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // claimable USDC per user

    // -------------------------------------------------------------------------
    // Cooldown state
    // -------------------------------------------------------------------------
    uint256 public constant COOLDOWN_PERIOD = 7 days;

    struct UnstakeRequest {
        uint256 shares;       // sHRZN shares locked for unstaking
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
    // Reward accounting
    // -------------------------------------------------------------------------

    /// @notice Current reward per staked share (scaled by 1e18)
    function rewardPerToken() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored;
    }

    /// @notice Claimable USDC rewards for an account
    function earned(address account) public view returns (uint256) {
        return (balanceOf(account) * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / 1e18
            + rewards[account];
    }

    /// @notice Called by FeeDistributor to add USDC rewards for stakers
    /// @param usdcAmount Amount of USDC being added (already transferred to this contract)
    function notifyRewardAmount(uint256 usdcAmount) external onlyRole(DISTRIBUTOR_ROLE) {
        uint256 supply = totalSupply();
        require(supply > 0, "sHRZNVault: no stakers");
        rewardPerTokenStored += (usdcAmount * 1e18) / supply;
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
    function requestUnstake(uint256 shares) external updateReward(msg.sender) {
        require(shares > 0, "sHRZNVault: zero shares");
        require(balanceOf(msg.sender) >= shares, "sHRZNVault: insufficient shares");
        require(unstakeRequests[msg.sender].shares == 0, "sHRZNVault: pending request");

        unstakeRequests[msg.sender] = UnstakeRequest({shares: shares, requestedAt: block.timestamp});
        // Shares remain in user's balance during cooldown (they can't be transferred)
        emit UnstakeRequested(msg.sender, shares);
    }

    /// @notice Complete unstaking after cooldown period
    function completeUnstake() external nonReentrant updateReward(msg.sender) {
        UnstakeRequest memory req = unstakeRequests[msg.sender];
        require(req.shares > 0, "sHRZNVault: no request");
        require(block.timestamp >= req.requestedAt + COOLDOWN_PERIOD, "sHRZNVault: cooldown active");

        delete unstakeRequests[msg.sender];
        emit UnstakeCompleted(msg.sender, previewRedeem(req.shares));
        _withdraw(msg.sender, msg.sender, msg.sender, previewRedeem(req.shares), req.shares);
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
    // ERC20 _update override — snapshot rewards on every share transfer/mint/burn
    // -------------------------------------------------------------------------

    /// @dev Called on every mint, burn, and transfer of sHRZN shares.
    ///      Snapshotting rewards for both parties ensures new depositors cannot
    ///      claim rewards that accrued before their deposit.
    function _update(address from, address to, uint256 value) internal override {
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
