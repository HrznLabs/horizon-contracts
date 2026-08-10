// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";

contract TestPaymentRouter is PaymentRouter {
    constructor(
        address _usdc,
        address _protocolTreasury,
        address _resolverTreasury,
        address _labsTreasury,
        address _admin
    ) PaymentRouter(_usdc, _protocolTreasury, _resolverTreasury, _labsTreasury, _admin) {}

    function isFactoryEscrow(address escrow) external view returns (bool) {
        return _isFactoryEscrow(escrow);
    }
}

contract DeliveryEscrowPoC is Test {
    DeliveryMissionFactory factory;
    TestPaymentRouter paymentRouter;
    MockERC20 token;

    address admin = address(1);
    address poster = address(2);
    address performer = address(3);

    function setUp() public {
        vm.startPrank(admin);
        token = new MockERC20("USDC", "USDC", 6);
        paymentRouter = new TestPaymentRouter(address(token), admin, admin, admin, admin);
        paymentRouter.setAcceptedToken(address(token), true);
        factory = new DeliveryMissionFactory(address(paymentRouter));
        paymentRouter.setMissionFactory(address(factory));

        token.mint(poster, 1000 * 1e6);
        vm.stopPrank();
    }

    function testDeliveryEscrowPoC() public {
        vm.startPrank(poster);
        token.approve(address(factory), type(uint256).max);

        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100 * 1e6, // reward
            block.timestamp + 2 hours, // expiresAt
            address(0), // guild
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrowAddr = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddr));

        vm.prank(performer);
        escrow.acceptMission();

        // Fast forward past expiration
        vm.warp(block.timestamp + 3 hours);

        // Performer submits proof after expiration
        vm.prank(performer);
        escrow.submitProof(bytes32("proof"));

        assertEq(uint(escrow.getRuntime().state), uint(IMissionEscrow.MissionState.Submitted));

        // Factory escrow validation fails
        bool isEscrow = paymentRouter.isFactoryEscrow(escrowAddr);
        assertFalse(isEscrow);
    }
}
