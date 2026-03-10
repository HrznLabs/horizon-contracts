// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ReputationAttestations.sol";
import "../src/interfaces/IMissionFactory.sol";
import "../src/interfaces/IMissionEscrow.sol";

contract ReputationAttestationsTest is Test {
    ReputationAttestations reputation;
    address rater1 = address(0x1);
    address rater2 = address(0x2);
    address ratee = address(0x3);
    address factory = address(0x4);
    address escrow = address(0x5);

    function setUp() public {
        reputation = new ReputationAttestations();
        reputation.setMissionFactory(factory);
    }

    function testSubmitRating() public {
        // Mock factory.getMission(1) -> escrow
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMissionFactory.getMission.selector, 1),
            abi.encode(escrow)
        );

        // Mock escrow.getParticipants() -> Poster=rater1, Performer=ratee, State=Completed
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IMissionEscrow.getParticipants.selector),
            abi.encode(rater1, ratee, IMissionEscrow.MissionState.Completed)
        );

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
        // Mock factory.getMission(1) -> escrow
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMissionFactory.getMission.selector, 1),
            abi.encode(escrow)
        );
        // Mock factory.getMission(2) -> escrow (reuse same escrow for simplicity)
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMissionFactory.getMission.selector, 2),
            abi.encode(escrow)
        );

        // Mock escrow for rater1 -> ratee (poster -> performer)
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IMissionEscrow.getParticipants.selector),
            abi.encode(rater1, ratee, IMissionEscrow.MissionState.Completed)
        );

        vm.prank(rater1);
        reputation.submitRating(1, ratee, 5, bytes32("comment1"));

        // Mock escrow for rater2 -> ratee (also poster -> performer for simplicity, or change params)
        // Let's say rater2 is also poster of mission 2
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IMissionEscrow.getParticipants.selector),
            abi.encode(rater2, ratee, IMissionEscrow.MissionState.Completed)
        );

        vm.prank(rater2);
        reputation.submitRating(2, ratee, 3, bytes32("comment2"));

        assertEq(reputation.ratingCounts(ratee), 2);
        assertEq(reputation.ratingSums(ratee), 8);
        (uint256 avg, uint256 count) = reputation.getAverageRating(ratee);
        assertEq(avg, 400); // 8 * 100 / 2 = 400
        assertEq(count, 2);
    }
}
