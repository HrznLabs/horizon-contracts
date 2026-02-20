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

contract DisputeResolverSecurity is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    DisputeResolver public disputeResolverContract;
    MockERC20 public usdc;

    address public owner = address(0x1);
    address public poster = address(0x2);
    address public performer = address(0x3);
    address public resolver = address(0x4);
    address public resolversDAO = address(0x5);
    address public protocolDAO = address(0x6);
    address public attacker = address(0x7);

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

        // Deploy DisputeResolver
        disputeResolverContract = new DisputeResolver(
            address(usdc), resolversDAO, protocolDAO, protocolTreasury, resolverTreasury
        );

        // Deploy MissionFactory
        factory = new MissionFactory(address(usdc), address(paymentRouter));
        factory.setDisputeResolver(address(disputeResolverContract));
        vm.stopPrank();

        // Mint USDC to poster and performer (for DDR)
        usdc.mint(poster, 1000e6);
        usdc.mint(performer, 1000e6);

        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);

        vm.prank(poster);
        usdc.approve(address(disputeResolverContract), 1000e6);

        vm.prank(performer);
        usdc.approve(address(disputeResolverContract), 1000e6);
    }

    function test_AppealBypass() public {
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

        // 4. Poster raises dispute on Escrow first
        vm.prank(poster);
        escrow.raiseDispute(keccak256("evidence"));

        // Then create dispute on Resolver
        vm.prank(poster);
        uint256 disputeId =
            disputeResolverContract.createDispute(escrowAddress, missionId, keccak256("evidence"));

        // 5. Assign resolver
        vm.prank(resolversDAO);
        disputeResolverContract.assignResolver(disputeId, resolver);

        // 6. Performer deposits DDR and submits evidence
        vm.prank(performer);
        disputeResolverContract.submitEvidence(disputeId, keccak256("evidence2"));

        // 7. Resolver resolves dispute (PosterWins)
        vm.prank(resolver);
        disputeResolverContract.resolveDispute(
            disputeId, IDisputeResolver.DisputeOutcome.PosterWins, keccak256("resolution"), 0
        );

        // Verify state is Resolved
        IDisputeResolver.Dispute memory dispute = disputeResolverContract.getDispute(disputeId);
        assertEq(uint256(dispute.state), uint256(IDisputeResolver.DisputeState.Resolved));

        // 8. Performer appeals
        vm.prank(performer);
        disputeResolverContract.appealResolution(disputeId);

        // Verify state is Appealed
        dispute = disputeResolverContract.getDispute(disputeId);
        assertEq(uint256(dispute.state), uint256(IDisputeResolver.DisputeState.Appealed));

        // 9. Attacker calls finalizeDispute - SHOULD REVERT
        vm.prank(attacker);
        vm.expectRevert(IDisputeResolver.InvalidDisputeState.selector);
        disputeResolverContract.finalizeDispute(disputeId);

        // 10. Verify state is still Appealed
        dispute = disputeResolverContract.getDispute(disputeId);
        assertEq(uint256(dispute.state), uint256(IDisputeResolver.DisputeState.Appealed));
    }
}
