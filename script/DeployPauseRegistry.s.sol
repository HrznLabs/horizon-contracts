// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PauseRegistry} from "../src/PauseRegistry.sol";

/**
 * @title DeployPauseRegistry
 * @notice Deploys the PauseRegistry contract — the protocol-wide circuit breaker.
 *
 * PauseRegistry is a MAINNET BLOCKER: MissionFactory and MissionEscrow already
 * import it; until a real address is wired in they silently skip pause checks
 * (pauseRegistry == address(0)). Deploy this first, then run WirePauseRegistry.s.sol.
 *
 * Usage (dry-run):
 *   forge script script/DeployPauseRegistry.s.sol:DeployPauseRegistry \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     -vvvv
 *
 * Usage (broadcast + verify):
 *   PRIVATE_KEY=0x... forge script script/DeployPauseRegistry.s.sol:DeployPauseRegistry \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * After deploy:
 *   export PAUSE_REGISTRY_ADDRESS=<address from console log>
 *   forge script script/WirePauseRegistry.s.sol:WirePauseRegistry \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract DeployPauseRegistry is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Admin is the deployer by default. Override with PAUSE_REGISTRY_ADMIN if needed.
        address admin = vm.envOr("PAUSE_REGISTRY_ADMIN", deployer);

        console2.log("Deploying PauseRegistry from:", deployer);
        console2.log("Admin (DEFAULT_ADMIN_ROLE + PAUSER_ROLE):", admin);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        PauseRegistry registry = new PauseRegistry(admin);

        vm.stopBroadcast();

        console2.log("\n========================================");
        console2.log("DEPLOYMENT SUMMARY");
        console2.log("========================================");
        console2.log("PauseRegistry deployed at:", address(registry));
        console2.log("Admin:", admin);
        console2.log("Circuit breaker threshold:", registry.circuitBreakerThresholdBPS(), "bps (default 30%)");
        console2.log("----------------------------------------");
        console2.log("Next step - export and wire:");
        console2.log("  export PAUSE_REGISTRY_ADDRESS=", address(registry));
        console2.log("  Then run WirePauseRegistry.s.sol");
        console2.log("========================================");
    }
}
