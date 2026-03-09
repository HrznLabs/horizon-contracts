// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {SeasonsRegistry} from "../src/SeasonsRegistry.sol";

/**
 * @title SeasonsRegistryTest
 * @notice Comprehensive test suite for the SeasonsRegistry contract
 */
contract SeasonsRegistryTest is Test {
    SeasonsRegistry public registry;

    address owner = makeAddr("owner");
    address nobody = makeAddr("nobody");

    // Convenient time constants
    uint64 constant T0 = 1_000_000;
    uint64 constant T1 = T0 + 30 days;
    uint64 constant T2 = T1 + 30 days;
    uint64 constant T3 = T2 + 30 days;

    function setUp() public {
        vm.prank(owner);
        registry = new SeasonsRegistry();
        // Start time at a known point
        vm.warp(T0);
    }

    // =========================================================================
    // DEPLOYMENT
    // =========================================================================

    function test_Constructor_SetsOwner() public view {
        assertEq(registry.owner(), owner);
    }

    function test_Constructor_SeasonCountZero() public view {
        assertEq(registry.seasonCount(), 0);
    }

    // =========================================================================
    // startSeason — happy path
    // =========================================================================

    function test_StartSeason_FirstSeason() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        assertEq(registry.seasonCount(), 1);
        SeasonsRegistry.Season memory s = registry.getSeason(1);
        assertEq(s.id, 1);
        assertEq(s.startTime, T0);
        assertEq(s.endTime, T1);
        assertTrue(s.active);
    }

    function test_StartSeason_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SeasonsRegistry.SeasonStarted(1, T0, T1);
        registry.startSeason(1, T0, T1);
    }

    function test_StartSeason_SequentialSecondSeason() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.prank(owner);
        registry.startSeason(2, T1, T2);

        assertEq(registry.seasonCount(), 2);
        SeasonsRegistry.Season memory s = registry.getSeason(2);
        assertEq(s.id, 2);
        assertEq(s.startTime, T1);
        assertEq(s.endTime, T2);
        assertTrue(s.active);
    }

    // =========================================================================
    // startSeason — reverts
    // =========================================================================

    function test_StartSeason_Reverts_InvalidSeasonId_SkipAhead() public {
        // Try to start season 2 before season 1 exists
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidSeasonId()"));
        registry.startSeason(2, T0, T1);
    }

    function test_StartSeason_Reverts_InvalidSeasonId_Zero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidSeasonId()"));
        registry.startSeason(0, T0, T1);
    }

    function test_StartSeason_Reverts_InvalidSeasonId_Duplicate() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        // Try to start season 1 again
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidSeasonId()"));
        registry.startSeason(1, T1, T2);
    }

    function test_StartSeason_Reverts_InvalidTimeRange_EqualTimes() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidTimeRange()"));
        registry.startSeason(1, T0, T0);
    }

    function test_StartSeason_Reverts_InvalidTimeRange_EndBeforeStart() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidTimeRange()"));
        registry.startSeason(1, T1, T0);
    }

    function test_StartSeason_Reverts_SeasonOverlap() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T2); // ends at T2

        // startTime of season 2 < endTime of season 1 (T1 < T2)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SeasonOverlap()"));
        registry.startSeason(2, T1, T3);
    }

    function test_StartSeason_Reverts_SeasonOverlap_SameStart() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T2);

        // startTime == previous endTime is fine (>= check), but < endTime should revert
        // startTime T0 < endTime T2 — should revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SeasonOverlap()"));
        registry.startSeason(2, T0, T3);
    }

    function test_StartSeason_Allows_ExactlyAfterPrevious() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        // startTime == previous endTime: T1 >= T1 is NOT < endTime, so no overlap revert
        vm.prank(owner);
        registry.startSeason(2, T1, T2);

        assertEq(registry.seasonCount(), 2);
    }

    function test_StartSeason_Reverts_NotOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.startSeason(1, T0, T1);
    }

    // =========================================================================
    // endSeason — happy path
    // =========================================================================

    function test_EndSeason_MarksInactive() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.warp(T0 + 1 days);
        vm.prank(owner);
        registry.endSeason(1);

        SeasonsRegistry.Season memory s = registry.getSeason(1);
        assertFalse(s.active);
    }

    function test_EndSeason_UpdatesEndTime() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        uint64 earlyEnd = T0 + 5 days;
        vm.warp(earlyEnd);
        vm.prank(owner);
        registry.endSeason(1);

        SeasonsRegistry.Season memory s = registry.getSeason(1);
        assertEq(s.endTime, earlyEnd);
    }

    function test_EndSeason_EmitsEvent() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit SeasonsRegistry.SeasonEnded(1);
        registry.endSeason(1);
    }

    // =========================================================================
    // endSeason — reverts
    // =========================================================================

    function test_EndSeason_Reverts_SeasonNotFound() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SeasonNotFound()"));
        registry.endSeason(99);
    }

    function test_EndSeason_Reverts_SeasonNotFound_IdZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SeasonNotFound()"));
        registry.endSeason(0);
    }

    function test_EndSeason_Reverts_NotOwner() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.prank(nobody);
        vm.expectRevert();
        registry.endSeason(1);
    }

    // =========================================================================
    // getCurrentSeason
    // =========================================================================

    function test_GetCurrentSeason_NoSeasons_ReturnsEmpty() public view {
        SeasonsRegistry.Season memory s = registry.getCurrentSeason();
        assertEq(s.id, 0);
        assertFalse(s.active);
    }

    function test_GetCurrentSeason_BeforeSeason_ReturnsEmpty() public {
        vm.prank(owner);
        registry.startSeason(1, T1, T2); // starts in the future

        // block.timestamp is T0, which is before T1
        SeasonsRegistry.Season memory s = registry.getCurrentSeason();
        assertEq(s.id, 0);
    }

    function test_GetCurrentSeason_DuringActiveSeason() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.warp(T0 + 1 days);
        SeasonsRegistry.Season memory s = registry.getCurrentSeason();
        assertEq(s.id, 1);
        assertTrue(s.active);
    }

    function test_GetCurrentSeason_AtStartTime() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        // warp exactly to startTime
        vm.warp(T0);
        SeasonsRegistry.Season memory s = registry.getCurrentSeason();
        assertEq(s.id, 1);
    }

    function test_GetCurrentSeason_AtEndTime_ReturnsEmpty() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        // At endTime the season is no longer current (strict <)
        vm.warp(T1);
        SeasonsRegistry.Season memory s = registry.getCurrentSeason();
        assertEq(s.id, 0);
    }

    function test_GetCurrentSeason_AfterSeason_ReturnsEmpty() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.warp(T1 + 1 days);
        SeasonsRegistry.Season memory s = registry.getCurrentSeason();
        assertEq(s.id, 0);
    }

    function test_GetCurrentSeason_AfterEndSeason_ReturnsEmpty() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.warp(T0 + 5 days);
        vm.prank(owner);
        registry.endSeason(1);

        SeasonsRegistry.Season memory s = registry.getCurrentSeason();
        assertEq(s.id, 0);
    }

    function test_GetCurrentSeason_MultipleSeasonsReturnsActive() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.prank(owner);
        registry.startSeason(2, T1, T2);

        // Warp to season 2
        vm.warp(T1 + 1 days);
        SeasonsRegistry.Season memory s = registry.getCurrentSeason();
        assertEq(s.id, 2);
    }

    // =========================================================================
    // getSeasonForTimestamp
    // =========================================================================

    function test_GetSeasonForTimestamp_NoSeasons_ReturnsEmpty() public view {
        SeasonsRegistry.Season memory s = registry.getSeasonForTimestamp(T0);
        assertEq(s.id, 0);
    }

    function test_GetSeasonForTimestamp_MatchesSeason1() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        SeasonsRegistry.Season memory s = registry.getSeasonForTimestamp(T0 + 1 days);
        assertEq(s.id, 1);
    }

    function test_GetSeasonForTimestamp_MatchesPastSeason() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.prank(owner);
        registry.startSeason(2, T1, T2);

        // Query a past timestamp that falls in season 1
        SeasonsRegistry.Season memory s = registry.getSeasonForTimestamp(T0 + 5 days);
        assertEq(s.id, 1);
    }

    function test_GetSeasonForTimestamp_MatchesCurrentSeason() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        vm.prank(owner);
        registry.startSeason(2, T1, T2);

        // Query a timestamp in season 2
        SeasonsRegistry.Season memory s = registry.getSeasonForTimestamp(T1 + 5 days);
        assertEq(s.id, 2);
    }

    function test_GetSeasonForTimestamp_AtBoundary_StartIncluded() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        SeasonsRegistry.Season memory s = registry.getSeasonForTimestamp(T0);
        assertEq(s.id, 1);
    }

    function test_GetSeasonForTimestamp_AtBoundary_EndExcluded() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        // At endTime, should NOT match season 1
        SeasonsRegistry.Season memory s = registry.getSeasonForTimestamp(T1);
        assertEq(s.id, 0);
    }

    function test_GetSeasonForTimestamp_BetweenSeasons_ReturnsEmpty() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        // Gap between T1 and T2
        vm.prank(owner);
        registry.startSeason(2, T2, T3);

        // Timestamp in the gap
        SeasonsRegistry.Season memory s = registry.getSeasonForTimestamp(T1 + 1 days);
        assertEq(s.id, 0);
    }

    // =========================================================================
    // getSeason
    // =========================================================================

    function test_GetSeason_Reverts_NotFound() public {
        vm.expectRevert(abi.encodeWithSignature("SeasonNotFound()"));
        registry.getSeason(1);
    }

    function test_GetSeason_ReturnsCorrectData() public {
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        SeasonsRegistry.Season memory s = registry.getSeason(1);
        assertEq(s.id, 1);
        assertEq(s.startTime, T0);
        assertEq(s.endTime, T1);
        assertTrue(s.active);
    }

    // =========================================================================
    // FUZZ TESTS
    // =========================================================================

    function testFuzz_StartSeason_InvalidTimeRange(uint64 start, uint64 end) public {
        vm.assume(end <= start);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidTimeRange()"));
        registry.startSeason(1, start, end);
    }

    function testFuzz_GetSeasonForTimestamp_OutOfRange(uint64 ts) public {
        vm.assume(ts < T0 || ts >= T1);
        vm.prank(owner);
        registry.startSeason(1, T0, T1);

        if (ts < T0 || ts >= T1) {
            SeasonsRegistry.Season memory s = registry.getSeasonForTimestamp(ts);
            // Either id=0 (out of range) or matches another season (none exist here)
            if (ts < T0 || ts >= T1) {
                assertEq(s.id, 0);
            }
        }
    }
}
