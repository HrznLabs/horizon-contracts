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

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy DeliveriesDAO
        dao = new DeliveriesDAO(address(usdc));

        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, INITIAL_BALANCE);
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
        assertEq(poolBalance, 2e6);
        assertEq(totalPremiums, 2e6);
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
        assertEq(poolBalance, 0.5e6); // 2 USDC premium - 1.5 USDC payout
        assertEq(totalClaims, 1.5e6);
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

    function test_RevertWhen_InsufficientPoolBalance() public {
        // Create policy with small premium
        uint256 missionId = 1;
        uint256 coverageAmount = 100e6;
        
        vm.startPrank(poster);
        usdc.approve(address(dao), 2e6);
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        dao.submitInsuranceClaim(missionId, keccak256("evidence"), 100e6);
        vm.stopPrank();

        // Try to approve claim for more than pool has
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.InsufficientPoolBalance.selector);
        dao.processInsuranceClaim(0, true, 100e6); // Pool only has 2 USDC
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
        assertEq(poolBalance, 1e6); // 2 USDC - 1 USDC withdrawn
    }

    function test_RevertWhen_WithdrawExceedsBalance() public {
        vm.prank(owner);
        vm.expectRevert("Insufficient balance");
        dao.withdrawFunds(1e6, address(5)); // Pool is empty
    }

    function test_GetPoolStats() public {
        // Create multiple policies
        vm.startPrank(poster);
        usdc.approve(address(dao), 10e6);
        dao.createInsurancePolicy(1, 100e6, false); // 2 USDC premium
        dao.createInsurancePolicy(2, 100e6, true);  // 1 USDC premium
        vm.stopPrank();

        (uint256 poolBalance, uint256 totalClaims, uint256 totalPremiums) = dao.getPoolStats();
        assertEq(poolBalance, 3e6);
        assertEq(totalClaims, 0);
        assertEq(totalPremiums, 3e6);
    }
}
