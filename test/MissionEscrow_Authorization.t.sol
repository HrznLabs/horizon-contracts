// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MissionEscrowAuthorizationTest is Test {
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public poster = address(2);
    address public performer = address(3);
    address public stranger = address(99);

    uint256 public constant REWARD_AMOUNT = 100e6;
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(address(usdc), address(4), address(5), address(6));
        factory = new MissionFactory(address(usdc), address(router));
        factory.setDisputeResolver(address(999));
        usdc.mint(poster, 1000e6);
    }

    function test_RaiseDispute_RevertMessage() public {
        // Setup: Create and accept mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        // Stranger tries to raise dispute
        vm.prank(stranger);

        // Expecting NotParty
        vm.expectRevert(IMissionEscrow.NotParty.selector);
        IMissionEscrow(escrow).raiseDispute(keccak256("evidence"));
    }
}
