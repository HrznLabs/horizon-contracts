// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ReputationAttestations.sol";

contract ReputationAttestationsTest is Test {
    ReputationAttestations reputation;
    address rater1 = address(0x1);
    address rater2 = address(0x2);
    address ratee = address(0x3);

    function setUp() public {
        reputation = new ReputationAttestations();
    }

    function testSubmitRating() public {
        vm.prank(rater1);
        reputation.submitRating(1, ratee, 5, bytes32("comment1"));

        ReputationAttestations.Rating memory rating = reputation.getRating(1, rater1, ratee);
        assertEq(rating.score, 5);

        assertEq(reputation.ratingCounts(ratee), 1);
        assertEq(reputation.ratingSums(ratee), 5);
        (uint256 avg, uint256 count) = reputation.getAverageRating(ratee);
        assertEq(avg, 500); // 5 * 100 / 1
        assertEq(count, 1);
    }

    function testSubmitMultipleRatings() public {
        vm.prank(rater1);
        reputation.submitRating(1, ratee, 5, bytes32("comment1"));

        vm.prank(rater2);
        reputation.submitRating(2, ratee, 3, bytes32("comment2"));

        assertEq(reputation.ratingCounts(ratee), 2);
        assertEq(reputation.ratingSums(ratee), 8);
        (uint256 avg, uint256 count) = reputation.getAverageRating(ratee);
        assertEq(avg, 400); // 8 * 100 / 2 = 400
        assertEq(count, 2);
    }
}
