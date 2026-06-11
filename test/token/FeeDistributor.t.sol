// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../src/token/HorizonToken.sol";
import "../../src/token/sHRZNVault.sol";
import "../../src/token/FeeDistributor.sol";
import "../../test/mocks/MockERC20.sol";

contract FeeDistributorTest is Test {
    HorizonToken hrzn;
    sHRZNVault vault;
    FeeDistributor distributor;
    MockERC20 usdc;

    address treasury = makeAddr("treasury");
    address resolverPool = makeAddr("resolverPool");
    address admin = makeAddr("admin");
    address guild1 = makeAddr("guild1");
    address guild2 = makeAddr("guild2");
    address teamV = makeAddr("teamV");
    address advisorV = makeAddr("advisorV");
    address staker = makeAddr("staker");

    uint256 constant DISTRIBUTE_AMOUNT = 10_000e6; // 10,000 USDC

    function setUp() public {
        hrzn = new HorizonToken(treasury, teamV, advisorV);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new sHRZNVault(address(hrzn), address(usdc), admin);

        distributor = new FeeDistributor(
            address(usdc),
            address(vault),
            treasury,
            resolverPool,
            admin
        );

        // Grant DISTRIBUTOR_ROLE on vault to FeeDistributor
        bytes32 distributorRole = vault.DISTRIBUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(distributorRole, address(distributor));

        // Register guilds
        vm.prank(admin);
        distributor.registerGuild(guild1);
        vm.prank(admin);
        distributor.registerGuild(guild2);

        // Stake some HRZN so vault has supply (needed for notifyRewardAmount)
        vm.prank(treasury);
        hrzn.transfer(staker, 1000e18);
        vm.prank(staker);
        hrzn.approve(address(vault), 1000e18);
        vm.prank(staker);
        vault.deposit(1000e18, staker);

        // Mint USDC to treasury and approve distributor
        usdc.mint(treasury, DISTRIBUTE_AMOUNT * 10);
        vm.prank(treasury);
        usdc.approve(address(distributor), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Split math
    // -------------------------------------------------------------------------

    function test_Distribute_SplitsCorrectly() public {
        // Record some guild volumes
        bytes32 volumeRole = distributor.VOLUME_RECORDER_ROLE();
        vm.prank(admin);
        distributor.grantRole(volumeRole, admin);

        vm.prank(admin);
        distributor.recordGuildVolume(guild1, 7000e6); // 70%
        vm.prank(admin);
        distributor.recordGuildVolume(guild2, 3000e6); // 30%

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 resolverBefore = usdc.balanceOf(resolverPool);

        vm.prank(admin);
        distributor.distribute(DISTRIBUTE_AMOUNT);

        // Staker amount: 40% = 4000 USDC
        assertApproxEqAbs(usdc.balanceOf(address(vault)), 4000e6, 1e3);
        // Guild1: 30% * 70% = 21% = 2100 USDC
        assertApproxEqAbs(usdc.balanceOf(guild1), 2100e6, 1e3);
        // Guild2: 30% * 30% = 9% = 900 USDC
        assertApproxEqAbs(usdc.balanceOf(guild2), 900e6, 1e3);
        // Treasury: 20% = 2000 USDC (treasury sent 10000, received 2000 back, net -8000)
        // treasuryBefore - DISTRIBUTE_AMOUNT + 2000 = treasuryBefore - 8000
        assertApproxEqAbs(usdc.balanceOf(treasury), treasuryBefore - DISTRIBUTE_AMOUNT + 2000e6, 1e3);
        // Resolver: 10% = 1000 USDC
        assertApproxEqAbs(usdc.balanceOf(resolverPool), resolverBefore + 1000e6, 1e3);
    }

    function test_Distribute_ResetsGuildVolume() public {
        bytes32 volumeRole = distributor.VOLUME_RECORDER_ROLE();
        vm.prank(admin);
        distributor.grantRole(volumeRole, admin);
        vm.prank(admin);
        distributor.recordGuildVolume(guild1, 5000e6);

        vm.prank(admin);
        distributor.distribute(DISTRIBUTE_AMOUNT);

        assertEq(distributor.guildVolume(guild1), 0);
        assertEq(distributor.totalGuildVolume(), 0);
    }

    function test_Distribute_TooSoon_Reverts() public {
        vm.prank(admin);
        distributor.distribute(DISTRIBUTE_AMOUNT);

        vm.prank(admin);
        vm.expectRevert("FeeDistributor: too soon");
        distributor.distribute(DISTRIBUTE_AMOUNT);
    }

    function test_Distribute_AfterMinPeriod_Succeeds() public {
        vm.prank(admin);
        distributor.distribute(DISTRIBUTE_AMOUNT);

        vm.warp(block.timestamp + 7 days);

        vm.prank(admin);
        distributor.distribute(DISTRIBUTE_AMOUNT);
    }

    function test_Distribute_NonAdmin_Reverts() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert();
        distributor.distribute(DISTRIBUTE_AMOUNT);
    }

    function test_Distribute_NoGuildVolume_GuildPortionToTreasury() public {
        // No volume recorded — guild portion should go to treasury instead
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(admin);
        distributor.distribute(DISTRIBUTE_AMOUNT);

        // Treasury should receive 20% (own share) + 30% (guild fallback) = 50%
        uint256 expectedTreasuryReceived = 5000e6;
        assertApproxEqAbs(usdc.balanceOf(treasury), treasuryBefore - DISTRIBUTE_AMOUNT + expectedTreasuryReceived, 1e3);
    }

    // -------------------------------------------------------------------------
    // Guild management
    // -------------------------------------------------------------------------

    function test_RegisterGuild_Twice_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("FeeDistributor: already registered");
        distributor.registerGuild(guild1);
    }

    function test_RemoveGuild_Deregisters() public {
        vm.prank(admin);
        distributor.removeGuild(guild1);
        assertFalse(distributor.isRegistered(guild1));
        assertEq(distributor.guildCount(), 1); // only guild2 remains
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    function testFuzz_SplitAlwaysSums(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        usdc.mint(treasury, amount);
        vm.prank(treasury);
        usdc.approve(address(distributor), amount);

        vm.prank(admin);
        distributor.distribute(amount);

        // Staker share: 40%
        uint256 stakers = (amount * 4000) / 10_000;
        // Resolver: remainder (avoids rounding issues)
        // Just verify no USDC is stuck in the contract
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }
}
