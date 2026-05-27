// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IBrook} from "./interfaces/IBrook.sol";
import {Types} from "./libraries/Types.sol";
import {BrookConstants} from "./libraries/Types.sol";
import {ScoreLib} from "./libraries/ScoreLib.sol";

/// @title Brook
/// @notice A Uniswap v4 hook for predictable, paycheck-style LP yield.
contract Brook is BaseHook, IBrook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    mapping(bytes32 poolId => Types.PoolConfig) internal _config;
    mapping(bytes32 poolId => Types.EpochState) internal _epoch;
    mapping(bytes32 poolId => mapping(bytes32 positionKey => Types.LPState)) internal _positions;
    mapping(bytes32 poolId => Types.PoolConfig) internal _pendingConfig;
    mapping(bytes32 poolId => bool) internal _initialized;
    mapping(bytes32 poolId => mapping(bytes32 positionKey => uint64)) internal _lastClaimTime;
    mapping(bytes32 poolId => Currency) internal _feeCurrency;
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

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        bytes32 poolId = keccak256(abi.encode(key));
        _processSwap(poolId, key, params, swapDelta);
        return (BaseHook.afterSwap.selector, _epoch[poolId].lastSkimAmount);
    }

    // ---------------------------------------------------------------------
    // Swap processing (extracted to avoid stack-too-deep)
    // ---------------------------------------------------------------------

    function _processSwap(
        bytes32 poolId,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta
    ) internal {
        Types.PoolConfig storage cfg   = _config[poolId];
        Types.EpochState storage epoch = _epoch[poolId];
        uint64 now_ = uint64(block.timestamp);

        // 1. Epoch rollover.
        if (
            epoch.lastUpdateTime > 0 &&
            now_ >= epoch.lastUpdateTime + cfg.epochLength
        ) {
            _rolloverEpoch(poolId, epoch);
        }

        // 2. Reset skim amount for this swap.
        epoch.lastSkimAmount = 0;

        // 3. Fee skim.
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
                epoch.buffer         += fee;
                epoch.lastSkimAmount  = int128(fee);

                if (Currency.unwrap(_feeCurrency[poolId]) == address(0)) {
                    _feeCurrency[poolId] = feeCurrency;
                }
            }
        }

        // 4. Record current tick for in-range accumulator.
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        epoch.currentTick = tick;

        // 5. Update timestamp.
        epoch.lastUpdateTime = now_;

        emit FeesSkimmed(poolId, epoch.buffer, now_);
    }

    // ---------------------------------------------------------------------
    // Claim
    // ---------------------------------------------------------------------

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

        _lastClaimTime[poolId][positionKey] = uint64(block.timestamp);
        _feeCurrency[poolId].transfer(recipient, vested);

        emit YieldClaimed(poolId, positionKey, recipient, vested);
    }

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

        if (epoch.totalScore == 0) {
            epoch.totalScore = uint64(lpScore);
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

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

    function _settleTime(
        bytes32 poolId,
        bytes32 positionKey,
        uint64 now_
    ) internal {
        Types.LPState storage lp    = _positions[poolId][positionKey];
        Types.EpochState storage ep = _epoch[poolId];

        if (lp.lastTouched == 0 || now_ <= lp.lastTouched) return;

        uint64 elapsed = now_ - lp.lastTouched;
        lp.totalTime  += elapsed;

        if (
            ep.currentTick >= lp.tickLower &&
            ep.currentTick < lp.tickUpper
        ) {
            lp.inRangeTime += elapsed;
        }

        lp.lastTouched = now_;
    }

    // ---------------------------------------------------------------------
    // View functions
    // ---------------------------------------------------------------------

    function getPoolConfig(bytes32 poolId)
        external view override returns (Types.PoolConfig memory)
    { return _config[poolId]; }

    function getEpochState(bytes32 poolId)
        external view override returns (Types.EpochState memory)
    { return _epoch[poolId]; }

    function getLPState(bytes32 poolId, bytes32 positionKey)
        external view override returns (Types.LPState memory)
    { return _positions[poolId][positionKey]; }

    function isInitialized(bytes32 poolId) external view returns (bool)
    { return _initialized[poolId]; }

    function getPendingConfig(bytes32 poolId)
        external view returns (Types.PoolConfig memory)
    { return _pendingConfig[poolId]; }

    function getLastClaimTime(bytes32 poolId, bytes32 positionKey)
        external view returns (uint64)
    { return _lastClaimTime[poolId][positionKey]; }

    function getFeeCurrency(bytes32 poolId)
        external view returns (Currency)
    { return _feeCurrency[poolId]; }
}