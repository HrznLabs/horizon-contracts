// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken2 is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract DeliverySettlementPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockToken2 token;

    address poster = address(0x1);
    address performer = address(0x2);

    function setUp() public {
        token = new MockToken2();
        router = new PaymentRouter(
            address(token),
            address(0x10),
            address(0x11),
            address(0x12),
            address(this)
        );
        router.grantRole(router.DEFAULT_ADMIN_ROLE(), address(this));

        factory = new DeliveryMissionFactory(address(router));

        router.setMissionFactory(address(factory));

        router.setAcceptedToken(address(token), true);

        token.mint(poster, 1000e6);
        token.mint(address(router), 100e6);
    }

    function testSettlementFails() public {
        vm.startPrank(poster);
        token.approve(address(factory), 1000e6);
        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100e6,
            block.timestamp + 1 days,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        vm.startPrank(escrow);
        // The escrow fails to settle payments because the router can't verify it
        // _isFactoryEscrow will revert due to missing getMissionByEscrow
        // Which translates to a revert with OnlyMissionEscrow()
        vm.expectRevert();
        router.settlePayment(missionId, performer, address(token), 100e6, address(0));
        vm.stopPrank();
    }
}
