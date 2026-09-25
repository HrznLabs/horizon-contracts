// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";

contract DeliveryEscrowPoC is Test {
    DeliveryMissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury, owner);
        factory = new DeliveryMissionFactory(address(router));

        router.setMissionFactory(address(factory));
        router.setAcceptedToken(address(usdc), true);
        vm.stopPrank();

        usdc.mint(poster, 1000e6);
    }

    function test_MissingGetMissionByEscrowRevertsPaymentVerbose() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), 100e6);

        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100e6,
            block.timestamp + 2 hours,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrowAddr = factory.missions(missionId);

        // This will fail because PaymentRouter._isFactoryEscrow tries to call getMissionByEscrow on the factory
        // But DeliveryMissionFactory doesn't implement it! Thus it reverts with OnlyMissionEscrow
        vm.startPrank(escrowAddr);
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        router.settlePayment(missionId, performer, address(usdc), 100e6, address(0));
        vm.stopPrank();
    }
}
