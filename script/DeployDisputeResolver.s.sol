// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { DeliveryMissionFactory } from "../src/DeliveryMissionFactory.sol";

/**
 * @title DeployDisputeResolver
 * @notice Deploys a fresh DisputeResolver and re-points the factories that hand it to new
 *         escrows (MissionFactory.setDisputeResolver / DeliveryMissionFactory.setDisputeResolver).
 *         Use it when only the resolver changed (e.g. audit H2/H3/H4, #818) and the factories
 *         are otherwise current.
 *
 * What it does NOT do: escrows created before the switch keep the resolver address they were
 * initialised with (MissionEscrow stores `_disputeResolver` at init and `onlyDisputeResolver`
 * compares against it), so disputes on EXISTING escrows keep going to the OLD resolver. Only
 * escrows created after the re-point use the new one. A DisputeResolver keeps no factory /
 * escrow allow-list, so nothing has to be registered on the resolver side.
 *
 * Environment:
 *   USDC                    (optional) default Base Sepolia USDC.
 *   ADMIN                   (optional) final owner, default broadcaster.
 *   RESOLVERS_DAO, PROTOCOL_DAO, PROTOCOL_TREASURY, RESOLVER_TREASURY   (optional) default: the
 *                           OLD_DISPUTE_RESOLVER value when given, else ADMIN.
 *   MISSION_FACTORY         (optional) core factory to re-point (broadcaster must be its owner).
 *   DELIVERY_MISSION_FACTORY(optional) delivery factory to re-point (broadcaster must be its owner).
 *   OLD_DISPUTE_RESOLVER    (optional) previous resolver; read-only, its DAO/treasury config is carried
 *                           over and it is echoed in the summary.
 *   ALLOW_UNWIRED_FACTORIES (optional, default false) do not revert when the broadcaster cannot
 *                           re-point a factory; print the call the owner must make instead.
 *   DEPLOYER_PRIVATE_KEY    (optional) when unset the script broadcasts with `--sender`.
 *
 * Dry run:
 *   MISSION_FACTORY=0x... DELIVERY_MISSION_FACTORY=0x... \
 *   forge script script/DeployDisputeResolver.s.sol --rpc-url https://sepolia.base.org --sender <owner> -vvvv
 */
