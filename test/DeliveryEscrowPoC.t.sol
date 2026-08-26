// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";

contract DeliveryEscrowPoC is Test {
    PaymentRouter router;
    DeliveryMissionFactory factory;
    MockERC20 token;

    function setUp() public {
        token = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(
            address(token),
            address(0x1),
            address(0x2),
            address(0x3),
            address(this)
        ); // DEFAULT_ADMIN_ROLE
        factory = new DeliveryMissionFactory(address(router));

        router.setMissionFactory(address(factory));

        token.mint(address(this), 1000e6);
        token.approve(address(factory), 1000e6);
    }

    function test_settleFailsForDeliveryEscrow() public {
        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100e6,
            block.timestamp + 2 hours,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrowAddr = factory.missions(missionId);

        vm.startPrank(escrowAddr);

        vm.expectRevert(abi.encodeWithSignature("OnlyMissionEscrow()"));
        router.settlePayment(
            missionId,
            address(0x123),
            address(token),
            100e6,
            address(0)
        );
        vm.stopPrank();
    }
}
