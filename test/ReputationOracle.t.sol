// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ReputationOracle} from "../src/ReputationOracle.sol";
import {IReputationOracle} from "../src/interfaces/IReputationOracle.sol";

/**
 * @title ReputationOracleTest
 * @notice Comprehensive test suite for the ReputationOracle contract
 */
contract ReputationOracleTest is Test {
    ReputationOracle public oracle;

    address admin = makeAddr("admin");
    address relayer = makeAddr("relayer");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");
    address guild1 = makeAddr("guild1");
    address guild2 = makeAddr("guild2");
    address nobody = makeAddr("nobody");

    function setUp() public {
        oracle = new ReputationOracle(admin, relayer);
    }

    // =========================================================================
    // DEPLOYMENT
    // =========================================================================

    function test_Constructor_GrantsRoles() public view {
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.RELAYER_ROLE(), relayer));
    }

    function test_Constructor_RevertsZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ReputationOracle(address(0), relayer);
    }

    function test_Constructor_ZeroRelayer_Ok() public {
        // Zero relayer is fine — admin can add one later
        ReputationOracle o = new ReputationOracle(admin, address(0));
        assertTrue(o.hasRole(o.ADMIN_ROLE(), admin));
        assertFalse(o.hasRole(o.RELAYER_ROLE(), address(0)));
    }

    // =========================================================================
    // updateScore (per-guild)
    // =========================================================================

    function test_UpdateScore_SingleUser() public {
        vm.prank(relayer);
        oracle.updateScore(user1, guild1, 500);

        assertEq(oracle.getScore(user1, guild1), 500);
    }

    function test_UpdateScore_EmitsEvent() public {
        vm.prank(relayer);
        vm.expectEmit(true, true, false, true);
        emit IReputationOracle.ScoreUpdated(user1, guild1, 0, 500);
        oracle.updateScore(user1, guild1, 500);
    }

    function test_UpdateScore_RevertsWithoutRole() public {
        vm.prank(nobody);
        vm.expectRevert();
        oracle.updateScore(user1, guild1, 500);
    }

    function test_UpdateScore_RevertsOutOfRange() public {
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("ScoreOutOfRange(uint256)", 1001));
        oracle.updateScore(user1, guild1, 1001);
    }

    function test_UpdateScore_NoOpOnSameValue() public {
        vm.prank(relayer);
        oracle.updateScore(user1, guild1, 400);

        // Second call with same value — score unchanged, no revert
        vm.prank(relayer);
        oracle.updateScore(user1, guild1, 400);

        assertEq(oracle.getScore(user1, guild1), 400);
    }

    function test_UpdateScore_DifferentGuilds() public {
        vm.startPrank(relayer);
        oracle.updateScore(user1, guild1, 300);
        oracle.updateScore(user1, guild2, 700);
        vm.stopPrank();

        assertEq(oracle.getScore(user1, guild1), 300);
        assertEq(oracle.getScore(user1, guild2), 700);
    }

    // =========================================================================
    // updateGlobalScore
    // =========================================================================

    function test_UpdateGlobalScore() public {
        vm.prank(relayer);
        oracle.updateGlobalScore(user1, 650);

        assertEq(oracle.getGlobalScore(user1), 650);
    }

    function test_UpdateGlobalScore_EmitsEvent() public {
        vm.prank(relayer);
        vm.expectEmit(true, false, false, true);
        emit IReputationOracle.GlobalScoreUpdated(user1, 0, 650);
        oracle.updateGlobalScore(user1, 650);
    }

    function test_UpdateGlobalScore_RevertsOutOfRange() public {
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("ScoreOutOfRange(uint256)", 1500));
        oracle.updateGlobalScore(user1, 1500);
    }

    function test_UpdateGlobalScore_RevertsWithoutRole() public {
        vm.prank(nobody);
        vm.expectRevert();
        oracle.updateGlobalScore(user1, 500);
    }

    // =========================================================================
    // batchUpdateScores
    // =========================================================================

    function test_BatchUpdateScores() public {
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        uint256[] memory scores = new uint256[](3);
        scores[0] = 100;
        scores[1] = 500;
        scores[2] = 900;

        vm.prank(relayer);
        oracle.batchUpdateScores(users, guild1, scores);

        assertEq(oracle.getScore(user1, guild1), 100);
        assertEq(oracle.getScore(user2, guild1), 500);
        assertEq(oracle.getScore(user3, guild1), 900);
    }

    function test_BatchUpdateScores_EmitsBatchEvent() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory scores = new uint256[](2);
        scores[0] = 100;
        scores[1] = 200;

        vm.prank(relayer);
        vm.expectEmit(true, false, false, true);
        emit IReputationOracle.BatchScoresUpdated(guild1, 2);
        oracle.batchUpdateScores(users, guild1, scores);
    }

    function test_BatchUpdateScores_RevertsLengthMismatch() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory scores = new uint256[](1);
        scores[0] = 100;

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
        oracle.batchUpdateScores(users, guild1, scores);
    }

    function test_BatchUpdateScores_RevertsOutOfRange() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory scores = new uint256[](2);
        scores[0] = 500;
        scores[1] = 1001; // Over max

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("ScoreOutOfRange(uint256)", 1001));
        oracle.batchUpdateScores(users, guild1, scores);
    }

    // =========================================================================
    // getTier
    // =========================================================================

    function test_GetTier_Newcomer() public view {
        assertEq(oracle.getTier(0), 0);
        assertEq(oracle.getTier(199), 0);
    }

    function test_GetTier_Bronze() public view {
        assertEq(oracle.getTier(200), 1);
        assertEq(oracle.getTier(399), 1);
    }

    function test_GetTier_Silver() public view {
        assertEq(oracle.getTier(400), 2);
        assertEq(oracle.getTier(599), 2);
    }

    function test_GetTier_Gold() public view {
        assertEq(oracle.getTier(600), 3);
        assertEq(oracle.getTier(799), 3);
    }

    function test_GetTier_Diamond() public view {
        assertEq(oracle.getTier(800), 4);
        assertEq(oracle.getTier(1000), 4);
    }

    // =========================================================================
    // getScoreWithTier
    // =========================================================================

    function test_GetScoreWithTier() public {
        vm.prank(relayer);
        oracle.updateScore(user1, guild1, 650);

        (uint256 score, uint8 tier) = oracle.getScoreWithTier(user1, guild1);
        assertEq(score, 650);
        assertEq(tier, 3); // Gold
    }

    // =========================================================================
    // PAUSE
    // =========================================================================

    function test_Pause_BlocksUpdates() public {
        vm.prank(admin);
        oracle.pause();

        vm.prank(relayer);
        vm.expectRevert("ReputationOracle: paused");
        oracle.updateScore(user1, guild1, 500);
    }

    function test_Pause_AllowsReads() public {
        vm.prank(relayer);
        oracle.updateScore(user1, guild1, 400);

        vm.prank(admin);
        oracle.pause();

        // Reads still work
        assertEq(oracle.getScore(user1, guild1), 400);
        assertEq(oracle.getTier(400), 2);
    }

    function test_Unpause_ResumesUpdates() public {
        vm.prank(admin);
        oracle.pause();

        vm.prank(admin);
        oracle.unpause();

        vm.prank(relayer);
        oracle.updateScore(user1, guild1, 500); // Should not revert
        assertEq(oracle.getScore(user1, guild1), 500);
    }

    function test_Pause_OnlyAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        oracle.pause();
    }

    // =========================================================================
    // ADMIN — Relayer Management
    // =========================================================================

    function test_AddRelayer() public {
        address newRelayer = makeAddr("newRelayer");

        vm.prank(admin);
        oracle.addRelayer(newRelayer);

        vm.prank(newRelayer);
        oracle.updateScore(user1, guild1, 300); // Should not revert
        assertEq(oracle.getScore(user1, guild1), 300);
    }

    function test_RemoveRelayer() public {
        vm.prank(admin);
        oracle.removeRelayer(relayer);

        vm.prank(relayer);
        vm.expectRevert();
        oracle.updateScore(user1, guild1, 300);
    }

    // =========================================================================
    // FUZZ TESTS
    // =========================================================================

    function testFuzz_ScoreAlwaysInRange(uint256 score) public {
        score = bound(score, 0, 1000);

        vm.prank(relayer);
        oracle.updateScore(user1, guild1, score);
        assertEq(oracle.getScore(user1, guild1), score);
        assertTrue(oracle.getTier(score) <= 4);
    }

    function testFuzz_OutOfRange_Reverts(uint256 score) public {
        score = bound(score, 1001, type(uint256).max);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSignature("ScoreOutOfRange(uint256)", score));
        oracle.updateScore(user1, guild1, score);
    }

    function testFuzz_TierBoundaries(uint256 score) public {
        score = bound(score, 0, 1000);
        uint8 tier = oracle.getTier(score);

        if (score < 200) assertEq(tier, 0);
        else if (score < 400) assertEq(tier, 1);
        else if (score < 600) assertEq(tier, 2);
        else if (score < 800) assertEq(tier, 3);
        else assertEq(tier, 4);
    }

    function testFuzz_GlobalScore(uint256 score) public {
        score = bound(score, 0, 1000);

        vm.prank(relayer);
        oracle.updateGlobalScore(user1, score);
        assertEq(oracle.getGlobalScore(user1), score);
    }
}
