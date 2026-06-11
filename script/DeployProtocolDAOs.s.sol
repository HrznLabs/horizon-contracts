// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GuildFactory} from "../src/GuildFactory.sol";
import {GuildDAO} from "../src/GuildDAO.sol";

/**
 * @title DeployProtocolDAOs
 * @notice Deploy the 3 Protocol DAOs via GuildFactory
 * @dev Run: forge script script/DeployProtocolDAOs.s.sol --rpc-url base-sepolia --broadcast
 * 
 * Protocol DAOs:
 * 1. Protocol DAO - Core protocol governance (fee parameters, upgrades, treasury)
 * 2. Resolvers DAO - Dispute resolution system governance
 * 3. Labs DAO - R&D funding and development
 */
contract DeployProtocolDAOs is Script {
    // jollyv.eth / jollyv.base.eth - Protocol Owner & Treasury
    address public constant JOLLYV_ETH = 0x2b30efBA367D669c9cd7723587346a79b67A42DB;
    
    // GuildFactory address on Base Sepolia (from previous deployment)
    // UPDATE THIS with your deployed GuildFactory address!
    address public constant GUILD_FACTORY = 0x93E57638DC3540a1472cD01C42a89463D9f5682A;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===========================================");
        console.log("  Protocol DAOs Deployment");
        console.log("  Owner/Treasury: jollyv.eth");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("GuildFactory:", GUILD_FACTORY);
        console.log("");

        GuildFactory factory = GuildFactory(GUILD_FACTORY);
        
        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // 1. PROTOCOL DAO
        // Core protocol governance
        // ============================================
        console.log("1. Deploying Protocol DAO...");
        (uint256 protocolDAOId, address protocolDAO) = factory.createGuild(
            "Protocol DAO",
            JOLLYV_ETH,  // Treasury
            0            // No guild fee for protocol DAOs
        );
        console.log("   ID:", protocolDAOId);
        console.log("   Address:", protocolDAO);
        
        // Set eligibility requirements
        GuildDAO(protocolDAO).updateEligibility(
            0,      // minGuildXP - not applicable for protocol DAO
            1000,   // minGlobalXP - high requirement
            75,     // minReputation - high requirement
            bytes32(0)  // requiredBadge - none
        );
        console.log("   Eligibility: 1000 XP, 75 reputation");

        // ============================================
        // 2. RESOLVERS DAO
        // Dispute resolution governance
        // ============================================
        console.log("");
        console.log("2. Deploying Resolvers DAO...");
        (uint256 resolversDAOId, address resolversDAO) = factory.createGuild(
            "Resolvers DAO",
            JOLLYV_ETH,  // Treasury
            0            // No guild fee
        );
        console.log("   ID:", resolversDAOId);
        console.log("   Address:", resolversDAO);
        
        GuildDAO(resolversDAO).updateEligibility(
            0,      // minGuildXP
            500,    // minGlobalXP - moderate requirement
            80,     // minReputation - high (dispute resolution requires trust)
            bytes32(0)
        );
        console.log("   Eligibility: 500 XP, 80 reputation");

        // ============================================
        // 3. LABS DAO
        // R&D and development governance
        // ============================================
        console.log("");
        console.log("3. Deploying Labs DAO...");
        (uint256 labsDAOId, address labsDAO) = factory.createGuild(
            "Horizon Labs DAO",
            JOLLYV_ETH,  // Treasury
            0            // No guild fee
        );
        console.log("   ID:", labsDAOId);
        console.log("   Address:", labsDAO);
        
        GuildDAO(labsDAO).updateEligibility(
            0,      // minGuildXP
            250,    // minGlobalXP - lower for contributors
            60,     // minReputation - moderate
            bytes32(0)
        );
        console.log("   Eligibility: 250 XP, 60 reputation");

        vm.stopBroadcast();

        // ============================================
        // DEPLOYMENT SUMMARY
        // ============================================
        console.log("");
        console.log("===========================================");
        console.log("  PROTOCOL DAOs DEPLOYED");
        console.log("===========================================");
        console.log("");
        console.log("Protocol DAO:");
        console.log("  ID:      ", protocolDAOId);
        console.log("  Address: ", protocolDAO);
        console.log("  Purpose:  Core protocol governance");
        console.log("");
        console.log("Resolvers DAO:");
        console.log("  ID:      ", resolversDAOId);
        console.log("  Address: ", resolversDAO);
        console.log("  Purpose:  Dispute resolution governance");
        console.log("");
        console.log("Labs DAO:");
        console.log("  ID:      ", labsDAOId);
        console.log("  Address: ", labsDAO);
        console.log("  Purpose:  R&D and development");
        console.log("");
        console.log("Treasury (all DAOs): ", JOLLYV_ETH);
        console.log("");
        console.log("===========================================");
        console.log("  UPDATE DATABASE WITH THESE ADDRESSES!");
        console.log("===========================================");
        console.log("");
        console.log("Run this SQL in Supabase:");
        console.log("");
        console.log("UPDATE guilds SET");
        console.log("  on_chain_id = ", protocolDAOId, ",");
        console.log("  contract_address = '", protocolDAO, "'");
        console.log("WHERE protocol_dao_type = 'protocol';");
        console.log("");
        console.log("UPDATE guilds SET");
        console.log("  on_chain_id = ", resolversDAOId, ",");
        console.log("  contract_address = '", resolversDAO, "'");
        console.log("WHERE protocol_dao_type = 'resolvers';");
        console.log("");
        console.log("UPDATE guilds SET");
        console.log("  on_chain_id = ", labsDAOId, ",");
        console.log("  contract_address = '", labsDAO, "'");
        console.log("WHERE protocol_dao_type = 'labs';");
    }
}


