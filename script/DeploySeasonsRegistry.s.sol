// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SeasonsRegistry} from "../src/SeasonsRegistry.sol";

/**
 * @title DeploySeasonsRegistry
 * @notice Deploys the SeasonsRegistry contract to Base Sepolia (or any EVM chain).
 *
 * Usage (dry-run):
 *   forge script script/DeploySeasonsRegistry.s.sol:DeploySeasonsRegistry \
 *     --rpc-url $BASE_RPC_URL \
 *     -vvvv
 *
 * Usage (broadcast):
 *   PRIVATE_KEY=0x... forge script script/DeploySeasonsRegistry.s.sol:DeploySeasonsRegistry \
 *     --rpc-url $BASE_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeploySeasonsRegistry is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deploying SeasonsRegistry from:", deployer);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        SeasonsRegistry registry = new SeasonsRegistry();

        vm.stopBroadcast();

        console2.log("\n========================================");
        console2.log("DEPLOYMENT SUMMARY");
        console2.log("========================================");
        console2.log("SeasonsRegistry deployed at:", address(registry));
        console2.log("Owner:", registry.owner());
        console2.log("========================================");
    }
}
