// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { GuildFactory } from "../src/GuildFactory.sol";

/**
 * @title RedeployGuildFactory
 * @notice Deploys a fresh GuildFactory. The factory's constructor deploys the GuildDAO
 *         implementation, so this is how a GuildDAO fix (e.g. #949 removeMember role
 *         revocation / last-admin guard) reaches new guilds.
 *
 * IMPORTANT - existing clones are NOT upgraded. GuildDAO clones are EIP-1167 minimal
 * proxies bound to the implementation address of the factory that created them.
 * iTakeMetaDAO, AtobaDAO, LisboaCafe and the DeliveriesDAO guild roles created from the
 * old GuildFactory keep running the OLD (vulnerable) implementation. They must be
 * recreated from the new factory (new addresses) if the fix matters for them.
 *
 * Environment:
 *   DEPLOYER_PRIVATE_KEY  (optional) when unset the script broadcasts with `--sender`.
 *   OLD_GUILD_FACTORY     (optional) previous factory, echoed in the summary for the
 *                         consumer-update checklist.
 *
 * Dry run:   forge script script/RedeployGuildFactory.s.sol --rpc-url <rpc> --sender <admin> -vvvv
 * Broadcast: add `--broadcast --verify` and set DEPLOYER_PRIVATE_KEY (see script/README.md).
 */
contract RedeployGuildFactory is Script {
    function run() external returns (address guildFactory, address guildImplementation) {
        uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address oldFactory = vm.envOr("OLD_GUILD_FACTORY", address(0));
        address broadcaster = deployerPrivateKey != 0 ? vm.addr(deployerPrivateKey) : msg.sender;

        console.log("===========================================");
        console.log("  GuildFactory redeploy (new GuildDAO impl)");
        console.log("===========================================");
        console.log("Chain id:    ", block.chainid);
        console.log("Broadcaster: ", broadcaster);
        if (oldFactory != address(0)) {
            console.log("Old factory: ", oldFactory);
            if (oldFactory.code.length > 0) {
                console.log("Old impl:    ", GuildFactory(oldFactory).guildImplementation());
            }
        }
        console.log("");

        if (deployerPrivateKey != 0) {
            vm.startBroadcast(deployerPrivateKey);
        } else {
            vm.startBroadcast();
        }

        console.log("1. Deploying GuildFactory (constructor deploys GuildDAO implementation)...");
        GuildFactory factory = new GuildFactory();
        guildFactory = address(factory);
        guildImplementation = factory.guildImplementation();

        vm.stopBroadcast();

        require(factory.owner() == broadcaster, "factory owner != broadcaster");
        require(guildImplementation.code.length > 0, "GuildDAO impl has no code");

        console.log("");
        console.log("=== DEPLOYMENT JSON ===");
        console.log("{");
        console.log('  "chainId": %s,', vm.toString(block.chainid));
        console.log('  "GuildFactory": "%s",', vm.toString(guildFactory));
        console.log('  "GuildDAOImpl": "%s",', vm.toString(guildImplementation));
        console.log('  "previousGuildFactory": "%s"', vm.toString(oldFactory));
        console.log("}");
        console.log("=== END DEPLOYMENT JSON ===");
        console.log("");
        console.log(
            "NOTE: existing guild clones (iTakeMetaDAO, AtobaDAO, LisboaCafe, DeliveriesDAO"
        );
        console.log(
            "      guild roles) stay on the OLD GuildDAO implementation. Only guilds created"
        );
        console.log("      through this new factory get the fixed implementation.");
        console.log("");
        console.log("Explorer:");
        console.log("  https://sepolia.basescan.org/address/%s", guildFactory);
        console.log("  https://sepolia.basescan.org/address/%s", guildImplementation);

        if (
            !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                && !vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            console.log("");
            console.log("SIMULATION COMPLETE - no transactions were broadcast (add --broadcast)");
        }
    }
}
