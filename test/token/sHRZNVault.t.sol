// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../src/token/HorizonToken.sol";
import "../../src/token/sHRZNVault.sol";
import "../../test/mocks/MockERC20.sol";

/// @notice Realigned for the 2026-08-11 audit fixes:
///  - _decimalsOffset() is 6 (first deposit mints assets * 1e6 shares), so share
///    assertions are relationship-based, not hardcoded 1:1.
///  - requestUnstake/completeUnstake now actually work (audit C1).
///  - escrowed shares don't earn or dilute (audit M2).
///  - zero-share deposits revert (audit H1).
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

        bytes32 distributorRole = vault.DISTRIBUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(distributorRole, distributor);

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
    // Deposit / shares (offset = 6)
    // -------------------------------------------------------------------------

    function test_Deposit_IssuesShares() public {
        _deposit(alice, ALICE_HRZN);
        // First deposit mints assets * 10^decimalsOffset() shares.
        assertEq(vault.balanceOf(alice), ALICE_HRZN * 1e6);
        assertEq(vault.totalAssets(), ALICE_HRZN);
        // Round-trips back to the deposited assets.
        assertEq(vault.previewRedeem(vault.balanceOf(alice)), ALICE_HRZN);
    }

    function test_TwoDepositors_SharesProportional() public {
        _deposit(alice, ALICE_HRZN);
        _deposit(bob, BOB_HRZN);
        assertEq(vault.totalAssets(), ALICE_HRZN + BOB_HRZN);
        // Shares proportional to deposits: alice/bob shares == 600/400.
        // (cross-multiply to avoid rounding-direction fragility)
        assertApproxEqRel(
            vault.balanceOf(alice) * BOB_HRZN,
            vault.balanceOf(bob) * ALICE_HRZN,
            1e12 // 1e-6 %
        );
    }

    function test_RevertWhen_DepositMintsZeroShares() public {
        // Seed the vault, then inflate the share price by donating a large amount of
        // HRZN directly, then attempt a deposit small enough to round to zero shares.
        _deposit(alice, 1); // 1 wei -> 1e6 shares
        vm.prank(treasury);
        hrzn.transfer(address(vault), 1_000_000e18); // donation inflates totalAssets

        // A 1-wei deposit into the now-inflated pool rounds to 0 shares; the guard
        // must revert rather than silently absorb the depositor's asset.
        vm.startPrank(bob);
        hrzn.approve(address(vault), 1);
        vm.expectRevert("sHRZNVault: zero shares");
        vault.deposit(1, bob);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Rewards
    // -------------------------------------------------------------------------

    function test_RewardPerToken_UpdatesOnNotify() public {
        _deposit(alice, ALICE_HRZN);
        _notifyReward(1000e6);
        assertGt(vault.rewardPerToken(), 0);
    }

    function test_Earned_ProportionalToShares() public {
        _deposit(alice, ALICE_HRZN);
        _deposit(bob, BOB_HRZN);
        _notifyReward(1000e6);
        assertApproxEqAbs(vault.earned(alice), 600e6, 1e3);
        assertApproxEqAbs(vault.earned(bob), 400e6, 1e3);
    }

    function test_ClaimRewards_TransfersUsdc() public {
        _deposit(alice, ALICE_HRZN);
        _notifyReward(1000e6);
        uint256 aliceReward = vault.earned(alice);
        vm.prank(alice);
        vault.claimRewards();
        assertEq(usdc.balanceOf(alice), aliceReward);
        assertEq(vault.rewards(alice), 0);
    }

    function test_NewDepositor_EarnsZeroFromPastRewards() public {
        _deposit(alice, ALICE_HRZN);
        _notifyReward(1000e6);
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
    // Cooldown unstaking (audit C1: this whole flow now works)
    // -------------------------------------------------------------------------

    function test_RequestUnstake_EscrowsShares() public {
        _deposit(alice, ALICE_HRZN);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestUnstake(shares);

        // Shares moved to escrow (the contract), request recorded.
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
        (uint256 reqShares,) = vault.unstakeRequests(alice);
        assertEq(reqShares, shares);
    }

    function test_CompleteUnstake_BeforeCooldown_Reverts() public {
        _deposit(alice, ALICE_HRZN);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestUnstake(shares);

        vm.prank(alice);
        vm.expectRevert("sHRZNVault: cooldown active");
        vault.completeUnstake();
    }

    function test_CompleteUnstake_AfterCooldown_ReturnsHRZN() public {
        _deposit(alice, ALICE_HRZN);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestUnstake(shares);

        vm.warp(block.timestamp + vault.COOLDOWN_PERIOD());

        vm.prank(alice);
        vault.completeUnstake();

        assertEq(hrzn.balanceOf(alice), ALICE_HRZN);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
    }

    /// @notice audit M2: shares in cooldown escrow must not earn rewards, and must
    /// not dilute active stakers — the full reward goes to the remaining staker and
    /// nothing is stranded on the vault.
    function test_EscrowedSharesDoNotEarnOrDilute() public {
        _deposit(alice, ALICE_HRZN);
        _deposit(bob, BOB_HRZN);

        // Alice requests unstake of all her shares -> escrowed.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestUnstake(aliceShares);
        uint256 aliceEarnedAtRequest = vault.earned(alice);

        // Reward arrives during the cooldown.
        _notifyReward(1000e6);

        // Bob (the only circulating staker) earns the FULL reward; alice earns nothing new.
        assertApproxEqAbs(vault.earned(bob), 1000e6, 1e3);
        assertEq(vault.earned(alice), aliceEarnedAtRequest);

        // Everything is claimable — nothing stranded on the vault.
        assertEq(vault.earned(address(vault)), 0);
        vm.prank(bob);
        vault.claimRewards();
        assertApproxEqAbs(usdc.balanceOf(bob), 1000e6, 1e3);
    }

    function test_DirectWithdraw_Reverts() public {
        _deposit(alice, ALICE_HRZN);
        vm.prank(alice);
        vm.expectRevert("sHRZNVault: use requestUnstake");
        vault.withdraw(1, alice, alice);
    }

    function test_DirectRedeem_Reverts() public {
        _deposit(alice, ALICE_HRZN);
        vm.prank(alice);
        vm.expectRevert("sHRZNVault: use requestUnstake");
        vault.redeem(1, alice, alice);
    }

    // -------------------------------------------------------------------------
    // Fuzz: single depositor, only their own earned USDC is claimable
    // -------------------------------------------------------------------------

    function testFuzz_NoStuckFunds(uint256 depositAmount, uint256 rewardAmount) public {
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);
        rewardAmount = bound(rewardAmount, 1e6, 1_000_000e6);

        vm.prank(treasury);
        hrzn.transfer(alice, depositAmount);
        _deposit(alice, depositAmount);
        _notifyReward(rewardAmount);

        uint256 earned = vault.earned(alice);
        // Sole staker: earned equals the whole reward (minus at most rounding dust).
        assertApproxEqAbs(earned, rewardAmount, 1e6);
        assertLe(earned, rewardAmount);
    }
}
