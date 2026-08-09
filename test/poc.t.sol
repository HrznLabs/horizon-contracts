// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";

contract PoC2 is Test {
    function testDeliveryEscrowCannotSettleComplete() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        PaymentRouter router = new PaymentRouter(address(usdc), address(1), address(2), address(3), address(this));

        DeliveryMissionFactory factory = new DeliveryMissionFactory(address(router));

        router.setMissionFactory(address(factory));
        router.setAcceptedToken(address(usdc), true);

        usdc.mint(address(this), 1000e6);
        usdc.approve(address(factory), 1000e6);

        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100e6,
            block.timestamp + 1 days,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrow = factory.missions(missionId);

        vm.prank(address(factory));
        DeliveryEscrow.DeliveryParams memory dp;
        DeliveryEscrow.DeliveryWaypoint[] memory dw = new DeliveryEscrow.DeliveryWaypoint[](0);
        DeliveryEscrow(payable(escrow)).initializeDelivery(dp, dw);

        vm.prank(address(4)); // Performer
        DeliveryEscrow(payable(escrow)).acceptMission();

        vm.prank(address(4)); // Performer
        DeliveryEscrow(payable(escrow)).submitProof(bytes32(0));

        // This will revert because router doesn't recognize escrow
        vm.expectRevert();
        DeliveryEscrow(payable(escrow)).approveCompletion();
    }
}
