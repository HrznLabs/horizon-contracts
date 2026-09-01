// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeliveriesDAO} from "../src/DeliveriesDAO.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeliveriesDAOTest is Test {
    DeliveriesDAO public dao;
    MockERC20 public usdc;

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
    function test_M4_PolicyZero_CannotBeOverwritten() public {
        vm.startPrank(poster);
        usdc.approve(address(dao), 4e6);
        dao.createInsurancePolicy(0, 100e6, false);

        // FAILED BEFORE FIX: the old `missionId == 0` sentinel let mission 0's policy be
        // recreated indefinitely, double-counting premiums and (now) reserves.
        vm.expectRevert("Policy already exists");
        dao.createInsurancePolicy(0, 100e6, false);
        vm.stopPrank();

        assertEq(dao.reservedCoverage(), 100e6);
    }
}
