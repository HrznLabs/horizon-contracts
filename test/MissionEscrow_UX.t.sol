// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract MissionEscrowUXTest is Test {
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public randomUser = address(4);

    // Treasuries
    address public protocolTreasury = address(10);
    address public resolverTreasury = address(11);
    address public labsTreasury = address(12);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy PaymentRouter
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury);

        // Deploy MissionFactory
        factory = new MissionFactory(address(usdc), address(router));
        factory.setDisputeResolver(address(999));

        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, 1000e6);
    }

    function test_RevertWithNotParty_WhenRandomUserRaisesDispute() public {
        // 1. Create mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        // 2. Accept mission (to get to Accepted state where dispute is allowed)
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        // 3. Random user tries to raise dispute
        vm.prank(randomUser);

        // EXPECTED BEHAVIOR: Reverts with NotParty
        vm.expectRevert(IMissionEscrow.NotParty.selector);
        IMissionEscrow(escrow).raiseDispute(keccak256("evidence"));
    }
}
