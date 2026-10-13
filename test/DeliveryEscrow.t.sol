// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeliveryEscrowTest is Test {
    DeliveryMissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);

    // audit H5 (#819): the order is split between a restaurant and the courier.
    address public restaurantDAO = address(7);
    address public metaDAO = address(8);
    address public restaurantTreasury = address(9);
    address public metaDAOTreasury = address(10);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC — the FULL order
    uint256 public constant FOOD_COST = 80e6;      // 80 USDC to the restaurant
    uint256 public constant DELIVERY_FEE = 20e6;   // 20 USDC split through the hierarchy

    uint16 public constant SUBDAO_FEE_BPS = 200;   // 2% of the delivery fee
    uint16 public constant METADAO_FEE_BPS = 50;   // 0.5% of the delivery fee
    uint16 public constant BPS = 10_000;

    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);

        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            owner // admin
        );

        factory = new DeliveryMissionFactory(address(router));

        // audit C2: a dispute resolver must be configured before any mission is created.
        factory.setDisputeResolver(makeAddr("deliveryDisputeResolver"));

        // Register the delivery factory with the router so its escrows are recognized
        // as valid settlement callers (PaymentRouter._isFactoryEscrow -> getMissionByEscrow).
        router.setMissionFactory(address(factory));

        // audit H5: DAO payouts land in the registered treasuries.
        router.setGuildTreasury(restaurantDAO, restaurantTreasury);
        router.setGuildTreasury(metaDAO, metaDAOTreasury);

        vm.stopPrank();

        usdc.mint(poster, 1000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _defaultParams() internal view returns (DeliveryEscrow.DeliveryParams memory) {
        return DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(37774900, -122419400, keccak256("pickup addr"), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(34052200, -118243700, keccak256("dropoff addr"), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(1, 2, 5000, 0),
            pickupWindowStart: block.timestamp + 1 hours,
            pickupWindowEnd: block.timestamp + 3 hours,
            deliveryDeadline: block.timestamp + 8 hours,
            realTimeTrackingEnabled: true,
            tipAmount: 0
        });
    }

    /// @dev Standard restaurant order: 80 USDC food + 20 USDC delivery fee = 100 USDC escrowed.
    function _defaultSettlement() internal view returns (DeliveryEscrow.DeliverySettlement memory) {
        return DeliveryEscrow.DeliverySettlement({
            foodCost: FOOD_COST,
            deliveryFee: DELIVERY_FEE,
            restaurantDAO: restaurantDAO,
            subDAOFeeBps: SUBDAO_FEE_BPS,
            metaDAO: metaDAO,
            metaDAOFeeBps: METADAO_FEE_BPS
        });
    }

    function _oneWaypoint() internal view returns (DeliveryEscrow.DeliveryWaypoint[] memory wps) {
        wps = new DeliveryEscrow.DeliveryWaypoint[](1);
        wps[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0,
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });
    }

    function _twoWaypoints() internal view returns (DeliveryEscrow.DeliveryWaypoint[] memory wps) {
        wps = new DeliveryEscrow.DeliveryWaypoint[](2);
        wps[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0,
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });
        wps[1] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("dropoff"),
            latitude: 34052200,
            longitude: -118243700,
            waypointType: 2,
            arrivalDeadline: block.timestamp + 6 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });
    }

    /// @dev Create a fully-initialized delivery mission via the factory (option A flow:
    /// params, settlement breakdown and waypoints are set atomically inside
    /// createDeliveryMission).
    function _createDeliveryMission(
        DeliveryEscrow.DeliveryParams memory params,
        DeliveryEscrow.DeliverySettlement memory settlement,
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints
    ) internal returns (uint256 missionId, address escrowAddress) {
        uint256 reward = settlement.foodCost + settlement.deliveryFee + params.tipAmount;
        return _createDeliveryMissionWithReward(params, settlement, waypoints, reward);
    }

    /// @dev Same, but with an explicit rewardAmount so mismatch cases can be exercised.
    function _createDeliveryMissionWithReward(
        DeliveryEscrow.DeliveryParams memory params,
        DeliveryEscrow.DeliverySettlement memory settlement,
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints,
        uint256 rewardAmount
    ) internal returns (uint256 missionId, address escrowAddress) {
        vm.startPrank(poster);
        usdc.approve(address(factory), rewardAmount);
        missionId = factory.createDeliveryMission(
            address(usdc),
            rewardAmount,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH,
            params,
            settlement,
            waypoints
        );
        escrowAddress = factory.missions(missionId);
        vm.stopPrank();
    }

    /// @dev Attempt a creation that must revert. The USDC approval is done BEFORE
    /// vm.expectRevert so the expectation applies to createDeliveryMission itself.
    function _createExpectingRevert(
        DeliveryEscrow.DeliveryParams memory params,
        DeliveryEscrow.DeliverySettlement memory settlement,
        uint256 rewardAmount,
        bytes memory revertData
    ) internal {
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = _oneWaypoint();

        vm.startPrank(poster);
        usdc.approve(address(factory), rewardAmount);
        vm.expectRevert(revertData);
        factory.createDeliveryMission(
            address(usdc),
            rewardAmount,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH,
            params,
            settlement,
            waypoints
        );
        vm.stopPrank();
    }

    /// @dev Convenience: default restaurant order with the given waypoints.
    function _createDefaultMission(DeliveryEscrow.DeliveryWaypoint[] memory waypoints)
        internal
        returns (uint256 missionId, address escrowAddress)
    {
        return _createDeliveryMission(_defaultParams(), _defaultSettlement(), waypoints);
    }

    /// @dev Drive a mission from Open to Submitted with the default courier.
    function _acceptAndSubmit(DeliveryEscrow escrow, uint256 waypointCount) internal {
        vm.prank(performer);
        escrow.acceptMission();

        vm.startPrank(performer);
        for (uint256 i = 0; i < waypointCount; i++) {
            escrow.completeWaypoint(i, keccak256(abi.encode("proof", i)));
        }
        escrow.submitProof(keccak256("final"));
        vm.stopPrank();
    }

    struct Balances {
        uint256 performer;
        uint256 restaurant;
        uint256 metaDAO;
        uint256 protocol;
        uint256 labs;
        uint256 resolver;
    }

    function _snapshotBalances() internal view returns (Balances memory b) {
        b.performer = usdc.balanceOf(performer);
        b.restaurant = usdc.balanceOf(restaurantTreasury);
        b.metaDAO = usdc.balanceOf(metaDAOTreasury);
        b.protocol = usdc.balanceOf(protocolTreasury);
        b.labs = usdc.balanceOf(labsTreasury);
        b.resolver = usdc.balanceOf(resolverTreasury);
    }

    function _deltas(Balances memory before) internal view returns (Balances memory d) {
        d.performer = usdc.balanceOf(performer) - before.performer;
        d.restaurant = usdc.balanceOf(restaurantTreasury) - before.restaurant;
        d.metaDAO = usdc.balanceOf(metaDAOTreasury) - before.metaDAO;
        d.protocol = usdc.balanceOf(protocolTreasury) - before.protocol;
        d.labs = usdc.balanceOf(labsTreasury) - before.labs;
        d.resolver = usdc.balanceOf(resolverTreasury) - before.resolver;
    }

    function _sum(Balances memory d) internal pure returns (uint256) {
        return d.performer + d.restaurant + d.metaDAO + d.protocol + d.labs + d.resolver;
    }

    // -------------------------------------------------------------------------
    // Bug 1: delivery params are set atomically on create (issue #812)
    // -------------------------------------------------------------------------

    function test_DeliveryParamsSetOnCreate() public {
        DeliveryEscrow.DeliveryParams memory params = _defaultParams();
        (, address escrowAddress) = _createDeliveryMission(params, _defaultSettlement(), _twoWaypoints());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        DeliveryEscrow.DeliveryParams memory stored = escrow.getDeliveryParams();
        assertEq(stored.pickup.latitude, params.pickup.latitude);
        assertEq(stored.dropoff.latitude, params.dropoff.latitude);
        assertTrue(stored.realTimeTrackingEnabled);

        // Waypoints recorded too
        assertEq(escrow.getWaypoints().length, 2);
        assertEq(escrow.getWaypoint(0).waypointType, 0);
        assertEq(escrow.getWaypoint(1).waypointType, 2);
    }

    /// @notice audit H5: the settlement breakdown is recorded on-chain at creation.
    function test_SettlementBreakdownSetOnCreate() public {
        (uint256 missionId, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        DeliveryEscrow.DeliverySettlement memory s = escrow.getSettlement();
        assertEq(s.foodCost, FOOD_COST);
        assertEq(s.deliveryFee, DELIVERY_FEE);
        assertEq(s.restaurantDAO, restaurantDAO);
        assertEq(s.metaDAO, metaDAO);
        assertEq(s.subDAOFeeBps, SUBDAO_FEE_BPS);
        assertEq(s.metaDAOFeeBps, METADAO_FEE_BPS);

        // Same values readable through the factory
        assertEq(factory.getSettlement(missionId).foodCost, FOOD_COST);
    }

    /// @notice initializeDelivery stays factory-only AND one-shot: a second call
    /// (even from a non-factory address) must revert, so params can't be overwritten.
    function test_RevertWhen_InitializeDeliveryCalledAgain() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // Non-factory caller is rejected before the already-initialized check.
        vm.prank(poster);
        vm.expectRevert(DeliveryEscrow.NotFactory.selector);
        escrow.initializeDelivery(_defaultParams(), _defaultSettlement(), _oneWaypoint());
    }

    // -------------------------------------------------------------------------
    // Bug 2: escrow is authorized for settlement (issue #812)
    // -------------------------------------------------------------------------

    function test_GetMissionByEscrow() public {
        (uint256 missionId, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        assertEq(factory.getMissionByEscrow(escrowAddress), missionId);
        assertEq(factory.getMissionByEscrow(address(0xdead)), 0);
    }

    // -------------------------------------------------------------------------
    // audit H5 (#819): approveCompletion splits food cost vs delivery fee
    // -------------------------------------------------------------------------

    /// @notice The restaurant is paid its food cost in full and the courier only earns
    /// the delivery fee net of protocol fees. Before this fix the courier received ~90%
    /// of the WHOLE order (food included) and the restaurant received nothing.
    function test_ApproveCompletion_SplitsFoodCostAndDeliveryFee() public {
        (, address escrowAddress) = _createDefaultMission(_twoWaypoints());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));
        _acceptAndSubmit(escrow, 2);

        Balances memory before = _snapshotBalances();

        vm.prank(poster);
        escrow.approveCompletion();

        Balances memory got = _deltas(before);

        // Expected split of the DELIVERY FEE only
        uint256 expProtocol = (DELIVERY_FEE * 250) / BPS;  // 2.5%
        uint256 expLabs     = (DELIVERY_FEE * 250) / BPS;  // 2.5%
        uint256 expResolver = (DELIVERY_FEE * 200) / BPS;  // 2%
        uint256 expMeta     = (DELIVERY_FEE * METADAO_FEE_BPS) / BPS;
        uint256 expSub      = (DELIVERY_FEE * SUBDAO_FEE_BPS) / BPS;
        uint256 expCourier  = DELIVERY_FEE - expProtocol - expLabs - expResolver - expMeta - expSub;

        assertEq(got.performer, expCourier, "courier must earn only the delivery fee net of fees");
        assertEq(got.protocol, expProtocol, "protocol fee wrong");
        assertEq(got.labs, expLabs, "labs fee wrong");
        assertEq(got.resolver, expResolver, "resolver fee wrong");
        assertEq(got.metaDAO, expMeta, "MetaDAO fee wrong");

        // The restaurant treasury receives the food cost in full, plus its SubDAO share
        // of the delivery fee (both land in the same registered treasury).
        assertEq(got.restaurant, FOOD_COST + expSub, "restaurant payout wrong");

        // The courier must NOT be paid out of the food cost — the pre-fix behaviour
        // handed them ~90% of the whole order.
        assertLt(got.performer, FOOD_COST, "courier was paid out of the food cost");
        assertEq(got.performer, 18_100_000, "courier should get 18.1 USDC of a 20 USDC fee");
    }

    /// @notice With no SubDAO fee the restaurant receives EXACTLY the food cost.
    function test_ApproveCompletion_RestaurantReceivesExactlyFoodCost() public {
        DeliveryEscrow.DeliverySettlement memory s = _defaultSettlement();
        s.subDAOFeeBps = 0;
        s.metaDAOFeeBps = 0;

        (, address escrowAddress) = _createDeliveryMission(_defaultParams(), s, _oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));
        _acceptAndSubmit(escrow, 1);

        uint256 restaurantBefore = usdc.balanceOf(restaurantTreasury);

        vm.prank(poster);
        escrow.approveCompletion();

        assertEq(
            usdc.balanceOf(restaurantTreasury) - restaurantBefore,
            FOOD_COST,
            "restaurant must receive exactly the food cost"
        );
    }

    /// @notice Every escrowed wei is accounted for: payouts sum to the order total and
    /// neither the escrow nor the router retains a residue.
    function test_ApproveCompletion_ConservesEveryWei() public {
        (, address escrowAddress) = _createDefaultMission(_twoWaypoints());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));
        _acceptAndSubmit(escrow, 2);

        assertEq(usdc.balanceOf(escrowAddress), REWARD_AMOUNT, "escrow must hold the full order");
        uint256 routerBefore = usdc.balanceOf(address(router));

        Balances memory before = _snapshotBalances();

        vm.prank(poster);
        escrow.approveCompletion();

        assertEq(_sum(_deltas(before)), REWARD_AMOUNT, "payouts must sum to the order total");
        assertEq(usdc.balanceOf(escrowAddress), 0, "escrow must be empty");
        assertEq(usdc.balanceOf(address(router)), routerBefore, "router must not retain funds");
        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Completed));
    }

    /// @notice The performer floor applies to the delivery-fee portion (not the food cost).
    function test_ApproveCompletion_PerformerFloorHoldsOnDeliveryFee() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));
        _acceptAndSubmit(escrow, 1);

        uint256 performerBefore = usdc.balanceOf(performer);

        vm.prank(poster);
        escrow.approveCompletion();

        uint256 got = usdc.balanceOf(performer) - performerBefore;
        assertGe(
            got,
            (DELIVERY_FEE * router.performerFloorBPS()) / BPS,
            "courier below performer floor on the delivery fee"
        );
        assertLe(got, DELIVERY_FEE, "courier cannot earn more than the delivery fee");
    }

    /// @notice A plain courier job (no restaurant) still settles: the whole reward is the
    /// delivery fee and the courier keeps it net of the fixed protocol fees.
    function test_ApproveCompletion_NonFoodDeliveryHasNoRestaurantLeg() public {
        DeliveryEscrow.DeliverySettlement memory s = DeliveryEscrow.DeliverySettlement({
            foodCost: 0,
            deliveryFee: REWARD_AMOUNT,
            restaurantDAO: address(0),
            subDAOFeeBps: 0,
            metaDAO: address(0),
            metaDAOFeeBps: 0
        });

        (, address escrowAddress) = _createDeliveryMission(_defaultParams(), s, _oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));
        _acceptAndSubmit(escrow, 1);

        Balances memory before = _snapshotBalances();

        vm.prank(poster);
        escrow.approveCompletion();

        Balances memory got = _deltas(before);
        assertEq(got.restaurant, 0, "no restaurant leg expected");
        // 7% fixed fees, courier keeps 93%
        assertEq(got.performer, (REWARD_AMOUNT * 9300) / BPS, "courier should keep 93%");
        assertEq(_sum(got), REWARD_AMOUNT, "payouts must sum to the order total");
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @notice Tip decision: tips are paid to the courier IN FULL, with no protocol fee,
    /// and are escrowed as part of rewardAmount (rewardAmount == food + fee + tip).
    function test_ApproveCompletion_TipGoesEntirelyToCourier() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();

        uint256 tip = 5e6;
        vm.startPrank(poster);
        usdc.approve(address(escrow), tip);
        escrow.addTip(tip);
        vm.stopPrank();

        vm.startPrank(performer);
        escrow.completeWaypoint(0, keccak256("p0"));
        escrow.submitProof(keccak256("final"));
        vm.stopPrank();

        // addTip keeps the invariant: reward grew by exactly the tip.
        assertEq(escrow.getParams().rewardAmount, REWARD_AMOUNT + tip);

        Balances memory before = _snapshotBalances();

        vm.prank(poster);
        escrow.approveCompletion();

        Balances memory got = _deltas(before);

        uint256 expSub = (DELIVERY_FEE * SUBDAO_FEE_BPS) / BPS;
        // Courier gets the net delivery fee PLUS 100% of the tip.
        assertEq(got.performer, 18_100_000 + tip, "tip must reach the courier untaxed");
        assertEq(got.restaurant, FOOD_COST + expSub, "tip must not change the restaurant payout");
        assertEq(_sum(got), REWARD_AMOUNT + tip, "payouts must sum to order + tip");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow must be empty");
    }

    /// @notice A tip declared upfront is funded from the escrowed reward and behaves the same.
    function test_ApproveCompletion_UpfrontTipIsEscrowedAndPaidToCourier() public {
        DeliveryEscrow.DeliveryParams memory params = _defaultParams();
        params.tipAmount = 3e6;

        (, address escrowAddress) = _createDeliveryMission(params, _defaultSettlement(), _oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // rewardAmount == food + fee + upfront tip
        assertEq(escrow.getParams().rewardAmount, FOOD_COST + DELIVERY_FEE + 3e6);
        assertEq(usdc.balanceOf(escrowAddress), FOOD_COST + DELIVERY_FEE + 3e6);

        _acceptAndSubmit(escrow, 1);

        Balances memory before = _snapshotBalances();
        vm.prank(poster);
        escrow.approveCompletion();
        Balances memory got = _deltas(before);

        assertEq(got.performer, 18_100_000 + 3e6, "upfront tip must reach the courier untaxed");
        assertEq(_sum(got), FOOD_COST + DELIVERY_FEE + 3e6);
    }

    // -------------------------------------------------------------------------
    // audit H5: creation-time validation
    // -------------------------------------------------------------------------

    function test_RevertWhen_BreakdownDoesNotMatchReward() public {
        // Escrow 101 USDC but only account for 100 -> 1 USDC would be stranded.
        _createExpectingRevert(
            _defaultParams(),
            _defaultSettlement(),
            REWARD_AMOUNT + 1e6,
            abi.encodeWithSelector(
                DeliveryEscrow.SettlementBreakdownMismatch.selector,
                REWARD_AMOUNT + 1e6, // escrowed
                REWARD_AMOUNT        // accounted for
            )
        );
    }

    function test_RevertWhen_BreakdownExceedsReward() public {
        DeliveryEscrow.DeliverySettlement memory s = _defaultSettlement();
        s.foodCost = FOOD_COST + 10e6;

        // Promising 110 out of a 100 USDC escrow would revert mid-settlement.
        _createExpectingRevert(
            _defaultParams(),
            s,
            REWARD_AMOUNT,
            abi.encodeWithSelector(
                DeliveryEscrow.SettlementBreakdownMismatch.selector,
                REWARD_AMOUNT,
                REWARD_AMOUNT + 10e6
            )
        );
    }

    /// @notice The upfront tip must be covered by the escrowed reward too.
    function test_RevertWhen_UpfrontTipNotEscrowed() public {
        DeliveryEscrow.DeliveryParams memory params = _defaultParams();
        params.tipAmount = 5e6;

        // rewardAmount only covers food + fee, so the tip is unfunded.
        _createExpectingRevert(
            params,
            _defaultSettlement(),
            REWARD_AMOUNT,
            abi.encodeWithSelector(
                DeliveryEscrow.SettlementBreakdownMismatch.selector,
                REWARD_AMOUNT,
                REWARD_AMOUNT + 5e6
            )
        );
    }

    function test_RevertWhen_SubDAOFeeAboveCap() public {
        DeliveryEscrow.DeliverySettlement memory s = _defaultSettlement();
        uint16 cap = router.MAX_SUBDAO_FEE_BPS();
        s.subDAOFeeBps = cap + 1;

        _createExpectingRevert(
            _defaultParams(),
            s,
            REWARD_AMOUNT,
            abi.encodeWithSelector(DeliveryMissionFactory.SubDAOFeeTooHigh.selector, cap + 1, cap)
        );
    }

    function test_RevertWhen_MetaDAOFeeAboveCap() public {
        DeliveryEscrow.DeliverySettlement memory s = _defaultSettlement();
        uint16 cap = router.MAX_METADAO_FEE_BPS();
        s.metaDAOFeeBps = cap + 1;

        _createExpectingRevert(
            _defaultParams(),
            s,
            REWARD_AMOUNT,
            abi.encodeWithSelector(DeliveryMissionFactory.MetaDAOFeeTooHigh.selector, cap + 1, cap)
        );
    }

    /// @notice Fees within their individual caps can still breach the performer floor
    /// once governance raises it — creation must fail rather than settlement.
    function test_RevertWhen_FeesBreachPerformerFloor() public {
        vm.prank(owner);
        router.setPerformerFloor(9200); // max total fees = 800 bps; fixed alone are 700

        DeliveryEscrow.DeliverySettlement memory s = _defaultSettlement();
        s.subDAOFeeBps = 200;
        s.metaDAOFeeBps = 0;

        _createExpectingRevert(
            _defaultParams(),
            s,
            REWARD_AMOUNT,
            abi.encodeWithSelector(DeliveryMissionFactory.PerformerFloorViolated.selector, 900, 800)
        );
    }

    function test_RevertWhen_FoodCostWithoutRestaurantDAO() public {
        DeliveryEscrow.DeliverySettlement memory s = _defaultSettlement();
        s.restaurantDAO = address(0);

        _createExpectingRevert(
            _defaultParams(),
            s,
            REWARD_AMOUNT,
            abi.encodeWithSelector(DeliveryEscrow.MissingRestaurantDAO.selector)
        );
    }

    function test_RevertWhen_MetaDAOFeeWithoutMetaDAO() public {
        DeliveryEscrow.DeliverySettlement memory s = _defaultSettlement();
        s.metaDAO = address(0);

        _createExpectingRevert(
            _defaultParams(),
            s,
            REWARD_AMOUNT,
            abi.encodeWithSelector(DeliveryEscrow.MissingMetaDAO.selector)
        );
    }

    // -------------------------------------------------------------------------
    // audit C2: dispute resolver must be set, and a disputed delivery is settleable
    // -------------------------------------------------------------------------

    function test_RevertWhen_CreateWithoutDisputeResolver() public {
        // A fresh factory with no resolver configured must refuse to create missions.
        vm.prank(owner);
        DeliveryMissionFactory bare = new DeliveryMissionFactory(address(router));

        vm.startPrank(poster);
        usdc.approve(address(bare), REWARD_AMOUNT);
        vm.expectRevert(DeliveryMissionFactory.DisputeResolverNotSet.selector);
        bare.createDeliveryMission(
            address(usdc), REWARD_AMOUNT, block.timestamp + 1 days,
            address(0), METADATA_HASH, LOCATION_HASH,
            _defaultParams(), _defaultSettlement(), _oneWaypoint()
        );
        vm.stopPrank();
    }

    function test_DisputedDeliveryIsSettleable_NotFrozen() public {
        (, address escrowAddress) = _createDefaultMission(_twoWaypoints());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // The escrow was initialized with the real resolver, so a raised dispute
        // can actually be settled (before C2 it froze forever: resolver was address(0)).
        vm.prank(performer);
        escrow.acceptMission();
        vm.prank(performer);
        escrow.raiseDispute(keccak256("dispute"));
        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Disputed));

        uint256 performerBefore = usdc.balanceOf(performer);

        // The configured resolver can settle it (performer wins) — funds move.
        vm.prank(factory.disputeResolver());
        escrow.settleDispute(2, 0);
        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Completed));
        assertGt(usdc.balanceOf(performer), performerBefore, "dispute payout must reach the performer");
        assertEq(usdc.balanceOf(escrowAddress), 0, "escrow must be empty after dispute settlement");
    }

    /// @notice A poster-wins dispute still refunds the full order (food included).
    function test_DisputedDelivery_PosterWinsRefundsFullOrder() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();
        vm.prank(poster);
        escrow.raiseDispute(keccak256("dispute"));

        uint256 posterBefore = usdc.balanceOf(poster);
        vm.prank(factory.disputeResolver());
        escrow.settleDispute(1, 0);

        assertEq(usdc.balanceOf(poster) - posterBefore, REWARD_AMOUNT, "poster must be fully refunded");
    }

    /// @notice claimExpired / grace-window behaviour is unchanged by the H5 rework.
    function test_ClaimExpired_RefundsFullOrderAfterGrace() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        uint256 expiresAt = escrow.getParams().expiresAt;

        // Inside the grace window the poster cannot reclaim.
        vm.warp(expiresAt + 1);
        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.MissionNotExpired.selector);
        escrow.claimExpired();

        // After the grace window the full order is refunded.
        vm.warp(expiresAt + escrow.SUBMISSION_GRACE_PERIOD() + 1);
        uint256 posterBefore = usdc.balanceOf(poster);
        vm.prank(poster);
        escrow.claimExpired();

        assertEq(usdc.balanceOf(poster) - posterBefore, REWARD_AMOUNT);
        assertEq(uint8(escrow.getRuntime().state), uint8(IMissionEscrow.MissionState.Cancelled));
    }

    // -------------------------------------------------------------------------
    // Existing behaviour (now reachable because params are actually set)
    // -------------------------------------------------------------------------

    function test_CompleteWaypoint() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();

        bytes32 proofHash = keccak256("pickup proof");
        vm.prank(performer);
        escrow.completeWaypoint(0, proofHash);

        DeliveryEscrow.DeliveryWaypoint memory waypoint = escrow.getWaypoint(0);
        assertTrue(waypoint.completed);
        assertEq(waypoint.proofHash, proofHash);
    }

    function test_AddTrackingCheckpoint() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(performer);
        escrow.addTrackingCheckpoint(37800000, -122400000, 0); // enRoute

        DeliveryEscrow.TrackingCheckpoint memory checkpoint = escrow.getLatestCheckpoint();
        assertEq(checkpoint.latitude, 37800000);
        assertEq(checkpoint.longitude, -122400000);
        assertEq(checkpoint.checkpointType, 0);
    }

    function test_AddTip() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();

        uint256 tipAmount = 10e6; // 10 USDC
        vm.startPrank(poster);
        usdc.approve(address(escrow), tipAmount);
        escrow.addTip(tipAmount);
        vm.stopPrank();

        assertEq(escrow.getTipAmount(), tipAmount);
        assertEq(usdc.balanceOf(address(escrow)), REWARD_AMOUNT + tipAmount);
    }

    function test_RevertWhen_SubmitProofWithIncompleteWaypoints() public {
        (, address escrowAddress) = _createDefaultMission(_twoWaypoints());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(performer);
        escrow.completeWaypoint(0, keccak256("proof1"));

        vm.prank(performer);
        vm.expectRevert("All waypoints must be completed");
        escrow.submitProof(keccak256("final proof"));
    }

    function test_SubmitProofAfterAllWaypointsCompleted() public {
        (uint256 missionId, address escrowAddress) = _createDefaultMission(_twoWaypoints());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();

        vm.startPrank(performer);
        escrow.completeWaypoint(0, keccak256("proof1"));
        escrow.completeWaypoint(1, keccak256("proof2"));

        bytes32 finalProof = keccak256("final proof");
        escrow.submitProof(finalProof);
        vm.stopPrank();

        IMissionEscrow.MissionRuntime memory runtime = factory.getMissionRuntime(missionId);
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Submitted));
        assertEq(runtime.proofHash, finalProof);
    }

    /// @notice Only the poster may approve, and only from Submitted.
    function test_RevertWhen_ApproveCompletionByNonPoster() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));
        _acceptAndSubmit(escrow, 1);

        vm.prank(performer);
        vm.expectRevert(IMissionEscrow.NotPoster.selector);
        escrow.approveCompletion();
    }

    function test_RevertWhen_ApproveCompletionBeforeSubmission() public {
        (, address escrowAddress) = _createDefaultMission(_oneWaypoint());
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.approveCompletion();
    }
}
