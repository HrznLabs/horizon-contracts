// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IMissionFactory} from "../src/interfaces/IMissionFactory.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";

contract MockMissionFactory is IMissionFactory {
    mapping(uint256 => address) public missions;

    function setMission(uint256 missionId, address escrow) external {
        missions[missionId] = escrow;
    }

    function getMission(uint256 missionId) external view returns (address) {
        return missions[missionId];
    }
}

contract PaymentRouterSecurityTest is Test {
    PaymentRouter public router;
    MockERC20 public usdc;
    MockMissionFactory public factory;

    address public protocolTreasury = address(0x1);
    address public resolverTreasury = address(0x2);
    address public labsTreasury = address(0x3);
    address public attacker = address(0x1337);
    address public legitimateMission = address(0x888);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury
        );
        factory = new MockMissionFactory();
        router.setMissionFactory(address(factory));

        // Setup legitimate mission
        factory.setMission(1, legitimateMission);
    }

    function test_Exploit_UnauthorizedSettlement() public {
        // 1. Simulate accidental funds in PaymentRouter
        uint256 fundAmount = 1000e6;
        usdc.mint(address(router), fundAmount);

        assertEq(usdc.balanceOf(address(router)), fundAmount, "Router should have funds");

        // 2. Attacker calls settlePayment
        vm.startPrank(attacker);

        // Attacker claims to be performer for mission 999 (doesn't exist)
        // This should now revert
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        router.settlePayment(999, attacker, fundAmount, address(0));

        vm.stopPrank();

        // 3. Verify funds NOT drained
        assertEq(usdc.balanceOf(address(router)), fundAmount, "Router should still have funds");
        assertEq(usdc.balanceOf(attacker), 0, "Attacker should have 0 funds");
    }

    function test_AuthorizedSettlement() public {
        // Simulate funds sent by mission (normal flow)
        uint256 rewardAmount = 1000e6;
        usdc.mint(address(router), rewardAmount);

        // Legitimate mission calls settlePayment
        vm.startPrank(legitimateMission);

        // Should succeed
        router.settlePayment(1, attacker, rewardAmount, address(0));

        vm.stopPrank();

        uint256 expectedPerformerAmount = (rewardAmount * 9000) / 10000;
        assertEq(usdc.balanceOf(attacker), expectedPerformerAmount, "Performer should receive funds");
    }

    function test_RevertWhen_MissionFactoryNotSet() public {
        // Create new router without factory
        PaymentRouter unsafeRouter = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury
        );

        usdc.mint(address(unsafeRouter), 100e6);

        // Should revert because missionFactory is address(0)
        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        unsafeRouter.settlePayment(1, attacker, 100e6, address(0));
    }
}
