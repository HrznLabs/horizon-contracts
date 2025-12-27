// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MissionFactoryTest is Test {
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy PaymentRouter
        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury
        );

        // Deploy MissionFactory
        factory = new MissionFactory(address(usdc), address(router));

        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, 1000e6);
    }

    function test_CreateMission() public {
        vm.startPrank(poster);
        
        // Approve USDC spending
        usdc.approve(address(factory), REWARD_AMOUNT);

        // Create mission
        uint256 expiresAt = block.timestamp + 1 days;
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT,
            expiresAt,
            address(0), // No guild
            METADATA_HASH,
            LOCATION_HASH
        );

        vm.stopPrank();

        // Verify mission created
        assertEq(missionId, 1);
        assertEq(factory.missionCount(), 1);

        // Verify escrow deployed
        address escrow = factory.missions(missionId);
        assertTrue(escrow != address(0));

        // Verify escrow holds USDC
        assertEq(usdc.balanceOf(escrow), REWARD_AMOUNT);

        // Verify mission params
        IMissionEscrow.MissionParams memory params = factory.getMissionParams(missionId);
        assertEq(params.poster, poster);
        assertEq(params.rewardAmount, REWARD_AMOUNT);
        assertEq(params.expiresAt, expiresAt);
        assertEq(params.metadataHash, METADATA_HASH);
        assertEq(params.locationHash, LOCATION_HASH);

        // Verify mission state is Open
        IMissionEscrow.MissionRuntime memory runtime = factory.getMissionRuntime(missionId);
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Open));
    }

    function test_RevertWhen_RewardTooLow() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), 0.5e6);

        vm.expectRevert(MissionFactory.InvalidRewardAmount.selector);
        factory.createMission(
            0.5e6, // Below minimum
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );

        vm.stopPrank();
    }

    function test_RevertWhen_DurationTooShort() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);

        vm.expectRevert(MissionFactory.InvalidDuration.selector);
        factory.createMission(
            REWARD_AMOUNT,
            block.timestamp + 30 minutes, // Below minimum
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );

        vm.stopPrank();
    }

    function test_AcceptMission() public {
        // Create mission
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

        // Accept mission as performer
        address escrow = factory.missions(missionId);
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        // Verify state changed
        IMissionEscrow.MissionRuntime memory runtime = factory.getMissionRuntime(missionId);
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Accepted));
        assertEq(runtime.performer, performer);
    }

    function test_SubmitProof() public {
        // Create and accept mission
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

        // Submit proof
        bytes32 proofHash = keccak256("proof");
        vm.prank(performer);
        IMissionEscrow(escrow).submitProof(proofHash);

        // Verify state
        IMissionEscrow.MissionRuntime memory runtime = factory.getMissionRuntime(missionId);
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Submitted));
        assertEq(runtime.proofHash, proofHash);
    }

    function test_CompleteMission() public {
        // Create, accept, and submit
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

        vm.prank(performer);
        IMissionEscrow(escrow).submitProof(keccak256("proof"));

        // Approve completion
        vm.prank(poster);
        IMissionEscrow(escrow).approveCompletion();

        // Verify state
        IMissionEscrow.MissionRuntime memory runtime = factory.getMissionRuntime(missionId);
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Completed));

        // Verify performer received payment (minus fees)
        assertTrue(usdc.balanceOf(performer) > 0);
    }

    function test_CancelMission() public {
        // Create mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );

        uint256 posterBalanceBefore = usdc.balanceOf(poster);

        // Cancel mission
        address escrow = factory.missions(missionId);
        IMissionEscrow(escrow).cancelMission();

        vm.stopPrank();

        // Verify state
        IMissionEscrow.MissionRuntime memory runtime = factory.getMissionRuntime(missionId);
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Cancelled));

        // Verify refund
        assertEq(usdc.balanceOf(poster), posterBalanceBefore + REWARD_AMOUNT);
    }
}


