// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {ReputationOracle} from "../src/ReputationOracle.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {IReputationOracle} from "../src/interfaces/IReputationOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ReputationGatingTest is Test {
    MissionFactory public factory;
    ReputationOracle public oracle;
    PaymentRouter public router;
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

    uint256 public constant REWARD_100 = 100e6;   // 100 USDC
    uint256 public constant REWARD_600 = 600e6;   // 600 USDC (premium)
    bytes32 public constant META = keccak256("metadata");
    bytes32 public constant LOC = keccak256("location");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy PaymentRouter
        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            owner
        );

        // Deploy MissionFactory
        factory = new MissionFactory(address(router));
        router.setMissionFactory(address(factory));

        // Deploy ReputationOracle
        oracle = new ReputationOracle(owner, relayer);

        // Configure factory with oracle
        factory.setReputationOracle(address(oracle));

        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, 100_000e6);

        // Set up performer with reputation score = 500
        vm.prank(relayer);
        oracle.updateScore(performer, guild, 500);
    }

    // =========================================================================
    // Helper: create mission with minReputation
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
    // Test 1: No gating (minReputation = 0)
    // =========================================================================

    function test_AcceptMission_NoGating() public {
        uint256 mid = _createMission(REWARD_100, 0);
        address escrow = factory.missions(mid);

        // Anyone can accept when no gating
        vm.prank(newUser);
        IMissionEscrow(escrow).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow).getRuntime();
        assertEq(uint8(rt.state), uint8(IMissionEscrow.MissionState.Accepted));
        assertEq(rt.performer, newUser);
    }

    // =========================================================================
    // Test 2: Reputation gated — performer qualifies
    // =========================================================================

    function test_AcceptMission_ReputationGated() public {
        uint256 mid = _createMission(REWARD_100, 400);
        address escrow = factory.missions(mid);

        // Performer has score 500 >= 400, should succeed
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow).getRuntime();
        assertEq(rt.performer, performer);
    }

    // =========================================================================
    // Test 3: Reputation gated — performer blocked
    // =========================================================================

    function test_AcceptMission_ReputationBlocked() public {
        uint256 mid = _createMission(REWARD_100, 600);
        address escrow = factory.missions(mid);

        // Performer has score 500 < 600, should revert
        vm.prank(performer);
        vm.expectRevert(
            abi.encodeWithSelector(IMissionEscrow.InsufficientReputation.selector, 500, 600)
        );
        IMissionEscrow(escrow).acceptMission();
    }

    // =========================================================================
    // Test 4: Protocol auto-floor for high-value missions
    // =========================================================================

    function test_ProtocolAutoFloor_HighValueMission() public {
        // Create a 600 USDC mission with minReputation=0
        // Protocol auto-floor should enforce minReputation=200
        uint256 mid = _createMission(REWARD_600, 0);
        address escrow = factory.missions(mid);

        // Check the stored minReputation in params
        IMissionEscrow.MissionParams memory params = IMissionEscrow(escrow).getParams();
        assertEq(params.minReputation, 200); // Protocol floor applied

        // New user with score 0 should be blocked
        vm.prank(newUser);
        vm.expectRevert(
            abi.encodeWithSelector(IMissionEscrow.InsufficientReputation.selector, 0, 200)
        );
        IMissionEscrow(escrow).acceptMission();
    }

    // =========================================================================
    // Test 5: Guild default applied when higher
    // =========================================================================

    function test_GuildDefault_AppliedWhenHigher() public {
        // Set guild minimum to 300
        vm.prank(owner);
        factory.setGuildMinReputation(guild, 300);

        // Create mission with poster's minReputation=100
        // Guild default (300) is higher → effective = 300
        uint256 mid = _createMission(REWARD_100, 100);
        address escrow = factory.missions(mid);

        IMissionEscrow.MissionParams memory params = IMissionEscrow(escrow).getParams();
        assertEq(params.minReputation, 300); // Guild default wins
    }

    // =========================================================================
    // Test 6: Poster override applied when higher
    // =========================================================================

    function test_PosterOverride_AppliedWhenHigher() public {
        // Set guild minimum to 200
        vm.prank(owner);
        factory.setGuildMinReputation(guild, 200);

        // Create mission with poster's minReputation=500
        // Poster specified 500 > guild's 200 → effective = 500
        uint256 mid = _createMission(REWARD_100, 500);
        address escrow = factory.missions(mid);

        IMissionEscrow.MissionParams memory params = IMissionEscrow(escrow).getParams();
        assertEq(params.minReputation, 500); // Poster override wins
    }

    // =========================================================================
    // Test 7: New user can accept starter mission
    // =========================================================================

    function test_NewUser_CanAcceptStarterMission() public {
        uint256 mid = _createMission(REWARD_100, 0);
        address escrow = factory.missions(mid);

        // newUser has score 0, minReputation 0 → should succeed
        vm.prank(newUser);
        IMissionEscrow(escrow).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow).getRuntime();
        assertEq(rt.performer, newUser);
    }

    // =========================================================================
    // Test 8: New user cannot accept premium mission
    // =========================================================================

    function test_NewUser_CannotAcceptPremiumMission() public {
        uint256 mid = _createMission(REWARD_100, 200);
        address escrow = factory.missions(mid);

        // newUser has score 0 < 200 → should revert
        vm.prank(newUser);
        vm.expectRevert(
            abi.encodeWithSelector(IMissionEscrow.InsufficientReputation.selector, 0, 200)
        );
        IMissionEscrow(escrow).acceptMission();
    }

    // =========================================================================
    // Test 9: No oracle → all allowed (graceful bypass)
    // =========================================================================

    function test_NoOracle_AllowsAll() public {
        // Remove oracle from factory
        vm.prank(owner);
        factory.setReputationOracle(address(0));

        // Create gated mission
        uint256 mid = _createMissionNoGuild(REWARD_100, 500);
        address escrow = factory.missions(mid);

        // Even with minReputation=500, no oracle means no check
        vm.prank(newUser);
        IMissionEscrow(escrow).acceptMission();

        IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow).getRuntime();
        assertEq(rt.performer, newUser);
    }

    // =========================================================================
    // Test 10: Backward-compatible createMission (no minReputation param)
    // =========================================================================

    function test_BackwardCompatible_CreateMission() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_100);
        uint256 mid = factory.createMission(
            address(usdc),
            REWARD_100,
            block.timestamp + 1 days,
            address(0),
            META,
            LOC
        );
        vm.stopPrank();

        address escrow = factory.missions(mid);
        IMissionEscrow.MissionParams memory params = IMissionEscrow(escrow).getParams();
        assertEq(params.minReputation, 0); // Default: no gating

        // Anyone can accept
        vm.prank(newUser);
        IMissionEscrow(escrow).acceptMission();
    }

    // =========================================================================
    // Test 11: Backward-compatible + protocol auto-floor
    // =========================================================================

    function test_BackwardCompatible_ProtocolFloor() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_600);
        uint256 mid = factory.createMission(
            address(usdc),
            REWARD_600,
            block.timestamp + 1 days,
            address(0),
            META,
            LOC
        );
        vm.stopPrank();

        address escrow = factory.missions(mid);
        IMissionEscrow.MissionParams memory params = IMissionEscrow(escrow).getParams();
        assertEq(params.minReputation, 200); // Protocol floor applied even without explicit param
    }

    // =========================================================================
    // Test 12: Guild min reputation admin function
    // =========================================================================

    function test_SetGuildMinReputation_OnlyOwner() public {
        vm.prank(poster);
        vm.expectRevert();
        factory.setGuildMinReputation(guild, 300);

        vm.prank(owner);
        factory.setGuildMinReputation(guild, 300);
        assertEq(factory.guildMinReputation(guild), 300);
    }

    // =========================================================================
    // Fuzz: reputation gating accepts or rejects correctly
    // =========================================================================

    function testFuzz_ReputationGating(uint256 score, uint256 minRep) public {
        score = bound(score, 0, 1000);
        minRep = bound(minRep, 0, 1000);

        // Set performer score
        vm.prank(relayer);
        oracle.updateScore(performer, guild, score);

        // Create mission
        uint256 mid = _createMission(REWARD_100, minRep);
        address escrow = factory.missions(mid);

        vm.prank(performer);
        if (minRep == 0 || score >= minRep) {
            // Should succeed
            IMissionEscrow(escrow).acceptMission();
            IMissionEscrow.MissionRuntime memory rt = IMissionEscrow(escrow).getRuntime();
            assertEq(rt.performer, performer);
        } else {
            // Should revert
            vm.expectRevert(
                abi.encodeWithSelector(IMissionEscrow.InsufficientReputation.selector, score, minRep)
            );
            IMissionEscrow(escrow).acceptMission();
        }
    }
}
