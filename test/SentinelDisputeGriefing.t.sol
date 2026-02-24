// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract SentinelDisputeGriefing is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    DisputeResolver public disputeResolverContract;
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

        // Mint USDC to poster and performer
        usdc.mint(poster, 1000e6);
        usdc.mint(performer, 1000e6);

        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);

        vm.prank(performer);
        usdc.approve(address(disputeResolverContract), 1000e6); // For DDR if needed
    }

    function test_Griefing_DirectRaiseDispute_Reverts() public {
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

        // 3. Performer tries to raise dispute DIRECTLY (bypassing DDR)
        // This MUST revert with NotDisputeResolver
        vm.prank(performer);
        vm.expectRevert(IMissionEscrow.NotDisputeResolver.selector);
        escrow.raiseDispute(keccak256("griefing"));

        // 4. Verify state is STILL Accepted (not Disputed)
        assertEq(uint256(escrow.getRuntime().state), uint256(IMissionEscrow.MissionState.Accepted));
    }

    function test_ValidDispute_ViaResolver_Succeeds() public {
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

        // 3. Performer raises dispute via DisputeResolver (paying DDR)
        vm.prank(performer);
        disputeResolverContract.createDispute(escrowAddress, missionId, keccak256("valid dispute"));

        // 4. Verify state is Disputed (Escrow state updated)
        assertEq(uint256(escrow.getRuntime().state), uint256(IMissionEscrow.MissionState.Disputed));

        // 5. Verify DisputeResolver has the dispute
        uint256[] memory disputes = disputeResolverContract.getDisputesByMission(missionId);
        assertEq(disputes.length, 1);

        // 6. Verify DDR was collected
        uint256 disputeId = disputes[0];
        uint256 ddrAmount = disputeResolverContract.getDDRDeposit(disputeId, performer);
        assertEq(ddrAmount, 5e6); // 5% of 100 USDC = 5 USDC
    }
}
