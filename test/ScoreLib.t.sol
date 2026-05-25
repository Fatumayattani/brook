// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ScoreLib} from "../src/libraries/ScoreLib.sol";

/// @dev Wrapper so Foundry can intercept library reverts via vm.expectRevert.
contract ScoreLibWrapper {
    function computeScore(
        uint128 liquidity,
        uint64  inRangeTime,
        uint64  totalTime,
        uint16  multiplier
    ) external pure returns (uint256) {
        return ScoreLib.computeScore(liquidity, inRangeTime, totalTime, multiplier);
    }
}

contract ScoreLibTest is Test {

    uint16 constant MULT = 4;
    ScoreLibWrapper wrapper;

    function setUp() public {
        wrapper = new ScoreLibWrapper();
    }

    // ---------------------------------------------------------------------
    // computeScore — zero cases
    // ---------------------------------------------------------------------

    function test_computeScore_zeroLiquidityReturnsZero() public pure {
        uint256 score = ScoreLib.computeScore(0, 7 days, 7 days, MULT);
        assertEq(score, 0);
    }

    function test_computeScore_zeroTotalTimeReturnsZero() public pure {
        uint256 score = ScoreLib.computeScore(1000e6, 0, 0, MULT);
        assertEq(score, 0);
    }

    function test_computeScore_zeroInRangeTimeReturnsNonZero() public pure {
        uint256 score = ScoreLib.computeScore(1000e6, 0, 7 days, MULT);
        assertGt(score, 0);
    }

    // ---------------------------------------------------------------------
    // computeScore — boundary cases
    // ---------------------------------------------------------------------

    function test_computeScore_fullyInRange() public pure {
        uint128 liquidity = 1000e6;
        uint64 totalTime = uint64(7 days);
        uint256 score = ScoreLib.computeScore(liquidity, totalTime, totalTime, MULT);
        uint256 expected = uint256(liquidity) * totalTime;
        assertEq(score, expected);
    }

    function test_computeScore_fullyOutOfRange() public pure {
        uint128 liquidity = 1000e6;
        uint64 totalTime = uint64(7 days);
        uint256 score = ScoreLib.computeScore(liquidity, 0, totalTime, MULT);
        uint256 expected = uint256(liquidity) * totalTime / MULT;
        assertEq(score, expected);
    }

    function test_computeScore_halfInRange() public pure {
        uint128 liquidity = 1000e6;
        uint64 totalTime = uint64(7 days);
        uint64 inRangeTime = uint64(7 days / 2);
        uint64 outOfRangeTime = totalTime - inRangeTime;

        uint256 score = ScoreLib.computeScore(liquidity, inRangeTime, totalTime, MULT);

        uint256 effectiveTimeScaled = uint256(inRangeTime) * MULT + uint256(outOfRangeTime);
        uint256 expected = uint256(liquidity) * effectiveTimeScaled / MULT;
        assertEq(score, expected);
    }

    function test_computeScore_quarterInRange() public pure {
        uint128 liquidity = 1000e6;
        uint64 totalTime  = uint64(7 days);
        uint64 inRangeTime = uint64(7 days / 4);

        uint256 scorePartial = ScoreLib.computeScore(liquidity, inRangeTime, totalTime, MULT);
        uint256 scoreFull    = ScoreLib.computeScore(liquidity, totalTime,   totalTime, MULT);

        assertGt(scoreFull, scorePartial);
        assertGt(scoreFull, 2 * scorePartial);
    }

    function test_computeScore_multiplierOneEqualizesAllTime() public pure {
        uint128 liquidity = 1000e6;
        uint64 totalTime  = uint64(7 days);

        uint256 scoreFullIn  = ScoreLib.computeScore(liquidity, totalTime, totalTime, 1);
        uint256 scoreFullOut = ScoreLib.computeScore(liquidity, 0,         totalTime, 1);

        assertEq(scoreFullIn, scoreFullOut);
    }

    function test_computeScore_scalesLinearlyWithLiquidity() public pure {
        uint64 totalTime = uint64(7 days);
        uint256 score1x = ScoreLib.computeScore(1000e6, totalTime, totalTime, MULT);
        uint256 score2x = ScoreLib.computeScore(2000e6, totalTime, totalTime, MULT);
        uint256 score5x = ScoreLib.computeScore(5000e6, totalTime, totalTime, MULT);

        assertEq(score2x, score1x * 2);
        assertEq(score5x, score1x * 5);
    }

    function test_computeScore_scalesLinearlyWithTime() public pure {
        uint128 liquidity = 1000e6;
        uint256 score7d  = ScoreLib.computeScore(liquidity, 7 days,  7 days,  MULT);
        uint256 score14d = ScoreLib.computeScore(liquidity, 14 days, 14 days, MULT);

        assertEq(score14d, score7d * 2);
    }

    // ---------------------------------------------------------------------
    // computeScore — reverts (called through wrapper)
    // ---------------------------------------------------------------------

    function test_computeScore_revertsZeroMultiplier() public {
        vm.expectRevert(ScoreLib.InvalidMultiplier.selector);
        wrapper.computeScore(1000e6, 7 days, 7 days, 0);
    }

    function test_computeScore_revertsInRangeExceedsTotalTime() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ScoreLib.InvalidTimeAccounting.selector,
                uint64(8 days),
                uint64(7 days)
            )
        );
        wrapper.computeScore(1000e6, 8 days, 7 days, MULT);
    }

    // ---------------------------------------------------------------------
    // computeShare
    // ---------------------------------------------------------------------

    function test_computeShare_zeroTotalScoreReturnsZero() public pure {
        uint256 share = ScoreLib.computeShare(1000, 0, 1_000_000);
        assertEq(share, 0);
    }

    function test_computeShare_zeroBufferReturnsZero() public pure {
        uint256 share = ScoreLib.computeShare(1000, 5000, 0);
        assertEq(share, 0);
    }

    function test_computeShare_fullScore() public pure {
        uint256 share = ScoreLib.computeShare(1000, 1000, 1_000_000);
        assertEq(share, 1_000_000);
    }

    function test_computeShare_halfScore() public pure {
        uint256 share = ScoreLib.computeShare(500, 1000, 1_000_000);
        assertEq(share, 500_000);
    }

    function test_computeShare_twoEqualLPs() public pure {
        uint256 score  = 1000;
        uint256 total  = 2000;
        uint128 buffer = 1_000_000;

        uint256 share1 = ScoreLib.computeShare(score, total, buffer);
        uint256 share2 = ScoreLib.computeShare(score, total, buffer);

        assertEq(share1, share2);
        assertEq(share1 + share2, buffer);
    }

    function test_computeShare_smallScoreGetsProportion() public pure {
        uint256 share = ScoreLib.computeShare(1, 100, 1_000_000);
        assertEq(share, 10_000);
    }

    // ---------------------------------------------------------------------
    // computeVested
    // ---------------------------------------------------------------------

    function test_computeVested_zeroElapsedReturnsZero() public pure {
        uint256 vested = ScoreLib.computeVested(1_000_000, 0, 7 days);
        assertEq(vested, 0);
    }

    function test_computeVested_fullElapsedReturnsFullShare() public pure {
        uint256 vested = ScoreLib.computeVested(1_000_000, 7 days, 7 days);
        assertEq(vested, 1_000_000);
    }

    function test_computeVested_elapsedExceedsEpochReturnsFull() public pure {
        uint256 vested = ScoreLib.computeVested(1_000_000, 10 days, 7 days);
        assertEq(vested, 1_000_000);
    }

    function test_computeVested_halfElapsedReturnsHalfShare() public pure {
        uint256 vested = ScoreLib.computeVested(1_000_000, uint64(7 days / 2), 7 days);
        assertEq(vested, 500_000);
    }

    function test_computeVested_quarterElapsedReturnsQuarterShare() public pure {
        uint256 vested = ScoreLib.computeVested(1_000_000, uint64(7 days / 4), 7 days);
        assertEq(vested, 250_000);
    }

    function test_computeVested_zeroEpochLengthReturnsZero() public pure {
        uint256 vested = ScoreLib.computeVested(1_000_000, 1 days, 0);
        assertEq(vested, 0);
    }

    function test_computeVested_zeroShareReturnsZero() public pure {
        uint256 vested = ScoreLib.computeVested(0, 3 days, 7 days);
        assertEq(vested, 0);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    function testFuzz_computeScore_neverExceedsMaximum(
        uint128 liquidity,
        uint64  inRangeTime,
        uint64  totalTime,
        uint16  multiplier
    ) public pure {
        multiplier  = uint16(bound(multiplier,  1,    10));
        totalTime   = uint64(bound(totalTime,   1,    90 days));
        inRangeTime = uint64(bound(inRangeTime, 0,    totalTime));
        liquidity   = uint128(bound(liquidity,  0,    type(uint128).max / 1e12));

        uint256 score    = ScoreLib.computeScore(liquidity, inRangeTime, totalTime, multiplier);
        uint256 maxScore = ScoreLib.computeScore(liquidity, totalTime,   totalTime, multiplier);

        assertLe(score, maxScore);
    }

    function testFuzz_computeShare_neverExceedsBuffer(
        uint256 lpScore,
        uint256 totalScore,
        uint128 buffer
    ) public pure {
        if (totalScore == 0) return;
        lpScore = bound(lpScore, 0, totalScore);

        uint256 share = ScoreLib.computeShare(lpScore, totalScore, buffer);
        assertLe(share, uint256(buffer));
    }

    function testFuzz_computeVested_neverExceedsShare(
        uint256 share,
        uint64  elapsed,
        uint64  epochLength
    ) public pure {
        if (epochLength == 0) return;
        elapsed = uint64(bound(elapsed, 0, epochLength));

        uint256 vested = ScoreLib.computeVested(share, elapsed, epochLength);
        assertLe(vested, share);
    }
}