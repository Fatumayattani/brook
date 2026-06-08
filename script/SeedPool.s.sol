// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {Brook} from "../src/Brook.sol";
import {Types} from "../src/libraries/Types.sol";
import {BrookConstants} from "../src/libraries/Types.sol";

contract SeedPool is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint24  constant FEE              = 3000;
    int24   constant TICK_SPACING     = 60;
    uint160 constant SQRT_PRICE_1_1   = 79228162514264337593543950336;
    uint64  constant EPOCH_LENGTH     = 7 days;
    uint16  constant SMOOTHING_FEE    = 2000;
    uint16  constant IN_RANGE_MULT    = 4;
    int256  constant LIQUIDITY_AMOUNT = 1_000;
    int256  constant SWAP_AMOUNT      = -10_000;
    uint8   constant SWAP_COUNT       = 5;
    int24   constant TICK_LOWER       = -887220;
    int24   constant TICK_UPPER       =  887220;

    address constant POOL_MODIFY_LIQUIDITY_TEST = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;
    address constant POOL_SWAP_TEST             = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;

    /// @notice Deploy fresh tokens and seed a new Brook pool in a single broadcast.
    function runWithNewTokens(address brookAddress) external {
        address poolManager = AddressConstants.getPoolManagerAddress(block.chainid);

        vm.startBroadcast();

        // 1. Deploy tokens inside broadcast so addresses are deterministic.
        address tokenA = _deployToken("Brook Token A", "BTA");
        address tokenB = _deployToken("Brook Token B", "BTB");

        // 2. Sort tokens.
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        // 3. Mint to deployer.
        _mint(token0, msg.sender, 1_000_000e18);
        _mint(token1, msg.sender, 1_000_000e18);

        // 4. Approve test contracts.
        IERC20(token0).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(token1).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(token0).approve(POOL_SWAP_TEST, type(uint256).max);
        IERC20(token1).approve(POOL_SWAP_TEST, type(uint256).max);
        IERC20(token0).approve(poolManager, type(uint256).max);
        IERC20(token1).approve(poolManager, type(uint256).max);

        // 5. Build PoolKey and compute poolId inside broadcast.
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(brookAddress)
        });

        bytes32 poolId = keccak256(abi.encode(key));

        // 6. Configure Brook, initialize pool, add liquidity, run swaps.
        Brook(brookAddress).configurePool(poolId, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);

        IPoolManager(poolManager).initialize(key, SQRT_PRICE_1_1);

        IPoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_TEST).modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      TICK_LOWER,
                tickUpper:      TICK_UPPER,
                liquidityDelta: LIQUIDITY_AMOUNT,
                salt:           bytes32(0)
            }),
            ""
        );

        // Fresh pool at SQRT_PRICE_1_1 — alternate swap directions.
        _runSwapsFreshPool(key);

        vm.stopBroadcast();

        // 7. Log state after broadcast.
        Types.EpochState memory epoch = Brook(brookAddress).getEpochState(poolId);
        console.log("---");
        console.log("Epoch buffer:", epoch.buffer);
        console.log("BROOK_ADDRESS:", brookAddress);
        console.log("POOL_MANAGER:", poolManager);
        console.log("TOKEN0:", token0);
        console.log("TOKEN1:", token1);
        console.log("POOL_ID:"); console.logBytes32(poolId);
    }

    /// @notice Add liquidity and run swaps on an already-initialized pool.
    function runLiquidityAndSwaps(
        address brookAddress,
        address tokenA,
        address tokenB,
        bytes32 poolId
    ) external {
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(brookAddress)
        });

        vm.startBroadcast();

        _mint(token0, msg.sender, 1_000_000e18);
        _mint(token1, msg.sender, 1_000_000e18);

        IERC20(token0).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(token1).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(token0).approve(POOL_SWAP_TEST, type(uint256).max);
        IERC20(token1).approve(POOL_SWAP_TEST, type(uint256).max);

        IPoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_TEST).modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      TICK_LOWER,
                tickUpper:      TICK_UPPER,
                liquidityDelta: LIQUIDITY_AMOUNT,
                salt:           bytes32(0)
            }),
            ""
        );

        // Pool at MIN_PRICE — only swap !zeroForOne.
        _runSwapsMinPrice(key);

        vm.stopBroadcast();

        Types.EpochState memory epoch = Brook(brookAddress).getEpochState(poolId);
        console.log("Epoch buffer:", epoch.buffer);
        console.log("BROOK_ADDRESS:", brookAddress);
        console.log("TOKEN0:", token0);
        console.log("TOKEN1:", token1);
        console.log("POOL_ID:"); console.logBytes32(poolId);
    }

    // ---------------------------------------------------------------------
    // Swap helpers
    // ---------------------------------------------------------------------

    /// @dev For a fresh pool at SQRT_PRICE_1_1 — alternate directions.
    function _runSwapsFreshPool(PoolKey memory key) internal {
        for (uint8 i = 0; i < SWAP_COUNT; i++) {
            bool zeroForOne = i % 2 == 0;
            IPoolSwapTest(POOL_SWAP_TEST).swap(
                key,
                SwapParams({
                    zeroForOne:        zeroForOne,
                    amountSpecified:   SWAP_AMOUNT,
                    sqrtPriceLimitX96: zeroForOne
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                IPoolSwapTest.TestSettings({
                    takeClaims:      false,
                    settleUsingBurn: false
                }),
                ""
            );
        }
    }

    /// @dev For a pool already at MIN_PRICE — only swap !zeroForOne.
    function _runSwapsMinPrice(PoolKey memory key) internal {
        for (uint8 i = 0; i < SWAP_COUNT; i++) {
            IPoolSwapTest(POOL_SWAP_TEST).swap(
                key,
                SwapParams({
                    zeroForOne:        false,
                    amountSpecified:   SWAP_AMOUNT,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                IPoolSwapTest.TestSettings({
                    takeClaims:      false,
                    settleUsingBurn: false
                }),
                ""
            );
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _deployToken(string memory name, string memory symbol)
        internal returns (address)
    {
        bytes memory bytecode = abi.encodePacked(
            type(MinimalERC20).creationCode,
            abi.encode(name, symbol)
        );
        address token;
        assembly { token := create(0, add(bytecode, 0x20), mload(bytecode)) }
        return token;
    }

    function _mint(address token, address to, uint256 amount) internal {
        MinimalERC20(token).mint(to, amount);
    }
}

// ---------------------------------------------------------------------
// Interfaces for Uniswap-deployed test contracts
// ---------------------------------------------------------------------

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta);
}

interface IPoolSwapTest {
    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        TestSettings memory testSettings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta);
}

// ---------------------------------------------------------------------
// Minimal ERC20
// ---------------------------------------------------------------------

contract MinimalERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name; symbol = _symbol; owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        totalSupply += amount; balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max)
            allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount; balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}