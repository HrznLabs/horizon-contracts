// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryEscrow.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) public { balanceOf[to] += amount; }
    function approve(address, uint256) public returns (bool) { return true; }
    function transferFrom(address, address to, uint256 amount) public returns (bool) {
        balanceOf[to] += amount;
        return true;
    }
}

contract DeliveryMissionFactoryPoC is Test {
    DeliveryMissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20();

        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            owner
        );
        router.setAcceptedToken(address(usdc), true);

        factory = new DeliveryMissionFactory(address(router));

        router.setMissionFactory(address(factory));

        vm.stopPrank();
    }

    function test_deliveryEscrowSettlementFails() public {
        vm.startPrank(poster);
        usdc.mint(poster, 1000e6);

        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100e6,
            block.timestamp + 2 hours,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrow = factory.missions(missionId);

        // Simulating that the escrow tries to call `settlePayment` on PaymentRouter.
        // It reverts because DeliveryMissionFactory does not implement `getMissionByEscrow(address)`.

        vm.startPrank(escrow);
        vm.expectRevert();
        router.settlePayment(missionId, address(3), address(usdc), 100e6, address(0));
    }
}
