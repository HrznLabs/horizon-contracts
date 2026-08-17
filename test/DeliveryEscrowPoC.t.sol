// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeliveryEscrowTest} from "./DeliveryEscrow.t.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";

contract DeliveryEscrowPoCTest is DeliveryEscrowTest {
    function test_FactoryEscrowBypass() public {
        (uint256 missionId, address escrowAddress) = _createDeliveryMission();

        vm.startPrank(owner);
        router.setMissionFactory(address(factory));
        vm.stopPrank();

        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](1);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0,
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(37774900, -122419400, bytes32(0), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(34052200, -118243700, bytes32(0), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(1, 1, 1000, 0),
            pickupWindowStart: block.timestamp,
            pickupWindowEnd: block.timestamp + 2 hours,
            deliveryDeadline: block.timestamp + 6 hours,
            realTimeTrackingEnabled: true,
            tipAmount: 0
        });

        vm.prank(address(factory));
        escrow.initializeDelivery(params, waypoints);

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(performer);
        escrow.completeWaypoint(0, bytes32("proof"));

        vm.prank(performer);
        escrow.submitProof(bytes32("proof final"));

        vm.prank(poster);
        vm.expectRevert(bytes4(keccak256("OnlyMissionEscrow()")));
        escrow.approveCompletion();
    }
}
