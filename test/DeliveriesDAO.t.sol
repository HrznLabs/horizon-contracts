// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeliveriesDAO} from "../src/DeliveriesDAO.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDeliveryRegistry} from "./mocks/MockDeliveryRegistry.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";

contract DeliveriesDAOTest is Test {
    DeliveriesDAO public dao;
    MockERC20 public usdc;
    MockDeliveryRegistry public registry;

    /// @notice Reward escrowed for each registered test mission.
    uint256 public constant ESCROWED_REWARD = 1000e6;

    address public owner = address(1);
    address public performer1 = address(2);
    address public performer2 = address(3);
    address public poster = address(4);

    uint256 public constant INITIAL_BALANCE = 10000e6; // 10,000 USDC

    /// @notice Capital seeded into the insurance pool by the DAO.
    /// @dev Audit M4: policies are now reserved 1:1 against pool capital, so the pool must
    ///      be genuinely funded before it can underwrite anything. Premiums (1–2% of
    ///      coverage) can never back 100% payouts on their own.
    uint256 public constant POOL_SEED = 1000e6; // 1,000 USDC

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy DeliveriesDAO
        dao = new DeliveriesDAO(address(usdc));

        vm.stopPrank();

        // Audit M4 residual: policies must reference real orders of the delivery factory.
        registry = new MockDeliveryRegistry();
        for (uint256 id = 1; id <= 3; id++) {
            registry.setMission(id, poster, ESCROWED_REWARD);
        }
        registry.setMission(42, poster, ESCROWED_REWARD);
        _wire(dao);

        // Mint USDC to poster
        usdc.mint(poster, INITIAL_BALANCE);

        // Capitalise the insurance pool so policies can actually be underwritten.
        usdc.mint(owner, POOL_SEED);
        vm.startPrank(owner);
        usdc.approve(address(dao), POOL_SEED);
        dao.fundPool(POOL_SEED);
        vm.stopPrank();
    }

    /// @notice A DAO whose insurance pool has NOT been capitalised.
    function _uncapitalisedDao() internal returns (DeliveriesDAO fresh) {
        vm.prank(owner);
        fresh = new DeliveriesDAO(address(usdc));
        _wire(fresh);
    }

    function _wire(DeliveriesDAO d) internal {
        vm.prank(owner);
        d.setDeliveryFactory(address(registry));
    }

    // =============================================================================
    // PERFORMER CURATION TESTS
    // =============================================================================

    function test_CuratePerformer() public {
        vm.prank(owner);
        dao.curatePerformer(performer1, 85);

        assertTrue(dao.curatedPerformers(performer1));
        assertEq(dao.performerRating(performer1), 85);
    }

    function test_RemovePerformer() public {
        // First curate
        vm.startPrank(owner);
        dao.curatePerformer(performer1, 85);
        
        // Then remove
        dao.removePerformer(performer1);
        vm.stopPrank();

        assertFalse(dao.curatedPerformers(performer1));
        assertEq(dao.performerRating(performer1), 0);
    }

    function test_UpdatePerformerRating() public {
        vm.startPrank(owner);
        dao.curatePerformer(performer1, 85);
        
        // Update rating
        dao.updatePerformerRating(performer1, 95);
        vm.stopPrank();

        assertEq(dao.performerRating(performer1), 95);
    }

    function test_RevertWhen_NonOwnerCuratesPerformer() public {
        vm.prank(performer1);
        vm.expectRevert();
        dao.curatePerformer(performer2, 85);
    }

    function test_RevertWhen_RatingExceeds100() public {
        vm.prank(owner);
        vm.expectRevert("Rating must be 0-100");
        dao.curatePerformer(performer1, 101);
    }

    function test_IsPerformerCurated() public {
        vm.prank(owner);
        dao.curatePerformer(performer1, 85);

        assertTrue(dao.isPerformerCurated(performer1));
        assertFalse(dao.isPerformerCurated(performer2));
    }

    // =============================================================================
    // INSURANCE FEE TESTS
    // =============================================================================

    function test_GetInsuranceFee_Curated() public {
        uint256 rewardAmount = 100e6; // 100 USDC
        uint256 fee = dao.getInsuranceFee(rewardAmount, true);
        
        // Curated fee is 1% (100 basis points)
        assertEq(fee, 1e6); // 1 USDC
    }

    function test_GetInsuranceFee_Public() public {
        uint256 rewardAmount = 100e6; // 100 USDC
        uint256 fee = dao.getInsuranceFee(rewardAmount, false);
        
        // Public fee is 2% (200 basis points)
        assertEq(fee, 2e6); // 2 USDC
    }

    function test_UpdateFees() public {
        vm.prank(owner);
        dao.updateFees(150, 250); // 1.5% and 2.5%

        assertEq(dao.curatedInsuranceFee(), 150);
        assertEq(dao.publicInsuranceFee(), 250);
    }

    function test_RevertWhen_FeeExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.InvalidFeeRate.selector);
        dao.updateFees(1001, 200); // Exceeds 10% max
    }

    // =============================================================================
    // INSURANCE POLICY TESTS
    // =============================================================================

    function test_CreateInsurancePolicy() public {
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6; // 100 USDC
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6); // 2% premium
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        vm.stopPrank();

        // Verify policy created
        DeliveriesDAO.InsurancePolicy memory policy = dao.getPolicy(missionId);
        assertEq(policy.missionId, missionId);
        assertEq(policy.poster, poster);
        assertEq(policy.coverageAmount, coverageAmount);
        assertEq(policy.premium, 2e6); // 2% of 100 USDC
        assertTrue(policy.active);
        assertFalse(policy.claimed);

        // Verify pool balance updated
        (uint256 poolBalance, , uint256 totalPremiums) = dao.getPoolStats();
        assertEq(poolBalance, POOL_SEED + 2e6);
        assertEq(totalPremiums, 2e6);
        // Coverage is now reserved against the pool.
        assertEq(dao.reservedCoverage(), coverageAmount);
    }

    function test_CreateInsurancePolicy_Curated() public {
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 1e6); // 1% premium for curated
        dao.createInsurancePolicy(missionId, coverageAmount, true);
        vm.stopPrank();

        DeliveriesDAO.InsurancePolicy memory policy = dao.getPolicy(missionId);
        assertEq(policy.premium, 1e6); // 1% of 100 USDC
    }

    function test_RevertWhen_PolicyAlreadyExists() public {
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 4e6); // Enough for 2 policies
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        
        vm.expectRevert("Policy already exists");
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        vm.stopPrank();
    }

    // =============================================================================
    // INSURANCE CLAIM TESTS
    // =============================================================================

    function test_SubmitInsuranceClaim() public {
        // First create a policy
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        
        // Submit claim
        bytes32 evidenceHash = keccak256("evidence");
        uint256 requestedAmount = 50e6; // Claim 50 USDC
        dao.submitInsuranceClaim(missionId, evidenceHash, requestedAmount);
        vm.stopPrank();

        // Verify claim created
        DeliveriesDAO.InsuranceClaim memory claim = dao.getClaim(0);
        assertEq(claim.missionId, missionId);
        assertEq(claim.claimant, poster);
        assertEq(claim.evidenceHash, evidenceHash);
        assertEq(claim.requestedAmount, requestedAmount);
        assertFalse(claim.approved);
        assertFalse(claim.processed);

        // Verify policy marked as claimed
        DeliveriesDAO.InsurancePolicy memory policy = dao.getPolicy(missionId);
        assertTrue(policy.claimed);
    }

    function test_RevertWhen_ClaimExceedsCoverage() public {
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        
        vm.expectRevert("Exceeds coverage");
        dao.submitInsuranceClaim(missionId, keccak256("evidence"), 150e6); // More than coverage
        vm.stopPrank();
    }

    function test_RevertWhen_PolicyNotActive() public {
        uint256 missionId = 999; // Non-existent policy
        
        vm.prank(poster);
        vm.expectRevert(DeliveriesDAO.PolicyNotActive.selector);
        dao.submitInsuranceClaim(missionId, keccak256("evidence"), 50e6);
    }

    function test_ProcessInsuranceClaim_Approved() public {
        // Create policy and submit claim
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        dao.submitInsuranceClaim(missionId, keccak256("evidence"), 50e6);
        vm.stopPrank();

        uint256 posterBalanceBefore = usdc.balanceOf(poster);

        // Process claim (approve) - payout 1.5 USDC (pool has 2 USDC)
        vm.prank(owner);
        dao.processInsuranceClaim(0, true, 1.5e6);

        // Verify claim processed
        DeliveriesDAO.InsuranceClaim memory claim = dao.getClaim(0);
        assertTrue(claim.approved);
        assertTrue(claim.processed);
        assertEq(claim.paidAmount, 1.5e6);

        // Verify payout sent
        assertEq(usdc.balanceOf(poster), posterBalanceBefore + 1.5e6);

        // Verify pool balance decreased
        (uint256 poolBalance, uint256 totalClaims, ) = dao.getPoolStats();
        assertEq(poolBalance, POOL_SEED + 2e6 - 1.5e6);
        assertEq(totalClaims, 1.5e6);
        // Settling the claim releases the policy's reserve.
        assertEq(dao.reservedCoverage(), 0);
    }

    function test_ProcessInsuranceClaim_Rejected() public {
        // Create policy and submit claim
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        dao.submitInsuranceClaim(missionId, keccak256("evidence"), 50e6);
        vm.stopPrank();

        uint256 posterBalanceBefore = usdc.balanceOf(poster);

        // Process claim (reject)
        vm.prank(owner);
        dao.processInsuranceClaim(0, false, 0);

        // Verify claim processed but not approved
        DeliveriesDAO.InsuranceClaim memory claim = dao.getClaim(0);
        assertFalse(claim.approved);
        assertTrue(claim.processed);
        assertEq(claim.paidAmount, 0);

        // Verify no payout
        assertEq(usdc.balanceOf(poster), posterBalanceBefore);
    }

    function test_RevertWhen_ClaimAlreadyProcessed() public {
        // Create policy and submit claim
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        dao.submitInsuranceClaim(missionId, keccak256("evidence"), 50e6);
        vm.stopPrank();

        // Process claim once
        vm.startPrank(owner);
        dao.processInsuranceClaim(0, false, 0);
        
        // Try to process again
        vm.expectRevert(DeliveriesDAO.ClaimAlreadyProcessed.selector);
        dao.processInsuranceClaim(0, true, 50e6);
        vm.stopPrank();
    }

    /// @dev Audit M4 replaced the old `test_RevertWhen_InsufficientPoolBalance`. That test
    ///      asserted the pool could underwrite 100 USDC of coverage on a 2 USDC premium and
    ///      only fail at payout time. Policies are now reserved 1:1, so an under-capitalised
    ///      pool is rejected at creation (see test_M4_CreatePolicy_RejectedWhenInsolvent)
    ///      and InsufficientPoolBalance is unreachable through the normal flow. The payout
    ///      ceiling that IS reachable — payout > coverage — is asserted here instead.
    function test_RevertWhen_PayoutExceedsCoverage() public {
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;

        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        dao.submitInsuranceClaim(missionId, keccak256("evidence"), 100e6);
        vm.stopPrank();

        // The owner cannot pay out more than the policy covers, even though the
        // (now capitalised) pool physically holds enough USDC.
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.ExceedsCoverage.selector);
        dao.processInsuranceClaim(0, true, coverageAmount + 1);
    }

    // =============================================================================
    // ADMIN FUNCTION TESTS
    // =============================================================================

    function test_WithdrawFunds() public {
        // First add some funds to pool
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        vm.stopPrank();

        address recipient = address(5);
        uint256 withdrawAmount = 1e6;

        // Withdraw funds
        vm.prank(owner);
        dao.withdrawFunds(withdrawAmount, recipient);

        // Verify withdrawal
        assertEq(usdc.balanceOf(recipient), withdrawAmount);
        (uint256 poolBalance, , ) = dao.getPoolStats();
        assertEq(poolBalance, POOL_SEED + 2e6 - withdrawAmount);
    }

    function test_RevertWhen_WithdrawExceedsBalance() public {
        vm.prank(owner);
        vm.expectRevert("Insufficient balance");
        dao.withdrawFunds(POOL_SEED + 1, address(5)); // More than the pool holds
    }

    function test_GetPoolStats() public {
        // Create multiple policies
        vm.startPrank(poster);
        usdc.approve(address(dao), 10e6);
        dao.createInsurancePolicy(1, 100e6, false); // 2 USDC premium
        dao.createInsurancePolicy(2, 100e6, true);  // 1 USDC premium
        vm.stopPrank();

        (uint256 poolBalance, uint256 totalClaims, uint256 totalPremiums) = dao.getPoolStats();
        assertEq(poolBalance, POOL_SEED + 3e6);
        assertEq(totalClaims, 0);
        assertEq(totalPremiums, 3e6);
    }

    // =============================================================================
    // AUDIT M4: INSURANCE POOL SOLVENCY
    // =============================================================================

    /// @notice The owner must not be able to move capital that backs live policies.
    function test_M4_WithdrawFunds_CannotDrainReservedCoverage() public {
        uint256 coverage = 900e6;
        uint256 premium = (coverage * 200) / 10_000; // 2% public rate = 18 USDC

        vm.startPrank(poster);
        usdc.approve(address(dao), premium);
        dao.createInsurancePolicy(1, coverage, false);
        vm.stopPrank();

        uint256 poolBalance = dao.insurancePoolBalance();
        assertEq(poolBalance, POOL_SEED + premium);
        assertEq(dao.reservedCoverage(), coverage);
        assertEq(dao.availableSurplus(), poolBalance - coverage);

        // FAILED BEFORE FIX: the owner could withdraw the entire pool, including the
        // capital backing the live policy.
        vm.prank(owner);
        vm.expectRevert("Insufficient balance");
        dao.withdrawFunds(poolBalance, address(5));

        // One wei above the surplus is still refused...
        uint256 surplus = dao.availableSurplus(); // resolve before arming expectRevert
        vm.prank(owner);
        vm.expectRevert("Insufficient balance");
        dao.withdrawFunds(surplus + 1, address(5));

        // ...but the genuine surplus is withdrawable, leaving coverage fully backed.
        vm.prank(owner);
        dao.withdrawFunds(surplus, address(5));

        assertEq(usdc.balanceOf(address(5)), surplus);
        assertEq(dao.insurancePoolBalance(), coverage);
        assertEq(dao.availableSurplus(), 0);
        // The pool can still pay the policy in full.
        assertGe(usdc.balanceOf(address(dao)), coverage);
    }

    /// @notice A pool holding only premiums cannot underwrite 100% coverage.
    function test_M4_CreatePolicy_RejectedWhenInsolvent() public {
        DeliveriesDAO fresh = _uncapitalisedDao();

        vm.startPrank(poster);
        usdc.approve(address(fresh), 2e6);
        // FAILED BEFORE FIX: this succeeded, creating 100 USDC of coverage backed by a
        // 2 USDC premium.
        vm.expectRevert(
            abi.encodeWithSelector(DeliveriesDAO.InsufficientSolvency.selector, 2e6, 100e6)
        );
        fresh.createInsurancePolicy(1, 100e6, false);
        vm.stopPrank();
    }

    /// @notice Policies are rejected once cumulative coverage would exceed the pool.
    function test_M4_CreatePolicy_RejectedWhenCumulativeCoverageExceedsPool() public {
        // First policy: 900 USDC coverage against a 1000 USDC pool — fine.
        vm.startPrank(poster);
        usdc.approve(address(dao), type(uint256).max);
        dao.createInsurancePolicy(1, 900e6, false);

        // Second policy would push reserved coverage past the pool balance.
        vm.expectRevert();
        dao.createInsurancePolicy(2, 900e6, false);
        vm.stopPrank();

        assertEq(dao.reservedCoverage(), 900e6);
    }

    function test_M4_FundPool_RestoresSolvencyHeadroom() public {
        DeliveriesDAO fresh = _uncapitalisedDao();
        assertEq(fresh.availableSurplus(), 0);

        usdc.mint(owner, 500e6);
        vm.startPrank(owner);
        usdc.approve(address(fresh), 500e6);
        fresh.fundPool(500e6);
        vm.stopPrank();

        assertEq(fresh.insurancePoolBalance(), 500e6);
        assertEq(fresh.availableSurplus(), 500e6);

        vm.startPrank(poster);
        usdc.approve(address(fresh), 2e6);
        fresh.createInsurancePolicy(1, 100e6, false);
        vm.stopPrank();

        assertEq(fresh.reservedCoverage(), 100e6);
        assertEq(fresh.availableSurplus(), 500e6 + 2e6 - 100e6);
    }

    /// @notice Settling a claim frees the reserve so the capital is reusable.
    function test_M4_ProcessClaim_ReleasesReserve() public {
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(1, 100e6, false);
        dao.submitInsuranceClaim(1, keccak256("evidence"), 40e6);
        vm.stopPrank();

        assertEq(dao.reservedCoverage(), 100e6);

        vm.prank(owner);
        dao.processInsuranceClaim(0, true, 40e6);

        assertEq(dao.reservedCoverage(), 0);
        assertFalse(dao.getPolicy(1).active);
        assertEq(dao.availableSurplus(), dao.insurancePoolBalance());
    }

    /// @notice A rejected claim also closes the policy and frees its reserve.
    function test_M4_RejectedClaim_ReleasesReserve() public {
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(1, 100e6, false);
        dao.submitInsuranceClaim(1, keccak256("evidence"), 40e6);
        vm.stopPrank();

        vm.prank(owner);
        dao.processInsuranceClaim(0, false, 0);

        assertEq(dao.reservedCoverage(), 0);
        assertFalse(dao.getPolicy(1).active);
    }

    /// @notice Completed deliveries can be closed out to recycle their reserve.
    function test_M4_ClosePolicy_ReleasesReserve() public {
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(1, 100e6, false);
        vm.stopPrank();

        assertEq(dao.reservedCoverage(), 100e6);

        // PR #963 review: only a terminal order can be closed out.
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
        dao.closePolicy(1);
        registry.setState(1, IMissionEscrow.MissionState.Completed);
        // Issue #969: record terminal, then wait out the holder's claim window.
        dao.recordPolicyTerminal(1);
        vm.warp(block.timestamp + dao.CLAIM_WINDOW());

        vm.prank(owner);
        dao.closePolicy(1);

        assertEq(dao.reservedCoverage(), 0);
        assertFalse(dao.getPolicy(1).active);

        // Closing twice is refused.
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.PolicyNotActive.selector);
        dao.closePolicy(1);
    }

    function test_M4_ClosePolicy_NonOwner_Reverts() public {
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(1, 100e6, false);
        vm.stopPrank();

        vm.prank(poster);
        vm.expectRevert();
        dao.closePolicy(1);
    }

    /// @notice A pending claim blocks the shortcut close so reserves stay put.
    function test_M4_ClosePolicy_WithPendingClaim_Reverts() public {
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(1, 100e6, false);
        dao.submitInsuranceClaim(1, keccak256("evidence"), 40e6);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert("Claim pending");
        dao.closePolicy(1);

        assertEq(dao.reservedCoverage(), 100e6);
    }

    /// @notice Mission id 0 must not be a re-creatable policy slot.
    /// @dev The delivery factory numbers missions from 1, so mission 0 is now not insurable
    ///      at all (L1); a registered mission still cannot be insured twice.
    function test_M4_PolicyZero_CannotBeOverwritten() public {
        vm.startPrank(poster);
        usdc.approve(address(dao), 4e6);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.UnknownMission.selector, 0));
        dao.createInsurancePolicy(0, 100e6, false);

        dao.createInsurancePolicy(1, 100e6, false);
        vm.expectRevert("Policy already exists");
        dao.createInsurancePolicy(1, 100e6, false);
        vm.stopPrank();

        assertEq(dao.reservedCoverage(), 100e6);
    }

    // =============================================================================
    // AUDIT M4 RESIDUAL — policy/claim-path drain (issue #820)
    // =============================================================================

    address internal attacker = address(0xBAD);

    function _fundAttacker(uint256 amount) internal {
        usdc.mint(attacker, amount);
        vm.prank(attacker);
        usdc.approve(address(dao), type(uint256).max);
    }

    /// @notice The drain as it stood after #828: an outsider insures orders that do not
    ///         exist for the whole surplus at a 2% premium. Now refused.
    function test_M4Drain_FakeMission_Reverts() public {
        _fundAttacker(100e6);
        // FAILED BEFORE FIX: mission 7777 does not exist, yet a 1,000 USDC policy was sold
        // for 20 USDC and could be claimed against the pool.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.UnknownMission.selector, 7777));
        dao.createInsurancePolicy(7777, 1000e6, false);
        assertEq(dao.reservedCoverage(), 0);
    }

    /// @notice Someone else's real order cannot be insured by a third party (also L1 grief).
    function test_M4Drain_NotPoster_Reverts() public {
        _fundAttacker(100e6);
        vm.prank(attacker);
        vm.expectRevert(DeliveriesDAO.NotMissionPoster.selector);
        dao.createInsurancePolicy(1, 100e6, false);
    }

    /// @notice Coverage is bounded by what the poster actually escrowed.
    function test_M4Drain_CoverageAboveEscrowedReward_Reverts() public {
        registry.setMission(5, attacker, 10e6); // a 10 USDC order
        _fundAttacker(100e6);
        // FAILED BEFORE FIX: a 10 USDC order could carry 900 USDC of coverage.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.InvalidCoverage.selector, 900e6, 10e6));
        dao.createInsurancePolicy(5, 900e6, false);

        vm.prank(attacker);
        dao.createInsurancePolicy(5, 10e6, false); // exactly the escrowed reward is fine
        assertEq(dao.reservedCoverage(), 10e6);
    }

    function test_M4Drain_CoverageAbovePerPolicyCap_Reverts() public {
        registry.setMission(6, attacker, 50_000e6);
        _fundAttacker(10_000e6);
        uint256 cap = dao.maxCoveragePerPolicy();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.InvalidCoverage.selector, cap + 1, cap));
        dao.createInsurancePolicy(6, cap + 1, false);
    }

    function test_M4Drain_ZeroCoverage_Reverts() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.InvalidCoverage.selector, 0, 1000e6));
        dao.createInsurancePolicy(1, 0, false);
    }

    /// @notice Completed / cancelled / disputed orders can no longer be insured after the fact.
    function test_M4Drain_SettledMission_NotInsurable() public {
        IMissionEscrow.MissionState[3] memory dead = [
            IMissionEscrow.MissionState.Completed,
            IMissionEscrow.MissionState.Cancelled,
            IMissionEscrow.MissionState.Disputed
        ];
        vm.startPrank(poster);
        usdc.approve(address(dao), type(uint256).max);
        vm.stopPrank();
        for (uint256 i = 0; i < dead.length; i++) {
            registry.setState(1, dead[i]);
            vm.prank(poster);
            vm.expectRevert(DeliveriesDAO.MissionNotInsurable.selector);
            dao.createInsurancePolicy(1, 100e6, false);
        }
        registry.setState(1, IMissionEscrow.MissionState.Accepted);
        vm.prank(poster);
        dao.createInsurancePolicy(1, 100e6, false);
    }

    function test_M4Drain_NoFactory_NoPolicies() public {
        vm.prank(owner);
        DeliveriesDAO bare = new DeliveriesDAO(address(usdc));
        vm.prank(poster);
        vm.expectRevert(DeliveriesDAO.DeliveryFactoryNotSet.selector);
        bare.createInsurancePolicy(1, 100e6, false);
    }

    /// @notice Even with owner-approved claims, aggregate payouts are capped per period.
    function test_M4Drain_PeriodPayoutCap() public {
        // Tighten caps: 400/policy, 1,000/period. Pool: 1,000 seed + 10,000 extra.
        vm.prank(owner);
        dao.setPayoutLimits(400e6, 1000e6);
        usdc.mint(owner, 10_000e6);
        vm.startPrank(owner);
        usdc.approve(address(dao), 10_000e6);
        dao.fundPool(10_000e6);
        vm.stopPrank();

        vm.startPrank(poster);
        usdc.approve(address(dao), type(uint256).max);
        for (uint256 id = 1; id <= 3; id++) {
            dao.createInsurancePolicy(id, 400e6, false);
            dao.submitInsuranceClaim(id, keccak256("evidence"), 400e6);
        }
        vm.stopPrank();

        vm.startPrank(owner);
        dao.processInsuranceClaim(0, true, 400e6);
        dao.processInsuranceClaim(1, true, 400e6);
        assertEq(dao.remainingPeriodPayout(), 200e6);
        // FAILED BEFORE FIX: nothing bounded the aggregate outflow of approved claims.
        vm.expectRevert(
            abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 400e6, 200e6)
        );
        dao.processInsuranceClaim(2, true, 400e6);
        vm.stopPrank();

        // Next period the claim is payable.
        vm.warp(block.timestamp + dao.PAYOUT_PERIOD());
        vm.prank(owner);
        dao.processInsuranceClaim(2, true, 400e6);
        assertEq(dao.totalClaimsPaid(), 1200e6);
    }

    /// @notice A compromised owner cannot lift the caps instantly; loosening waits CONFIG_DELAY.
    function test_M4Drain_LooseningLimits_IsDelayed() public {
        uint256 perPolicy = dao.maxCoveragePerPolicy();
        uint256 perPeriod = dao.maxPayoutPerPeriod();

        vm.prank(owner);
        dao.setPayoutLimits(1_000_000e6, 1_000_000e6);
        assertEq(dao.maxCoveragePerPolicy(), perPolicy, "not applied yet");
        assertEq(dao.maxPayoutPerPeriod(), perPeriod, "not applied yet");

        uint256 eta = dao.pendingLimitsEta();
        assertEq(eta, block.timestamp + dao.CONFIG_DELAY());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.TooEarly.selector, eta));
        dao.applyPayoutLimits();

        vm.warp(eta);
        vm.prank(owner);
        dao.applyPayoutLimits();
        assertEq(dao.maxPayoutPerPeriod(), 1_000_000e6);
    }

    function test_M4Drain_TighteningLimits_IsImmediate_AndCancelsQueue() public {
        vm.startPrank(owner);
        dao.setPayoutLimits(1_000_000e6, 1_000_000e6); // queued
        dao.setPayoutLimits(100e6, 500e6); // tighten → immediate
        vm.stopPrank();
        assertEq(dao.maxCoveragePerPolicy(), 100e6);
        assertEq(dao.maxPayoutPerPeriod(), 500e6);
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.applyPayoutLimits();
    }

    function test_M4Drain_InvalidLimits_Revert() public {
        vm.startPrank(owner);
        vm.expectRevert(DeliveriesDAO.InvalidLimits.selector);
        dao.setPayoutLimits(0, 100e6);
        vm.expectRevert(DeliveriesDAO.InvalidLimits.selector);
        dao.setPayoutLimits(200e6, 100e6);
        vm.stopPrank();
    }

    /// @notice Swapping in a hostile factory (that vouches for fake orders) is delayed too.
    function test_M4Drain_FactorySwap_IsDelayed() public {
        MockDeliveryRegistry hostile = new MockDeliveryRegistry();
        hostile.setMission(7777, attacker, 1000e6);

        vm.prank(owner);
        dao.setDeliveryFactory(address(hostile));
        assertEq(dao.deliveryFactory(), address(registry), "swap queued, not applied");

        _fundAttacker(100e6);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.UnknownMission.selector, 7777));
        dao.createInsurancePolicy(7777, 100e6, false);

        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        vm.prank(owner);
        dao.applyDeliveryFactory();
        assertEq(dao.deliveryFactory(), address(hostile));
    }

    function test_M4Drain_ConfigFunctions_OnlyOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        dao.setDeliveryFactory(attacker);
        vm.expectRevert();
        dao.setPayoutLimits(1, 1);
        vm.expectRevert();
        dao.applyPayoutLimits();
        vm.expectRevert();
        dao.applyDeliveryFactory();
        vm.stopPrank();
    }

    /// @notice Happy path end-to-end: real order → policy → claim → payout within caps.
    function test_M4_HappyPath_RealOrderClaimPaid() public {
        uint256 before = usdc.balanceOf(poster);
        vm.startPrank(poster);
        usdc.approve(address(dao), type(uint256).max);
        dao.createInsurancePolicy(42, 250e6, true); // 1% curated premium = 2.5 USDC
        dao.submitInsuranceClaim(42, keccak256("lost parcel"), 250e6);
        vm.stopPrank();

        vm.prank(owner);
        dao.processInsuranceClaim(0, true, 250e6);

        assertEq(usdc.balanceOf(poster), before - 2.5e6 + 250e6);
        assertEq(dao.reservedCoverage(), 0);
        assertEq(dao.payoutPeriodPaid(), 250e6);
    }
}
