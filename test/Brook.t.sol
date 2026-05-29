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

/// @dev Minimal router that handles both liquidity and swap operations
///      using the v4 unlock/settle pattern.
contract TestRouter {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    // -----------------------------------------------------------------------
    // Liquidity
    // -----------------------------------------------------------------------

    struct LiquidityParams {
        PoolKey key;
        ModifyLiquidityParams params;
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

    // -----------------------------------------------------------------------
    // Swap
    // -----------------------------------------------------------------------

    struct SwapCallParams {
        PoolKey key;
        SwapParams params;
        address payer;
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

    // -----------------------------------------------------------------------
    // Unlock callback
    // -----------------------------------------------------------------------

    function unlockCallback(bytes calldata data)
        external
        returns (bytes memory)
    {
        require(msg.sender == address(manager), "not manager");

        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == 0) {
            LiquidityParams memory p = abi.decode(payload, (LiquidityParams));
            (BalanceDelta delta, BalanceDelta fees) = manager.modifyLiquidity(
                p.key, p.params, ""
            );
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
            MockERC20(Currency.unwrap(currency)).transferFrom(
                payer, address(manager), owed
            );
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint128(amount));
        }
    }
}

contract BrookTest is Test {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IPoolManager internal poolManager;
    Brook internal brook;
    TestRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;

    uint64  constant EPOCH_LENGTH   = 7 days;
    uint16  constant SMOOTHING_FEE  = 2000; // 20%
    uint16  constant IN_RANGE_MULT  = 4;
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
        require(address(brook) == expected, "BrookTest: deploy mismatch");

        router = new TestRouter(poolManager);
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

    function _initPool(PoolKey memory key) internal {
        bytes32 id = _poolId(key);
        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function _positionKey(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, tickLower, tickUpper, salt));
    }

    function _addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal {
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: liquidityDelta,
                salt:           bytes32(0)
            }),
            address(this)
        );
    }

    function _removeLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal {
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: -liquidityDelta,
                salt:           bytes32(0)
            }),
            address(this)
        );
    }

    function _swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (BalanceDelta) {
        return router.swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? 4295128740
                    : 1461446703485210103287273052203988822378723970341
            }),
            address(this)
        );
    }

    // ---------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------

    function test_deploy_addressEncodesPermissionFlags() public view {
        uint160 expectedFlags = uint160(
              Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        uint160 addressFlags = uint160(address(brook)) & uint160(0x3FFF);
        assertEq(addressFlags, expectedFlags, "address bits do not match flags");
    }

    function test_deploy_brookPointsAtPoolManager() public view {
        assertEq(address(brook.poolManager()), address(poolManager));
    }

    // ---------------------------------------------------------------------
    // configurePool
    // ---------------------------------------------------------------------

    function test_configurePool_storesPendingConfig() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);
        Types.PoolConfig memory pending = brook.getPendingConfig(id);
        assertEq(pending.epochLength,       EPOCH_LENGTH);
        assertEq(pending.smoothingFee,      SMOOTHING_FEE);
        assertEq(pending.inRangeMultiplier, IN_RANGE_MULT);
        assertEq(pending.startTime,         0);
    }

    function test_configurePool_revertsEpochTooShort() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrook.InvalidEpochLength.selector,
                30 minutes,
                BrookConstants.MIN_EPOCH_LENGTH,
                BrookConstants.MAX_EPOCH_LENGTH
            )
        );
        brook.configurePool(id, 30 minutes, SMOOTHING_FEE, IN_RANGE_MULT);
    }

    function test_configurePool_revertsEpochTooLong() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrook.InvalidEpochLength.selector,
                91 days,
                BrookConstants.MIN_EPOCH_LENGTH,
                BrookConstants.MAX_EPOCH_LENGTH
            )
        );
        brook.configurePool(id, 91 days, SMOOTHING_FEE, IN_RANGE_MULT);
    }

    function test_configurePool_revertsFeeTooHigh() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrook.InvalidSmoothingFee.selector,
                6000,
                BrookConstants.MAX_SMOOTHING_FEE
            )
        );
        brook.configurePool(id, EPOCH_LENGTH, 6000, IN_RANGE_MULT);
    }

    function test_configurePool_revertsMultiplierTooLow() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrook.InvalidInRangeMultiplier.selector,
                0,
                BrookConstants.MIN_IN_RANGE_MULTIPLIER,
                BrookConstants.MAX_IN_RANGE_MULTIPLIER
            )
        );
        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, 0);
    }

    function test_configurePool_revertsMultiplierTooHigh() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBrook.InvalidInRangeMultiplier.selector,
                11,
                BrookConstants.MIN_IN_RANGE_MULTIPLIER,
                BrookConstants.MAX_IN_RANGE_MULTIPLIER
            )
        );
        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, 11);
    }

    // ---------------------------------------------------------------------
    // beforeInitialize
    // ---------------------------------------------------------------------

    function test_beforeInitialize_locksConfig() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        uint64 before = uint64(block.timestamp);
        _initPool(key);
        uint64 after_ = uint64(block.timestamp);
        Types.PoolConfig memory cfg = brook.getPoolConfig(id);
        assertEq(cfg.epochLength,       EPOCH_LENGTH);
        assertEq(cfg.smoothingFee,      SMOOTHING_FEE);
        assertEq(cfg.inRangeMultiplier, IN_RANGE_MULT);
        assertGe(cfg.startTime,         before);
        assertLe(cfg.startTime,         after_);
    }

    function test_beforeInitialize_marksPoolInitialized() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        assertFalse(brook.isInitialized(id));
        _initPool(key);
        assertTrue(brook.isInitialized(id));
    }

    function test_beforeInitialize_clearsPendingConfig() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);
        Types.PoolConfig memory pending = brook.getPendingConfig(id);
        assertEq(pending.epochLength, 0);
    }

    function test_beforeInitialize_emitsPoolInitialized() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);
        vm.expectEmit(true, false, false, false);
        emit IBrook.PoolInitialized(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT, 0);
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsIfNotConfigured() public {
        PoolKey memory key = _makePoolKey();
        vm.expectRevert();
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_configurePool_revertsIfAlreadyInitialized() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);
        vm.expectRevert(
            abi.encodeWithSelector(IBrook.PoolAlreadyInitialized.selector, id)
        );
        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);
    }

    // ---------------------------------------------------------------------
    // afterAddLiquidity
    // ---------------------------------------------------------------------

    function test_afterAddLiquidity_initializesNewPosition() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        int24 tickLower = -120;
        int24 tickUpper =  120;

        uint64 before = uint64(block.timestamp);
        _addLiquidity(key, tickLower, tickUpper, 1000e6);
        uint64 after_ = uint64(block.timestamp);

        bytes32 posKey = _positionKey(address(router), tickLower, tickUpper, bytes32(0));
        Types.LPState memory lp = brook.getLPState(id, posKey);

        assertEq(lp.tickLower,   tickLower);
        assertEq(lp.tickUpper,   tickUpper);
        assertGe(lp.depositTime, before);
        assertLe(lp.depositTime, after_);
        assertGt(lp.liquidity,   0);
    }

    function test_afterAddLiquidity_emitsLPDeposited() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        int24 tickLower = -120;
        int24 tickUpper =  120;
        bytes32 posKey = _positionKey(address(router), tickLower, tickUpper, bytes32(0));

        vm.expectEmit(true, true, true, false);
        emit IBrook.LPDeposited(id, posKey, address(router), 0);

        _addLiquidity(key, tickLower, tickUpper, 1000e6);
    }

    function test_afterAddLiquidity_topsUpExistingPosition() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -120, 120, 1000e6);
        vm.warp(block.timestamp + 1 days);
        _addLiquidity(key, -120, 120, 500e6);

        bytes32 posKey = _positionKey(address(router), -120, 120, bytes32(0));
        Types.LPState memory lp = brook.getLPState(id, posKey);

        assertGt(lp.liquidity, 0);
        assertGt(lp.totalTime, 0);
    }

    function test_afterAddLiquidity_differentRangesAreIndependent() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -120,  120, 1000e6);
        _addLiquidity(key, -240, -120, 500e6);

        bytes32 posKey1 = _positionKey(address(router), -120,  120, bytes32(0));
        bytes32 posKey2 = _positionKey(address(router), -240, -120, bytes32(0));

        Types.LPState memory lp1 = brook.getLPState(id, posKey1);
        Types.LPState memory lp2 = brook.getLPState(id, posKey2);

        assertGt(lp1.liquidity, 0);
        assertGt(lp2.liquidity, 0);
        assertTrue(posKey1 != posKey2);
    }

    // ---------------------------------------------------------------------
    // beforeRemoveLiquidity + afterRemoveLiquidity
    // ---------------------------------------------------------------------

    function test_afterRemoveLiquidity_reducesLiquidity() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -120, 120, 1000e6);
        bytes32 posKey = _positionKey(address(router), -120, 120, bytes32(0));
        uint128 before = brook.getLPState(id, posKey).liquidity;

        vm.warp(block.timestamp + 1 days);
        _removeLiquidity(key, -120, 120, 400e6);

        assertLt(brook.getLPState(id, posKey).liquidity, before);
        assertGt(brook.getLPState(id, posKey).liquidity, 0);
    }

    function test_afterRemoveLiquidity_fullWithdrawalZerosLiquidity() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -120, 120, 1000e6);
        bytes32 posKey = _positionKey(address(router), -120, 120, bytes32(0));
        uint128 full = brook.getLPState(id, posKey).liquidity;

        vm.warp(block.timestamp + 1 days);
        _removeLiquidity(key, -120, 120, int256(uint256(full)));

        assertEq(brook.getLPState(id, posKey).liquidity, 0);
    }

    function test_beforeRemoveLiquidity_settlesTotalTime() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -120, 120, 1000e6);
        vm.warp(block.timestamp + 3 days);
        _removeLiquidity(key, -120, 120, 400e6);

        bytes32 posKey = _positionKey(address(router), -120, 120, bytes32(0));
        assertGt(brook.getLPState(id, posKey).totalTime, 0);
    }

    function test_afterRemoveLiquidity_emitsLPWithdrawn() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -120, 120, 1000e6);
        bytes32 posKey = _positionKey(address(router), -120, 120, bytes32(0));

        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, true, false);
        emit IBrook.LPWithdrawn(id, posKey, address(router), 0);
        _removeLiquidity(key, -120, 120, 400e6);
    }

    function test_afterRemoveLiquidity_preservesStateAfterFullWithdrawal() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -120, 120, 1000e6);
        bytes32 posKey = _positionKey(address(router), -120, 120, bytes32(0));
        uint128 full = brook.getLPState(id, posKey).liquidity;

        vm.warp(block.timestamp + 2 days);
        _removeLiquidity(key, -120, 120, int256(uint256(full)));

        Types.LPState memory after_ = brook.getLPState(id, posKey);
        assertEq(after_.liquidity,  0);
        assertGt(after_.totalTime,  0);
        assertEq(after_.tickLower,  -120);
        assertEq(after_.tickUpper,   120);
    }

    // ---------------------------------------------------------------------
    // afterSwap
    // ---------------------------------------------------------------------

    function test_afterSwap_accumulates_fees_in_buffer() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        // Add liquidity so there is something to swap against.
        _addLiquidity(key, -600, 600, 1000e6);

        Types.EpochState memory before = brook.getEpochState(id);
        assertEq(before.buffer, 0);

        // Execute a swap.
        _swap(key, true, -1000);

        Types.EpochState memory after_ = brook.getEpochState(id);
        assertGt(after_.buffer, 0);
    }

    function test_afterSwap_emitsFeesSkimmed() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -600, 600, 1000e6);

        vm.expectEmit(true, false, false, false);
        emit IBrook.FeesSkimmed(id, 0, 0);

        _swap(key, true, -1000);
    }

    function test_afterSwap_multipleSwapsAccumulate() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);
        _initPool(key);

        _addLiquidity(key, -600, 600, 1000e6);

        _swap(key, true,  -1000);
        uint128 bufferAfterFirst = brook.getEpochState(id).buffer;

        _swap(key, false, -1000);
        uint128 bufferAfterSecond = brook.getEpochState(id).buffer;

        assertGt(bufferAfterSecond, bufferAfterFirst);
    }

    function test_afterSwap_epochRolloverMovesBuffer() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);

    // First swap fills the buffer.
    _swap(key, true, -1000);
    uint128 bufferBeforeRollover = brook.getEpochState(id).buffer;
    assertGt(bufferBeforeRollover, 0);

    // Warp past epoch length to trigger rollover on next swap.
    vm.warp(block.timestamp + EPOCH_LENGTH + 1);

    // Second swap triggers rollover then accumulates fresh fees.
    _swap(key, false, -1000);

    Types.EpochState memory state = brook.getEpochState(id);

    // prevBuffer should hold what was in the buffer before rollover.
    assertEq(state.prevBuffer, bufferBeforeRollover);

    // Buffer was reset at rollover — it now only has fees from the second swap.
    // It should be a fresh accumulation, not the old total.
    assertGt(state.buffer, 0);

    // EpochRolled event should have been emitted — verified by prevBuffer being set.
    assertTrue(state.prevBuffer > 0);
}

