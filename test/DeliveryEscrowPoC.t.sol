// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryEscrow.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract DeliveryEscrowPoC is Test {
    PaymentRouter router;
    DeliveryMissionFactory factory;
    MockToken token;

    address admin = address(0x1);
    address poster = address(0x2);
    address performer = address(0x3);

    function setUp() public {
        vm.startPrank(admin);
        token = new MockToken();
        router = new PaymentRouter(admin, admin, admin, admin, admin);
        factory = new DeliveryMissionFactory(address(router));

        router.setAcceptedToken(address(token), true);
        router.setMissionFactory(address(factory));
        vm.stopPrank();

        token.mint(poster, 1000 * 10**6);
    }

    function test_AuthenticationFailsForDeliveryEscrow() public {
        vm.startPrank(poster);
        token.approve(address(factory), 100 * 10**6);

        uint256 expiresAt = block.timestamp + 2 hours;

        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100 * 10**6,
            expiresAt,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        // Get the escrow address from the factory state manually since it's not exposed cleanly
        address escrowAddress = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.startPrank(performer);
        // Accept mission
        escrow.acceptMission();

        // Setup a mock proof (not relevant for this specific auth failure but need to proceed)
        escrow.submitProof(bytes32(0));
        vm.stopPrank();

        vm.startPrank(poster);
        // Approve completion -> triggers settlement
        // This will revert because the escrow is not authenticated with PaymentRouter
        // Specifically, PaymentRouter._isFactoryEscrow tries to call getMissionByEscrow on the factory
        // Expecting OnlyMissionEscrow() error from PaymentRouter modifier onlyAuthorizedSettler
        vm.expectRevert();
        escrow.approveCompletion();
        vm.stopPrank();
    }
}
