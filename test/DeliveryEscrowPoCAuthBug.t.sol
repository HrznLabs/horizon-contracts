// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/DeliveryEscrow.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1000000 * 1e6);
    }
}

contract DeliveryEscrowPoCAuthBug is Test {
    DeliveryMissionFactory public factory;
    PaymentRouter public router;
    MockUSDC public usdc;

    address poster = address(0x100);
    address performer = address(0x101);

    function setUp() public {
        usdc = new MockUSDC();
        router = new PaymentRouter(address(usdc), address(0x1), address(0x2), address(0x3), address(this));

        router.setAcceptedToken(address(usdc), true);

        factory = new DeliveryMissionFactory(address(router));
        router.setMissionFactory(address(factory));

        usdc.transfer(poster, 1000 * 1e6);
        vm.prank(poster);
        usdc.approve(address(factory), type(uint256).max);
    }

    function test_settlementRevertsDueToMissingGetMissionByEscrow() public {
        vm.prank(poster);
        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100 * 1e6, // reward
            block.timestamp + 2 hours, // expiresAt
            address(0), // guild
            bytes32(0), // metadata
            bytes32(0)  // location
        );

        // Get the escrow address
        address escrowAddr = factory.missions(missionId);
        assertEq(escrowAddr != address(0), true, "Escrow not created");

        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddr));

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(performer);
        escrow.submitProof(bytes32(0));

        // Try to settle (simulate poster confirming delivery)
        // This fails because PaymentRouter cannot authenticate the DeliveryEscrow
        // since DeliveryMissionFactory does not implement `getMissionByEscrow(address)`
        vm.prank(poster);
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        escrow.approveCompletion();
    }
}
