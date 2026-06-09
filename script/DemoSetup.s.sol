// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {Brook} from "../src/Brook.sol";
import {Types} from "../src/libraries/Types.sol";
import {BrookRouter} from "../src/BrookRouter.sol";

/// @notice Sets up a fresh, self-serve demo pool with a 1-hour epoch.
///         Run AS THE DEMO WALLET so the LP position keys to it.
contract DemoSetup is Script {
    uint24  constant FEE             = 3000;
    int24   constant TICK_SPACING    = 60;
    uint160 constant SQRT_PRICE_1_1  = 79228162514264337593543950336;
    uint64  constant EPOCH_LENGTH    = 1 hours;
    uint16  constant SMOOTHING_FEE   = 2000;
    uint16  constant IN_RANGE_MULT   = 4;
    uint256 constant LIQUIDITY       = 1_000_000;
    int256  constant FILL_SWAP       = -50_000;

    function run(address brookAddress, address routerAddress) external {
        address poolManager = AddressConstants.getPoolManagerAddress(block.chainid);

        vm.startBroadcast();

        address tokenA = _deployToken("Demo Token A", "DTA");
        address tokenB = _deployToken("Demo Token B", "DTB");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        _mint(token0, msg.sender, 1_000_000e18);
        _mint(token1, msg.sender, 1_000_000e18);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(brookAddress)
        });
        bytes32 poolId = keccak256(abi.encode(key));

        Brook(brookAddress).configurePool(poolId, EPOCH_LENGTH, SMOOTHING_FEE, IN_RANGE_MULT);
        IPoolManager(poolManager).initialize(key, SQRT_PRICE_1_1);

        IERC20(token0).approve(routerAddress, type(uint256).max);
        IERC20(token1).approve(routerAddress, type(uint256).max);
        BrookRouter(routerAddress).addLiquidity(key, LIQUIDITY);

        BrookRouter(routerAddress).swap(key, false, FILL_SWAP);

        vm.stopBroadcast();

        Types.EpochState memory ep = Brook(brookAddress).getEpochState(poolId);

        console.log("--- DEMO POOL READY ---");
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Epoch buffer:", ep.buffer);
        console.log("POOL_ID:");
        console.logBytes32(poolId);
        console.log("Position key for this wallet:");
        console.logBytes32(BrookRouter(routerAddress).positionKeyFor(msg.sender));
        console.log("Wait 1 hour, then swap once more to roll the epoch.");
    }

    function _deployToken(string memory name, string memory symbol)
        internal returns (address token)
    {
        bytes memory bytecode = abi.encodePacked(
            type(DemoERC20).creationCode,
            abi.encode(name, symbol)
        );
        assembly { token := create(0, add(bytecode, 0x20), mload(bytecode)) }
    }

    function _mint(address token, address to, uint256 amount) internal {
        DemoERC20(token).mint(to, amount);
    }
}

contract DemoERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name; symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
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
