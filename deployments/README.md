# Brook Deployments

Brook is architected to run on any chain that supports Uniswap v4. The hook contains
no chain-specific logic; the canonical PoolManager for each chain is resolved
automatically at deploy time via hookmate's `AddressConstants`. Deploying to a new
chain is a matter of pointing the scripts at that chain's RPC and letting the salt
miner produce a hook address that encodes the correct permission flags.

## Live deployments

| Chain | Chain ID | Status | Brook | Router |
|-------|----------|--------|-------|--------|
| Unichain Sepolia | 1301 | **Live & verified** | `0xef91EAf413170cAD2f65B3f05E969759df0AA744` | `0x57b79d383E951227C9d0479eFd031a7Ca73fB81e` |
| Base Sepolia | 84532 | Ready to deploy | — | — |

See the per-chain JSON files in this folder for full details.

## Why deploying to a new chain is not just "add an RPC"

Uniswap v4 encodes a hook's permissions in its contract address. Brook requires a
specific set of permission bits (beforeInitialize, afterAddLiquidity,
beforeRemoveLiquidity, afterRemoveLiquidity, afterSwap, afterSwapReturnDelta), so
each chain needs a CREATE2 salt mined such that the resulting address carries exactly
those bits. `DeployBrook.s.sol` does this automatically per chain — but it is a real
mining step, not a config toggle. Once the hook is deployed, the router is a standard
periphery deploy, and an optional demo pool can be seeded.

## Deploying to a new chain (e.g. Base Sepolia)

Prerequisites: an RPC URL for the target chain, a funded deployer key, and (if you
want a demo pool) a little gas in a demo wallet.

```bash
# 1. Environment
export RPC_URL=https://sepolia.base.org
export PRIVATE_KEY=<deployer key>

# 2. Deploy Brook (mines a fresh CREATE2 salt for this chain)
forge script script/DeployBrook.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY

# 3. Deploy the router, pointing at the Brook address from step 2
forge script script/DeployRouter.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY \
  --sig "run(address)" \
  --tc DeployRouter \
  <BROOK_ADDRESS>

# 4. (Optional) Seed a self-serve demo pool, run as the demo wallet
forge script script/DemoSetup.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --private-key $DEMO_KEY \
  --sig "run(address,address)" \
  --tc DemoSetup \
  <BROOK_ADDRESS> <ROUTER_ADDRESS>
```

After deploying, record the addresses in the chain's JSON file and (if you want the
app to serve that chain) fill the corresponding entry in `frontend/src/App.jsx`
`CHAINS` config and set `live: true`.

## Supported chains

`DeployBrook.s.sol` recognises canonical Uniswap v4 PoolManagers on: Ethereum
mainnet, Optimism, BNB Smart Chain, Unichain, Polygon, Worldchain, Unichain Sepolia,
Base Sepolia, Soneium, Base, Arbitrum One, Avalanche, Ink, Blast, and Zora. On an
unknown chain (e.g. a local Anvil node) it deploys a fresh PoolManager from bytecode.
