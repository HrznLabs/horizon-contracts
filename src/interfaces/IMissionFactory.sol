// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMissionFactory {
    /**
     * @notice Get escrow address for a mission
     * @param missionId The mission ID
     * @return escrow The escrow contract address
     */
    function getMission(uint256 missionId) external view returns (address escrow);
}
