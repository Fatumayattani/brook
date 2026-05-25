// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

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
    /// @param poolId            keccak256(abi.encode(key)) for the pool.
    /// @param epochLength       Duration of one epoch in seconds.
    /// @param smoothingFee      Bps of swap fee diverted to buffer (max 5000).
    /// @param inRangeMultiplier Weight for in-range vs out-of-range time (1-10).
    function configurePool(
        bytes32 poolId,
        uint64 epochLength,
        uint16 smoothingFee,
        uint16 inRangeMultiplier
    ) external {
        if (_initialized[poolId]) revert PoolAlreadyInitialized(poolId);

        if (
            epochLength < BrookConstants.MIN_EPOCH_LENGTH ||
            epochLength > BrookConstants.MAX_EPOCH_LENGTH
        ) revert InvalidEpochLength(
            epochLength,
            BrookConstants.MIN_EPOCH_LENGTH,
            BrookConstants.MAX_EPOCH_LENGTH
        );

        if (smoothingFee > BrookConstants.MAX_SMOOTHING_FEE)
            revert InvalidSmoothingFee(
                smoothingFee,
                BrookConstants.MAX_SMOOTHING_FEE
            );

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
            startTime:         0,
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
    ///      and marks the pool as initialized.
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal override returns (bytes4) {
        bytes32 poolId = keccak256(abi.encode(key));

        Types.PoolConfig memory pending = _pendingConfig[poolId];
        if (pending.epochLength == 0) revert PoolNotConfigured(poolId);

        uint64 startTime = uint64(block.timestamp);
        _config[poolId] = Types.PoolConfig({
            epochLength:       pending.epochLength,
            startTime:         startTime,
            smoothingFee:      pending.smoothingFee,
            inRangeMultiplier: pending.inRangeMultiplier
        });

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

    /// @inheritdoc BaseHook
    /// @dev Tracks LP entry when liquidity is added to a Brook pool.
    ///      For new positions, initializes LPState with current timestamp.
    ///      For existing positions, settles the current score at the old
    ///      liquidity level before updating to the new amount.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 poolId     = keccak256(abi.encode(key));
        bytes32 positionKey = _derivePositionKey(sender, params);

        Types.LPState storage lp = _positions[poolId][positionKey];
        uint64 now_ = uint64(block.timestamp);

        if (lp.depositTime == 0) {
            // New position — initialize state.
            lp.tickLower   = params.tickLower;
            lp.tickUpper   = params.tickUpper;
            lp.depositTime = now_;
            lp.lastTouched = now_;
            lp.liquidity   = uint128(uint256(
                lp.liquidity + uint128(uint256(int256(params.liquidityDelta)))
            ));
        } else {
            // Existing position — settle score at old liquidity, then update.
            _settleTime(poolId, positionKey, now_);
            lp.liquidity = uint128(uint256(
                lp.liquidity + uint128(uint256(int256(params.liquidityDelta)))
            ));
            lp.lastTouched = now_;
        }

        emit LPDeposited(poolId, positionKey, sender, lp.liquidity);

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Derives a unique position key from sender address and tick range.
    ///      Mirrors the v4 convention: keccak256(owner, tickLower, tickUpper, salt).
    function _derivePositionKey(
        address owner,
        ModifyLiquidityParams calldata params
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            owner,
            params.tickLower,
            params.tickUpper,
            params.salt
        ));
    }

    /// @dev Lazily updates totalTime for a position up to the current timestamp.
    ///      In-range tracking is added in PR #8 (lazy accumulator).
    ///      For now we only accumulate totalTime.
    function _settleTime(
        bytes32 poolId,
        bytes32 positionKey,
        uint64 now_
    ) internal {
        Types.LPState storage lp = _positions[poolId][positionKey];
        if (lp.lastTouched == 0 || now_ <= lp.lastTouched) return;

        uint64 elapsed = now_ - lp.lastTouched;
        lp.totalTime  += elapsed;
        lp.lastTouched = now_;
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