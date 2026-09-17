// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/DeliveryEscrow.sol";
import "../src/PaymentRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDCPoC is ERC20 {
    constructor() ERC20("USDCPoC", "USDCPoC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveryEscrowPoC is Test {
    PaymentRouter router;
    DeliveryMissionFactory factory;
    MockUSDCPoC usdc;

    address admin = address(1);
    address poster = address(2);
    address performer = address(3);

    function setUp() public {
        usdc = new MockUSDCPoC();

        vm.startPrank(admin);
        router = new PaymentRouter(address(usdc), admin, admin, admin, admin);
        router.setAcceptedToken(address(usdc), true);

        factory = new DeliveryMissionFactory(address(router));
        // Set the DeliveryMissionFactory as the mission factory in PaymentRouter
        router.setMissionFactory(address(factory));
        vm.stopPrank();

        usdc.mint(poster, 1000e6);
    }

    function testDeliveryEscrowSettlementFails() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), 1000e6);
        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100e6,
            block.timestamp + 2 days,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrowAddr = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddr));

        // Performer accepts the mission
        vm.startPrank(performer);
        escrow.acceptMission();
        vm.stopPrank();

        // Initialize delivery and waypoints so that it can be completed
        DeliveryEscrow.DeliveryParams memory deliveryParams;
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](0);

        vm.startPrank(address(factory));
        escrow.initializeDelivery(deliveryParams, waypoints);
        vm.stopPrank();

        // Submit proof
        vm.startPrank(performer);
        escrow.submitProof(bytes32(0));
        vm.stopPrank();

        // Poster approves
        vm.startPrank(poster);

        // Without the patch, this reverted with OnlyMissionEscrow.
        // With the patch, this should succeed.
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        escrow.approveCompletion();
        vm.stopPrank();
    }
}