contract DeployDisputeResolver is Script {
    address internal constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    error NoCodeAtAddress(string name, address addr);
    error BroadcasterNotOwner(string name, address addr, address owner, address broadcaster);

    struct Config {
        address usdc;
        address admin;
        address resolversDAO;
        address protocolDAO;
        address protocolTreasury;
        address resolverTreasury;
        address missionFactory;
        address deliveryMissionFactory;
        address oldDisputeResolver;
        bool allowUnwiredFactories;
        uint256 deployerPrivateKey;
    }

    struct Deployed {
        address disputeResolver;
        bool missionFactoryWired;
        bool deliveryFactoryWired;
    }

    function run() external returns (Deployed memory) {
        Config memory cfg = Config({
            usdc: vm.envOr("USDC", USDC_BASE_SEPOLIA),
            admin: vm.envOr("ADMIN", address(0)),
            resolversDAO: vm.envOr("RESOLVERS_DAO", address(0)),
            protocolDAO: vm.envOr("PROTOCOL_DAO", address(0)),
            protocolTreasury: vm.envOr("PROTOCOL_TREASURY", address(0)),
            resolverTreasury: vm.envOr("RESOLVER_TREASURY", address(0)),
            missionFactory: vm.envOr("MISSION_FACTORY", address(0)),
            deliveryMissionFactory: vm.envOr("DELIVERY_MISSION_FACTORY", address(0)),
            oldDisputeResolver: vm.envOr("OLD_DISPUTE_RESOLVER", address(0)),
            allowUnwiredFactories: vm.envOr("ALLOW_UNWIRED_FACTORIES", false),
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
        if (cfg.oldDisputeResolver != address(0)) {
            if (cfg.oldDisputeResolver.code.length == 0) {
                revert NoCodeAtAddress("OLD_DISPUTE_RESOLVER", cfg.oldDisputeResolver);
            }
            DisputeResolver old = DisputeResolver(cfg.oldDisputeResolver);
            if (cfg.resolversDAO == address(0)) cfg.resolversDAO = old.resolversDAO();
            if (cfg.protocolDAO == address(0)) cfg.protocolDAO = old.protocolDAO();
            if (cfg.protocolTreasury == address(0)) cfg.protocolTreasury = old.protocolTreasury();
            if (cfg.resolverTreasury == address(0)) cfg.resolverTreasury = old.resolverTreasury();
        }
        if (cfg.resolversDAO == address(0)) cfg.resolversDAO = cfg.admin;
        if (cfg.protocolDAO == address(0)) cfg.protocolDAO = cfg.admin;
        if (cfg.protocolTreasury == address(0)) cfg.protocolTreasury = cfg.admin;
        if (cfg.resolverTreasury == address(0)) cfg.resolverTreasury = cfg.admin;

        console.log("===========================================");
        console.log("  DisputeResolver (re)deployment");
        console.log("===========================================");
        console.log("Chain id:                ", block.chainid);
        console.log("Broadcaster:             ", broadcaster);
        console.log("Admin / owner:           ", cfg.admin);
        console.log("USDC:                    ", cfg.usdc);
        console.log("ResolversDAO:            ", cfg.resolversDAO);
        console.log("ProtocolDAO:             ", cfg.protocolDAO);
        console.log("MissionFactory:          ", cfg.missionFactory);
        console.log("DeliveryMissionFactory:  ", cfg.deliveryMissionFactory);
        console.log("Old DisputeResolver:     ", cfg.oldDisputeResolver);

        // ------------------------------------------------------------------
        // 1. Pre-flight
        // ------------------------------------------------------------------
        if (cfg.usdc.code.length == 0) revert NoCodeAtAddress("USDC", cfg.usdc);
        bool canWireCore = _preflightFactory("MISSION_FACTORY", cfg.missionFactory, broadcaster, cfg.allowUnwiredFactories);
        bool canWireDelivery = _preflightFactory(
            "DELIVERY_MISSION_FACTORY", cfg.deliveryMissionFactory, broadcaster, cfg.allowUnwiredFactories
        );

        // ------------------------------------------------------------------
        // 2. Broadcast
        // ------------------------------------------------------------------
        if (cfg.deployerPrivateKey != 0) {
            vm.startBroadcast(cfg.deployerPrivateKey);
        } else {
            vm.startBroadcast();
        }

        DisputeResolver resolver = new DisputeResolver(
            cfg.usdc, cfg.resolversDAO, cfg.protocolDAO, cfg.protocolTreasury, cfg.resolverTreasury
        );
        out.disputeResolver = address(resolver);
        console.log("1. DisputeResolver:", out.disputeResolver);

        if (canWireCore) {
            MissionFactory(cfg.missionFactory).setDisputeResolver(address(resolver));
            out.missionFactoryWired = true;
            console.log("2. MissionFactory.setDisputeResolver done");
        }
        if (canWireDelivery) {
            DeliveryMissionFactory(cfg.deliveryMissionFactory).setDisputeResolver(address(resolver));
            out.deliveryFactoryWired = true;
            console.log("3. DeliveryMissionFactory.setDisputeResolver done");
        }
        if (cfg.admin != broadcaster) {
            resolver.transferOwnership(cfg.admin);
            console.log("4. ownership transferred to", cfg.admin);
        }

        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // 3. Post-checks
        // ------------------------------------------------------------------
        require(resolver.owner() == cfg.admin, "resolver owner != admin");
        require(resolver.resolversDAO() == cfg.resolversDAO, "resolversDAO mismatch");
        require(resolver.protocolDAO() == cfg.protocolDAO, "protocolDAO mismatch");
        if (out.missionFactoryWired) {
            require(
                MissionFactory(cfg.missionFactory).disputeResolver() == address(resolver),
                "MissionFactory not re-pointed"
            );
        }
        if (out.deliveryFactoryWired) {
            require(
                DeliveryMissionFactory(cfg.deliveryMissionFactory).disputeResolver() == address(resolver),
                "DeliveryMissionFactory not re-pointed"
            );
        }

        // ------------------------------------------------------------------
        // 4. Summary
        // ------------------------------------------------------------------
        console.log("");
        console.log("=== DEPLOYMENT JSON ===");
        console.log("{");
        console.log('  "chainId": %s,', vm.toString(block.chainid));
        console.log('  "DisputeResolver": "%s",', vm.toString(out.disputeResolver));
        console.log('  "previousDisputeResolver": "%s",', vm.toString(cfg.oldDisputeResolver));
        console.log('  "MissionFactory": "%s",', vm.toString(cfg.missionFactory));
        console.log('  "missionFactoryWired": %s,', out.missionFactoryWired ? "true" : "false");
        console.log('  "DeliveryMissionFactory": "%s",', vm.toString(cfg.deliveryMissionFactory));
        console.log('  "deliveryFactoryWired": %s', out.deliveryFactoryWired ? "true" : "false");
        console.log("}");
        console.log("=== END DEPLOYMENT JSON ===");

        if (cfg.missionFactory != address(0) && !out.missionFactoryWired) {
            _printActionRequired(cfg.missionFactory, address(resolver));
        }
        if (cfg.deliveryMissionFactory != address(0) && !out.deliveryFactoryWired) {
            _printActionRequired(cfg.deliveryMissionFactory, address(resolver));
        }
        console.log("");
        console.log("NOTE: escrows created BEFORE this re-point keep the previous resolver address;");
        console.log("      only new escrows dispute through the new DisputeResolver.");
    }

    /// @dev Returns true when the broadcaster can call setDisputeResolver on `factory`.
    function _preflightFactory(string memory name, address factory, address broadcaster, bool allowUnwired)
        internal
        view
        returns (bool)
    {
        if (factory == address(0)) return false;
        if (factory.code.length == 0) revert NoCodeAtAddress(name, factory);
        // Both factories are Ownable with the same owner() selector.
        address owner = MissionFactory(factory).owner();
        if (owner == broadcaster) return true;
        if (!allowUnwired) revert BroadcasterNotOwner(name, factory, owner, broadcaster);
        console.log("WARNING: broadcaster is not the owner of", name, "- NOT re-pointed");
        return false;
    }

    function _printActionRequired(address factory, address resolver) internal pure {
        console.log("ACTION REQUIRED - new escrows of this factory still use the OLD resolver until its owner runs:");
        console.log(
            string.concat(
                "  cast send ",
                vm.toString(factory),
                " 'setDisputeResolver(address)' ",
                vm.toString(resolver),
                " --rpc-url $BASE_SEPOLIA_RPC_URL --account <factory owner>"
            )
        );
    }
}
