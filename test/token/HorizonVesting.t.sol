// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../src/token/HorizonToken.sol";
import "../../src/token/HorizonVesting.sol";

contract HorizonVestingTest is Test {
    HorizonToken token;
    HorizonVesting vesting;

    address treasury = makeAddr("treasury");
    address teamVesting_addr = makeAddr("teamVesting_addr");
    address advisorVesting_addr = makeAddr("advisorVesting_addr");
    address beneficiary = makeAddr("beneficiary");
    address admin = makeAddr("admin");

    uint64 constant START = 1_740_000_000; // fixed start for determinism
    uint64 constant CLIFF_DURATION = 365 days;
    uint64 constant TOTAL_DURATION = 3 * 365 days; // 3 years total
    uint256 constant VEST_AMOUNT = 150_000_000e18;

    function setUp() public {
        vm.warp(START);

        token = new HorizonToken(treasury, teamVesting_addr, advisorVesting_addr);

        vesting = new HorizonVesting(
            address(token),
            beneficiary,
            treasury,
            admin,
            START,
            CLIFF_DURATION,
            TOTAL_DURATION
        );

        // Fund the vesting contract with team allocation
        vm.prank(teamVesting_addr);
        token.transfer(address(vesting), VEST_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // vestedAmount
    // -------------------------------------------------------------------------

    function test_BeforeCliff_VestedIsZero() public {
        vm.warp(START + CLIFF_DURATION - 1);
        assertEq(vesting.vestedAmount(uint64(block.timestamp)), 0);
    }

    function test_AtExactCliff_VestedIsProportional() public {
        uint64 cliffTs = START + CLIFF_DURATION;
        vm.warp(cliffTs);
        uint256 expected = (VEST_AMOUNT * CLIFF_DURATION) / TOTAL_DURATION;
        assertEq(vesting.vestedAmount(cliffTs), expected);
    }

    function test_AtEnd_VestedIsFullAmount() public {
        vm.warp(START + TOTAL_DURATION);
        assertEq(vesting.vestedAmount(uint64(block.timestamp)), VEST_AMOUNT);
    }

    function test_BeyondEnd_VestedCapped() public {
        vm.warp(START + TOTAL_DURATION + 365 days);
        assertEq(vesting.vestedAmount(uint64(block.timestamp)), VEST_AMOUNT);
    }

    function test_Midpoint_VestedIsHalf() public {
        uint64 mid = START + TOTAL_DURATION / 2;
        vm.warp(mid);
        uint256 expected = (VEST_AMOUNT * (TOTAL_DURATION / 2)) / TOTAL_DURATION;
        assertEq(vesting.vestedAmount(mid), expected);
    }

    // -------------------------------------------------------------------------
    // releasable / release
    // -------------------------------------------------------------------------

    function test_Release_BeforeCliff_Reverts() public {
        vm.warp(START + CLIFF_DURATION - 1);
        vm.prank(beneficiary);
        vm.expectRevert("HorizonVesting: nothing to release");
        vesting.release();
    }

    function test_Release_FullyVested() public {
        vm.warp(START + TOTAL_DURATION);

        vm.prank(beneficiary);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), VEST_AMOUNT);
        assertEq(vesting.released(), VEST_AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_Release_PartialThenFull() public {
        // Release at cliff
        vm.warp(START + CLIFF_DURATION);
        vm.prank(beneficiary);
        vesting.release();
        uint256 afterCliff = token.balanceOf(beneficiary);
        assertGt(afterCliff, 0);

        // Release rest at end
        vm.warp(START + TOTAL_DURATION);
        vm.prank(beneficiary);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), VEST_AMOUNT);
        assertEq(vesting.released(), VEST_AMOUNT);
    }

    function test_Release_NonBeneficiary_Reverts() public {
        vm.warp(START + TOTAL_DURATION);
        vm.expectRevert("HorizonVesting: not beneficiary");
        vesting.release();
    }

    // -------------------------------------------------------------------------
    // revoke
    // -------------------------------------------------------------------------

    function test_Revoke_BeforeCliff_AllToTreasury() public {
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.warp(START + CLIFF_DURATION / 2);

        vm.prank(admin);
        vesting.revoke();

        assertTrue(vesting.revoked());
        // All VEST_AMOUNT should be returned (nothing vested before cliff)
        assertEq(token.balanceOf(treasury), treasuryBefore + VEST_AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_Revoke_AfterPartialVest_SplitsCorrectly() public {
        // Warp to halfway through total duration
        uint64 halfTs = START + TOTAL_DURATION / 2;
        vm.warp(halfTs);

        // Beneficiary releases vested portion first
        vm.prank(beneficiary);
        vesting.release();
        uint256 alreadyReleased = vesting.released();
        assertGt(alreadyReleased, 0);

        uint256 treasuryBefore = token.balanceOf(treasury);

        // Admin revokes
        vm.prank(admin);
        vesting.revoke();

        // Vesting contract should be empty (releasable was 0 at revoke time, all unvested went to treasury)
        assertEq(token.balanceOf(address(vesting)), 0);
        // Treasury received the unvested portion
        uint256 unvested = VEST_AMOUNT - alreadyReleased;
        // Account for linear math rounding
        assertApproxEqAbs(token.balanceOf(treasury), treasuryBefore + unvested, 1e12);
    }

    function test_Revoke_Sets_RevokeFlagAndBlocksRelease() public {
        vm.warp(START + CLIFF_DURATION + 1);

        vm.prank(admin);
        vesting.revoke();

        assertTrue(vesting.revoked());
        // After revoke, vestedAmount returns 0 for future timestamps
        vm.warp(START + TOTAL_DURATION);
        assertEq(vesting.vestedAmount(uint64(block.timestamp)), 0);
    }

    function test_DoubleRevoke_Reverts() public {
        vm.prank(admin);
        vesting.revoke();

        vm.prank(admin);
        vm.expectRevert("HorizonVesting: already revoked");
        vesting.revoke();
    }

    function test_Revoke_NonOwner_Reverts() public {
        vm.prank(beneficiary);
        vm.expectRevert();
        vesting.revoke();
    }

    // -------------------------------------------------------------------------
    // Constructor validation
    // -------------------------------------------------------------------------

    function test_Constructor_CliffGeDuration_Reverts() public {
        vm.expectRevert("HorizonVesting: cliff >= duration");
        new HorizonVesting(
            address(token), beneficiary, treasury, admin,
            START, 365 days, 365 days // cliff == duration
        );
    }

    function test_Constructor_ZeroBeneficiary_Reverts() public {
        vm.expectRevert("HorizonVesting: zero beneficiary");
        new HorizonVesting(
            address(token), address(0), treasury, admin,
            START, 180 days, 365 days
        );
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    function testFuzz_VestedNeverExceedsBalance(uint64 timestamp) public {
        timestamp = uint64(bound(uint256(timestamp), START, START + TOTAL_DURATION * 2));
        vm.warp(timestamp);
        uint256 vested = vesting.vestedAmount(timestamp);
        uint256 total = token.balanceOf(address(vesting)) + vesting.released();
        assertLe(vested, total);
    }

    function testFuzz_LinearMonotonicity(uint64 t1, uint64 t2) public view {
        t1 = uint64(bound(uint256(t1), START + CLIFF_DURATION, START + TOTAL_DURATION));
        t2 = uint64(bound(uint256(t2), uint256(t1), START + TOTAL_DURATION));
        assertLe(vesting.vestedAmount(t1), vesting.vestedAmount(t2));
    }
}
