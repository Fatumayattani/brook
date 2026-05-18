// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IBrook} from "./interfaces/IBrook.sol";
import {Types} from "./libraries/Types.sol";

/// @title Brook
/// @notice A Uniswap v4 hook for predictable, paycheck-style LP yield.
/// @dev Captures swap fees into a per-epoch buffer, then streams the previous
///      epoch's buffer to LPs over the next epoch, weighted by useful liquidity.
///      Mechanism logic is built incrementally across PRs #5–#13. This PR
///      establishes the contract shell, permission flags, and state layout.
contract Brook is BaseHook, IBrook {
    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    /// @notice Per-pool immutable configuration.
    /// @dev Set once at beforeInitialize (PR #5). Cannot change after.
    mapping(bytes32 poolId => Types.PoolConfig) internal _config;

    /// @notice Per-pool epoch state. Mutates on every relevant action.
    mapping(bytes32 poolId => Types.EpochState) internal _epoch;

    /// @notice Per-LP-position state, keyed by pool then by position key.
    mapping(bytes32 poolId => mapping(bytes32 positionKey => Types.LPState)) internal _positions;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ---------------------------------------------------------------------
    // Hook permissions
    // ---------------------------------------------------------------------

    /// @notice The permission flags this hook advertises.
    /// @dev The deployed address must encode these flags in its lowest 14 bits.
    ///      Address mining happens in PR #3 via HookMiner.
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:                  true,
            afterInitialize:                   false,
            beforeAddLiquidity:                false,
            afterAddLiquidity:                 true,
            beforeRemoveLiquidity:             true,
            afterRemoveLiquidity:              true,
            beforeSwap:                        false,
            afterSwap:                         true,
            beforeDonate:                      false,
            afterDonate:                       false,
            beforeSwapReturnDelta:             false,
            afterSwapReturnDelta:              true,
            afterAddLiquidityReturnDelta:      false,
            afterRemoveLiquidityReturnDelta:   false
        });
    }

    // ---------------------------------------------------------------------
    // View functions (IBrook)
    // ---------------------------------------------------------------------

    /// @inheritdoc IBrook
    function getPoolConfig(bytes32 poolId)
        external
        view
        override
        returns (Types.PoolConfig memory)
    {
        return _config[poolId];
    }

    /// @inheritdoc IBrook
    function getEpochState(bytes32 poolId)
        external
        view
        override
        returns (Types.EpochState memory)
    {
        return _epoch[poolId];
    }

    /// @inheritdoc IBrook
    function getLPState(bytes32 poolId, bytes32 positionKey)
        external
        view
        override
        returns (Types.LPState memory)
    {
        return _positions[poolId][positionKey];
    }
}