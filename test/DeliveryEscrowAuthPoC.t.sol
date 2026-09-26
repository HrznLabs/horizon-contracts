// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveryMissionFactory.sol";
import "../src/PaymentRouter.sol";
import "../src/DeliveryEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20PoC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveryEscrowAuthPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockERC20PoC token;

    function setUp() public {
        token = new MockERC20PoC();
        router = new PaymentRouter(address(token), address(1), address(2), address(3), address(this));
        router.grantRole(router.DEFAULT_ADMIN_ROLE(), address(this));
        router.grantRole(router.FEE_MANAGER_ROLE(), address(this));

        factory = new DeliveryMissionFactory(address(router));

        router.setAcceptedToken(address(token), true);
        router.setMissionFactory(address(factory));

        token.mint(address(this), 1000e6);
        token.approve(address(factory), type(uint256).max);
    }

    function testMissionSettlementVulnerability() public {
        bytes32 metadataHash = keccak256("metadata");
        bytes32 locationHash = keccak256("location");
        uint256 expiresAt = block.timestamp + 2 hours;

        uint256 missionId = factory.createDeliveryMission(
            address(token),
            10e6,
            expiresAt,
            address(0),
            metadataHash,
            locationHash
        );

        address escrow = factory.missions(missionId);

        // As a performer, accept and complete
        vm.startPrank(address(0x1337));
        DeliveryEscrow(payable(escrow)).acceptMission();
        DeliveryEscrow(payable(escrow)).submitProof(keccak256("proof"));
        vm.stopPrank();

        // This simulates what happens when we try to approve and trigger settlement:
        // Because DeliveryMissionFactory does not implement `getMissionByEscrow(address)`,
        // the PaymentRouter's fallback try-catch inside `_isFactoryEscrow` fails and returns false,
        // which triggers `OnlyMissionEscrow()` revert.

        vm.expectRevert(IPaymentRouter.OnlyMissionEscrow.selector);
        DeliveryEscrow(payable(escrow)).approveCompletion();
    }
}
