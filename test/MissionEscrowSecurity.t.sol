// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title MissionEscrowSecurityTest
 * @notice Tests for SEC-02: Dispute settlement routes performer payments through PaymentRouter
 */
contract MissionEscrowSecurityTest is Test {
    PaymentRouter public router;
    MissionFactory public factory;
    MockERC20 public usdc;

    address public admin = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);
    address public disputeResolverAddr = address(10);

    uint256 public constant REWARD_AMOUNT = 1000e6; // 1000 USDC
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockERC20("USD Coin", "USDC", 6);

        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            admin
        );

        factory = new MissionFactory(address(router));
        router.setMissionFactory(address(factory));
        factory.setDisputeResolver(disputeResolverAddr);

        vm.stopPrank();

        usdc.mint(poster, 100_000e6);
    }

    // =========================================================================
    // Helper: create mission, accept, raise dispute
    // =========================================================================

    function _createDisputedMission() internal returns (address escrow, uint256 missionId) {
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256("proof"));

        vm.prank(poster);
        MissionEscrow(escrow).raiseDispute(keccak256("dispute-evidence"));
    }

    // =========================================================================
    // SEC-02: Dispute settlement — performer payment routed through PaymentRouter
    // =========================================================================

    function test_DisputePerformerWins_RoutedThroughPaymentRouter() public {
        (address escrow,) = _createDisputedMission();

        // Before settlement: escrow holds all funds
        uint256 escrowBalBefore = usdc.balanceOf(escrow);
        assertEq(escrowBalBefore, REWARD_AMOUNT);

        // Settle: outcome 2 = PerformerWins
        vm.prank(disputeResolverAddr);
        MissionEscrow(escrow).settleDispute(2, 0);

        // Performer should receive ~90% (after protocol fees)
        uint256 performerBal = usdc.balanceOf(performer);
        // Expected: 1000 USDC - 2.5% protocol - 2.5% labs - 2% resolver = 93%
        // 930 USDC for performer (no guild)
        assertEq(performerBal, 930e6, "Performer should receive 93% (no guild fee)");

        // Protocol treasury should receive 2.5%
        assertEq(usdc.balanceOf(protocolTreasury), 25e6, "Protocol treasury should receive 2.5%");

        // Labs treasury should receive 2.5%
        assertEq(usdc.balanceOf(labsTreasury), 25e6, "Labs treasury should receive 2.5%");

        // Resolver treasury should receive 2%
        assertEq(usdc.balanceOf(resolverTreasury), 20e6, "Resolver treasury should receive 2%");

        // Escrow should be empty
        assertEq(usdc.balanceOf(escrow), 0, "Escrow should be empty after settlement");
    }

    function test_DisputePosterWins_DirectRefund() public {
        (address escrow,) = _createDisputedMission();

        uint256 posterBalBefore = usdc.balanceOf(poster);

        // Settle: outcome 1 = PosterWins
        vm.prank(disputeResolverAddr);
        MissionEscrow(escrow).settleDispute(1, 0);

        // Poster should get full refund (no protocol fees on refunds)
        uint256 posterBalAfter = usdc.balanceOf(poster);
        assertEq(posterBalAfter - posterBalBefore, REWARD_AMOUNT, "Poster should receive full refund");

        // No fees should have been distributed
        assertEq(usdc.balanceOf(protocolTreasury), 0, "No protocol fee on refund");
        assertEq(usdc.balanceOf(labsTreasury), 0, "No labs fee on refund");
        assertEq(usdc.balanceOf(resolverTreasury), 0, "No resolver fee on refund");
    }

    function test_DisputeSplit_PerformerPortionRoutedThroughRouter() public {
        (address escrow,) = _createDisputedMission();

        uint256 posterBalBefore = usdc.balanceOf(poster);

        // Settle: outcome 3 = Split, 60% to performer
        vm.prank(disputeResolverAddr);
        MissionEscrow(escrow).settleDispute(3, 6000);

        // Performer portion = 1000 * 60% = 600 USDC, routed through PaymentRouter
        // Performer gets: 600 - 2.5% - 2.5% - 2% = 600 * 93% = 558 USDC
        uint256 performerBal = usdc.balanceOf(performer);
        assertEq(performerBal, 558e6, "Performer should receive 93% of their split portion");

        // Poster gets direct refund of remaining 40% = 400 USDC (no fees)
        uint256 posterBalAfter = usdc.balanceOf(poster);
        assertEq(posterBalAfter - posterBalBefore, 400e6, "Poster should receive 40% direct refund");

        // Protocol fees only on performer's portion (600 USDC)
        assertEq(usdc.balanceOf(protocolTreasury), 15e6, "Protocol: 2.5% of 600");
        assertEq(usdc.balanceOf(labsTreasury), 15e6, "Labs: 2.5% of 600");
        assertEq(usdc.balanceOf(resolverTreasury), 12e6, "Resolver: 2% of 600");

        // Escrow should be empty
        assertEq(usdc.balanceOf(escrow), 0, "Escrow should be empty");
    }

    function test_DisputeCancelled_DirectRefund() public {
        (address escrow,) = _createDisputedMission();

        uint256 posterBalBefore = usdc.balanceOf(poster);

        // Settle: outcome 4 = Cancelled
        vm.prank(disputeResolverAddr);
        MissionEscrow(escrow).settleDispute(4, 0);

        // Poster gets full refund (no fees on cancellation)
        uint256 posterBalAfter = usdc.balanceOf(poster);
        assertEq(posterBalAfter - posterBalBefore, REWARD_AMOUNT, "Poster should receive full refund on cancel");
    }

    function test_DisputeInvalidOutcome_Reverts() public {
        (address escrow,) = _createDisputedMission();

        vm.prank(disputeResolverAddr);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        MissionEscrow(escrow).settleDispute(0, 0);

        vm.prank(disputeResolverAddr);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        MissionEscrow(escrow).settleDispute(5, 0);
    }

    function test_DisputeNotResolver_Reverts() public {
        (address escrow,) = _createDisputedMission();

        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.NotDisputeResolver.selector);
        MissionEscrow(escrow).settleDispute(2, 0);
    }

    function test_DisputeNotDisputedState_Reverts() public {
        // Create mission but don't raise dispute
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        // Try to settle dispute on a non-disputed mission
        vm.prank(disputeResolverAddr);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        MissionEscrow(escrow).settleDispute(2, 0);
    }

    function test_DisputeSettledEmitsEvent() public {
        (address escrow, uint256 missionId) = _createDisputedMission();

        // Expect the DisputeSettled event
        vm.expectEmit(true, false, false, true);
        emit IMissionEscrow.DisputeSettled(missionId, 2, 0, REWARD_AMOUNT);

        vm.prank(disputeResolverAddr);
        MissionEscrow(escrow).settleDispute(2, 0);
    }

    function test_DisputeSettled_StateTransition() public {
        (address escrow,) = _createDisputedMission();

        // Verify disputed state
        IMissionEscrow.MissionRuntime memory runtime = MissionEscrow(escrow).getRuntime();
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Disputed));

        vm.prank(disputeResolverAddr);
        MissionEscrow(escrow).settleDispute(2, 0);

        // Verify completed state
        runtime = MissionEscrow(escrow).getRuntime();
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Completed));
    }
}
