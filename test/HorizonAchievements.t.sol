// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/HorizonAchievements.sol";

contract HorizonAchievementsTest is Test {
    HorizonAchievements achievements;
    address admin = address(this);
    address minter = address(2);
    address user = address(3);
    address user2 = address(4);
    address[] users;

    function setUp() public {
        achievements = new HorizonAchievements("Horizon Achievements", "HACH", "https://example.com/");

        achievements.grantRole(achievements.ADMIN_ROLE(), admin);
        achievements.grantRole(achievements.MINTER_ROLE(), minter);

        achievements.createAchievementType(
            "Test Achievement",
            "TEST",
            HorizonAchievements.AchievementCategory.Milestone,
            false,
            0,
            "https://test.com/",
            10
        );

        for (uint i = 10; i < 20; i++) {
            users.push(address(uint160(i)));
        }
    }

    function test_mintAchievement() public {
        vm.prank(minter);
        achievements.mintAchievement(user, 1, bytes32(0));
        assertEq(achievements.balanceOf(user), 1);
    }

    function test_batchMintAchievements() public {
        bytes32[] memory proofHashes = new bytes32[](users.length);
        vm.prank(minter);
        achievements.batchMintAchievements(users, 1, proofHashes);
        for (uint i = 0; i < users.length; i++) {
            assertEq(achievements.balanceOf(users[i]), 1);
        }
    }

    function test_transferAchievement() public {
        vm.prank(minter);
        achievements.mintAchievement(user, 1, bytes32(0));

        vm.prank(user);
        achievements.transferFrom(user, user2, 1);
        assertEq(achievements.balanceOf(user2), 1);
        assertEq(achievements.balanceOf(user), 0);
    }
}
