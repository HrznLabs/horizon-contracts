// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GuildDAO} from "../src/GuildDAO.sol";

/**
 * @title UpdateTreasuries
 * @notice Update Protocol DAO treasury addresses to Gnosis Safes
 * @dev Run: forge script script/UpdateTreasuries.s.sol --rpc-url <RPC_URL> --broadcast
 * 
 * INSTRUCTIONS:
 * 1. Create Gnosis Safes for each DAO at app.safe.global
 * 2. Set the following environment variables:
 *    - IS_MAINNET (true/false)
 *    - PROTOCOL_DAO_MAINNET (if mainnet)
 *    - RESOLVERS_DAO_MAINNET (if mainnet)
 *    - LABS_DAO_MAINNET (if mainnet)
 *    - NEW_PROTOCOL_TREASURY
 *    - NEW_RESOLVERS_TREASURY
 *    - NEW_LABS_TREASURY
 *    - DEPLOYER_PRIVATE_KEY
 * 3. Run this script with the admin private key
 */
contract UpdateTreasuries is Script {
    // =============================================================================
    // TESTNET ADDRESSES (Base Sepolia)
    // =============================================================================
    
    // Protocol DAO addresses (deployed)
    address public constant PROTOCOL_DAO_SEPOLIA = 0xfC8b4A430A52841Bda4ce7789E2B1Cf9e17A599F;
    address public constant RESOLVERS_DAO_SEPOLIA = 0x8b369940D85f6DC8B5BB34a27EA8101c9863128A;
    address public constant LABS_DAO_SEPOLIA = 0x082af13A5de37bf8F9700469DDB1532d8E7a8609;
    
    // =============================================================================
    // MAINNET ADDRESSES (Base) - Set via Env Vars
    // =============================================================================
    
    address public PROTOCOL_DAO_MAINNET;
    address public RESOLVERS_DAO_MAINNET;
    address public LABS_DAO_MAINNET;
    
    // =============================================================================
    // NEW TREASURY ADDRESSES (Gnosis Safes) - Set via Env Vars
    // =============================================================================
    
    address public NEW_PROTOCOL_TREASURY;
    address public NEW_RESOLVERS_TREASURY;
    address public NEW_LABS_TREASURY;

    // =============================================================================
    // CONFIGURATION
    // =============================================================================
    
    // Set to true for mainnet, false for testnet
    bool public IS_MAINNET;

    function run() public {
        // Load configuration from environment
        IS_MAINNET = vm.envOr("IS_MAINNET", false);

        if (IS_MAINNET) {
            PROTOCOL_DAO_MAINNET = vm.envAddress("PROTOCOL_DAO_MAINNET");
            RESOLVERS_DAO_MAINNET = vm.envAddress("RESOLVERS_DAO_MAINNET");
            LABS_DAO_MAINNET = vm.envAddress("LABS_DAO_MAINNET");
        }

        NEW_PROTOCOL_TREASURY = vm.envOr("NEW_PROTOCOL_TREASURY", address(0));
        NEW_RESOLVERS_TREASURY = vm.envOr("NEW_RESOLVERS_TREASURY", address(0));
        NEW_LABS_TREASURY = vm.envOr("NEW_LABS_TREASURY", address(0));

        require(NEW_PROTOCOL_TREASURY != address(0), "Set NEW_PROTOCOL_TREASURY env var");
        require(NEW_RESOLVERS_TREASURY != address(0), "Set NEW_RESOLVERS_TREASURY env var");
        require(NEW_LABS_TREASURY != address(0), "Set NEW_LABS_TREASURY env var");
        
        uint256 adminKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.addr(adminKey);
        
        // Select addresses based on network
        address protocolDAO = IS_MAINNET ? PROTOCOL_DAO_MAINNET : PROTOCOL_DAO_SEPOLIA;
        address resolversDAO = IS_MAINNET ? RESOLVERS_DAO_MAINNET : RESOLVERS_DAO_SEPOLIA;
        address labsDAO = IS_MAINNET ? LABS_DAO_MAINNET : LABS_DAO_SEPOLIA;

        console.log("===========================================");
        console.log("  Update Protocol DAO Treasuries");
        console.log("===========================================");
        console.log("Network:", IS_MAINNET ? "Base Mainnet" : "Base Sepolia");
        console.log("Admin:", admin);
        console.log("");
        console.log("New Treasuries:");
        console.log("  Protocol DAO:", NEW_PROTOCOL_TREASURY);
        console.log("  Resolvers DAO:", NEW_RESOLVERS_TREASURY);
        console.log("  Labs DAO:", NEW_LABS_TREASURY);
        console.log("");
        
        vm.startBroadcast(adminKey);
        
        // Update Protocol DAO
        console.log("Updating Protocol DAO treasury...");
        GuildDAO(protocolDAO).updateConfig(
            "Protocol DAO",
            NEW_PROTOCOL_TREASURY,
            0 // No guild fee
        );
        console.log("  Done!");
        
        // Update Resolvers DAO
        console.log("Updating Resolvers DAO treasury...");
        GuildDAO(resolversDAO).updateConfig(
            "Resolvers DAO",
            NEW_RESOLVERS_TREASURY,
            0
        );
        console.log("  Done!");
        
        // Update Labs DAO
        console.log("Updating Labs DAO treasury...");
        GuildDAO(labsDAO).updateConfig(
            "Horizon Labs DAO",
            NEW_LABS_TREASURY,
            0
        );
        console.log("  Done!");
        
        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("  TREASURY UPDATE COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Don't forget to update Supabase:");
        console.log("");
        console.log("UPDATE guilds SET treasury = '", NEW_PROTOCOL_TREASURY, "'");
        console.log("WHERE protocol_dao_type = 'protocol';");
        console.log("");
        console.log("UPDATE guilds SET treasury = '", NEW_RESOLVERS_TREASURY, "'");
        console.log("WHERE protocol_dao_type = 'resolvers';");
        console.log("");
        console.log("UPDATE guilds SET treasury = '", NEW_LABS_TREASURY, "'");
        console.log("WHERE protocol_dao_type = 'labs';");
    }
}
