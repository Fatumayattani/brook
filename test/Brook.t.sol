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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {Brook} from "../src/Brook.sol";
import {IBrook} from "../src/interfaces/IBrook.sol";
import {Types} from "../src/libraries/Types.sol";
import {BrookConstants} from "../src/libraries/Types.sol";

/// @dev Minimal router that unlocks the PoolManager, calls modifyLiquidity,
///      then settles any owed balances by transferring tokens from the caller.
contract LiquidityRouter {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct AddParams {
        PoolKey key;
        ModifyLiquidityParams params;
        address payer;
    }

    function addLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        address payer
    ) external returns (BalanceDelta delta, BalanceDelta fees) {
        bytes memory data = abi.encode(AddParams(key, params, payer));
        bytes memory result = manager.unlock(data);
        (delta, fees) = abi.decode(result, (BalanceDelta, BalanceDelta));
    }

    function unlockCallback(bytes calldata data)
        external
        returns (bytes memory)
    {
        require(msg.sender == address(manager), "not manager");
        AddParams memory p = abi.decode(data, (AddParams));

        (BalanceDelta delta, BalanceDelta fees) = manager.modifyLiquidity(
            p.key,
            p.params,
            ""
        );

        _settle(p.key.currency0, p.payer, delta.amount0());
        _settle(p.key.currency1, p.payer, delta.amount1());

        return abi.encode(delta, fees);
    }

    function _settle(Currency currency, address payer, int128 amount) internal {
    if (amount < 0) {
        // Caller owes the pool — transfer tokens then settle.
        uint128 owed = uint128(-amount);
        manager.sync(currency);
        MockERC20(Currency.unwrap(currency)).transferFrom(
            payer,
            address(manager),
            owed
        );
        manager.settle();
    } else if (amount > 0) {
        // Pool owes the caller — take tokens out.
        manager.take(currency, payer, uint128(amount));
    }
}
}

contract BrookTest is Test {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IPoolManager internal poolManager;
    Brook internal brook;
    LiquidityRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;

    uint64 constant EPOCH_LENGTH  = 7 days;
    uint16 constant SMOOTHING_FEE = 2000;
    uint16 constant IN_RANGE_MULT = 4;
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

        router = new LiquidityRouter(poolManager);
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
        router.addLiquidity(
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
    int256 liquidity = 1000e6;

    uint64 before = uint64(block.timestamp);
    _addLiquidity(key, tickLower, tickUpper, liquidity);
    uint64 after_ = uint64(block.timestamp);

    // sender is router, not address(this), because router calls modifyLiquidity
    bytes32 posKey = _positionKey(address(router), tickLower, tickUpper, bytes32(0));
    Types.LPState memory lp = brook.getLPState(id, posKey);

    assertEq(lp.tickLower,   tickLower);
    assertEq(lp.tickUpper,   tickUpper);
    assertGe(lp.depositTime, before);
    assertLe(lp.depositTime, after_);
    assertGe(lp.lastTouched, before);
    assertGt(lp.liquidity,   0);
}

function test_afterAddLiquidity_emitsLPDeposited() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    int24 tickLower = -120;
    int24 tickUpper =  120;
    // sender is router because it calls modifyLiquidity
    bytes32 posKey = _positionKey(address(router), tickLower, tickUpper, bytes32(0));

    vm.expectEmit(true, true, true, false);
    emit IBrook.LPDeposited(id, posKey, address(router), 0);

    _addLiquidity(key, tickLower, tickUpper, 1000e6);
}

function test_afterAddLiquidity_topsUpExistingPosition() public {
    PoolKey memory key = _makePoolKey();
    bytes32 id = _poolId(key);
    _initPool(key);

    int24 tickLower = -120;
    int24 tickUpper =  120;

    _addLiquidity(key, tickLower, tickUpper, 1000e6);
    vm.warp(block.timestamp + 1 days);
    _addLiquidity(key, tickLower, tickUpper, 500e6);

    bytes32 posKey = _positionKey(address(router), tickLower, tickUpper, bytes32(0));
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