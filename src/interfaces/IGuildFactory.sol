// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGuildFactory {
    /**
     * @notice Check if address is a valid guild
     * @param guild Address to check
     * @return True if valid guild
     */
    function isValidGuild(address guild) external view returns (bool);
}
