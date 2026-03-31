// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**6);
    }
}

contract SentinelMissionFactoryDeployTest is Test {
    MockUSDC public usdc;
    MissionFactory public factory;

    function setUp() public {
        usdc = new MockUSDC();
        factory = new MissionFactory(address(usdc), address(0x2));
    }

    function test_MissionEscrowImplIsInitialized() public {
        MissionEscrow impl = MissionEscrow(factory.escrowImplementation());

        vm.prank(address(0xbad));
        // We expect it to revert with "Initializable: contract is already initialized"
        vm.expectRevert();
        impl.initialize(1, address(0xbad), 100e6, 1, address(0), bytes32(0), bytes32(0), address(0x2), address(usdc), address(0x3), address(0));
    }
}