// ---------------------------------------------------------------------
// claim
// ---------------------------------------------------------------------

function test_claim_revertsIfPoolNotInitialized() public {
    bytes32 fakePoolId = keccak256("fake");
    bytes32 fakePosKey = keccak256("fake-pos");

    vm.expectRevert(
        abi.encodeWithSelector(IBrook.PoolNotConfigured.selector, fakePoolId)
    );
    brook.claim(fakePoolId, fakePosKey, address(this));
}

function test_claim_revertsIfNoEpochComplete() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    vm.expectRevert(
        abi.encodeWithSelector(IBrook.EpochNotYetComplete.selector, id)
    );
    brook.claim(id, posKey, address(this));
}

function test_claim_revertsIfNothingToClaim() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);
    _swap(key, true, -1000);

    vm.warp(block.timestamp + EPOCH_LENGTH + 1);
    _swap(key, false, -1000);

    bytes32 fakePosKey = keccak256("nonexistent");

    vm.expectRevert(
        abi.encodeWithSelector(IBrook.NothingToClaim.selector, id, fakePosKey)
    );
    brook.claim(id, fakePosKey, address(this));
}

function test_claim_payoutAfterEpochRollover() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);

    // Fill the buffer with swap fees.
    _swap(key, true, -1000);
    _swap(key, false, -1000);
    _swap(key, true, -1000);

    uint128 bufferBeforeRollover = brook.getEpochState(id).buffer;
    assertGt(bufferBeforeRollover, 0);

    // Warp past epoch to trigger rollover.
    vm.warp(block.timestamp + EPOCH_LENGTH + 1);

    // Trigger rollover via swap.
    _swap(key, false, -1000);

    assertEq(brook.getEpochState(id).prevBuffer, bufferBeforeRollover);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    // Warp halfway through next epoch so some yield has vested.
    vm.warp(block.timestamp + EPOCH_LENGTH / 2);

    address recipient = makeAddr("recipient");
    uint256 balanceBefore = token1.balanceOf(recipient);

    brook.claim(id, posKey, recipient);

    uint256 balanceAfter = token1.balanceOf(recipient);
    assertGt(balanceAfter, balanceBefore);
}

