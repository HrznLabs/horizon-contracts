// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HorizonToken} from "../src/token/HorizonToken.sol";
import {HorizonVesting} from "../src/token/HorizonVesting.sol";
import {sHRZNVault} from "../src/token/sHRZNVault.sol";
import {FeeDistributor} from "../src/token/FeeDistributor.sol";
import {HorizonTimelock} from "../src/token/HorizonTimelock.sol";
import {HorizonGovernor} from "../src/token/HorizonGovernor.sol";
import {BuybackExecutor} from "../src/token/BuybackExecutor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployToken
 * @notice Full deployment of Horizon Protocol M5 token economics stack on Base Sepolia
 * @dev Deploy: forge script script/DeployToken.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify
 *
 * Deployment order (solves chicken-and-egg vesting problem):
 *   1. HorizonToken — ADMIN receives 800M + 150M (team alloc) + 50M (advisor alloc)
 *   2. HorizonVesting (team)    — token=hrznToken, beneficiary=ADMIN, cliff=12mo, total=36mo
 *   3. HorizonVesting (advisors) — token=hrznToken, beneficiary=ADMIN, cliff=6mo,  total=24mo
 *   4. Transfer 150M HRZN from ADMIN to teamVesting contract
 *   5. Transfer  50M HRZN from ADMIN to advisorVesting contract
 *   6. HorizonTimelock + HorizonGovernor
 *   7. sHRZNVault
 *   8. FeeDistributor
 *   9. BuybackExecutor
 *  10. Grant DISTRIBUTOR_ROLE on sHRZNVault to FeeDistributor
 *  11. Write token-base-sepolia.json
 */
