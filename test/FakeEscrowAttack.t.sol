// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { DisputeResolver } from "../src/DisputeResolver.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract FakeEscrow is IMissionEscrow {
    MissionParams public params;
    MissionRuntime public runtime;

    function setParams(address poster, uint256 rewardAmount) external {
        params.poster = poster;
        params.rewardAmount = rewardAmount;
    }

    function setRuntime(address performer, MissionState state) external {
        runtime.performer = performer;
        runtime.state = state;
    }

    function getParams() external view returns (MissionParams memory) {
        return params;
    }

    function getRuntime() external view returns (MissionRuntime memory) {
        return runtime;
    }

    function raiseDispute(bytes32) external {}

    // Implement other interface functions as stubs
    function initialize(uint96, address, uint96, uint64, address, bytes32, bytes32, address, address, address, address) external {}
    function acceptMission() external {}
    function submitProof(bytes32) external {}
    function approveCompletion() external {}
    function cancelMission() external {}
    function claimExpired() external {}
    function getMissionId() external view returns (uint256) { return 0; }
    function getDisputeResolver() external view returns (address) { return address(0); }
    function getParticipants() external view returns (address, address, MissionState) {
        return (params.poster, runtime.performer, runtime.state);
    }
    function settleDispute(uint8, uint256) external {}
}

contract FakeEscrowAttack is Test {
    MissionFactory public factory;
    PaymentRouter public paymentRouter;
    DisputeResolver public resolver;
    MockERC20 public usdc;

    address public owner = address(0x1);
    address public poster = address(0x2);
    address public performer = address(0x3);
    address public attacker = address(0x99);

    address public resolversDAO = address(0x4);
    address public protocolDAO = address(0x5);
    address public protocolTreasury = address(0x10);
    address public resolverTreasury = address(0x11);
    address public labsTreasury = address(0x12);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("USDC", "USDC", 6);
        paymentRouter = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury);

        factory = new MissionFactory(address(usdc), address(paymentRouter));

        resolver = new DisputeResolver(
            address(usdc), address(factory), resolversDAO, protocolDAO, protocolTreasury, resolverTreasury
        );

        factory.setDisputeResolver(address(resolver));
        paymentRouter.setMissionFactory(address(factory));
        vm.stopPrank();

        usdc.mint(poster, 1000e6);
        usdc.mint(attacker, 1000e6);

        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);

        vm.prank(attacker);
        usdc.approve(address(resolver), 1000e6);
    }

    function test_FakeEscrowAttack() public {
        // 1. Poster creates a REAL mission (ID 1)
        vm.prank(poster);
        uint256 missionId = factory.createMission(REWARD_AMOUNT, block.timestamp + 1 days, address(0), bytes32(0), bytes32(0));

        // 2. Attacker deploys FakeEscrow
        vm.startPrank(attacker);
        FakeEscrow fakeEscrow = new FakeEscrow();
        // Attacker sets themselves as poster in fake escrow to bypass "NotParty" check
        fakeEscrow.setParams(attacker, REWARD_AMOUNT);
        fakeEscrow.setRuntime(address(0), IMissionEscrow.MissionState.Disputed); // Or Accepted/Submitted

        // 3. Attacker raises dispute linked to REAL missionId (1) but FAKE escrow
        // EXPECT REVERT
        vm.expectRevert(DisputeResolver.InvalidEscrow.selector);
        resolver.createDispute(address(fakeEscrow), missionId, keccak256("fake_evidence"));
        vm.stopPrank();

        // 4. Verification: No dispute created
        uint256[] memory disputes = resolver.getDisputesByMission(missionId);
        assertEq(disputes.length, 0);

        console.log("Attack prevented: Fake escrow rejected");
    }
}
