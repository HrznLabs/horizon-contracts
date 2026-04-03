// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DisputeResolver.sol";
import "../src/MissionEscrow.sol";
import "../src/MissionFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DisputeResolverOverrideSplitValidationTest is Test {
    DisputeResolver public resolver;
    MissionFactory public factory;
    MockUSDC public usdc;

    address public protocolDAO = address(0x1);
    address public resolversDAO = address(0x2);
    address public protocolTreasury = address(0x3);
    address public resolverTreasury = address(0x4);
    address public routerAddr = address(0x99);

    address public poster = address(0x11);
    address public performer = address(0x12);
    address public resolverUser = address(0x13);

    function setUp() public {
        usdc = new MockUSDC();
        factory = new MissionFactory(address(usdc), routerAddr);

        resolver = new DisputeResolver(
            address(usdc),
            address(factory),
            resolversDAO,
            protocolDAO,
            protocolTreasury,
            resolverTreasury
        );

        factory.setDisputeResolver(address(resolver));

        usdc.mint(poster, 10_000e6);
        usdc.mint(performer, 10_000e6);

        vm.startPrank(poster);
        usdc.approve(address(factory), type(uint256).max);
        usdc.approve(address(resolver), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(performer);
        usdc.approve(address(resolver), type(uint256).max);
        vm.stopPrank();
    }

    function test_OverrideResolution_RevertIfSplitPercentageInvalid() public {
        vm.startPrank(poster);
        uint256 missionId = factory.createMission(
            100e6, block.timestamp + 1 days, address(0), bytes32(0), bytes32(0)
        );
        address escrowAddr = factory.getMission(missionId);
        vm.stopPrank();

        vm.startPrank(performer);
        MissionEscrow(escrowAddr).acceptMission();
        vm.stopPrank();

        vm.startPrank(poster);
        uint256 disputeId = resolver.createDispute(escrowAddr, missionId, bytes32(0));
        vm.stopPrank();

        vm.prank(resolversDAO);
        resolver.assignResolver(disputeId, resolverUser);

        vm.startPrank(performer);
        resolver.submitEvidence(disputeId, bytes32(0));
        vm.stopPrank();

        vm.prank(resolverUser);
        resolver.resolveDispute(disputeId, IDisputeResolver.DisputeOutcome.Split, bytes32(0), 5000);

        vm.prank(poster);
        resolver.appealResolution(disputeId);

        vm.startPrank(protocolDAO);
        vm.expectRevert(IDisputeResolver.InvalidOutcome.selector);
        resolver.overrideResolution(
            disputeId, IDisputeResolver.DisputeOutcome.Split, bytes32(0), 10_001
        );
        vm.stopPrank();
    }
}
