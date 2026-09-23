// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryMissionFactory.sol";
import "./mocks/MockERC20.sol";
import "../src/DeliveryEscrow.sol";
import "../src/interfaces/IPaymentRouter.sol";

contract DeliveryEscrowAuthPoCTest is Test {
    PaymentRouter router;
    DeliveryMissionFactory deliveryFactory;
    MockERC20 usdc;
    address owner = address(1);
    address poster = address(10);
    address performer = address(11);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(address(usdc), address(2), address(3), address(4), owner);
        deliveryFactory = new DeliveryMissionFactory(address(router));
        router.setMissionFactory(address(deliveryFactory));
        vm.stopPrank();
    }

    function testSettlementRevertsDueToMissingAuthMethod() public {
        vm.startPrank(owner);
        usdc.mint(poster, 1000e6);
        vm.stopPrank();

        vm.startPrank(poster);
        usdc.approve(address(deliveryFactory), 1000e6);
        uint256 missionId = deliveryFactory.createDeliveryMission(
            address(usdc), 1000e6, block.timestamp + 1 days, address(0), bytes32(0), bytes32(0)
        );
        vm.stopPrank();

        address escrowAddress = deliveryFactory.missions(missionId);

        vm.startPrank(escrowAddress);
        usdc.mint(address(router), 1000e6);

        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        router.settlePayment(missionId, performer, address(usdc), 1000e6, address(0));
        vm.stopPrank();
    }
}
