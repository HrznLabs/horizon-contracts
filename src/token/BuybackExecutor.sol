// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./HorizonToken.sol";

/// @notice Minimal Aerodrome router interface for USDC->HRZN swap
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @title BuybackExecutor
/// @notice Swaps USDC for HRZN via Aerodrome and burns the HRZN.
/// @dev Implements the deflationary buyback-and-burn mechanic for Horizon Protocol.
///      On testnet the router address is a placeholder (no Aerodrome on Base Sepolia).
///      Update `setRouter` before mainnet deployment.
contract BuybackExecutor is AccessControl {
    using SafeERC20 for IERC20;

    // =========================================================================
    // ROLES
    // =========================================================================

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // =========================================================================
    // STATE
    // =========================================================================

    IERC20 public immutable usdc;
    HorizonToken public immutable hrzn;
    IAerodromeRouter public router;
    address public aerodromeFactory;

    uint256 public totalUsdcSpent;
    uint256 public totalHrznBurned;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event BuybackExecuted(uint256 usdcSpent, uint256 hrznBurned);
    event RouterUpdated(address newRouter, address newFactory);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(
        address _usdc,
        address _hrzn,
        address _router,
        address _factory,
        address _admin
    ) {
        usdc = IERC20(_usdc);
        hrzn = HorizonToken(_hrzn);
        router = IAerodromeRouter(_router);
        aerodromeFactory = _factory;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(EXECUTOR_ROLE, _admin);
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /// @notice Update the Aerodrome router (admin only — used to swap testnet mock for mainnet)
    function setRouter(address _router, address _factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        router = IAerodromeRouter(_router);
        aerodromeFactory = _factory;
        emit RouterUpdated(_router, _factory);
    }

    // =========================================================================
    // BUYBACK
    // =========================================================================

    /// @notice Execute a buyback: pull USDC from caller, swap for HRZN via Aerodrome, burn HRZN
    /// @param usdcAmount  Amount of USDC to spend (6 decimals)
    /// @param minHrznOut  Minimum HRZN to receive (18 decimals) — slippage protection
    /// @param deadline    Unix timestamp deadline for the swap
    function executeBuyback(
        uint256 usdcAmount,
        uint256 minHrznOut,
        uint256 deadline
    ) external onlyRole(EXECUTOR_ROLE) {
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        usdc.forceApprove(address(router), usdcAmount);

        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({
            from: address(usdc),
            to: address(hrzn),
            stable: false,
            factory: aerodromeFactory
        });

        uint256[] memory amounts = router.swapExactTokensForTokens(
            usdcAmount,
            minHrznOut,
            routes,
            address(this),
            deadline
        );

        uint256 hrznReceived = amounts[amounts.length - 1];
        hrzn.burn(hrznReceived);

        totalUsdcSpent += usdcAmount;
        totalHrznBurned += hrznReceived;

        emit BuybackExecuted(usdcAmount, hrznReceived);
    }
}
