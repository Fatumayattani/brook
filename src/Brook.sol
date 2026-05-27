// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {IBrook} from "./interfaces/IBrook.sol";
import {Types} from "./libraries/Types.sol";
import {BrookConstants} from "./libraries/Types.sol";
import {ScoreLib} from "./libraries/ScoreLib.sol";

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
    using CurrencyLibrary for Currency;

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    /// @notice Per-pool immutable configuration.
    mapping(bytes32 poolId => Types.PoolConfig) internal _config;

    /// @notice Per-pool epoch state.
    mapping(bytes32 poolId => Types.EpochState) internal _epoch;

    /// @notice Per-LP-position state.
    mapping(bytes32 poolId => mapping(bytes32 positionKey => Types.LPState)) internal _positions;

    /// @notice Pending config set by configurePool before pool initialization.
    mapping(bytes32 poolId => Types.PoolConfig) internal _pendingConfig;

    /// @notice Tracks which pools have been initialized by Brook.
    mapping(bytes32 poolId => bool) internal _initialized;

    /// @notice Last claim timestamp per LP position.
    mapping(bytes32 poolId => mapping(bytes32 positionKey => uint64)) internal _lastClaimTime;

    /// @notice Fee currency per pool, set on first swap, used for payouts.
    mapping(bytes32 poolId => Currency) internal _feeCurrency;

    /// @notice Reentrancy guard flag.
    bool internal _locked;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier nonReentrant() {
        require(!_locked, "Brook: reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ---------------------------------------------------------------------
    // Pool configuration
    // ---------------------------------------------------------------------

    /// @notice Set pool parameters before calling poolManager.initialize.
    /// @dev Must be called before initialize. Can only be set once per pool.
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
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 poolId      = keccak256(abi.encode(key));
        bytes32 positionKey = _derivePositionKey(sender, params);

        Types.LPState storage lp = _positions[poolId][positionKey];
        uint64 now_ = uint64(block.timestamp);

        if (lp.depositTime == 0) {
            lp.tickLower   = params.tickLower;
            lp.tickUpper   = params.tickUpper;
            lp.depositTime = now_;
            lp.lastTouched = now_;
            lp.liquidity   = uint128(uint256(int256(params.liquidityDelta)));
        } else {
            _settleTime(poolId, positionKey, now_);
            lp.liquidity  += uint128(uint256(int256(params.liquidityDelta)));
            lp.lastTouched = now_;
        }

        emit LPDeposited(poolId, positionKey, sender, lp.liquidity);

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @inheritdoc BaseHook
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        bytes32 poolId      = keccak256(abi.encode(key));
        bytes32 positionKey = _derivePositionKey(sender, params);
        _settleTime(poolId, positionKey, uint64(block.timestamp));
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 poolId      = keccak256(abi.encode(key));
        bytes32 positionKey = _derivePositionKey(sender, params);

        Types.LPState storage lp = _positions[poolId][positionKey];
        uint128 removed = uint128(uint256(int256(-params.liquidityDelta)));

        if (removed >= lp.liquidity) {
            lp.liquidity   = 0;
            lp.lastTouched = uint64(block.timestamp);
        } else {
            lp.liquidity  -= removed;
            lp.lastTouched = uint64(block.timestamp);
        }

        emit LPWithdrawn(poolId, positionKey, sender, lp.liquidity);

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @inheritdoc BaseHook
    /// @dev Three things happen here in order:
    ///      1. Check and trigger epoch rollover if enough time has passed.
    ///      2. Skim smoothing fee from swap output into the epoch buffer.
    ///      3. Update epoch lastUpdateTime.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        bytes32 poolId = keccak256(abi.encode(key));
        Types.PoolConfig storage cfg   = _config[poolId];
        Types.EpochState storage epoch = _epoch[poolId];

        // 1. Check and trigger epoch rollover.
        uint64 now_ = uint64(block.timestamp);
        if (
            epoch.lastUpdateTime > 0 &&
            now_ >= epoch.lastUpdateTime + cfg.epochLength
        ) {
            _rolloverEpoch(poolId, epoch);
        }

        // 2. Skim smoothing fee from swap output.
        int128 feeSkimAmount = 0;
        Currency feeCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        int128 outputAmount  = params.zeroForOne
            ? swapDelta.amount1()
            : swapDelta.amount0();

        if (outputAmount > 0) {
            uint128 fee = uint128(
                uint256(uint128(outputAmount)) * cfg.smoothingFee / 10000
            );
            if (fee > 0) {
                poolManager.take(feeCurrency, address(this), fee);
                epoch.buffer += fee;
                feeSkimAmount = int128(fee);

                // Record fee currency for this pool on first swap.
                if (Currency.unwrap(_feeCurrency[poolId]) == address(0)) {
                    _feeCurrency[poolId] = feeCurrency;
                }
            }
        }

        // 3. Update last interaction timestamp.
        epoch.lastUpdateTime = now_;

        emit FeesSkimmed(poolId, epoch.buffer, now_);

        return (BaseHook.afterSwap.selector, feeSkimAmount);
    }

    // ---------------------------------------------------------------------
    // Claim
    // ---------------------------------------------------------------------

    /// @notice Claims vested yield from the previous epoch's buffer.
    /// @dev Score is computed lazily at claim time using accumulated time data.
    ///      Yield streams linearly over the epoch length.
    /// @param poolId      keccak256(abi.encode(key)) for the pool.
    /// @param positionKey keccak256(abi.encode(owner, tickLower, tickUpper, salt)).
    /// @param recipient   Address to send the claimed yield to.
    function claim(
        bytes32 poolId,
        bytes32 positionKey,
        address recipient
    ) external nonReentrant {
        if (!_initialized[poolId]) revert PoolNotConfigured(poolId);

        Types.EpochState storage epoch = _epoch[poolId];

        if (epoch.prevBuffer == 0) revert EpochNotYetComplete(poolId);

        Types.LPState storage lp = _positions[poolId][positionKey];

        if (lp.totalTime == 0 && lp.liquidity == 0)
            revert NothingToClaim(poolId, positionKey);

        _settleTime(poolId, positionKey, uint64(block.timestamp));

        uint256 vested = _computeVested(poolId, positionKey);

        if (vested == 0) revert NothingToClaim(poolId, positionKey);

        // Update state before transfer (checks-effects-interactions).
        _lastClaimTime[poolId][positionKey] = uint64(block.timestamp);

        // Transfer yield to recipient.
        _feeCurrency[poolId].transfer(recipient, vested);

        emit YieldClaimed(poolId, positionKey, recipient, vested);
    }

    /// @dev Computes the vested yield for a position.
    ///      Extracted to avoid stack-too-deep in claim().
    function _computeVested(
        bytes32 poolId,
        bytes32 positionKey
    ) internal returns (uint256 vested) {
        Types.EpochState storage epoch = _epoch[poolId];
        Types.PoolConfig storage cfg   = _config[poolId];
        Types.LPState storage lp       = _positions[poolId][positionKey];

        uint256 lpScore = ScoreLib.computeScore(
            lp.liquidity,
            lp.inRangeTime,
            lp.totalTime,
            cfg.inRangeMultiplier
        );

        if (lpScore == 0) return 0;

        uint256 effectiveTotalScore = epoch.totalScore == 0
            ? lpScore
            : epoch.totalScore;

        uint256 share = ScoreLib.computeShare(
            lpScore,
            effectiveTotalScore,
            epoch.prevBuffer
        );

        if (share == 0) return 0;

        uint64 lastClaim    = _lastClaimTime[poolId][positionKey];
        uint64 rolloverTime = epoch.lastUpdateTime;
        uint64 claimFrom    = lastClaim > rolloverTime ? lastClaim : rolloverTime;
        uint64 elapsed      = uint64(block.timestamp) - claimFrom;

        vested = ScoreLib.computeVested(share, elapsed, cfg.epochLength);

        // Update totalScore on first claim of this epoch.
        if (epoch.totalScore == 0) {
            epoch.totalScore = uint64(lpScore);
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Rolls the current buffer into prevBuffer and starts a fresh epoch.
    function _rolloverEpoch(
        bytes32 poolId,
        Types.EpochState storage epoch
    ) internal {
        uint128 prevBuffer   = epoch.buffer;
        epoch.prevBuffer     = prevBuffer;
        epoch.buffer         = 0;
        epoch.totalScore     = 0;
        epoch.lastUpdateTime = uint64(block.timestamp);

        emit EpochRolled(poolId, prevBuffer, uint64(block.timestamp));
    }

    /// @dev Derives a unique position key from sender address and tick range.
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
    // View functions
    // ---------------------------------------------------------------------

    /// @inheritdoc IBrook
    function getPoolConfig(bytes32 poolId)
        external view override returns (Types.PoolConfig memory)
    {
        return _config[poolId];
    }

    /// @inheritdoc IBrook
    function getEpochState(bytes32 poolId)
        external view override returns (Types.EpochState memory)
    {
        return _epoch[poolId];
    }

    /// @inheritdoc IBrook
    function getLPState(bytes32 poolId, bytes32 positionKey)
        external view override returns (Types.LPState memory)
    {
        return _positions[poolId][positionKey];
    }

    /// @notice Returns true if a pool has been initialized with Brook.
    function isInitialized(bytes32 poolId) external view returns (bool) {
        return _initialized[poolId];
    }

    /// @notice Returns the pending config for a pool not yet initialized.
    function getPendingConfig(bytes32 poolId)
        external view returns (Types.PoolConfig memory)
    {
        return _pendingConfig[poolId];
    }

    /// @notice Returns the last claim timestamp for a position.
    function getLastClaimTime(bytes32 poolId, bytes32 positionKey)
        external view returns (uint64)
    {
        return _lastClaimTime[poolId][positionKey];
    }

    /// @notice Returns the fee currency for a pool.
    function getFeeCurrency(bytes32 poolId)
        external view returns (Currency)
    {
        return _feeCurrency[poolId];
    }
}