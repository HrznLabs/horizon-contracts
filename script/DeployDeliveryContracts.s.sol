// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {DeliveriesDAO} from "../src/DeliveriesDAO.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";

/**
 * @title DeployDeliveryContracts
 * @notice Deployment script for delivery mission contracts
 * @dev Run with: forge script script/DeployDeliveryContracts.s.sol:DeployDeliveryContracts --rpc-url $BASE_RPC_URL --broadcast --verify
 */
contract DeployDeliveryContracts is Script {
    // Base Sepolia USDC address
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    // Existing PaymentRouter on Base Sepolia (from previous deployment)
    address constant PAYMENT_ROUTER = 0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying delivery contracts to Base Sepolia...");
        console.log("Deployer:", deployer);
        console.log("USDC:", USDC);
        console.log("PaymentRouter:", PAYMENT_ROUTER);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy DeliveryMissionFactory
        console.log("\n1. Deploying DeliveryMissionFactory...");
        DeliveryMissionFactory deliveryFactory = new DeliveryMissionFactory(
            PAYMENT_ROUTER
        );
        console.log("DeliveryMissionFactory deployed at:", address(deliveryFactory));
        console.log("DeliveryEscrow implementation at:", deliveryFactory.deliveryEscrowImplementation());

        // Deploy DeliveriesDAO
        console.log("\n2. Deploying DeliveriesDAO...");
        DeliveriesDAO deliveriesDAO = new DeliveriesDAO(USDC);
        console.log("DeliveriesDAO deployed at:", address(deliveriesDAO));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("DeliveryMissionFactory:", address(deliveryFactory));
        console.log("DeliveryEscrow Implementation:", deliveryFactory.deliveryEscrowImplementation());
        console.log("DeliveriesDAO:", address(deliveriesDAO));
        console.log("\nVerify contracts on Basescan:");
        console.log("https://sepolia.basescan.org/address/%s", address(deliveryFactory));
        console.log("https://sepolia.basescan.org/address/%s", deliveryFactory.deliveryEscrowImplementation());
        console.log("https://sepolia.basescan.org/address/%s", address(deliveriesDAO));
    }
}
