// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title GuildTimelock
 * @notice TimelockController for Guild governance with configurable delay
 * @dev Wraps OpenZeppelin's TimelockController with guild-specific configuration
 *
 * The timelock adds a delay between when a proposal passes and when it can be executed.
 * This gives users time to exit if they disagree with a decision.
 */
contract GuildTimelock is TimelockController {
    /// @notice The Guild DAO this timelock is associated with
    address public immutable guildDAO;

    /// @notice Emitted when timelock is deployed
    event GuildTimelockDeployed(address indexed guildDAO, uint256 minDelay);

    /**
     * @notice Deploy a new GuildTimelock
     * @param _minDelay Minimum delay before execution (in seconds)
     * @param _proposers Addresses that can propose (typically the Governor)
     * @param _executors Addresses that can execute (address(0) for anyone)
     * @param _admin Optional admin address (address(0) to disable admin)
     * @param _guildDAO The Guild DAO this timelock serves
     */
    constructor(
        uint256 _minDelay,
        address[] memory _proposers,
        address[] memory _executors,
        address _admin,
        address _guildDAO
    ) TimelockController(_minDelay, _proposers, _executors, _admin) {
        guildDAO = _guildDAO;
        emit GuildTimelockDeployed(_guildDAO, _minDelay);
    }
}
