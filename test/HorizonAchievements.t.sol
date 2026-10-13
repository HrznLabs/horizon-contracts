// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HorizonAchievements} from "../src/HorizonAchievements.sol";

contract HorizonAchievementsTest is Test {
    HorizonAchievements public achievements;

    address public admin = address(1);
    address public minter = address(2);
    address public userA = address(3);
    address public userB = address(4);

    uint256 public soulboundTypeId;
    uint256 public tradableTypeId;
    uint256 public cappedTypeId;

    function setUp() public {
        vm.startPrank(admin);
        achievements = new HorizonAchievements("Horizon Achievements", "HRZN-ACH", "https://meta.horizon.xyz/");

        // Grant minter role
        achievements.grantRole(achievements.MINTER_ROLE(), minter);

        // Create a soulbound type (maxSupply = 0 → unlimited)
        soulboundTypeId = achievements.createAchievementType(
            "First Mission",
            "Complete your first mission",
            HorizonAchievements.AchievementCategory.Milestone,
            true,  // isSoulbound
            0,     // unlimited supply
            "https://meta.horizon.xyz/soulbound/",
            100
        );

        // Create a tradable type (maxSupply = 0 → unlimited)
        tradableTypeId = achievements.createAchievementType(
            "Speed Demon",
            "Complete a mission in under 5 minutes",
            HorizonAchievements.AchievementCategory.Performance,
            false, // tradable
            0,     // unlimited supply
            "https://meta.horizon.xyz/tradable/",
            200
        );

        // Create a capped type (maxSupply = 2)
        cappedTypeId = achievements.createAchievementType(
            "Founding Member",
            "One of the first members",
            HorizonAchievements.AchievementCategory.Special,
            false, // tradable
            2,     // max supply = 2
            "https://meta.horizon.xyz/capped/",
            500
        );

        vm.stopPrank();
    }

    // =========================================================================
    // Soulbound: transfer is blocked after mint
    // =========================================================================

    function test_SoulboundMint_TransferBlocked() public {
        vm.prank(minter);
        uint256 tokenId = achievements.mintAchievement(userA, soulboundTypeId, keccak256("proof1"));

        assertEq(achievements.ownerOf(tokenId), userA);

        // Attempt to transfer — should revert with SoulboundTransferNotAllowed
        vm.prank(userA);
        vm.expectRevert(HorizonAchievements.SoulboundTransferNotAllowed.selector);
        achievements.transferFrom(userA, userB, tokenId);
    }

    function test_SoulboundMint_SafeTransferBlocked() public {
        vm.prank(minter);
        uint256 tokenId = achievements.mintAchievement(userA, soulboundTypeId, keccak256("proof2"));

        vm.prank(userA);
        vm.expectRevert(HorizonAchievements.SoulboundTransferNotAllowed.selector);
        achievements.safeTransferFrom(userA, userB, tokenId);
    }

    // =========================================================================
    // Tradable: transfer succeeds
    // =========================================================================

    function test_TradableMint_TransferSucceeds() public {
        vm.prank(minter);
        uint256 tokenId = achievements.mintAchievement(userA, tradableTypeId, keccak256("tproof1"));

        assertEq(achievements.ownerOf(tokenId), userA);

        vm.prank(userA);
        achievements.transferFrom(userA, userB, tokenId);

        assertEq(achievements.ownerOf(tokenId), userB);
    }

    // =========================================================================
    // Max-supply enforcement
    // =========================================================================

    function test_MaxSupply_EnforcedOnThirdMint() public {
        vm.startPrank(minter);
        achievements.mintAchievement(userA, cappedTypeId, keccak256("c1"));
        achievements.mintAchievement(userB, cappedTypeId, keccak256("c2"));

        // Third mint must revert
        vm.expectRevert(HorizonAchievements.MaxSupplyReached.selector);
        achievements.mintAchievement(address(5), cappedTypeId, keccak256("c3"));
        vm.stopPrank();
    }

    function test_MaxSupply_ExactBoundary() public {
        vm.startPrank(minter);
        // Two mints succeed
        uint256 t1 = achievements.mintAchievement(userA, cappedTypeId, keccak256("b1"));
        uint256 t2 = achievements.mintAchievement(userB, cappedTypeId, keccak256("b2"));
        vm.stopPrank();

        assertEq(achievements.ownerOf(t1), userA);
        assertEq(achievements.ownerOf(t2), userB);
    }

    // =========================================================================
    // Proof-hash uniqueness (duplicate proof reverts for soulbound)
    // =========================================================================

    function test_ProofHash_SoulboundDuplicateReverts() public {
        bytes32 proof = keccak256("unique-mission-123");

        vm.startPrank(minter);
        achievements.mintAchievement(userA, soulboundTypeId, proof);

        // Same user, same type — should revert (AlreadyHasAchievement for soulbound)
        vm.expectRevert(HorizonAchievements.AlreadyHasAchievement.selector);
        achievements.mintAchievement(userA, soulboundTypeId, proof);
        vm.stopPrank();
    }

    function test_ProofHash_DifferentUsersAcceptedForTradable() public {
        bytes32 proof = keccak256("shared-proof");

        vm.startPrank(minter);
        uint256 t1 = achievements.mintAchievement(userA, tradableTypeId, proof);
        // Different user, same proof — tradable allows it
        uint256 t2 = achievements.mintAchievement(userB, tradableTypeId, proof);
        vm.stopPrank();

        assertTrue(t1 != t2);
        assertEq(achievements.ownerOf(t1), userA);
        assertEq(achievements.ownerOf(t2), userB);
    }
}
