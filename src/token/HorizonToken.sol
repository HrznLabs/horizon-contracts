// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/// @title HorizonToken
/// @notice HRZN ERC-20 governance token with fixed 1B supply, voting power, and permit support.
/// @dev Uses timestamp-based clock mode (required for OZ Governor v5 compatibility).
///      Supply is minted entirely in the constructor — no further minting is possible.
contract HorizonToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @param treasury    Receives 800M HRZN (workers 350M + ecosystem 200M + protocol 200M + liquidity 50M)
    /// @param teamVesting Receives 150M HRZN (team allocation, locked in vesting contract)
    /// @param advisorVesting Receives 50M HRZN (advisor allocation, locked in vesting contract)
    constructor(address treasury, address teamVesting, address advisorVesting)
        ERC20("Horizon", "HRZN")
        ERC20Permit("Horizon")
    {
        _mint(treasury, 800_000_000 * 10 ** 18);
        _mint(teamVesting, 150_000_000 * 10 ** 18);
        _mint(advisorVesting, 50_000_000 * 10 ** 18);
    }

    // -------------------------------------------------------------------------
    // Clock — timestamp mode (required for OZ Governor v5)
    // -------------------------------------------------------------------------

    /// @notice Returns the current block timestamp as a uint48 for voting checkpoints.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice Returns the clock mode identifier string for ERC-6372 compatibility.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // -------------------------------------------------------------------------
    // Diamond-inheritance overrides (OZ 5.x)
    // -------------------------------------------------------------------------

    /// @dev Both ERC20Permit and Votes (via ERC20Votes) inherit Nonces.
    ///      Explicit override routes through the single Nonces storage.
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @dev Both ERC20 and ERC20Votes define _update. Override merges both paths.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }
}
