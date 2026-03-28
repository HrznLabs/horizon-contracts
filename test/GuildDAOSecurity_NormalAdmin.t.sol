// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { GuildDAO } from "../src/GuildDAO.sol";
import { GuildFactory } from "../src/GuildFactory.sol";

contract GuildDAOSecurityTest_NormalAdmin is Test {
    GuildFactory public factory;
    GuildDAO public guild;

    address public admin = address(1);
    address public officer = address(2);
    address public normalAdmin = address(3);
    address public treasury = address(4);

    function setUp() public {
        factory = new GuildFactory();
        vm.prank(admin);
        (, address guildAddress) = factory.createGuild("Test Guild", treasury, 500);
        guild = GuildDAO(guildAddress);

        // Admin adds officer as member and grants role
        vm.startPrank(admin);
        guild.addMember(officer);
        guild.grantOfficerRole(officer);

        guild.addMember(normalAdmin);
        guild.grantRole(guild.ADMIN_ROLE(), normalAdmin);
        vm.stopPrank();
    }

    function test_OfficerCannotRemoveNormalAdmin() public {
        assertTrue(guild.isAdmin(normalAdmin));
        assertTrue(guild.isMember(normalAdmin));

        // Officer tries to remove normal admin
        vm.prank(officer);
        vm.expectRevert(GuildDAO.CannotRemoveAdmin.selector);
        guild.removeMember(normalAdmin);

        assertTrue(guild.isMember(normalAdmin));

        // Normal admin should still have the role
        assertTrue(guild.isAdmin(normalAdmin));
    }
}
