// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaymentRouter.sol";
import "../src/MissionFactory.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/DeliveryEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDCPoC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveryEscrowPoCTest is Test {
    PaymentRouter router;
    DeliveryMissionFactory deliveryFactory;
    MockUSDCPoC usdc;

    address owner = address(0x1);
    address poster = address(0x2);
    address performer = address(0x3);
    address protocolTreasury = address(0x4);
    address resolverTreasury = address(0x5);
    address labsTreasury = address(0x6);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDCPoC();
        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            owner
        );
        router.setAcceptedToken(address(usdc), true);

        deliveryFactory = new DeliveryMissionFactory(address(router));

        // Setup router with deliveryFactory as missionFactory
        router.setMissionFactory(address(deliveryFactory));
        vm.stopPrank();

        usdc.mint(poster, 1000e6);
    }

    function test_SettleDeliveryEscrow() public {
        vm.startPrank(poster);
        usdc.approve(address(deliveryFactory), 100e6);
        uint256 missionId = deliveryFactory.createDeliveryMission(
            address(usdc),
            100e6,
            block.timestamp + 1 days,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrowAddr = deliveryFactory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddr));

        DeliveryEscrow.DeliveryWaypoint[] memory waypoints = new DeliveryEscrow.DeliveryWaypoint[](1);
        waypoints[0] = DeliveryEscrow.DeliveryWaypoint({
            addressHash: keccak256("pickup"),
            latitude: 0,
            longitude: 0,
            waypointType: 0,
            arrivalDeadline: 0,
            completed: false,
            completedAt: 0,
            proofHash: bytes32(0)
        });
        DeliveryEscrow.DeliveryParams memory params = DeliveryEscrow.DeliveryParams({
            pickup: DeliveryEscrow.DeliveryLocation(0, 0, bytes32(0), 0, 0, false),
            dropoff: DeliveryEscrow.DeliveryLocation(0, 0, bytes32(0), 0, 0, false),
            package: DeliveryEscrow.PackageDetails(0, 0, 0, 0),
            pickupWindowStart: 0,
            pickupWindowEnd: 0,
            deliveryDeadline: 0,
            realTimeTrackingEnabled: false,
            tipAmount: 0
        });

        vm.prank(address(deliveryFactory));
        escrow.initializeDelivery(params, waypoints);

        vm.prank(performer);
        escrow.acceptMission();

        vm.prank(performer);
        escrow.completeWaypoint(0, bytes32(0));

        vm.prank(performer);
        escrow.submitProof(bytes32(0));

        vm.expectRevert(abi.encodeWithSignature("OnlyMissionEscrow()"));
        vm.prank(poster);
        escrow.approveCompletion();
    }
}
