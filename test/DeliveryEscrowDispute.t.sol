// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title DeliveryEscrowDisputeTest
 * @notice Issue #950: DeliveryEscrow.settleDispute must route the restaurant's food cost
 *         through settleRestaurantOrder instead of paying the whole order to the courier.
 */
contract DeliveryEscrowDisputeTest is Test {
    DeliveryMissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);
    address public restaurantDAO = address(7);
    address public metaDAO = address(8);
    address public restaurantTreasury = address(9);
    address public metaDAOTreasury = address(10);
    address public resolver;

    uint256 public constant FOOD_COST = 80e6;
    uint256 public constant DELIVERY_FEE = 20e6;
    uint256 public constant TIP = 5e6;
    uint16 public constant SUBDAO_FEE_BPS = 200;
    uint16 public constant METADAO_FEE_BPS = 50;
    uint256 public constant BPS = 10_000;

    uint8 internal constant POSTER_WINS = 1;
    uint8 internal constant PERFORMER_WINS = 2;
    uint8 internal constant SPLIT = 3;
    uint8 internal constant CANCELLED = 4;

    struct Balances {
        uint256 poster;
        uint256 performer;
        uint256 restaurant;
        uint256 metaDAO;
        uint256 protocol;
        uint256 labs;
        uint256 resolver;
    }

    function setUp() public {
        resolver = makeAddr("deliveryDisputeResolver");

        vm.startPrank(owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury, owner);
        factory = new DeliveryMissionFactory(address(router));
        factory.setDisputeResolver(resolver);
        router.setMissionFactory(address(factory));
        router.setGuildTreasury(restaurantDAO, restaurantTreasury);
        router.setGuildTreasury(metaDAO, metaDAOTreasury);
        vm.stopPrank();

        usdc.mint(poster, 1_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _params(uint256 tip) internal view returns (DeliveryEscrow.DeliveryParams memory) {
        return DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(37774900, -122419400, keccak256("pickup"), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(34052200, -118243700, keccak256("dropoff"), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(3, 2, 1000, 0),
            pickupWindowStart: block.timestamp + 1 hours,
            pickupWindowEnd: block.timestamp + 3 hours,
            deliveryDeadline: block.timestamp + 8 hours,
            realTimeTrackingEnabled: false,
            tipAmount: tip
        });
    }

    function _settlement(uint256 foodCost, uint256 deliveryFee)
        internal
        view
        returns (DeliveryEscrow.DeliverySettlement memory)
    {
        return DeliveryEscrow.DeliverySettlement({
            foodCost: foodCost,
            deliveryFee: deliveryFee,
            restaurantDAO: restaurantDAO,
            subDAOFeeBps: SUBDAO_FEE_BPS,
            metaDAO: metaDAO,
            metaDAOFeeBps: METADAO_FEE_BPS
        });
    }

    function _waypoints() internal view returns (DeliveryEscrow.DeliveryWaypoint[] memory wps) {
        wps = new DeliveryEscrow.DeliveryWaypoint[](1);
        wps[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("dropoff"),
            latitude: 34052200,
            longitude: -118243700,
            waypointType: 2,
            arrivalDeadline: 0,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });
    }

    /// @dev Create a delivery mission and have the courier accept it.
    function _createAccepted(uint256 foodCost, uint256 deliveryFee, uint256 tip)
        internal
        returns (DeliveryEscrow escrow)
    {
        uint256 reward = foodCost + deliveryFee + tip;
        vm.startPrank(poster);
        usdc.approve(address(factory), reward);
        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            reward,
            block.timestamp + 1 days,
            address(0),
            keccak256("metadata"),
            keccak256("location"),
            _params(tip),
            _settlement(foodCost, deliveryFee),
            _waypoints()
        );
        vm.stopPrank();
        escrow = DeliveryEscrow(payable(factory.missions(missionId)));

        vm.prank(performer);
        escrow.acceptMission();
    }

    function _createDisputed(uint256 foodCost, uint256 deliveryFee, uint256 tip)
        internal
        returns (DeliveryEscrow escrow)
    {
        escrow = _createAccepted(foodCost, deliveryFee, tip);
        vm.prank(poster);
        escrow.raiseDispute(keccak256("dispute"));
    }

    function _snap() internal view returns (Balances memory b) {
        b.poster = usdc.balanceOf(poster);
        b.performer = usdc.balanceOf(performer);
        b.restaurant = usdc.balanceOf(restaurantTreasury);
        b.metaDAO = usdc.balanceOf(metaDAOTreasury);
        b.protocol = usdc.balanceOf(protocolTreasury);
        b.labs = usdc.balanceOf(labsTreasury);
        b.resolver = usdc.balanceOf(resolverTreasury);
    }

    function _deltas(Balances memory b) internal view returns (Balances memory d) {
        Balances memory a = _snap();
        d.poster = a.poster - b.poster;
        d.performer = a.performer - b.performer;
        d.restaurant = a.restaurant - b.restaurant;
        d.metaDAO = a.metaDAO - b.metaDAO;
        d.protocol = a.protocol - b.protocol;
        d.labs = a.labs - b.labs;
        d.resolver = a.resolver - b.resolver;
    }

    function _sum(Balances memory d) internal pure returns (uint256) {
        return d.poster + d.performer + d.restaurant + d.metaDAO + d.protocol + d.labs + d.resolver;
    }

    /// @dev Courier's share of a delivery fee after the PaymentRouter hierarchy split.
    function _courierNet(uint256 fee) internal pure returns (uint256) {
        return fee - (fee * 250) / BPS - (fee * 250) / BPS - (fee * 200) / BPS
            - (fee * METADAO_FEE_BPS) / BPS - (fee * SUBDAO_FEE_BPS) / BPS;
    }

    function _settle(DeliveryEscrow escrow, uint8 outcome, uint256 split)
        internal
        returns (Balances memory d)
    {
        uint256 routerBefore = usdc.balanceOf(address(router));
        Balances memory b = _snap();
        vm.prank(resolver);
        escrow.settleDispute(outcome, split);
        d = _deltas(b);

        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow must be empty");
        assertEq(usdc.balanceOf(address(router)), routerBefore, "router must not retain funds");
        assertEq(_sum(d), escrow.getParams().rewardAmount, "outflows must equal rewardAmount");
        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Completed));
    }

    // -------------------------------------------------------------------------
    // Refund outcomes
    // -------------------------------------------------------------------------

    function test_PosterWins_RefundsFullOrderNoFees() public {
        DeliveryEscrow escrow = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        uint256 reward = FOOD_COST + DELIVERY_FEE + TIP;

        vm.expectEmit(true, false, false, true, address(escrow));
        emit IMissionEscrow.DisputeSettled(escrow.getMissionId(), POSTER_WINS, reward, 0);
        Balances memory d = _settle(escrow, POSTER_WINS, 0);

        assertEq(d.poster, reward, "poster must get the full order back");
        assertEq(d.performer + d.restaurant + d.protocol + d.labs + d.resolver + d.metaDAO, 0);
    }

    function test_Cancelled_RefundsFullOrderNoFees() public {
        DeliveryEscrow escrow = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        Balances memory d = _settle(escrow, CANCELLED, 0);
        assertEq(d.poster, FOOD_COST + DELIVERY_FEE + TIP, "poster must get the full order back");
        assertEq(d.restaurant, 0, "restaurant is not paid on-chain on a cancel");
        assertEq(d.performer, 0);
    }

    // -------------------------------------------------------------------------
    // PerformerWins == approveCompletion
    // -------------------------------------------------------------------------

    function test_PerformerWins_MatchesApproveCompletionExactly() public {
        // Reference: the happy path through approveCompletion.
        DeliveryEscrow happy = _createAccepted(FOOD_COST, DELIVERY_FEE, TIP);
        vm.startPrank(performer);
        happy.completeWaypoint(0, keccak256("p0"));
        happy.submitProof(keccak256("final"));
        vm.stopPrank();
        Balances memory b = _snap();
        vm.prank(poster);
        happy.approveCompletion();
        Balances memory expected = _deltas(b);

        // Same order, settled as PerformerWins.
        DeliveryEscrow disputed = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        uint256 reward = FOOD_COST + DELIVERY_FEE + TIP;

        vm.expectEmit(true, true, false, true, address(disputed));
        emit DeliveryEscrow.DeliveryOrderSettled(disputed.getMissionId(), performer, FOOD_COST, DELIVERY_FEE, TIP);
        vm.expectEmit(true, false, false, true, address(disputed));
        emit IMissionEscrow.DisputeSettled(disputed.getMissionId(), PERFORMER_WINS, 0, reward);
        Balances memory got = _settle(disputed, PERFORMER_WINS, 0);

        assertEq(got.poster, 0, "poster gets nothing on PerformerWins");
        assertEq(got.performer, expected.performer, "courier payout differs from approveCompletion");
        assertEq(got.restaurant, expected.restaurant, "restaurant payout differs from approveCompletion");
        assertEq(got.metaDAO, expected.metaDAO, "MetaDAO payout differs");
        assertEq(got.protocol, expected.protocol, "protocol payout differs");
        assertEq(got.labs, expected.labs, "labs payout differs");
        assertEq(got.resolver, expected.resolver, "resolver payout differs");

        // The bug: the courier used to receive ~90% of the whole order, food included.
        assertEq(got.performer, _courierNet(DELIVERY_FEE) + TIP);
        assertLt(got.performer, FOOD_COST, "courier was paid out of the food cost");
    }

    // -------------------------------------------------------------------------
    // Split
    // -------------------------------------------------------------------------

    function _assertSplit(uint256 foodCost, uint256 deliveryFee, uint256 tip, uint256 split) internal {
        DeliveryEscrow escrow = _createDisputed(foodCost, deliveryFee, tip);
        uint256 reward = foodCost + deliveryFee + tip;
        uint256 feeShare = (deliveryFee * split) / BPS;
        uint256 tipShare = (tip * split) / BPS;

        Balances memory d = _settle(escrow, SPLIT, split);

        assertEq(
            d.restaurant,
            foodCost + (feeShare * SUBDAO_FEE_BPS) / BPS,
            "restaurant must get the full food cost (+ SubDAO share of the routed fee)"
        );
        assertEq(d.performer, _courierNet(feeShare) + tipShare, "courier must get fee share net + tip share");
        assertEq(d.poster, reward - foodCost - feeShare - tipShare, "poster gets the remainder");
        assertEq(d.protocol, (feeShare * 250) / BPS, "protocol fee only on the routed fee share");
    }

    function test_Split_0bps() public {
        _assertSplit(FOOD_COST, DELIVERY_FEE, TIP, 0);
    }

    function test_Split_5000bps() public {
        _assertSplit(FOOD_COST, DELIVERY_FEE, TIP, 5000);
    }

    function test_Split_10000bps_EqualsPerformerWins() public {
        _assertSplit(FOOD_COST, DELIVERY_FEE, TIP, 10000);
    }

    function test_Split_3333bps_RoundingGoesToPoster() public {
        _assertSplit(FOOD_COST + 1, DELIVERY_FEE + 7, TIP + 3, 3333);
    }

    function test_Split_ZeroTip() public {
        _assertSplit(FOOD_COST, DELIVERY_FEE, 0, 5000);
    }

    function test_Split_ZeroFoodCost() public {
        _assertSplit(0, DELIVERY_FEE, TIP, 5000);
    }

    /// @notice foodCost == 0 and deliveryFee == 0: the router is skipped entirely.
    function test_Split_TipOnly_SkipsRouter() public {
        DeliveryEscrow escrow = _createDisputed(0, 0, 10e6);
        Balances memory d = _settle(escrow, SPLIT, 2500);
        assertEq(d.performer, 2.5e6, "courier gets 25% of the tip");
        assertEq(d.poster, 7.5e6, "poster gets the rest");
        assertEq(d.protocol + d.labs + d.resolver + d.restaurant + d.metaDAO, 0, "no router fees");
    }

    function test_Split_EmitsDisputeSettledWithPerformerSide() public {
        DeliveryEscrow escrow = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        uint256 feeShare = DELIVERY_FEE / 2;
        uint256 tipShare = TIP / 2;
        uint256 performerSide = FOOD_COST + feeShare + tipShare;
        uint256 reward = FOOD_COST + DELIVERY_FEE + TIP;

        vm.expectEmit(true, true, false, true, address(escrow));
        emit DeliveryEscrow.DeliveryOrderSettled(escrow.getMissionId(), performer, FOOD_COST, feeShare, tipShare);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit IMissionEscrow.DisputeSettled(escrow.getMissionId(), SPLIT, reward - performerSide, performerSide);
        _settle(escrow, SPLIT, 5000);
    }

    // -------------------------------------------------------------------------
    // Reverts
    // -------------------------------------------------------------------------

    function test_RevertWhen_SplitAbove100Percent() public {
        DeliveryEscrow escrow = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(DeliveryEscrow.InvalidSplitPercentage.selector, 10001));
        escrow.settleDispute(SPLIT, 10001);
    }

    function test_RevertWhen_CallerIsNotDisputeResolver() public {
        DeliveryEscrow escrow = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.NotDisputeResolver.selector);
        escrow.settleDispute(POSTER_WINS, 0);

        vm.prank(performer);
        vm.expectRevert(IMissionEscrow.NotDisputeResolver.selector);
        escrow.settleDispute(PERFORMER_WINS, 0);
    }

    function test_RevertWhen_NotDisputed() public {
        DeliveryEscrow escrow = _createAccepted(FOOD_COST, DELIVERY_FEE, TIP);
        vm.prank(resolver);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.settleDispute(PERFORMER_WINS, 0);
    }

    function test_RevertWhen_SettledTwice() public {
        DeliveryEscrow escrow = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        _settle(escrow, PERFORMER_WINS, 0);
        vm.prank(resolver);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.settleDispute(PERFORMER_WINS, 0);
    }

    function test_RevertWhen_OutcomeNone() public {
        DeliveryEscrow escrow = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        vm.prank(resolver);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.settleDispute(0, 0);
    }

    function test_RevertWhen_OutcomeOutOfRange() public {
        DeliveryEscrow escrow = _createDisputed(FOOD_COST, DELIVERY_FEE, TIP);
        vm.prank(resolver);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.settleDispute(5, 0);
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    function testFuzz_SettleDispute_ConservesEveryWei(
        uint256 foodCost,
        uint256 deliveryFee,
        uint256 tip,
        uint256 split,
        uint8 outcomeSeed
    ) public {
        foodCost = bound(foodCost, 0, 100_000e6);
        deliveryFee = bound(deliveryFee, 0, 100_000e6);
        tip = bound(tip, 0, 100_000e6);
        split = bound(split, 0, BPS);
        // Factory minimum is 1 USDC.
        if (foodCost + deliveryFee + tip < 1e6) deliveryFee += 1e6;
        uint8 outcome = uint8(bound(outcomeSeed, 1, 4));

        DeliveryEscrow escrow = _createDisputed(foodCost, deliveryFee, tip);
        uint256 reward = foodCost + deliveryFee + tip;

        // _settle asserts: escrow empty, router residue-free, outflows == rewardAmount.
        Balances memory d = _settle(escrow, outcome, split);

        if (outcome == POSTER_WINS || outcome == CANCELLED) {
            assertEq(d.poster, reward);
        } else {
            uint256 s = outcome == PERFORMER_WINS ? BPS : split;
            uint256 feeShare = (deliveryFee * s) / BPS;
            uint256 tipShare = (tip * s) / BPS;
            assertGe(d.restaurant, foodCost, "restaurant must get at least the food cost");
            assertEq(d.poster, reward - foodCost - feeShare - tipShare);
            assertEq(d.performer, _courierNet(feeShare) + tipShare);
        }
    }
}
