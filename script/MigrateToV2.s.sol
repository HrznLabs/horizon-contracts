// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GuildFactory} from "../src/GuildFactory.sol";
import {GuildDAO} from "../src/GuildDAO.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MissionFactory} from "../src/MissionFactory.sol";

/**
 * @title MigrateToV2
 * @notice Full migration script to deploy v2 contracts and recreate Protocol DAOs
 * @dev Run with: forge script script/MigrateToV2.s.sol --rpc-url base-sepolia --broadcast
 * 
 * This script:
 * 1. Uses existing GuildFactory v2 and PaymentRouter v2 (deployed for iTake)
 * 2. Creates Protocol DAO, Resolvers DAO, Labs DAO on GuildFactory v2
 * 3. Deploys new MissionFactory pointing to PaymentRouter v2
 * 4. Sets all treasury addresses
 * 5. Transfers ownership to jollyv.eth
 */
contract MigrateToV2 is Script {
    // =============================================================================
    // ADDRESSES
    // =============================================================================
    
    // Deployed v2 contracts (from iTake deployment)
    address public constant GUILD_FACTORY_V2 = 0xe44ff754dde60bFa289766F6e884940832D8D380;
    address public constant PAYMENT_ROUTER_V2 = 0x8b5D47c862b54a29Fc4eF9f3d8c041C8Ae669750;
    
    // USDC on Base Sepolia
    address public constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    // Owner (jollyv.eth)
    address public constant JOLLYV_ETH = 0x2b30efBA367D669c9cd7723587346a79b67A42DB;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("===========================================");
        console.log("  HORIZON V2 FULL MIGRATION");
        console.log("===========================================");
        console.log("");
        console.log("Using existing v2 contracts:");
        console.log("  GuildFactory v2:", GUILD_FACTORY_V2);
        console.log("  PaymentRouter v2:", PAYMENT_ROUTER_V2);
        console.log("");
        
        GuildFactory guildFactory = GuildFactory(GUILD_FACTORY_V2);
        PaymentRouter paymentRouter = PaymentRouter(PAYMENT_ROUTER_V2);
        
        // =============================================================================
        // 1. CREATE PROTOCOL DAOs ON GUILDFACTORY V2
        // =============================================================================
        
        console.log("1. Creating Protocol DAOs on GuildFactory v2...");
        
        // Protocol DAO (0% guild fee - fees go to dedicated treasury)
        (uint256 protocolId, address protocolDAO) = guildFactory.createGuild(
            "Protocol DAO",
            JOLLYV_ETH,  // Treasury
            0            // 0% guild fee (platform fees are separate)
        );
        console.log("   Protocol DAO (ID:", protocolId, "):", protocolDAO);
        
        // Resolvers DAO (0% guild fee)
        (uint256 resolversId, address resolversDAO) = guildFactory.createGuild(
            "Resolvers DAO",
            JOLLYV_ETH,
            0
        );
        console.log("   Resolvers DAO (ID:", resolversId, "):", resolversDAO);
        
        // Labs DAO (0% guild fee)
        (uint256 labsId, address labsDAO) = guildFactory.createGuild(
            "Horizon Labs DAO",
            JOLLYV_ETH,
            0
        );
        console.log("   Labs DAO (ID:", labsId, "):", labsDAO);
        
        // =============================================================================
        // 2. DEPLOY NEW MISSIONFACTORY POINTING TO PAYMENTROUTER V2
        // =============================================================================
        
        console.log("");
        console.log("2. Deploying new MissionFactory...");
        
        // MissionFactory takes 1 arg: paymentRouter (token is per-mission)
        MissionFactory missionFactory = new MissionFactory(
            PAYMENT_ROUTER_V2
        );
        console.log("   MissionFactory:", address(missionFactory));
        
        // =============================================================================
        // 3. CONFIGURE PAYMENTROUTER V2 TREASURIES
        // =============================================================================
        
        console.log("");
        console.log("3. Configuring PaymentRouter v2 treasuries...");
        
        // Set Protocol DAO treasury
        paymentRouter.setGuildTreasury(protocolDAO, JOLLYV_ETH);
        
        // Set Resolvers DAO treasury
        paymentRouter.setGuildTreasury(resolversDAO, JOLLYV_ETH);
        
        // Set Labs DAO treasury
        paymentRouter.setGuildTreasury(labsDAO, JOLLYV_ETH);
        
        console.log("   All treasuries set to jollyv.eth");
        
        // =============================================================================
        // 4. TRANSFER OWNERSHIP
        // =============================================================================
        
        console.log("");
        console.log("4. Transferring ownership to jollyv.eth...");
        
        missionFactory.transferOwnership(JOLLYV_ETH);
        console.log("   MissionFactory ownership transferred");
        
        // Note: Escrows authorize themselves when created - no need to
        // explicitly authorize MissionFactory on PaymentRouter
        
        vm.stopBroadcast();
        
        // =============================================================================
        // SUMMARY
        // =============================================================================
        
        console.log("");
        console.log("===========================================");
        console.log("  V2 MIGRATION COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Protocol DAOs (v2):");
        console.log("  Protocol DAO (ID:", protocolId, "):", protocolDAO);
        console.log("  Resolvers DAO (ID:", resolversId, "):", resolversDAO);
        console.log("  Labs DAO (ID:", labsId, "):", labsDAO);
        console.log("");
        console.log("Core Contracts (v2):");
        console.log("  MissionFactory:", address(missionFactory));
        console.log("  PaymentRouter:", PAYMENT_ROUTER_V2);
        console.log("  GuildFactory:", GUILD_FACTORY_V2);
        console.log("");
        console.log("Fee Structure (v2):");
        console.log("  Protocol: 2.5%");
        console.log("  Labs: 2.5%");
        console.log("  Resolver: 2%");
        console.log("  Total Platform: 7% (+ optional guild fees)");
        console.log("  Worker gets: 93%+ (best deal in Web3!)");
        console.log("");
        console.log("UPDATE YOUR .env FILES:");
        console.log("  MISSION_FACTORY_ADDRESS=", address(missionFactory));
        console.log("  PAYMENT_ROUTER_ADDRESS=", PAYMENT_ROUTER_V2);
        console.log("  GUILD_FACTORY_ADDRESS=", GUILD_FACTORY_V2);
    }
}
