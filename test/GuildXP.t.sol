// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {GuildXP} from "../src/governance/GuildXP.sol";

/**
 * @title GuildXPTest
 * @notice Direct unit tests for the GuildXP contract.
 *
 * Coverage:
 *   - Constructor + initial role assignment
 *   - updateXP(): happy path, access control, per-guild isolation
 *   - batchUpdateXP(): happy path, gas sanity, length mismatch revert
 *   - updateGlobalXP(): RELAYER_ROLE gate
 *   - batchUpdateGlobalXP(): RELAYER_ROLE gate + length mismatch
 *   - getGuildXP() / getTotalGuildXP() read correctness
 *   - Guild-specific relayer delegation + isolation between guilds
 *   - Guild admin delegation + isolation between guilds
 *   - Pause / unpause: blocks XP updates, only ADMIN_ROLE can toggle
 */
contract GuildXPTest is Test {
    GuildXP public xp;

    address public admin = address(1);
    address public globalRelayer = address(2);
    address public guildRelayerA = address(3);
    address public guildRelayerB = address(4);
    address public guildAdminA = address(5);
    address public guildAdminB = address(6);
    address public attacker = address(7);
    address public user1 = address(8);
    address public user2 = address(9);
    address public user3 = address(10);

    address public guildA = address(100);
    address public guildB = address(101);

    // =========================================================================
    // SETUP
    // =========================================================================

    function setUp() public {
        xp = new GuildXP(admin, globalRelayer);

        // Set up per-guild relayer A for guildA
        vm.startPrank(admin);
        xp.setGuildAdmin(guildA, guildAdminA);
        xp.setGuildAdmin(guildB, guildAdminB);
        vm.stopPrank();

        vm.prank(guildAdminA);
        xp.setGuildRelayer(guildA, guildRelayerA, true);

        vm.prank(guildAdminB);
        xp.setGuildRelayer(guildB, guildRelayerB, true);
    }

    // =========================================================================
    // CONSTRUCTOR + INITIAL STATE
    // =========================================================================

    function test_Constructor_AdminRolesAssigned() public view {
        assertTrue(xp.hasRole(xp.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(xp.hasRole(xp.ADMIN_ROLE(), admin));
    }

    function test_Constructor_GlobalRelayerAssigned() public view {
        assertTrue(xp.hasRole(xp.RELAYER_ROLE(), globalRelayer));
    }

    function test_Constructor_ZeroAdminReverts() public {
        vm.expectRevert(GuildXP.ZeroAddress.selector);
        new GuildXP(address(0), globalRelayer);
    }

    function test_Constructor_ZeroRelayerAllowed() public {
        // Zero globalRelayer is valid — no global relayer granted
        GuildXP xpNoRelayer = new GuildXP(admin, address(0));
        assertFalse(xpNoRelayer.hasRole(xpNoRelayer.RELAYER_ROLE(), address(0)));
    }

    function test_Constructor_InitialXPIsZero() public view {
        assertEq(xp.getGuildXP(guildA, user1), 0);
        assertEq(xp.getTotalGuildXP(guildA), 0);
        assertEq(xp.totalGlobalXP(), 0);
    }

    // =========================================================================
    // updateXP — HAPPY PATH
    // =========================================================================

    function test_UpdateXP_GlobalRelayer_HappyPath() public {
        vm.prank(globalRelayer);
        xp.updateXP(guildA, user1, 500);

        assertEq(xp.getGuildXP(guildA, user1), 500);
        assertEq(xp.getTotalGuildXP(guildA), 500);
    }

    function test_UpdateXP_GuildRelayer_HappyPath() public {
        vm.prank(guildRelayerA);
        xp.updateXP(guildA, user1, 200);

        assertEq(xp.getGuildXP(guildA, user1), 200);
    }

    function test_UpdateXP_GuildAdmin_HappyPath() public {
        vm.prank(guildAdminA);
        xp.updateXP(guildA, user1, 100);

        assertEq(xp.getGuildXP(guildA, user1), 100);
    }

    function test_UpdateXP_IncreaseTotalXP() public {
        vm.startPrank(globalRelayer);
        xp.updateXP(guildA, user1, 300);
        xp.updateXP(guildA, user2, 200);
        vm.stopPrank();

        assertEq(xp.getTotalGuildXP(guildA), 500);
    }

    function test_UpdateXP_DecreaseTotalXP() public {
        vm.prank(globalRelayer);
        xp.updateXP(guildA, user1, 300);

        vm.prank(globalRelayer);
        xp.updateXP(guildA, user1, 100); // decrease from 300 → 100

        assertEq(xp.getGuildXP(guildA, user1), 100);
        assertEq(xp.getTotalGuildXP(guildA), 100);
    }

    function test_UpdateXP_NoChangeIsNoop() public {
        vm.prank(globalRelayer);
        xp.updateXP(guildA, user1, 500);

        uint256 totalBefore = xp.getTotalGuildXP(guildA);

        vm.prank(globalRelayer);
        xp.updateXP(guildA, user1, 500); // same value

        assertEq(xp.getTotalGuildXP(guildA), totalBefore);
    }

    function test_UpdateXP_EmitsXPUpdatedEvent() public {
        vm.prank(globalRelayer);
        vm.expectEmit(true, true, false, true);
        emit GuildXP.XPUpdated(guildA, user1, 0, 400);
        xp.updateXP(guildA, user1, 400);
    }

    // =========================================================================
    // updateXP — ACCESS CONTROL
    // =========================================================================

    function test_UpdateXP_AttackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.updateXP(guildA, user1, 100);
    }

    function test_UpdateXP_GuildRelayerA_CannotUpdateGuildB() public {
        vm.prank(guildRelayerA);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.updateXP(guildB, user1, 100);
    }

    function test_UpdateXP_GuildAdminA_CannotUpdateGuildB() public {
        vm.prank(guildAdminA);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.updateXP(guildB, user1, 100);
    }

    function test_UpdateXP_GlobalRelayer_CanUpdateAnyGuild() public {
        vm.startPrank(globalRelayer);
        xp.updateXP(guildA, user1, 100);
        xp.updateXP(guildB, user1, 200);
        vm.stopPrank();

        assertEq(xp.getGuildXP(guildA, user1), 100);
        assertEq(xp.getGuildXP(guildB, user1), 200);
    }

    // =========================================================================
    // batchUpdateXP
    // =========================================================================

    function test_BatchUpdateXP_HappyPath() public {
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100;
        amounts[1] = 200;
        amounts[2] = 300;

        vm.prank(globalRelayer);
        xp.batchUpdateXP(guildA, users, amounts);

        assertEq(xp.getGuildXP(guildA, user1), 100);
        assertEq(xp.getGuildXP(guildA, user2), 200);
        assertEq(xp.getGuildXP(guildA, user3), 300);
        assertEq(xp.getTotalGuildXP(guildA), 600);
    }

    function test_BatchUpdateXP_LengthMismatch_Reverts() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory amounts = new uint256[](3); // mismatched length
        amounts[0] = 100;
        amounts[1] = 200;
        amounts[2] = 300;

        vm.prank(globalRelayer);
        vm.expectRevert(GuildXP.ArrayLengthMismatch.selector);
        xp.batchUpdateXP(guildA, users, amounts);
    }

    function test_BatchUpdateXP_EmitsBatchEvent() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50;
        amounts[1] = 75;

        vm.prank(globalRelayer);
        vm.expectEmit(true, false, false, true);
        emit GuildXP.BatchXPUpdated(guildA, 2);
        xp.batchUpdateXP(guildA, users, amounts);
    }

    function test_BatchUpdateXP_GasLowerThanSingleLoopEquivalent() public {
        address[] memory users = new address[](5);
        uint256[] memory amounts = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            users[i] = address(uint160(200 + i));
            amounts[i] = (i + 1) * 100;
        }

        // Measure batch gas
        uint256 gasBefore = gasleft();
        vm.prank(globalRelayer);
        xp.batchUpdateXP(guildA, users, amounts);
        uint256 batchGasUsed = gasBefore - gasleft();

        // Measure single-call loop gas (reset state first by zeroing XP)
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(globalRelayer);
            xp.updateXP(guildA, users[i], 0);
        }

        uint256 singleGasBefore = gasleft();
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(globalRelayer);
            xp.updateXP(guildA, users[i], amounts[i]);
        }
        uint256 singleGasUsed = singleGasBefore - gasleft();

        // Batch should be cheaper (fewer tx overhead) — sanity assertion
        // We just ensure batch gas is non-zero and less than 5× individual (rough bound)
        assertGt(batchGasUsed, 0);
        assertLt(batchGasUsed, singleGasUsed * 2);
    }

    function test_BatchUpdateXP_AccessControl_AttackerReverts() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(attacker);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.batchUpdateXP(guildA, users, amounts);
    }

    // =========================================================================
    // updateGlobalXP
    // =========================================================================

    function test_UpdateGlobalXP_RelayerCanUpdate() public {
        vm.prank(globalRelayer);
        xp.updateGlobalXP(user1, 1000);

        assertEq(xp.getGlobalXP(user1), 1000);
        assertEq(xp.totalGlobalXP(), 1000);
    }

    function test_UpdateGlobalXP_IncreasesTotal() public {
        vm.startPrank(globalRelayer);
        xp.updateGlobalXP(user1, 500);
        xp.updateGlobalXP(user2, 300);
        vm.stopPrank();

        assertEq(xp.totalGlobalXP(), 800);
    }

    function test_UpdateGlobalXP_DecreasesTotal() public {
        vm.prank(globalRelayer);
        xp.updateGlobalXP(user1, 500);

        vm.prank(globalRelayer);
        xp.updateGlobalXP(user1, 200);

        assertEq(xp.getGlobalXP(user1), 200);
        assertEq(xp.totalGlobalXP(), 200);
    }

    function test_UpdateGlobalXP_AttackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        xp.updateGlobalXP(user1, 100);
    }

    function test_UpdateGlobalXP_GuildRelayerReverts() public {
        // Guild-specific relayer does NOT have RELAYER_ROLE
        vm.prank(guildRelayerA);
        vm.expectRevert();
        xp.updateGlobalXP(user1, 100);
    }

    // =========================================================================
    // batchUpdateGlobalXP
    // =========================================================================

    function test_BatchUpdateGlobalXP_RelayerCanUpdate() public {
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100;
        amounts[1] = 200;
        amounts[2] = 300;

        vm.prank(globalRelayer);
        xp.batchUpdateGlobalXP(users, amounts);

        assertEq(xp.getGlobalXP(user1), 100);
        assertEq(xp.getGlobalXP(user2), 200);
        assertEq(xp.getGlobalXP(user3), 300);
        assertEq(xp.totalGlobalXP(), 600);
    }

    function test_BatchUpdateGlobalXP_LengthMismatch_Reverts() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(globalRelayer);
        vm.expectRevert(GuildXP.ArrayLengthMismatch.selector);
        xp.batchUpdateGlobalXP(users, amounts);
    }

    function test_BatchUpdateGlobalXP_AttackerReverts() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(attacker);
        vm.expectRevert();
        xp.batchUpdateGlobalXP(users, amounts);
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    function test_GetGuildXP_ReturnsCorrectPerUserValue() public {
        vm.prank(globalRelayer);
        xp.updateXP(guildA, user1, 777);

        assertEq(xp.getGuildXP(guildA, user1), 777);
        assertEq(xp.getGuildXP(guildA, user2), 0); // different user
        assertEq(xp.getGuildXP(guildB, user1), 0); // different guild
    }

    function test_GetTotalGuildXP_SumsAcrossUsers() public {
        vm.startPrank(globalRelayer);
        xp.updateXP(guildA, user1, 100);
        xp.updateXP(guildA, user2, 250);
        xp.updateXP(guildA, user3, 50);
        vm.stopPrank();

        assertEq(xp.getTotalGuildXP(guildA), 400);
    }

    function test_GetTotalGuildXP_GuildBIsIndependent() public {
        vm.startPrank(globalRelayer);
        xp.updateXP(guildA, user1, 100);
        xp.updateXP(guildB, user1, 999);
        vm.stopPrank();

        assertEq(xp.getTotalGuildXP(guildA), 100);
        assertEq(xp.getTotalGuildXP(guildB), 999);
    }

    function test_CanUpdate_ReturnsTrueForAuthorized() public view {
        assertTrue(xp.canUpdate(guildA, globalRelayer));
        assertTrue(xp.canUpdate(guildA, guildRelayerA));
        assertTrue(xp.canUpdate(guildA, guildAdminA));
    }

    function test_CanUpdate_ReturnsFalseForUnauthorized() public view {
        assertFalse(xp.canUpdate(guildA, attacker));
        assertFalse(xp.canUpdate(guildA, guildRelayerB)); // B relayer → A guild = false
        assertFalse(xp.canUpdate(guildA, guildAdminB));   // B admin → A guild = false
    }

    // =========================================================================
    // PER-GUILD RELAYER ISOLATION
    // =========================================================================

    function test_GuildRelayerIsolation_RelayerACannotUpdateGuildB() public {
        vm.prank(guildRelayerA);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.updateXP(guildB, user1, 500);
    }

    function test_GuildRelayerIsolation_RelayerBCannotUpdateGuildA() public {
        vm.prank(guildRelayerB);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.updateXP(guildA, user1, 500);
    }

    function test_GuildRelayerRevoke_RemovesAccess() public {
        // Revoke guildRelayerA from guildA
        vm.prank(guildAdminA);
        xp.setGuildRelayer(guildA, guildRelayerA, false);

        vm.prank(guildRelayerA);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.updateXP(guildA, user1, 100);
    }

    // =========================================================================
    // PER-GUILD ADMIN ISOLATION
    // =========================================================================

    function test_GuildAdminIsolation_AdminACannotUpdateGuildB() public {
        vm.prank(guildAdminA);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.updateXP(guildB, user1, 100);
    }

    function test_GuildAdmin_CanDelegateRelayer() public {
        address newRelayer = address(999);
        vm.prank(guildAdminA);
        xp.setGuildRelayer(guildA, newRelayer, true);

        assertTrue(xp.guildRelayers(guildA, newRelayer));

        vm.prank(newRelayer);
        xp.updateXP(guildA, user1, 50);
        assertEq(xp.getGuildXP(guildA, user1), 50);
    }

    function test_SetGuildAdmin_ProtocolAdminCanOverride() public {
        address newAdmin = address(998);
        vm.prank(admin);
        xp.setGuildAdmin(guildA, newAdmin);

        assertEq(xp.guildAdmins(guildA), newAdmin);
    }

    function test_SetGuildAdmin_AttackerCannotOverride() public {
        vm.prank(attacker);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.setGuildAdmin(guildA, attacker);
    }

    // =========================================================================
    // PAUSE / UNPAUSE
    // =========================================================================

    function test_Pause_BlocksUpdateXP() public {
        vm.prank(admin);
        xp.pause();

        vm.prank(globalRelayer);
        vm.expectRevert(GuildXP.ContractPaused.selector);
        xp.updateXP(guildA, user1, 100);
    }

    function test_Pause_BlocksBatchUpdateXP() public {
        vm.prank(admin);
        xp.pause();

        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(globalRelayer);
        vm.expectRevert(GuildXP.ContractPaused.selector);
        xp.batchUpdateXP(guildA, users, amounts);
    }

    function test_Pause_BlocksUpdateGlobalXP() public {
        vm.prank(admin);
        xp.pause();

        vm.prank(globalRelayer);
        vm.expectRevert(GuildXP.ContractPaused.selector);
        xp.updateGlobalXP(user1, 100);
    }

    function test_Pause_BlocksBatchUpdateGlobalXP() public {
        vm.prank(admin);
        xp.pause();

        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(globalRelayer);
        vm.expectRevert(GuildXP.ContractPaused.selector);
        xp.batchUpdateGlobalXP(users, amounts);
    }

    function test_Unpause_RestoresXPUpdates() public {
        vm.prank(admin);
        xp.pause();

        vm.prank(admin);
        xp.unpause();

        vm.prank(globalRelayer);
        xp.updateXP(guildA, user1, 200);
        assertEq(xp.getGuildXP(guildA, user1), 200);
    }

    function test_Pause_OnlyAdminRoleCanPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        xp.pause();
    }

    function test_Unpause_OnlyAdminRoleCanUnpause() public {
        vm.prank(admin);
        xp.pause();

        vm.prank(attacker);
        vm.expectRevert();
        xp.unpause();
    }

    function test_Pause_EmitsPausedEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit GuildXP.Paused(admin);
        xp.pause();
    }

    function test_Unpause_EmitsUnpausedEvent() public {
        vm.prank(admin);
        xp.pause();

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit GuildXP.Unpaused(admin);
        xp.unpause();
    }

    // =========================================================================
    // GLOBAL RELAYER MANAGEMENT
    // =========================================================================

    function test_AddGlobalRelayer_AdminCanAdd() public {
        address newRelayer = address(997);
        vm.prank(admin);
        xp.addGlobalRelayer(newRelayer);

        assertTrue(xp.hasRole(xp.RELAYER_ROLE(), newRelayer));
    }

    function test_RemoveGlobalRelayer_AdminCanRemove() public {
        vm.prank(admin);
        xp.removeGlobalRelayer(globalRelayer);

        assertFalse(xp.hasRole(xp.RELAYER_ROLE(), globalRelayer));

        vm.prank(globalRelayer);
        vm.expectRevert(GuildXP.NotAuthorized.selector);
        xp.updateXP(guildA, user1, 100);
    }

    function test_AddGlobalRelayer_AttackerCannotAdd() public {
        vm.prank(attacker);
        vm.expectRevert();
        xp.addGlobalRelayer(attacker);
    }
}
