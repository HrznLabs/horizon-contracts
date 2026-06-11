// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title HorizonTimelock
/// @notice TimelockController used as the execution timelock for HorizonGovernor.
/// @dev Standard OZ v5 TimelockController — no customisation needed.
contract HorizonTimelock is TimelockController {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
