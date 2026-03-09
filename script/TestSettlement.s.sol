// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";

/**
 * @title TestSettlement
 * @notice Runs a minimal end-to-end settleRestaurantOrder for demo/recording.
 *
 * Order: "Bacalhau a Bras" at AtobaDAO (test amounts)
 *   Food cost:     1.00 USDC  -> AtobaDAO restaurant treasury (direct)
 *   Delivery fee:  0.30 USDC  -> split through fee hierarchy:
 *     Courier (~90.5%):    0.2715 USDC -> TEST_COURIER
 *     AtobaDAO (2%):       0.0060 USDC -> AtobaDAO (marketplace cut)
 *     iTakeMetaDAO (0.5%): 0.0015 USDC -> iTakeMetaDAO
 *     Protocol (2.5%):     0.0075 USDC -> protocol treasury
 *     Labs (2.5%):         0.0075 USDC -> labs treasury
 *     Resolver (2%):       0.0060 USDC -> resolver treasury
 *   Total charged:  1.30 USDC
 *
 * Run:
 *   forge script script/TestSettlement.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast
 */
contract TestSettlement is Script {
    // =========================================================================
    // ADDRESSES - Base Sepolia
    // =========================================================================

    address constant PAYMENT_ROUTER = 0x3E9AC70d72F2cF10aD7511faABd3C913337bD101;
    // Accepted tokens (Base Sepolia)
    address constant USDC           = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant EURC           = 0x808456652fdb597867f38412077A9182bf77359F;
    address constant ITAKE_META_DAO = 0xD3eEd41E70ac3346F071C2163AaB6Effe03f1572;
    address constant ATOBA_DAO      = 0x5Fb9f9D04c40eaF8E405c0E6953609cC0793c7cc;

    // Test courier - separate address from deployer (simulates a real courier wallet)
    address constant TEST_COURIER   = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    // Order breakdown (6 decimals) — small test amounts to preserve testnet funds
    uint256 constant FOOD_COST     = 1_000_000; //  1.00 USDC -> restaurant (direct)
    uint256 constant DELIVERY_FEE  =   300_000; //  0.30 USDC -> courier + fees
    uint256 constant TOTAL_AMOUNT  = 1_300_000; //  1.30 USDC total

    // =========================================================================
    // RUN
    // =========================================================================

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        PaymentRouter router = PaymentRouter(PAYMENT_ROUTER);
        IERC20 usdc = IERC20(USDC);

        console.log("===========================================");
        console.log("  Horizon Protocol - Test Settlement");
        console.log("  Network: Base Sepolia (84532)");
        console.log("===========================================");
        console.log("Deployer:     ", deployer);
        console.log("PaymentRouter:", PAYMENT_ROUTER);
        console.log("Food cost:    1.00 USDC -> AtobaDAO (direct)");
        console.log("Delivery fee: 0.30 USDC -> courier + fees");
        console.log("Total:        1.30 USDC");
        console.log("Courier:      ", TEST_COURIER);
        console.log("AtobaDAO:     ", ATOBA_DAO);
        console.log("iTakeMetaDAO: ", ITAKE_META_DAO);

        vm.startBroadcast(deployerPrivateKey);

        // ------------------------------------------------------------------
        // Step 1: Grant SETTLER_ROLE to deployer
        //   Deployer holds DEFAULT_ADMIN_ROLE so this is permissionless.
        // ------------------------------------------------------------------
        bytes32 SETTLER_ROLE = keccak256("SETTLER_ROLE");
        router.grantRole(SETTLER_ROLE, deployer);
        console.log("\n[1/3] SETTLER_ROLE granted to deployer");

        // ------------------------------------------------------------------
        // Step 2: Fund PaymentRouter with 16.50 USDC (food + delivery)
        //   In production, MissionEscrow clones hold the payment.
        //   Here we simulate the escrow release directly.
        // ------------------------------------------------------------------
        usdc.transfer(PAYMENT_ROUTER, TOTAL_AMOUNT);
        console.log("[2/3] Transferred 1.30 USDC to PaymentRouter");

        // ------------------------------------------------------------------
        // Step 3: Settle with correct restaurant order split
        //   missionId = 2 (second iTake order)
        //   token = USDC (European order could use EURC instead)
        //   foodCost  = 1.00 USDC -> AtobaDAO restaurant treasury (direct)
        //   deliveryFee = 0.30 USDC -> courier ~90.5% + platform fees
        //   subDAOFeeBps = 200 (2% of delivery fee - AtobaDAO marketplace cut)
        //   metaDAOFeeBps = 50 (0.5% of delivery fee - iTake platform fee)
        // ------------------------------------------------------------------
        router.settleRestaurantOrder(
            2,              // missionId
            TEST_COURIER,   // performer (courier)
            USDC,           // token (USDC — swap to EURC for European orders)
            FOOD_COST,      // foodCost -> direct to restaurant
            DELIVERY_FEE,   // deliveryFee -> split through hierarchy
            ATOBA_DAO,      // restaurantDAO
            ITAKE_META_DAO, // metaDAO (iTake platform)
            200,            // subDAOFeeBps - 2% of delivery fee
            50              // metaDAOFeeBps - 0.5% of delivery fee
        );

        console.log("[3/3] settleRestaurantOrder executed!");
        console.log("\n===========================================");
        console.log("  Settlement complete. Payment distribution:");
        console.log("  AtobaDAO (food):     1.0000 USDC -> restaurant treasury (direct)");
        console.log("  Courier (~90.5%):    0.2715 USDC -> courier (of 0.30 delivery fee)");
        console.log("  AtobaDAO (2%):       0.0060 USDC -> restaurant (marketplace cut)");
        console.log("  iTakeMetaDAO (0.5%): 0.0015 USDC -> iTake platform");
        console.log("  Protocol (2.5%):     0.0075 USDC -> jollyv.eth treasury");
        console.log("  Labs (2.5%):         0.0075 USDC -> labs treasury");
        console.log("  Resolver (2%):       0.0060 USDC -> resolver treasury");
        console.log("===========================================");
        console.log("\n  Bookmark this tx on Basescan for the video:");
        console.log("  https://base-sepolia.basescan.org/address/", PAYMENT_ROUTER);

        vm.stopBroadcast();
    }
}
