# Brook

> A Uniswap v4 hook for predictable, paycheck-style LP yield.

Brook turns lumpy swap fees into a steady, paycheck-style stream of LP yield,
weighted by who actually provided useful liquidity. It makes Uniswap legible to
DAO treasuries, structured products, and serious capital that needs predictable
income — not casino-grade volatility.

---

## The problem

LP income on Uniswap is wildly volatile. Some weeks bring 80% APR, others bring
zero. That volatility is fine for retail farmers, but it disqualifies an entire
class of capital — DAO treasuries, stablecoin LPs, structured product builders,
and institutional players who need legible cash flows for governance, accounting,
and reporting.

Meanwhile, mercenary capital flashes through pools during high-volume moments,
extracts the fat fees, and exits — leaving committed LPs to absorb the volatility
they couldn't time around.

## How Brook works

Each pool runs on fixed epochs (default: 7 days).

**During an epoch**, Brook diverts a small fraction of swap fees into a buffer
instead of distributing them immediately.

**At each epoch rollover**, the previous epoch's buffer becomes the next epoch's
payout pool, streamed linearly to LPs over its duration.

**LPs receive payouts** in proportion to their *useful liquidity score* — how
much of the epoch they were both deposited *and* in-range. LPs who commit and
stay in-range earn meaningfully more than mercenary capital that parks
out-of-range for show.

```
[Pool actions]                     [Hook actions]
swap occurs           ──→          skim fee → epoch buffer
LP deposits           ──→          start tracking time + ticks
LP withdraws          ──→          settle score before exit

         All of this updates the [Epoch state]:

  ┌─────────────────────────────────────────────────────────┐
  │ Buffer (epoch N)  ──rollover──→  prevBuffer (epoch N−1)  │
  │ accumulating now                 streaming now           │
  └─────────────────────────────────────────────────────────┘
                                                │
                                                ▼
[Useful liquidity score]  ──feeds──→  [LP claim]
liquidity × inRangeTime               share = score / totalScore
+ partial out-of-range credit         × elapsed / epochLength
```

At any moment, **two epochs are alive**: one filling with fees, one streaming
out to LPs. Even if this week sees zero swaps, last week's buffer is still
paying out. That's the smoothing.

## Why "paycheck-style"

A paycheck is what makes capital usable for planning. You can budget against it.
You can build on top of it. You can show it to a treasury committee without
flinching. Brook gives LPs the closest thing to a paycheck the AMM world has —
a predictable, time-vested, fairly-weighted income stream backed by real
protocol fees.

## Who Brook is for

- **DAO treasuries** providing liquidity to their own token's pool
- **Stablecoin LPs** seeking predictable, low-volatility yield
- **LST / LRT pools** (stETH/ETH, weETH/ETH, and similar)
- **Token projects** seeding their own liquidity with long-term alignment
- **Structured product builders** wanting smooth underlying for LP bonds and fixed-rate vaults
- **Yield aggregators** needing a stable APR number to display
- **Institutional / RWA pools** where balance-sheet-grade cash flows matter

### Who Brook is NOT for

- Speculators and degens — fee volatility is what they're hunting
- Memecoin pools — volatility is the product
- Anyone LPing for less than a few days — the epoch model assumes commitment

## Differentiator

Most fee-distribution mechanics treat all liquidity equally. Brook rewards LPs
in proportion to how much *useful* liquidity they actually provided. With the
default in-range multiplier, an LP who stayed in-range the full epoch earns
roughly 2.3x more than one who was only in-range 25% of the time.

The math:

```
score = liquidity × (inRangeTime + (totalTime − inRangeTime) / inRangeMultiplier)
```

Out-of-range LPs still earn something — Brook isn't punitive — but the committed,
useful liquidity earns the lion's share of the buffer.

## Project status

UHI9 cohort capstone (April–June 2026). Pre-audit, pre-mainnet.

This is research-grade code being developed inside the Uniswap Hook Incubator.
It will be deployed to testnet during the cohort and demoed at UHI9 Demo Day on
June 19, 2026. Mainnet deployment, formal audit, and production usage are
post-cohort milestones.

## Quickstart

```bash
forge install
forge build
forge test
```

Foundry stable is required (not nightly — see the v4-template README for why).
Run `foundryup` if you're unsure which version you have.

## Project structure

```
src/
├── Brook.sol                   main hook contract
├── libraries/
│   ├── EpochMath.sol          rollover and vesting math
│   └── ScoreLib.sol           useful-liquidity score function
└── interfaces/
    └── IBrook.sol              public-facing interface

test/
├── Brook.t.sol                 unit tests
├── Brook.fuzz.t.sol            fuzz and invariant tests
└── Brook.fork.t.sol            mainnet-fork integration tests

script/
├── DeployBrook.s.sol           CREATE2 address mining + deploy
└── SeedPool.s.sol              demo pool setup

docs/
└── brook-starter-pack.md       mechanism, architecture, and full roadmap

frontend/                       Next.js demo (added in PR #21)
```

## Documentation

The full mechanism design, hook permissions, data model, attack surface, and
roadmap live in [`docs/brook-starter-pack.md`](docs/brook-starter-pack.md).

## Roadmap

Brook is being built across 22 PRs grouped into four phases:

1. **Foundations** (PRs 1–3) — repo scaffold, empty hook, address mining
2. **Data model and initialization** (PRs 4–7) — structs, beforeInitialize, position keys, afterAddLiquidity
3. **The mechanism** (PRs 8–13) — score function, in-range accumulator, fee skim, epoch rollover, claim flow
4. **Hardening and demo** (PRs 14–22) — security, fuzz tests, deployment, frontend, pitch

See the full PR breakdown in [`docs/brook-starter-pack.md`](docs/brook-starter-pack.md).

## Built during

[**UHI9**](https://atrium.academy/uniswap) — the ninth cohort of the Uniswap
Hook Incubator, run by Atrium Academy and funded by the Uniswap Foundation.

## Acknowledgments

- Built on the [Uniswap Foundation v4 template](https://github.com/uniswapfoundation/v4-template)
- Mechanism inspired by Curve gauges, Sablier streams, and bond coupon design
- Theme guidance from UHI9's "Impermanent Loss and Yield Systems" track

## License

BUSL-1.1 — matches Uniswap v4 core licensing. Converts to GPL after up to four
years.

---

*Brook is a work in progress. The code in this repo is not yet ready for
production use, has not been audited, and should not custody real funds.