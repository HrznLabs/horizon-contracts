// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { DeliveryMissionFactory } from "../src/DeliveryMissionFactory.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { PauseRegistry } from "../src/PauseRegistry.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { RedeployCore } from "../script/RedeployCore.s.sol";
import { DeployDisputeResolver } from "../script/DeployDisputeResolver.s.sol";

/**
 * @notice Tests for the Base Sepolia core redeploy scripts: a fresh, coherently wired
 *         router + factory + pause registry + dispute resolver that can actually settle a mission.
 */
contract RedeployScriptsTest is Test {
    RedeployCore public core;
    DeployDisputeResolver public drScript;
    MockERC20 public usdc;
    MockERC20 public eurc;

    uint256 internal constant ADMIN_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B;
    address internal admin;
    address internal other;

    address public poster = address(0x3001);
    address public performer = address(0x3002);
    address public treasury = address(0x3003);

    // "live" stand-ins
    PaymentRouter public oldRouter;
    MissionFactory public oldFactory;
    DisputeResolver public oldResolver;
    DeliveryMissionFactory public deliveryFactory;
    PaymentRouter public itakeRouter;

    function setUp() public {
        admin = vm.addr(ADMIN_PK);
        other = vm.addr(OTHER_PK);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        eurc = new MockERC20("Euro Coin", "EURC", 6);
        core = new RedeployCore();
        drScript = new DeployDisputeResolver();

        vm.startPrank(admin);
        oldRouter = new PaymentRouter(address(usdc), treasury, treasury, treasury, admin);
        oldRouter.setPerformerFloor(9100);
        oldFactory = new MissionFactory(address(oldRouter));
        oldRouter.setMissionFactory(address(oldFactory));
        oldResolver = new DisputeResolver(address(usdc), treasury, treasury, treasury, treasury);
        oldFactory.setDisputeResolver(address(oldResolver));
        itakeRouter = new PaymentRouter(address(usdc), treasury, treasury, treasury, admin);
        deliveryFactory = new DeliveryMissionFactory(address(itakeRouter));
        deliveryFactory.setDisputeResolver(address(oldResolver));
        itakeRouter.setMissionFactory(address(deliveryFactory));
        vm.stopPrank();

        usdc.mint(poster, 1_000_000e6);
    }

    function _coreCfg(uint256 pk) internal view returns (RedeployCore.Config memory) {
        return RedeployCore.Config({
            usdc: address(usdc),
            eurc: address(eurc),
            admin: address(0),
            protocolTreasury: address(0),
            resolverTreasury: address(0),
            labsTreasury: address(0),
            disputeResolver: address(oldResolver),
            allowNoDisputeResolver: false,
            deployPauseRegistry: true,
            existingPauseRegistry: address(0),
            oldPaymentRouter: address(oldRouter),
            oldMissionFactory: address(oldFactory),
            deployerPrivateKey: pk
        });
    }

    function _drCfg(uint256 pk) internal view returns (DeployDisputeResolver.Config memory) {
        return DeployDisputeResolver.Config({
            usdc: address(usdc),
            admin: address(0),
            resolversDAO: address(0),
            protocolDAO: address(0),
            protocolTreasury: address(0),
            resolverTreasury: address(0),
            missionFactory: address(0),
            deliveryMissionFactory: address(deliveryFactory),
            oldDisputeResolver: address(oldResolver),
            allowUnwiredFactories: false,
            deployerPrivateKey: pk
        });
    }

    // -------------------------------------------------------------------------
    // RedeployCore
    // -------------------------------------------------------------------------

    function test_Core_DeploysFreshWiredSetAndLeavesOldOneUntouched() public {
        RedeployCore.Deployed memory out = core.deploy(_coreCfg(ADMIN_PK));
        PaymentRouter router = PaymentRouter(out.paymentRouter);
        MissionFactory factory = MissionFactory(out.missionFactory);

        assertTrue(out.paymentRouter != address(oldRouter) && out.missionFactory != address(oldFactory));
        assertTrue(out.settlementReady, "settlementReady");
        assertEq(router.missionFactory(), out.missionFactory, "router -> factory");
        assertEq(factory.paymentRouter(), out.paymentRouter, "factory -> router");
        assertEq(factory.disputeResolver(), address(oldResolver), "resolver");
        assertEq(address(factory.pauseRegistry()), out.pauseRegistry, "pause registry");
        assertTrue(out.pauseRegistryIsNew, "registry is new");
        assertEq(factory.escrowImplementation(), out.missionEscrowImpl, "escrow impl");
        assertTrue(router.acceptedTokens(address(usdc)) && router.acceptedTokens(address(eurc)), "tokens");
        assertEq(router.performerFloorBPS(), 9100, "floor carried over");
        assertEq(router.protocolTreasury(), treasury, "treasury carried over");
        assertEq(factory.owner(), admin, "factory owner");
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin), "router admin");
        assertTrue(PauseRegistry(out.pauseRegistry).hasRole(0x00, admin), "registry admin");

        // Old set + iTake/delivery set untouched.
        assertEq(oldRouter.missionFactory(), address(oldFactory), "old router untouched");
        assertEq(itakeRouter.missionFactory(), address(deliveryFactory), "itake router untouched");
        assertEq(address(oldFactory.pauseRegistry()), address(0), "old factory untouched");
        assertFalse(oldRouter.acceptedTokens(address(eurc)), "old router untouched (EURC)");
    }

    function test_Core_NewMissionSettlesAndPaysPerformer() public {
        RedeployCore.Deployed memory out = core.deploy(_coreCfg(ADMIN_PK));
        MissionFactory factory = MissionFactory(out.missionFactory);

        uint256 reward = 1000e6;
        vm.startPrank(poster);
        usdc.approve(address(factory), reward);
        uint256 id = factory.createMission(
            address(usdc), reward, block.timestamp + 1 days, address(0), keccak256("m"), keccak256("l")
        );
        vm.stopPrank();
        address escrow = factory.missions(id);
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();
        vm.prank(performer);
        IMissionEscrow(escrow).submitProof(keccak256("proof"));
        vm.prank(poster);
        IMissionEscrow(escrow).approveCompletion();

        assertEq(usdc.balanceOf(escrow), 0, "escrow drained");
        assertEq(usdc.balanceOf(out.paymentRouter), 0, "router residue");
        assertGe(usdc.balanceOf(performer), (reward * 9000) / 10_000, "performer >= 90%");
    }

    function test_Core_PauseRegistryBlocksNewMissions() public {
        RedeployCore.Deployed memory out = core.deploy(_coreCfg(ADMIN_PK));
        vm.prank(admin);
        PauseRegistry(out.pauseRegistry).pauseGlobal();

        MissionFactory factory = MissionFactory(out.missionFactory);
        vm.startPrank(poster);
        usdc.approve(address(factory), 1000e6);
        vm.expectRevert(MissionFactory.Paused.selector);
        factory.createMission(
            address(usdc), 1000e6, block.timestamp + 1 days, address(0), keccak256("m"), keccak256("l")
        );
        vm.stopPrank();
    }

    function test_Core_DeployPauseRegistryFalseSkipsIt() public {
        RedeployCore.Config memory cfg = _coreCfg(ADMIN_PK);
        cfg.deployPauseRegistry = false;
        RedeployCore.Deployed memory out = core.deploy(cfg);
        assertEq(out.pauseRegistry, address(0));
        assertEq(address(MissionFactory(out.missionFactory).pauseRegistry()), address(0));
    }

    function test_Core_ReusesExistingPauseRegistry() public {
        PauseRegistry existing = new PauseRegistry(admin);
        RedeployCore.Config memory cfg = _coreCfg(ADMIN_PK);
        cfg.existingPauseRegistry = address(existing);
        RedeployCore.Deployed memory out = core.deploy(cfg);
        assertEq(out.pauseRegistry, address(existing));
        assertFalse(out.pauseRegistryIsNew);
        assertEq(address(MissionFactory(out.missionFactory).pauseRegistry()), address(existing));
    }

    function test_Core_RevertsWithoutDisputeResolverUnlessOptedOut() public {
        RedeployCore.Config memory cfg = _coreCfg(ADMIN_PK);
        cfg.disputeResolver = address(0);
        vm.expectRevert(RedeployCore.DisputeResolverRequired.selector);
        core.deploy(cfg);

        cfg.allowNoDisputeResolver = true;
        RedeployCore.Deployed memory out = core.deploy(cfg);
        assertEq(MissionFactory(out.missionFactory).disputeResolver(), address(0));
    }

    function test_Core_RevertsOnDeadDependencies() public {
        RedeployCore.Config memory cfg = _coreCfg(ADMIN_PK);
        cfg.disputeResolver = address(0xdead);
        vm.expectRevert(abi.encodeWithSelector(RedeployCore.NoCodeAtAddress.selector, "DISPUTE_RESOLVER", address(0xdead)));
        core.deploy(cfg);

        cfg = _coreCfg(ADMIN_PK);
        cfg.usdc = address(0xbeef);
        vm.expectRevert(abi.encodeWithSelector(RedeployCore.NoCodeAtAddress.selector, "USDC", address(0xbeef)));
        core.deploy(cfg);
    }

    function test_Core_HandsRolesToAdminWhenDifferentFromBroadcaster() public {
        RedeployCore.Config memory cfg = _coreCfg(OTHER_PK);
        cfg.admin = admin;
        RedeployCore.Deployed memory out = core.deploy(cfg);
        PaymentRouter router = PaymentRouter(out.paymentRouter);
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(router.hasRole(router.PAUSER_ROLE(), admin));
        assertTrue(router.hasRole(router.FEE_MANAGER_ROLE(), admin));
        assertFalse(router.hasRole(router.DEFAULT_ADMIN_ROLE(), other));
        assertEq(MissionFactory(out.missionFactory).owner(), admin);
        assertEq(router.missionFactory(), out.missionFactory);
    }

    // -------------------------------------------------------------------------
    // DeployDisputeResolver
    // -------------------------------------------------------------------------

    function test_Resolver_RepointsBothFactories() public {
        DeployDisputeResolver.Config memory cfg = _drCfg(ADMIN_PK);
        cfg.missionFactory = address(oldFactory);
        DeployDisputeResolver.Deployed memory out = drScript.deploy(cfg);
        assertTrue(out.missionFactoryWired && out.deliveryFactoryWired);
        assertTrue(out.disputeResolver != address(oldResolver));
        assertEq(oldFactory.disputeResolver(), out.disputeResolver);
        assertEq(deliveryFactory.disputeResolver(), out.disputeResolver);
        DisputeResolver r = DisputeResolver(out.disputeResolver);
        assertEq(r.owner(), admin);
        assertEq(r.protocolTreasury(), treasury, "carried over from old resolver");
        assertEq(address(r.usdc()), address(usdc));
    }

    function test_Resolver_RevertsWhenBroadcasterNotFactoryOwner() public {
        DeployDisputeResolver.Config memory cfg = _drCfg(OTHER_PK);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployDisputeResolver.BroadcasterNotOwner.selector,
                "DELIVERY_MISSION_FACTORY",
                address(deliveryFactory),
                admin,
                other
            )
        );
        drScript.deploy(cfg);
    }

    function test_Resolver_AllowUnwiredPrintsInsteadOfReverting() public {
        DeployDisputeResolver.Config memory cfg = _drCfg(OTHER_PK);
        cfg.allowUnwiredFactories = true;
        DeployDisputeResolver.Deployed memory out = drScript.deploy(cfg);
        assertFalse(out.deliveryFactoryWired);
        assertEq(deliveryFactory.disputeResolver(), address(oldResolver), "untouched");
    }

    function test_Chain_ResolverThenCore_NewFactoryUsesNewResolver() public {
        DeployDisputeResolver.Deployed memory r = drScript.deploy(_drCfg(ADMIN_PK));
        RedeployCore.Config memory cfg = _coreCfg(ADMIN_PK);
        cfg.disputeResolver = r.disputeResolver;
        RedeployCore.Deployed memory out = core.deploy(cfg);
        assertEq(MissionFactory(out.missionFactory).disputeResolver(), r.disputeResolver);
        assertEq(deliveryFactory.disputeResolver(), r.disputeResolver);
    }
}
