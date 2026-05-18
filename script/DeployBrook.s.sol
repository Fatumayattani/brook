// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {Brook} from "../src/Brook.sol";

/// @title DeployBrook
/// @notice Mines a CREATE2 salt so the deployed Brook address encodes the
///         correct hook permission flags, then deploys Brook.
/// @dev    Run locally against Anvil:
///             anvil
///             forge script script/DeployBrook.s.sol \
///                 --rpc-url http://localhost:8545 \
///                 --broadcast \
///                 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
///         For a real chain (e.g. Unichain Sepolia, chainId 1301), the script
///         will pick up the canonical PoolManager via AddressConstants.
contract DeployBrook is Script {
    /// @dev Standard CREATE2 deployer address used across most EVM chains.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        // 1. Resolve the PoolManager — either canonical for this chain, or
        //    deploy a fresh one locally if no canonical exists (e.g. Anvil).
        address poolManager = _resolvePoolManager();
        console.log("PoolManager at:", poolManager);

        // 2. Compute the flag bitmask matching Brook.getHookPermissions().
        uint160 flags = uint160(
              Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // 3. Mine a salt that produces an address with those flag bits.
        bytes memory constructorArgs = abi.encode(poolManager);
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(Brook).creationCode,
            constructorArgs
        );
        console.log("Mined address:", expected);
        console.logBytes32(salt);

        // 4. Deploy Brook with the mined salt.
        vm.startBroadcast();
        Brook brook = new Brook{salt: salt}(IPoolManager(poolManager));
        vm.stopBroadcast();

        // 5. Sanity check: deployed address must match the mined address.
        require(address(brook) == expected, "Brook: address mismatch after deploy");
        console.log("Brook deployed at:", address(brook));
    }

    /// @dev If a canonical PoolManager exists for the current chain, return it.
    ///      Otherwise (Anvil / unknown chain), deploy a fresh PoolManager.
    function _resolvePoolManager() internal returns (address) {
        if (_hasCanonicalPoolManager(block.chainid)) {
            return AddressConstants.getPoolManagerAddress(block.chainid);
        }

        // Local / unsupported chain — deploy a fresh PoolManager from hookmate bytecode.
        vm.startBroadcast();
        address pm = V4PoolManagerDeployer.deploy(msg.sender);
        vm.stopBroadcast();
        return pm;
    }

    /// @dev Returns true for chains where hookmate has a canonical PoolManager.
    ///      Mirrors the chainIds in AddressConstants.getPoolManagerAddress.
    function _hasCanonicalPoolManager(uint256 chainId) internal pure returns (bool) {
        return chainId == 1          // Ethereum Mainnet
            || chainId == 10         // Optimism
            || chainId == 56         // BNB Smart Chain
            || chainId == 130        // Unichain
            || chainId == 137        // Polygon
            || chainId == 480        // Worldchain
            || chainId == 1301       // Unichain Sepolia
            || chainId == 1868       // Soneium
            || chainId == 8453       // Base
            || chainId == 42161      // Arbitrum One
            || chainId == 43114      // Avalanche
            || chainId == 57073      // Ink
            || chainId == 81457      // Blast
            || chainId == 7777777;   // Zora
    }
}