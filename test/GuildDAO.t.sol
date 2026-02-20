// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { GuildDAO } from "../src/GuildDAO.sol";
import { GuildFactory } from "../src/GuildFactory.sol";

contract GuildDAOTest is Test {
    GuildDAO public guildImplementation;
    GuildDAO public guild;
    GuildFactory public factory;

    address public admin = address(1);
    address public member1 = address(2);
    address public treasury = address(3);

    function setUp() public {
        vm.startPrank(admin);
        factory = new GuildFactory();

        // Create a guild via factory to test clone behavior
        (uint256 guildId, address guildAddress) = factory.createGuild("Test Guild", treasury, 500);
        guild = GuildDAO(guildAddress);

        vm.stopPrank();
    }

    function test_Initialize() public {
        GuildDAO.GuildConfig memory config = guild.getConfig();
        assertEq(config.name, "Test Guild");
        assertEq(config.admin, admin);
        assertEq(config.treasury, treasury);
        assertEq(config.guildFeeBps, 500);

        assertTrue(guild.hasRole(guild.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(guild.hasRole(guild.ADMIN_ROLE(), admin));
        assertTrue(guild.hasRole(guild.OFFICER_ROLE(), admin));
        assertTrue(guild.hasRole(guild.CURATOR_ROLE(), admin));

        assertTrue(guild.isMember(admin));
    }

    function test_AddMember() public {
        vm.startPrank(admin);

        // Admin is officer, so can add member
        guild.addMember(member1);

        vm.stopPrank();

        assertTrue(guild.isMember(member1));

        // Verify member data via getter
        (bool isMember, uint256 joinedAt, uint256 leftAt) = guild.members(member1);
        assertTrue(isMember);
        assertEq(joinedAt, block.timestamp);
        assertEq(leftAt, 0);
    }

    function test_RemoveMember() public {
        vm.startPrank(admin);
        guild.addMember(member1);

        // Advance time
        vm.warp(block.timestamp + 100);

        guild.removeMember(member1);
        vm.stopPrank();

        assertFalse(guild.isMember(member1));

        (bool isMember, uint256 joinedAt, uint256 leftAt) = guild.members(member1);
        assertFalse(isMember);
        assertEq(joinedAt, block.timestamp - 100);
        assertEq(leftAt, block.timestamp);
    }

    function test_RevertWhen_AddingExistingMember() public {
        vm.startPrank(admin);
        guild.addMember(member1);

        vm.expectRevert(GuildDAO.AlreadyMember.selector);
        guild.addMember(member1);
        vm.stopPrank();
    }

    function test_RevertWhen_RemovingNonMember() public {
        vm.startPrank(admin);
        vm.expectRevert(GuildDAO.NotMember.selector);
        guild.removeMember(member1);
        vm.stopPrank();
    }
}
