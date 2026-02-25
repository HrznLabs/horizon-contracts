// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract ClaimExpiredRepro is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public disputeResolver = address(4);
    address public protocolTreasury = address(5);
    address public resolverTreasury = address(6);
    address public labsTreasury = address(7);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("USDC", "USDC", 6);
        paymentRouter =
            new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury);
        factory = new MissionFactory(address(usdc), address(paymentRouter));
        factory.setDisputeResolver(disputeResolver);
        paymentRouter.setMissionFactory(address(factory));
        vm.stopPrank();

        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);
    }

    function test_PosterCannotClaimExpiredWhileDisputed() public {
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

        // 3. Dispute is raised by performer
        vm.prank(disputeResolver);
        escrow.raiseDispute(keccak256("evidence"));

        assertEq(uint256(escrow.getRuntime().state), uint256(IMissionEscrow.MissionState.Disputed));

        // 4. Fast forward past expiration
        vm.warp(expiresAt + 1);

        // 5. Poster claims expired funds - SHOULD REVERT
        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.claimExpired();

        // 6. Assertions
        // State should still be Disputed
        assertEq(uint256(escrow.getRuntime().state), uint256(IMissionEscrow.MissionState.Disputed));

        // Poster balance unchanged
        assertEq(usdc.balanceOf(poster), 900e6); // 1000 - 100
        // Escrow still holds funds
        assertEq(usdc.balanceOf(escrowAddress), 100e6);

        console.log("Vulnerability fixed: Poster could not claim expired funds while disputed!");
    }
}
