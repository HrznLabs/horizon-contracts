// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MissionFactory} from "../src/MissionFactory.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionEscrow} from "../src/interfaces/IMissionEscrow.sol";
import {IDisputeResolver} from "../src/interfaces/IDisputeResolver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DisputeResolverDeadlock is Test {
    MissionFactory public factory;
    PaymentRouter public router;
    DisputeResolver public resolver;
    MockERC20 public usdc;

    address public poster = address(1);
    address public performer = address(2);
    address public resolverAddr = address(3);
    address public dao = address(4);
    address public protocolTreasury = address(5);
    address public resolverTreasury = address(6);

    uint256 public constant REWARD_AMOUNT = 1000e6;
    bytes32 public constant EVIDENCE_HASH = keccak256("evidence");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, protocolTreasury);
        factory = new MissionFactory(address(usdc), address(router));
        resolver = new DisputeResolver(
            address(usdc),
            address(factory),
            dao, // Resolvers DAO
            dao, // Protocol DAO
            protocolTreasury,
            resolverTreasury
        );

        factory.setDisputeResolver(address(resolver));
        router.setMissionFactory(address(factory));

        // Fund parties
        usdc.mint(poster, REWARD_AMOUNT * 2);
        usdc.mint(performer, REWARD_AMOUNT);
    }

    function test_DisputeDeadlock_OnePartyNoShow_Fails() public {
        // 1. Poster creates mission
        vm.startPrank(poster);
        usdc.approve(address(factory), REWARD_AMOUNT);
        uint256 missionId = factory.createMission(
            REWARD_AMOUNT,
            block.timestamp + 1 days,
            address(0),
            keccak256("meta"),
            keccak256("loc")
        );
        vm.stopPrank();

        address escrowAddr = factory.missions(missionId);

        // 2. Performer accepts
        vm.prank(performer);
        IMissionEscrow(escrowAddr).acceptMission();

        // 3. Poster raises dispute
        vm.startPrank(poster);
        uint256 ddrAmount = (REWARD_AMOUNT * 500) / 10000; // 5% DDR
        usdc.approve(address(resolver), ddrAmount);
        uint256 disputeId = resolver.createDispute(escrowAddr, missionId, EVIDENCE_HASH);
        vm.stopPrank();

        // 4. Assign resolver
        vm.prank(dao);
        resolver.assignResolver(disputeId, resolverAddr);

        // 5. Performer goes missing, never submits evidence or DDR

        // 6. Resolver attempts to resolve in favor of poster (who followed rules)
        vm.prank(resolverAddr);
        // Expect insufficient DDR because performer didn't deposit
        resolver.resolveDispute(
            disputeId,
            IDisputeResolver.DisputeOutcome.Split,
            keccak256("resolution"),
            5000
        );

        // Check if dispute state is resolved
        IDisputeResolver.Dispute memory dispute = resolver.getDispute(disputeId);
        assertEq(uint256(dispute.state), uint256(IDisputeResolver.DisputeState.Resolved));
    }
}
