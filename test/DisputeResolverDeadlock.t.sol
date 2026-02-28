// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { IDisputeResolver } from "../src/interfaces/IDisputeResolver.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract DisputeResolverDeadlock is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    DisputeResolver public resolver;
    MockERC20 public usdc;

    address public owner = address(0x1);
    address public poster = address(0x2);
    address public performer = address(0x3);
    address public resolversDAO = address(0x4);
    address public protocolDAO = address(0x5);

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

        // Deploy DisputeResolver
        resolver = new DisputeResolver(
            address(usdc), address(factory), resolversDAO, protocolDAO, protocolTreasury, resolverTreasury
        );

        // Set DisputeResolver in Factory
        factory.setDisputeResolver(address(resolver));

        // Setup Router to allow Factory
        paymentRouter.setMissionFactory(address(factory));

        vm.stopPrank();

        // Mint USDC to poster and performer (for DDR)
        usdc.mint(poster, 1000e6);
        usdc.mint(performer, 1000e6);

        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);

        vm.prank(poster);
        usdc.approve(address(resolver), 1000e6);

        vm.prank(performer);
        usdc.approve(address(resolver), 1000e6);
    }

    function test_DisputeDeadlock_OnePartyNoShow() public {
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

        // 3. Performer submits proof
        vm.prank(performer);
        escrow.submitProof(keccak256("proof"));

        // 4. Performer creates dispute (in Resolver) paying DDR
        // This will automatically call escrow.raiseDispute()
        vm.startPrank(performer);
        uint256 disputeId = resolver.createDispute(escrowAddress, missionId, keccak256("evidence"));
        vm.stopPrank();

        // 6. Assign a resolver (by DAO)
        vm.prank(resolversDAO);
        address assignedResolver = address(0x99);
        resolver.assignResolver(disputeId, assignedResolver);

        // 7. Poster does NOT submit evidence or pay DDR (Simulating abandonment/malice)

        // 8. Resolver tries to resolve in favor of Performer
        vm.startPrank(assignedResolver);
        // Should succeed now even without Poster DDR
        resolver.resolveDispute(
            disputeId, IDisputeResolver.DisputeOutcome.PerformerWins, keccak256("resolution"), 0
        );
        vm.stopPrank();

        // 9. Finalize (after appeal period)
        vm.warp(block.timestamp + resolver.getAppealPeriod() + 1);
        resolver.finalizeDispute(disputeId);

        console.log("Deadlock resolved: Performer wins successfully");
    }
}
