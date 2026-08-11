// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";

contract DeliveryEscrowPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockERC20 usdc;

    address admin = address(0x1);
    address poster = address(0x2);
    address performer = address(0x3);
    address protocolTreasury = address(0x4);
    address resolverTreasury = address(0x5);
    address labsTreasury = address(0x6);

    uint256 constant REWARD_AMOUNT = 100e6;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            admin
        );

        factory = new DeliveryMissionFactory(address(router));
        router.setMissionFactory(address(factory));
        vm.stopPrank();

        usdc.mint(poster, 100_000e6);
    }

    function test_ExpiredMissionProofSubmission() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);

        uint256 expiresAt = block.timestamp + 1 days;

        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            REWARD_AMOUNT,
            expiresAt,
            address(0),
            keccak256("metadata"),
            keccak256("location")
        );

        address escrowAddress = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(escrowAddress);
        vm.stopPrank();

        DeliveryEscrow.DeliveryLocation memory pickup;
        DeliveryEscrow.DeliveryLocation memory dropoff;
        DeliveryEscrow.PackageDetails memory packageInfo;

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: pickup,
            dropoff: dropoff,
            package: packageInfo,
            pickupWindowStart: uint40(block.timestamp),
            pickupWindowEnd: uint40(block.timestamp + 1 hours),
            deliveryDeadline: uint40(block.timestamp + 2 hours),
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](0);

        vm.startPrank(address(factory)); // only factory can call initializeDelivery
        escrow.initializeDelivery(params, waypoints);
        vm.stopPrank();

        vm.startPrank(performer);
        escrow.acceptMission();

        vm.warp(expiresAt + 1); // Warp past expiration

        escrow.submitProof(keccak256("proof"));
        vm.stopPrank();

        IMissionEscrow.MissionRuntime memory runtime = escrow.getRuntime();
        assertEq(uint(runtime.state), uint(IMissionEscrow.MissionState.Submitted));

        vm.startPrank(poster);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.claimExpired();
        vm.stopPrank();
    }
}
