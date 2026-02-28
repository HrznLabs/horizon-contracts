// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { IDisputeResolver } from "../src/interfaces/IDisputeResolver.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

// Fake Escrow that mocks MissionEscrow behavior
contract FakeMissionEscrow is IMissionEscrow {
    address public poster;
    address public performer;
    address public disputeResolver;

    constructor(address _poster, address _performer, address _disputeResolver) {
        poster = _poster;
        performer = _performer;
        disputeResolver = _disputeResolver;
    }

    function getParams() external view returns (MissionParams memory) {
        return MissionParams({
            poster: poster,
            rewardAmount: 100e6,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + 1 days,
            guild: address(0),
            metadataHash: bytes32(0),
            locationHash: bytes32(0)
        });
    }

    function getRuntime() external view returns (MissionRuntime memory) {
        return MissionRuntime({
            performer: performer,
            state: MissionState.Accepted,
            proofHash: bytes32(0),
            disputeRaised: false
        });
    }

    function raiseDispute(bytes32) external {
        if (msg.sender != disputeResolver) revert NotDisputeResolver();
        // Do nothing, just pretend to raise dispute
    }

    // Boilerplate for interface compliance
    function initialize(uint96, address, uint96, uint64, address, bytes32, bytes32, address, address, address, address) external {}
    function acceptMission() external {}
    function submitProof(bytes32) external {}
    function approveCompletion() external {}
    function cancelMission() external {}
    function claimExpired() external {}
    function settleDispute(uint8, uint256) external {}
    function getMissionId() external view returns (uint256) { return 1; }
    function getDisputeResolver() external view returns (address) { return disputeResolver; }
    function getParticipants() external view returns (address, address, MissionState) {
        return (poster, performer, MissionState.Accepted);
    }
}

contract FakeMissionDisputeTest is Test {
    DisputeResolver public disputeResolver;
    MockERC20 public usdc;
    FakeMissionEscrow public fakeEscrow;

    address public attacker = address(0x1337);
    address public resolversDAO = address(0x2);
    address public protocolDAO = address(0x3);
    address public protocolTreasury = address(0x4);
    address public resolverTreasury = address(0x5);
    address public missionFactory = address(0x6); // Mock factory address

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy DisputeResolver
        disputeResolver = new DisputeResolver(
            address(usdc),
            missionFactory,
            resolversDAO,
            protocolDAO,
            protocolTreasury,
            resolverTreasury
        );

        // Deploy Fake Escrow
        // Attacker is both poster and performer to easily bypass checks
        fakeEscrow = new FakeMissionEscrow(attacker, attacker, address(disputeResolver));

        // Mint USDC to attacker for DDR
        usdc.mint(attacker, 1000e6);
        vm.prank(attacker);
        usdc.approve(address(disputeResolver), 1000e6);
    }

    function test_CreateDisputeWithFakeEscrow() public {
        vm.startPrank(attacker);

        // Mock MissionFactory call
        // Factory returns address(0) or some other address for missionId 999
        vm.mockCall(
            missionFactory,
            abi.encodeWithSignature("getMission(uint256)", 999),
            abi.encode(address(0)) // Factory says mission doesn't exist
        );

        // Expect Revert: InvalidEscrow
        vm.expectRevert(IDisputeResolver.InvalidEscrow.selector);
        disputeResolver.createDispute(
            address(fakeEscrow),
            999,
            keccak256("fake_evidence")
        );

        vm.stopPrank();
    }
}
