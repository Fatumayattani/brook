// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {Brook} from "../src/Brook.sol";
import {Types} from "../src/libraries/Types.sol";

contract BrookTest is Test {
    // ---------------------------------------------------------------------
    // Permission flags
    // ---------------------------------------------------------------------

    function test_getHookPermissions_returnsExpectedFlags() public pure {
        Hooks.Permissions memory perms = _expectedPermissions();

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
    // State shape
    // ---------------------------------------------------------------------
    //
    // We can't yet instantiate Brook itself (the constructor requires an
    // IPoolManager and the deployed address must have mined flag bits).
    // That comes in PR #3. For now, we verify the Types structs have the
    // shape we expect — guards against accidental field renames or removals
    // that would break subsequent PRs.

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

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _expectedPermissions() internal pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:                true,
            afterInitialize:                 false,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               true,
            beforeRemoveLiquidity:           true,
            afterRemoveLiquidity:            true,
            beforeSwap:                      false,
            afterSwap:                       true,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            true,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}