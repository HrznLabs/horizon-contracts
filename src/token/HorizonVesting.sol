// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title HorizonVesting
/// @notice Cliff + linear vesting schedule for any ERC-20 token.
/// @dev Tokens are held by this contract. The beneficiary calls `release()` to claim
///      vested tokens after the cliff. The owner (admin) may call `revoke()` to cancel
///      unvested tokens and return them to the treasury.
contract HorizonVesting is Ownable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Immutable configuration
    // -------------------------------------------------------------------------

    /// @notice The ERC-20 token being vested.
    IERC20 public immutable token;

    /// @notice The address that receives vested tokens.
    address public immutable beneficiary;

    /// @notice The address that receives unvested tokens on revocation.
    address public immutable treasury;

    /// @notice Unix timestamp at which vesting starts.
    uint64 public immutable start;

    /// @notice Unix timestamp at which the cliff ends (no tokens vest before this).
    uint64 public immutable cliff;

    /// @notice Total duration of the vesting schedule in seconds from `start`.
    uint64 public immutable duration;

    // -------------------------------------------------------------------------
    // Mutable state
    // -------------------------------------------------------------------------

    /// @notice Cumulative amount of tokens already released to the beneficiary.
    uint256 public released;

    /// @notice Whether the vesting schedule has been revoked by the owner.
    bool public revoked;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event TokensReleased(uint256 amount);
    event VestingRevoked(uint256 returnedToTreasury);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _token           Address of the ERC-20 token to vest.
    /// @param _beneficiary     Recipient of vested tokens.
    /// @param _treasury        Recipient of unvested tokens on revocation.
    /// @param _owner           Owner allowed to revoke; passed to Ownable.
    /// @param _start           Unix timestamp when vesting starts.
    /// @param _cliffDuration   Seconds from `_start` until the cliff ends.
    /// @param _totalDuration   Total seconds of the vesting schedule from `_start`.
    constructor(
        address _token,
        address _beneficiary,
        address _treasury,
        address _owner,
        uint64 _start,
        uint64 _cliffDuration,
        uint64 _totalDuration
    ) Ownable(_owner) {
        require(_cliffDuration < _totalDuration, "HorizonVesting: cliff >= duration");
        require(_beneficiary != address(0), "HorizonVesting: zero beneficiary");
        require(_treasury != address(0), "HorizonVesting: zero treasury");

        token = IERC20(_token);
        beneficiary = _beneficiary;
        treasury = _treasury;
        start = _start;
        cliff = _start + _cliffDuration;
        duration = _totalDuration;
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Calculates the cumulative amount vested at a given timestamp.
    /// @param timestamp The point in time to evaluate (use block.timestamp for current).
    /// @return The total amount vested up to `timestamp` (not yet accounting for releases).
    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + released;
        if (timestamp < cliff || revoked) return 0;
        if (timestamp >= start + duration) return total;
        return (total * (timestamp - start)) / duration;
    }

    /// @notice Returns the amount currently claimable by the beneficiary.
    function releasable() public view returns (uint256) {
        uint256 vested = vestedAmount(uint64(block.timestamp));
        return vested > released ? vested - released : 0;
    }

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Releases all currently claimable tokens to the beneficiary.
    /// @dev Only the beneficiary may call this function.
    function release() external {
        require(msg.sender == beneficiary, "HorizonVesting: not beneficiary");
        uint256 amount = releasable();
        require(amount > 0, "HorizonVesting: nothing to release");
        released += amount;
        emit TokensReleased(amount);
        token.safeTransfer(beneficiary, amount);
    }

    /// @notice Revokes the vesting schedule.
    /// @dev Any tokens that have vested but not yet been released remain claimable.
    ///      All unvested tokens are transferred immediately to `treasury`.
    ///      After revocation, `vestedAmount()` returns 0 for future timestamps.
    function revoke() external onlyOwner {
        require(!revoked, "HorizonVesting: already revoked");
        revoked = true;

        // Compute how many tokens are vested-but-unreleased at this moment.
        // We must do this before setting `revoked = true` would affect vestedAmount,
        // but since we set revoked above we need to use the contract balance directly.
        uint256 total = token.balanceOf(address(this)) + released;
        uint256 vested;
        uint64 ts = uint64(block.timestamp);
        if (ts >= cliff) {
            vested = ts >= start + duration ? total : (total * (ts - start)) / duration;
        }
        uint256 releasableNow = vested > released ? vested - released : 0;
        uint256 unvested = token.balanceOf(address(this)) - releasableNow;

        emit VestingRevoked(unvested);
        if (unvested > 0) {
            token.safeTransfer(treasury, unvested);
        }
    }
}
