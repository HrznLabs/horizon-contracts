// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IReputationAttestations
 * @notice Interface for the ReputationAttestations contract
 */
interface IReputationAttestations {
    /**
     * @notice Record mission outcome (called by MissionEscrow)
     * @param missionId The mission ID
     * @param poster Poster address
     * @param performer Performer address
     * @param completed Whether mission was completed successfully
     * @param rewardAmount The reward amount
     */
    function recordOutcome(
        uint256 missionId,
        address poster,
        address performer,
        bool completed,
        uint256 rewardAmount
    ) external;
}
