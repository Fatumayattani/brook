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

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when a pool is successfully initialized with Brook.
    event PoolInitialized(
        bytes32 indexed poolId,
        uint64 epochLength,
        uint16 smoothingFee,
        uint16 inRangeMultiplier,
        uint64 startTime
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