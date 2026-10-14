// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeliveriesDAO} from "../src/DeliveriesDAO.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDeliveryRegistry} from "./mocks/MockDeliveryRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";

/// @notice PR #963 review follow-up: regression tests for the owner-outflow paths of the
///         DeliveriesDAO insurance pool (ported from the adversarial review's attack tests).
///         The two drain tests FAILED before the fix (the pool was emptied in one tx).
contract DeliveriesDAOOwnerOutflowsTest is Test {
    MockERC20 usdc;
    DeliveriesDAO dao;
    MockDeliveryRegistry registry;

    address owner = makeAddr("owner");
    address poster = makeAddr("poster");
    address poster2 = makeAddr("poster2");
    address thief = makeAddr("thief");
    address performer = makeAddr("performer");

    uint256 constant POOL_SEED = 10_000e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(owner);
        dao = new DeliveriesDAO(address(usdc));
        registry = new MockDeliveryRegistry();
        vm.prank(owner);
        dao.setDeliveryFactory(address(registry));
        _fund(dao, POOL_SEED);
        usdc.mint(poster, 10_000e6);
        usdc.mint(poster2, 10_000e6);
    }

    function _fund(DeliveriesDAO d, uint256 amt) internal {
        usdc.mint(owner, amt);
        vm.startPrank(owner);
        usdc.approve(address(d), amt);
        d.fundPool(amt);
        vm.stopPrank();
    }

    function _insure(uint256 id, address p, uint256 coverage) internal {
        registry.setMission(id, p, coverage);
        vm.startPrank(p);
        usdc.approve(address(dao), (coverage * 200) / 10_000);
        dao.createInsurancePolicy(id, coverage, false);
        vm.stopPrank();
    }

    // =========================================================================
    // Compromised owner key: close live policies + withdraw everything in one tx.
    // FAILED BEFORE FIX: the whole pool (incl. the 5,000 backing live orders) left in one tx.
    // =========================================================================
    function test_OwnerDrain_OneTxReverts_QueuedPathOnlyAfterDelay() public {
        // Honest posters hold 5 live policies of 1,000 USDC each -> 5,000 reserved.
        for (uint256 id = 1; id <= 5; id++) {
            _insure(id, id % 2 == 0 ? poster : poster2, 1_000e6);
        }
        assertEq(dao.reservedCoverage(), 5_000e6);
        uint256 poolBefore = usdc.balanceOf(address(dao));
        assertEq(poolBefore, POOL_SEED + 5 * 20e6);
        uint256 surplus = dao.availableSurplus();
        assertEq(surplus, poolBefore - 5_000e6);

        vm.startPrank(owner);
        // The reserve still stops a naive full withdraw.
        vm.expectRevert("Insufficient balance");
        dao.withdrawFunds(poolBefore, thief);
        // closePolicy can no longer strip cover from live orders.
        for (uint256 id = 1; id <= 5; id++) {
            vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
            dao.closePolicy(id);
        }
        assertEq(dao.reservedCoverage(), 5_000e6);
        // Even the surplus cannot leave immediately above the per-period budget.
        vm.expectRevert(
            abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, surplus, 5_000e6)
        );
        dao.withdrawFunds(surplus, thief);

        // The delayed path: queued, visible, and not executable for CONFIG_DELAY.
        dao.queueWithdraw(surplus, thief);
        assertEq(dao.pendingWithdrawAmount(), surplus);
        assertEq(dao.pendingWithdrawRecipient(), thief);
        uint256 eta = block.timestamp + dao.CONFIG_DELAY();
        assertEq(dao.pendingWithdrawEta(), eta);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.TooEarly.selector, eta));
        dao.executeWithdraw();
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.TooEarly.selector, eta));
        dao.executeWithdraw();
        vm.warp(eta);
        dao.executeWithdraw();
        vm.stopPrank();

        assertEq(usdc.balanceOf(thief), surplus);
        assertEq(dao.pendingWithdrawEta(), 0);
        // Live cover stays fully backed: every honest holder can still be paid.
        assertEq(usdc.balanceOf(address(dao)), 5_000e6);
        assertEq(dao.reservedCoverage(), 5_000e6);
        vm.prank(poster);
        dao.submitInsuranceClaim(2, bytes32("lost"), 1_000e6);
        vm.prank(owner);
        dao.processInsuranceClaim(0, true, 1_000e6);
        assertEq(dao.reservedCoverage(), 4_000e6);
    }

    /// @notice Small surplus withdrawals stay immediate, within the per-period budget.
    function test_ImmediateWithdraw_WithinPeriodBudget() public {
        vm.startPrank(owner);
        dao.withdrawFunds(3_000e6, thief);
        dao.withdrawFunds(2_000e6, thief);
        assertEq(dao.withdrawnThisPeriod(), 5_000e6);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 1, 0));
        dao.withdrawFunds(1, thief);
        // Issue #969: withdrawals have their own budget; the claim-payout budget is untouched.
        assertEq(dao.remainingPeriodWithdraw(), 0);
        assertEq(dao.payoutPeriodPaid(), 0);
        assertEq(dao.remainingPeriodPayout(), dao.maxPayoutPerPeriod());
        vm.warp(block.timestamp + dao.PAYOUT_PERIOD());
        dao.withdrawFunds(5_000e6, thief);
        vm.stopPrank();
        assertEq(usdc.balanceOf(thief), POOL_SEED);
    }

    // =========================================================================
    // Deny-then-withdraw bypass of the per-period cap.
    // FAILED BEFORE FIX: the denied claim's reserve was withdrawn in the same tx.
    // =========================================================================
    function test_DenyThenWithdraw_BoundedByPeriodCap() public {
        for (uint256 id = 1; id <= 6; id++) {
            _insure(id, poster, 1_000e6);
            vm.prank(poster);
            dao.submitInsuranceClaim(id, bytes32("x"), 1_000e6);
        }
        vm.startPrank(owner);
        for (uint256 c = 0; c < 5; c++) dao.processInsuranceClaim(c, true, 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 1_000e6, 0)
        );
        dao.processInsuranceClaim(5, true, 1_000e6);
        // Deny releases the reserve but charges it to releasedThisPeriod...
        dao.processInsuranceClaim(5, false, 0);
        assertEq(dao.reservedCoverage(), 0);
        assertEq(dao.releasedThisPeriod(), 1_000e6);
        uint256 left = usdc.balanceOf(address(dao));
        // ...so deny + withdraw together stay within ONE withdraw budget this period (issue
        // #969: the withdraw budget is separate from the claim payouts already made).
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, left, 4_000e6));
        dao.withdrawFunds(left, thief);
        dao.withdrawFunds(4_000e6, thief);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 1, 0));
        dao.withdrawFunds(1, thief);
        // Next period the budget is available again (only 1,120 of surplus is left).
        vm.warp(block.timestamp + dao.PAYOUT_PERIOD());
        dao.withdrawFunds(1_000e6, thief);
        assertEq(dao.releasedThisPeriod(), 0);
        vm.stopPrank();
        assertEq(usdc.balanceOf(thief), 5_000e6);
        assertGt(usdc.balanceOf(address(dao)), 0);
    }

    /// @notice A denial with budget left only shrinks the immediate headroom by its coverage.
    function test_DenyReducesImmediateWithdrawHeadroom() public {
        _insure(1, poster, 1_000e6);
        vm.prank(poster);
        dao.submitInsuranceClaim(1, bytes32("x"), 1_000e6);
        vm.startPrank(owner);
        dao.processInsuranceClaim(0, false, 0);
        vm.expectRevert(
            abi.encodeWithSelector(DeliveriesDAO.PeriodPayoutCapExceeded.selector, 4_000e6 + 1, 4_000e6)
        );
        dao.withdrawFunds(4_000e6 + 1, thief);
        dao.withdrawFunds(4_000e6, thief);
        vm.stopPrank();
        // Neither denials nor withdrawals consume the claim-payout budget (issue #969).
        assertEq(dao.remainingPeriodPayout(), dao.maxPayoutPerPeriod());
        assertEq(dao.remainingPeriodWithdraw(), 0);
    }

    /// @notice Approving a token payout releases the unpaid rest into the same counter.
    function test_TokenApproval_UnpaidRemainderCounted() public {
        _insure(1, poster, 1_000e6);
        vm.prank(poster);
        dao.submitInsuranceClaim(1, bytes32("x"), 1_000e6);
        vm.prank(owner);
        dao.processInsuranceClaim(0, true, 1);
        assertEq(dao.payoutPeriodPaid(), 1);
        assertEq(dao.releasedThisPeriod(), 1_000e6 - 1);
    }

    // =========================================================================
    // closePolicy only for terminal orders.
    // =========================================================================
    function test_ClosePolicy_OnlyTerminalOrders() public {
        _insure(1, poster, 1_000e6);
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
            vm.prank(owner);
            vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
            dao.closePolicy(1);
        }
        registry.setState(1, IMissionEscrow.MissionState.Cancelled);
        dao.recordPolicyTerminal(1);
        vm.warp(block.timestamp + dao.CLAIM_WINDOW()); // issue #969 grace window
        vm.prank(owner);
        dao.closePolicy(1);
        assertEq(dao.reservedCoverage(), 0);

        _insure(2, poster, 500e6);
        registry.setState(2, IMissionEscrow.MissionState.Completed);
        dao.recordPolicyTerminal(2);
        vm.warp(block.timestamp + dao.CLAIM_WINDOW());
        vm.prank(owner);
        dao.closePolicy(2);
        assertEq(dao.reservedCoverage(), 0);
    }

    // =========================================================================
    // Withdrawal queue mechanics.
    // =========================================================================
    function test_QueuedWithdraw_CancelReplaceTighten() public {
        vm.startPrank(owner);
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.executeWithdraw();
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.cancelWithdraw();
        vm.expectRevert(DeliveriesDAO.ZeroAddress.selector);
        dao.queueWithdraw(1, address(0));
        vm.expectRevert("Zero amount");
        dao.queueWithdraw(0, thief);

        // Explicit cancel.
        dao.queueWithdraw(POOL_SEED, thief);
        vm.expectEmit(address(dao));
        emit DeliveriesDAO.WithdrawCancelled();
        dao.cancelWithdraw();
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.executeWithdraw();

        // A new queue replaces the old one and restarts the delay.
        dao.queueWithdraw(POOL_SEED, thief);
        vm.warp(block.timestamp + 1 days);
        dao.queueWithdraw(1e6, owner);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(DeliveriesDAO.TooEarly.selector, block.timestamp + 1 days)
        );
        dao.executeWithdraw();

        // Any tightening of the limits cancels it.
        dao.setPayoutLimits(dao.maxCoveragePerPolicy(), dao.maxPayoutPerPeriod());
        assertEq(dao.pendingWithdrawEta(), 0);
        assertEq(dao.pendingWithdrawAmount(), 0);
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.executeWithdraw();
        vm.stopPrank();

        // Owner-only.
        vm.startPrank(thief);
        vm.expectRevert();
        dao.queueWithdraw(1, thief);
        vm.expectRevert();
        dao.executeWithdraw();
        vm.expectRevert();
        dao.cancelWithdraw();
        vm.stopPrank();
    }

    /// @notice The surplus is re-checked at execution: policies sold meanwhile stay backed.
    function test_QueuedWithdraw_RechecksSurplusAtExecution() public {
        vm.prank(owner);
        dao.queueWithdraw(POOL_SEED, thief);
        _insure(1, poster, 1_000e6);
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        vm.prank(owner);
        vm.expectRevert("Insufficient balance");
        dao.executeWithdraw();
        assertEq(usdc.balanceOf(thief), 0);
    }

    // =========================================================================
    // Real DeliveryMissionFactory (not the mock): registry ABI and binding hold end to end.
    // Verifies the registry ABI actually matches and the binding holds end to end.
    // =========================================================================
    function _realFactory() internal returns (DeliveryMissionFactory f) {
        address admin = makeAddr("admin");
        vm.startPrank(admin);
        PaymentRouter router = new PaymentRouter(
            address(usdc), makeAddr("pt"), makeAddr("rt"), makeAddr("lt"), admin
        );
        f = new DeliveryMissionFactory(address(router));
        f.setDisputeResolver(makeAddr("resolver"));
        vm.stopPrank();
    }

    function _createOrder(DeliveryMissionFactory f, address p, uint256 amt) internal returns (uint256 id) {
        uint256 expiresAt = block.timestamp + 2 hours;
        DeliveryEscrow.DeliveryParams memory dp = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(0, 0, bytes32("pickup"), 0, 0, false),
            dropoff: DeliveryEscrow.DeliveryLocation(0, 0, bytes32("dropoff"), 0, 0, false),
            package: DeliveryEscrow.PackageDetails(1, 1, 1000, 0),
            pickupWindowStart: block.timestamp,
            pickupWindowEnd: expiresAt,
            deliveryDeadline: expiresAt,
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });
        DeliveryEscrow.DeliverySettlement memory s = DeliveryEscrow.DeliverySettlement({
            foodCost: 0,
            deliveryFee: amt,
            restaurantDAO: address(0),
            subDAOFeeBps: 0,
            metaDAO: address(0),
            metaDAOFeeBps: 0
        });
        DeliveryEscrow.DeliveryWaypoint[] memory wp = new DeliveryEscrow.DeliveryWaypoint[](0);
        vm.startPrank(p);
        usdc.approve(address(f), amt);
        id = f.createDeliveryMission(
            address(usdc), amt, expiresAt, address(0), bytes32("m"), bytes32("l"), dp, s, wp
        );
        vm.stopPrank();
    }

    function test_RealFactory_PolicyBindsToRealEscrow() public {
        DeliveryMissionFactory f = _realFactory();
        vm.prank(owner);
        DeliveriesDAO real = new DeliveriesDAO(address(usdc));
        vm.prank(owner);
        real.setDeliveryFactory(address(f));
        _fund(real, POOL_SEED);

        uint256 big = _createOrder(f, poster, 2_500e6); // reward above the per-policy cap
        uint256 small = _createOrder(f, poster, 300e6);
        assertEq(usdc.balanceOf(f.missions(big)), 2_500e6, "escrow funded");

        vm.startPrank(poster);
        usdc.approve(address(real), 1_000e6);
        // unknown id (mission 0 and missionCount+1)
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.UnknownMission.selector, 0));
        real.createInsurancePolicy(0, 100e6, false);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.UnknownMission.selector, 99));
        real.createInsurancePolicy(99, 100e6, false);
        // coverage bound = min(reward, cap)
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.InvalidCoverage.selector, 1_000e6 + 1, 1_000e6));
        real.createInsurancePolicy(big, 1_000e6 + 1, false);
        vm.expectRevert(abi.encodeWithSelector(DeliveriesDAO.InvalidCoverage.selector, 300e6 + 1, 300e6));
        real.createInsurancePolicy(small, 300e6 + 1, false);
        real.createInsurancePolicy(big, 1_000e6, false);
        vm.stopPrank();

        // non-poster cannot insure someone else's order
        vm.prank(poster2);
        vm.expectRevert(DeliveriesDAO.NotMissionPoster.selector);
        real.createInsurancePolicy(small, 100e6, false);

        // Accepted is still insurable; Cancelled is not.
        DeliveryEscrow esc = DeliveryEscrow(payable(f.missions(small)));
        vm.prank(performer);
        esc.acceptMission();
        assertEq(uint8(f.getMissionRuntime(small).state), uint8(IMissionEscrow.MissionState.Accepted));
        vm.startPrank(poster);
        usdc.approve(address(real), 10e6);
        real.createInsurancePolicy(small, 300e6, false);
        vm.stopPrank();

        uint256 third = _createOrder(f, poster, 500e6);
        DeliveryEscrow thirdEsc = DeliveryEscrow(payable(f.missions(third)));
        vm.prank(poster);
        thirdEsc.cancelMission();
        assertEq(usdc.balanceOf(address(thirdEsc)), 0, "escrow refunded");
        vm.prank(poster);
        vm.expectRevert(DeliveriesDAO.MissionNotInsurable.selector);
        real.createInsurancePolicy(third, 100e6, false);

        assertEq(real.reservedCoverage(), 1_300e6);

    }

    /// @notice closePolicy reads the real escrow state through the factory.
    function test_RealFactory_ClosePolicyReadsEscrowState() public {
        DeliveryMissionFactory f = _realFactory();
        vm.prank(owner);
        DeliveriesDAO real = new DeliveriesDAO(address(usdc));
        vm.prank(owner);
        real.setDeliveryFactory(address(f));
        _fund(real, POOL_SEED);

        uint256 a = _createOrder(f, poster, 400e6);
        uint256 b = _createOrder(f, poster, 600e6);
        vm.startPrank(poster);
        usdc.approve(address(real), 20e6);
        real.createInsurancePolicy(a, 400e6, false);
        real.createInsurancePolicy(b, 600e6, false);
        vm.stopPrank();

        // Accepted: still covered.
        address escA = f.missions(a);
        vm.prank(performer);
        DeliveryEscrow(payable(escA)).acceptMission();
        vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
        real.recordPolicyTerminal(a);
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
        real.closePolicy(a);

        // Open: still covered; Cancelled by its poster: closable.
        vm.prank(owner);
        vm.expectRevert(DeliveriesDAO.PolicyStillCovering.selector);
        real.closePolicy(b);
        address escB = f.missions(b);
        vm.prank(poster);
        DeliveryEscrow(payable(escB)).cancelMission();
        assertEq(uint8(f.getMissionRuntime(b).state), uint8(IMissionEscrow.MissionState.Cancelled));
        real.recordPolicyTerminal(b); // reads the real escrow through the issuing factory
        assertEq(real.getPolicy(b).factory, address(f));
        vm.warp(block.timestamp + real.CLAIM_WINDOW());
        vm.prank(owner);
        real.closePolicy(b);
        assertEq(real.reservedCoverage(), 400e6);
    }

    // =========================================================================
    // Factory queue: overwrite cancels a hostile queued factory; stale pending limits
    // left by a tightening cannot be replayed.
    // =========================================================================
    function test_FactoryQueue_OverwriteIsTheOnlyCancel_AndStalePendingIsNotReplayable() public {
        address hostile = makeAddr("hostile");
        vm.startPrank(owner);
        dao.setDeliveryFactory(hostile);
        assertEq(dao.pendingDeliveryFactory(), hostile);
        // Overwrite with the honest registry (the only cancel available)
        dao.setDeliveryFactory(address(registry));
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        dao.applyDeliveryFactory();
        assertEq(dao.deliveryFactory(), address(registry));
        // nothing left to apply
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.applyDeliveryFactory();

        // Queue a loosening, then tighten (cancels eta but leaves pending values in storage)
        dao.setPayoutLimits(1_000_000e6, 1_000_000e6);
        dao.setPayoutLimits(1e6, 1e6);
        assertEq(dao.pendingMaxPayoutPerPeriod(), 1_000_000e6, "stale pending value remains");
        vm.warp(block.timestamp + dao.CONFIG_DELAY());
        vm.expectRevert(DeliveriesDAO.NothingQueued.selector);
        dao.applyPayoutLimits(); // stale values cannot be replayed: OK
        vm.stopPrank();
    }
}
