// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/DeliveryEscrow.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1_000_000 * 1e18);
    }
}

contract DeliveryEscrowPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockToken token;

    address admin = address(0x1);
    address user = address(0x2);
    address performer = address(0x3);

    function setUp() public {
        vm.startPrank(admin);
        token = new MockToken();
        router = new PaymentRouter(address(token), admin, admin, admin, admin);
        router.setAcceptedToken(address(token), true);

        factory = new DeliveryMissionFactory(address(router));
        router.setMissionFactory(address(factory));

        token.transfer(user, 10_000 * 1e18);
        vm.stopPrank();
    }

    function testDeliveryEscrowCannotSettle() public {
        vm.startPrank(user);
        token.approve(address(factory), type(uint256).max);

        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100 * 1e18,
            block.timestamp + 2 hours,
            address(0), // guild
            bytes32(0), // metadataHash
            bytes32(0) // locationHash
        );

        address escrowAddr = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddr));
        vm.stopPrank();

        // performer joins
        vm.startPrank(performer);
        escrow.acceptMission();
        escrow.submitProof(bytes32(0));
        vm.stopPrank();

        // user attempts to approve completion
        vm.startPrank(user);
        vm.expectRevert();
        escrow.approveCompletion();
        vm.stopPrank();
    }
}
