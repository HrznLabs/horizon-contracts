// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "src/token/sHRZNVault.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockHRZN is ERC20 {
    constructor() ERC20("Mock HRZN", "HRZN") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract sHRZNVaultPoC is Test {
    MockHRZN hrzn;
    MockUSDC usdc;
    sHRZNVault vault;
    address alice = address(0x1);
    address admin = address(0x2);

    function setUp() public {
        hrzn = new MockHRZN();
        usdc = new MockUSDC();
        vault = new sHRZNVault(address(hrzn), address(usdc), admin);

        hrzn.mint(alice, 1000 ether);

        vm.startPrank(alice);
        hrzn.approve(address(vault), 1000 ether);
        vault.deposit(1000 ether, alice);
        vm.stopPrank();
    }

    function testRequestUnstakeReverts() public {
        vm.startPrank(alice);

        // This will revert because it calls _transfer which calls _update
        // where it sets unstakeRequests[alice] before the _transfer.
        // During _transfer, it checks unstakeRequests[from].shares == 0,
        // but it is already > 0!
        vault.requestUnstake(500 ether);
        vm.stopPrank();
    }
}
