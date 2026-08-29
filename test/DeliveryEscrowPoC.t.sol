// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1000000 * 1e18);
    }
}

contract DeliveryEscrowPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockToken token;

    function setUp() public {
        router = new PaymentRouter(address(this), address(this), address(this), address(this), address(this));
        factory = new DeliveryMissionFactory(address(router));

        router.setMissionFactory(address(factory));

        token = new MockToken();
        router.setAcceptedToken(address(token), true);
    }

    function test_poc_delivery_escrow_getMissionByEscrow_missing() public {
        address poster = address(0x111);
        address performer = address(0x222);

        token.transfer(poster, 1000e6);

        vm.startPrank(poster);
        token.approve(address(factory), 1000e6);

        uint256 missionId = factory.createDeliveryMission(
            address(token),
            1000e6,
            block.timestamp + 2 hours,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        DeliveryEscrow(payable(escrow)).acceptMission();

        vm.prank(performer);
        DeliveryEscrow(payable(escrow)).submitProof(bytes32(uint256(1)));

        // This fails because PaymentRouter cannot authenticate the escrow
        // since DeliveryMissionFactory does not implement getMissionByEscrow(address)
        vm.prank(poster);
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        DeliveryEscrow(payable(escrow)).approveCompletion();
    }
}
