// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {GuildFactory} from "../src/GuildFactory.sol";
import {ReputationAttestations} from "../src/ReputationAttestations.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";
import {HorizonAchievements} from "../src/HorizonAchievements.sol";

/**
 * @title DeployScript
 * @notice Deployment script for Horizon Protocol contracts (v2.1)
 * @dev Deploy to Base Sepolia: forge script script/Deploy.s.sol --rpc-url base-sepolia --broadcast
 * 
 * Fee Structure (updated):
 * - Protocol: 4% (fixed)
 * - Labs: 4% (fixed)
 * - Resolver: 2% (fixed)
 * - Guild: 0-15% (variable, set per-mission when curated)
 * - Performer: 90% - guildFee
 */
contract DeployScript is Script {
    // Base Sepolia USDC
    address public constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    // jollyv.eth / jollyv.base.eth - Protocol Owner
    address public constant JOLLYV_ETH = 0x2b30efBA367D669c9cd7723587346a79b67A42DB;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===========================================");
        console.log("  Horizon Protocol v2.2 Deployment");
        console.log("  Owner: jollyv.eth (jollyv.base.eth)");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("Owner:", JOLLYV_ETH);
        console.log("Network: Base Sepolia (84532)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy PaymentRouter with jollyv.eth as treasuries
        console.log("1. Deploying PaymentRouter...");
        PaymentRouter paymentRouter = new PaymentRouter(
            USDC_BASE_SEPOLIA,
            JOLLYV_ETH, // Protocol treasury
            JOLLYV_ETH, // Resolver treasury
            JOLLYV_ETH  // Labs treasury
        );
        console.log("   PaymentRouter:", address(paymentRouter));
        console.log("   Fee structure: Protocol 4%, Labs 4%, Resolver 2%, Guild variable");

        // 2. Deploy DisputeResolver with jollyv.eth as owner
        console.log("2. Deploying DisputeResolver...");
        DisputeResolver disputeResolver = new DisputeResolver(
            USDC_BASE_SEPOLIA,
            JOLLYV_ETH, // ResolversDAO
            JOLLYV_ETH, // ProtocolDAO
            JOLLYV_ETH, // Protocol treasury
            JOLLYV_ETH  // Resolver treasury
        );
        console.log("   DisputeResolver:", address(disputeResolver));
        console.log("   DDR Rate: 5%, LPP Rate: 2%");

        // 3. Deploy MissionFactory
        console.log("3. Deploying MissionFactory...");
        MissionFactory missionFactory = new MissionFactory(
            USDC_BASE_SEPOLIA,
            address(paymentRouter),
            address(disputeResolver)
        );
        console.log("   MissionFactory:", address(missionFactory));

        // 4. Deploy GuildFactory
        console.log("4. Deploying GuildFactory...");
        GuildFactory guildFactory = new GuildFactory();
        console.log("   GuildFactory:", address(guildFactory));

        // 5. Deploy ReputationAttestations
        console.log("5. Deploying ReputationAttestations...");
        ReputationAttestations reputationAttestations = new ReputationAttestations();
        console.log("   ReputationAttestations:", address(reputationAttestations));

        // 6. Deploy HorizonAchievements (NFT contract)
        console.log("6. Deploying HorizonAchievements...");
        HorizonAchievements achievements = new HorizonAchievements(
            "Horizon Achievements",
            "HRZN",
            "https://horizon.xyz/api/achievements/"
        );
        console.log("   HorizonAchievements:", address(achievements));

        // 7. Configure contracts
        console.log("");
        console.log("Configuring contracts...");
        
        paymentRouter.setMissionFactory(address(missionFactory));
        console.log("   PaymentRouter.setMissionFactory done");
        
        reputationAttestations.setMissionFactory(address(missionFactory));
        console.log("   ReputationAttestations.setMissionFactory done");

        // 8. Transfer ownership to jollyv.eth
        console.log("");
        console.log("Transferring ownership to jollyv.eth...");
        
        paymentRouter.transferOwnership(JOLLYV_ETH);
        console.log("   PaymentRouter ownership transferred");
        
        missionFactory.transferOwnership(JOLLYV_ETH);
        console.log("   MissionFactory ownership transferred");
        
        reputationAttestations.transferOwnership(JOLLYV_ETH);
        console.log("   ReputationAttestations ownership transferred");
        
        disputeResolver.transferOwnership(JOLLYV_ETH);
        console.log("   DisputeResolver ownership transferred");
        
        // Note: HorizonAchievements uses AccessControl, not Ownable
        // Admin role can grant roles to jollyv.eth after deployment

        vm.stopBroadcast();

        // Log deployment summary
        console.log("");
        console.log("===========================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Core Contracts:");
        console.log("  PaymentRouter:         ", address(paymentRouter));
        console.log("  MissionFactory:        ", address(missionFactory));
        console.log("  GuildFactory:          ", address(guildFactory));
        console.log("  ReputationAttestations:", address(reputationAttestations));
        console.log("  DisputeResolver:       ", address(disputeResolver));
        console.log("  HorizonAchievements:   ", address(achievements));
        console.log("");
        console.log("External:");
        console.log("  USDC (Base Sepolia):   ", USDC_BASE_SEPOLIA);
        console.log("");
        console.log("Fee Structure:");
        console.log("  Protocol Fee: 4%");
        console.log("  Labs Fee:     4%");
        console.log("  Resolver Fee: 2%");
        console.log("  Guild Fee:    Variable (0-15%)");
        console.log("  Performer:    90% - guildFee");
        console.log("");
        console.log("Copy these addresses to your .env file!");
    }
}
