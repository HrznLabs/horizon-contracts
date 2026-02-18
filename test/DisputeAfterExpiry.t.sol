// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DisputeAfterExpiryTest is Test {
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
        usdc = new MockERC20("USDC", "USDC", 6);
        paymentRouter = new PaymentRouter(address(usdc), address(5), address(6), address(7));
        factory = new MissionFactory(address(usdc), address(paymentRouter));
        factory.setDisputeResolver(disputeResolver);
        factory.transferOwnership(owner);
        vm.stopPrank();

        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);
    }

    function test_PerformerCanGriefPosterAfterExpiry() public {
        vm.startPrank(poster);
        uint256 expiresAt = block.timestamp + 1 days;
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT,
            expiresAt,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrowAddress = factory.missions(missionId);
        MissionEscrow escrow = MissionEscrow(escrowAddress);

        // Performer accepts
        vm.prank(performer);
        escrow.acceptMission();

        // Fast forward past expiration
        vm.warp(expiresAt + 1);

        // Performer raises dispute (Griefing Attack)
        vm.prank(performer);
        escrow.raiseDispute(bytes32("grief"));

        // Verify state is Disputed
        IMissionEscrow.MissionRuntime memory runtime = escrow.getRuntime();
        assertEq(uint256(runtime.state), uint256(IMissionEscrow.MissionState.Disputed));

        // Poster tries to claim expired funds - REVERTS
        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.claimExpired();
    }
}
