// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { GuildDAO } from "../src/GuildDAO.sol";
import { GuildFactory } from "../src/GuildFactory.sol";

/// @notice Ported from HrznLabs/horizon-contracts 745a86f (Sentinel #159) plus last-admin guard.
contract GuildDAOSecurityTest is Test {
    GuildFactory factory;
    GuildDAO guild;
    address admin = address(0x1);
    address member1 = address(0x2);
    address officer = address(0x3);
    address admin2 = address(0x4);

    function setUp() public {
        factory = new GuildFactory();

        vm.startPrank(admin);
        (, address guildProxy) = factory.createGuild("SecurityGuild", admin, 500);
        guild = GuildDAO(guildProxy);

        guild.addMember(member1);
        guild.grantOfficerRole(member1);
        guild.grantCuratorRole(member1);

        guild.addMember(officer);
        guild.grantOfficerRole(officer);
        vm.stopPrank();
    }

    // --- Ported (Sentinel #159) -------------------------------------------------------------

    function test_RemoveMemberRevokesRoles() public {
        assertTrue(guild.isMember(member1));
        assertTrue(guild.isOfficer(member1));
        assertTrue(guild.isCurator(member1));

        vm.prank(admin);
        guild.removeMember(member1);

        assertFalse(guild.isMember(member1));
        assertFalse(guild.isOfficer(member1));
        assertFalse(guild.isCurator(member1));
        assertFalse(guild.isAdmin(member1));
    }

    function test_RemovedMemberCannotUseFormerPrivileges() public {
        bytes32 officerRole = guild.OFFICER_ROLE();
        bytes32 curatorRole = guild.CURATOR_ROLE();
        vm.prank(admin);
        guild.removeMember(member1);

        vm.startPrank(member1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, member1, officerRole
            )
        );
        guild.addMember(address(0xBEEF));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, member1, curatorRole
            )
        );
        guild.publishToBoard(1);
        vm.stopPrank();
    }

    // --- Last-admin guard -------------------------------------------------------------------

    function test_InitialAdminCounts() public view {
        assertEq(guild.adminCount(), 1);
        assertEq(guild.defaultAdminCount(), 1);
    }

    function test_RevertWhen_RemovingLastAdmin() public {
        vm.prank(admin);
        vm.expectRevert(GuildDAO.CannotRemoveLastAdmin.selector);
        guild.removeMember(admin);

        assertTrue(guild.isMember(admin));
        assertTrue(guild.isAdmin(admin));
        assertTrue(guild.hasRole(guild.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_RevertWhen_LastAdminRenounces() public {
        bytes32 adminRole = guild.ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(GuildDAO.CannotRemoveLastAdmin.selector);
        guild.renounceRole(adminRole, admin);
    }

    function test_RevertWhen_LastDefaultAdminRevoked() public {
        bytes32 defaultAdmin = guild.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(GuildDAO.CannotRemoveLastAdmin.selector);
        guild.revokeRole(defaultAdmin, admin);
    }

    function test_CanRemoveAdminWhenAnotherAdminExists() public {
        _addSecondFullAdmin();

        vm.prank(admin2);
        guild.removeMember(admin);

        assertFalse(guild.isMember(admin));
        assertFalse(guild.isAdmin(admin));
        assertFalse(guild.hasRole(guild.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(guild.isOfficer(admin));
        assertFalse(guild.isCurator(admin));
        assertEq(guild.adminCount(), 1);
        assertEq(guild.defaultAdminCount(), 1);

        // admin2 is now the last admin and is protected.
        vm.prank(admin2);
        vm.expectRevert(GuildDAO.CannotRemoveLastAdmin.selector);
        guild.removeMember(admin2);
    }

    function test_RevertWhen_OfficerRemovesAdmin() public {
        _addSecondFullAdmin();
        bytes32 defaultAdmin = guild.DEFAULT_ADMIN_ROLE();

        vm.prank(officer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, officer, defaultAdmin
            )
        );
        guild.removeMember(admin2);
        assertTrue(guild.isAdmin(admin2));
    }

    function test_OfficerCanStillRemovePlainMember() public {
        address plain = address(0x5);
        vm.prank(admin);
        guild.addMember(plain);

        vm.prank(officer);
        guild.removeMember(plain);
        assertFalse(guild.isMember(plain));
    }

    // --- Role-admin enforcement (mirrors OZ revokeRole) -------------------------------------

    /// @dev (a) ADMIN_ROLE without DEFAULT_ADMIN_ROLE cannot strip the guild superadmin.
    function test_RevertWhen_AdminOnlyRemovesDefaultAdmin() public {
        _addSecondFullAdmin(); // keep last-admin guard out of the way
        address adminOnly = _addAdminOnly(address(0x6));
        bytes32 defaultAdmin = guild.DEFAULT_ADMIN_ROLE();

        vm.prank(adminOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, adminOnly, defaultAdmin
            )
        );
        guild.removeMember(admin);

        assertTrue(guild.isMember(admin));
        assertTrue(guild.hasRole(defaultAdmin, admin));
        assertTrue(guild.isAdmin(admin));
    }

    /// @dev (b) ADMIN_ROLE without DEFAULT_ADMIN_ROLE cannot strip a peer ADMIN.
    function test_RevertWhen_AdminOnlyRemovesPeerAdmin() public {
        address adminOnly = _addAdminOnly(address(0x6));
        address peer = _addAdminOnly(address(0x7));
        bytes32 defaultAdmin = guild.DEFAULT_ADMIN_ROLE();

        vm.prank(adminOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, adminOnly, defaultAdmin
            )
        );
        guild.removeMember(peer);

        assertTrue(guild.isMember(peer));
        assertTrue(guild.isAdmin(peer));
        assertEq(guild.adminCount(), 3);
    }

    /// @dev (c) An officer cannot strip OFFICER/CURATOR from a peer officer: OZ `revokeRole`
    ///      requires getRoleAdmin(OFFICER_ROLE) == DEFAULT_ADMIN_ROLE.
    function test_RevertWhen_OfficerRemovesPeerOfficer() public {
        bytes32 officerRole = guild.OFFICER_ROLE();
        bytes32 roleAdmin = guild.getRoleAdmin(officerRole);
        assertEq(roleAdmin, guild.DEFAULT_ADMIN_ROLE());

        vm.prank(officer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, officer, roleAdmin
            )
        );
        guild.removeMember(member1);

        assertTrue(guild.isMember(member1));
        assertTrue(guild.isOfficer(member1));
        assertTrue(guild.isCurator(member1));
    }

    /// @dev Same actor is rejected by OZ's public revokeRole -> removeMember matches it.
    function test_RemoveMemberMatchesRevokeRoleAuthority() public {
        bytes32 officerRole = guild.OFFICER_ROLE();
        bytes32 defaultAdmin = guild.DEFAULT_ADMIN_ROLE();
        vm.prank(officer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, officer, defaultAdmin
            )
        );
        guild.revokeRole(officerRole, member1);
    }

    /// @dev (d) DEFAULT_ADMIN holder WITHOUT ADMIN_ROLE can remove an admin-level member and
    ///      every role is stripped.
    function test_DefaultAdminOnlyCanRemoveAdminLevelMember() public {
        _addSecondFullAdmin();
        bytes32 defaultAdmin = guild.DEFAULT_ADMIN_ROLE();
        address superOnly = address(0x8);
        vm.startPrank(admin);
        guild.addMember(superOnly);
        guild.grantRole(defaultAdmin, superOnly);
        vm.stopPrank();
        assertFalse(guild.isAdmin(superOnly));
        assertFalse(guild.isOfficer(superOnly));

        vm.prank(superOnly);
        guild.removeMember(admin2);

        assertFalse(guild.isMember(admin2));
        assertFalse(guild.hasRole(defaultAdmin, admin2));
        assertFalse(guild.isAdmin(admin2));
        assertFalse(guild.isOfficer(admin2));
        assertFalse(guild.isCurator(admin2));
        assertEq(guild.adminCount(), 1);
        assertEq(guild.defaultAdminCount(), 2); // admin + superOnly
    }

    function test_RemovedAdminCannotRegrantItself() public {
        _addSecondFullAdmin();
        vm.prank(admin2);
        guild.removeMember(admin);

        bytes32 adminRole = guild.ADMIN_ROLE();
        bytes32 defaultAdmin = guild.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, defaultAdmin
            )
        );
        guild.grantRole(adminRole, admin);
    }

    function test_CountsIgnoreRedundantGrants() public {
        bytes32 adminRole = guild.ADMIN_ROLE();
        vm.prank(admin);
        guild.grantRole(adminRole, admin); // already held: no-op
        assertEq(guild.adminCount(), 1);
    }

    function _addAdminOnly(address who) internal returns (address) {
        bytes32 adminRole = guild.ADMIN_ROLE();
        vm.startPrank(admin);
        guild.addMember(who);
        guild.grantRole(adminRole, who);
        guild.grantOfficerRole(who);
        vm.stopPrank();
        return who;
    }

    function _addSecondFullAdmin() internal {
        bytes32 adminRole = guild.ADMIN_ROLE();
        bytes32 defaultAdmin = guild.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        guild.addMember(admin2);
        guild.grantRole(adminRole, admin2);
        guild.grantRole(defaultAdmin, admin2);
        guild.grantOfficerRole(admin2);
        vm.stopPrank();
        assertEq(guild.adminCount(), 2);
        assertEq(guild.defaultAdminCount(), 2);
    }
}
