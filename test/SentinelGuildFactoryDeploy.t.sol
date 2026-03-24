// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { GuildFactory } from "../src/GuildFactory.sol";
import { GuildDAO } from "../src/GuildDAO.sol";

contract SentinelGuildFactoryDeployTest is Test {
    GuildFactory public factory;

    function setUp() public {
        factory = new GuildFactory();
    }

    function test_GuildDAOImplIsInitialized() public {
        GuildDAO impl = GuildDAO(factory.guildImplementation());

        vm.prank(address(0xbad));
        // We expect it to revert with "Initializable: contract is already initialized"
        vm.expectRevert();
        impl.initialize("Hack", address(0xbad), address(0xbad), 0);
    }
}
