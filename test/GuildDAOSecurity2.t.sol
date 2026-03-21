// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { GuildDAO } from "../src/GuildDAO.sol";
import { GuildFactory } from "../src/GuildFactory.sol";

contract GuildDAOSecurityTest2 is Test {
    GuildFactory public factory;
    GuildDAO public guild;

    address public defaultAdmin = address(1);
    address public officer = address(2);
    address public normalAdmin = address(3);
    address public treasury = address(4);

    function setUp() public {
        factory = new GuildFactory();
        vm.prank(defaultAdmin);
        (, address guildAddress) = factory.createGuild("Test Guild", treasury, 500);
        guild = GuildDAO(guildAddress);

        vm.startPrank(defaultAdmin);
        // Add officer
        guild.addMember(officer);
        guild.grantOfficerRole(officer);

        // Add normal admin
        guild.addMember(normalAdmin);
        guild.grantRole(guild.ADMIN_ROLE(), normalAdmin);
        vm.stopPrank();
    }

    function test_OfficerCannotRemoveNormalAdmin() public {
        assertTrue(guild.isAdmin(normalAdmin));
        assertFalse(guild.hasRole(guild.DEFAULT_ADMIN_ROLE(), normalAdmin));

        // Officer tries to remove normal admin, should revert now
        vm.prank(officer);
        vm.expectRevert(GuildDAO.CannotRemoveAdmin.selector);
        guild.removeMember(normalAdmin);

        // Normal admin is NOT removed and retains their role!
        assertTrue(guild.isMember(normalAdmin));
        assertTrue(guild.isAdmin(normalAdmin));
    }
}
