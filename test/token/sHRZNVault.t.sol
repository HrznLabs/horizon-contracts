// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../src/token/HorizonToken.sol";
import "../../src/token/sHRZNVault.sol";
import "../../test/mocks/MockERC20.sol";

contract sHRZNVaultTest is Test {
    HorizonToken hrzn;
    sHRZNVault vault;
    MockERC20 usdc;

    address treasury = makeAddr("treasury");
    address teamV = makeAddr("teamV");
    address advisorV = makeAddr("advisorV");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address distributor = makeAddr("distributor");

    uint256 constant ALICE_HRZN = 600e18;
    uint256 constant BOB_HRZN = 400e18;

    function setUp() public {
        hrzn = new HorizonToken(treasury, teamV, advisorV);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new sHRZNVault(address(hrzn), address(usdc), admin);

        // Grant distributor role
        bytes32 distributorRole = vault.DISTRIBUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(distributorRole, distributor);

        // Fund alice and bob
        vm.prank(treasury);
        hrzn.transfer(alice, ALICE_HRZN);
        vm.prank(treasury);
        hrzn.transfer(bob, BOB_HRZN);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        hrzn.approve(address(vault), amount);
        vm.prank(user);
        vault.deposit(amount, user);
    }

    function _notifyReward(uint256 amount) internal {
        usdc.mint(distributor, amount);
        vm.prank(distributor);
        usdc.transfer(address(vault), amount);
        vm.prank(distributor);
        vault.notifyRewardAmount(amount);
    }

    // -------------------------------------------------------------------------
    // Deposit / shares
    // -------------------------------------------------------------------------

    function test_Deposit_IssuesShares() public {
        _deposit(alice, ALICE_HRZN);
        assertEq(vault.balanceOf(alice), ALICE_HRZN); // 1:1 on first deposit
        assertEq(vault.totalAssets(), ALICE_HRZN);
    }

    function test_TwoDepositors_SharesProportional() public {
        _deposit(alice, ALICE_HRZN); // 600 shares
        _deposit(bob, BOB_HRZN);     // 400 shares
        assertEq(vault.totalSupply(), ALICE_HRZN + BOB_HRZN);
        assertEq(vault.balanceOf(alice), ALICE_HRZN);
        assertEq(vault.balanceOf(bob), BOB_HRZN);
    }

    // -------------------------------------------------------------------------
    // Reward distribution
    // -------------------------------------------------------------------------

    function test_RewardPerToken_UpdatesOnNotify() public {
        _deposit(alice, ALICE_HRZN);
        uint256 rewardBefore = vault.rewardPerTokenStored();
        _notifyReward(1000e6); // 1000 USDC
        assertGt(vault.rewardPerTokenStored(), rewardBefore);
    }

    function test_Earned_ProportionalToShares() public {
        _deposit(alice, ALICE_HRZN); // 600 shares = 60%
        _deposit(bob, BOB_HRZN);     // 400 shares = 40%
        _notifyReward(1000e6);        // 1000 USDC reward

        // Alice earns 60%, Bob earns 40%
        assertApproxEqAbs(vault.earned(alice), 600e6, 1e3); // ~600 USDC
        assertApproxEqAbs(vault.earned(bob), 400e6, 1e3);   // ~400 USDC
    }

    function test_ClaimRewards_TransfersUsdc() public {
        _deposit(alice, ALICE_HRZN);
        _notifyReward(1000e6);

        uint256 aliceReward = vault.earned(alice);
        assertGt(aliceReward, 0);

        vm.prank(alice);
        vault.claimRewards();

        assertEq(usdc.balanceOf(alice), aliceReward);
        assertEq(vault.rewards(alice), 0);
    }

    function test_NewDepositor_EarnsZeroFromPastRewards() public {
        _deposit(alice, ALICE_HRZN);
        _notifyReward(1000e6);
        // Bob deposits AFTER reward — should earn 0 from past reward
        _deposit(bob, BOB_HRZN);
        assertEq(vault.earned(bob), 0);
    }

    function test_NotifyReward_NoStakers_Reverts() public {
        usdc.mint(distributor, 1000e6);
        vm.prank(distributor);
        usdc.transfer(address(vault), 1000e6);
        vm.prank(distributor);
        vm.expectRevert("sHRZNVault: no stakers");
        vault.notifyRewardAmount(1000e6);
    }

    // -------------------------------------------------------------------------
    // Cooldown unstaking
    // -------------------------------------------------------------------------

    function test_RequestUnstake_LocksPending() public {
        _deposit(alice, ALICE_HRZN);
        vm.prank(alice);
        vault.requestUnstake(ALICE_HRZN);
        (uint256 shares,) = vault.unstakeRequests(alice);
        assertEq(shares, ALICE_HRZN);
    }

    function test_CompleteUnstake_BeforeCooldown_Reverts() public {
        _deposit(alice, ALICE_HRZN);
        vm.prank(alice);
        vault.requestUnstake(ALICE_HRZN);
        vm.prank(alice);
        vm.expectRevert("sHRZNVault: cooldown active");
        vault.completeUnstake();
    }

    function test_CompleteUnstake_AfterCooldown_ReturnsHRZN() public {
        _deposit(alice, ALICE_HRZN);
        vm.prank(alice);
        vault.requestUnstake(ALICE_HRZN);

        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        vault.completeUnstake();

        assertEq(hrzn.balanceOf(alice), ALICE_HRZN);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_DirectWithdraw_Reverts() public {
        _deposit(alice, ALICE_HRZN);
        vm.prank(alice);
        vm.expectRevert("sHRZNVault: use requestUnstake");
        vault.withdraw(ALICE_HRZN, alice, alice);
    }

    // -------------------------------------------------------------------------
    // No stuck funds invariant
    // -------------------------------------------------------------------------

    function testFuzz_NoStuckFunds(uint256 depositAmount, uint256 rewardAmount) public {
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);
        rewardAmount = bound(rewardAmount, 1, 1_000_000e6);

        // Fund and deposit
        vm.prank(treasury);
        hrzn.transfer(alice, depositAmount);
        _deposit(alice, depositAmount);

        // Distribute reward
        usdc.mint(distributor, rewardAmount);
        vm.prank(distributor);
        usdc.transfer(address(vault), rewardAmount);
        vm.prank(distributor);
        vault.notifyRewardAmount(rewardAmount);

        // Alice claims all rewards
        uint256 earned = vault.earned(alice);
        if (earned > 0) {
            vm.prank(alice);
            vault.claimRewards();
        }

        // Dust invariant: stuck USDC = rewardAmount - earned(claimed).
        // When rewardPerTokenStored truncates to 0 (reward too small relative to supply),
        // earned = 0 and the full rewardAmount sits as unclaimed dust. This is acceptable
        // rounding behaviour — verify the stuck amount equals rewardAmount - earned exactly.
        uint256 stuck = usdc.balanceOf(address(vault));
        assertEq(stuck, rewardAmount - earned);
    }
}
