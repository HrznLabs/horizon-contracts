// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract SentinelFakeGuildAttack is Test {
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(address(usdc), address(4), address(5), address(6));
        factory = new MissionFactory(address(usdc), address(router));
        factory.setDisputeResolver(address(888));
        router.setMissionFactory(address(factory));
        vm.stopPrank();

        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);
    }

    function test_FakeGuildStealsFee_Reverts() public {
        vm.startPrank(poster);
        // Attacker (poster) sets themselves as guild
        // This should now revert since guildFactory is not set or the guild is invalid
        vm.expectRevert(MissionFactory.GuildFactoryNotSet.selector);
        uint256 missionId = factory.createMission(
            100e6, block.timestamp + 1 days, poster, bytes32(0), bytes32(0)
        );
        vm.stopPrank();
    }
}