contract DeployToken is Script {
    // =========================================================================
    // CONSTANTS — Base Sepolia
    // =========================================================================

    /// @notice Circle's official USDC on Base Sepolia
    address public constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    /// @notice jollyv.eth — protocol admin + treasury recipient
    address public constant ADMIN = 0x2b30efBA367D669c9cd7723587346a79b67A42DB;

    // Vesting allocation amounts
    uint256 public constant TEAM_ALLOC    = 150_000_000 * 10 ** 18;
    uint256 public constant ADVISOR_ALLOC =  50_000_000 * 10 ** 18;

    // =========================================================================
    // RUN
    // =========================================================================

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("===========================================");
        console.log("  Horizon Token Economics Deployment");
        console.log("  Network: Base Sepolia (84532)");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("Admin:   ", ADMIN);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ------------------------------------------------------------------
        // 1. HorizonToken
        //    Mint all 1B HRZN: 800M → ADMIN (treasury), 150M → ADMIN (for team vesting),
        //    50M → ADMIN (for advisor vesting). We transfer to vesting contracts below.
        // ------------------------------------------------------------------
        console.log("1. Deploying HorizonToken...");
        HorizonToken hrznToken = new HorizonToken(
            ADMIN, // treasury: 800M
            ADMIN, // team alloc: 150M (held by ADMIN until transferred to vesting contract)
            ADMIN  // advisor alloc: 50M (held by ADMIN until transferred to vesting contract)
        );
        console.log("   HorizonToken:", address(hrznToken));
        console.log("   Total supply:", hrznToken.totalSupply());

        // ------------------------------------------------------------------
        // 2. HorizonVesting — Team (12mo cliff, 36mo total)
        //    Beneficiary = ADMIN multisig; will be transferred to actual team multisig post-deploy
        // ------------------------------------------------------------------
        console.log("2. Deploying team HorizonVesting (12mo cliff, 36mo total)...");
        HorizonVesting teamVesting = new HorizonVesting(
            address(hrznToken),   // token
            ADMIN,                // beneficiary — team multisig (update post-deploy)
            ADMIN,                // treasury — receives unvested tokens on revocation
            ADMIN,                // owner — can revoke
            uint64(block.timestamp),
            uint64(365 days),     // 12-month cliff
            uint64(3 * 365 days)  // 36-month total duration
        );
        console.log("   teamVesting:", address(teamVesting));

        // ------------------------------------------------------------------
        // 3. HorizonVesting — Advisors (6mo cliff, 24mo total)
        // ------------------------------------------------------------------
        console.log("3. Deploying advisor HorizonVesting (6mo cliff, 24mo total)...");
        HorizonVesting advisorVesting = new HorizonVesting(
            address(hrznToken),  // token
            ADMIN,               // beneficiary — advisor representative (update post-deploy)
            ADMIN,               // treasury
            ADMIN,               // owner
            uint64(block.timestamp),
            uint64(180 days),    // 6-month cliff
            uint64(2 * 365 days) // 24-month total duration
        );
        console.log("   advisorVesting:", address(advisorVesting));

        // ------------------------------------------------------------------
        // 4 & 5. Fund vesting contracts from ADMIN wallet
        // ------------------------------------------------------------------
        console.log("4. Funding vesting contracts from ADMIN...");
        IERC20(address(hrznToken)).transfer(address(teamVesting), TEAM_ALLOC);
        console.log("   Transferred 150M HRZN to teamVesting");

        IERC20(address(hrznToken)).transfer(address(advisorVesting), ADVISOR_ALLOC);
        console.log("   Transferred 50M HRZN to advisorVesting");

        // ------------------------------------------------------------------
        // 6. HorizonTimelock + HorizonGovernor
        // ------------------------------------------------------------------
        console.log("5. Deploying HorizonTimelock...");
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // address(0) = anyone can execute after timelock

        HorizonTimelock timelock = new HorizonTimelock(
            2 days,    // minDelay — 2-day execution delay
            proposers,
            executors,
            ADMIN      // admin — can update timelock parameters
        );
        console.log("   HorizonTimelock:", address(timelock));

        console.log("6. Deploying HorizonGovernor...");
        HorizonGovernor governor = new HorizonGovernor(
            IVotes(address(hrznToken)),
            timelock
        );
        console.log("   HorizonGovernor:", address(governor));

        // Grant PROPOSER_ROLE on timelock to governor so it can queue proposals
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        console.log("   PROPOSER_ROLE granted to governor on timelock");

        // ------------------------------------------------------------------
        // 7. sHRZNVault — ERC-4626 staking vault
        // ------------------------------------------------------------------
        console.log("7. Deploying sHRZNVault...");
        sHRZNVault vault = new sHRZNVault(
            address(hrznToken),
            USDC_BASE_SEPOLIA,
            ADMIN
        );
        console.log("   sHRZNVault:", address(vault));

        // ------------------------------------------------------------------
        // 8. FeeDistributor
        //    For testnet: use ADMIN as protocolTreasury and resolverPool
        // ------------------------------------------------------------------
        console.log("8. Deploying FeeDistributor...");
        FeeDistributor feeDistributor = new FeeDistributor(
            USDC_BASE_SEPOLIA,
            address(vault),
            ADMIN, // protocolTreasury
            ADMIN, // resolverPool
            ADMIN  // admin
        );
        console.log("   FeeDistributor:", address(feeDistributor));

        // ------------------------------------------------------------------
        // 9. BuybackExecutor
        //    For testnet: router/factory are placeholder (ADMIN) — no Aerodrome on testnet
        //    Call setRouter() before mainnet deployment
        // ------------------------------------------------------------------
        console.log("9. Deploying BuybackExecutor...");
        BuybackExecutor buyback = new BuybackExecutor(
            USDC_BASE_SEPOLIA,
            address(hrznToken),
            ADMIN, // router placeholder — update before mainnet via setRouter()
            ADMIN, // factory placeholder
            ADMIN  // admin
        );
        console.log("   BuybackExecutor:", address(buyback));

        // ------------------------------------------------------------------
        // 10. Grant DISTRIBUTOR_ROLE on sHRZNVault to FeeDistributor
        //     Required so FeeDistributor can call vault.notifyRewardAmount()
        // ------------------------------------------------------------------
        console.log("10. Granting DISTRIBUTOR_ROLE to FeeDistributor...");
        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(feeDistributor));
        console.log("    Done");

        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        console.log("");
        console.log("===========================================");
        console.log("  TOKEN DEPLOYMENT COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Token:");
        console.log("  HorizonToken:     ", address(hrznToken));
        console.log("");
        console.log("Vesting:");
        console.log("  TeamVesting:      ", address(teamVesting));
        console.log("  AdvisorVesting:   ", address(advisorVesting));
        console.log("");
        console.log("Governance:");
        console.log("  HorizonTimelock:  ", address(timelock));
        console.log("  HorizonGovernor:  ", address(governor));
        console.log("");
        console.log("Staking / Fees:");
        console.log("  sHRZNVault:       ", address(vault));
        console.log("  FeeDistributor:   ", address(feeDistributor));
        console.log("  BuybackExecutor:  ", address(buyback));
        console.log("");
        console.log("POST-DEPLOY TODO:");
        console.log("  - Update BuybackExecutor.setRouter() with real Aerodrome address (mainnet)");
        console.log("  - Transfer teamVesting beneficiary to actual team multisig");
        console.log("  - Transfer advisorVesting beneficiary to advisor representative");
        console.log("  - Set HRZN token on PaymentRouter via PaymentRouter.setHRZNToken()");
        console.log("  - Set sHRZNVault on guild DAOs via GuildDAO.setSHrznVault()");
        console.log("  - Written: deployments/token-base-sepolia.json");

        // ------------------------------------------------------------------
        // 11. Write deployment output
        // ------------------------------------------------------------------
        string memory json = string(abi.encodePacked(
            "{\n",
            '  "network": "base-sepolia",\n',
            '  "chainId": 84532,\n',
            '  "deployedAt": "2026-02-20",\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "HorizonToken": "',    vm.toString(address(hrznToken)),    '",\n',
            '  "TeamVesting": "',     vm.toString(address(teamVesting)),   '",\n',
            '  "AdvisorVesting": "',  vm.toString(address(advisorVesting)),'",\n',
            '  "sHRZNVault": "',      vm.toString(address(vault)),         '",\n',
            '  "FeeDistributor": "',  vm.toString(address(feeDistributor)),'",\n',
            '  "HorizonTimelock": "', vm.toString(address(timelock)),      '",\n',
            '  "HorizonGovernor": "', vm.toString(address(governor)),      '",\n',
            '  "BuybackExecutor": "', vm.toString(address(buyback)),       '"\n',
            "}\n"
        ));

        // vm.writeFile written manually — see deployments/token-base-sepolia.json
        console.log("Deployment JSON (copy to deployments/token-base-sepolia.json):");
        console.log(json);
    }
}
