// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IBrook} from "./interfaces/IBrook.sol";
import {Types} from "./libraries/Types.sol";
import {BrookConstants} from "./libraries/Types.sol";

/// @title Brook
/// @notice A Uniswap v4 hook for predictable, paycheck-style LP yield.
/// @dev Captures swap fees into a per-epoch buffer, then streams the previous
///      epoch's buffer to LPs over the next epoch, weighted by useful liquidity.
///
///      Pool creation flow (two steps):
///      1. Call configurePool(poolId, epochLength, smoothingFee, multiplier)
///      2. Call poolManager.initialize(key, sqrtPriceX96)
///         beforeInitialize fires, reads pending config, locks it permanently.
contract Brook is BaseHook, IBrook {

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    /// @notice Per-pool immutable configuration.
    /// @dev Set once at beforeInitialize. Cannot change after.
    mapping(bytes32 poolId => Types.PoolConfig) internal _config;

    /// @notice Per-pool epoch state. Mutates on every relevant action.
    mapping(bytes32 poolId => Types.EpochState) internal _epoch;

    /// @notice Per-LP-position state, keyed by pool then by position key.
    mapping(bytes32 poolId => mapping(bytes32 positionKey => Types.LPState)) internal _positions;

    /// @notice Pending config set by configurePool before pool initialization.
    /// @dev Consumed and deleted by beforeInitialize. Prevents replay.
    mapping(bytes32 poolId => Types.PoolConfig) internal _pendingConfig;

    /// @notice Tracks which pools have been initialized by Brook.
    mapping(bytes32 poolId => bool) internal _initialized;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ---------------------------------------------------------------------
    // Pool configuration
    // ---------------------------------------------------------------------

    /// @notice Set pool parameters before calling poolManager.initialize.
    /// @dev Must be called before initialize. Can only be set once per pool.
    ///      The caller is responsible for ensuring the poolId matches the
    ///      PoolKey they will use to initialize the pool.
    /// @param poolId     keccak256(abi.encode(key)) for the pool being created.
    /// @param epochLength      Duration of one epoch in seconds.
    /// @param smoothingFee     Bps of swap fee diverted to buffer (max 5000).
    /// @param inRangeMultiplier Weight for in-range vs out-of-range time (1-10).
    function configurePool(
        bytes32 poolId,
        uint64 epochLength,
        uint16 smoothingFee,
        uint16 inRangeMultiplier
    ) external {
        // Cannot reconfigure an already-initialized pool.
        if (_initialized[poolId]) revert PoolAlreadyInitialized(poolId);

        // Validate epoch length.
        if (
            epochLength < BrookConstants.MIN_EPOCH_LENGTH ||
            epochLength > BrookConstants.MAX_EPOCH_LENGTH
        ) revert InvalidEpochLength(
            epochLength,
            BrookConstants.MIN_EPOCH_LENGTH,
            BrookConstants.MAX_EPOCH_LENGTH
        );

        // Validate smoothing fee.
        if (smoothingFee > BrookConstants.MAX_SMOOTHING_FEE)
            revert InvalidSmoothingFee(
                smoothingFee,
                BrookConstants.MAX_SMOOTHING_FEE
            );

        // Validate in-range multiplier.
        if (
            inRangeMultiplier < BrookConstants.MIN_IN_RANGE_MULTIPLIER ||
            inRangeMultiplier > BrookConstants.MAX_IN_RANGE_MULTIPLIER
        ) revert InvalidInRangeMultiplier(
            inRangeMultiplier,
            BrookConstants.MIN_IN_RANGE_MULTIPLIER,
            BrookConstants.MAX_IN_RANGE_MULTIPLIER
        );

        _pendingConfig[poolId] = Types.PoolConfig({
            epochLength:       epochLength,
            startTime:         0, // set in beforeInitialize
            smoothingFee:      smoothingFee,
            inRangeMultiplier: inRangeMultiplier
        });
    }

    // ---------------------------------------------------------------------
    // Hook permissions
    // ---------------------------------------------------------------------

    /// @notice The permission flags this hook advertises.
    /// @dev The deployed address must encode these flags in its lowest 14 bits.
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
    // Hook callbacks
    // ---------------------------------------------------------------------

    /// @inheritdoc BaseHook
    /// @dev Reads pending config set by configurePool, locks it permanently,
    ///      and marks the pool as initialized. Reverts if configurePool was
    ///      not called first.
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal override returns (bytes4) {
        bytes32 poolId = keccak256(abi.encode(key));

        // Must have called configurePool first.
        Types.PoolConfig memory pending = _pendingConfig[poolId];
        if (pending.epochLength == 0) revert PoolNotConfigured(poolId);

        // Lock config permanently with the actual start time.
        uint64 startTime = uint64(block.timestamp);
        _config[poolId] = Types.PoolConfig({
            epochLength:       pending.epochLength,
            startTime:         startTime,
            smoothingFee:      pending.smoothingFee,
            inRangeMultiplier: pending.inRangeMultiplier
        });

        // Mark initialized and clean up pending config.
        _initialized[poolId] = true;
        delete _pendingConfig[poolId];

        emit PoolInitialized(
            poolId,
            pending.epochLength,
            pending.smoothingFee,
            pending.inRangeMultiplier,
            startTime
        );

        return BaseHook.beforeInitialize.selector;
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

    /// @notice Returns true if a pool has been initialized with Brook.
    function isInitialized(bytes32 poolId) external view returns (bool) {
        return _initialized[poolId];
    }

    /// @notice Returns the pending config for a pool not yet initialized.
    function getPendingConfig(bytes32 poolId)
        external
        view
        returns (Types.PoolConfig memory)
    {
        return _pendingConfig[poolId];
    }
}