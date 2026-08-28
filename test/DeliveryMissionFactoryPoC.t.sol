// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryEscrow.sol";
import "../src/interfaces/IPaymentRouter.sol";
import "../src/interfaces/IMissionEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveryMissionFactoryPoC is Test {
    DeliveryMissionFactory public factory;
    PaymentRouter public router;
    MockUSDC public usdc;

    address public protocolTreasury = address(0x10);
    address public resolverTreasury = address(0x11);
    address public labsTreasury = address(0x12);
    address public admin = address(0x13);

    function setUp() public {
        usdc = new MockUSDC();
        router = new PaymentRouter(address(usdc), protocolTreasury, resolverTreasury, labsTreasury, admin);
        factory = new DeliveryMissionFactory(address(router));

        vm.prank(admin);
        router.setMissionFactory(address(factory));
    }

    function test_settlementFailsDueToMissingGetMissionByEscrow() public {
        address poster = address(0xAA);
        address performer = address(0xBB);

        usdc.mint(poster, 100e6);
        vm.startPrank(poster);
        usdc.approve(address(factory), 100e6);
        uint256 missionId = factory.createDeliveryMission(
            address(usdc),
            100e6,
            block.timestamp + 2 hours,
            address(0),
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        address escrow = factory.missions(missionId);

        // Performer completes it
        vm.prank(performer);
        IMissionEscrow(escrow).acceptMission();

        vm.prank(performer);
        IMissionEscrow(escrow).submitProof(bytes32(0));

        // Settle will fail with OnlyMissionEscrow because _isFactoryEscrow fails internally in PaymentRouter
        vm.prank(poster);
        vm.expectRevert();
        IMissionEscrow(escrow).approveCompletion();
    }
}
