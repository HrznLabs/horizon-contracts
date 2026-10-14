// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMissionEscrow} from "../../src/interfaces/IMissionEscrow.sol";

/// @notice Stand-in for DeliveryMissionFactory's mission lookups used by DeliveriesDAO.
contract MockDeliveryRegistry {
    struct Mission {
        address poster;
        uint256 reward;
        IMissionEscrow.MissionState state;
    }

    mapping(uint256 => Mission) internal _missions;

    function setMission(uint256 id, address poster, uint256 reward) external {
        _missions[id] = Mission(poster, reward, IMissionEscrow.MissionState.Open);
    }

    function setState(uint256 id, IMissionEscrow.MissionState state) external {
        _missions[id].state = state;
    }

    function missions(uint256 id) external view returns (address) {
        // Any non-zero address stands in for the escrow clone of a registered mission.
        return _missions[id].poster == address(0) ? address(0) : address(uint160(0xE5C0 + id));
    }

    function getMissionParams(uint256 id)
        external
        view
        returns (IMissionEscrow.MissionParams memory p)
    {
        p.poster = _missions[id].poster;
        p.rewardAmount = _missions[id].reward;
    }

    function getMissionRuntime(uint256 id)
        external
        view
        returns (IMissionEscrow.MissionRuntime memory r)
    {
        r.state = _missions[id].state;
    }
}
