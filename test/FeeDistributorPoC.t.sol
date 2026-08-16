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

contract FeeDistributorPoC is Test {
    FeeDistributor distributor;
    MockUSDC usdc;
    MockVault vault;

    address admin = address(0x1);
    address treasury = address(0x2);
    address resolverPool = address(0x3);
    address volumeRecorder = address(0x4);

    address guildA = address(0xA);
    address guildB = address(0xB);

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockVault();

        distributor = new FeeDistributor(
            address(usdc),
            address(vault),
            treasury,
            resolverPool,
            admin
        );

        vm.startPrank(admin);
        distributor.grantRole(distributor.VOLUME_RECORDER_ROLE(), volumeRecorder);
        distributor.registerGuild(guildA);
        distributor.registerGuild(guildB);
        vm.stopPrank();

        usdc.mint(treasury, 10000e6);
        vm.prank(treasury);
        usdc.approve(address(distributor), type(uint256).max);
    }

    function test_StuckFundsOnGuildRemoval() public {
        // Record volume for both guilds
        vm.startPrank(volumeRecorder);
        distributor.recordGuildVolume(guildA, 100e6);
        distributor.recordGuildVolume(guildB, 100e6);
        vm.stopPrank();

        // Remove guild A before distribution
        vm.prank(admin);
        distributor.removeGuild(guildA);

        uint256 balanceBefore = usdc.balanceOf(address(distributor));

        // Warp to allow distribution
        vm.warp(block.timestamp + 8 days);

        // Distribute 1000 USDC
        vm.prank(admin);
        distributor.distribute(1000e6);

        uint256 balanceAfter = usdc.balanceOf(address(distributor));

        // guildTotal is 30% of 1000 = 300.
        // Guild B has 100 volume out of 200 total volume.
        // Guild B gets 150.
        // Guild A is removed, so its 150 is not distributed.
        // Contract should have 150 USDC stuck inside.
        assertEq(balanceAfter - balanceBefore, 150e6, "Funds are stuck in the contract!");

        // Wait, the next distribution loop clears guildVolume based on the `guilds` array!
        // Guild A was removed, so its volume is NEVER CLEARED!
        // Next period, totalGuildVolume starts at 0.
        // Wait, in `distribute`:
        // totalGuildVolume = 0;
        // The totalGuildVolume is reset to 0. But guildA's volume in `guildVolume` mapping is NOT cleared!
        // If guildA is re-registered later, or if we just check its mapping, it still has 100e6 volume.
        // But since totalGuildVolume is reset to 0, it doesn't immediately break things, unless it's re-registered.
    }
}
