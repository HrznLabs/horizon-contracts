// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryEscrow.sol";
import "../src/token/HorizonToken.sol";
import "../src/interfaces/IMissionFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDCPoC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveryEscrowPoC is Test {
    PaymentRouter router;
    DeliveryMissionFactory factory;
    MockUSDCPoC usdc;

    function setUp() public {
        usdc = new MockUSDCPoC();
        router = new PaymentRouter(
            address(usdc),
            address(0x1),
            address(0x2),
            address(0x3),
            address(this)
        );
        factory = new DeliveryMissionFactory(address(router));

        router.grantRole(router.DEFAULT_ADMIN_ROLE(), address(this));
        router.setMissionFactory(address(factory));
        router.setAcceptedToken(address(usdc), true);

        router.grantRole(router.FEE_MANAGER_ROLE(), address(this));
        router.setPerformerFloor(8500);

        usdc.mint(address(this), 1000e6);
        usdc.approve(address(factory), type(uint256).max);
    }

    function test_settleFailsExplicitlyTrace() public {
        uint256 rewardAmount = 100e6;
        uint256 expiresAt = block.timestamp + 2 hours;

        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            rewardAmount,
            expiresAt,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrowAddress = factory.missions(missionId);
        DeliveryEscrow escrow = DeliveryEscrow(payable(escrowAddress));

        vm.prank(address(0x4));
        escrow.acceptMission();

        vm.prank(address(0x4));
        escrow.submitProof(bytes32(0));

        vm.prank(address(this));
        // Need to see where it reverts
        vm.expectRevert();
        escrow.approveCompletion();
    }
}
