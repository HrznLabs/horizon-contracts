// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GuildGovernorFactorySimple} from "../src/governance/GuildGovernorFactorySimple.sol";
import {GuildXP} from "../src/governance/GuildXP.sol";

/**
 * @title DeployGovernance
 * @notice Deploys Guild Governance contracts to Base Sepolia
 *
 * Usage:
 *   PRIVATE_KEY=0x... RELAYER_ADDRESS=0x... forge script script/DeployGovernance.s.sol:DeployGovernance \
 *     --rpc-url $BASE_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployGovernance is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Relayer is the backend service that syncs XP from database
        // Default to deployer if not specified
        address relayer = vm.envOr("RELAYER_ADDRESS", deployer);

        console2.log("Deploying from:", deployer);
        console2.log("Relayer address:", relayer);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy GuildXP contract (production - syncs with database)
        GuildXP xpContract = new GuildXP(deployer, relayer);
        console2.log("GuildXP deployed at:", address(xpContract));

        // 2. Deploy Governor Factory
        GuildGovernorFactorySimple factory = new GuildGovernorFactorySimple(address(xpContract));
        console2.log("GuildGovernorFactorySimple deployed at:", address(factory));

        // Log default parameters
        console2.log("\nDefault Parameters:");
        console2.log("  Voting Delay:", factory.defaultVotingDelay(), "blocks");
        console2.log("  Voting Period:", factory.defaultVotingPeriod(), "blocks (~1 week)");
        console2.log("  Proposal Threshold:", factory.defaultProposalThreshold(), "XP");
        console2.log("  Quorum:", factory.defaultQuorum(), "%");

        vm.stopBroadcast();

        // Output deployment addresses for easy copying
        console2.log("\n========================================");
        console2.log("DEPLOYMENT SUMMARY");
        console2.log("========================================");
        console2.log("GUILD_XP_ADDRESS=", address(xpContract));
        console2.log("GOVERNOR_FACTORY_ADDRESS=", address(factory));
        console2.log("========================================");
    }
}

/**
 * @title DeployGovernanceForGuild
 * @notice Deploys governance for a specific guild
 *
 * Usage:
 *   GUILD_ADDRESS=0x... forge script script/DeployGovernance.s.sol:DeployGovernanceForGuild \
 *     --rpc-url $BASE_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract DeployGovernanceForGuild is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("GOVERNOR_FACTORY_ADDRESS");
        address guildAddress = vm.envAddress("GUILD_ADDRESS");

        console2.log("Deploying governance for guild:", guildAddress);

        vm.startBroadcast(deployerPrivateKey);

        GuildGovernorFactorySimple factory = GuildGovernorFactorySimple(factoryAddress);

        // Check if already deployed
        if (factory.hasGovernance(guildAddress)) {
            console2.log("Governance already deployed for this guild!");
            address governor = factory.getGovernance(guildAddress);
            console2.log("Governor:", governor);
            vm.stopBroadcast();
            return;
        }

        // Deploy governance
        address governor = factory.deployGovernance(guildAddress);

        console2.log("\nGovernance deployed:");
        console2.log("  Governor:", governor);

        vm.stopBroadcast();
    }
}

/**
 * @title SetupTestXP
 * @notice Sets up test XP for accounts to test governance
 *
 * Usage:
 *   GUILD_XP_ADDRESS=0x... GUILD_ADDRESS=0x... forge script script/DeployGovernance.s.sol:SetupTestXP \
 *     --rpc-url $BASE_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract SetupTestXP is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address xpAddress = vm.envAddress("GUILD_XP_ADDRESS");
        address guildAddress = vm.envAddress("GUILD_ADDRESS");

        console2.log("Setting up test XP for guild:", guildAddress);

        vm.startBroadcast(deployerPrivateKey);

        GuildXP xpContract = GuildXP(xpAddress);

        // Set up test accounts with XP
        address deployer = vm.addr(deployerPrivateKey);

        // Give deployer enough XP to propose and vote
        xpContract.updateXP(guildAddress, deployer, 1000);
        console2.log("Set 1000 XP for deployer:", deployer);

        // Total XP for quorum calculation
        console2.log("Total Guild XP:", xpContract.getTotalGuildXP(guildAddress));

        vm.stopBroadcast();
    }
}
