// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {GuildFactory} from "../src/GuildFactory.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";
import {HorizonAchievements} from "../src/HorizonAchievements.sol";

/**
 * @title DeployScript
 * @notice Deployment script for Horizon Protocol contracts (v3 - Secure Foundation)
 * @dev Deploy to Base Sepolia: forge script script/Deploy.s.sol --rpc-url base-sepolia --broadcast
 * 
 * Fee Structure (v3):
 * - Protocol: 2.5% (fixed)
 * - Labs: 2.5% (fixed)
 * - Resolver: 2% (fixed)
 * - Guild: 0-3% (variable, auto-capped to protect 90% performer floor)
 * - Performer: >= 90% minimum (governable floor)
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
        console.log("  Horizon Protocol v3.0 Deployment");
        console.log("  (Secure Foundation)");
        console.log("  Owner: jollyv.eth (jollyv.base.eth)");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("Owner:", JOLLYV_ETH);
        console.log("Network: Base Sepolia (84532)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy PaymentRouter with AccessControl
        console.log("1. Deploying PaymentRouter (AccessControl + Pausable)...");
        PaymentRouter paymentRouter = new PaymentRouter(
            USDC_BASE_SEPOLIA,
            JOLLYV_ETH, // Protocol treasury
            JOLLYV_ETH, // Resolver treasury
            JOLLYV_ETH, // Labs treasury
            JOLLYV_ETH  // Admin (DEFAULT_ADMIN_ROLE, PAUSER_ROLE, FEE_MANAGER_ROLE)
        );
        console.log("   PaymentRouter:", address(paymentRouter));
        console.log("   Fee structure: Protocol 2.5%, Labs 2.5%, Resolver 2%, Guild variable");
        console.log("   Performer floor: 90% (governable, min 85%)");

        // 2. Deploy MissionFactory
        console.log("2. Deploying MissionFactory...");
        MissionFactory missionFactory = new MissionFactory(
            address(paymentRouter)
        );
        console.log("   MissionFactory:", address(missionFactory));

        // 3. Deploy GuildFactory
        console.log("3. Deploying GuildFactory...");
        GuildFactory guildFactory = new GuildFactory();
        console.log("   GuildFactory:", address(guildFactory));

        // 4. Deploy DisputeResolver
        console.log("4. Deploying DisputeResolver (with DDR timeout)...");
        DisputeResolver disputeResolver = new DisputeResolver(
            USDC_BASE_SEPOLIA,
            JOLLYV_ETH, // ResolversDAO
            JOLLYV_ETH, // ProtocolDAO
            JOLLYV_ETH, // Protocol treasury
            JOLLYV_ETH  // Resolver treasury
        );
        console.log("   DisputeResolver:", address(disputeResolver));
        console.log("   DDR Rate: 5%, LPP Rate: 2%, DDR Timeout: 24h");

        // 5. Deploy HorizonAchievements (NFT contract)
        console.log("5. Deploying HorizonAchievements...");
        HorizonAchievements achievements = new HorizonAchievements(
            "Horizon Achievements",
            "HRZN",
            "https://horizon.xyz/api/achievements/"
        );
        console.log("   HorizonAchievements:", address(achievements));

        // 6. Configure contracts
        console.log("");
        console.log("Configuring contracts...");
        
        // PaymentRouter: Grant SETTLER_ROLE to MissionFactory-deployed escrows
        // (In practice, escrow clones call settlePayment, so we grant to the factory
        //  or use a hook pattern. For now, grant to admin for flexibility.)
        paymentRouter.setMissionFactory(address(missionFactory));
        console.log("   PaymentRouter.setMissionFactory done");
        
        // MissionFactory: Set disputeResolver
        missionFactory.setDisputeResolver(address(disputeResolver));
        console.log("   MissionFactory.setDisputeResolver done");
        
        // 7. Transfer ownership to jollyv.eth
        // Note: PaymentRouter uses AccessControl, not Ownable
        //       Admin roles already granted to JOLLYV_ETH in constructor
        console.log("");
        console.log("Transferring ownership to jollyv.eth...");
        
        missionFactory.transferOwnership(JOLLYV_ETH);
        console.log("   MissionFactory ownership transferred");
        
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
        console.log("  DisputeResolver:       ", address(disputeResolver));
        console.log("  HorizonAchievements:   ", address(achievements));
        console.log("");
        console.log("External:");
        console.log("  USDC (Base Sepolia):   ", USDC_BASE_SEPOLIA);
        console.log("");
        console.log("Fee Structure (v3):");
        console.log("  Protocol Fee: 2.5%");
        console.log("  Labs Fee:     2.5%");
        console.log("  Resolver Fee: 2%");
        console.log("  Guild Fee:    Variable (0-3%, auto-capped)");
        console.log("  Performer:    >= 90% minimum (governable floor)");
        console.log("");
        console.log("Security Features:");
        console.log("  PaymentRouter: AccessControl + Pausable");
        console.log("  DisputeResolver: DDR Timeout (24h default)");
        console.log("  MissionEscrow: onlyDisputeResolver on settleDispute");
        console.log("");
        console.log("Copy these addresses to your .env file!");
    }
}
