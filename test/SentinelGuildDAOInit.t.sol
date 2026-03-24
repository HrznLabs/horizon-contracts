// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { GuildDAO } from "../src/GuildDAO.sol";
import { GuildFactory } from "../src/GuildFactory.sol";

contract SentinelGuildDAOInitTest is Test {
    GuildDAO public implementation;

    function setUp() public {
        // Deploy raw implementation
        implementation = new GuildDAO();
    }

    function test_CannotInitializeImplementation() public {
        // Trying to take over the implementation contract
        vm.prank(address(0xbad));
        vm.expectRevert();
        implementation.initialize("Hack", address(0xbad), address(0xbad), 0);
    }
}
