// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeliveryEscrow } from "../src/DeliveryEscrow.sol";
import { DeliveryMissionFactory } from "../src/DeliveryMissionFactory.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { IDisputeResolver } from "../src/interfaces/IDisputeResolver.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { IPaymentRouter } from "../src/interfaces/IPaymentRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { DeployDeliveryContracts } from "../script/DeployDeliveryContracts.s.sol";
import { DeliveryRouterWiring } from "../script/lib/DeliveryRouterWiring.sol";

/// @dev Exposes the library's internal functions so expectRevert can observe them.
contract WiringHarness {
    function assertSettlementReady(PaymentRouter router, address factory) external view {
        DeliveryRouterWiring.assertSettlementReady(router, factory);
    }
}

/**
 * @notice #950 review follow-up (PR #952): a DeliveryEscrow dispute settlement only works when
 *         the PaymentRouter recognises the escrow clones, i.e. router.missionFactory() points at
 *         the DeliveryMissionFactory. These tests cover the deploy script (fails closed, wires the
 *         router) and the on-chain failure mode it prevents.
 */
contract DeliveryRouterWiringTest is Test {
    PaymentRouter public router;
    DisputeResolver public dr;
    MockERC20 public usdc;
    DeployDeliveryContracts public script;
    WiringHarness public harness;

    uint256 internal constant ADMIN_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B;
    address internal admin;

    address public poster = address(0x2001);
    address public performer = address(0x2002);
    address public protocolTreasury = address(0x2003);
    address public resolverTreasury = address(0x2004);
    address public labsTreasury = address(0x2005);
    address public restaurantDAO = address(0x2006);
    address public metaDAO = address(0x2007);
    address public restaurantTreasury = address(0x2008);
    address public metaDAOTreasury = address(0x2009);
    address public resolversDAO = address(0x200A);
    address public protocolDAO = address(0x200B);
    address public humanResolver = address(0x200C);

    uint256 internal constant FOOD = 80e6;
    uint256 internal constant FEE = 20e6;
    uint256 internal constant TIP = 5e6;
    uint256 internal constant BPS = 10_000;

    function setUp() public {
        admin = vm.addr(ADMIN_PK);
        vm.startPrank(admin);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury, admin);
        router.setGuildTreasury(restaurantDAO, restaurantTreasury);
        router.setGuildTreasury(metaDAO, metaDAOTreasury);
        dr = new DisputeResolver(address(usdc), resolversDAO, protocolDAO, protocolTreasury, resolverTreasury);
        vm.stopPrank();
        script = new DeployDeliveryContracts();
        harness = new WiringHarness();
        usdc.mint(poster, 1_000_000e6);
        usdc.mint(performer, 1_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _cfg(uint256 pk, bool allowUnwired) internal view returns (DeployDeliveryContracts.Config memory) {
        return DeployDeliveryContracts.Config({
            paymentRouter: address(router),
            disputeResolver: address(dr),
            usdc: address(usdc),
            deployDeliveriesDAO: false,
            existingDeliveriesDAO: address(0),
            deployerPrivateKey: pk,
            allowUnwiredRouter: allowUnwired,
            allowRouterRepoint: false
        });
    }

    function _create(DeliveryMissionFactory factory) internal returns (DeliveryEscrow escrow) {
        DeliveryEscrow.DeliveryParams memory p = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(1, 1, keccak256("p"), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(2, 2, keccak256("d"), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(3, 2, 1000, 0),
            pickupWindowStart: block.timestamp + 1 hours,
            pickupWindowEnd: block.timestamp + 3 hours,
            deliveryDeadline: block.timestamp + 8 hours,
            realTimeTrackingEnabled: false,
            tipAmount: TIP
        });
        DeliveryEscrow.DeliverySettlement memory s = DeliveryEscrow.DeliverySettlement({
            foodCost: FOOD,
            deliveryFee: FEE,
            restaurantDAO: restaurantDAO,
            subDAOFeeBps: 200,
            metaDAO: metaDAO,
            metaDAOFeeBps: 50
        });
        DeliveryEscrow.DeliveryWaypoint[] memory w = new DeliveryEscrow.DeliveryWaypoint[](0);
        uint256 reward = FOOD + FEE + TIP;
        vm.startPrank(poster);
        usdc.approve(address(factory), reward);
        uint256 id = factory.createDeliveryMission(
            address(usdc), reward, block.timestamp + 1 days, address(0), keccak256("m"), keccak256("l"), p, s, w
        );
        vm.stopPrank();
        escrow = DeliveryEscrow(payable(factory.missions(id)));
        vm.prank(performer);
        escrow.acceptMission();
    }

    /// @dev Real DisputeResolver flow up to (but not including) finalizeDispute.
    function _resolve(DeliveryEscrow e, IDisputeResolver.DisputeOutcome outcome, uint256 split)
        internal
        returns (uint256 disputeId)
    {
        vm.prank(poster);
        e.raiseDispute(keccak256("x"));
        uint256 ddr = (e.getParams().rewardAmount * 500) / BPS;
        vm.startPrank(poster);
        usdc.approve(address(dr), ddr);
        disputeId = dr.createDispute(address(e), e.getMissionId(), keccak256("ev-p"));
        vm.stopPrank();
        vm.startPrank(performer);
        usdc.approve(address(dr), ddr);
        dr.submitEvidence(disputeId, keccak256("ev-c"));
        vm.stopPrank();
        vm.prank(resolversDAO);
        dr.assignResolver(disputeId, humanResolver);
        vm.prank(humanResolver);
        dr.resolveDispute(disputeId, outcome, keccak256("res"), split);
        vm.warp(block.timestamp + 48 hours + 1);
    }

    /// @dev The pre-fix DeployiTake wiring: SETTLER_ROLE on the FACTORY, router.missionFactory unset.
    function _legacyWiredFactory() internal returns (DeliveryMissionFactory factory) {
        vm.startPrank(admin);
        factory = new DeliveryMissionFactory(address(router));
        factory.setDisputeResolver(address(dr));
        router.grantRole(router.SETTLER_ROLE(), address(factory));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Finding 1: the redeploy script must not silently skip the router wiring
    // -------------------------------------------------------------------------

    function test_DeployScript_RevertsWhenBroadcasterIsNotRouterAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeliveryRouterWiring.BroadcasterNotRouterAdmin.selector, address(router), vm.addr(OTHER_PK)
            )
        );
        script.deploy(_cfg(OTHER_PK, false));
        assertEq(router.missionFactory(), address(0), "router must stay untouched");
    }

    function test_DeployScript_AllowUnwiredOptOut_ReportsNotSettlementReady() public {
        DeployDeliveryContracts.Deployed memory out = script.deploy(_cfg(OTHER_PK, true));
        assertFalse(out.routerWired, "routerWired");
        assertFalse(out.settlementReady, "settlementReady must be false");
        assertEq(router.missionFactory(), address(0), "router must stay unwired");
    }

    function test_DeployScript_WiresRouterToNewFactory() public {
        DeployDeliveryContracts.Deployed memory out = script.deploy(_cfg(ADMIN_PK, false));
        assertTrue(out.routerWired, "routerWired");
        assertTrue(out.settlementReady, "settlementReady");
        assertEq(router.missionFactory(), out.deliveryMissionFactory, "router.missionFactory");
        DeliveryMissionFactory factory = DeliveryMissionFactory(out.deliveryMissionFactory);
        assertEq(factory.owner(), admin, "factory owner");
        assertEq(factory.disputeResolver(), address(dr), "dispute resolver");
        assertEq(factory.paymentRouter(), address(router), "factory router");
    }

    function test_DeployScript_RevertsWhenRouterAlreadyWiredToAnotherFactory() public {
        DeployDeliveryContracts.Deployed memory first = script.deploy(_cfg(ADMIN_PK, false));
        vm.expectRevert(abi.encodeWithSelector(DeployDeliveryContracts.RouterAlreadyWired.selector, first.deliveryMissionFactory));
        script.deploy(_cfg(ADMIN_PK, false));
        assertEq(router.missionFactory(), first.deliveryMissionFactory, "router must stay pointed at the live factory");
    }

    function test_DeployScript_AllowRouterRepoint_OptInRepointsRouter() public {
        DeployDeliveryContracts.Deployed memory first = script.deploy(_cfg(ADMIN_PK, false));
        DeployDeliveryContracts.Config memory cfg = _cfg(ADMIN_PK, false);
        cfg.allowRouterRepoint = true;
        DeployDeliveryContracts.Deployed memory second = script.deploy(cfg);
        assertTrue(second.deliveryMissionFactory != first.deliveryMissionFactory, "new factory");
        assertTrue(second.settlementReady, "settlementReady");
        assertEq(router.missionFactory(), second.deliveryMissionFactory, "router re-pointed");
    }

    // -------------------------------------------------------------------------
    // Finding 2: with the script's wiring, a PerformerWins / Split dispute finalizes
    // -------------------------------------------------------------------------

    function test_ScriptWired_PerformerWinsDisputeFinalizesAndPaysRestaurant() public {
        DeployDeliveryContracts.Deployed memory out = script.deploy(_cfg(ADMIN_PK, false));
        DeliveryEscrow e = _create(DeliveryMissionFactory(out.deliveryMissionFactory));
        uint256 id = _resolve(e, IDisputeResolver.DisputeOutcome.PerformerWins, 0);

        uint256 rBefore = usdc.balanceOf(restaurantTreasury);
        dr.finalizeDispute(id);

        assertEq(usdc.balanceOf(address(e)), 0, "escrow not empty");
        assertEq(usdc.balanceOf(address(router)), 0, "router residue");
        assertEq(usdc.balanceOf(address(dr)), 0, "DDR not distributed");
        assertEq(usdc.balanceOf(restaurantTreasury) - rBefore, FOOD + (FEE * 200) / BPS, "restaurant");
        assertEq(uint8(e.getRuntime().state), uint8(IMissionEscrow.MissionState.Completed));
    }

    function test_ScriptWired_SplitDisputeFinalizes() public {
        DeployDeliveryContracts.Deployed memory out = script.deploy(_cfg(ADMIN_PK, false));
        DeliveryEscrow e = _create(DeliveryMissionFactory(out.deliveryMissionFactory));
        uint256 id = _resolve(e, IDisputeResolver.DisputeOutcome.Split, 5000);
        dr.finalizeDispute(id);
        assertEq(usdc.balanceOf(address(e)), 0, "escrow not empty");
        assertEq(usdc.balanceOf(address(router)), 0, "router residue");
        assertEq(uint8(e.getRuntime().state), uint8(IMissionEscrow.MissionState.Completed));
    }

    /// @dev Documents the live Base Sepolia state the script now refuses to produce: SETTLER_ROLE on
    ///      the factory authorises nobody, PerformerWins can never finalize (DDR frozen), while
    ///      PosterWins (no router call) still works.
    function test_LegacyFactorySettlerRole_PerformerWinsFinalizeRevertsForever_PosterWinsOk() public {
        DeliveryMissionFactory factory = _legacyWiredFactory();
        assertFalse(DeliveryRouterWiring.isSettlementReady(router, address(factory)), "legacy is ready?");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeliveryRouterWiring.RouterNotWiredToDeliveryFactory.selector,
                address(router),
                address(factory),
                address(0)
            )
        );
        harness.assertSettlementReady(router, address(factory));

        DeliveryEscrow stuck = _create(factory);
        uint256 id = _resolve(stuck, IDisputeResolver.DisputeOutcome.PerformerWins, 0);
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        dr.finalizeDispute(id);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        dr.finalizeDispute(id);

        DeliveryEscrow refunded = _create(factory);
        uint256 id2 = _resolve(refunded, IDisputeResolver.DisputeOutcome.PosterWins, 0);
        dr.finalizeDispute(id2);
        assertEq(usdc.balanceOf(address(refunded)), 0, "PosterWins refund");
    }

    /// @dev Wiring the router (what the fixed scripts do) unfreezes the same legacy dispute.
    function test_LegacyFactory_WiringRouterUnfreezesPerformerWins() public {
        DeliveryMissionFactory factory = _legacyWiredFactory();
        DeliveryEscrow e = _create(factory);
        uint256 id = _resolve(e, IDisputeResolver.DisputeOutcome.PerformerWins, 0);
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        dr.finalizeDispute(id);

        vm.prank(admin);
        router.setMissionFactory(address(factory));
        harness.assertSettlementReady(router, address(factory));
        dr.finalizeDispute(id);
        assertEq(usdc.balanceOf(address(e)), 0, "escrow not empty");
    }

    function test_AssertSettlementReady_RevertsOnFactoryRouterMismatch() public {
        vm.startPrank(admin);
        PaymentRouter other =
            new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury, admin);
        DeliveryMissionFactory factory = new DeliveryMissionFactory(address(other));
        router.setMissionFactory(address(factory));
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeliveryRouterWiring.FactoryRouterMismatch.selector, address(factory), address(router), address(other)
            )
        );
        harness.assertSettlementReady(router, address(factory));
    }
}
