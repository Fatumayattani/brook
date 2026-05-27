// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title Brook Constants
library BrookConstants {
    uint64 internal constant MIN_EPOCH_LENGTH       = 1 hours;
    uint64 internal constant MAX_EPOCH_LENGTH       = 90 days;
    uint16 internal constant MAX_SMOOTHING_FEE      = 5000;
    uint16 internal constant MIN_IN_RANGE_MULTIPLIER = 1;
    uint16 internal constant MAX_IN_RANGE_MULTIPLIER = 10;
}

/// @title Brook Types
library Types {

    struct PoolConfig {
        uint64 epochLength;
        uint64 startTime;
        uint16 smoothingFee;
        uint16 inRangeMultiplier;
    }

    struct EpochState {
        uint128 buffer;
        uint128 prevBuffer;
        uint64  totalScore;
        uint64  lastUpdateTime;
        int24   currentTick;
        int128  lastSkimAmount;
    }

    struct LPState {
        uint128 liquidity;
        int24   tickLower;
        int24   tickUpper;
        uint64  depositTime;
        uint64  inRangeTime;
        uint64  totalTime;
        uint64  lastTouched;
        uint64  pendingClaim;
        uint64  scoreSnapshot;
    }
}