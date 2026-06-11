// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPauseRegistry
 * @notice Interface for centralized pause state management
 */
interface IPauseRegistry {
    // Events
    event GlobalPaused(address indexed by);
    event GlobalUnpaused(address indexed by);
    event ContractPaused(address indexed target, address indexed by);
    event ContractUnpaused(address indexed target, address indexed by);
    event CircuitBreakerTriggered(
        address indexed target,
        uint256 drainAmount,
        uint256 previousBalance,
        uint256 newBalance
    );

    // Errors
    error NotRegistered();
    error AlreadyPaused();
    error NotPaused();

    /// @notice Check if a target is paused (globally or individually)
    function isPaused(address target) external view returns (bool);

    /// @notice Check if global pause is active
    function isGloballyPaused() external view returns (bool);

    /// @notice Pause all contracts
    function pauseGlobal() external;

    /// @notice Unpause all contracts
    function unpauseGlobal() external;

    /// @notice Pause a specific contract
    function pauseContract(address target) external;

    /// @notice Unpause a specific contract
    function unpauseContract(address target) external;

    /// @notice Report balance change for circuit breaker
    function reportBalanceChange(address token, address target) external;

    /// @notice Manually trigger circuit breaker
    function triggerCircuitBreaker(address target) external;
}
