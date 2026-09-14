// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IMissionFactory} from "../src/interfaces/IMissionFactory.sol";

contract DeliveryEscrowSentinelPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockERC20 token;

    address poster = address(0x1111);

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(address(token), address(this), address(this), address(this), address(this));

        factory = new DeliveryMissionFactory(address(router));
        router.setMissionFactory(address(factory));

        token.mint(poster, 10000e6);
        vm.prank(poster);
        token.approve(address(factory), type(uint256).max);
    }

    function test_poc_factory_does_not_implement_getMissionByEscrow() public {
        // 1. Poster creates a delivery mission via factory
        vm.prank(poster);
        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100e6,
            block.timestamp + 1 days,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrowAddr = factory.missions(missionId);

        // 2. Check if PaymentRouter._isFactoryEscrow will revert or return false.
        // It relies on: IMissionFactory(factory).getMissionByEscrow(caller)

        // Manually trigger the staticcall to simulate what PaymentRouter does
        (bool success, bytes memory data) = address(factory).staticcall(
            abi.encodeWithSelector(IMissionFactory.getMissionByEscrow.selector, escrowAddr)
        );

        // Success is false because the factory does not implement getMissionByEscrow.
        // This causes the PaymentRouter to revert when the clone escrow tries to call it to settle the payment.
        assertFalse(success);
    }
}