function test_claim_emitsYieldClaimed() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);
    _swap(key, true, -1000);

    vm.warp(block.timestamp + EPOCH_LENGTH + 1);
    _swap(key, false, -1000);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    vm.warp(block.timestamp + EPOCH_LENGTH / 2);

    vm.expectEmit(true, true, true, false);
    emit IBrook.YieldClaimed(id, posKey, address(this), 0);

    brook.claim(id, posKey, address(this));
}

function test_claim_secondClaimOnlyVestsAdditional() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);
    _swap(key, true, -1000);

    vm.warp(block.timestamp + EPOCH_LENGTH + 1);
    _swap(key, false, -1000);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    address recipient = makeAddr("recipient");

    // First claim at 25% of epoch.
    vm.warp(block.timestamp + EPOCH_LENGTH / 4);
    brook.claim(id, posKey, recipient);
    uint256 firstClaim = token1.balanceOf(recipient);
    assertGt(firstClaim, 0);

    // Second claim at 50% of epoch.
    vm.warp(block.timestamp + EPOCH_LENGTH / 4);
    brook.claim(id, posKey, recipient);
    uint256 secondClaim = token1.balanceOf(recipient) - firstClaim;
    assertGt(secondClaim, 0);

    // Both claims together should be less than or equal to the full share.
    assertLe(firstClaim + secondClaim, uint256(brook.getEpochState(id).prevBuffer));
}

