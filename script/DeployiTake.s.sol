// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {GuildFactory} from "../src/GuildFactory.sol";
import {GuildDAO} from "../src/GuildDAO.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationOracle} from "../src/ReputationOracle.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {DeliveriesDAO} from "../src/DeliveriesDAO.sol";

/**
 * @title DeployiTake
 * @notice Complete deployment script for the iTake stack on Base Sepolia
 * @dev Deploy: forge script script/DeployiTake.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify
 *
 * Deployment sequence:
 *   1. GuildFactory (contains GuildDAO implementation)
 *   2. PaymentRouter (USDC + treasury addresses + admin)
 *   3. ReputationOracle (admin = deployer, RELAYER_ROLE = backend hot wallet)
 *   4. DeliveryMissionFactory (usdc + paymentRouter)
 *   5. DeliveriesDAO (insurance pool, usdc)
 *   6. iTake MetaDAO via GuildFactory (0.5% fee)
 *   7. AtobaDAO SubDAO (2% restaurant fee, portuguese cuisine)
 *   8. LisboaCafe SubDAO (2.5% restaurant fee, cafe)
 *   9. Register SubDAOs with MetaDAO + set PaymentRouter treasuries
 *  10. Seed menu items (3 per restaurant)
 *  11. Write deployment addresses to deployments/base-sepolia.json
 */
