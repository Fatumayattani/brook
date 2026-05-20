// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title Brook Constants
/// @notice Protocol-wide constants used across Brook contracts.
library BrookConstants {
    /// @notice Minimum epoch length: 1 hour.
    uint64 internal constant MIN_EPOCH_LENGTH = 1 hours;

    /// @notice Maximum epoch length: 90 days.
    uint64 internal constant MAX_EPOCH_LENGTH = 90 days;

    /// @notice Maximum smoothing fee: 50% of swap fees (5000 bps).
    uint16 internal constant MAX_SMOOTHING_FEE = 5000;

    /// @notice Minimum in-range multiplier: 1 (no differentiation).
    uint16 internal constant MIN_IN_RANGE_MULTIPLIER = 1;

    /// @notice Maximum in-range multiplier: 10 (10x for in-range LPs).
    uint16 internal constant MAX_IN_RANGE_MULTIPLIER = 10;
}

/// @title Brook Types
/// @notice Core data structures used by the Brook hook.
/// @dev Grouped in a library for clarity and reuse across Brook.sol,
///      libraries, and tests. None of these structs hold state directly —
///      they describe the shape of state stored in mappings on Brook.sol.
library Types {
    /// @notice Per-pool configuration locked at pool initialization.
    /// @param epochLength      Duration of one epoch in seconds.
    /// @param startTime        Pool init timestamp, anchors epoch boundaries.
    /// @param smoothingFee     Bps of swap fee diverted to the buffer (e.g. 2000 = 20%).
    /// @param inRangeMultiplier Weight applied to in-range vs out-of-range LP time
    ///                          when computing useful liquidity score.
    struct PoolConfig {
        uint64 epochLength;
        uint64 startTime;
        uint16 smoothingFee;
        uint16 inRangeMultiplier;
    }

    /// @notice Per-pool epoch state. Updated on every swap and at rollover.
    /// @param buffer           Fees accumulated this epoch.
    /// @param prevBuffer       Last epoch's buffer, currently streaming to LPs.
    /// @param totalScore       Sum of all LP scores this epoch.
    /// @param lastUpdateTime   Last time epoch state was touched.
    struct EpochState {
        uint128 buffer;
        uint128 prevBuffer;
        uint64  totalScore;
        uint64  lastUpdateTime;
    }

    /// @notice Per-LP-position state. Keyed by position key in a nested mapping.
    /// @param liquidity        Current liquidity provided by this position.
    /// @param tickLower        Lower tick of the position's range.
    /// @param tickUpper        Upper tick of the position's range.
    /// @param depositTime      When this position first deposited.
    /// @param inRangeTime      Accumulated in-range seconds this epoch.
    /// @param totalTime        Accumulated deposit seconds this epoch.
    /// @param lastTouched      Last time this position's state was settled.
    /// @param pendingClaim     Unclaimed payout from previous epoch.
    /// @param scoreSnapshot    Score for the currently-streaming epoch.
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