// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";

contract DeliveryEscrow_Expiration_PoC is Test {
    DeliveryMissionFactory public deliveryFactory;
    MissionFactory public missionFactory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public admin = address(1);
    address public poster = address(2);
    address public performer = address(3);

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(address(usdc), address(11), address(12), address(13), admin);

        missionFactory = new MissionFactory(address(router));
        deliveryFactory = new DeliveryMissionFactory(address(router));

        router.setMissionFactory(address(missionFactory));
        router.setMissionFactory(address(deliveryFactory));
        vm.stopPrank();
    }

    function test_submitProof_after_expiration_mission() public {
        uint256 rewardAmount = 100e6;
        usdc.mint(poster, rewardAmount);

        vm.startPrank(poster);
        usdc.approve(address(missionFactory), rewardAmount);

        uint256 expiresAt = block.timestamp + 1 days;
        uint256 missionId = missionFactory.createMission(
            address(usdc),
            rewardAmount,
            expiresAt,
            address(0),
            keccak256("metadata"),
            keccak256("location")
        );
        vm.stopPrank();

        address escrowAddress = missionFactory.missions(missionId);
        MissionEscrow escrow = MissionEscrow(escrowAddress);

        vm.prank(performer);
        escrow.acceptMission();

        vm.warp(block.timestamp + 2 days);

        vm.prank(performer);
        escrow.submitProof(keccak256("proof"));

        IMissionEscrow.MissionRuntime memory runtime = escrow.getRuntime();
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Submitted));

        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.claimExpired();
    }

    function test_submitProof_after_expiration_delivery() public {
        uint256 rewardAmount = 100e6;
        usdc.mint(poster, rewardAmount);

        vm.startPrank(poster);
        usdc.approve(address(deliveryFactory), rewardAmount);

        uint256 expiresAt = block.timestamp + 1 days;

        uint256 missionId = deliveryFactory.createDeliveryMission(
            address(usdc),
            rewardAmount,
            expiresAt,
            address(0),
            keccak256("metadata"),
            keccak256("location")
        );
        vm.stopPrank();

        address escrowAddress = deliveryFactory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(0, 0, bytes32(0), 0, 0, false),
            dropoff: DeliveryEscrow.DeliveryLocation(0, 0, bytes32(0), 0, 0, false),
            package: DeliveryEscrow.PackageDetails(0, 0, 0, 0),
            pickupWindowStart: block.timestamp,
            pickupWindowEnd: block.timestamp + 1 hours,
            deliveryDeadline: block.timestamp + 2 hours,
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });

        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](1);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: bytes32(0),
            latitude: 0,
            longitude: 0,
            waypointType: 0,
            arrivalDeadline: 0,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });

        vm.prank(address(deliveryFactory));
        escrow.initializeDelivery(params, waypoints);

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(performer);
        escrow.completeWaypoint(0, keccak256("proof"));

        vm.warp(block.timestamp + 2 days);

        vm.prank(performer);
        escrow.submitProof(keccak256("final_proof"));

        IMissionEscrow.MissionRuntime memory runtime = escrow.getRuntime();
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Submitted));

        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.claimExpired();
    }
}
