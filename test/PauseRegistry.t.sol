// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PauseRegistry} from "../src/PauseRegistry.sol";
import {IPauseRegistry} from "../src/interfaces/IPauseRegistry.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title PauseRegistryTest
 * @notice Tests for SEC-8: Global + per-contract pause, circuit breaker, graceful wind-down
 */
contract PauseRegistryTest is Test {
    PauseRegistry public pauseRegistry;
    MissionFactory public factory;
    PaymentRouter public router;
    MockERC20 public usdc;

    address public admin = address(1);
    address public poster = address(2);
    address public performer = address(3);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);
    address public pauser = address(7);
    address public attacker = address(8);
    address public contractA = address(100);
    address public contractB = address(101);

    uint256 public constant REWARD_AMOUNT = 1000e6;
    bytes32 public constant METADATA_HASH = keccak256("metadata");
    bytes32 public constant LOCATION_HASH = keccak256("location");

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockERC20("USD Coin", "USDC", 6);

        pauseRegistry = new PauseRegistry(admin);
        pauseRegistry.grantRole(pauseRegistry.PAUSER_ROLE(), pauser);

        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            admin
        );

        factory = new MissionFactory(address(router));
        router.setMissionFactory(address(factory));
        factory.setPauseRegistry(address(pauseRegistry));

        vm.stopPrank();

        usdc.mint(poster, 100_000e6);
    }

    // =========================================================================
    // GLOBAL PAUSE
    // =========================================================================

    function test_GlobalPause_BlocksAllContracts() public {
        vm.prank(pauser);
        pauseRegistry.pauseGlobal();

        assertTrue(pauseRegistry.isPaused(contractA));
        assertTrue(pauseRegistry.isPaused(contractB));
        assertTrue(pauseRegistry.isPaused(address(factory)));
        assertTrue(pauseRegistry.isGloballyPaused());
    }

    function test_GlobalUnpause_RestoresAll() public {
        vm.prank(pauser);
        pauseRegistry.pauseGlobal();
        assertTrue(pauseRegistry.isPaused(contractA));

        vm.prank(pauser);
        pauseRegistry.unpauseGlobal();
        assertFalse(pauseRegistry.isPaused(contractA));
        assertFalse(pauseRegistry.isPaused(contractB));
    }

    // =========================================================================
    // PER-CONTRACT PAUSE
    // =========================================================================

    function test_PerContractPause_OnlyBlocksTarget() public {
        vm.prank(pauser);
        pauseRegistry.pauseContract(contractA);

        assertTrue(pauseRegistry.isPaused(contractA));
        assertFalse(pauseRegistry.isPaused(contractB));
    }

    function test_PerContractUnpause() public {
        vm.prank(pauser);
        pauseRegistry.pauseContract(contractA);
        assertTrue(pauseRegistry.isPaused(contractA));

        vm.prank(pauser);
        pauseRegistry.unpauseContract(contractA);
        assertFalse(pauseRegistry.isPaused(contractA));
    }

    function test_GlobalOverridesPerContract() public {
        // Per-contract is unpaused, but global is paused → still paused
        vm.prank(pauser);
        pauseRegistry.pauseGlobal();
        assertTrue(pauseRegistry.isPaused(contractA));

        // Unpause contract A specifically — still paused because global is on
        vm.prank(pauser);
        pauseRegistry.unpauseContract(contractA);
        assertTrue(pauseRegistry.isPaused(contractA));
    }

    // =========================================================================
    // ACCESS CONTROL
    // =========================================================================

    function test_PauseRequiresPauserRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        pauseRegistry.pauseGlobal();
    }

    function test_UnpauseRequiresPauserRole() public {
        vm.prank(pauser);
        pauseRegistry.pauseGlobal();

        vm.prank(attacker);
        vm.expectRevert();
        pauseRegistry.unpauseGlobal();
    }

    function test_ContractPauseRequiresPauserRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        pauseRegistry.pauseContract(contractA);
    }

    // =========================================================================
    // MISSION FACTORY INTEGRATION
    // =========================================================================

    function test_MissionFactory_CannotCreateWhenPaused() public {
        // Pause factory
        vm.prank(pauser);
        pauseRegistry.pauseContract(address(factory));

        // Try to create mission — should revert
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        vm.expectRevert(MissionFactory.Paused.selector);
        factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();
    }

    function test_MissionFactory_CannotCreateWhenGloballyPaused() public {
        // Global pause
        vm.prank(pauser);
        pauseRegistry.pauseGlobal();

        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        vm.expectRevert(MissionFactory.Paused.selector);
        factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();
    }

    function test_MissionFactory_CanCreateAfterUnpause() public {
        // Pause then unpause
        vm.prank(pauser);
        pauseRegistry.pauseContract(address(factory));
        vm.prank(pauser);
        pauseRegistry.unpauseContract(address(factory));

        // Should succeed
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        assertEq(missionId, 1);
    }

    // =========================================================================
    // MISSION ESCROW GRACEFUL WIND-DOWN
    // =========================================================================

    function test_MissionEscrow_CannotAcceptWhenPaused() public {
        // Create mission first (before pause)
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        // Pause the escrow
        vm.prank(pauser);
        pauseRegistry.pauseContract(escrow);

        // Try to accept — should fail (graceful wind-down: block new operations)
        vm.prank(performer);
        vm.expectRevert(IMissionEscrow.Paused.selector);
        MissionEscrow(escrow).acceptMission();
    }

    function test_MissionEscrow_CanSettleWhenPaused() public {
        // Create and accept mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256("proof"));

        // Pause the escrow AFTER submission
        vm.prank(pauser);
        pauseRegistry.pauseContract(escrow);

        // Settle should still work (graceful wind-down: settlement NOT paused)
        vm.prank(poster);
        MissionEscrow(escrow).approveCompletion();

        // Verify performer received payment
        assertTrue(usdc.balanceOf(performer) > 0);

        // Verify mission completed
        IMissionEscrow.MissionRuntime memory runtime = MissionEscrow(escrow).getRuntime();
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Completed));
    }

    function test_MissionEscrow_CanSubmitProofWhenPaused() public {
        // Create and accept mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.prank(performer);
        MissionEscrow(escrow).acceptMission();

        // Pause the escrow AFTER acceptance
        vm.prank(pauser);
        pauseRegistry.pauseContract(escrow);

        // In-progress work submission should still work
        vm.prank(performer);
        MissionEscrow(escrow).submitProof(keccak256("proof"));
    }

    // =========================================================================
    // CIRCUIT BREAKER
    // =========================================================================

    function test_CircuitBreaker_DefaultThreshold() public view {
        assertEq(pauseRegistry.circuitBreakerThresholdBPS(), 3000); // 30%
    }

    function test_CircuitBreaker_ManualTrigger() public {
        vm.prank(pauser);
        pauseRegistry.triggerCircuitBreaker(contractA);

        assertTrue(pauseRegistry.isPaused(contractA));
    }

    function test_CircuitBreaker_AutoPauseOnDrain() public {
        // Register contract and set known balance
        vm.startPrank(admin);
        pauseRegistry.registerContract(contractA);
        
        // Mint tokens to contractA
        usdc.mint(contractA, 1000e6);
        pauseRegistry.setLastKnownBalance(contractA, 1000e6);
        vm.stopPrank();

        // Simulate drain: transfer 400e6 out (40% > 30% threshold)
        vm.prank(contractA);
        usdc.transfer(address(0xdead), 400e6);

        // Report balance change
        pauseRegistry.reportBalanceChange(address(usdc), contractA);

        // Should be auto-paused
        assertTrue(pauseRegistry.isPaused(contractA));
    }

    function test_CircuitBreaker_NoPauseUnderThreshold() public {
        vm.startPrank(admin);
        pauseRegistry.registerContract(contractA);
        usdc.mint(contractA, 1000e6);
        pauseRegistry.setLastKnownBalance(contractA, 1000e6);
        vm.stopPrank();

        // Simulate small transfer: 200e6 out (20% < 30% threshold)
        vm.prank(contractA);
        usdc.transfer(address(0xdead), 200e6);

        pauseRegistry.reportBalanceChange(address(usdc), contractA);

        // Should NOT be paused
        assertFalse(pauseRegistry.isPaused(contractA));
    }

    function test_CircuitBreaker_UpdateThreshold() public {
        vm.prank(admin);
        pauseRegistry.setCircuitBreakerThreshold(5000); // Raise to 50%

        assertEq(pauseRegistry.circuitBreakerThresholdBPS(), 5000);
    }

    function test_CircuitBreaker_OnlyRegisteredCanReport() public {
        // contractA is NOT registered
        vm.expectRevert(IPauseRegistry.NotRegistered.selector);
        pauseRegistry.reportBalanceChange(address(usdc), contractA);
    }

    // =========================================================================
    // EVENTS
    // =========================================================================

    function test_EmitsGlobalPausedEvent() public {
        vm.prank(pauser);
        vm.expectEmit(true, false, false, false);
        emit PauseRegistry.GlobalPaused(pauser);
        pauseRegistry.pauseGlobal();
    }

    function test_EmitsContractPausedEvent() public {
        vm.prank(pauser);
        vm.expectEmit(true, true, false, false);
        emit PauseRegistry.ContractPaused(contractA, pauser);
        pauseRegistry.pauseContract(contractA);
    }
}
