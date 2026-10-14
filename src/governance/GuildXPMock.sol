// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title GuildXPMock
 * @notice Mock XP contract for testing governance
 * @dev In production, this would be replaced by the actual XP tracking contract.
 *      Mirrors GuildXP's per-block checkpoints (audit H6) so governors can be tested
 *      against snapshot reads.
 */
contract GuildXPMock {
    using Checkpoints for Checkpoints.Trace208;

    // guild => user => xp
    mapping(address => mapping(address => uint256)) public guildXP;
    // guild => total xp
    mapping(address => uint256) public totalGuildXP;

    mapping(address => mapping(address => Checkpoints.Trace208)) private _xpHistory;
    mapping(address => Checkpoints.Trace208) private _totalHistory;

    event XPSet(address indexed guild, address indexed account, uint256 amount);

    error FutureLookup(uint256 timepoint, uint48 currentClock);

    /**
     * @notice Set XP for a user in a guild
     */
    function setGuildXP(address guild, address account, uint256 amount) public {
        uint256 oldAmount = guildXP[guild][account];
        guildXP[guild][account] = amount;

        // Update total
        if (amount > oldAmount) {
            totalGuildXP[guild] += (amount - oldAmount);
        } else {
            totalGuildXP[guild] -= (oldAmount - amount);
        }

        uint48 key = SafeCast.toUint48(block.number);
        _xpHistory[guild][account].push(key, SafeCast.toUint208(amount));
        _totalHistory[guild].push(key, SafeCast.toUint208(totalGuildXP[guild]));

        emit XPSet(guild, account, amount);
    }

    /**
     * @notice Get a user's XP for a specific guild
     */
    function getGuildXP(address guild, address account) external view returns (uint256) {
        return guildXP[guild][account];
    }

    /**
     * @notice Get total XP for a guild
     */
    function getTotalGuildXP(address guild) external view returns (uint256) {
        return totalGuildXP[guild];
    }

    function getPastGuildXP(
        address guild,
        address account,
        uint256 timepoint
    ) external view returns (uint256) {
        return _xpHistory[guild][account].upperLookupRecent(_check(timepoint));
    }

    function getPastTotalGuildXP(address guild, uint256 timepoint) external view returns (uint256) {
        return _totalHistory[guild].upperLookupRecent(_check(timepoint));
    }

    /**
     * @notice Batch set XP for multiple users
     */
    function batchSetGuildXP(
        address guild,
        address[] calldata accounts,
        uint256[] calldata amounts
    ) external {
        require(accounts.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < accounts.length; i++) {
            setGuildXP(guild, accounts[i], amounts[i]);
        }
    }

    function _check(uint256 timepoint) private view returns (uint48) {
        if (timepoint >= block.number) {
            revert FutureLookup(timepoint, SafeCast.toUint48(block.number));
        }
        return SafeCast.toUint48(timepoint);
    }
}
