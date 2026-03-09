// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GuildXPMock
 * @notice Mock XP contract for testing governance
 * @dev In production, this would be replaced by the actual XP tracking contract
 */
contract GuildXPMock {
    // guild => user => xp
    mapping(address => mapping(address => uint256)) public guildXP;
    // guild => total xp
    mapping(address => uint256) public totalGuildXP;

    event XPSet(address indexed guild, address indexed account, uint256 amount);

    /**
     * @notice Set XP for a user in a guild
     */
    function setGuildXP(address guild, address account, uint256 amount) external {
        uint256 oldAmount = guildXP[guild][account];
        guildXP[guild][account] = amount;
        
        // Update total
        if (amount > oldAmount) {
            totalGuildXP[guild] += (amount - oldAmount);
        } else {
            totalGuildXP[guild] -= (oldAmount - amount);
        }
        
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
            uint256 oldAmount = guildXP[guild][accounts[i]];
            guildXP[guild][accounts[i]] = amounts[i];
            
            if (amounts[i] > oldAmount) {
                totalGuildXP[guild] += (amounts[i] - oldAmount);
            } else {
                totalGuildXP[guild] -= (oldAmount - amounts[i]);
            }
            
            emit XPSet(guild, accounts[i], amounts[i]);
        }
    }
}
