// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract DisputeFeeBypass is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    MockERC20 public usdc;

    address public owner = address(0x1);
    address public poster = address(0x2);
    address public performer = address(0x3);
    address public disputeResolver = address(0x4); // Mock resolver

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

        // Set factory on router
        paymentRouter.setMissionFactory(address(factory));
        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);
    }

    function test_PerformerGetsRewardWithFeesAfterDispute() public {
        // 1. Poster creates a mission
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

        // 3. Performer raises dispute (simulating bad faith or just greedy)
        vm.prank(performer);
        escrow.raiseDispute(bytes32("dispute"));

        // 4. Resolver settles in favor of Performer (Outcome 2)
        // This simulates the DisputeResolver contract calling settleDispute
        vm.prank(disputeResolver);
        escrow.settleDispute(2, 0); // Outcome 2 = PerformerWins

        // 5. Check balances
        // Performer should receive 90% of reward (10% fees)
        uint256 performerBalance = usdc.balanceOf(performer);
        console.log("Performer Balance:", performerBalance);

        // Fees: 4% + 4% + 2% = 10%
        // 100 * 0.9 = 90 USDC
        assertEq(performerBalance, 90e6, "Performer should get 90% reward after fees");

        // Ensure Treasuries got their share
        assertEq(usdc.balanceOf(protocolTreasury), 4e6, "Protocol treasury got 4%");
        assertEq(usdc.balanceOf(labsTreasury), 4e6, "Labs treasury got 4%");
        assertEq(usdc.balanceOf(resolverTreasury), 2e6, "Resolver treasury got 2%");
    }

    function test_SplitOutcomeApplyFees() public {
        // 1. Poster creates a mission
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

        // 3. Performer raises dispute
        vm.prank(performer);
        escrow.raiseDispute(bytes32("dispute"));

        // 4. Resolver settles with SPLIT (Outcome 3)
        // Split 50% (5000 bps)
        vm.prank(disputeResolver);
        escrow.settleDispute(3, 5000);

        // 5. Check balances
        // Performer gets 50% of 100 = 50. Fees = 10% of 50 = 5.
        // Performer gets 45.
        uint256 performerBalance = usdc.balanceOf(performer);
        console.log("Performer Balance:", performerBalance);
        assertEq(performerBalance, 45e6, "Performer should get 45% reward after split + fees");

        // Poster gets 50% refund (no fees)
        // Poster started with 1000, paid 100. Refund 50. Total 950.
        assertEq(usdc.balanceOf(poster), 950e6, "Poster should get 50% refund");

        // Fees: 4% + 4% + 2% of 50 = 5 total
        // Protocol: 4% of 50 = 2
        // Labs: 4% of 50 = 2
        // Resolver: 2% of 50 = 1
        assertEq(usdc.balanceOf(protocolTreasury), 2e6, "Protocol treasury got 4% of split");
        assertEq(usdc.balanceOf(labsTreasury), 2e6, "Labs treasury got 4% of split");
        assertEq(usdc.balanceOf(resolverTreasury), 1e6, "Resolver treasury got 2% of split");
    }
}
