// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract DisputeDoS is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    DisputeResolver public disputeResolver;
    MockERC20 public usdc;

    address public owner = address(0x1);
    address public poster = address(0x2);
    address public performer = address(0x3);

    address public protocolTreasury = address(0x10);
    address public resolverTreasury = address(0x11);
    address public labsTreasury = address(0x12);
    address public resolversDAO = address(0x13);
    address public protocolDAO = address(0x14);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        vm.startPrank(owner);
        // Deploy Mock USDC
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy DisputeResolver
        disputeResolver = new DisputeResolver(
            address(usdc),
            resolversDAO,
            protocolDAO,
            protocolTreasury,
            resolverTreasury
        );

        // Deploy PaymentRouter
        paymentRouter =
            new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury);

        // Deploy MissionFactory
        factory = new MissionFactory(address(usdc), address(paymentRouter));
        factory.setDisputeResolver(address(disputeResolver));

        // Set factory on router
        paymentRouter.setMissionFactory(address(factory));
        vm.stopPrank();

        // Mint USDC to poster and performer
        usdc.mint(poster, 1000e6);
        usdc.mint(performer, 1000e6); // For DDR if needed

        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);

        vm.prank(performer);
        usdc.approve(address(disputeResolver), 1000e6);
    }

    function test_DirectCall_Reverts() public {
        // 1. Poster creates a mission
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrowAddress = factory.missions(missionId);
        MissionEscrow escrow = MissionEscrow(escrowAddress);

        // 2. Performer accepts
        vm.prank(performer);
        escrow.acceptMission();

        // 3. Performer tries to raise dispute DIRECTLY on Escrow
        // This MUST revert now
        vm.prank(performer);
        vm.expectRevert(IMissionEscrow.NotDisputeResolver.selector);
        escrow.raiseDispute(bytes32("griefing"));
    }

    function test_ResolverCall_Succeeds() public {
        // 1. Poster creates a mission
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrowAddress = factory.missions(missionId);
        MissionEscrow escrow = MissionEscrow(escrowAddress);

        // 2. Performer accepts
        vm.prank(performer);
        escrow.acceptMission();

        // 3. Performer raises dispute via DisputeResolver
        vm.prank(performer);
        disputeResolver.createDispute(escrowAddress, missionId, bytes32("evidence"));

        // 4. Verify state is Disputed on Escrow
        (,, IMissionEscrow.MissionState state) = escrow.getParticipants();
        assertEq(uint(state), uint(IMissionEscrow.MissionState.Disputed));

        // 5. Verify DisputeResolver has record
        uint256[] memory disputes = disputeResolver.getDisputesByMission(missionId);
        assertEq(disputes.length, 1);
    }
}
