// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title ScoreLib
/// @notice Pure math library for computing an LP's useful liquidity score.
/// @dev The score determines each LP's share of the epoch buffer payout.
///      A higher score means more useful liquidity was provided.
///
///      Formula:
///          score = liquidity × (inRangeTime + outOfRangeTime / multiplier)
///
///      Where outOfRangeTime = totalTime - inRangeTime.
///
///      With multiplier = 4 (default):
///          100% in-range LP → score = liquidity × totalTime
///           25% in-range LP → score = liquidity × 0.4375 × totalTime
///          The in-range LP earns ~2.3x more than the 25% in-range LP.
///
///      Out-of-range LPs still earn something — Brook is not punitive,
///      it rewards commitment proportionally.
library ScoreLib {

    /// @notice Thrown when inRangeTime exceeds totalTime.
    error InvalidTimeAccounting(uint64 inRangeTime, uint64 totalTime);

    /// @notice Thrown when multiplier is zero (would cause division by zero).
    error InvalidMultiplier();

    /// @notice Computes the useful liquidity score for a single LP position.
    /// @param liquidity         The LP's current liquidity amount.
    /// @param inRangeTime       Seconds the position was in-range this epoch.
    /// @param totalTime         Total seconds the position was deposited this epoch.
    /// @param inRangeMultiplier Weight for in-range vs out-of-range time (min 1).
    /// @return score            The LP's score for this epoch.
    function computeScore(
        uint128 liquidity,
        uint64  inRangeTime,
        uint64  totalTime,
        uint16  inRangeMultiplier
    ) internal pure returns (uint256 score) {
        if (inRangeMultiplier == 0) revert InvalidMultiplier();
        if (inRangeTime > totalTime) revert InvalidTimeAccounting(inRangeTime, totalTime);

        if (liquidity == 0 || totalTime == 0) return 0;

        uint64 outOfRangeTime = totalTime - inRangeTime;

        // effectiveTimeScaled = inRangeTime × multiplier + outOfRangeTime
        // score = liquidity × effectiveTimeScaled / multiplier
        uint256 effectiveTimeScaled = uint256(inRangeTime) * inRangeMultiplier
            + uint256(outOfRangeTime);

        score = FullMath.mulDiv(
            uint256(liquidity),
            effectiveTimeScaled,
            inRangeMultiplier
        );
    }

    /// @notice Computes an LP's proportional share of a buffer amount.
    /// @param lpScore     The LP's score for this epoch.
    /// @param totalScore  Sum of all LP scores for this epoch.
    /// @param buffer      Total buffer available for distribution.
    /// @return share      The LP's share of the buffer.
    function computeShare(
        uint256 lpScore,
        uint256 totalScore,
        uint128 buffer
    ) internal pure returns (uint256 share) {
        if (totalScore == 0 || buffer == 0) return 0;
        share = FullMath.mulDiv(uint256(buffer), lpScore, totalScore);
    }

    /// @notice Computes the vested portion of a share given elapsed time.
    /// @dev Yield streams linearly over the epoch length. An LP claiming
    ///      halfway through the epoch receives 50% of their share.
    /// @param share        The LP's total share for this epoch.
    /// @param elapsed      Seconds elapsed since epoch rollover.
    /// @param epochLength  Total length of the epoch in seconds.
    /// @return vested      The currently vested portion of the share.
    function computeVested(
        uint256 share,
        uint64  elapsed,
        uint64  epochLength
    ) internal pure returns (uint256 vested) {
        if (epochLength == 0 || share == 0) return 0;
        if (elapsed >= epochLength) return share;
        vested = FullMath.mulDiv(share, elapsed, epochLength);
    }
}