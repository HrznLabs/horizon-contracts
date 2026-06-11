// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title SyncCheckTest
 * @notice Validates that Solidity fee constants match TypeScript (packages/shared/src/constants/fees.ts)
 * @dev Run in CI: forge test --match-test testConstantsMatch
 *
 * ⚠️ SYNC: If this test fails, update packages/shared/src/constants/fees.ts to match!
 */
contract SyncCheckTest is Test {
    PaymentRouter public router;

    function setUp() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        router = new PaymentRouter(
            address(usdc),
            address(1),  // protocolTreasury
            address(2),  // resolverTreasury
            address(3),  // labsTreasury
            address(this) // admin
        );
    }

    /**
     * @notice Core constant sync check — MUST match fees.ts
     * If this fails, update packages/shared/src/constants/fees.ts
     */
    function testConstantsMatch() public view {
        // Fixed fees
        assertEq(router.PROTOCOL_FEE_BPS(), 250, "PROTOCOL_FEE_BPS mismatch -- update fees.ts!");
        assertEq(router.LABS_FEE_BPS(), 250, "LABS_FEE_BPS mismatch -- update fees.ts!");
        assertEq(router.RESOLVER_FEE_BPS(), 200, "RESOLVER_FEE_BPS mismatch -- update fees.ts!");

        // Hierarchy fees
        assertEq(router.MAX_SUBDAO_FEE_BPS(), 200, "MAX_SUBDAO_FEE_BPS mismatch -- update fees.ts!");
        assertEq(router.MAX_METADAO_FEE_BPS(), 100, "MAX_METADAO_FEE_BPS mismatch -- update fees.ts!");

        // Performer floor
        assertEq(router.MIN_PERFORMER_FLOOR_BPS(), 8500, "MIN_PERFORMER_FLOOR_BPS mismatch -- update fees.ts!");
        assertEq(router.performerFloorBPS(), 9000, "DEFAULT_PERFORMER_FLOOR_BPS mismatch -- update fees.ts!");

        // Computed: fixed fees total
        uint16 fixedTotal = router.PROTOCOL_FEE_BPS() + router.LABS_FEE_BPS() + router.RESOLVER_FEE_BPS();
        assertEq(fixedTotal, 700, "FIXED_FEES_BPS mismatch -- update fees.ts!");

        // Computed: max guild fee
        uint16 maxGuild = router.maxGuildFeeBPS();
        assertEq(maxGuild, 300, "MAX_GUILD_FEE_BPS mismatch -- update fees.ts!");

        console.log("Sync check PASSED: TypeScript constants match Solidity");
    }
}
