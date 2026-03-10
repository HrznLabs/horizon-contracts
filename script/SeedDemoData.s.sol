// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console, stdJson} from "forge-std/Script.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {GuildFactory} from "../src/GuildFactory.sol";
import {ReputationOracle} from "../src/ReputationOracle.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SeedDemoData
 * @notice Seeds Base Sepolia with demo data: guilds, missions (USDC + EURC), reputation
 * @dev Requires three private keys in .env:
 *      - DEPLOYER_PRIVATE_KEY: has DEFAULT_ADMIN_ROLE on ReputationOracle
 *      - DEMO_WALLET_PRIVATE_KEY: jollyv.eth wallet that funds missions (has USDC + EURC)
 *      - DEMO_PERFORMER_PRIVATE_KEY: generated wallet to accept/submit missions
 *
 *      Budget (jollyv.eth balances: 8.33 USDC + 18.00 EURC):
 *        USDC: 4 open (0.5+1.0+1.5+2.0=5.0) + 2 completed (0.5+1.0=1.5) = 6.5 total
 *        EURC: 4 open (1.0+2.0+3.0+5.0=11.0) + 2 completed (1.0+1.5=2.5) = 13.5 total
 *
 *      Run: forge script script/SeedDemoData.s.sol --rpc-url base-sepolia --broadcast
 */
