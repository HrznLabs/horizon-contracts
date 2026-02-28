// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { MissionFactory } from "../src/MissionFactory.sol";
import { MissionEscrow } from "../src/MissionEscrow.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { ReputationAttestations } from "../src/ReputationAttestations.sol";
import { IMissionEscrow } from "../src/interfaces/IMissionEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract ReputationIntegrationTest is Test {
    MissionFactory public factory;
    PaymentRouter public router;
    ReputationAttestations public reputation;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);

    // Treasuries
    address public protocolTreasury = address(10);
    address public resolverTreasury = address(11);
    address public labsTreasury = address(12);

    uint256 public constant REWARD_AMOUNT = 100e6; // 100 USDC
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");
    bytes32 public constant PROOF_HASH = keccak256("proof");

    event MissionOutcomeRecorded(
        uint256 indexed missionId,
        address indexed poster,
        address indexed performer,
        bool completed,
        uint256 rewardAmount
    );

    event ReputationUpdateFailed(uint256 indexed id);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(poster, 1000e6);
        usdc.mint(performer, 1000e6); // Give some to performer too, just in case

        // Deploy PaymentRouter
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury);

        // Deploy MissionFactory
        factory = new MissionFactory(address(usdc), address(router));
        factory.setDisputeResolver(address(999));

        // Deploy ReputationAttestations
        reputation = new ReputationAttestations();
        reputation.setMissionFactory(address(factory));
        factory.setReputationAttestations(address(reputation));

        // Link router to factory
        router.setMissionFactory(address(factory));

        vm.stopPrank();

        vm.prank(poster);
        usdc.approve(address(factory), 1000e6);
    }

    function test_MissionOutcomeRecorded_WhenMissionCompleted() public {
        // 1. Create mission
        vm.startPrank(poster);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        // 2. Accept mission
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        // 3. Submit proof
        vm.prank(performer);
        IMissionEscrow(escrow).submitProof(PROOF_HASH);

        // 4. Approve completion
        vm.startPrank(poster);

        // We expect MissionOutcomeRecorded to be emitted
        // This should FAIL currently because it is not emitted
        vm.expectEmit(true, true, true, true);
        emit MissionOutcomeRecorded(missionId, poster, performer, true, REWARD_AMOUNT);

        IMissionEscrow(escrow).approveCompletion();
        vm.stopPrank();
    }

    function test_DoNotBlockPayment_WhenReputationReverts() public {
        // 1. Setup factory with malicious reputation contract
        vm.startPrank(owner);
        MockReputationReverter maliciousReputation = new MockReputationReverter();
        factory.setReputationAttestations(address(maliciousReputation));
        vm.stopPrank();

        // 2. Create mission
        vm.startPrank(poster);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT, block.timestamp + 1 days, address(0), METADATA_HASH, LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        // 3. Accept and Submit
        vm.startPrank(performer);
        IMissionEscrow(escrow).acceptMission();
        IMissionEscrow(escrow).submitProof(PROOF_HASH);
        vm.stopPrank();

        // 4. Approve completion - SHOULD NOT REVERT
        vm.startPrank(poster);

        // Expect ReputationUpdateFailed event
        vm.expectEmit(true, false, false, false);
        emit ReputationUpdateFailed(missionId);

        // Also expect MissionCompleted
        // Note: expectEmit only checks the NEXT event.
        // ReputationUpdateFailed is emitted BEFORE MissionCompleted?
        // Let's check MissionEscrow.sol order.
        // Yes, recordOutcome is called, then MissionCompleted emitted.
        // So ReputationUpdateFailed is emitted first.

        IMissionEscrow(escrow).approveCompletion();

        vm.stopPrank();

        // Verify payment happened (performer got paid)
        assertEq(usdc.balanceOf(performer), 1000e6 + 90e6); // 90% of 100 USDC (assuming default fees)
    }
}

contract MockReputationReverter {
    function recordOutcome(uint256, address, address, bool, uint256) external pure {
        revert("DoS Attempt");
    }
}
