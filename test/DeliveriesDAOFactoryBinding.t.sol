// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeliveriesDAO} from "../src/DeliveriesDAO.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDeliveryRegistry} from "./mocks/MockDeliveryRegistry.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";

/// @notice Issue #969 (follow-up to #968): regression tests ported from the #968 adversarial
///         review (Adversary968DeliveriesDAO.t.sol A2, A4, A5, A6). Each attack SUCCEEDED
///         before the fix; here the attack must fail.
contract DeliveriesDAOFactoryBindingTest is Test {
    MockERC20 usdc;
    DeliveriesDAO dao;
    MockDeliveryRegistry registry;

    address owner = makeAddr("owner");
    address poster = makeAddr("poster");
    address poster2 = makeAddr("poster2");
    address thief = makeAddr("thief");
    address keeper = makeAddr("keeper");

    uint256 constant POOL_SEED = 10_000e6;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(owner);
        dao = new DeliveriesDAO(address(usdc));
        registry = new MockDeliveryRegistry();
        vm.prank(owner);
        dao.setDeliveryFactory(address(registry));
        _fund(POOL_SEED);
        usdc.mint(poster, 10_000e6);
        usdc.mint(poster2, 10_000e6);
    }

    function _fund(uint256 amt) internal {
        usdc.mint(owner, amt);
        vm.startPrank(owner);
        usdc.approve(address(dao), amt);
        dao.fundPool(amt);
        vm.stopPrank();
    }

    function _insure(MockDeliveryRegistry r, uint256 id, address p, uint256 cov) internal {
        r.setMission(id, p, cov);
        vm.startPrank(p);
        usdc.approve(address(dao), (cov * 200) / 10_000);
        dao.createInsurancePolicy(id, cov, false);
        vm.stopPrank();
    }

    function _migrate(address to) internal {
        vm.startPrank(owner);
        dao.setDeliveryFactory(to);
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        dao.applyDeliveryFactory();
        vm.stopPrank();
    }

    // =========================================================================
    // A4 — factory re-point drain. Before: hostile factory reported every live order
    // Completed, closePolicy released all reserves and executeWithdraw emptied the pool.
    // =========================================================================
    function test_A4_FactoryRepoint_CannotReleaseLiveReserves() public {
        for (uint256 id = 1; id <= 5; id++) _insure(registry, id, poster, 1_000e6);
        vm.prank(poster);
        dao.submitInsuranceClaim(1, bytes32("x"), 1_000e6);
        uint256 pool = usdc.balanceOf(address(dao));

        MockDeliveryRegistry hostile = new MockDeliveryRegistry();
        for (uint256 id = 1; id <= 5; id++) {
            hostile.setMission(id, poster, 1);
            hostile.setState(id, IMissionEscrow.MissionState.Completed);
        }
        vm.startPrank(owner);
        dao.setDeliveryFactory(address(hostile));
        dao.queueWithdraw(pool, thief);
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        dao.applyDeliveryFactory();
        assertEq(dao.deliveryFactory(), address(hostile));
        for (uint256 id = 2; id <= 5; id++) {
            assertEq(dao.getPolicy(id).factory, address(registry), "policy bound to issuer");
            // Terminal state is read from the issuing factory: still Open there.
            vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
            dao.recordPolicyTerminal(id);
            vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
            dao.closePolicy(id);
        }
        // Denying the pending claim is within the documented owner-trust boundary...
        dao.processInsuranceClaim(0, false, 0);
        // ...but the live reserves of orders 2..5 cannot leave.
        vm.expectRevert("Insufficient balance");
        dao.executeWithdraw();
        vm.stopPrank();

        assertEq(dao.reservedCoverage(), 4_000e6);
        assertEq(usdc.balanceOf(thief), 0);
        assertGe(usdc.balanceOf(address(dao)), 4_000e6, "live reserves intact");
        // Holders of live orders can still claim.
        vm.prank(poster);
        dao.submitInsuranceClaim(3, bytes32("lost"), 1_000e6);
    }

    /// @notice Any tightening cancels a queued factory change (and the queued withdrawal).
    function test_A4_TighteningCancelsQueuedFactory() public {
        address hostile = address(new MockDeliveryRegistry());
        vm.startPrank(owner);
        dao.setDeliveryFactory(hostile);
        dao.queueWithdraw(1e6, thief);
        vm.expectEmit(address(dao));
        emit DeliveriesDAO.DeliveryFactoryCancelled();
        dao.setPayoutLimits(dao.maxCoveragePerPolicy(), dao.maxPayoutPerPeriod());
        assertEq(dao.pendingDeliveryFactory(), address(0));
        assertEq(dao.pendingDeliveryFactoryEta(), 0);
        assertEq(dao.pendingWithdrawEta(), 0);
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.applyDeliveryFactory();
        assertEq(dao.deliveryFactory(), address(registry));

        // Same via the withdraw-limit setter.
        dao.setDeliveryFactory(hostile);
        dao.setPayoutLimits(2_000e6, 10_000e6); // queued loosening
        dao.setMaxWithdrawPerPeriod(10_000e6); // queued loosening
        dao.setMaxWithdrawPerPeriod(dao.maxWithdrawPerPeriod()); // tighten (equal)
        assertEq(dao.pendingDeliveryFactoryEta(), 0);
        assertEq(dao.pendingLimitsEta(), 0);
        assertEq(dao.pendingMaxWithdrawEta(), 0);
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.applyDeliveryFactory();
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.applyPayoutLimits();
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.applyMaxWithdrawPerPeriod();
        vm.stopPrank();
    }

    // =========================================================================
    // A5 — legit migration + id collision. Before: a live old policy was closed because
    // the NEW factory had an unrelated terminal mission with the same id.
    // =========================================================================
    function test_A5_IdCollisionAfterMigration_CannotCloseLivePolicy() public {
        _insure(registry, 7, poster, 1_000e6);
        MockDeliveryRegistry v2 = new MockDeliveryRegistry();
        v2.setMission(7, poster2, 50e6);
        v2.setState(7, IMissionEscrow.MissionState.Cancelled);
        _migrate(address(v2));

        vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
        dao.recordPolicyTerminal(7);
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
        dao.closePolicy(7);
        // While the old policy is live, the colliding id cannot be insured on v2.
        vm.startPrank(poster2);
        usdc.approve(address(dao), 1e6);
        vm.expectRevert("Policy already exists");
        dao.createInsurancePolicy(7, 50e6, false);
        vm.stopPrank();
        // The old holder is still covered.
        vm.prank(poster);
        dao.submitInsuranceClaim(7, bytes32("lost"), 1_000e6);
        assertEq(dao.reservedCoverage(), 1_000e6);
    }

    /// @notice Once the old factory's policy is settled, the id can be re-insured on the new one.
    function test_A5_IdCollisionAfterMigration_ReinsurableOnceOldPolicySettled() public {
        _insure(registry, 7, poster, 1_000e6);
        MockDeliveryRegistry v2 = new MockDeliveryRegistry();
        _migrate(address(v2));

        registry.setState(7, IMissionEscrow.MissionState.Completed);
        dao.recordPolicyTerminal(7);
        vm.warp(block.timestamp + dao.CLAIM_WINDOW());
        vm.prank(owner);
        dao.closePolicy(7);

        _insure(v2, 7, poster2, 50e6);
        DeliveriesDAO.InsurancePolicy memory p = dao.getPolicy(7);
        assertEq(p.factory, address(v2));
        assertEq(p.poster, poster2);
        assertTrue(p.active);
        assertEq(p.terminalAt, 0);
        assertEq(dao.reservedCoverage(), 50e6);
        // A settled policy of the CURRENT factory can still never be re-created.
        v2.setState(7, IMissionEscrow.MissionState.Cancelled);
        dao.recordPolicyTerminal(7);
        vm.warp(block.timestamp + dao.CLAIM_WINDOW());
        vm.prank(owner);
        dao.closePolicy(7);
        v2.setState(7, IMissionEscrow.MissionState.Open);
        vm.prank(poster2);
        vm.expectRevert("Policy already exists");
        dao.createInsurancePolicy(7, 50e6, false);
    }

    // =========================================================================
    // A6 — no claim grace window. Before: the owner closed a Completed order's policy
    // in the same block, uncharged, before the holder could file.
    // =========================================================================
    function test_A6_OwnerCannotCloseBeforeClaimWindow_HolderCanStillClaim() public {
        _insure(registry, 9, poster, 1_000e6);
        registry.setState(9, IMissionEscrow.MissionState.Completed);

        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector); // window never started
        dao.closePolicy(9);

        uint256 closableAt = block.timestamp + dao.CLAIM_WINDOW();
        vm.expectEmit(address(dao));
        emit DeliveriesDAO.PolicyTerminalRecorded(9, closableAt);
        vm.prank(owner);
        dao.recordPolicyTerminal(9);
        assertEq(dao.getPolicy(9).terminalAt, block.timestamp);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.ClaimWindowOpen.selector, closableAt));
        dao.closePolicy(9);
        // Re-recording does not restart (or shorten) the window.
        vm.warp(closableAt - 1);
        dao.recordPolicyTerminal(9);
        assertEq(dao.getPolicy(9).terminalAt, closableAt - dao.CLAIM_WINDOW());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.ClaimWindowOpen.selector, closableAt));
        dao.closePolicy(9);

        // The holder files inside the window: the policy can no longer be closed.
        vm.prank(poster);
        dao.submitInsuranceClaim(9, bytes32("damaged"), 1_000e6);
        vm.warp(closableAt);
        vm.prank(owner);
        vm.expectRevert("Claim pending");
        dao.closePolicy(9);
        // A denial is on-chain and charged to the withdraw budget.
        vm.prank(owner);
        dao.processInsuranceClaim(0, false, 0);
        assertTrue(dao.getClaim(0).processed);
        assertEq(dao.releasedThisPeriod(), 1_000e6);
    }

    function test_A6_CloseAfterWindow_ChargedToReleasedThisPeriod() public {
        _insure(registry, 9, poster, 1_000e6);
        registry.setState(9, IMissionEscrow.MissionState.Cancelled);
        vm.prank(keeper); // permissionless
        dao.recordPolicyTerminal(9);
        vm.warp(block.timestamp + dao.CLAIM_WINDOW());

        vm.prank(keeper);
        vm.expectRevert(); // closing stays owner-only
        dao.closePolicy(9);

        vm.prank(owner);
        dao.closePolicy(9);
        assertEq(dao.reservedCoverage(), 0);
        assertEq(dao.releasedThisPeriod(), 1_000e6, "close release charged");
        assertEq(dao.remainingPeriodWithdraw(), dao.maxWithdrawPerPeriod() - 1_000e6);
        assertEq(dao.remainingPeriodPayout(), dao.maxPayoutPerPeriod(), "claims budget untouched");

        uint256 cap = dao.remainingPeriodWithdraw();
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, cap + 1, cap)
        );
        dao.withdrawFunds(cap + 1, thief);
        dao.withdrawFunds(cap, thief);
        vm.stopPrank();
    }

    function test_RecordPolicyTerminal_InactiveOrLive_Reverts() public {
        vm.expectRevert(DeliveriesDAO.PolicyNotActive.selector);
        dao.recordPolicyTerminal(42);
        _insure(registry, 1, poster, 100e6);
        IMissionEscrow.MissionState[4] memory live = [
            IMissionEscrow.MissionState.Open,
            IMissionEscrow.MissionState.Accepted,
            IMissionEscrow.MissionState.Submitted,
            IMissionEscrow.MissionState.Disputed
        ];
        for (uint256 i = 0; i < live.length; i++) {
            registry.setState(1, live[i]);
            vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
            dao.recordPolicyTerminal(1);
        }
    }

    // =========================================================================
    // A2 — boundary double-dip + withdrawals starving claims. Before: one shared
    // budget, so withdrawals blocked an approved claim, and 2x the cap moved in 1s.
    // =========================================================================
    function test_A2_WithdrawalsNeverStarveClaims_BoundaryBoundedPerCounter() public {
        _fund(20_000e6); // ample surplus so only the budgets bind
        _insure(registry, 1, poster, 1_000e6);
        vm.prank(poster);
        dao.submitInsuranceClaim(1, bytes32("lost"), 1_000e6);

        uint256 wCap = dao.maxWithdrawPerPeriod();
        uint256 pCap = dao.maxPayoutPerPeriod();
        vm.startPrank(owner);
        dao.withdrawFunds(1e6, thief); // anchors the window at t0
        uint256 t0 = dao.payoutPeriodStart();
        vm.warp(t0 + dao.PAYOUT_PERIOD() - 1);
        dao.withdrawFunds(wCap - 1e6, thief);
        assertEq(dao.remainingPeriodWithdraw(), 0);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 1, 0));
        dao.withdrawFunds(1, thief);

        // The honest approved claim is NOT blocked by the withdrawals.
        assertEq(dao.remainingPeriodPayout(), pCap);
        dao.processInsuranceClaim(0, true, 1_000e6);
        assertEq(usdc.balanceOf(poster), 10_000e6 - 20e6 + 1_000e6);
        assertEq(dao.payoutPeriodPaid(), 1_000e6);
        assertEq(dao.withdrawnThisPeriod(), wCap);

        // Across the boundary the withdraw counter allows at most one more cap.
        vm.warp(t0 + dao.PAYOUT_PERIOD());
        vm.expectRevert(
            abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, wCap + 1, wCap)
        );
        dao.withdrawFunds(wCap + 1, thief);
        dao.withdrawFunds(wCap, thief);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 1, 0));
        dao.withdrawFunds(1, thief);
        vm.stopPrank();

        // Documented bound: <= 2x maxWithdrawPerPeriod of withdrawals in any 1-period interval.
        assertEq(usdc.balanceOf(thief), 2 * wCap);
        assertLe(usdc.balanceOf(thief), 2 * dao.maxWithdrawPerPeriod());
    }

    /// @notice Claim payouts are bounded by their own counter, unaffected by withdrawals.
    function test_A2_ClaimBudgetIndependent() public {
        _fund(20_000e6);
        vm.prank(owner);
        dao.setPayoutLimits(1_000e6, 2_000e6);
        for (uint256 id = 1; id <= 3; id++) {
            _insure(registry, id, poster, 1_000e6);
            vm.prank(poster);
            dao.submitInsuranceClaim(id, bytes32("x"), 1_000e6);
        }
        vm.startPrank(owner);
        dao.withdrawFunds(dao.maxWithdrawPerPeriod(), thief); // full withdraw budget
        dao.processInsuranceClaim(0, true, 1_000e6);
        dao.processInsuranceClaim(1, true, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 1_000e6, 0));
        dao.processInsuranceClaim(2, true, 1_000e6);
        vm.warp(block.timestamp + dao.PAYOUT_PERIOD());
        dao.processInsuranceClaim(2, true, 1_000e6);
        vm.stopPrank();
        assertEq(dao.totalClaimsPaid(), 3_000e6);
    }

    // =========================================================================
    // maxWithdrawPerPeriod config: same delay rules as the payout limits.
    // =========================================================================
    function test_WithdrawLimit_LooseningDelayed_TighteningImmediate() public {
        vm.startPrank(owner);
        dao.setMaxWithdrawPerPeriod(1_000e6);
        assertEq(dao.maxWithdrawPerPeriod(), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 1_000e6 + 1, 1_000e6));
        dao.withdrawFunds(1_000e6 + 1, thief);

        dao.setMaxWithdrawPerPeriod(8_000e6);
        assertEq(dao.maxWithdrawPerPeriod(), 1_000e6, "loosening not immediate");
        uint256 eta = dao.pendingMaxWithdrawEta();
        assertEq(eta, block.timestamp + dao.CONFIG_DELAY());
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.TooEarly.selector, eta));
        dao.applyMaxWithdrawPerPeriod();
        vm.warp(eta);
        dao.applyMaxWithdrawPerPeriod();
        assertEq(dao.maxWithdrawPerPeriod(), 8_000e6);
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.applyMaxWithdrawPerPeriod();

        dao.setMaxWithdrawPerPeriod(0); // immediate withdrawals disabled
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 1, 0));
        dao.withdrawFunds(1, thief);
        vm.stopPrank();

        vm.startPrank(thief);
        vm.expectRevert();
        dao.setMaxWithdrawPerPeriod(0);
        vm.expectRevert();
        dao.applyMaxWithdrawPerPeriod();
        vm.stopPrank();
    }
}
