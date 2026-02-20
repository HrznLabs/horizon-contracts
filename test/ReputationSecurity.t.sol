// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { ReputationAttestations } from "../src/ReputationAttestations.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";

contract ReputationSecurity is Test {
    ReputationAttestations public reputation;
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public attacker = address(0xBADC0DE);
    address public victim = address(0xDEADBEEF);

    uint256 public constant REWARD_AMOUNT = 100e6;
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");
    bytes32 public constant PROOF_HASH = keccak256("proof");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy dependencies
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(address(usdc), address(4), address(5), address(6));
        factory = new MissionFactory(address(usdc), address(router));
        factory.setDisputeResolver(address(888));
        router.setMissionFactory(address(factory));

        reputation = new ReputationAttestations();
        reputation.setMissionFactory(address(factory));

        vm.stopPrank();

        usdc.mint(poster, 1000e6);
    }

    function test_Exploit_ReputationBypass_Fixed() public {
        // Attack: Rate victim for a non-existent mission
        vm.startPrank(attacker);

        // 1. Test invalid mission (not found)
        // Since factory.getMission reverts if not found, we expect revert
        vm.expectRevert(MissionFactory.MissionNotFound.selector);
        reputation.submitRating(999, victim, 5, keccak256("fake rating"));

        vm.stopPrank();

        // 2. Setup a valid mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );
        vm.stopPrank();

        address escrowAddress = factory.missions(missionId);
        IMissionEscrow escrow = IMissionEscrow(escrowAddress);

        // 3. Test mission not completed
        vm.startPrank(attacker);
        vm.expectRevert(ReputationAttestations.MissionNotCompleted.selector);
        reputation.submitRating(missionId, victim, 5, keccak256("fake rating"));
        vm.stopPrank();

        // Complete mission
        vm.startPrank(performer);
        escrow.acceptMission();
        escrow.submitProof(PROOF_HASH);
        vm.stopPrank();

        vm.startPrank(poster);
        escrow.approveCompletion();
        vm.stopPrank();

        // 4. Test non-participant rating
        vm.startPrank(attacker);
        vm.expectRevert(ReputationAttestations.NotParticipant.selector);
        reputation.submitRating(missionId, victim, 5, keccak256("fake rating"));
        vm.stopPrank();

        // 5. Test rating wrong counterparty
        vm.startPrank(poster);
        // Poster rates attacker (not performer)
        vm.expectRevert(ReputationAttestations.InvalidCounterparty.selector);
        reputation.submitRating(missionId, attacker, 5, keccak256("bad rating"));
        vm.stopPrank();

        // 6. Test valid rating
        vm.startPrank(poster);
        reputation.submitRating(missionId, performer, 5, keccak256("Good job"));
        vm.stopPrank();

        ReputationAttestations.Rating memory rating =
            reputation.getRating(missionId, poster, performer);
        assertEq(rating.score, 5);

        console.log("Fix verified: Exploit prevented and valid rating succeeded");
    }
}
