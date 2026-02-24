// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract MissionEscrowSecurity is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    MockERC20 public usdc;

    address public owner = address(0x1);
    address public poster = address(0x2);
    address public performer = address(0x3);
    address public disputeResolver = address(0x4);

    address public protocolTreasury = address(0x10);
    address public resolverTreasury = address(0x11);
    address public labsTreasury = address(0x12);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        vm.startPrank(owner);
        // Deploy Mock USDC
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy PaymentRouter
        paymentRouter =
            new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury);

        // Deploy MissionFactory
        factory = new MissionFactory(address(usdc), address(paymentRouter));
        factory.setDisputeResolver(disputeResolver);
        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);
    }

    function test_PosterCannotStealFundsAfterSubmission() public {
        // 1. Poster creates a mission that expires in 1 day
        vm.startPrank(poster);
        uint256 expiresAt = block.timestamp + 1 days;

        uint256 missionId =
            factory.createMission(REWARD_AMOUNT, expiresAt, address(0), bytes32(0), bytes32(0));
        vm.stopPrank();

        address escrowAddress = factory.missions(missionId);
        MissionEscrow escrow = MissionEscrow(escrowAddress);

        // 2. Performer accepts
        vm.prank(performer);
        escrow.acceptMission();

        // 3. Performer submits proof
        vm.prank(performer);
        escrow.submitProof(keccak256("proof"));

        assertEq(uint256(escrow.getRuntime().state), uint256(IMissionEscrow.MissionState.Submitted));

        // 4. Fast forward past expiration
        vm.warp(expiresAt + 1);

        // 5. Poster tries to claim expired funds - SHOULD REVERT
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(IMissionEscrow.InvalidState.selector, IMissionEscrow.MissionState.Submitted));
        escrow.claimExpired();

        // 6. Assertions
        // State should still be Submitted
        assertEq(uint256(escrow.getRuntime().state), uint256(IMissionEscrow.MissionState.Submitted));

        // Poster balance unchanged (900 USDC remaining)
        assertEq(usdc.balanceOf(poster), 900e6);

        // Escrow still holds funds
        assertEq(usdc.balanceOf(escrowAddress), 100e6);
    }
}
