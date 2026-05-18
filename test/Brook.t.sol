// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {Brook} from "../src/Brook.sol";
import {Types} from "../src/libraries/Types.sol";

contract BrookTest is Test {
    /// @dev Standard CREATE2 deployer address used across most EVM chains.
    ///      Kept here for documentation — production deploys use this proxy,
    ///      but Foundry's `new Contract{salt: s}(...)` uses the test contract
    ///      itself as the deployer, so we mine against `address(this)` below.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IPoolManager internal poolManager;
    Brook internal brook;

    function setUp() public {
        // 1. Deploy a fresh PoolManager from hookmate bytecode.
        poolManager = IPoolManager(V4PoolManagerDeployer.deploy(address(this)));

        // 2. Compute the flag bitmask matching Brook.getHookPermissions().
        uint160 flags = uint160(
              Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // 3. Mine a salt using `address(this)` as the deployer, because in
        //    Foundry tests `new Contract{salt: s}(...)` deploys via the
        //    test contract — not the canonical CREATE2 proxy.
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(Brook).creationCode,
            abi.encode(address(poolManager))
        );

        // 4. Deploy Brook with the mined salt.
        brook = new Brook{salt: salt}(poolManager);
        require(address(brook) == expected, "BrookTest: deploy mismatch");
    }

    // ---------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------

    function test_deploy_addressEncodesPermissionFlags() public view {
        uint160 expectedFlags = uint160(
              Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // The lowest 14 bits of the hook address must equal the flag bitmask.
        uint160 addressFlags = uint160(address(brook)) & uint160(0x3FFF);
        assertEq(addressFlags, expectedFlags, "address bits do not match flags");
    }

    function test_deploy_brookPointsAtPoolManager() public view {
        assertEq(address(brook.poolManager()), address(poolManager));
    }

    // ---------------------------------------------------------------------
    // Permission flags
    // ---------------------------------------------------------------------

    function test_getHookPermissions_returnsExpectedFlags() public view {
        Hooks.Permissions memory perms = brook.getHookPermissions();

        assertTrue(perms.beforeInitialize, "beforeInitialize should be true");
        assertTrue(perms.afterAddLiquidity, "afterAddLiquidity should be true");
        assertTrue(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be true");
        assertTrue(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be true");
        assertTrue(perms.afterSwap, "afterSwap should be true");
        assertTrue(perms.afterSwapReturnDelta, "afterSwapReturnDelta should be true");

        assertFalse(perms.afterInitialize, "afterInitialize should be false");
        assertFalse(perms.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(perms.beforeSwap, "beforeSwap should be false");
        assertFalse(perms.beforeDonate, "beforeDonate should be false");
        assertFalse(perms.afterDonate, "afterDonate should be false");
        assertFalse(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta should be false");
        assertFalse(perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be false");
        assertFalse(perms.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be false");
    }

    // ---------------------------------------------------------------------
    // State shape sanity checks
    // ---------------------------------------------------------------------

    function test_poolConfig_defaultValuesAreZero() public pure {
        Types.PoolConfig memory cfg;
        assertEq(cfg.epochLength, 0);
        assertEq(cfg.startTime, 0);
        assertEq(cfg.smoothingFee, 0);
        assertEq(cfg.inRangeMultiplier, 0);
    }

    function test_epochState_defaultValuesAreZero() public pure {
        Types.EpochState memory state;
        assertEq(state.buffer, 0);
        assertEq(state.prevBuffer, 0);
        assertEq(state.totalScore, 0);
        assertEq(state.lastUpdateTime, 0);
    }

    function test_lpState_defaultValuesAreZero() public pure {
        Types.LPState memory lp;
        assertEq(lp.liquidity, 0);
        assertEq(lp.tickLower, int24(0));
        assertEq(lp.tickUpper, int24(0));
        assertEq(lp.depositTime, 0);
        assertEq(lp.inRangeTime, 0);
        assertEq(lp.totalTime, 0);
        assertEq(lp.lastTouched, 0);
        assertEq(lp.pendingClaim, 0);
        assertEq(lp.scoreSnapshot, 0);
    }
}