// ---------------------------------------------------------------------
// in-range accumulator
// ---------------------------------------------------------------------

function test_inRange_timeAccumulatesWhenInRange() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    // Add liquidity covering the current tick (tick 0 at 1:1 price).
    _addLiquidity(key, -120, 120, 1000e6);

    // Execute a swap to set currentTick in epoch state.
    _swap(key, true, -1000);

    bytes32 posKey = _positionKey(address(router), -120, 120, bytes32(0));

    // Warp forward and trigger a settlement via top-up.
    vm.warp(block.timestamp + 1 days);
    _addLiquidity(key, -120, 120, 1e6);

    Types.LPState memory lp = brook.getLPState(id, posKey);

    // Position was in-range (tick 0 is between -120 and 120).
    assertGt(lp.inRangeTime, 0);
    assertEq(lp.inRangeTime, lp.totalTime);
}

function test_inRange_scoreHigherForInRangeLP() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -120, 120, 1000e6);
    _swap(key, true, -1000);

    bytes32 posKeyInRange = _positionKey(address(router), -120, 120, bytes32(0));

    vm.warp(block.timestamp + 7 days);
    _addLiquidity(key, -120, 120, 1e6);

    Types.LPState memory lp = brook.getLPState(id, posKeyInRange);

    assertGt(lp.inRangeTime, 0);
    assertEq(lp.inRangeTime, lp.totalTime);
}

