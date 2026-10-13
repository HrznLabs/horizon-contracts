// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GuildGovernor} from "./GuildGovernor.sol";
import {GuildTimelock} from "./GuildTimelock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title GuildTimelockDeployer / GuildGovernorDeployer
 * @notice Thin deployment shims holding the creation bytecode that used to be
 *         embedded in GuildGovernorFactory.
 * @dev Issue #832: `new GuildTimelock(...)` and `new GuildGovernor(...)` inside the
 *      factory embed both contracts' full creation code in the factory's RUNTIME
 *      bytecode, putting it 931 bytes over the EIP-170 limit (25,507 > 24,576) — the
 *      factory could never be deployed. Moving each `new` behind an external call
 *      splits that code across three deployable contracts while keeping the deployed
 *      Governor/Timelock byte-identical (same constructors, no proxies, no
 *      initializers).
 *
 *      These shims are intentionally permissionless: they hold no state and grant no
 *      roles — everything security-relevant (authorisation, one-shot slots, parameter
 *      floors, role wiring) stays in GuildGovernorFactory, which passes itself as the
 *      timelock admin exactly as before.
 */
contract GuildTimelockDeployer {
    function deploy(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin,
        address guildDAO
    ) external returns (address) {
        return address(new GuildTimelock(minDelay, proposers, executors, admin, guildDAO));
    }
}

contract GuildGovernorDeployer {
    function deploy(
        address guildDAO,
        address payable timelock,
        address xpContract,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumPercent
    ) external returns (address) {
        return address(
            new GuildGovernor(
                guildDAO,
                TimelockController(timelock),
                xpContract,
                votingDelay,
                votingPeriod,
                proposalThreshold,
                quorumPercent
            )
        );
    }
}
