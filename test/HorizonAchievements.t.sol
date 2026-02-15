// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { HorizonAchievements } from "../src/HorizonAchievements.sol";

contract HorizonAchievementsTest is Test {
    HorizonAchievements public achievements;
    address public admin = address(1);
    address public user = address(2);

    function setUp() public {
        vm.prank(admin);
        achievements = new HorizonAchievements(
            "Horizon Achievements", "HRZN", "https://horizon.xyz/api/achievements/"
        );
    }

    function test_CreateAchievementType() public {
        vm.prank(admin);
        uint256 typeId = achievements.createAchievementType(
            "First Mission",
            "Complete your first mission",
            HorizonAchievements.AchievementCategory.Milestone,
            true, // Soulbound
            0, // Unlimited
            "first-mission",
            100
        );

        assertEq(typeId, 1);

        HorizonAchievements.AchievementType memory typeInfo = achievements.getAchievementType(typeId);
        assertEq(typeInfo.name, "First Mission");
        assertEq(typeInfo.description, "Complete your first mission");
        assertEq(uint8(typeInfo.category), uint8(HorizonAchievements.AchievementCategory.Milestone));
        assertTrue(typeInfo.isSoulbound);
        assertEq(typeInfo.maxSupply, 0);
        assertEq(typeInfo.baseTokenURI, "first-mission");
        assertEq(typeInfo.xpReward, 100);
    }

    function test_MintAchievement() public {
        vm.startPrank(admin);
        uint256 typeId = achievements.createAchievementType(
            "First Mission",
            "Complete your first mission",
            HorizonAchievements.AchievementCategory.Milestone,
            true, // Soulbound
            0, // Unlimited
            "first-mission",
            100
        );
        vm.stopPrank();

        bytes32 proofHash = keccak256("proof");

        vm.prank(admin);
        uint256 tokenId = achievements.mintAchievement(user, typeId, proofHash);

        assertEq(tokenId, 1);
        assertEq(achievements.ownerOf(tokenId), user);

        HorizonAchievements.Achievement memory achievement = achievements.getAchievement(tokenId);
        assertEq(achievement.tokenId, tokenId);
        assertEq(achievement.typeId, typeId);
        assertEq(achievement.originalOwner, user);
        assertEq(achievement.proofHash, proofHash);
        // MintedAt should be close to block.timestamp
        assertEq(achievement.mintedAt, block.timestamp);

        // Check user tracking
        assertTrue(achievements.hasAchievement(user, typeId));
        assertEq(achievements.getUserAchievementToken(user, typeId), tokenId);
    }

    function test_SoulboundTransfer() public {
        vm.startPrank(admin);
        uint256 typeId = achievements.createAchievementType(
            "Soulbound",
            "Soulbound achievement",
            HorizonAchievements.AchievementCategory.Milestone,
            true, // Soulbound
            0, // Unlimited
            "",
            100
        );
        uint256 tokenId = achievements.mintAchievement(user, typeId, keccak256("proof"));
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(HorizonAchievements.SoulboundTransferNotAllowed.selector);
        achievements.transferFrom(user, address(3), tokenId);
    }

    function test_TradableTransfer() public {
        vm.startPrank(admin);
        uint256 typeId = achievements.createAchievementType(
            "Tradable",
            "Tradable achievement",
            HorizonAchievements.AchievementCategory.Special,
            false, // Not Soulbound
            0, // Unlimited
            "",
            100
        );
        uint256 tokenId = achievements.mintAchievement(user, typeId, keccak256("proof"));
        vm.stopPrank();

        vm.prank(user);
        achievements.transferFrom(user, address(3), tokenId);

        assertEq(achievements.ownerOf(tokenId), address(3));

        // Verify internal tracking updates
        assertFalse(achievements.hasAchievement(user, typeId));
        assertTrue(achievements.hasAchievement(address(3), typeId));
    }
}
