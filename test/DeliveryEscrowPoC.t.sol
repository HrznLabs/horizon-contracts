// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1000000 * 1e6);
    }
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

contract DeliveryEscrowPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter paymentRouter;
    MockUSDC usdc;

    address poster = address(0x111);
    address performer = address(0x222);
    address admin = address(0x333);
    address treasury = address(0x444);

    function setUp() public {
        usdc = new MockUSDC();

        paymentRouter = new PaymentRouter(
            address(usdc),
            treasury,
            treasury,
            treasury,
            admin
        );

        factory = new DeliveryMissionFactory(address(paymentRouter));

        vm.prank(admin);
        paymentRouter.setMissionFactory(address(factory));

        usdc.transfer(poster, 1000 * 1e6);
    }

    function testDeliveryEscrowCannotSettle() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), 1000 * 1e6);

        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100 * 1e6, // reward
            block.timestamp + 2 hours, // expiresAt
            address(0), // guild
            bytes32(0), // metadata
            bytes32(0)  // locationHash
        );
        vm.stopPrank();

        address escrowAddress = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(performer);
        escrow.submitProof(bytes32(uint256(1)));

        // This fails with OnlyMissionEscrow() because missing factory mapping
        vm.startPrank(poster);
        vm.expectRevert();
        escrow.approveCompletion();
        vm.stopPrank();
    }
}
