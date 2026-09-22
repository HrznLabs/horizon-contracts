// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { DeliveryMissionFactory } from "../src/DeliveryMissionFactory.sol";
import { DeliveryEscrow } from "../src/DeliveryEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDCAuth is ERC20 {
    constructor() ERC20("USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveryAuthPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockUSDCAuth usdc;

    address admin = address(0x1);
    address poster = address(0x2);
    address performer = address(0x3);

    function setUp() public {
        usdc = new MockUSDCAuth();

        vm.startPrank(admin);
        router =
            new PaymentRouter(address(usdc), address(0x11), address(0x12), address(0x13), admin);
        factory = new DeliveryMissionFactory(address(router));
        router.setMissionFactory(address(factory));
        vm.stopPrank();

        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(factory), type(uint256).max);
    }

    function test_poc_delivery_escrow_settlement_reverts() public {
        vm.startPrank(poster);
        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100e6,
            block.timestamp + 2 hours,
            address(0), // guild
            bytes32(0), // metadata
            bytes32(0) // location
        );
        vm.stopPrank();

        DeliveryEscrow escrow = DeliveryEscrow(payable(factory.missions(missionId)));

        // Simulating the escrow trying to call settlePayment
        vm.startPrank(address(escrow));

        // This will revert with "OnlyMissionEscrow()"
        // because DeliveryMissionFactory doesn't have getMissionByEscrow
        vm.expectRevert(bytes4(keccak256("OnlyMissionEscrow()")));
        router.settlePayment(missionId, performer, address(usdc), 100e6, address(0));
        vm.stopPrank();
    }
}
