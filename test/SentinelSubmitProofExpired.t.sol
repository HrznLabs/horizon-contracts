// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SentinelSubmitProofExpiredTest is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public disputeResolver = address(4);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        vm.startPrank(owner);
        // Deploy Mock USDC with args
        usdc = new MockERC20("USDC", "USDC", 6);
        // Deploy PaymentRouter
        paymentRouter = new PaymentRouter(address(usdc), address(5), address(6), address(7));
        // Deploy Factory
        factory = new MissionFactory(address(usdc), address(paymentRouter));
        factory.setDisputeResolver(disputeResolver);
        // Set MissionFactory in Router for authorization
        paymentRouter.setMissionFactory(address(factory));
        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);
    }

    function test_PerformerCannotSubmitProofAfterExpiry() public {
        vm.startPrank(poster);
        uint256 expiresAt = block.timestamp + 1 days;
        uint256 missionId =
            factory.createMission(REWARD_AMOUNT, expiresAt, address(0), bytes32(0), bytes32(0));
        vm.stopPrank();

        address escrowAddress = factory.missions(missionId);
        MissionEscrow escrow = MissionEscrow(escrowAddress);

        // Performer accepts
        vm.prank(performer);
        escrow.acceptMission();

        // Fast forward past expiration
        vm.warp(expiresAt + 1);

        // Performer submits proof - SHOULD REVERT now
        vm.prank(performer);
        vm.expectRevert(IMissionEscrow.MissionExpired.selector);
        escrow.submitProof(bytes32("late_proof"));

        // Confirm state is STILL Accepted (not Submitted)
        IMissionEscrow.MissionRuntime memory runtime = escrow.getRuntime();
        assertEq(uint256(runtime.state), uint256(IMissionEscrow.MissionState.Accepted));

        // Now poster tries to claim expired - SHOULD SUCCEED
        vm.prank(poster);
        escrow.claimExpired();

        // Assert state is Cancelled
        runtime = escrow.getRuntime();
        assertEq(uint256(runtime.state), uint256(IMissionEscrow.MissionState.Cancelled));

        // Assert poster got refund
        assertEq(usdc.balanceOf(poster), 1000e6); // Back to original amount
    }
}
