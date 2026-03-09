// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../src/token/HorizonToken.sol";

contract HorizonTokenTest is Test {
    HorizonToken token;

    address treasury = makeAddr("treasury");
    address teamVesting = makeAddr("teamVesting");
    address advisorVesting = makeAddr("advisorVesting");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new HorizonToken(treasury, teamVesting, advisorVesting);
    }

    // -------------------------------------------------------------------------
    // Supply
    // -------------------------------------------------------------------------

    function test_TotalSupply() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
    }

    function test_InitialDistribution() public view {
        assertEq(token.balanceOf(treasury), 800_000_000 * 10 ** 18);
        assertEq(token.balanceOf(teamVesting), 150_000_000 * 10 ** 18);
        assertEq(token.balanceOf(advisorVesting), 50_000_000 * 10 ** 18);
    }

    function test_SumEqualsTotal() public view {
        uint256 sum = token.balanceOf(treasury)
            + token.balanceOf(teamVesting)
            + token.balanceOf(advisorVesting);
        assertEq(sum, token.TOTAL_SUPPLY());
    }

    // -------------------------------------------------------------------------
    // Clock mode (ERC-6372)
    // -------------------------------------------------------------------------

    function test_ClockMode_IsTimestamp() public view {
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }

    function test_Clock_ReturnsBlockTimestamp() public {
        uint256 ts = 1_740_000_000;
        vm.warp(ts);
        assertEq(token.clock(), uint48(ts));
    }

    // -------------------------------------------------------------------------
    // ERC20Votes
    // -------------------------------------------------------------------------

    function test_Delegate_GetVotes() public {
        vm.prank(treasury);
        token.delegate(alice);
        assertEq(token.getVotes(alice), 800_000_000 * 10 ** 18);
    }

    function test_Transfer_UpdatesDelegatee() public {
        vm.prank(treasury);
        token.delegate(treasury);

        vm.prank(treasury);
        token.transfer(alice, 100e18);

        assertEq(token.getVotes(treasury), 800_000_000 * 10 ** 18 - 100e18);
    }

    function test_PastVotes_AfterTransfer() public {
        // Use explicit large timestamps to avoid OZ v5 ERC5805FutureLookup (timepoint must be < clock)
        vm.warp(10_000);
        vm.prank(treasury);
        token.delegate(treasury); // checkpoint at 10_000

        vm.warp(11_000);
        vm.prank(treasury);
        token.transfer(alice, 500e18); // checkpoint at 11_000

        vm.warp(12_000); // well ahead of both checkpoints

        assertEq(token.getPastVotes(treasury, 10_000), 800_000_000 * 10 ** 18);
        assertEq(token.getPastVotes(treasury, 11_000), 800_000_000 * 10 ** 18 - 500e18);
    }

    // -------------------------------------------------------------------------
    // ERC20Burnable
    // -------------------------------------------------------------------------

    function test_Burn_ReducesSupply() public {
        vm.prank(treasury);
        token.burn(1_000e18);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18 - 1_000e18);
        assertEq(token.balanceOf(treasury), 800_000_000 * 10 ** 18 - 1_000e18);
    }

    function test_BurnFrom_RequiresAllowance() public {
        vm.prank(treasury);
        token.approve(alice, 500e18);

        vm.prank(alice);
        token.burnFrom(treasury, 500e18);

        assertEq(token.balanceOf(treasury), 800_000_000 * 10 ** 18 - 500e18);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18 - 500e18);
    }

    function test_BurnFrom_ExceedsAllowance_Reverts() public {
        vm.prank(treasury);
        token.approve(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert();
        token.burnFrom(treasury, 101e18);
    }

    // -------------------------------------------------------------------------
    // ERC20Permit (nonces)
    // -------------------------------------------------------------------------

    function test_Nonces_StartsAtZero() public view {
        assertEq(token.nonces(treasury), 0);
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    function testFuzz_Transfer_SupplyInvariant(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(treasury));
        uint256 supplyBefore = token.totalSupply();
        vm.prank(treasury);
        token.transfer(alice, amount);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function testFuzz_Burn_ReducesSupplyExactly(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(treasury));
        uint256 supplyBefore = token.totalSupply();
        vm.prank(treasury);
        token.burn(amount);
        assertEq(token.totalSupply(), supplyBefore - amount);
    }

    function testFuzz_VotingPower_AfterTransfer(uint256 amount) public {
        amount = bound(amount, 1, token.balanceOf(treasury));
        vm.prank(treasury);
        token.delegate(treasury);
        vm.prank(alice);
        token.delegate(alice);

        vm.prank(treasury);
        token.transfer(alice, amount);

        assertEq(token.getVotes(treasury), 800_000_000 * 10 ** 18 - amount);
        assertEq(token.getVotes(alice), amount);
    }
}
