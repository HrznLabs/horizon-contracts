// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/DeliveryEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken2 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DeliveryEscrowPoCTest is Test {
    PaymentRouter router;
    DeliveryMissionFactory factory;
    MockToken2 token;

    address admin = address(1);
    address poster = address(2);
    address performer = address(3);

    function setUp() public {
        vm.startPrank(admin);
        token = new MockToken2();

        router = new PaymentRouter(
            address(token),
            address(10), // protocol
            address(11), // resolver
            address(12), // labs
            admin
        );

        factory = new DeliveryMissionFactory(address(router));
        router.setMissionFactory(address(factory));

        token.transfer(poster, 1000 * 10**6);
        vm.stopPrank();
    }

    function testDeliveryEscrowCannotSettle() public {
        vm.startPrank(poster);
        token.approve(address(factory), type(uint256).max);

        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100 * 10**6, // reward
            block.timestamp + 2 hours,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrow = factory.missions(missionId);
        vm.stopPrank();

        // The escrow should be unable to settle payment because it fails the _isFactoryEscrow check
        vm.prank(escrow);
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        router.settlePayment(missionId, performer, address(token), 100 * 10**6, address(0));
    }
}