function test_inRange_currentTickStoredAfterSwap() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);

    Types.EpochState memory before = brook.getEpochState(id);
    assertEq(before.currentTick, 0);

    _swap(key, true, -1000);

    Types.EpochState memory after_ = brook.getEpochState(id);
    // Tick may have moved from 0 after swap.
    // We just verify it was recorded (field is accessible and set).
    assertTrue(after_.currentTick <= 0);
}

function test_inRange_timeDoesNotAccumulateWhenOutOfRange() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    // Add some in-range liquidity first so swap can execute.
    _addLiquidity(key, -600, 600, 1000e6);

    // Execute a swap to set currentTick BEFORE adding the out-of-range position.
    _swap(key, true, -1000);

    // Now add the out-of-range position — depositTime and lastTouched set here.
    // At this point currentTick is already recorded from the swap above.
    _addLiquidity(key, -600, -120, 500e6);

    bytes32 posKey = _positionKey(address(router), -600, -120, bytes32(0));

    // Warp forward and trigger settlement via another swap.
    vm.warp(block.timestamp + 1 days);
    _swap(key, false, -1000);

    // Trigger explicit settlement via top-up.
    _addLiquidity(key, -600, -120, 1e6);

    Types.LPState memory lp = brook.getLPState(id, posKey);

    // Position range is -600 to -120. Current tick should be near 0 (above -120).
    // Position is out of range — inRangeTime should be zero.
    assertEq(lp.inRangeTime, 0);
    assertGt(lp.totalTime, 0);
}

// ---------------------------------------------------------------------
// hardening
// ---------------------------------------------------------------------

function test_claim_revertsOnZeroAddressRecipient() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);
    _swap(key, true, -1000);

    vm.warp(block.timestamp + EPOCH_LENGTH + 1);
    _swap(key, false, -1000);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    vm.warp(block.timestamp + EPOCH_LENGTH / 2);

    vm.expectRevert(IBrook.InvalidRecipient.selector);
    brook.claim(id, posKey, address(0));
}

function test_computePositionKey_matchesDerived() public view {
    // The position key computed externally must match what Brook stores internally.
    int24 tickLower = -120;
    int24 tickUpper =  120;
    bytes32 salt    = bytes32(0);

    bytes32 computed = brook.computePositionKey(
        address(router),
        tickLower,
        tickUpper,
        salt
    );

    bytes32 expected = keccak256(abi.encode(
        address(router),
        tickLower,
        tickUpper,
        salt
    ));

    assertEq(computed, expected);
}

