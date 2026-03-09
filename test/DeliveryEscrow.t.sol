// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeliveryEscrowTest is Test {
    DeliveryMissionFactory public factory;
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
            labsTreasury,
            owner  // admin
        );

        // Deploy DeliveryMissionFactory
        factory = new DeliveryMissionFactory(address(router));

        vm.stopPrank();

        // Mint USDC to poster
        usdc.mint(poster, 1000e6);
    }

    function _createDeliveryMission() internal returns (uint256 missionId, address escrowAddress) {
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        
        missionId = factory.createDeliveryMission(
            address(usdc),
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            METADATA_HASH,
            LOCATION_HASH
        );
        
        escrowAddress = factory.missions(missionId);
        vm.stopPrank();
    }

    function test_InitializeDelivery() public {
        (uint256 missionId, address escrowAddress) = _createDeliveryMission();
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // Create delivery params matching actual struct
        DeliveryEscrow.DeliveryLocation memory pickup = DeliveryEscrow.DeliveryLocation({
            latitude: 37774900,
            longitude: -122419400,
            addressHash: keccak256("pickup address"),
            precision: 0,
            geofenceRadius: 100,
            requirePresence: false
        });

        DeliveryEscrow.DeliveryLocation memory dropoff = DeliveryEscrow.DeliveryLocation({
            latitude: 34052200,
            longitude: -118243700,
            addressHash: keccak256("dropoff address"),
            precision: 0,
            geofenceRadius: 100,
            requirePresence: false
        });

        DeliveryEscrow.PackageDetails memory packageDetails = DeliveryEscrow.PackageDetails({
            itemType: 1, // package
            packageSize: 2, // medium
            estimatedWeight: 5000, // 5kg in grams
            specialHandling: 0
        });

        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](2);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0, // pickup
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });
        waypoints[1] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("dropoff"),
            latitude: 34052200,
            longitude: -118243700,
            waypointType: 2, // dropoff
            arrivalDeadline: block.timestamp + 6 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: pickup,
            dropoff: dropoff,
            package: packageDetails,
            pickupWindowStart: block.timestamp + 1 hours,
            pickupWindowEnd: block.timestamp + 3 hours,
            deliveryDeadline: block.timestamp + 8 hours,
            realTimeTrackingEnabled: true,
            tipAmount: 0
        });

        // Initialize delivery
        vm.prank(poster);
        escrow.initializeDelivery(params, waypoints);

        // Verify delivery initialized
        DeliveryEscrow.DeliveryParams memory storedParams = escrow.getDeliveryParams();
        assertEq(storedParams.pickup.latitude, pickup.latitude);
        assertEq(storedParams.dropoff.latitude, dropoff.latitude);
        assertTrue(storedParams.realTimeTrackingEnabled);
    }

    function test_CompleteWaypoint() public {
        (uint256 missionId, address escrowAddress) = _createDeliveryMission();
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // Initialize delivery
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](1);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0,
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(37774900, -122419400, bytes32(0), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(34052200, -118243700, bytes32(0), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(1, 2, 5000, 0),
            pickupWindowStart: block.timestamp,
            pickupWindowEnd: block.timestamp + 2 hours,
            deliveryDeadline: block.timestamp + 6 hours,
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });

        vm.prank(poster);
        escrow.initializeDelivery(params, waypoints);

        // Accept mission
        vm.prank(performer);
        escrow.acceptMission();

        // Complete waypoint
        bytes32 proofHash = keccak256("pickup proof");
        vm.prank(performer);
        escrow.completeWaypoint(0, proofHash);

        // Verify waypoint completed
        DeliveryEscrow.DeliveryWaypoint memory waypoint = escrow.getWaypoint(0);
        assertTrue(waypoint.completed);
        assertEq(waypoint.proofHash, proofHash);
    }

    function test_AddTrackingCheckpoint() public {
        (uint256 missionId, address escrowAddress) = _createDeliveryMission();
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // Initialize with tracking enabled
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](1);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0,
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(37774900, -122419400, bytes32(0), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(34052200, -118243700, bytes32(0), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(1, 1, 1000, 0),
            pickupWindowStart: block.timestamp,
            pickupWindowEnd: block.timestamp + 2 hours,
            deliveryDeadline: block.timestamp + 6 hours,
            realTimeTrackingEnabled: true, // Enable tracking
            tipAmount: 0
        });

        vm.prank(poster);
        escrow.initializeDelivery(params, waypoints);

        // Accept mission
        vm.prank(performer);
        escrow.acceptMission();

        // Add tracking checkpoint
        vm.prank(performer);
        escrow.addTrackingCheckpoint(37800000, -122400000, 0); // enRoute

        // Verify checkpoint added
        DeliveryEscrow.TrackingCheckpoint memory checkpoint = escrow.getLatestCheckpoint();
        assertEq(checkpoint.latitude, 37800000);
        assertEq(checkpoint.longitude, -122400000);
        assertEq(checkpoint.checkpointType, 0);
    }

    function test_AddTip() public {
        (uint256 missionId, address escrowAddress) = _createDeliveryMission();
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // Initialize delivery
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](1);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0,
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(37774900, -122419400, bytes32(0), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(34052200, -118243700, bytes32(0), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(1, 1, 1000, 0),
            pickupWindowStart: block.timestamp,
            pickupWindowEnd: block.timestamp + 2 hours,
            deliveryDeadline: block.timestamp + 6 hours,
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });

        vm.prank(poster);
        escrow.initializeDelivery(params, waypoints);

        // Accept mission
        vm.prank(performer);
        escrow.acceptMission();

        // Add tip
        uint256 tipAmount = 10e6; // 10 USDC
        vm.startPrank(poster);
        usdc.approve(address(escrow), tipAmount);
        escrow.addTip(tipAmount);
        vm.stopPrank();

        // Verify tip added
        assertEq(escrow.getTipAmount(), tipAmount);
        assertEq(usdc.balanceOf(address(escrow)), REWARD_AMOUNT + tipAmount);
    }

    function test_RevertWhen_SubmitProofWithIncompleteWaypoints() public {
        (uint256 missionId, address escrowAddress) = _createDeliveryMission();
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // Initialize with 2 waypoints
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](2);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0,
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });
        waypoints[1] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("dropoff"),
            latitude: 34052200,
            longitude: -118243700,
            waypointType: 2,
            arrivalDeadline: block.timestamp + 6 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(37774900, -122419400, bytes32(0), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(34052200, -118243700, bytes32(0), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(1, 2, 5000, 0),
            pickupWindowStart: block.timestamp,
            pickupWindowEnd: block.timestamp + 2 hours,
            deliveryDeadline: block.timestamp + 8 hours,
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });

        vm.prank(poster);
        escrow.initializeDelivery(params, waypoints);

        // Accept mission
        vm.prank(performer);
        escrow.acceptMission();

        // Complete only first waypoint
        vm.prank(performer);
        escrow.completeWaypoint(0, keccak256("proof1"));

        // Try to submit proof without completing all waypoints
        vm.prank(performer);
        vm.expectRevert("All waypoints must be completed");
        escrow.submitProof(keccak256("final proof"));
    }

    function test_SubmitProofAfterAllWaypointsCompleted() public {
        (uint256 missionId, address escrowAddress) = _createDeliveryMission();
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        // Initialize with 2 waypoints
        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](2);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 37774900,
            longitude: -122419400,
            waypointType: 0,
            arrivalDeadline: block.timestamp + 2 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });
        waypoints[1] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("dropoff"),
            latitude: 34052200,
            longitude: -118243700,
            waypointType: 2,
            arrivalDeadline: block.timestamp + 6 hours,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });

        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(37774900, -122419400, bytes32(0), 0, 100, false),
            dropoff: DeliveryEscrow.DeliveryLocation(34052200, -118243700, bytes32(0), 0, 100, false),
            package: DeliveryEscrow.PackageDetails(1, 2, 5000, 0),
            pickupWindowStart: block.timestamp,
            pickupWindowEnd: block.timestamp + 2 hours,
            deliveryDeadline: block.timestamp + 8 hours,
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });

        vm.prank(poster);
        escrow.initializeDelivery(params, waypoints);

        // Accept mission
        vm.prank(performer);
        escrow.acceptMission();

        // Complete all waypoints
        vm.startPrank(performer);
        escrow.completeWaypoint(0, keccak256("proof1"));
        escrow.completeWaypoint(1, keccak256("proof2"));

        // Now submit proof should work
        bytes32 finalProof = keccak256("final proof");
        escrow.submitProof(finalProof);
        vm.stopPrank();

        // Verify state changed to Submitted
        IMissionEscrow.MissionRuntime memory runtime = factory.getMissionRuntime(missionId);
        assertEq(uint8(runtime.state), uint8(IMissionEscrow.MissionState.Submitted));
        assertEq(runtime.proofHash, finalProof);
    }
}
