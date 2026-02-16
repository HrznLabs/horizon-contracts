// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { ReputationAttestations } from "../src/ReputationAttestations.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract ReputationSecurityTest is Test {
    MissionFactory public factory;
    PaymentRouter public router;
    ReputationAttestations public reputation;
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
    bytes32 public constant COMMENT_HASH = keccak256("comment");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy PaymentRouter
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury);
        router.setMissionFactory(address(999)); // Temporary

        // Deploy MissionFactory
        factory = new MissionFactory(address(usdc), address(router));
        factory.setDisputeResolver(address(999));

        // Update router with real factory
        router.setMissionFactory(address(factory));

        // Deploy ReputationAttestations
        reputation = new ReputationAttestations();
        reputation.setMissionFactory(address(factory));

        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, 1000e6);
        vm.prank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
    }

    function test_RevertWhen_UnauthorizedRating() public {
        // 1. Create mission
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );

        address escrow = factory.missions(missionId);

        // 2. Accept and complete mission
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();
        vm.prank(performer);
        IMissionEscrow(escrow).submitProof(keccak256("proof"));
        vm.prank(poster);
        IMissionEscrow(escrow).approveCompletion();

        // 3. Random user tries to rate performer
        vm.prank(randomUser);
        vm.expectRevert(ReputationAttestations.NotAuthorized.selector);
        reputation.submitRating(missionId, performer, 5, COMMENT_HASH);
    }

    function test_AuthorizedRating() public {
        // 1. Create mission
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );

        address escrow = factory.missions(missionId);

        // 2. Accept and complete mission
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();
        vm.prank(performer);
        IMissionEscrow(escrow).submitProof(keccak256("proof"));
        vm.prank(poster);
        IMissionEscrow(escrow).approveCompletion();

        // 3. Poster rates performer
        vm.prank(poster);
        reputation.submitRating(missionId, performer, 5, COMMENT_HASH);

        // Verify rating
        ReputationAttestations.Rating memory rating =
            reputation.getRating(missionId, poster, performer);
        assertEq(rating.score, 5);

        // 4. Performer rates poster
        vm.prank(performer);
        reputation.submitRating(missionId, poster, 4, COMMENT_HASH);

        // Verify rating
        rating = reputation.getRating(missionId, performer, poster);
        assertEq(rating.score, 4);
    }

    function test_RevertWhen_RatingBeforeCompletion() public {
        // 1. Create mission
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );

        address escrow = factory.missions(missionId);

        // 2. Accept mission (State: Accepted)
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        // 3. Poster tries to rate performer before completion
        vm.prank(poster);
        vm.expectRevert(ReputationAttestations.MissionNotCompleted.selector);
        reputation.submitRating(missionId, performer, 5, COMMENT_HASH);
    }

    function test_RevertWhen_RatingWrongParty() public {
        // 1. Create mission
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );

        address escrow = factory.missions(missionId);

        // 2. Accept and complete mission
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();
        vm.prank(performer);
        IMissionEscrow(escrow).submitProof(keccak256("proof"));
        vm.prank(poster);
        IMissionEscrow(escrow).approveCompletion();

        // 3. Poster tries to rate RANDOM USER (not performer)
        vm.prank(poster);
        vm.expectRevert(ReputationAttestations.NotAuthorized.selector);
        reputation.submitRating(missionId, randomUser, 5, COMMENT_HASH);
    }
}