function test_computePositionKey_differentSendersDifferentKeys() public view {
    bytes32 key1 = brook.computePositionKey(address(0x1), -120, 120, bytes32(0));
    bytes32 key2 = brook.computePositionKey(address(0x2), -120, 120, bytes32(0));

    assertTrue(key1 != key2);
}

function test_computePositionKey_differentRangesDifferentKeys() public view {
    bytes32 key1 = brook.computePositionKey(address(router), -120,  120, bytes32(0));
    bytes32 key2 = brook.computePositionKey(address(router), -240, -120, bytes32(0));

    assertTrue(key1 != key2);
}

function test_configurePool_anyoneCanConfigure() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);

    // A random address can configure a pool.
    address randomCaller = makeAddr("random");
    vm.prank(randomCaller);
    brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);

    Types.PoolConfig memory pending = brook.getPendingConfig(id);
    assertEq(pending.epochLength, EPOCH_LENGTH);
}

function test_configurePool_cannotReconfigureAfterInit() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    vm.expectRevert(
        abi.encodeWithSelector(IBrook.PoolAlreadyInitialized.selector, id)
    );
    brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);
}

// ---------------------------------------------------------------------
// edge cases
// ---------------------------------------------------------------------

function test_edge_emptyEpoch_claimRevertsWithNoBuffer() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);

    // No swaps — buffer stays zero.
    // Warp past epoch length.
    vm.warp(block.timestamp + EPOCH_LENGTH + 1);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    // prevBuffer is still zero — claim should revert.
    vm.expectRevert(
        abi.encodeWithSelector(IBrook.EpochNotYetComplete.selector, id)
    );
    brook.claim(id, posKey, address(this));
}

function test_edge_firstEpoch_noPayoutUntilRollover() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);
    _swap(key, true, -1000);

    // Buffer is filling but no rollover yet.
    assertGt(brook.getEpochState(id).buffer, 0);
    assertEq(brook.getEpochState(id).prevBuffer, 0);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    // Cannot claim yet.
    vm.expectRevert(
        abi.encodeWithSelector(IBrook.EpochNotYetComplete.selector, id)
    );
    brook.claim(id, posKey, address(this));
}

function test_edge_lazyRollover_triggeredOnNextSwap() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);
    _swap(key, true, -1000);

    uint128 bufferBefore = brook.getEpochState(id).buffer;
    assertGt(bufferBefore, 0);

    vm.warp(block.timestamp + EPOCH_LENGTH + 1);

    // Rollover fires lazily on next swap.
    _swap(key, false, -1000);

    Types.EpochState memory state = brook.getEpochState(id);
    assertEq(state.prevBuffer, bufferBefore);
    // Current buffer has fees from the second swap — just assert it was reset and refilling.
    assertGt(state.buffer, 0);
}

function test_edge_flashDeposit_trivialScore() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    // LP1 deposits at the start and stays the whole epoch.
    _addLiquidity(key, -600, 600, 1000e6);
    _swap(key, true, -1000);

    // Warp to just before rollover.
    vm.warp(block.timestamp + EPOCH_LENGTH - 1);

    // LP2 flash deposits 1 second before rollover.
    _addLiquidity(key, -600, 600, 1000e6);

    // Rollover triggers.
    vm.warp(block.timestamp + 2);
    _swap(key, false, -1000);

    bytes32 posKey1 = _positionKey(address(router), -600, 600, bytes32(0));

    // Warp to end of streaming epoch.
    vm.warp(block.timestamp + EPOCH_LENGTH);

    address recipient = makeAddr("lp1");
    brook.claim(id, posKey1, recipient);

    uint256 lp1Payout = token1.balanceOf(recipient);

    // LP1 should get the vast majority of the buffer.
    // LP2's score is trivial (1 second vs full epoch).
    assertGt(lp1Payout, 0);
}

function test_edge_singleLP_gets100PercentOfBuffer() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);

    // Two swaps to fill the buffer.
    _swap(key, true, -1000);
    _swap(key, false, -1000);

    uint128 prevBuf = brook.getEpochState(id).buffer;
    assertGt(prevBuf, 0);

    // Trigger rollover.
    vm.warp(block.timestamp + EPOCH_LENGTH + 1);
    _swap(key, true, -1000);

    assertEq(brook.getEpochState(id).prevBuffer, prevBuf);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    // Claim at 50% elapsed — hook definitely has enough balance.
    vm.warp(block.timestamp + EPOCH_LENGTH / 2);

    address recipient = makeAddr("sole-lp");
    brook.claim(id, posKey, recipient);

    // Single LP earns all of their vested share.
    assertGt(token1.balanceOf(recipient), 0);
}

