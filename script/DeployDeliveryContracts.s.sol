// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { DeliveryMissionFactory } from "../src/DeliveryMissionFactory.sol";
import { DeliveriesDAO } from "../src/DeliveriesDAO.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { DeliveryRouterWiring } from "./lib/DeliveryRouterWiring.sol";

/**
 * @title DeployDeliveryContracts
 * @notice (Re)deploys the delivery vertical: a fresh DeliveryMissionFactory (which deploys the
 *         DeliveryEscrow implementation in its constructor), its DisputeResolver, and the
 *         PaymentRouter wiring that lets the new escrow clones settle.
 *
 * Router wiring is MANDATORY (#950 review). DeliveryEscrow clones call
 * PaymentRouter.settleRestaurantOrder from approveCompletion and from settleDispute
 * (PerformerWins / Split). The router only accepts them when
 * `router.missionFactory() == newFactory` (see script/lib/DeliveryRouterWiring.sol). Without it
 * every delivery settlement reverts OnlyMissionEscrow and disputes cannot be finalized, so the
 * script refuses to run unless the broadcaster holds DEFAULT_ADMIN_ROLE on the router. The only
 * escape hatch is ALLOW_UNWIRED_ROUTER=true (admin key held elsewhere, e.g. a multisig); the
 * script then reports `settlementReady: false` and prints the exact call the admin must make.
 *
 * Environment:
 *   PAYMENT_ROUTER        (required) live PaymentRouter (must be the delivery-dedicated router;
 *                         its single missionFactory slot is pointed at the new factory).
 *   DISPUTE_RESOLVER      (required) live DisputeResolver.
 *   USDC                  (optional) defaults to Base Sepolia USDC. Must be accepted on the router.
 *   DEPLOYER_PRIVATE_KEY  (optional) when unset the script broadcasts with `--sender`/`--account`.
 *   DEPLOY_DELIVERIES_DAO (optional, default false) also deploy a new DeliveriesDAO.
 *   DELIVERIES_DAO        (optional) existing DeliveriesDAO echoed in the summary.
 *   ALLOW_UNWIRED_ROUTER  (optional, default false) see above. Leaves delivery settlement BROKEN
 *                         until the router admin calls setMissionFactory.
 *   ALLOW_ROUTER_REPOINT  (optional, default false) the router has ONE missionFactory slot. If it
 *                         already points at a factory, the script reverts RouterAlreadyWired
 *                         (re-pointing orphans every escrow of the current factory: they can no
 *                         longer settle). Set true only when that is intended.
 *
 * Dry run (no broadcast):
 *   PAYMENT_ROUTER=0x... DISPUTE_RESOLVER=0x... \
 *   forge script script/DeployDeliveryContracts.s.sol --rpc-url https://sepolia.base.org \
 *     --sender <router admin> -vvvv
 */
