// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Types} from "../libraries/Types.sol";

/// @title IBrook
/// @notice Public interface for the Brook hook.
interface IBrook {

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Thrown when epochLength is outside the allowed range.
    error InvalidEpochLength(uint64 provided, uint64 min, uint64 max);

    /// @notice Thrown when smoothingFee exceeds the maximum allowed bps.
    error InvalidSmoothingFee(uint16 provided, uint16 max);

    /// @notice Thrown when inRangeMultiplier is outside the allowed range.
    error InvalidInRangeMultiplier(uint16 provided, uint16 min, uint16 max);

    /// @notice Thrown when beforeInitialize fires but configurePool was not called first.
    error PoolNotConfigured(bytes32 poolId);

    /// @notice Thrown when configurePool is called on an already initialized pool.
    error PoolAlreadyInitialized(bytes32 poolId);

    /// @notice Thrown when claim is called before any epoch has rolled over.
    error EpochNotYetComplete(bytes32 poolId);

    /// @notice Thrown when an LP has nothing to claim.
    error NothingToClaim(bytes32 poolId, bytes32 positionKey);

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when a pool is successfully initialized with Brook.
    event PoolInitialized(
        bytes32 indexed poolId,
        uint64  epochLength,
        uint16  smoothingFee,
        uint16  inRangeMultiplier,
        uint64  startTime
    );

    /// @notice Emitted when an LP deposits liquidity into a Brook pool.
    event LPDeposited(
        bytes32 indexed poolId,
        bytes32 indexed positionKey,
        address indexed sender,
        uint128 liquidity
    );

    /// @notice Emitted when an LP withdraws liquidity from a Brook pool.
    event LPWithdrawn(
        bytes32 indexed poolId,
        bytes32 indexed positionKey,
        address indexed sender,
        uint128 remainingLiquidity
    );

    /// @notice Emitted when fees are skimmed into the epoch buffer after a swap.
    event FeesSkimmed(
        bytes32 indexed poolId,
        uint128 bufferTotal,
        uint64  timestamp
    );

    /// @notice Emitted when an epoch rolls over.
    event EpochRolled(
        bytes32 indexed poolId,
        uint128 prevBuffer,
        uint64  timestamp
    );

    /// @notice Emitted when an LP successfully claims yield.
    event YieldClaimed(
        bytes32 indexed poolId,
        bytes32 indexed positionKey,
        address indexed recipient,
        uint256 amount
    );

    // ---------------------------------------------------------------------
    // View functions
    // ---------------------------------------------------------------------

    /// @notice Returns the config for a given pool.
    function getPoolConfig(bytes32 poolId)
        external
        view
        returns (Types.PoolConfig memory);

    /// @notice Returns the epoch state for a given pool.
    function getEpochState(bytes32 poolId)
        external
        view
        returns (Types.EpochState memory);

    /// @notice Returns the state for a given LP position.
    function getLPState(bytes32 poolId, bytes32 positionKey)
        external
        view
        returns (Types.LPState memory);
}