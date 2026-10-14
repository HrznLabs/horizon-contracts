// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { PauseRegistry } from "../src/PauseRegistry.sol";

/**
 * @title RedeployCore
 * @notice Deploys a FRESH, coherently wired core set on Base Sepolia:
 *           PaymentRouter  (USDC + EURC accepted, treasuries/floor carried over from the old router)
 *           MissionFactory (its constructor deploys the MissionEscrow implementation)
 *           PauseRegistry  (optional, DEPLOY_PAUSE_REGISTRY, default true)
 *         and every wiring call the set needs:
 *           router.setMissionFactory(factory)
 *           factory.setDisputeResolver(DISPUTE_RESOLVER)
 *           factory.setPauseRegistry(registry)
 *
 * The old core router/factory (0x3013... / 0x6d97...) are left ORPHANED and untouched: this script
 * never calls a setter on them (it only reads them to carry config over). Nothing in the script
 * touches the iTake PaymentRouter or the DeliveryMissionFactory either.
 *
 * Why the router wiring is mandatory: MissionEscrow clones call PaymentRouter.settlePayment* from
 * the escrow itself. The router's onlyAuthorizedSettler accepts a clone only when
 * `router.missionFactory().getMissionByEscrow(clone) > 0`, so a factory the router does not point at
 * can create missions that can NEVER pay out. A brand new router starts with missionFactory == 0, so
 * the script wires it in the same broadcast and asserts it afterwards. Re-pointing an EXISTING router
 * is deliberately not supported (it has ONE factory slot; doing so orphans every escrow of the old
 * factory) - RouterAlreadyWired reverts if the fresh router is not unwired.
 *
 * Run order (see script/README.md section "Core + DisputeResolver + PauseRegistry"):
 *   1. DeployDisputeResolver.s.sol   -> new DisputeResolver (also re-points DeliveryMissionFactory)
 *   2. RedeployCore.s.sol            -> DISPUTE_RESOLVER=<address from step 1>
 *
 * Environment:
 *   DISPUTE_RESOLVER      (required) resolver the new factory hands to new escrows. Fail-closed: the
 *                         script reverts DisputeResolverRequired unless ALLOW_NO_DISPUTE_RESOLVER=true
 *                         (then disputes on new missions revert until factory.setDisputeResolver).
 *   USDC, EURC            (optional) default Base Sepolia. Both are whitelisted on the NEW router.
 *                         EURC=0x0 skips EURC.
 *   ADMIN                 (optional) final DEFAULT_ADMIN/PAUSER/FEE_MANAGER of the router, owner of the
 *                         factory, admin of the PauseRegistry. Default: broadcaster. When different from
 *                         the broadcaster the script hands every role/ownership over at the end.
 *   PROTOCOL_TREASURY, RESOLVER_TREASURY, LABS_TREASURY
 *                         (optional) default: the OLD_PAYMENT_ROUTER value when given, else ADMIN.
 *   OLD_PAYMENT_ROUTER, OLD_MISSION_FACTORY
 *                         (optional) previous core router/factory. Read-only: treasuries, performer
 *                         floor and reputationOracle are carried over; echoed in the summary.
 *   DEPLOY_PAUSE_REGISTRY (optional, default true) deploy a PauseRegistry and wire it into the factory.
 *   PAUSE_REGISTRY        (optional) existing registry to wire instead of deploying a new one.
 *   ALLOW_NO_DISPUTE_RESOLVER (optional, default false) see DISPUTE_RESOLVER.
 *   DEPLOYER_PRIVATE_KEY  (optional) when unset the script broadcasts with `--sender`/`--account`.
 *
 * Dry run (no broadcast):
 *   DISPUTE_RESOLVER=0x... OLD_PAYMENT_ROUTER=0x... OLD_MISSION_FACTORY=0x... \
 *   forge script script/RedeployCore.s.sol --rpc-url https://sepolia.base.org --sender <admin> -vvvv
 */
