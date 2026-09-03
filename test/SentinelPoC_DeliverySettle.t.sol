// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockTokenForPoC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SentinelPoCDeliverySettle is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockTokenForPoC token;

    function setUp() public {
        token = new MockTokenForPoC();
        router = new PaymentRouter(address(token), address(this), address(this), address(this), address(this));

        factory = new DeliveryMissionFactory(address(router));

        router.setMissionFactory(address(factory));
        router.setAcceptedToken(address(token), true);

        token.mint(address(this), 10000 * 1e6);
        token.approve(address(factory), type(uint256).max);
    }

    function test_settlementFailsBecauseFactoryMissingGetter() public {
        uint256 missionId = factory.createDeliveryMission(
            address(token),
            100 * 1e6, // reward
            block.timestamp + 2 hours, // expiry
            address(0), // guild
            bytes32(0),
            bytes32(0)
        );

        DeliveryEscrow escrow = DeliveryEscrow(payable(factory.missions(missionId)));
        token.mint(address(escrow), 100 * 1e6);
        token.mint(address(router), 100 * 1e6);

        vm.prank(address(escrow));

        // This will revert because DeliveryMissionFactory does not have getMissionByEscrow
        // So PaymentRouter._isFactoryEscrow catches the revert and returns false.
        // So OnlyAuthorizedSettler reverts the transaction.
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        router.settlePayment(
            missionId,
            address(0x123), // performer
            address(token),  // token
            100 * 1e6,      // reward
            address(0)      // guild
        );
    }
}
