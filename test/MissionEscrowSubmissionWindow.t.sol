// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title MissionEscrowSubmissionWindowTest
 * @notice Covers the post-expiry submission grace window (issue #781).
 *
 * Behaviour under test:
 *  - a performer may submit proof until expiresAt + SUBMISSION_GRACE_PERIOD
 *  - after that window the submission is rejected
 *  - the poster may only reclaim once the window has closed
 *  - once proof exists the poster must approve or dispute, never unilaterally reclaim
 */
contract MissionEscrowSubmissionWindowTest is Test {
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

    uint256 public constant REWARD_AMOUNT = 1000e6;
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");
    bytes32 public constant PROOF_HASH = keccak256("proof");

    uint256 public expiresAt;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(
            address(usdc), protocolTreasury, resolverTreasury, labsTreasury, admin
        );
        factory = new MissionFactory(address(router));
        router.setMissionFactory(address(factory));
        factory.setDisputeResolver(disputeResolverAddr);
        vm.stopPrank();

        usdc.mint(poster, 100_000e6);
    }

    /// @dev Mission created and accepted, sitting in Accepted state.
    function _acceptedMission() internal returns (MissionEscrow escrow) {
        expiresAt = block.timestamp + 1 days;

        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc), REWARD_AMOUNT, expiresAt, address(0), METADATA_HASH, LOCATION_HASH
        );
        vm.stopPrank();

        escrow = MissionEscrow(factory.getMission(missionId));

        vm.prank(performer);
        escrow.acceptMission();
    }

    // =========================================================================
    // Submission window
    // =========================================================================

    function test_SubmitProof_BeforeExpiry() public {
        MissionEscrow escrow = _acceptedMission();

        vm.prank(performer);
        escrow.submitProof(PROOF_HASH);

        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Submitted));
    }

    function test_SubmitProof_WithinGraceAfterExpiry() public {
        MissionEscrow escrow = _acceptedMission();

        // 1 hour past expiry — inside the 24h grace window
        vm.warp(expiresAt + 1 hours);

        vm.prank(performer);
        escrow.submitProof(PROOF_HASH);

        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Submitted));
    }

    function test_SubmitProof_AtGraceBoundary() public {
        MissionEscrow escrow = _acceptedMission();

        vm.warp(expiresAt + escrow.SUBMISSION_GRACE_PERIOD());

        vm.prank(performer);
        escrow.submitProof(PROOF_HASH);

        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Submitted));
    }

    function test_RevertWhen_SubmitProof_AfterGraceClosed() public {
        MissionEscrow escrow = _acceptedMission();

        vm.warp(expiresAt + escrow.SUBMISSION_GRACE_PERIOD() + 1);

        vm.prank(performer);
        vm.expectRevert(IMissionEscrow.SubmissionWindowClosed.selector);
        escrow.submitProof(PROOF_HASH);
    }

    // =========================================================================
    // Poster reclaim
    // =========================================================================

    function test_RevertWhen_ClaimExpired_DuringGrace() public {
        MissionEscrow escrow = _acceptedMission();

        // Expired, but the performer still holds the grace window
        vm.warp(expiresAt + 1);

        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.MissionNotExpired.selector);
        escrow.claimExpired();
    }

    function test_ClaimExpired_AfterGrace_WhenNothingSubmitted() public {
        MissionEscrow escrow = _acceptedMission();
        uint256 balanceBefore = usdc.balanceOf(poster);

        vm.warp(expiresAt + escrow.SUBMISSION_GRACE_PERIOD() + 1);

        vm.prank(poster);
        escrow.claimExpired();

        assertEq(usdc.balanceOf(poster), balanceBefore + REWARD_AMOUNT);
        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Cancelled));
    }

    /// @notice The core fix: delivered work cannot be reclaimed out from under the performer.
    function test_RevertWhen_ClaimExpired_AfterProofSubmitted() public {
        MissionEscrow escrow = _acceptedMission();

        vm.prank(performer);
        escrow.submitProof(PROOF_HASH);

        vm.warp(expiresAt + escrow.SUBMISSION_GRACE_PERIOD() + 1);

        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.ProofAlreadySubmitted.selector);
        escrow.claimExpired();
    }

    /// @notice Neither side is stuck: the poster still has the dispute path.
    function test_PosterCanDisputeSubmittedWorkAfterExpiry() public {
        MissionEscrow escrow = _acceptedMission();

        vm.prank(performer);
        escrow.submitProof(PROOF_HASH);

        vm.warp(expiresAt + escrow.SUBMISSION_GRACE_PERIOD() + 1);

        vm.prank(poster);
        escrow.raiseDispute(keccak256("bad work"));

        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Disputed));
    }

    /// @notice And the performer can dispute a poster who simply goes quiet.
    function test_PerformerCanDisputeUnresponsivePoster() public {
        MissionEscrow escrow = _acceptedMission();

        vm.prank(performer);
        escrow.submitProof(PROOF_HASH);

        vm.warp(expiresAt + 30 days);

        vm.prank(performer);
        escrow.raiseDispute(keccak256("poster unresponsive"));

        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Disputed));
    }

    // =========================================================================
    // Fuzz: the window boundary holds for any offset
    // =========================================================================

    function testFuzz_SubmissionWindowBoundary(uint256 offset) public {
        offset = bound(offset, 1, 365 days);
        MissionEscrow escrow = _acceptedMission();
        uint256 grace = escrow.SUBMISSION_GRACE_PERIOD();

        vm.warp(expiresAt + offset);

        vm.prank(performer);
        if (offset <= grace) {
            escrow.submitProof(PROOF_HASH);
            assertEq(
                uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Submitted)
            );
        } else {
            vm.expectRevert(IMissionEscrow.SubmissionWindowClosed.selector);
            escrow.submitProof(PROOF_HASH);
        }
    }

    // =========================================================================
    // Disputed funds are off-limits to unilateral reclaim
    // =========================================================================

    /// @notice A poster must not be able to drain a disputed escrow after expiry.
    /// Without this guard the poster wins every dispute by waiting: claimExpired
    /// sets Cancelled and empties the escrow, after which settleDispute() can
    /// never run again (it requires the Disputed state).
    function test_RevertWhen_ClaimExpired_WhileDisputed() public {
        MissionEscrow escrow = _acceptedMission();

        vm.prank(performer);
        escrow.submitProof(PROOF_HASH);

        vm.prank(poster);
        escrow.raiseDispute(keccak256("disagreement"));

        vm.warp(expiresAt + escrow.SUBMISSION_GRACE_PERIOD() + 1);

        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.DisputeAlreadyRaised.selector);
        escrow.claimExpired();
    }

    /// @notice Same protection when the dispute was raised straight from Accepted.
    function test_RevertWhen_ClaimExpired_WhileDisputedFromAccepted() public {
        MissionEscrow escrow = _acceptedMission();

        vm.prank(performer);
        escrow.raiseDispute(keccak256("poster went quiet"));

        vm.warp(expiresAt + escrow.SUBMISSION_GRACE_PERIOD() + 30 days);

        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.DisputeAlreadyRaised.selector);
        escrow.claimExpired();
    }

    /// @notice The escrow still holds the reward, so settlement remains possible
    /// however long the dispute takes.
    function test_DisputedEscrowRetainsFundsLongAfterExpiry() public {
        MissionEscrow escrow = _acceptedMission();

        vm.prank(performer);
        escrow.submitProof(PROOF_HASH);
        vm.prank(poster);
        escrow.raiseDispute(keccak256("disagreement"));

        vm.warp(expiresAt + 365 days);

        assertEq(usdc.balanceOf(address(escrow)), REWARD_AMOUNT);
        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Disputed));

        // And the resolver can still settle in the performer's favour.
        vm.prank(disputeResolverAddr);
        escrow.settleDispute(2, 0);
        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Completed));
    }
}
