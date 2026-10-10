// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/token/sHRZNVault.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract sHRZNVaultDoSTest is Test {
    sHRZNVault public vault;
    MockToken public hrzn;
    MockToken public usdc;

    address user = address(0x1);

    function setUp() public {
        hrzn = new MockToken();
        usdc = new MockToken();
        vault = new sHRZNVault(address(hrzn), address(usdc), address(this));

        hrzn.mint(user, 1000e18);
        vm.prank(user);
        hrzn.approve(address(vault), 1000e18);
    }

    function testRequestUnstakeRevertsDueToSelfDenial() public {
        vm.startPrank(user);
        vault.deposit(100e18, user);

        // This fails because inside requestUnstake we update unstakeRequests[user] BEFORE calling _transfer
        // _transfer calls _update, which checks if unstakeRequests[from].shares == 0
        // Because unstakeRequests is set before the transfer, the transfer reverts.
        vm.expectRevert("sHRZNVault: shares locked in cooldown");
        vault.requestUnstake(50e18);
        vm.stopPrank();
    }
}
