// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {DeliveriesDAO} from "../src/DeliveriesDAO.sol";

/**
 * @title TransferOwnership
 * @notice Transfer ownership of deployed contracts to jollyv.eth
 * @dev Run with: forge script script/TransferOwnership.s.sol:TransferOwnership --rpc-url $BASE_RPC_URL --broadcast
 */
contract TransferOwnership is Script {
    // Deployed contract addresses on Base Sepolia
    address constant DELIVERY_FACTORY = 0xa38E26D6BF038bC1572A6FC302C590595186cf34;
    address constant DELIVERIES_DAO = 0x6474dbB832445B78f16cE3ab81fE9D8Cad0C2BE2;
    
    // jollyv.eth address
    address constant NEW_OWNER = 0x2b30efBA367D669c9cd7723587346a79b67A42DB;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Transferring ownership of contracts...");
        console.log("Current owner:", deployer);
        console.log("New owner (jollyv.eth):", NEW_OWNER);

        vm.startBroadcast(deployerPrivateKey);

        // Transfer DeliveryMissionFactory ownership
        console.log("\n1. Transferring DeliveryMissionFactory ownership...");
        DeliveryMissionFactory factory = DeliveryMissionFactory(DELIVERY_FACTORY);
        factory.transferOwnership(NEW_OWNER);
        console.log("DeliveryMissionFactory ownership transferred");

        // Transfer DeliveriesDAO ownership
        console.log("\n2. Transferring DeliveriesDAO ownership...");
        DeliveriesDAO dao = DeliveriesDAO(DELIVERIES_DAO);
        dao.transferOwnership(NEW_OWNER);
        console.log("DeliveriesDAO ownership transferred");

        vm.stopBroadcast();

        console.log("\n=== Ownership Transfer Complete ===");
        console.log("All contracts now owned by:", NEW_OWNER);
        console.log("\nVerify on Basescan:");
        console.log("DeliveryMissionFactory:", DELIVERY_FACTORY);
        console.log("DeliveriesDAO:", DELIVERIES_DAO);
    }
}
