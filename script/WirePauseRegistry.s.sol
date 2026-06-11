// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IMissionFactory {
    function setPauseRegistry(address _pauseRegistry) external;
    function pauseRegistry() external view returns (address);
    function owner() external view returns (address);
}

/**
 * @title WirePauseRegistry
 * @notice Wires the deployed PauseRegistry address into MissionFactory (and optionally
 *         any additional consuming contracts) via their setPauseRegistry() setters.
 *
 * MissionEscrow does NOT have a standalone setPauseRegistry setter — the registry
 * address is passed at construction time by MissionFactory when it deploys escrow
 * clones, so wiring the factory is sufficient.
 *
 * Prerequisites:
 *   1. DeployPauseRegistry.s.sol has been run
 *   2. Environment contains:
 *        PRIVATE_KEY            — deployer private key (must be factory owner)
 *        PAUSE_REGISTRY_ADDRESS — address from DeployPauseRegistry output
 *        MISSION_FACTORY_ADDRESS — deployed MissionFactory address
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   PAUSE_REGISTRY_ADDRESS=0x... \
 *   MISSION_FACTORY_ADDRESS=0x... \
 *   forge script script/WirePauseRegistry.s.sol:WirePauseRegistry \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvvv
 *
 * Verify the wiring:
 *   cast call $MISSION_FACTORY_ADDRESS "pauseRegistry()(address)" --rpc-url $BASE_SEPOLIA_RPC_URL
 *   # should return $PAUSE_REGISTRY_ADDRESS
 */
contract WirePauseRegistry is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address pauseRegistryAddr = vm.envAddress("PAUSE_REGISTRY_ADDRESS");
        address missionFactoryAddr = vm.envAddress("MISSION_FACTORY_ADDRESS");

        console2.log("Wiring PauseRegistry into MissionFactory");
        console2.log("Caller (must be factory owner):", deployer);
        console2.log("PauseRegistry:", pauseRegistryAddr);
        console2.log("MissionFactory:", missionFactoryAddr);

        IMissionFactory factory = IMissionFactory(missionFactoryAddr);

        address currentRegistry = factory.pauseRegistry();
        console2.log("Current pauseRegistry on factory:", currentRegistry);

        if (currentRegistry == pauseRegistryAddr) {
            console2.log("Already wired - nothing to do.");
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        factory.setPauseRegistry(pauseRegistryAddr);

        vm.stopBroadcast();

        console2.log("\n========================================");
        console2.log("WIRING COMPLETE");
        console2.log("========================================");
        console2.log("MissionFactory.pauseRegistry() =>", pauseRegistryAddr);
        console2.log("----------------------------------------");
        console2.log("Verify with:");
        console2.log("  cast call", missionFactoryAddr, "\"pauseRegistry()(address)\" --rpc-url $BASE_SEPOLIA_RPC_URL");
        console2.log("========================================");
    }
}
