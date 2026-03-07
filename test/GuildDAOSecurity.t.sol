// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { GuildDAO } from "../src/GuildDAO.sol";
import { GuildFactory } from "../src/GuildFactory.sol";

contract GuildDAOSecurityTest is Test {
    GuildFactory public factory;
    GuildDAO public guild;

    address public admin = address(1);
    address public officer = address(2);
    address public treasury = address(3);

    function setUp() public {
        factory = new GuildFactory();
        vm.prank(admin);
        (, address guildAddress) = factory.createGuild("Test Guild", treasury, 500);
        guild = GuildDAO(guildAddress);

        // Admin adds officer as member and grants role
        vm.startPrank(admin);
        guild.addMember(officer);
        guild.grantOfficerRole(officer);
        vm.stopPrank();
    }

    function test_OfficerCanRemoveAdmin() public {
        assertTrue(guild.isAdmin(admin));
        assertTrue(guild.isMember(admin));

        // Officer removes admin
        vm.prank(officer);
        guild.removeMember(admin);

        assertFalse(guild.isMember(admin));

        // Admin should no longer have the role
        assertFalse(guild.isAdmin(admin));
        assertFalse(guild.isOfficer(admin));
        assertFalse(guild.isCurator(admin));
    }
}
