# Brook

A Uniswap v4 hook that turns lumpy swap fees into predictable, paycheck-style LP yield, weighted by who actually provided useful liquidity.

---

## The problem

LP income on Uniswap is wildly volatile. Some weeks bring high APR, others bring zero. That volatility is fine for retail farmers but it disqualifies an entire class of capital - DAO treasuries, stablecoin LPs, structured product builders, and institutional players who need legible cash flows for governance, accounting, and reporting.

Meanwhile, mercenary capital flashes through pools during high-volume moments, extracts the fat fees, and exits — leaving committed LPs to absorb the volatility they could not time around.

---

## How Brook works

Each pool runs on fixed epochs (default: 7 days). During an epoch, Brook diverts a fraction of swap fees into a buffer instead of distributing them immediately. At each epoch rollover, the previous epoch's buffer becomes the next epoch's payout pool, streamed linearly to LPs over its duration, weighted by useful liquidity score.

### The two-epoch model

Two epochs are always alive simultaneously:

```
Buffer (epoch N)   →rollover→   prevBuffer (epoch N-1)
filling now                     streaming now
```

Even if a week sees zero swaps, the previous week's buffer continues streaming. That is the smoothing guarantee.

### Pool creation flow

Brook uses a two-step pool creation pattern. This version of v4-core does not pass hookData to initialize, so configuration is set before pool creation:

```
1. brook.configurePool(poolId, epochLength, smoothingFee, inRangeMultiplier)
2. poolManager.initialize(key, sqrtPriceX96)
   beforeInitialize fires, reads the pending config, locks it permanently
```

Parameters are immutable after initialization.

### What happens on every swap

```
swap occurs
    ↓
afterSwap fires
    ↓
1. check epoch rollover
2. identify output token from swap direction
3. skim smoothingFee bps of swap output
4. poolManager.take(feeCurrency, address(this), fee)
5. epoch.buffer += fee
6. return feeSkimAmount as afterSwapReturnDelta
7. update lastUpdateTime
```

### Score formula

```
score = liquidity × (inRangeTime × multiplier + outOfRangeTime) / multiplier
```

With the default multiplier of 4:

| Behaviour | Score relative to full in-range |
|---|---|
| 100% in-range | 1.0x |
| 50% in-range | 0.625x |
| 25% in-range | 0.4375x |
| 0% in-range | 0.25x |

Out-of-range LPs still earn. Brook rewards commitment proportionally rather than punishing absence.

---

## Hook permissions

```solidity
Hooks.Permissions({
    beforeInitialize:                  true,
    afterInitialize:                   false,
    beforeAddLiquidity:                false,
    afterAddLiquidity:                 true,
    beforeRemoveLiquidity:             true,
    afterRemoveLiquidity:              true,
    beforeSwap:                        false,
    afterSwap:                         true,
    beforeDonate:                      false,
    afterDonate:                       false,
    beforeSwapReturnDelta:             false,
    afterSwapReturnDelta:              true,
    afterAddLiquidityReturnDelta:      false,
    afterRemoveLiquidityReturnDelta:   false
})
```

Flag bitmask: `0x2744`. The deployed address encodes these flags in its lowest 14 bits via CREATE2 address mining.

---

## Data model

```solidity
struct PoolConfig {
    uint64 epochLength;        // seconds, default 7 days
    uint64 startTime;          // set at pool initialization
    uint16 smoothingFee;       // bps diverted to buffer, max 5000
    uint16 inRangeMultiplier;  // 1 to 10, default 4
}

struct EpochState {
    uint128 buffer;            // fees accumulating this epoch
    uint128 prevBuffer;        // streaming to LPs now
    uint64  totalScore;        // sum of all LP scores this epoch
    uint64  lastUpdateTime;    // updated on every swap
}

struct LPState {
    uint128 liquidity;
    int24   tickLower;
    int24   tickUpper;
    uint64  depositTime;
    uint64  inRangeTime;
    uint64  totalTime;
    uint64  lastTouched;
    uint64  pendingClaim;
    uint64  scoreSnapshot;
}
```

### Validation bounds

```
epochLength:         1 hour  to  90 days
smoothingFee:        0 bps   to  5000 bps
inRangeMultiplier:   1       to  10
```

---

## Import paths

