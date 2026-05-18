// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Types} from "../libraries/Types.sol";

/// @title IBrook
/// @notice Public interface for the Brook hook.
/// @dev This interface grows through PRs #5–#13 as state-mutating functions
///      and events are added. For now it exposes only view functions that
///      let external callers (tests, frontend, integrators) read state.
interface IBrook {
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