// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IMissionFactory
 * @notice Interface for the MissionFactory contract
 * @dev Used by PaymentRouter to verify escrow clones
 */
interface IMissionFactory {
    /// @notice Get mission ID by escrow address (returns 0 if not found)
    function getMissionByEscrow(address escrow) external view returns (uint256);

    /// @notice Get escrow address by mission ID
    function getMission(uint256 missionId) external view returns (address);

    /// @notice Get current mission count
    function missionCount() external view returns (uint256);
}
