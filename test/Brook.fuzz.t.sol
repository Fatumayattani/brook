// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {Brook} from "../src/Brook.sol";
import {IBrook} from "../src/interfaces/IBrook.sol";
import {Types} from "../src/libraries/Types.sol";
import {BrookConstants} from "../src/libraries/Types.sol";
import {ScoreLib} from "../src/libraries/ScoreLib.sol";

/// @dev Minimal router — same as Brook.t.sol TestRouter.
contract FuzzRouter {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct LiquidityParams {
        PoolKey key;
        ModifyLiquidityParams params;
        address payer;
    }

    struct SwapCallParams {
        PoolKey key;
        SwapParams params;
        address payer;
    }

    function modifyLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        address payer
    ) external returns (BalanceDelta delta, BalanceDelta fees) {
        bytes memory data = abi.encode(uint8(0), abi.encode(LiquidityParams(key, params, payer)));
        bytes memory result = manager.unlock(data);
        (delta, fees) = abi.decode(result, (BalanceDelta, BalanceDelta));
    }

    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        address payer
    ) external returns (BalanceDelta delta) {
        bytes memory data = abi.encode(uint8(1), abi.encode(SwapCallParams(key, params, payer)));
        bytes memory result = manager.unlock(data);
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == 0) {
            LiquidityParams memory p = abi.decode(payload, (LiquidityParams));
            (BalanceDelta delta, BalanceDelta fees) = manager.modifyLiquidity(p.key, p.params, "");
            _settle(p.key.currency0, p.payer, delta.amount0());
            _settle(p.key.currency1, p.payer, delta.amount1());
            return abi.encode(delta, fees);
        } else {
            SwapCallParams memory p = abi.decode(payload, (SwapCallParams));
            BalanceDelta delta = manager.swap(p.key, p.params, "");
            _settle(p.key.currency0, p.payer, delta.amount0());
            _settle(p.key.currency1, p.payer, delta.amount1());
            return abi.encode(delta);
        }
    }

    function _settle(Currency currency, address payer, int128 amount) internal {
        if (amount < 0) {
            uint128 owed = uint128(-amount);
            manager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), owed);
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint128(amount));
        }
    }
}

