# Brook

> A Uniswap v4 hook for predictable, paycheck-style LP yield.

Brook turns lumpy swap fees into a steady, paycheck-style stream of LP yield, weighted by who actually provided useful liquidity. It makes Uniswap legible to DAO treasuries, structured products, and serious capital that needs predictable income, not casino-grade volatility.

---

## The problem

LP income on Uniswap is wildly volatile. Some weeks bring 80% APR, others bring zero. That volatility is fine for retail farmers, but it disqualifies an entire class of capital — DAO treasuries, stablecoin LPs, structured product builders, and institutional players who need legible cash flows for governance, accounting, and reporting.

Meanwhile, mercenary capital flashes through pools during high-volume moments, extracts the fat fees, and exits — leaving committed LPs to absorb the volatility they couldn't time around.

---

## How Brook works

Each pool runs on fixed epochs (default: 7 days).

During an epoch, Brook diverts a fraction of swap fees into a buffer instead of distributing them immediately.

At each epoch rollover, the previous epoch's buffer becomes the next epoch's payout pool, streamed linearly to LPs over its duration.

LPs receive payouts in proportion to their **useful liquidity score** — how much of the epoch they were both deposited and in-range. LPs who commit and stay in-range earn meaningfully more than mercenary capital that parks out-of-range for show.

```
swap occurs      →   fee skimmed into epoch buffer
LP deposits      →   entry time and tick range recorded
LP withdraws     →   score settled before exit

         ┌────────────────────────────────────────────┐
         │  Buffer (epoch N)   →rollover→  prevBuffer  │
         │  filling now                  streaming now │
         └────────────────────────────────────────────┘
                                               │
                                               ▼
         score = liquidity × inRangeTime   →  LP claim
```

At any moment two epochs are alive: one filling with fees, one streaming out to LPs. Even if this week sees zero swaps, last week's buffer is still paying out. That is the smoothing.

---

## Why "paycheck-style"

A paycheck is what makes capital usable for planning. You can budget against it. You can build on top of it. You can show it to a treasury committee without flinching. Brook gives LPs the closest thing to a paycheck the AMM world has — a predictable, time-vested, fairly-weighted income stream backed by real protocol fees.

---

## Who Brook is for

- DAO treasuries providing liquidity to their own token's pool
- Stablecoin LPs seeking predictable, low-volatility yield
- LST and LRT pools (stETH/ETH, weETH/ETH, and similar)
- Token projects seeding their own liquidity with long-term alignment
- Structured product builders wanting smooth underlying for LP bonds and fixed-rate vaults
- Yield aggregators needing a stable APR number to display
- Institutional and RWA pools where balance-sheet-grade cash flows matter

Brook is not for speculators, memecoin pools, or anyone LPing for less than a few days. The epoch model assumes commitment.

---

## The score function

Most fee-distribution mechanics treat all liquidity equally. Brook rewards LPs in proportion to how much *useful* liquidity they actually provided.

```
score = liquidity × (inRangeTime + (totalTime − inRangeTime) / inRangeMultiplier)
```

With the default multiplier of 4, an LP who stayed in-range the full epoch earns roughly 2.3x more than one who was only in-range 25% of the time. Out-of-range LPs still earn something — Brook is not punitive — but committed, useful liquidity earns the lion's share.

---

## Project status

UHI9 cohort capstone (April–June 2026). Pre-audit, pre-mainnet.

Being developed inside the Uniswap Hook Incubator. Testnet deployment is scheduled during the hookathon. Demo Day is June 19, 2026. Mainnet deployment, formal audit, and production usage are post-cohort milestones.

---

## Quickstart

```bash
forge install
forge build
forge test
```

Foundry stable is required (not nightly). Run `foundryup` to update.

---

## Project structure

```
src/
├── Brook.sol                   main hook contract
├── libraries/
│   ├── ScoreLib.sol            useful-liquidity score, share, and vesting math
│   └── Types.sol               PoolConfig, EpochState, LPState structs + BrookConstants
└── interfaces/
    └── IBrook.sol              public-facing interface, events, and errors

test/
├── Brook.t.sol                 unit and integration tests
├── ScoreLib.t.sol              score function unit and fuzz tests
└── utils/                      shared test helpers (Deployers, BaseTest, EasyPosm)

script/
├── DeployBrook.s.sol           CREATE2 address mining + deploy
└── SeedPool.s.sol              demo pool setup (coming soon)

docs/
└── brook-starter-pack.md       mechanism design, architecture, and full roadmap

frontend/
└── src/                        Vite + React landing page (live on Netlify)
```

---

## Roadmap

Brook is being built across four phases:

**Phase 1 — Foundations** · repo scaffold, address mining, deploy script

**Phase 2 — Pool lifecycle** · beforeInitialize, afterAddLiquidity, beforeRemoveLiquidity, afterRemoveLiquidity

**Phase 3 — The mechanism** · score function, fee skim, epoch rollover, claim flow

**Phase 4 — Hardening and demo** · fuzz tests, testnet deployment, frontend demo, pitch

---

## Built during

[UHI9](https://atrium.academy/uniswap) — the ninth cohort of the Uniswap Hook Incubator, run by Atrium Academy and funded by the Uniswap Foundation.

---

## Acknowledgments

- Built on the [Uniswap Foundation v4 template](https://github.com/uniswapfoundation/v4-template)
- Mechanism inspired by Curve gauges, Sablier streams, and bond coupon design
- Theme: UHI9 "Impermanent Loss and Yield Systems"

---

## License

BUSL-1.1 — matches Uniswap v4 core licensing. Converts to GPL after up to four years.

---

*Pre-audit, pre-mainnet. Do not use this code to custody real funds.*