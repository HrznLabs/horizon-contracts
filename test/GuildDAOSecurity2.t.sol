// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { GuildDAO } from "../src/GuildDAO.sol";
import { GuildFactory } from "../src/GuildFactory.sol";

contract GuildDAOSecurity2Test is Test {
    GuildFactory public factory;
    GuildDAO public guild;

    address public defaultAdmin = address(1);
    address public normalAdmin = address(2);
    address public officer = address(3);
    address public treasury = address(4);

    function setUp() public {
        factory = new GuildFactory();
        vm.prank(defaultAdmin);
        (, address guildAddress) = factory.createGuild("Test Guild", treasury, 500);
        guild = GuildDAO(guildAddress);

        vm.startPrank(defaultAdmin);
        guild.addMember(normalAdmin);
        guild.grantRole(guild.ADMIN_ROLE(), normalAdmin);
        guild.addMember(officer);
        guild.grantOfficerRole(officer);
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
        assertTrue(guild.isAdmin(normalAdmin));
    }
}
