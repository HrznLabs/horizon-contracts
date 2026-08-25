// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/token/FeeDistributor.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVault is IsHRZNVault {
    function notifyRewardAmount(uint256) external {}
    function totalSupply() external view returns (uint256) { return 0; }
}

contract FeeDistributorStaleVolumePoC is Test {
    FeeDistributor distributor;
    MockUSDC usdc;
    MockVault vault;

    address admin = address(0x1);
    address treasury = address(0x2);
    address resolver = address(0x3);
    address guildA = address(0x4);
    address guildB = address(0x5);

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockVault();

        vm.startPrank(admin);
        distributor = new FeeDistributor(
            address(usdc),
            address(vault),
            treasury,
            resolver,
            admin
        );
        distributor.grantRole(distributor.VOLUME_RECORDER_ROLE(), admin);
        vm.stopPrank();

        usdc.mint(treasury, 1_000_000 * 1e6);
        vm.prank(treasury);
        usdc.approve(address(distributor), type(uint256).max);
    }

    function test_Sentinel_FeeDistributor_StaleVolume() public {
        vm.startPrank(admin);

        // 1. Register guildA and record volume
        distributor.registerGuild(guildA);
        distributor.recordGuildVolume(guildA, 100);

        // 2. Remove guildA. Its volume (100) is left behind, and totalGuildVolume remains 100.
        distributor.removeGuild(guildA);

        // 3. Register guildB and record volume 100.
        // totalGuildVolume becomes 200, but only guildB is registered.
        distributor.registerGuild(guildB);
        distributor.recordGuildVolume(guildB, 100);

        // 4. Distribute fees. 10_000 total -> 3_000 for guilds.
        // guildB gets (3_000 * 100) / 200 = 1,500 USDC.
        // The remaining 1,500 USDC is stuck in the contract.
        skip(distributor.MIN_PERIOD() + 1);
        distributor.distribute(10_000);

        assertEq(usdc.balanceOf(guildB), 1500, "Guild B should only get half due to stale volume");
        assertEq(usdc.balanceOf(address(distributor)), 1500, "1500 USDC stuck in contract");

        // 5. In the next period, guildB is still registered. Let's register guildA again.
        distributor.registerGuild(guildA);

        // At this point, distribute() resets totalGuildVolume to 0,
        // and loop resets guildVolume for all CURRENTLY registered guilds (guildB).
        // BUT guildA was NOT in the array during distribute(), so its guildVolume is STILL 100!
        assertEq(distributor.guildVolume(guildA), 100, "Guild A retains its stale volume of 100");

        // Let's add new volume for guild B
        distributor.recordGuildVolume(guildB, 50); // totalGuildVolume = 50

        // Distribute fees again.
        // guildA's share: (3000 * 100) / 50 = 6000 USDC.
        // This will revert because the contract tries to pay out more than it pulled from treasury for guilds (3000)
        skip(distributor.MIN_PERIOD() + 1);

        vm.expectRevert();
        distributor.distribute(10_000); // Fails due to insufficient USDC for treasury/resolver portions, as it overpaid guilds

        vm.stopPrank();
    }
}
