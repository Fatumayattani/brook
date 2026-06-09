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
import {Types} from "../src/libraries/Types.sol";
import {BrookRouter, IBrookClaim} from "../src/BrookRouter.sol";

contract BrookRouterTest is Test {
    IPoolManager internal poolManager;
    Brook        internal brook;
    BrookRouter  internal router;
    MockERC20    internal token0;
    MockERC20    internal token1;
    Currency     internal currency0;
    Currency     internal currency1;

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");

    uint64  constant EPOCH_LENGTH   = 1 hours;
    uint16  constant SMOOTHING_FEE  = 2000;
    uint16  constant IN_RANGE_MULT  = 4;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant LIQUIDITY      = 1_000_000;

    function setUp() public {
        poolManager = IPoolManager(V4PoolManagerDeployer.deploy(address(this)));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

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
        require(address(brook) == expected, "deploy mismatch");

        router = new BrookRouter(poolManager, IBrookClaim(address(brook)));

        _fundAndApprove(alice);
        _fundAndApprove(bob);
    }

    function _fundAndApprove(address user) internal {
        token0.mint(user, 1_000_000 ether);
        token1.mint(user, 1_000_000 ether);
        vm.startPrank(user);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(brook))
        });
    }

    function _initPool() internal returns (PoolKey memory key, bytes32 id) {
        key = _key();
        id  = keccak256(abi.encode(key));
        brook.configurePool(id, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_addLiquidity_keysPositionToUserNotRouter() public {
        (PoolKey memory key, bytes32 id) = _initPool();

        vm.prank(alice);
        router.addLiquidity(key, LIQUIDITY);

        bytes32 aliceKey = router.positionKeyFor(alice);
        Types.LPState memory lp = brook.getLPState(id, aliceKey);
        assertEq(lp.liquidity, uint128(LIQUIDITY), "alice liquidity recorded");

        bytes32 routerKey = keccak256(abi.encode(address(router), int24(-887220), int24(887220), bytes32(0)));
        Types.LPState memory routerLp = brook.getLPState(id, routerKey);
        assertEq(routerLp.liquidity, 0, "router holds no position");
    }

    function test_twoUsers_haveDistinctPositions() public {
        (PoolKey memory key, bytes32 id) = _initPool();

        vm.prank(alice);
        router.addLiquidity(key, LIQUIDITY);
        vm.prank(bob);
        router.addLiquidity(key, LIQUIDITY * 2);

        Types.LPState memory aLp = brook.getLPState(id, router.positionKeyFor(alice));
        Types.LPState memory bLp = brook.getLPState(id, router.positionKeyFor(bob));

        assertEq(aLp.liquidity, uint128(LIQUIDITY),     "alice position");
        assertEq(bLp.liquidity, uint128(LIQUIDITY * 2), "bob position");
    }

    function test_swap_fillsEpochBuffer() public {
        (PoolKey memory key, bytes32 id) = _initPool();

        vm.prank(alice);
        router.addLiquidity(key, LIQUIDITY);

        vm.prank(bob);
        router.swap(key, false, -10_000);

        Types.EpochState memory ep = brook.getEpochState(id);
        assertGt(ep.buffer, 0, "buffer filled by swap");
    }

    function test_fullLoop_userClaimsRealYield() public {
        (PoolKey memory key, bytes32 id) = _initPool();

        vm.prank(alice);
        router.addLiquidity(key, LIQUIDITY);

        vm.prank(bob);
        router.swap(key, false, -50_000);

        Types.EpochState memory ep = brook.getEpochState(id);
        assertGt(ep.buffer, 0, "buffer should be non-zero");

        vm.warp(block.timestamp + EPOCH_LENGTH + 1);
        vm.prank(bob);
        router.swap(key, true, -50_000);

        ep = brook.getEpochState(id);
        assertGt(ep.prevBuffer, 0, "prevBuffer should be funded after roll");

        vm.warp(block.timestamp + (EPOCH_LENGTH / 2));

        Currency feeCcy = brook.getFeeCurrency(id);
        address feeToken = Currency.unwrap(feeCcy);
        uint256 beforeBal = MockERC20(feeToken).balanceOf(alice);

        vm.prank(alice);
        router.claim(key);

        uint256 afterBal = MockERC20(feeToken).balanceOf(alice);
        assertGt(afterBal, beforeBal, "alice received yield in her wallet");
    }

    function test_claim_revertsBeforeRollover() public {
        (PoolKey memory key,) = _initPool();

        vm.prank(alice);
        router.addLiquidity(key, LIQUIDITY);
        vm.prank(bob);
        router.swap(key, false, -10_000);

        vm.prank(alice);
        vm.expectRevert();
        router.claim(key);
    }
}
