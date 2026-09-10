// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1000000 * 1e6);
    }
}

contract DeliveryEscrowPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockUSDC usdc;

    address admin = address(0x1);
    address poster = address(0x2);
    address performer = address(0x3);

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();

        router = new PaymentRouter(
            address(usdc),
            address(0x4), // protocol
            address(0x5), // resolver
            address(0x6), // labs
            admin
        );

        factory = new DeliveryMissionFactory(address(router));
        router.setMissionFactory(address(factory));

        usdc.transfer(poster, 1000 * 1e6);
        vm.stopPrank();
    }

    function test_settlementFailsBecauseOfMissingGetMissionByEscrow() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), 100 * 1e6);
        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100 * 1e6,
            block.timestamp + 2 hours,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrowAddr = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddr));

        DeliveryEscrow.DeliveryParams memory params;
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](0);

        vm.prank(address(factory));
        escrow.initializeDelivery(params, waypoints);

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(performer);
        escrow.submitProof(bytes32(0));

        vm.expectRevert(); // Should revert with OnlyMissionEscrow because getMissionByEscrow is missing
        vm.prank(poster);
        escrow.approveCompletion();
    }
}