contract RedeployCore is Script {
    /// @dev Base Sepolia USDC / EURC - only defaults, override with USDC=0x... / EURC=0x...
    address internal constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant EURC_BASE_SEPOLIA = 0x808456652fdb597867f38412077A9182bf77359F;

    error NoCodeAtAddress(string name, address addr);
    error DisputeResolverRequired();
    /// @notice A freshly deployed router must start unwired; anything else means the wrong contract.
    error RouterAlreadyWired(address current);

    struct Config {
        address usdc;
        address eurc;
        address admin;
        address protocolTreasury;
        address resolverTreasury;
        address labsTreasury;
        address disputeResolver;
        bool allowNoDisputeResolver;
        bool deployPauseRegistry;
        address existingPauseRegistry;
        address oldPaymentRouter;
        address oldMissionFactory;
        uint256 deployerPrivateKey;
    }

    struct Deployed {
        address paymentRouter;
        address missionFactory;
        address missionEscrowImpl;
        address pauseRegistry;
        address disputeResolver;
        bool pauseRegistryIsNew;
        bool settlementReady;
    }

    function run() external returns (Deployed memory) {
        Config memory cfg = Config({
            usdc: vm.envOr("USDC", USDC_BASE_SEPOLIA),
            eurc: vm.envOr("EURC", EURC_BASE_SEPOLIA),
            admin: vm.envOr("ADMIN", address(0)),
            protocolTreasury: vm.envOr("PROTOCOL_TREASURY", address(0)),
            resolverTreasury: vm.envOr("RESOLVER_TREASURY", address(0)),
            labsTreasury: vm.envOr("LABS_TREASURY", address(0)),
            disputeResolver: vm.envOr("DISPUTE_RESOLVER", address(0)),
            allowNoDisputeResolver: vm.envOr("ALLOW_NO_DISPUTE_RESOLVER", false),
            deployPauseRegistry: vm.envOr("DEPLOY_PAUSE_REGISTRY", true),
            existingPauseRegistry: vm.envOr("PAUSE_REGISTRY", address(0)),
            oldPaymentRouter: vm.envOr("OLD_PAYMENT_ROUTER", address(0)),
            oldMissionFactory: vm.envOr("OLD_MISSION_FACTORY", address(0)),
            deployerPrivateKey: vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0))
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

    /// @notice Env-free entry point (used by run() and by test/RedeployScripts.t.sol).
    function deploy(Config memory cfg) public returns (Deployed memory out) {
        address broadcaster =
            cfg.deployerPrivateKey != 0 ? vm.addr(cfg.deployerPrivateKey) : msg.sender;
        if (cfg.admin == address(0)) cfg.admin = broadcaster;

        // ------------------------------------------------------------------
        // 1. Pre-flight - fail before spending gas
        // ------------------------------------------------------------------
        if (cfg.usdc.code.length == 0) revert NoCodeAtAddress("USDC", cfg.usdc);
        if (cfg.eurc != address(0) && cfg.eurc.code.length == 0) {
            revert NoCodeAtAddress("EURC", cfg.eurc);
        }
        if (cfg.disputeResolver == address(0)) {
            if (!cfg.allowNoDisputeResolver) revert DisputeResolverRequired();
        } else if (cfg.disputeResolver.code.length == 0) {
            revert NoCodeAtAddress("DISPUTE_RESOLVER", cfg.disputeResolver);
        }
        if (cfg.existingPauseRegistry != address(0) && cfg.existingPauseRegistry.code.length == 0) {
            revert NoCodeAtAddress("PAUSE_REGISTRY", cfg.existingPauseRegistry);
        }

        // Carry config over from the previous core set (read-only).
        uint16 floorBps = 0;
        if (cfg.oldPaymentRouter != address(0)) {
            if (cfg.oldPaymentRouter.code.length == 0) {
                revert NoCodeAtAddress("OLD_PAYMENT_ROUTER", cfg.oldPaymentRouter);
            }
            PaymentRouter old = PaymentRouter(cfg.oldPaymentRouter);
            if (cfg.protocolTreasury == address(0)) cfg.protocolTreasury = old.protocolTreasury();
            if (cfg.resolverTreasury == address(0)) cfg.resolverTreasury = old.resolverTreasury();
            if (cfg.labsTreasury == address(0)) cfg.labsTreasury = old.labsTreasury();
            floorBps = old.performerFloorBPS();
        }
        address reputationOracle = address(0);
        if (cfg.oldMissionFactory != address(0)) {
            if (cfg.oldMissionFactory.code.length == 0) {
                revert NoCodeAtAddress("OLD_MISSION_FACTORY", cfg.oldMissionFactory);
            }
            reputationOracle = MissionFactory(cfg.oldMissionFactory).reputationOracle();
            if (
                cfg.disputeResolver != address(0)
                    && MissionFactory(cfg.oldMissionFactory).disputeResolver() == cfg.disputeResolver
            ) {
                console.log("WARNING: DISPUTE_RESOLVER is the resolver the OLD factory already uses.");
                console.log("         Fine for a dry run; for the real run deploy a new one first");
                console.log("         (script/DeployDisputeResolver.s.sol) so audit H2/H3/H4 (#818) apply.");
            }
        }
        if (cfg.protocolTreasury == address(0)) cfg.protocolTreasury = cfg.admin;
        if (cfg.resolverTreasury == address(0)) cfg.resolverTreasury = cfg.admin;
        if (cfg.labsTreasury == address(0)) cfg.labsTreasury = cfg.admin;

        console.log("===========================================");
        console.log("  Core redeploy (router + factory + pause registry)");
        console.log("===========================================");
        console.log("Chain id:           ", block.chainid);
        console.log("Broadcaster:        ", broadcaster);
        console.log("Admin / owner:      ", cfg.admin);
        console.log("USDC:               ", cfg.usdc);
        console.log("EURC:               ", cfg.eurc);
        console.log("DisputeResolver:    ", cfg.disputeResolver);
        console.log("Protocol treasury:  ", cfg.protocolTreasury);
        console.log("Resolver treasury:  ", cfg.resolverTreasury);
        console.log("Labs treasury:      ", cfg.labsTreasury);
        console.log("Old PaymentRouter:  ", cfg.oldPaymentRouter);
        console.log("Old MissionFactory: ", cfg.oldMissionFactory);
        console.log("Carried floor bps:  ", uint256(floorBps));
        console.log("Carried rep oracle: ", reputationOracle);

        // ------------------------------------------------------------------
        // 2. Broadcast
        // ------------------------------------------------------------------
        if (cfg.deployerPrivateKey != 0) {
            vm.startBroadcast(cfg.deployerPrivateKey);
        } else {
            vm.startBroadcast();
        }

        // The broadcaster is the router admin during setup so it can wire; roles move to ADMIN at the end.
        PaymentRouter router = new PaymentRouter(
            cfg.usdc, cfg.protocolTreasury, cfg.resolverTreasury, cfg.labsTreasury, broadcaster
        );
        out.paymentRouter = address(router);
        console.log("1. PaymentRouter:", out.paymentRouter);

        if (cfg.eurc != address(0)) {
            router.setAcceptedToken(cfg.eurc, true);
            console.log("2. router.setAcceptedToken(EURC) done");
        }
        if (floorBps != 0 && floorBps != router.performerFloorBPS()) {
            router.setPerformerFloor(floorBps);
            console.log("   router.setPerformerFloor (carried over) done");
        }

        MissionFactory factory = new MissionFactory(address(router));
        out.missionFactory = address(factory);
        out.missionEscrowImpl = factory.escrowImplementation();
        console.log("3. MissionFactory:     ", out.missionFactory);
        console.log("   MissionEscrow impl: ", out.missionEscrowImpl);

        address current = router.missionFactory();
        if (current != address(0)) revert RouterAlreadyWired(current);
        router.setMissionFactory(address(factory));
        console.log("4. router.setMissionFactory(newFactory) done");

        if (cfg.disputeResolver != address(0)) {
            factory.setDisputeResolver(cfg.disputeResolver);
            out.disputeResolver = cfg.disputeResolver;
            console.log("5. factory.setDisputeResolver done");
        } else {
            console.log("5. SKIPPED (ALLOW_NO_DISPUTE_RESOLVER=true) - disputes revert until it is set");
        }

        if (reputationOracle != address(0)) {
            factory.setReputationOracle(reputationOracle);
            console.log("   factory.setReputationOracle (carried over) done");
        }

        if (cfg.existingPauseRegistry != address(0)) {
            out.pauseRegistry = cfg.existingPauseRegistry;
        } else if (cfg.deployPauseRegistry) {
            out.pauseRegistry = address(new PauseRegistry(cfg.admin));
            out.pauseRegistryIsNew = true;
            console.log("6. PauseRegistry:", out.pauseRegistry);
        }
        if (out.pauseRegistry != address(0)) {
            factory.setPauseRegistry(out.pauseRegistry);
            console.log("   factory.setPauseRegistry done");
        }

        // Hand over: grant first, renounce last, so the router never has zero admins.
        if (cfg.admin != broadcaster) {
            router.grantRole(router.PAUSER_ROLE(), cfg.admin);
            router.grantRole(router.FEE_MANAGER_ROLE(), cfg.admin);
            router.grantRole(router.DEFAULT_ADMIN_ROLE(), cfg.admin);
            router.renounceRole(router.PAUSER_ROLE(), broadcaster);
            router.renounceRole(router.FEE_MANAGER_ROLE(), broadcaster);
            router.renounceRole(router.DEFAULT_ADMIN_ROLE(), broadcaster);
            factory.transferOwnership(cfg.admin);
            console.log("7. router roles + factory ownership handed to", cfg.admin);
        }

        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // 3. Post-checks
        // ------------------------------------------------------------------
        require(router.missionFactory() == address(factory), "router not wired to factory");
        require(factory.paymentRouter() == address(router), "factory router mismatch");
        require(out.missionEscrowImpl.code.length > 0, "escrow impl has no code");
        require(router.acceptedTokens(cfg.usdc), "USDC not accepted");
        if (cfg.eurc != address(0)) require(router.acceptedTokens(cfg.eurc), "EURC not accepted");
        require(router.hasRole(router.DEFAULT_ADMIN_ROLE(), cfg.admin), "router admin != ADMIN");
        require(router.hasRole(router.PAUSER_ROLE(), cfg.admin), "router pauser != ADMIN");
        require(router.hasRole(router.FEE_MANAGER_ROLE(), cfg.admin), "router fee manager != ADMIN");
        if (cfg.admin != broadcaster) {
            require(!router.hasRole(router.DEFAULT_ADMIN_ROLE(), broadcaster), "broadcaster kept admin");
        }
        require(factory.owner() == cfg.admin, "factory owner != ADMIN");
        require(router.protocolTreasury() == cfg.protocolTreasury, "protocol treasury mismatch");
        require(router.resolverTreasury() == cfg.resolverTreasury, "resolver treasury mismatch");
        require(router.labsTreasury() == cfg.labsTreasury, "labs treasury mismatch");
        if (out.disputeResolver != address(0)) {
            require(factory.disputeResolver() == out.disputeResolver, "resolver not set");
        }
        if (out.pauseRegistry != address(0)) {
            require(address(factory.pauseRegistry()) == out.pauseRegistry, "pause registry not set");
        }
        // The router resolves escrow clones through factory.getMissionByEscrow; prove the hook is live.
        require(factory.getMissionByEscrow(address(0)) == 0, "getMissionByEscrow broken");
        out.settlementReady = router.missionFactory() == address(factory);

        // ------------------------------------------------------------------
        // 4. Summary
        // ------------------------------------------------------------------
        console.log("");
        console.log("=== DEPLOYMENT JSON ===");
        console.log("{");
        console.log('  "chainId": %s,', vm.toString(block.chainid));
        console.log('  "PaymentRouter": "%s",', vm.toString(out.paymentRouter));
        console.log('  "MissionFactory": "%s",', vm.toString(out.missionFactory));
        console.log('  "MissionEscrowImpl": "%s",', vm.toString(out.missionEscrowImpl));
        console.log('  "DisputeResolver": "%s",', vm.toString(out.disputeResolver));
        console.log('  "PauseRegistry": "%s",', vm.toString(out.pauseRegistry));
        console.log('  "USDC": "%s",', vm.toString(cfg.usdc));
        console.log('  "EURC": "%s",', vm.toString(cfg.eurc));
        console.log('  "admin": "%s",', vm.toString(cfg.admin));
        console.log('  "settlementReady": %s,', out.settlementReady ? "true" : "false");
        console.log('  "previousPaymentRouter": "%s",', vm.toString(cfg.oldPaymentRouter));
        console.log('  "previousMissionFactory": "%s"', vm.toString(cfg.oldMissionFactory));
        console.log("}");
        console.log("=== END DEPLOYMENT JSON ===");

        console.log("");
        console.log("NOTES:");
        console.log("- The previous core router/factory are orphaned (not modified); missions created");
        console.log("  there keep settling through them. Existing escrows keep their old resolver.");
        console.log("- PauseRegistry is wired into the NEW MissionFactory only. PaymentRouter has its");
        console.log("  own Pausable; the iTake router and DeliveryMissionFactory have no registry setter");
        console.log("  (the delivery factory passes address(0) to its escrows), so they cannot be wired.");
        console.log("- guildTreasuries are NOT carried over (none are set on the old core router).");
        if (out.disputeResolver == address(0)) {
            console.log("ACTION REQUIRED - set the resolver before the first mission:");
            console.log(
                string.concat(
                    "  cast send ",
                    vm.toString(out.missionFactory),
                    " 'setDisputeResolver(address)' <resolver> --rpc-url $BASE_SEPOLIA_RPC_URL --account <admin>"
                )
            );
        }
        console.log("Explorer:");
        console.log("  https://sepolia.basescan.org/address/%s", out.paymentRouter);
        console.log("  https://sepolia.basescan.org/address/%s", out.missionFactory);
        console.log("  https://sepolia.basescan.org/address/%s", out.missionEscrowImpl);
        if (out.pauseRegistry != address(0)) {
            console.log("  https://sepolia.basescan.org/address/%s", out.pauseRegistry);
        }
    }
}
