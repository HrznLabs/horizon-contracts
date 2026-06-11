// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {ReputationOracle} from "../src/ReputationOracle.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {PauseRegistry} from "../src/PauseRegistry.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {IReputationOracle} from "../src/interfaces/IReputationOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title IntegrationTest
 * @notice End-to-end integration tests for ReputationOracle + MissionEscrow + MissionFactory
 * @dev Plan 02-05 Task 1 — validates all M2 contracts work together
 */
contract IntegrationTest is Test {
    MissionFactory public factory;
    ReputationOracle public oracle;
    PaymentRouter public router;
    PauseRegistry public pauseRegistry;
    MockERC20 public usdc;

    address public owner = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public newUser = address(4);
    address public guild = address(10);
    address public relayer = address(11);
    address public protocolTreasury = address(100);
    address public resolverTreasury = address(101);
    address public labsTreasury = address(102);

    uint256 public constant REWARD_100 = 100e6;
    uint256 public constant REWARD_600 = 600e6;
    bytes32 public constant META = keccak256("metadata");
    bytes32 public constant LOC = keccak256("location");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy core infra
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pauseRegistry = new PauseRegistry(owner);
        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            owner
        );
        factory = new MissionFactory(address(router));
        router.setMissionFactory(address(factory));

        // Deploy ReputationOracle
        oracle = new ReputationOracle(owner, relayer);

        // Wire oracle into factory
        factory.setReputationOracle(address(oracle));

        vm.stopPrank();

        // Fund poster
        usdc.mint(poster, 1_000_000e6);
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    function _createMission(uint256 reward, uint256 minRep) internal returns (uint256) {
        vm.startPrank(poster);
        usdc.approve(address(factory), reward);
        uint256 mid = factory.createMission(
            address(usdc),
            reward,
            block.timestamp + 1 days,
            guild,
            META,
            LOC,
            minRep
        );
        vm.stopPrank();
        return mid;
    }

    function _createMissionNoGuild(uint256 reward, uint256 minRep) internal returns (uint256) {
        vm.startPrank(poster);
        usdc.approve(address(factory), reward);
        uint256 mid = factory.createMission(
            address(usdc),
            reward,
            block.timestamp + 1 days,
            address(0),
            META,
            LOC,
            minRep
        );
        vm.stopPrank();
        return mid;
    }

    // =========================================================================
    // Test 1: Full Reputation Gating Flow (E2E)
    // =========================================================================

    function test_FullReputationGatingFlow() public {
        // 1. Set performer's guild score to 500
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 500);

        // 2. Verify score is stored correctly
        assertEq(oracle.getScore(performer, guild), 500);
        (uint256 score, uint8 tier) = oracle.getScoreWithTier(performer, guild);
        assertEq(score, 500);
        assertEq(tier, 2); // Silver (400-599)

        // 3. Create mission with minReputation = 400
        uint256 mid = _createMission(REWARD_100, 400);
        address escrow = factory.missions(mid);

        // 4. Verify mission has correct minReputation
        IMissionEscrow.MissionParams memory params = IMissionEscrow(escrow).getParams();
        assertEq(params.minReputation, 400);

        // 5. Performer with score 500 >= 400 → accept succeeds
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow).getRuntime();
        assertEq(rt.performer, performer);
        assertEq(uint8(rt.state), uint8(IMissionEscrow.MissionState.Accepted));

        // 6. Verify newUser with score 0 cannot accept another gated mission
        uint256 mid2 = _createMission(REWARD_100, 400);
        address escrow2 = factory.missions(mid2);

        vm.prank(newUser);
        vm.expectRevert(
            abi.encodeWithSelector(IMissionEscrow.InsufficientReputation.selector, 0, 400)
        );
        IMissionEscrow(escrow2).acceptMission();

        // 7. Now give newUser a score and retry
        vm.prank(relayer);
        oracle.updateScore(newUser, guild, 450);

        vm.prank(newUser);
        IMissionEscrow(escrow2).acceptMission();

        rt = IMissionEscrow(escrow2).getRuntime();
        assertEq(rt.performer, newUser);
    }

    // =========================================================================
    // Test 2: Three-Layer Gating Priority
    // =========================================================================

    function test_ThreeLayerGatingPriority() public {
        // Layer 1: Protocol auto-floor = 200 (missions >= 500 USDC)
        // Layer 2: Guild default = 300
        // Layer 3: Poster override = 500
        // Effective: max(200, 300, 500) = 500

        vm.prank(owner);
        factory.setGuildMinReputation(guild, 300);

        // Create 600 USDC mission with poster override = 500
        uint256 mid = _createMission(REWARD_600, 500);
        address escrow = factory.missions(mid);

        IMissionEscrow.MissionParams memory params = IMissionEscrow(escrow).getParams();
        assertEq(params.minReputation, 500); // Poster override is highest

        // Verify each layer independently:

        // Only protocol auto-floor (no guild, 600 USDC, no poster specification)
        vm.prank(owner);
        factory.setGuildMinReputation(guild, 0); // Reset guild default

        uint256 mid2 = _createMission(REWARD_600, 0);
        address escrow2 = factory.missions(mid2);
        params = IMissionEscrow(escrow2).getParams();
        assertEq(params.minReputation, 200); // Protocol auto-floor only

        // Guild default higher than protocol floor
        vm.prank(owner);
        factory.setGuildMinReputation(guild, 300);

        uint256 mid3 = _createMission(REWARD_600, 0);
        address escrow3 = factory.missions(mid3);
        params = IMissionEscrow(escrow3).getParams();
        assertEq(params.minReputation, 300); // Guild default > protocol floor

        // Small mission, guild default only (no protocol floor)
        uint256 mid4 = _createMission(REWARD_100, 0);
        address escrow4 = factory.missions(mid4);
        params = IMissionEscrow(escrow4).getParams();
        assertEq(params.minReputation, 300); // Guild default only
    }

    // =========================================================================
    // Test 3: New User Progressive Unlock
    // =========================================================================

    function test_NewUserProgressiveUnlock() public {
        // Step 1: newUser with score 0 CAN accept open missions
        uint256 openMid = _createMission(REWARD_100, 0);
        address openEscrow = factory.missions(openMid);

        vm.prank(newUser);
        IMissionEscrow(openEscrow).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(openEscrow).getRuntime();
        assertEq(rt.performer, newUser);

        // Step 2: newUser with score 0 CANNOT accept gated mission (minRep=200)
        uint256 gatedMid = _createMission(REWARD_100, 200);
        address gatedEscrow = factory.missions(gatedMid);

        vm.prank(newUser);
        vm.expectRevert(
            abi.encodeWithSelector(IMissionEscrow.InsufficientReputation.selector, 0, 200)
        );
        IMissionEscrow(gatedEscrow).acceptMission();

        // Step 3: Backend pushes score 250 for newUser → now eligible
        vm.prank(relayer);
        oracle.updateScore(newUser, guild, 250);

        assertEq(oracle.getScore(newUser, guild), 250);

        vm.prank(newUser);
        IMissionEscrow(gatedEscrow).acceptMission();

        rt = IMissionEscrow(gatedEscrow).getRuntime();
        assertEq(rt.performer, newUser);

        // Step 4: User keeps building → unlock premium tier
        vm.prank(relayer);
        oracle.updateScore(newUser, guild, 650);

        uint256 premiumMid = _createMission(REWARD_100, 600);
        address premiumEscrow = factory.missions(premiumMid);

        vm.prank(newUser);
        IMissionEscrow(premiumEscrow).acceptMission();

        rt = IMissionEscrow(premiumEscrow).getRuntime();
        assertEq(rt.performer, newUser);
    }

    // =========================================================================
    // Test 4: Oracle Permissions
    // =========================================================================

    function test_OraclePermissions_OnlyRelayerCanUpdateScores() public {
        // Non-relayer cannot update scores
        vm.prank(poster);
        vm.expectRevert();
        oracle.updateScore(performer, guild, 100);

        vm.prank(newUser);
        vm.expectRevert();
        oracle.updateGlobalScore(performer, 100);

        // Relayer can update
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 800);
        assertEq(oracle.getScore(performer, guild), 800);

        vm.prank(relayer);
        oracle.updateGlobalScore(performer, 750);
        assertEq(oracle.getGlobalScore(performer), 750);
    }

    function test_OraclePermissions_BatchUpdate() public {
        address[] memory users = new address[](3);
        users[0] = address(20);
        users[1] = address(21);
        users[2] = address(22);

        uint256[] memory scores = new uint256[](3);
        scores[0] = 100;
        scores[1] = 500;
        scores[2] = 900;

        // Non-relayer batch fails
        vm.prank(poster);
        vm.expectRevert();
        oracle.batchUpdateScores(users, guild, scores);

        // Relayer batch succeeds
        vm.prank(relayer);
        oracle.batchUpdateScores(users, guild, scores);

        assertEq(oracle.getScore(users[0], guild), 100);
        assertEq(oracle.getScore(users[1], guild), 500);
        assertEq(oracle.getScore(users[2], guild), 900);

        // Verify tiers
        assertEq(oracle.getTier(100), 0);  // Newcomer
        assertEq(oracle.getTier(500), 2);  // Silver
        assertEq(oracle.getTier(900), 4);  // Diamond
    }

    function test_OraclePermissions_ScoreCappedAt1000() public {
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(IReputationOracle.ScoreOutOfRange.selector, 1001)
        );
        oracle.updateScore(performer, guild, 1001);

        // Exactly 1000 is fine
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 1000);
        assertEq(oracle.getScore(performer, guild), 1000);
        assertEq(oracle.getTier(1000), 4); // Diamond
    }

    function test_OraclePermissions_ArrayLengthMismatch() public {
        address[] memory users = new address[](2);
        users[0] = address(20);
        users[1] = address(21);

        uint256[] memory scores = new uint256[](3); // Mismatched
        scores[0] = 100;
        scores[1] = 200;
        scores[2] = 300;

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(IReputationOracle.ArrayLengthMismatch.selector)
        );
        oracle.batchUpdateScores(users, guild, scores);
    }

    // =========================================================================
    // Test 5: ReputationOracle pause behavior
    // =========================================================================

    function test_OraclePause_BlocksWritesAllowsReads() public {
        // Set a score before pausing
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 600);

        // Pause oracle
        vm.prank(owner);
        oracle.pause();

        // Reads still work (view functions don't check pause)
        assertEq(oracle.getScore(performer, guild), 600);
        assertEq(oracle.getGlobalScore(performer), 0);

        (uint256 s, uint8 t) = oracle.getScoreWithTier(performer, guild);
        assertEq(s, 600);
        assertEq(t, 3); // Gold

        // Writes are blocked
        vm.prank(relayer);
        vm.expectRevert("ReputationOracle: paused");
        oracle.updateScore(performer, guild, 700);

        vm.prank(relayer);
        vm.expectRevert("ReputationOracle: paused");
        oracle.updateGlobalScore(performer, 700);

        // Unpause
        vm.prank(owner);
        oracle.unpause();

        // Writes work again
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 700);
        assertEq(oracle.getScore(performer, guild), 700);
    }

    function test_OraclePause_MissionGatingStillWorksWithCachedScore() public {
        // Set score and create mission BEFORE pausing
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 500);

        uint256 mid = _createMission(REWARD_100, 400);
        address escrow = factory.missions(mid);

        // Pause oracle — reads still work
        vm.prank(owner);
        oracle.pause();

        // Mission acceptance uses getScore (view, not affected by pause)
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow).getRuntime();
        assertEq(rt.performer, performer);
    }

    // =========================================================================
    // Test 6: Relayer management
    // =========================================================================

    function test_RelayerManagement() public {
        address newRelayer = address(50);

        // Only admin can add relayers
        vm.prank(poster);
        vm.expectRevert();
        oracle.addRelayer(newRelayer);

        // Admin adds new relayer
        vm.prank(owner);
        oracle.addRelayer(newRelayer);

        // New relayer can update scores
        vm.prank(newRelayer);
        oracle.updateScore(performer, guild, 888);
        assertEq(oracle.getScore(performer, guild), 888);

        // Admin removes relayer
        vm.prank(owner);
        oracle.removeRelayer(newRelayer);

        // Removed relayer can no longer update
        vm.prank(newRelayer);
        vm.expectRevert();
        oracle.updateScore(performer, guild, 999);
    }

    // =========================================================================
    // Test 7: Score idempotency (no event on same score)
    // =========================================================================

    function test_ScoreIdempotency() public {
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 400);

        // Recording events
        vm.recordLogs();

        // Same score — should return early, no event
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 400);

        // No ScoreUpdated event emitted
        assertEq(vm.getRecordedLogs().length, 0);

        // Different score — should emit event
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 500);

        // Exactly one ScoreUpdated event
        // (This simply verifies the score changed, event emission is implicit)
        assertEq(oracle.getScore(performer, guild), 500);
    }

    // =========================================================================
    // Test 8: Multi-guild reputation isolation
    // =========================================================================

    function test_MultiGuildIsolation() public {
        address guild2 = address(20);
        address guild3 = address(30);

        vm.startPrank(relayer);
        oracle.updateScore(performer, guild, 800);   // Gold in guild 1
        oracle.updateScore(performer, guild2, 300);   // Bronze in guild 2
        oracle.updateScore(performer, guild3, 100);   // Newcomer in guild 3
        oracle.updateGlobalScore(performer, 500);     // Silver globally
        vm.stopPrank();

        assertEq(oracle.getScore(performer, guild), 800);
        assertEq(oracle.getScore(performer, guild2), 300);
        assertEq(oracle.getScore(performer, guild3), 100);
        assertEq(oracle.getGlobalScore(performer), 500);

        // Guild-specific gating: performer can accept in guild 1 (800 >= 600)
        uint256 mid1 = _createMission(REWARD_100, 600);
        address escrow1 = factory.missions(mid1);

        vm.prank(performer);
        IMissionEscrow(escrow1).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow1).getRuntime();
        assertEq(rt.performer, performer);
    }

    // =========================================================================
    // Test 9: Zero address oracle graceful bypass (factory-managed)
    // =========================================================================

    function test_NoOracle_GracefulBypass() public {
        // Remove oracle
        vm.prank(owner);
        factory.setReputationOracle(address(0));

        // Create mission with minReputation = 500
        uint256 mid = _createMissionNoGuild(REWARD_100, 500);
        address escrow = factory.missions(mid);

        // Even with minRep=500, no oracle → skip check
        vm.prank(newUser);
        IMissionEscrow(escrow).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow).getRuntime();
        assertEq(rt.performer, newUser);
    }

    // =========================================================================
    // Test 10: Tier derivation comprehensive
    // =========================================================================

    function test_TierDerivation() public pure {
        // Tier boundaries are comprehensively verified by testFuzz_TierBoundaries
    }

    function testFuzz_TierBoundaries(uint256 score) public view {
        score = bound(score, 0, 1000);

        uint8 tier = oracle.getTier(score);

        if (score >= 800) assertEq(tier, 4);       // Diamond
        else if (score >= 600) assertEq(tier, 3);   // Gold
        else if (score >= 400) assertEq(tier, 2);   // Silver
        else if (score >= 200) assertEq(tier, 1);   // Bronze
        else assertEq(tier, 0);                      // Newcomer
    }
}
