// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeliveryMissionFactory} from "../src/DeliveryMissionFactory.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IMissionFactory} from "../src/interfaces/IMissionFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1000000e18);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveryEscrowAuthPoC is Test {
    DeliveryMissionFactory factory;
    PaymentRouter router;
    MockToken token;
    address user = address(0x1);

    function setUp() public {
        token = new MockToken();
        router = new PaymentRouter(
            address(token),
            address(this),
            address(this),
            address(this),
            address(this)
        );
        vm.prank(address(this));
        router.setAcceptedToken(address(token), true);

        factory = new DeliveryMissionFactory(address(router));
        vm.prank(address(this));
        router.setMissionFactory(address(factory));

        token.mint(user, 10000000);
        vm.prank(user);
        token.approve(address(factory), type(uint256).max);
    }

    function test_DeliveryEscrowAuthenticationFails() public {
        vm.prank(user);
        uint256 missionId = factory.createDeliveryMission(
            address(token),
            1e6, // rewardAmount
            block.timestamp + 2 hours, // expiresAt
            address(0), // guild
            bytes32(0), // metadataHash
            bytes32(0)  // locationHash
        );

        address escrow = factory.missions(missionId);

        // Verify that PaymentRouter treats the escrow as unauthorized
        vm.prank(escrow);
        vm.expectRevert(bytes4(keccak256("OnlyMissionEscrow()")));
        router.settlePayment(missionId, user, address(token), 1e6, address(0));
    }
}