contract DeployiTake is Script {
    using stdJson for string;

    // =========================================================================
    // CONSTANTS — Base Sepolia
    // =========================================================================

    /// @notice Circle's official USDC on Base Sepolia
    address public constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    /// @notice Circle's EURC on Base Sepolia (for European orders)
    address public constant EURC_BASE_SEPOLIA = 0x808456652fdb597867f38412077A9182bf77359F;

    /// @notice jollyv.eth — protocol admin + treasury recipient
    address public constant JOLLYV_ETH = 0x2b30efBA367D669c9cd7723587346a79b67A42DB;

    // =========================================================================
    // RUN
    // =========================================================================

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Backend hot wallet granted RELAYER_ROLE on ReputationOracle.
        // Falls back to deployer if not set (dev convenience only — set in prod).
        address backendHotWallet = vm.envOr("BACKEND_HOT_WALLET", deployer);

        console.log("===========================================");
        console.log("  iTake Full Stack Deployment");
        console.log("  Network: Base Sepolia (84532)");
        console.log("===========================================");
        console.log("Deployer:         ", deployer);
        console.log("Backend wallet:   ", backendHotWallet);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ------------------------------------------------------------------
        // 1. GuildFactory — contains GuildDAO implementation
        // ------------------------------------------------------------------
        console.log("1. Deploying GuildFactory...");
        GuildFactory guildFactory = new GuildFactory();
        console.log("   GuildFactory:", address(guildFactory));

        // ------------------------------------------------------------------
        // 2. PaymentRouter — 5 args: usdc, protocolTreasury, resolverTreasury,
        //                            labsTreasury, admin
        // ------------------------------------------------------------------
        console.log("2. Deploying PaymentRouter...");
        PaymentRouter paymentRouter = new PaymentRouter(
            USDC_BASE_SEPOLIA,  // usdc
            JOLLYV_ETH,         // protocolTreasury
            JOLLYV_ETH,         // resolverTreasury
            JOLLYV_ETH,         // labsTreasury
            JOLLYV_ETH          // admin (DEFAULT_ADMIN_ROLE)
        );
        console.log("   PaymentRouter:", address(paymentRouter));

        // ------------------------------------------------------------------
        // 3. ReputationOracle — admin=deployer, relayer=backendHotWallet
        // ------------------------------------------------------------------
        console.log("3. Deploying ReputationOracle...");
        ReputationOracle reputationOracle = new ReputationOracle(
            deployer,         // admin (deployer during setup; transfer later)
            backendHotWallet  // relayer — backend service pushes scores here
        );
        console.log("   ReputationOracle:", address(reputationOracle));

        // ------------------------------------------------------------------
        // 4. DeliveryMissionFactory — usdc + paymentRouter
        //    (constructor also deploys DeliveryEscrow implementation)
        // ------------------------------------------------------------------
        console.log("4. Deploying DeliveryMissionFactory...");
        DeliveryMissionFactory deliveryMissionFactory = new DeliveryMissionFactory(
            address(paymentRouter)
        );
        console.log("   DeliveryMissionFactory:", address(deliveryMissionFactory));
        console.log("   DeliveryEscrow impl:   ", deliveryMissionFactory.deliveryEscrowImplementation());

        // ------------------------------------------------------------------
        // 5. DeliveriesDAO — insurance pool for delivery missions
        // ------------------------------------------------------------------
        console.log("5. Deploying DeliveriesDAO...");
        DeliveriesDAO deliveriesDAO = new DeliveriesDAO(USDC_BASE_SEPOLIA);
        console.log("   DeliveriesDAO:", address(deliveriesDAO));

        // ------------------------------------------------------------------
        // 6. iTake MetaDAO (0.5% platform fee)
        // ------------------------------------------------------------------
        console.log("6. Creating iTake MetaDAO...");
        (uint256 itakeId, address itakeAddress) = guildFactory.createMetaDAO(
            "iTake",    // name
            JOLLYV_ETH, // treasury
            50          // guildFeeBps (0.5%)
        );
        console.log("   iTake MetaDAO ID:  ", itakeId);
        console.log("   iTake Address:     ", itakeAddress);

        // ------------------------------------------------------------------
        // 7. AtobaDAO — portuguese restaurant SubDAO (2% fee)
        // ------------------------------------------------------------------
        console.log("7. Creating AtobaDAO Restaurant SubDAO...");
        (uint256 atobaId, address atobaAddress) = guildFactory.createSubDAO(
            "AtobaDAO",   // name (ASCII-safe)
            JOLLYV_ETH,   // treasury
            200,          // subDAOFeeBps (2%)
            itakeAddress, // parentMetaDAO
            50            // metaDAOFeeBps (0.5% to iTake)
        );
        console.log("   AtobaDAO ID:    ", atobaId);
        console.log("   AtobaDAO Addr:  ", atobaAddress);

        // ------------------------------------------------------------------
        // 8. LisboaCafe — cafe SubDAO (2.5% fee)
        // ------------------------------------------------------------------
        console.log("8. Creating LisboaCafe Restaurant SubDAO...");
        (uint256 lisboaId, address lisboaAddress) = guildFactory.createSubDAO(
            "LisboaCafe",  // name
            JOLLYV_ETH,    // treasury
            250,           // subDAOFeeBps (2.5%)
            itakeAddress,  // parentMetaDAO
            50             // metaDAOFeeBps (0.5% to iTake)
        );
        console.log("   LisboaCafe ID:  ", lisboaId);
        console.log("   LisboaCafe Addr:", lisboaAddress);

        // ------------------------------------------------------------------
        // 9. Register SubDAOs with iTake MetaDAO + set PaymentRouter treasuries
        // ------------------------------------------------------------------
        console.log("9. Registering SubDAOs + setting treasuries...");
        GuildDAO itakeDAO = GuildDAO(itakeAddress);
        itakeDAO.registerSubDAO(atobaAddress);
        itakeDAO.registerSubDAO(lisboaAddress);
        console.log("   SubDAOs registered with iTake MetaDAO");

        paymentRouter.setGuildTreasury(itakeAddress, JOLLYV_ETH);
        paymentRouter.setGuildTreasury(atobaAddress, JOLLYV_ETH);
        paymentRouter.setGuildTreasury(lisboaAddress, JOLLYV_ETH);
        console.log("   Treasuries set in PaymentRouter");

        // Whitelist EURC so European orders can pay in EURC
        paymentRouter.setAcceptedToken(EURC_BASE_SEPOLIA, true);
        console.log("   EURC whitelisted as accepted token");

        // Grant SETTLER_ROLE to DeliveryMissionFactory so it can settle payments
        bytes32 SETTLER_ROLE = paymentRouter.SETTLER_ROLE();
        paymentRouter.grantRole(SETTLER_ROLE, address(deliveryMissionFactory));
        console.log("   SETTLER_ROLE granted to DeliveryMissionFactory");

        // ------------------------------------------------------------------
        // 10. Seed menu items — 3 per restaurant (logged; stored off-chain)
        //     In production, menu items live in the backend DB (not on-chain).
        //     These console logs document the intended seed data.
        // ------------------------------------------------------------------
        console.log("10. Seeding menu items (off-chain, documented here)...");
        console.log("");
        console.log("   AtobaDAO Menu:");
        console.log("     - Francesinha (classic Porto sandwich)  | EUR 12.50 | category: mains");
        console.log("     - Bacalhau a Bras (salt cod with eggs)   | EUR 14.00 | category: mains");
        console.log("     - Pastel de Nata (custard tart)          | EUR  1.80 | category: desserts");
        console.log("");
        console.log("   LisboaCafe Menu:");
        console.log("     - Bifana (pork sandwich, Lisbon style)   | EUR  4.50 | category: sandwiches");
        console.log("     - Galao (espresso with foamed milk)      | EUR  1.50 | category: drinks");
        console.log("     - Tosta Mista (ham & cheese toast)       | EUR  3.00 | category: snacks");

        // ------------------------------------------------------------------
        // 11. Transfer ownerships to jollyv.eth
        // ------------------------------------------------------------------
        console.log("11. Transferring ownerships to jollyv.eth...");
        guildFactory.transferOwnership(JOLLYV_ETH);
        deliveryMissionFactory.transferOwnership(JOLLYV_ETH);
        deliveriesDAO.transferOwnership(JOLLYV_ETH);
        // PaymentRouter + ReputationOracle use AccessControl — admin role
        // is already on JOLLYV_ETH (PaymentRouter) / deployer (ReputationOracle).
        // Deployer can revoke own roles from gnosis safe after handoff.
        console.log("   Done");

        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        console.log("");
        console.log("===========================================");
        console.log("  ITAKE DEPLOYMENT COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Infrastructure:");
        console.log("  GuildFactory:            ", address(guildFactory));
        console.log("  PaymentRouter:            ", address(paymentRouter));
        console.log("  ReputationOracle:         ", address(reputationOracle));
        console.log("  DeliveryMissionFactory:   ", address(deliveryMissionFactory));
        console.log("  DeliveryEscrow (impl):    ", deliveryMissionFactory.deliveryEscrowImplementation());
        console.log("  DeliveriesDAO:            ", address(deliveriesDAO));
        console.log("");
        console.log("MetaDAO:");
        console.log("  iTake (fee 0.5%):  ", itakeAddress);
        console.log("");
        console.log("SubDAOs (Restaurants):");
        console.log("  AtobaDAO (fee 2%):", atobaAddress);
        console.log("  LisboaCafe (fee 2.5%):", lisboaAddress);
        console.log("");
        console.log("Fee Distribution (example $10 order):");
        console.log("  Protocol (2.5%): $0.25  Labs (2.5%): $0.25  Resolver (2%): $0.20");
        console.log("  iTake (0.5%):    $0.05  Restaurant (~2%): ~$0.20");
        console.log("  Performer (>90%): $9.05+");
        console.log("");
        console.log("UPDATE YOUR .env WITH THESE ADDRESSES!");
        console.log("Run: cat deployments/base-sepolia.json");

        // ------------------------------------------------------------------
        // Write deployments/base-sepolia.json
        // ------------------------------------------------------------------
        _writeDeployments(
            address(guildFactory),
            address(paymentRouter),
            address(reputationOracle),
            address(deliveryMissionFactory),
            deliveryMissionFactory.deliveryEscrowImplementation(),
            address(deliveriesDAO),
            itakeAddress,
            atobaAddress,
            lisboaAddress
        );
    }

    // =========================================================================
    // INTERNAL — write deployments JSON
    // =========================================================================

    function _writeDeployments(
        address guildFactory,
        address paymentRouter,
        address reputationOracle,
        address deliveryMissionFactory,
        address deliveryEscrowImpl,
        address deliveriesDAO,
        address itakeMetaDAO,
        address atobaDAO,
        address lisboaCafe
    ) internal {
        string memory json = string(abi.encodePacked(
            "{\n",
            '  "network": "base-sepolia",\n',
            '  "chainId": 84532,\n',
            '  "deployedAt": "2026-02-19",\n',
            '  "deployer": "', vm.toString(msg.sender), '",\n',
            '  "contracts": {\n',
            '    "GuildFactory": "',            vm.toString(guildFactory),            '",\n',
            '    "PaymentRouter": "',           vm.toString(paymentRouter),           '",\n',
            '    "ReputationOracle": "',        vm.toString(reputationOracle),        '",\n',
            '    "DeliveryMissionFactory": "',  vm.toString(deliveryMissionFactory),  '",\n',
            '    "DeliveryEscrowImpl": "',      vm.toString(deliveryEscrowImpl),      '",\n',
            '    "DeliveriesDAO": "',           vm.toString(deliveriesDAO),           '",\n',
            '    "iTakeMetaDAO": "',            vm.toString(itakeMetaDAO),            '",\n',
            '    "AtobaDAO": "',               vm.toString(atobaDAO),               '",\n',
            '    "LisboaCafe": "',             vm.toString(lisboaCafe),             '"\n',
            '  },\n',
            '  "seed": {\n',
            '    "AtobaDAO": {\n',
            '      "cuisineType": "portuguese",\n',
            '      "feesBps": 200,\n',
            '      "menuItems": [\n',
            '        { "name": "Francesinha", "category": "mains", "priceEuros": 12.50 },\n',
            '        { "name": "Bacalhau a Bras", "category": "mains", "priceEuros": 14.00 },\n',
            '        { "name": "Pastel de Nata", "category": "desserts", "priceEuros": 1.80 }\n',
            '      ]\n',
            '    },\n',
            '    "LisboaCafe": {\n',
            '      "cuisineType": "cafe",\n',
            '      "feesBps": 250,\n',
            '      "menuItems": [\n',
            '        { "name": "Bifana", "category": "sandwiches", "priceEuros": 4.50 },\n',
            '        { "name": "Galao", "category": "drinks", "priceEuros": 1.50 },\n',
            '        { "name": "Tosta Mista", "category": "snacks", "priceEuros": 3.00 }\n',
            '      ]\n',
            '    }\n',
            '  }\n',
            "}\n"
        ));

        // Ensure deployments directory exists (forge-std vm.writeFile creates parent dirs)
        vm.writeFile("deployments/base-sepolia.json", json);
        console.log("Written: deployments/base-sepolia.json");
    }
}
