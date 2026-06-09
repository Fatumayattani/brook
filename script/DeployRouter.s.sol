// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {BrookRouter, IBrookClaim} from "../src/BrookRouter.sol";

contract DeployRouter is Script {
    function run(address brookAddress) external {
        address poolManager = AddressConstants.getPoolManagerAddress(block.chainid);

        vm.startBroadcast();
        BrookRouter router = new BrookRouter(
            IPoolManager(poolManager),
            IBrookClaim(brookAddress)
        );
        vm.stopBroadcast();

        console.log("---");
        console.log("BrookRouter deployed:", address(router));
        console.log("PoolManager:", poolManager);
        console.log("Brook:", brookAddress);
    }
}
