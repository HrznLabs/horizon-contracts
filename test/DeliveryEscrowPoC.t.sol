// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockTokenERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveryEscrowPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockTokenERC20 usdc;

    address admin = address(1);
    address poster = address(2);
    address performer = address(3);

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockTokenERC20();
        router = new PaymentRouter(address(usdc), admin, admin, admin, admin);

        router.setAcceptedToken(address(usdc), true);

        factory = new DeliveryMissionFactory(address(router));

        // This simulates configuring PaymentRouter with DeliveryMissionFactory
        router.setMissionFactory(address(factory));

        vm.stopPrank();

        usdc.mint(poster, 1000e6);
    }

    function testDeliveryEscrowCannotSettle() public {
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

        address escrow = factory.missions(missionId);

        vm.startPrank(performer);
        DeliveryEscrow(payable(escrow)).acceptMission();
        vm.stopPrank();

        vm.startPrank(performer);
        DeliveryEscrow(payable(escrow)).submitProof(bytes32(uint256(1)));
        vm.stopPrank();

        vm.startPrank(poster);
        // This will fail because DeliveryMissionFactory does not have getMissionByEscrow
        // and PaymentRouter calls IMissionFactory(missionFactory).getMissionByEscrow(caller)
        vm.expectRevert();
        DeliveryEscrow(payable(escrow)).approveCompletion();
        vm.stopPrank();
    }
}