Confirmed against the actual lib folder. Do not change.

```solidity
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
```

---

## Callback signatures

Brook overrides the internal underscore versions of each callback. The external versions are defined on BaseHook and call these internally.

```solidity
function _beforeInitialize(address, PoolKey calldata, uint160)
    internal override returns (bytes4)

function _afterAddLiquidity(
    address, PoolKey calldata, ModifyLiquidityParams calldata,
    BalanceDelta, BalanceDelta, bytes calldata)
    internal override returns (bytes4, BalanceDelta)

function _beforeRemoveLiquidity(
    address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    internal override returns (bytes4)

function _afterRemoveLiquidity(
    address, PoolKey calldata, ModifyLiquidityParams calldata,
    BalanceDelta, BalanceDelta, bytes calldata)
    internal override returns (bytes4, BalanceDelta)

function _afterSwap(
    address, PoolKey calldata, SwapParams calldata,
    BalanceDelta, bytes calldata)
    internal override returns (bytes4, int128)
```

---

## Implementation notes

**afterSwapReturnDelta requires two steps or CurrencyNotSettled reverts.**
Brook calls `poolManager.take()` to claim the fee tokens into the hook contract, then returns the fee amount as `int128`. Both must happen in the same callback execution.

**Swap delta sign convention.**
Positive delta amount means tokens are leaving the pool (output to swapper). Brook identifies the output currency from `params.zeroForOne` — `currency1` when zeroForOne, `currency0` when not.

**HookMiner deployer differs between script and test.**
The deploy script mines against `CREATE2_DEPLOYER` (0x4e59...4956C). Tests mine against `address(this)` because Foundry uses the test contract as the CREATE2 deployer. Using the wrong deployer causes `HookAddressNotValid`.

**v4 unlock and settle pattern.**
The settle sequence for paying into the pool is: `sync(currency)` then `transferFrom(payer, manager, amount)` then `settle()`. To receive tokens from the pool: `take(currency, recipient, amount)`.

**Position key derivation.**
```solidity
keccak256(abi.encode(sender, tickLower, tickUpper, salt))
```
The sender is whoever called `modifyLiquidity` — the router in tests, the position manager in production.

**hookData not available in beforeInitialize.**
This v4-core version does not pass hookData to the initialize function. Brook uses the configurePool two-step pattern instead.

---

## File structure

```
src/
├── Brook.sol                   main hook contract
├── libraries/
│   ├── ScoreLib.sol            computeScore, computeShare, computeVested
│   └── Types.sol               PoolConfig, EpochState, LPState, BrookConstants
└── interfaces/
    └── IBrook.sol              errors, events, view functions

test/
├── Brook.t.sol                 hook lifecycle tests
├── ScoreLib.t.sol              score math unit and fuzz tests
└── utils/
    ├── BaseTest.sol
    ├── Deployers.sol
    └── libraries/
        └── EasyPosm.t.sol

script/
├── DeployBrook.s.sol           CREATE2 mining and chain-aware deploy
└── SeedPool.s.sol              demo pool setup

docs/
└── brook-starter-pack.md       this file

frontend/
└── src/                        Vite + React landing page
```

---

## Deployment

### Supported networks

Brook uses hookmate's `AddressConstants` to resolve the canonical PoolManager on supported chains automatically. On Anvil (chainId 31337) it deploys a fresh PoolManager from bytecode.

Supported chains include Ethereum mainnet, Unichain, Base, Arbitrum, Optimism, Polygon, BNB Smart Chain, Avalanche, Blast, Worldchain, Ink, Soneium, Zora, and Unichain Sepolia (testnet).

### Deploy command

```bash
forge script script/DeployBrook.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY \
  --verify
```

### Unichain Sepolia reference

PoolManager: `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`
RPC: `https://sepolia.unichain.org`
Explorer: `https://explorer.sepolia.unichain.org`

---

## Resources

- Uniswap v4 docs: https://docs.uniswap.org/contracts/v4
- v4-by-example: https://github.com/uniswapfoundation/v4-by-example
- Security Framework: https://github.com/uniswapfoundation/security-framework
- Atrium Academy: https://atrium.academy/uniswap
- Hook directory: https://projects.atrium.academy

---

*Pre-audit, pre-mainnet. Do not use this code to custody real funds.*