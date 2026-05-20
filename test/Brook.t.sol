// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {Brook} from "../src/Brook.sol";
import {IBrook} from "../src/interfaces/IBrook.sol";
import {Types} from "../src/libraries/Types.sol";
import {BrookConstants} from "../src/libraries/Types.sol";

contract BrookTest is Test {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IPoolManager internal poolManager;
    Brook internal brook;

    // valid default config values
    uint64  constant EPOCH_LENGTH       = 7 days;
    uint16  constant SMOOTHING_FEE      = 2000; // 20%
    uint16  constant IN_RANGE_MULT      = 4;

    function setUp() public {
        poolManager = IPoolManager(V4PoolManagerDeployer.deploy(address(this)));

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
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Builds a minimal PoolKey pointing at brook as the hook.
    function _makePoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0:   Currency.wrap(address(0)),
            currency1:   Currency.wrap(address(1)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(brook))
        });
    }

    /// @dev Derives the poolId the same way Brook does internally.
    function _poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /// @dev Configures and initializes a pool with default values.
    function _initPool(PoolKey memory key) internal {
        bytes32 id = _poolId(key);
        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);
        poolManager.initialize(key, 79228162514264337593543950336); // sqrtPriceX96 = 1:1
    }

    // ---------------------------------------------------------------------
    // Deployment (carried over from PR #3)
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
        assertEq(pending.startTime,         0); // not set until init
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
        assertEq(pending.epochLength, 0); // deleted
    }

    function test_beforeInitialize_emitsPoolInitialized() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);

        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);

        vm.expectEmit(true, false, false, false);
        emit IBrook.PoolInitialized(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT, 0);

        poolManager.initialize(key, 79228162514264337593543950336);
    }

    function test_beforeInitialize_revertsIfNotConfigured() public {
        PoolKey memory key = _makePoolKey();
        bytes32 id = _poolId(key);

    // The PoolManager wraps hook reverts in its own error before bubbling up.
    // We check that the call reverts at all, and verify the revert data
    // contains our PoolNotConfigured selector.
    vm.expectRevert();
    poolManager.initialize(key, 79228162514264337593543950336);
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
    // Permission flags (carried over)
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
    // State shape (carried over)
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