contract SeedDemoData is Script {
    using stdJson for string;

    // ── Token addresses (Base Sepolia) ──
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant EURC = 0x808456652fdb597867f38412077A9182bf77359F;

    // ── Deployed contract addresses (multi-token deployment) ──
    address constant GUILD_FACTORY = 0xba27678a8A5788D9d9EFfD38CE25c44CcD041388;
    address constant MISSION_FACTORY = 0x422b171Aa7cbCBe49Af1671E6A6ed2873B8f328f;
    address constant REPUTATION_ORACLE = 0xfe38E054FFe6A1784DA68f0e78A52655eF11E9B9;

    // ── Structs for JSON output ──
    struct OutputGuild {
        uint256 onChainId;
        address contractAddress;
        string name;
    }

    struct OutputMission {
        uint256 onChainId;
        address escrowAddress;
        string state;
        string token;
        string reward;
    }

    function run() external {
        // ── Load env keys ──
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        uint256 demoPk = vm.envUint("DEMO_WALLET_PRIVATE_KEY");
        address demoWallet = vm.addr(demoPk);

        uint256 performerPk = vm.envUint("DEMO_PERFORMER_PRIVATE_KEY");
        address performer = vm.addr(performerPk);

        console.log("===========================================");
        console.log("  Horizon Protocol - Demo Data Seed");
        console.log("  USDC + EURC | 8 Open + 4 Completed");
        console.log("===========================================");
        console.log("Deployer  :", deployer);
        console.log("DemoWallet:", demoWallet);
        console.log("Performer :", performer);
        console.log("");

        GuildFactory guildFactory = GuildFactory(GUILD_FACTORY);
        MissionFactory missionFactory = MissionFactory(MISSION_FACTORY);
        ReputationOracle repOracle = ReputationOracle(REPUTATION_ORACLE);

        // ═══════════════════════════════════════════════════════════════
        // PHASE 1: Admin actions — guilds + reputation (deployer)
        // ═══════════════════════════════════════════════════════════════
        vm.startBroadcast(deployerPk);

        // Grant RELAYER_ROLE to deployer if needed
        bytes32 relayerRole = repOracle.RELAYER_ROLE();
        if (!repOracle.hasRole(relayerRole, deployer)) {
            repOracle.grantRole(relayerRole, deployer);
            console.log("Granted RELAYER_ROLE to deployer");
        }

        // Create 2 guilds
        (uint256 guild1Id, address guild1Addr) = guildFactory.createGuild(
            "HorizonFreelancers", demoWallet, 250 // 2.5% fee
        );
        (uint256 guild2Id, address guild2Addr) = guildFactory.createGuild(
            "LisbonCreatives", demoWallet, 200 // 2.0% fee
        );
        console.log("Guilds:", guild1Addr, guild2Addr);

        // Set reputation scores
        repOracle.updateGlobalScore(demoWallet, 900); // Diamond
        repOracle.updateScore(demoWallet, guild1Addr, 900);
        repOracle.updateScore(demoWallet, guild2Addr, 900);
        repOracle.updateGlobalScore(performer, 650); // Gold

        console.log("Reputation: demo=900 Diamond, performer=650 Gold");

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════════
        // PHASE 2: Demo wallet creates 12 missions (USDC + EURC)
        // ═══════════════════════════════════════════════════════════════
        vm.startBroadcast(demoPk);

        IERC20(USDC).approve(address(missionFactory), type(uint256).max);
        IERC20(EURC).approve(address(missionFactory), type(uint256).max);

        uint256 expiry = block.timestamp + 30 days;
        bytes32 emptyHash = bytes32(0);

        OutputMission[] memory out = new OutputMission[](12);
        uint256 idx = 0;

        // ── 4 Open USDC ──
        uint256 id = missionFactory.createMission(USDC, 0.5e6, expiry, guild1Addr, emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Open", "USDC", "0.5");

        id = missionFactory.createMission(USDC, 1.0e6, expiry, address(0), emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Open", "USDC", "1.0");

        id = missionFactory.createMission(USDC, 1.5e6, expiry, guild2Addr, emptyHash, emptyHash, 200);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Open", "USDC", "1.5");

        id = missionFactory.createMission(USDC, 2.0e6, expiry, address(0), emptyHash, emptyHash, 200);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Open", "USDC", "2.0");

        // ── 4 Open EURC ──
        id = missionFactory.createMission(EURC, 1.0e6, expiry, guild1Addr, emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Open", "EURC", "1.0");

        id = missionFactory.createMission(EURC, 2.0e6, expiry, address(0), emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Open", "EURC", "2.0");

        id = missionFactory.createMission(EURC, 3.0e6, expiry, guild2Addr, emptyHash, emptyHash, 200);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Open", "EURC", "3.0");

        id = missionFactory.createMission(EURC, 5.0e6, expiry, address(0), emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Open", "EURC", "5.0");

        // ── 2 Completed USDC ──
        uint256 compStart = idx;

        id = missionFactory.createMission(USDC, 0.5e6, expiry, guild1Addr, emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Completed", "USDC", "0.5");

        id = missionFactory.createMission(USDC, 1.0e6, expiry, address(0), emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Completed", "USDC", "1.0");

        // ── 2 Completed EURC ──
        id = missionFactory.createMission(EURC, 1.0e6, expiry, guild2Addr, emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Completed", "EURC", "1.0");

        id = missionFactory.createMission(EURC, 1.5e6, expiry, address(0), emptyHash, emptyHash, 0);
        out[idx++] = OutputMission(id, missionFactory.missions(id), "Completed", "EURC", "1.5");

        vm.stopBroadcast();
        console.log("Created 12 missions (8 Open + 4 to-Complete)");

        // ═══════════════════════════════════════════════════════════════
        // PHASE 3: Performer accepts + submits proof on completed missions
        // ═══════════════════════════════════════════════════════════════
        vm.startBroadcast(performerPk);
        for (uint256 i = compStart; i < 12; i++) {
            IMissionEscrow(out[i].escrowAddress).acceptMission();
            IMissionEscrow(out[i].escrowAddress).submitProof(emptyHash);
        }
        vm.stopBroadcast();
        console.log("Performer accepted + submitted 4 missions");

        // ═══════════════════════════════════════════════════════════════
        // PHASE 4: Demo wallet approves completion (real settlement)
        // ═══════════════════════════════════════════════════════════════
        vm.startBroadcast(demoPk);
        for (uint256 i = compStart; i < 12; i++) {
            IMissionEscrow(out[i].escrowAddress).approveCompletion();
        }
        vm.stopBroadcast();
        console.log("4 missions completed - real settlement triggered");

        // ═══════════════════════════════════════════════════════════════
        // PHASE 5: Write output JSON
        // ═══════════════════════════════════════════════════════════════
        OutputGuild[] memory outGuilds = new OutputGuild[](2);
        outGuilds[0] = OutputGuild(guild1Id, guild1Addr, "HorizonFreelancers");
        outGuilds[1] = OutputGuild(guild2Id, guild2Addr, "LisbonCreatives");

        _writeOutputJson(demoWallet, performer, outGuilds, out);

        console.log("");
        console.log("===========================================");
        console.log("  DEMO SEED COMPLETE");
        console.log("  Output: deployments/demo-seed-output.json");
        console.log("===========================================");
    }

    function _writeOutputJson(
        address demoWallet,
        address performerWallet,
        OutputGuild[] memory guilds,
        OutputMission[] memory missions
    ) internal {
        string memory root = "root";
        vm.serializeAddress(root, "demoWallet", demoWallet);
        vm.serializeAddress(root, "performerWallet", performerWallet);

        string memory guildsArr = "[";
        for (uint256 i = 0; i < guilds.length; i++) {
            string memory g = "g";
            vm.serializeUint(g, "onChainId", guilds[i].onChainId);
            vm.serializeString(g, "name", guilds[i].name);
            string memory gJson = vm.serializeAddress(g, "contractAddress", guilds[i].contractAddress);
            guildsArr = string.concat(guildsArr, gJson);
            if (i < guilds.length - 1) guildsArr = string.concat(guildsArr, ",");
        }
        guildsArr = string.concat(guildsArr, "]");
        vm.serializeString(root, "guilds", guildsArr);

        string memory missArr = "[";
        for (uint256 i = 0; i < missions.length; i++) {
            string memory m = "m";
            vm.serializeUint(m, "onChainId", missions[i].onChainId);
            vm.serializeAddress(m, "escrowAddress", missions[i].escrowAddress);
            vm.serializeString(m, "state", missions[i].state);
            vm.serializeString(m, "token", missions[i].token);
            string memory mJson = vm.serializeString(m, "reward", missions[i].reward);
            missArr = string.concat(missArr, mJson);
            if (i < missions.length - 1) missArr = string.concat(missArr, ",");
        }
        missArr = string.concat(missArr, "]");

        string memory finalJson = vm.serializeString(root, "missions", missArr);
        vm.writeJson(finalJson, "deployments/demo-seed-output.json");
    }
}
