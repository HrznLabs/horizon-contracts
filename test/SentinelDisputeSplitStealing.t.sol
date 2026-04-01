// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DisputeResolver.sol";
import "../src/MissionEscrow.sol";
import "../src/MissionFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockPaymentRouter {
    function setMissionFactory(address) external { }
    function settlePayment(uint256, address, uint256, address) external { }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SentinelDisputeSplitStealing is Test {
    MockUSDC usdc;
    MockPaymentRouter router;
    MissionFactory factory;
    DisputeResolver resolver;

    address poster = address(0x1111);
    address performer = address(0x2222);
    address resolversDAO = address(0x3333);

    function setUp() public {
        usdc = new MockUSDC();
        router = new MockPaymentRouter();
        factory = new MissionFactory(address(usdc), address(router));
        resolver = new DisputeResolver(
            address(usdc), address(factory), resolversDAO, address(0x8), address(0x9), address(0xA)
        );

        factory.setDisputeResolver(address(resolver));

        usdc.mint(poster, 100_000e6);
        usdc.mint(performer, 10_000e6);
    }

    function test_SplitStealing() public {
        vm.startPrank(poster);
        usdc.approve(address(factory), type(uint256).max);
        uint256 missionId = factory.createMission(
            1000e6, block.timestamp + 1 days, address(0), bytes32(0), bytes32(0)
        );
        vm.stopPrank();

        address escrowAddr = factory.getMission(missionId);
        MissionEscrow escrow = MissionEscrow(escrowAddr);

        vm.prank(performer);
        escrow.acceptMission();

        // Performer submits proof
        vm.prank(performer);
        escrow.submitProof(bytes32(uint256(1)));

        // Performer raises dispute
        vm.startPrank(performer);
        usdc.approve(address(resolver), type(uint256).max);
        uint256 disputeId = resolver.createDispute(escrowAddr, missionId, bytes32(uint256(2)));
        vm.stopPrank();

        // Poster never deposits DDR

        // Resolver assigned
        vm.prank(resolversDAO);
        resolver.assignResolver(disputeId, address(0x7777));

        // Resolver decides Split 50%
        vm.prank(address(0x7777));
        resolver.resolveDispute(disputeId, IDisputeResolver.DisputeOutcome.Split, bytes32(0), 5000);

        // Advance time to pass appeal period
        vm.warp(block.timestamp + 49 hours);

        uint256 posterBalanceBefore = usdc.balanceOf(poster);

        // Finalize dispute
        resolver.finalizeDispute(disputeId);

        uint256 posterBalanceAfter = usdc.balanceOf(poster);

        uint256 posterGain = posterBalanceAfter - posterBalanceBefore;

        console.log("Poster Gain (DDR stolen):", posterGain);

        if (posterGain > 500e6) {
            console.log("Poster stole DDR:", posterGain - 500e6);
            assert(false);
        }
    }
}
