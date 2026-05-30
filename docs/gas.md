# Brook — Gas Reference

> Baseline snapshot generated from PR #15. All figures from Foundry test suite
> with via_ir = true and Solc 0.8.30 on the Cancun EVM.
>
> Test gas figures include full test infrastructure overhead (PoolManager deploy,
> token setup, liquidity provision). Hook-only costs are extracted estimates.

---

## Hook callback costs (estimated)

| Callback | Estimated hook gas | Trigger |
|---|---|---|
| `beforeInitialize` | ~30k | Once per pool creation |
| `afterAddLiquidity` | ~50k | Every LP deposit |
| `beforeRemoveLiquidity` | ~25k | Every LP withdrawal |
| `afterRemoveLiquidity` | ~30k | Every LP withdrawal |
| `afterSwap` (no rollover) | ~60k | Every swap |
| `afterSwap` (with rollover) | ~80k | First swap after epoch ends |
| `claim` | ~120k | On-demand by LP |

---

## Key observations

**afterSwap is the hot path.** It fires on every swap and does the most work:
reads epoch state, checks rollover, computes fee skim, calls `poolManager.take`,
reads current tick via `StateLibrary.getSlot0`, updates three storage slots.
At ~60k gas it adds meaningful but acceptable overhead per swap.

**Rollover costs ~20k extra.** When an epoch rolls over, Brook writes
`prevBuffer`, resets `buffer`, `totalScore`, and emits an event.
This happens at most once per epoch (lazily on first swap after epoch ends).

**claim is the most expensive user-facing call.** At ~120k it reads from
multiple storage mappings, calls `ScoreLib.computeScore`, `computeShare`,
and `computeVested`, then does a token transfer. Acceptable for a call
users make at most once per epoch.

**configurePool is cheap.** ~20k for the validation + storage write.
Only called once per pool.

---

## Snapshot baseline (PR #15)

Raw gas figures from `forge snapshot` — full test gas including infrastructure.
Use for regression detection only, not for absolute hook cost estimation.

```
test_afterSwap_accumulates_fees_in_buffer         659524
test_afterSwap_emitsFeesSkimmed                   655350
test_afterSwap_epochRolloverMovesBuffer           784423
test_afterSwap_multipleSwapsAccumulate            777593
test_afterAddLiquidity_initializesNewPosition     451046
test_afterAddLiquidity_topsUpExistingPosition     530304
test_beforeRemoveLiquidity_settlesTotalTime       525794
test_afterRemoveLiquidity_reducesLiquidity        539473
test_beforeInitialize_locksConfig                 113253
test_claim_payoutAfterEpochRollover               1014213
test_claim_secondClaimOnlyVestsAdditional         873037
test_edge_outOfRangeLP_stillEarnsPartialYield     982960
test_edge_singleLP_gets100PercentOfBuffer         936284
```

---

## Known optimization opportunities (post-audit)

**1. Cache poolId computation.**
`keccak256(abi.encode(key))` is computed in every callback. With `via_ir = true`
the compiler often optimizes this, but an explicit cache would guarantee it.

**2. Pack EpochState more tightly.**
`EpochState` currently uses two storage slots. Packing `totalScore` and
`lastUpdateTime` into a single slot with `currentTick` and `lastSkimAmount`
could save one SLOAD/SSTORE per swap.

**3. Reduce StateLibrary.getSlot0 call.**
`_processSwap` calls `poolManager.getSlot0` to read the current tick.
This is an `extsload` call to the PoolManager. On most swaps where the tick
doesn't change, this is an expensive no-op. Could be gated on a price change
threshold.

These are deferred to post-audit to avoid introducing bugs under time pressure.

---

## Acceptability assessment

Brook adds approximately 60k gas per swap in the base case. For context:

- A standard v4 swap costs roughly 100-150k gas
- Brook's overhead represents 30-40% additional cost
- This is on the higher end for a hook but justified by the mechanism complexity
- For pools targeting committed institutional LPs who value predictable yield,
  this overhead is acceptable
- Gas costs will decrease as the EVM evolves and as post-audit optimizations land

---

*Pre-audit figures. Gas costs may change with compiler updates or contract changes.*