contract DeployDeliveryContracts is Script {
    /// @dev Base Sepolia USDC - only a default, override with USDC=0x...
    address internal constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    error NoCodeAtAddress(string name, address addr);
    error TokenNotAccepted(address router, address token);
    /// @notice router.missionFactory() already points at a (different) factory; see ALLOW_ROUTER_REPOINT.
    error RouterAlreadyWired(address current);

    struct Config {
        address paymentRouter;
        address disputeResolver;
        address usdc;
        bool deployDeliveriesDAO;
        address existingDeliveriesDAO;
        uint256 deployerPrivateKey;
        bool allowUnwiredRouter;
        bool allowRouterRepoint;
    }

    struct Deployed {
        address deliveryMissionFactory;
        address deliveryEscrowImpl;
        address deliveriesDAO;
        bool deliveriesDAOIsNew;
        bool routerWired;
        bool settlementReady;
    }

    function run() external returns (Deployed memory) {
        Config memory cfg = Config({
            paymentRouter: vm.envAddress("PAYMENT_ROUTER"),
            disputeResolver: vm.envAddress("DISPUTE_RESOLVER"),
            usdc: vm.envOr("USDC", USDC_BASE_SEPOLIA),
            deployDeliveriesDAO: vm.envOr("DEPLOY_DELIVERIES_DAO", false),
            existingDeliveriesDAO: vm.envOr("DELIVERIES_DAO", address(0)),
            deployerPrivateKey: vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0)),
            allowUnwiredRouter: vm.envOr("ALLOW_UNWIRED_ROUTER", false),
            allowRouterRepoint: vm.envOr("ALLOW_ROUTER_REPOINT", false)
        });
        Deployed memory out = deploy(cfg);
        if (
            !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                && !vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            console.log("");
            console.log("SIMULATION COMPLETE - no transactions were broadcast (add --broadcast)");
        }
        return out;
    }

    /// @notice Env-free entry point (used by run() and by test/DeliveryRouterWiring.t.sol).
    function deploy(Config memory cfg) public returns (Deployed memory out) {
        address broadcaster =
            cfg.deployerPrivateKey != 0 ? vm.addr(cfg.deployerPrivateKey) : msg.sender;

        console.log("===========================================");
        console.log("  Delivery vertical (re)deployment");
        console.log("===========================================");
        console.log("Chain id:         ", block.chainid);
        console.log("Broadcaster:      ", broadcaster);
        console.log("PaymentRouter:    ", cfg.paymentRouter);
        console.log("DisputeResolver:  ", cfg.disputeResolver);
        console.log("USDC:             ", cfg.usdc);

        // ------------------------------------------------------------------
        // 1. Pre-flight - fail before spending gas
        // ------------------------------------------------------------------
        if (cfg.paymentRouter.code.length == 0) {
            revert NoCodeAtAddress("PAYMENT_ROUTER", cfg.paymentRouter);
        }
        if (cfg.disputeResolver.code.length == 0) {
            revert NoCodeAtAddress("DISPUTE_RESOLVER", cfg.disputeResolver);
        }
        if (cfg.usdc.code.length == 0) revert NoCodeAtAddress("USDC", cfg.usdc);

        PaymentRouter router = PaymentRouter(cfg.paymentRouter);
        if (!router.acceptedTokens(cfg.usdc)) revert TokenNotAccepted(cfg.paymentRouter, cfg.usdc);

        address previousFactory = router.missionFactory();
        bool isRouterAdmin = router.hasRole(router.DEFAULT_ADMIN_ROLE(), broadcaster);
        console.log("router.missionFactory() (current):", previousFactory);
        console.log("broadcaster is router admin:      ", isRouterAdmin);

        // Fail closed: an unwired factory deploys fine but can never settle (#950 review).
        if (!isRouterAdmin && !cfg.allowUnwiredRouter) {
            revert DeliveryRouterWiring.BroadcasterNotRouterAdmin(cfg.paymentRouter, broadcaster);
        }

        // The router has a single missionFactory slot. Re-pointing it away from a live factory
        // orphans that factory's escrows (they can no longer settle), so it must be explicit.
        // The new factory does not exist yet, so any non-zero current value is a different one.
        if (isRouterAdmin && previousFactory != address(0)) {
            if (!cfg.allowRouterRepoint) revert RouterAlreadyWired(previousFactory);
            console.log("WARNING: ALLOW_ROUTER_REPOINT=true - re-pointing router.missionFactory away from");
            console.log("         the current factory; its existing escrows can no longer settle:", previousFactory);
        }

        // ------------------------------------------------------------------
        // 2. Broadcast
        // ------------------------------------------------------------------
        if (cfg.deployerPrivateKey != 0) {
            vm.startBroadcast(cfg.deployerPrivateKey);
        } else {
            vm.startBroadcast();
        }

        DeliveryMissionFactory factory = new DeliveryMissionFactory(cfg.paymentRouter);
        out.deliveryMissionFactory = address(factory);
        out.deliveryEscrowImpl = factory.deliveryEscrowImplementation();
        console.log("1. DeliveryMissionFactory:", out.deliveryMissionFactory);
        console.log("   DeliveryEscrow impl:   ", out.deliveryEscrowImpl);

        factory.setDisputeResolver(cfg.disputeResolver);
        console.log("2. factory.setDisputeResolver done");

        if (isRouterAdmin) {
            router.setMissionFactory(address(factory));
            out.routerWired = true;
            console.log("3. router.setMissionFactory(newFactory) done");
        } else {
            console.log("3. NOT WIRED (ALLOW_UNWIRED_ROUTER=true) - delivery settlement is BROKEN");
        }

        if (cfg.deployDeliveriesDAO) {
            DeliveriesDAO dao = new DeliveriesDAO(cfg.usdc);
            // Audit M4 residual: policies can only be sold for this factory's missions.
            dao.setDeliveryFactory(address(factory));
            out.deliveriesDAO = address(dao);
            out.deliveriesDAOIsNew = true;
            console.log("4. DeliveriesDAO:", out.deliveriesDAO, "(deliveryFactory wired)");
        } else {
            out.deliveriesDAO = cfg.existingDeliveriesDAO;
        }

        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // 3. Post-checks
        // ------------------------------------------------------------------
        require(factory.owner() == broadcaster, "factory owner != broadcaster");
        require(factory.disputeResolver() == cfg.disputeResolver, "disputeResolver not set");
        if (out.routerWired) {
            DeliveryRouterWiring.assertSettlementReady(router, address(factory));
        }
        out.settlementReady = DeliveryRouterWiring.isSettlementReady(router, address(factory));

        // ------------------------------------------------------------------
        // 4. Summary
        // ------------------------------------------------------------------
        console.log("");
        console.log("=== DEPLOYMENT JSON ===");
        console.log("{");
        console.log('  "chainId": %s,', vm.toString(block.chainid));
        console.log('  "PaymentRouter": "%s",', vm.toString(cfg.paymentRouter));
        console.log('  "DisputeResolver": "%s",', vm.toString(cfg.disputeResolver));
        console.log('  "USDC": "%s",', vm.toString(cfg.usdc));
        console.log('  "DeliveryMissionFactory": "%s",', vm.toString(out.deliveryMissionFactory));
        console.log('  "DeliveryEscrowImpl": "%s",', vm.toString(out.deliveryEscrowImpl));
        console.log('  "DeliveriesDAO": "%s",', vm.toString(out.deliveriesDAO));
        console.log('  "settlementReady": %s,', out.settlementReady ? "true" : "false");
        console.log('  "previousRouterMissionFactory": "%s"', vm.toString(previousFactory));
        console.log("}");
        console.log("=== END DEPLOYMENT JSON ===");

        if (!out.settlementReady) {
            console.log("");
            console.log("ACTION REQUIRED - delivery settlement reverts until the router admin runs:");
            console.log(
                string.concat(
                    "  cast send ",
                    vm.toString(cfg.paymentRouter),
                    " 'setMissionFactory(address)' ",
                    vm.toString(address(factory)),
                    " --rpc-url $BASE_SEPOLIA_RPC_URL --account <router admin>"
                )
            );
        }
        if (previousFactory != address(0) && previousFactory != address(factory)) {
            console.log("NOTE: escrows of the previous factory can no longer settle:", previousFactory);
        }
    }
}
