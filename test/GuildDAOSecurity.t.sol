// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { GuildDAO } from "../src/GuildDAO.sol";
import { GuildFactory } from "../src/GuildFactory.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract GuildDAOSecurityTest is Test {
    GuildFactory factory;
    GuildDAO guild;
    address admin = address(0x1);
    address member1 = address(0x2);

    function setUp() public {
        factory = new GuildFactory();

        vm.startPrank(admin);
        (, address guildProxy) = factory.createGuild("SecurityGuild", admin, 500);
        guild = GuildDAO(guildProxy);

        guild.addMember(member1);
        guild.grantOfficerRole(member1);
        guild.grantCuratorRole(member1);
        vm.stopPrank();
    }

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
}
