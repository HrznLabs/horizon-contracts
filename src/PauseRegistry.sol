// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PauseRegistry
 * @notice Centralized pause state for global + per-contract pause control
 * @dev Provides:
 *   - Global pause: Blocks all new operations across all contracts
 *   - Per-contract pause: Targeted pause for specific contracts
 *   - Circuit breaker: Auto-pause on unusual fund drain
 *   - Graceful wind-down: Consuming contracts decide which ops to block
 *
 * Integration pattern for consuming contracts:
 *   require(!pauseRegistry.isPaused(address(this)), "Paused");
 *
 * Wind-down semantics (per 01-CONTEXT.md):
 *   - Paused MissionFactory: cannot create new missions
 *   - Paused MissionEscrow: cannot accept new deposits
 *   - Settlement ALWAYS works: in-progress missions can complete
 */
contract PauseRegistry is AccessControl {
    // =============================================================================
    // ROLES
    // =============================================================================

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Global pause flag — blocks all contracts when true
    bool public globalPaused;

    /// @notice Per-contract pause state
    mapping(address => bool) public contractPaused;

    /// @notice Circuit breaker drain threshold in basis points (default 30%)
    uint256 public circuitBreakerThresholdBPS = 3000;

    /// @notice Registered contracts that can trigger circuit breaker
    mapping(address => bool) public registeredContracts;

    /// @notice Per-contract balance tracking for circuit breaker
    mapping(address => uint256) public lastKnownBalance;

    // =============================================================================
    // EVENTS
    // =============================================================================

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
    event ContractRegistered(address indexed target);
    event ContractDeregistered(address indexed target);
    event CircuitBreakerThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // =============================================================================
    // ERRORS
    // =============================================================================

    error NotRegistered();
    error AlreadyPaused();
    error NotPaused();

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /**
     * @param _admin Admin address (gets DEFAULT_ADMIN_ROLE + PAUSER_ROLE)
     */
    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    // =============================================================================
    // PAUSE STATE QUERIES
    // =============================================================================

    /**
     * @notice Check if a target contract is paused (global OR per-contract)
     * @param target Contract address to check
     * @return True if target is paused (globally or individually)
     */
    function isPaused(address target) external view returns (bool) {
        return globalPaused || contractPaused[target];
    }

    /**
     * @notice Check if only global pause is active
     * @return True if global pause is on
     */
    function isGloballyPaused() external view returns (bool) {
        return globalPaused;
    }

    // =============================================================================
    // PAUSE CONTROLS (PAUSER_ROLE required)
    // =============================================================================

    /**
     * @notice Pause all contracts globally
     */
    function pauseGlobal() external onlyRole(PAUSER_ROLE) {
        globalPaused = true;
        emit GlobalPaused(msg.sender);
    }

    /**
     * @notice Unpause all contracts globally
     */
    function unpauseGlobal() external onlyRole(PAUSER_ROLE) {
        globalPaused = false;
        emit GlobalUnpaused(msg.sender);
    }

    /**
     * @notice Pause a specific contract
     * @param target Contract address to pause
     */
    function pauseContract(address target) external onlyRole(PAUSER_ROLE) {
        contractPaused[target] = true;
        emit ContractPaused(target, msg.sender);
    }

    /**
     * @notice Unpause a specific contract
     * @param target Contract address to unpause
     */
    function unpauseContract(address target) external onlyRole(PAUSER_ROLE) {
        contractPaused[target] = false;
        emit ContractUnpaused(target, msg.sender);
    }

    // =============================================================================
    // CIRCUIT BREAKER
    // =============================================================================

    /**
     * @notice Report a balance change and trigger circuit breaker if threshold exceeded
     * @dev Called by registered contracts after significant token transfers
     * @param token ERC20 token to check balance of
     * @param target Contract whose balance changed
     */
    function reportBalanceChange(address token, address target) external {
        if (!registeredContracts[target]) revert NotRegistered();

        uint256 previousBalance = lastKnownBalance[target];
        uint256 newBalance = IERC20(token).balanceOf(target);

        // Update balance
        lastKnownBalance[target] = newBalance;

        // Check if drain exceeds threshold
        if (previousBalance > 0 && newBalance < previousBalance) {
            uint256 drainAmount = previousBalance - newBalance;
            uint256 drainBPS = (drainAmount * 10000) / previousBalance;

            if (drainBPS >= circuitBreakerThresholdBPS) {
                contractPaused[target] = true;
                emit CircuitBreakerTriggered(target, drainAmount, previousBalance, newBalance);
            }
        }
    }

    /**
     * @notice Manually trigger circuit breaker for a contract
     * @dev Callable by PAUSER_ROLE for immediate emergency response
     */
    function triggerCircuitBreaker(address target) external onlyRole(PAUSER_ROLE) {
        contractPaused[target] = true;
        emit CircuitBreakerTriggered(target, 0, 0, 0);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @notice Register a contract for circuit breaker monitoring
     * @param target Contract address to register
     */
    function registerContract(address target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        registeredContracts[target] = true;
        emit ContractRegistered(target);
    }

    /**
     * @notice Deregister a contract from circuit breaker monitoring
     * @param target Contract address to deregister
     */
    function deregisterContract(address target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        registeredContracts[target] = false;
        emit ContractDeregistered(target);
    }

    /**
     * @notice Update circuit breaker threshold
     * @param newThresholdBPS New threshold in basis points (e.g., 3000 = 30%)
     */
    function setCircuitBreakerThreshold(uint256 newThresholdBPS) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldThreshold = circuitBreakerThresholdBPS;
        circuitBreakerThresholdBPS = newThresholdBPS;
        emit CircuitBreakerThresholdUpdated(oldThreshold, newThresholdBPS);
    }

    /**
     * @notice Update a contract's known balance (for circuit breaker initialization)
     * @param target Contract address
     * @param balance New known balance
     */
    function setLastKnownBalance(address target, uint256 balance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lastKnownBalance[target] = balance;
    }
}
