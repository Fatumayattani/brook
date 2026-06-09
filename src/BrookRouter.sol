// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @dev Minimal interface for the one Brook function the router calls.
interface IBrookClaim {
    function claim(bytes32 poolId, bytes32 positionKey, address recipient) external;
}

/// @title BrookRouter
/// @notice Periphery router that lets any EOA provide liquidity, swap, and claim
///         Brook yield directly — without needing to implement the v4 unlock
///         callback themselves.
/// @dev    The key trick: each user's address is encoded into the position `salt`.
///         Brook derives positionKey = keccak256(abi.encode(sender, tickLower,
///         tickUpper, salt)). Since this router is always `sender`, the salt is
///         what makes each user's position unique. On claim, the router recomputes
///         the user's key and routes yield to the user via Brook's `recipient` arg.
///
///         Brook itself is unchanged. This router is standard v4 periphery.
contract BrookRouter {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    IBrookClaim public immutable brook;

    // Full-range ticks (rounded to tickSpacing 60). One position per user keeps
    // the claim unambiguous.
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER =  887220;

    error NotPoolManager();
    error LiquidityTooLow();

    enum Action { ADD_LIQUIDITY, SWAP }

    struct AddLiquidityData {
        PoolKey key;
        uint256 liquidity;
        address user;
    }

    struct SwapData {
        PoolKey key;
        bool    zeroForOne;
        int256  amountSpecified;
        address user;
    }

    constructor(IPoolManager _poolManager, IBrookClaim _brook) {
        poolManager = _poolManager;
        brook       = _brook;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @notice Encode a user's address into a bytes32 salt.
    function saltFor(address user) public pure returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }

    /// @notice Compute the Brook positionKey for a given user under this router.
    function positionKeyFor(address user) external view returns (bytes32) {
        return keccak256(abi.encode(
            address(this),
            TICK_LOWER,
            TICK_UPPER,
            saltFor(user)
        ));
    }

    // ---------------------------------------------------------------------
    // User-facing entry points
    // ---------------------------------------------------------------------

    /// @notice Add full-range liquidity to a Brook pool on behalf of msg.sender.
    /// @dev    Pulls both tokens from the user; user must approve this router first.
    function addLiquidity(PoolKey calldata key, uint256 liquidity) external {
        if (liquidity == 0) revert LiquidityTooLow();
        poolManager.unlock(
            abi.encode(Action.ADD_LIQUIDITY, abi.encode(AddLiquidityData({
                key:       key,
                liquidity: liquidity,
                user:      msg.sender
            })))
        );
    }

    /// @notice Swap through a Brook pool on behalf of msg.sender.
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified
    ) external {
        poolManager.unlock(
            abi.encode(Action.SWAP, abi.encode(SwapData({
                key:             key,
                zeroForOne:      zeroForOne,
                amountSpecified: amountSpecified,
                user:            msg.sender
            })))
        );
    }

    /// @notice Claim vested Brook yield for msg.sender.
    /// @dev    Router recomputes the caller's positionKey and routes yield to them.
    function claim(PoolKey calldata key) external {
        bytes32 poolId = keccak256(abi.encode(key));
        bytes32 positionKey = keccak256(abi.encode(
            address(this),
            TICK_LOWER,
            TICK_UPPER,
            saltFor(msg.sender)
        ));
        brook.claim(poolId, positionKey, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Unlock callback
    // ---------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));

        if (action == Action.ADD_LIQUIDITY) {
            _addLiquidity(abi.decode(payload, (AddLiquidityData)));
        } else {
            _swap(abi.decode(payload, (SwapData)));
        }
        return "";
    }

    function _addLiquidity(AddLiquidityData memory d) internal {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower:      TICK_LOWER,
                tickUpper:      TICK_UPPER,
                liquidityDelta: int256(d.liquidity),
                salt:           saltFor(d.user)
            }),
            ""
        );
        _settle(d.key.currency0, d.user, delta.amount0());
        _settle(d.key.currency1, d.user, delta.amount1());
    }

    function _swap(SwapData memory d) internal {
        BalanceDelta delta = poolManager.swap(
            d.key,
            SwapParams({
                zeroForOne:        d.zeroForOne,
                amountSpecified:   d.amountSpecified,
                sqrtPriceLimitX96: d.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settle(d.key.currency0, d.user, delta.amount0());
        _settle(d.key.currency1, d.user, delta.amount1());
    }

    /// @dev Negative delta = router owes the pool (pull from user and pay in).
    ///      Positive delta = pool owes the router (take and forward to user).
    function _settle(Currency currency, address user, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).transferFrom(user, address(poolManager), owed);
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, user, uint256(uint128(amount)));
        }
    }
}
