// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MissionEscrow, IMissionEscrow} from "../src/MissionEscrow.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SentinelPoCTest is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockERC20 token;
    address poster = address(0x1);
    address performer = address(0x2);

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(address(token), address(this), address(this), address(this), address(this));
        router.setAcceptedToken(address(token), true);

        factory = new DeliveryMissionFactory(address(router));
    }

    function test_SentinelPoC_DeliveryEscrow_ExpirationBypass() public {
        token.mint(poster, 1000e6);
        vm.prank(poster);
        token.approve(address(factory), 1000e6);

        vm.prank(poster);
        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100e6,
            uint256(block.timestamp + 3600), // 1 hour
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrowAddress = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(escrowAddress);

        vm.prank(performer);
        escrow.acceptMission();

        vm.warp(block.timestamp + 7200); // Past expiration

        // performer can call submitProof, bypassing expiration which should have blocked it, allowing them to drag out a mission indefinitely.
        // MissionEscrow has a notExpired modifier, but DeliveryEscrow doesn't apply it to the overridden function.
        vm.prank(performer);
        escrow.submitProof(bytes32(0));

        IMissionEscrow.MissionRuntime memory runtime = escrow.getRuntime();
        assertEq(uint(runtime.state), uint(IMissionEscrow.MissionState.Submitted));

        // Now poster cannot claimExpired because state is Submitted
        vm.expectRevert();
        vm.prank(poster);
        escrow.claimExpired();
    }
}
