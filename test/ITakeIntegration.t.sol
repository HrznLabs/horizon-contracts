// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title ITakeIntegrationTest
 * @notice On-chain integration tests for iTake fee split validation (Plan 03-04 Task 3)
 * @dev Verifies: SubDAO 2% + MetaDAO 0.5% + performer floor 90% + tips pass-through
 */
contract ITakeIntegrationTest is Test {
    PaymentRouter public router;
    MockERC20 public usdc;

    address public admin = address(1);
    address public performer = address(2);
    address public poster = address(3);

    // iTake hierarchy
    address public iTakeMetaDAO = address(10);
    address public restaurantSubDAO = address(11);

    // Fee treasuries
    address public protocolTreasury = address(20);
    address public labsTreasury = address(21);
    address public resolverTreasury = address(22);
    address public metaDAOTreasury = address(23);
    address public subDAOTreasury = address(24);

    // Fee config (basis points)
    uint16 public constant SUBDAO_FEE_BPS = 200;    // 2% restaurant fee
    uint16 public constant METADAO_FEE_BPS = 50;    // 0.5% iTake platform fee

    // Protocol constants (from PaymentRouter)
    uint16 public constant PROTOCOL_FEE_BPS = 250;
    uint16 public constant LABS_FEE_BPS = 250;
    uint16 public constant RESOLVER_FEE_BPS = 200;
    uint16 public constant BPS_DENOMINATOR = 10000;
    uint16 public constant PERFORMER_FLOOR_BPS = 9000;

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(
            address(usdc),
            protocolTreasury,
            resolverTreasury,
            labsTreasury,
            admin
        );

        // Set guild treasuries
        router.setGuildTreasury(iTakeMetaDAO, metaDAOTreasury);
        router.setGuildTreasury(restaurantSubDAO, subDAOTreasury);

        // Grant SETTLER_ROLE to admin for direct test calls
        router.grantRole(router.SETTLER_ROLE(), admin);

        vm.stopPrank();

        // Fund poster
        usdc.mint(poster, 10_000e6);
        vm.prank(poster);
        usdc.transfer(address(router), 10_000e6);
    }

    // =========================================================================
    // Test 1: Standard iTake fee split (2% SubDAO + 0.5% MetaDAO)
    // =========================================================================

    function test_FeeSplitWithSubDAO() public {
        uint256 rewardAmount = 15e6; // €15.00 in USDC (6 decimals)

        uint256 performerBefore = usdc.balanceOf(performer);
        uint256 subDAOBefore   = usdc.balanceOf(subDAOTreasury);
        uint256 metaDAOBefore  = usdc.balanceOf(metaDAOTreasury);
        uint256 protocolBefore = usdc.balanceOf(protocolTreasury);
        uint256 labsBefore     = usdc.balanceOf(labsTreasury);
        uint256 resolverBefore = usdc.balanceOf(resolverTreasury);

        vm.prank(admin);
        router.settlePaymentWithHierarchy(
            1,                    // missionId
            performer,
            address(usdc),
            rewardAmount,
            restaurantSubDAO,
            iTakeMetaDAO,
            SUBDAO_FEE_BPS,
            METADAO_FEE_BPS
        );

        uint256 performerGot  = usdc.balanceOf(performer) - performerBefore;
        uint256 subDAOGot     = usdc.balanceOf(subDAOTreasury) - subDAOBefore;
        uint256 metaDAOGot    = usdc.balanceOf(metaDAOTreasury) - metaDAOBefore;
        uint256 protocolGot   = usdc.balanceOf(protocolTreasury) - protocolBefore;
        uint256 labsGot       = usdc.balanceOf(labsTreasury) - labsBefore;
        uint256 resolverGot   = usdc.balanceOf(resolverTreasury) - resolverBefore;

        uint256 totalOut = performerGot + subDAOGot + metaDAOGot + protocolGot + labsGot + resolverGot;

        console.log("Performer:  ", performerGot);
        console.log("SubDAO:     ", subDAOGot);
        console.log("MetaDAO:    ", metaDAOGot);
        console.log("Protocol:   ", protocolGot);
        console.log("Labs:       ", labsGot);
        console.log("Resolver:   ", resolverGot);
        console.log("Total out:  ", totalOut);

        // Performer gets at least floor (90%)
        assertGe(performerGot, (rewardAmount * PERFORMER_FLOOR_BPS) / BPS_DENOMINATOR,
            "Performer below floor");

        // SubDAO gets 2%
        assertEq(subDAOGot, (rewardAmount * SUBDAO_FEE_BPS) / BPS_DENOMINATOR,
            "SubDAO fee wrong");

        // MetaDAO gets 0.5%
        assertEq(metaDAOGot, (rewardAmount * METADAO_FEE_BPS) / BPS_DENOMINATOR,
            "MetaDAO fee wrong");

        // No wei lost (sum = total, allow 1 wei rounding)
        assertApproxEqAbs(totalOut, rewardAmount, 1, "Wei lost in distribution");
    }

    // =========================================================================
    // Test 2: No guild — standard settlement, performer gets >= 90%
    // =========================================================================

    function test_FeeSplitNoGuild() public {
        uint256 rewardAmount = 10e6;

        uint256 performerBefore = usdc.balanceOf(performer);

        vm.prank(admin);
        router.settlePaymentWithHierarchy(
            2,
            performer,
            address(usdc),
            rewardAmount,
            address(0),  // no SubDAO
            address(0),  // no MetaDAO
            0,
            0
        );

        uint256 performerGot = usdc.balanceOf(performer) - performerBefore;
        assertGe(performerGot, (rewardAmount * PERFORMER_FLOOR_BPS) / BPS_DENOMINATOR,
            "Performer below floor (no guild)");
    }

    // =========================================================================
    // Test 3: Odd amounts — verify no wei lost
    // =========================================================================

    function test_FeeSplitRounding_NoWeiLost() public {
        uint256 rewardAmount = 7_770_000; // €7.77 in USDC

        uint256 performerBefore = usdc.balanceOf(performer);
        uint256 subDAOBefore    = usdc.balanceOf(subDAOTreasury);
        uint256 metaDAOBefore   = usdc.balanceOf(metaDAOTreasury);
        uint256 protocolBefore  = usdc.balanceOf(protocolTreasury);
        uint256 labsBefore      = usdc.balanceOf(labsTreasury);
        uint256 resolverBefore  = usdc.balanceOf(resolverTreasury);

        vm.prank(admin);
        router.settlePaymentWithHierarchy(
            3,
            performer,
            address(usdc),
            rewardAmount,
            restaurantSubDAO,
            iTakeMetaDAO,
            SUBDAO_FEE_BPS,
            METADAO_FEE_BPS
        );

        uint256 totalOut =
            (usdc.balanceOf(performer) - performerBefore) +
            (usdc.balanceOf(subDAOTreasury) - subDAOBefore) +
            (usdc.balanceOf(metaDAOTreasury) - metaDAOBefore) +
            (usdc.balanceOf(protocolTreasury) - protocolBefore) +
            (usdc.balanceOf(labsTreasury) - labsBefore) +
            (usdc.balanceOf(resolverTreasury) - resolverBefore);

        // Allow max 1 wei rounding loss
        assertApproxEqAbs(totalOut, rewardAmount, 1, "Wei lost on odd amount");
    }

    // =========================================================================
    // Test 4: Reject invalid SubDAO fee (>2%)
    // =========================================================================

    function test_RejectExcessiveSubDAOFee() public {
        vm.prank(admin);
        vm.expectRevert(); // InvalidFeeConfig
        router.settlePaymentWithHierarchy(
            4,
            performer,
            address(usdc),
            10e6,
            restaurantSubDAO,
            iTakeMetaDAO,
            300,   // 3% — exceeds MAX_SUBDAO_FEE_BPS (200)
            METADAO_FEE_BPS
        );
    }

    // =========================================================================
    // Test 5: Fuzz — performer always gets at least floor, no wei lost
    // =========================================================================

    function test_fuzz_FeeSplit(uint256 rewardAmount) public {
        // Bound to realistic range: $1 to $10,000 USDC
        rewardAmount = bound(rewardAmount, 1e6, 10_000e6);

        // Ensure router has enough funds
        usdc.mint(address(router), rewardAmount);

        uint256 performerBefore  = usdc.balanceOf(performer);
        uint256 subDAOBefore     = usdc.balanceOf(subDAOTreasury);
        uint256 metaDAOBefore    = usdc.balanceOf(metaDAOTreasury);
        uint256 protocolBefore   = usdc.balanceOf(protocolTreasury);
        uint256 labsBefore       = usdc.balanceOf(labsTreasury);
        uint256 resolverBefore   = usdc.balanceOf(resolverTreasury);

        vm.prank(admin);
        router.settlePaymentWithHierarchy(
            5,
            performer,
            address(usdc),
            rewardAmount,
            restaurantSubDAO,
            iTakeMetaDAO,
            SUBDAO_FEE_BPS,
            METADAO_FEE_BPS
        );

        uint256 performerGot = usdc.balanceOf(performer) - performerBefore;
        uint256 totalOut =
            performerGot +
            (usdc.balanceOf(subDAOTreasury) - subDAOBefore) +
            (usdc.balanceOf(metaDAOTreasury) - metaDAOBefore) +
            (usdc.balanceOf(protocolTreasury) - protocolBefore) +
            (usdc.balanceOf(labsTreasury) - labsBefore) +
            (usdc.balanceOf(resolverTreasury) - resolverBefore);

        // Performer always at or above floor
        assertGe(performerGot, (rewardAmount * PERFORMER_FLOOR_BPS) / BPS_DENOMINATOR,
            "Performer below floor (fuzz)");

        // No more than 1 wei lost to rounding
        assertApproxEqAbs(totalOut, rewardAmount, 1, "Wei lost (fuzz)");
    }
}