contract BrookFuzzTest is Test {
    IPoolManager internal poolManager;
    Brook internal brook;
    FuzzRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        poolManager = IPoolManager(V4PoolManagerDeployer.deploy(address(this)));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        uint160 flags = uint160(
              Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(Brook).creationCode,
            abi.encode(address(poolManager))
        );

        brook = new Brook{salt: salt}(poolManager);
        require(address(brook) == expected, "BrookFuzzTest: deploy mismatch");

        router = new FuzzRouter(poolManager);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _makePoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(brook))
        });
    }

    function _poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _initPool(
        PoolKey memory key,
        uint64 epochLength,
        uint16 smoothingFee,
        uint16 multiplier
    ) internal {
        bytes32 id = _poolId(key);
        brook.configurePool(id, epochLength, smoothingFee, multiplier);
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function _addLiquidity(PoolKey memory key, int256 amount) internal {
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      -600,
                tickUpper:       600,
                liquidityDelta:  amount,
                salt:            bytes32(0)
            }),
            address(this)
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne) internal {
        router.swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -1000,
                sqrtPriceLimitX96: zeroForOne
                    ? 4295128740
                    : 1461446703485210103287273052203988822378723970341
            }),
            address(this)
        );
    }

    // ---------------------------------------------------------------------
    // Fuzz: configurePool accepts all valid inputs
    // ---------------------------------------------------------------------

    function testFuzz_configurePool_validInputsAlwaysSucceed(
        uint64 epochLength,
        uint16 smoothingFee,
        uint16 multiplier
    ) public {
        epochLength  = uint64(bound(epochLength,  BrookConstants.MIN_EPOCH_LENGTH, BrookConstants.MAX_EPOCH_LENGTH));
        smoothingFee = uint16(bound(smoothingFee, 0,                               BrookConstants.MAX_SMOOTHING_FEE));
        multiplier   = uint16(bound(multiplier,   BrookConstants.MIN_IN_RANGE_MULTIPLIER, BrookConstants.MAX_IN_RANGE_MULTIPLIER));

        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);

        brook.configurePool(id, epochLength, smoothingFee, multiplier);

        Types.PoolConfig memory pending = brook.getPendingConfig(id);
        assertEq(pending.epochLength,       epochLength);
        assertEq(pending.smoothingFee,      smoothingFee);
        assertEq(pending.inRangeMultiplier, multiplier);
    }

    // ---------------------------------------------------------------------
    // Fuzz: buffer only grows mid-epoch
    // ---------------------------------------------------------------------

    function testFuzz_buffer_onlyGrowsMidEpoch(uint8 swapCount) public {
        swapCount = uint8(bound(swapCount, 1, 20));

        PoolKey memory key = _makePoolKey();
        _initPool(key, 7 days, 2000, 4);
        _addLiquidity(key, 1000e6);

        uint128 lastBuffer = 0;

        for (uint8 i = 0; i < swapCount; i++) {
            bool zeroForOne = i % 2 == 0;
            _swap(key, zeroForOne);

            uint128 currentBuffer = brook.getEpochState(_poolId(key)).buffer;
            assertGe(currentBuffer, lastBuffer);
            lastBuffer = currentBuffer;
        }
    }

    // ---------------------------------------------------------------------
    // Fuzz: vested amount never exceeds share
    // ---------------------------------------------------------------------

    function testFuzz_claim_vestedNeverExceedsShare(
        uint64 elapsed,
        uint64 epochLength
    ) public pure{
        epochLength = uint64(bound(epochLength, BrookConstants.MIN_EPOCH_LENGTH, 30 days));
        elapsed     = uint64(bound(elapsed, 0, epochLength));

        uint256 share = 1_000_000;
        uint256 vested = ScoreLib.computeVested(share, elapsed, epochLength);

        assertLe(vested, share);
    }

    // ---------------------------------------------------------------------
    // Fuzz: score never exceeds maximum
    // ---------------------------------------------------------------------

    function testFuzz_score_neverExceedsMaximum(
        uint128 liquidity,
        uint64  inRangeTime,
        uint64  totalTime,
        uint16  multiplier
    ) public pure {
        multiplier  = uint16(bound(multiplier,  1,  10));
        totalTime   = uint64(bound(totalTime,   1,  90 days));
        inRangeTime = uint64(bound(inRangeTime, 0,  totalTime));
        liquidity   = uint128(bound(liquidity,  0,  type(uint128).max / 1e12));

        uint256 score    = ScoreLib.computeScore(liquidity, inRangeTime, totalTime, multiplier);
        uint256 maxScore = ScoreLib.computeScore(liquidity, totalTime,   totalTime, multiplier);

        assertLe(score, maxScore);
    }

    // ---------------------------------------------------------------------
    // Fuzz: epoch rollover preserves buffer value
    // ---------------------------------------------------------------------

    function testFuzz_rollover_preservesBufferValue(uint8 swapCount) public {
        swapCount = uint8(bound(swapCount, 1, 10));

        PoolKey memory key = _makePoolKey();
        _initPool(key, 7 days, 2000, 4);
        _addLiquidity(key, 1000e6);

        for (uint8 i = 0; i < swapCount; i++) {
            _swap(key, i % 2 == 0);
        }

        uint128 bufferBeforeRollover = brook.getEpochState(_poolId(key)).buffer;

        vm.warp(block.timestamp + 7 days + 1);
        _swap(key, true);

        Types.EpochState memory state = brook.getEpochState(_poolId(key));
        assertEq(state.prevBuffer, bufferBeforeRollover);
    }

    // ---------------------------------------------------------------------
    // Fuzz: computePositionKey always unique for different inputs
    // ---------------------------------------------------------------------

    function testFuzz_positionKey_uniquePerSender(
        address sender1,
        address sender2
    ) public view {
        vm.assume(sender1 != sender2);

        bytes32 key1 = brook.computePositionKey(sender1, -120, 120, bytes32(0));
        bytes32 key2 = brook.computePositionKey(sender2, -120, 120, bytes32(0));

        assertTrue(key1 != key2);
    }

    function testFuzz_positionKey_uniquePerRange(
        int24 tickLower1,
        int24 tickUpper1,
        int24 tickLower2,
        int24 tickUpper2
    ) public view {
        vm.assume(tickLower1 != tickLower2 || tickUpper1 != tickUpper2);
        vm.assume(tickLower1 < tickUpper1);
        vm.assume(tickLower2 < tickUpper2);

        bytes32 key1 = brook.computePositionKey(address(this), tickLower1, tickUpper1, bytes32(0));
        bytes32 key2 = brook.computePositionKey(address(this), tickLower2, tickUpper2, bytes32(0));

        assertTrue(key1 != key2);
    }
}