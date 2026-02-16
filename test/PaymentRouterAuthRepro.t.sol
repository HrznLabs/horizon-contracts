// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { PaymentRouter } from "../src/PaymentRouter.sol";
import { IPaymentRouter } from "../src/interfaces/IPaymentRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract PaymentRouterAuthRepro is Test {
    PaymentRouter public router;
    MockERC20 public usdc;

    address public owner = address(1);
    address public protocolTreasury = address(4);
    address public resolverTreasury = address(5);
    address public labsTreasury = address(6);
    address public attacker = address(999);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury);
        vm.stopPrank();

        // Fund the router (simulate stuck funds or accidental transfer)
        usdc.mint(address(router), 1000e6);
    }

    function test_Exploit_UnauthorizedPaymentSettlement_Reverts() public {
        vm.startPrank(attacker);

        uint256 routerBalanceBefore = usdc.balanceOf(address(router));
        console.log("Router Balance Before:", routerBalanceBefore);

        // Attacker calls settlePayment to drain funds to themselves (as performer)
        // They use a fake missionId and themselves as performer

        // This should now revert because msg.sender (attacker) is not the mission address
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        router.settlePayment(
            12_345, // fake missionId
            attacker,
            1000e6, // Amount to drain
            address(0) // No guild
        );

        uint256 routerBalanceAfter = usdc.balanceOf(address(router));
        uint256 attackerBalance = usdc.balanceOf(attacker);

        console.log("Router Balance After:", routerBalanceAfter);
        console.log("Attacker Balance:", attackerBalance);

        // Attacker gets nothing
        assertEq(attackerBalance, 0);
        // Router balance unchanged
        assertEq(routerBalanceAfter, routerBalanceBefore);

        vm.stopPrank();
    }
}