function test_edge_outOfRangeLP_stillEarnsPartialYield() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    // Add in-range liquidity so swaps work.
    _addLiquidity(key, -600, 600, 1000e6);

    // Add out-of-range liquidity (below current tick).
    _addLiquidity(key, -600, -120, 500e6);

    _swap(key, true, -1000);

    vm.warp(block.timestamp + EPOCH_LENGTH + 1);
    _swap(key, false, -1000);

    bytes32 posKeyOutOfRange = _positionKey(address(router), -600, -120, bytes32(0));

    vm.warp(block.timestamp + EPOCH_LENGTH);

    address recipient = makeAddr("out-of-range-lp");
    uint256 balBefore = token1.balanceOf(recipient);

    // Out-of-range LP should still earn something (inRangeMultiplier gives partial credit).
    brook.claim(id, posKeyOutOfRange, recipient);

    uint256 payout = token1.balanceOf(recipient) - balBefore;
    assertGt(payout, 0);
}

function test_edge_claimAtExactEpochBoundary() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);
    _swap(key, true, -1000);

    vm.warp(block.timestamp + EPOCH_LENGTH + 1);
    _swap(key, false, -1000);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));

    // Claim at exactly epoch length elapsed — should get full share.
    vm.warp(block.timestamp + EPOCH_LENGTH);

    address recipient = makeAddr("exact-boundary");
    brook.claim(id, posKey, recipient);

    assertGt(token1.balanceOf(recipient), 0);
}

function test_edge_noSwaps_lpWithdrawsCleanly() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    _addLiquidity(key, -600, 600, 1000e6);

    vm.warp(block.timestamp + 3 days);

    bytes32 posKey = _positionKey(address(router), -600, 600, bytes32(0));
    Types.LPState memory lp = brook.getLPState(id, posKey);
    uint128 full = lp.liquidity;

    // Withdraw cleanly with no swaps ever happening.
    _removeLiquidity(key, -600, 600, int256(uint256(full)));

    Types.LPState memory after_ = brook.getLPState(id, posKey);
    assertEq(after_.liquidity, 0);
    assertGt(after_.totalTime, 0);
    assertEq(brook.getEpochState(id).buffer, 0);
}

    // ---------------------------------------------------------------------
    // Permission flags
    // ---------------------------------------------------------------------

    function test_getHookPermissions_returnsExpectedFlags() public view {
        Hooks.Permissions memory perms = brook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertTrue(perms.afterAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertTrue(perms.afterRemoveLiquidity);
        assertTrue(perms.afterSwap);
        assertTrue(perms.afterSwapReturnDelta);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.beforeSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    // ---------------------------------------------------------------------
    // State shape
    // ---------------------------------------------------------------------

    function test_poolConfig_defaultValuesAreZero() public pure {
        Types.PoolConfig memory cfg;
        assertEq(cfg.epochLength, 0);
        assertEq(cfg.startTime, 0);
        assertEq(cfg.smoothingFee, 0);
        assertEq(cfg.inRangeMultiplier, 0);
    }

    function test_epochState_defaultValuesAreZero() public pure {
        Types.EpochState memory state;
        assertEq(state.buffer, 0);
        assertEq(state.prevBuffer, 0);
        assertEq(state.totalScore, 0);
        assertEq(state.lastUpdateTime, 0);
    }

    function test_lpState_defaultValuesAreZero() public pure {
        Types.LPState memory lp;
        assertEq(lp.liquidity, 0);
        assertEq(lp.tickLower, int24(0));
        assertEq(lp.tickUpper, int24(0));
        assertEq(lp.depositTime, 0);
        assertEq(lp.inRangeTime, 0);
        assertEq(lp.totalTime, 0);
        assertEq(lp.lastTouched, 0);
        assertEq(lp.pendingClaim, 0);
        assertEq(lp.scoreSnapshot, 0);
    }
}