// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from 'forge-std/Script.sol';

interface IPaymentRouter {
  function acceptedTokens(address token) external view returns (bool);
}

contract DiagnoseRouter is Script {
  address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
  address constant ROUTER_1 = 0x8b5D47c862b54a29Fc4eF9f3d8c041C8Ae669750;
  address constant ROUTER_2 = 0x3E9AC70d72F2cF10aD7511faABd3C913337bD101;

  function run() external {
    console.log('Diagnosing Routers...');

    try IPaymentRouter(ROUTER_1).acceptedTokens(USDC) returns (bool accepted) {
      console.log('Router 1 (0x8b5D...) accepted USDC:', accepted);
    } catch Error(string memory reason) {
      console.log('Router 1 failed with reason:', reason);
    } catch (bytes memory lowLevelData) {
      console.log('Router 1 failed with low-level data:');
      console.logBytes(lowLevelData);
    }

    try IPaymentRouter(ROUTER_2).acceptedTokens(USDC) returns (bool accepted) {
      console.log('Router 2 (0x3E9...) accepted USDC:', accepted);
    } catch Error(string memory reason) {
      console.log('Router 2 failed with reason:', reason);
    } catch (bytes memory lowLevelData) {
      console.log('Router 2 failed with low-level data:');
      console.logBytes(lowLevelData);
    }
  }
}
