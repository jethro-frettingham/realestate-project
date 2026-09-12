# Deploying Parcel

Deploys the full stack — `FeeHook`, `Launchpad`, `LaunchRouter`, `Buyback`,
the platform token (bootstrapped as its own launch), USDG (or a stand-in
on testnet), and all 20 property classes — and wires the live site to it
automatically. Six classes (couch, tent, shed, lean-to, van, shanty) are
static `PropertyClassCoin`s, fixed at deploy time from a flat assumed
ETH/USD rate, no oracle. The other 14 are `PegPool`-backed and get
`initialize()`d at that same starting rate, then repriced later by
whoever you set as `LIVE_TIER_UPDATER` (see below) — see
`contracts/PegPool.sol` for the mechanism.

Both networks use the **same contracts**; only the target `PoolManager`
address, chain id, and (on mainnet) the real USDG address differ.

Robinhood Chain Testnet:

| | |
|---|---|
| Chain ID | `46630` |
| RPC | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://explorer.testnet.chain.robinhood.com` |
| Faucet | `https://faucet.testnet.chain.robinhood.com` |
| Gas token | ETH |

Robinhood Chain mainnet:

| | |
|---|---|
| Chain ID | `4663` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| Gas token | ETH |

## 1. Install Foundry

In Git Bash (Foundry doesn't support PowerShell or Cmd directly):

```bash
curl -L https://foundry.paradigm.xyz | bash
```

Close and reopen Git Bash so `foundryup` is on your PATH, then:

```bash
foundryup
```

Check it worked:

```bash
forge --version
```

## 2. Install contract dependencies

From the repo root:

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts Uniswap/v4-core --no-commit
```

`Uniswap/v4-core` is the real v4 singleton `PoolManager` and libraries —
this repo talks to it directly rather than through a mock.

## 3. Set up a deployer wallet

Use a **throwaway wallet** for testnet. For mainnet, use a wallet you
actually control and are prepared to spend real ETH from — deploying
bootstraps the platform token with a real first buy (`PLATFORM_FIRST_BUY_WEI`,
default 0.05 ETH on mainnet).

1. Create a wallet (or use an existing one for mainnet) and copy its
   address and private key.
2. `cp .env.example .env` and paste the private key in as `PRIVATE_KEY`
   — **with a `0x` prefix**, which MetaMask's copy doesn't include by
   default (`PRIVATE_KEY=0xabc123...`). `.env` is already in
   `.gitignore` — it should never be committed.
3. Fund it. Testnet: get ETH from
   [faucet.testnet.chain.robinhood.com](https://faucet.testnet.chain.robinhood.com)
   — this deploys ~35 contracts (20 class coins/PegPools, each PegPool
   deploying its own coin, plus the core stack) and the platform token's
   bootstrap buy; still cheap but get more than a trivial amount. Mainnet:
   fund with real ETH covering gas for all of that plus the first-buy
   amount.
4. Decide who operates the 14 live-tier `PegPool`s going forward — see
   `LIVE_TIER_UPDATER` below. For a real deployment this should be a
   multisig you've already set up, not a single EOA, since the role is
   set immutably at each PegPool's construction and can't be rotated
   later without deploying new pools.

## 4a. Deploy to testnet

```bash
POOL_MANAGER=0x... LIVE_TIER_UPDATER=0x... forge script script/Deploy.s.sol \
  --rpc-url robinhood_testnet --broadcast
```

`POOL_MANAGER` must be Uniswap v4's `PoolManager` address on Robinhood
Chain Testnet. **This repo does not hardcode a guess for it** — look it
up yourself (the testnet explorer, or Uniswap's own deployments docs)
before running this. Getting it wrong means the deploy either reverts
harmlessly or, worse, points at something that isn't actually the real
`PoolManager`.

`LIVE_TIER_UPDATER` (optional, defaults to the deployer) is the address
authorized to call `reposition()` on the 14 live-tier PegPools later.
Because that role is set immutably at each PegPool's construction *and*
`initialize()` (called during this same deploy) must be sent by that same
address, this **must equal `PRIVATE_KEY`'s own address** unless you're
broadcasting this script as that other account — there's no way to
"deploy as one key, assign the role to another" in one step.

This writes every address to `deployments/testnet.json` (class coins
under a `classCoins` map, PegPools under a `pegPools` map — nonzero only
for the 14 live-tier tickers — both keyed by ticker).

## 4b. Deploy to mainnet

**Do this only after**: the full test suite passes (`forge test`,
including `test/Fork.t.sol` — already re-verified during development
against the real, currently-deployed mainnet `PoolManager`: create-launch,
buy, the post-cap sell, fee collection/reward claim, and the full PegPool
ask/harvest/reposition cycle all pass against its actual bytecode, not
just a freshly-deployed local instance), you've run through a local-fork
*deployment* dry run (see below — the fork tests exercise the contract
logic against real state, but not the deploy script itself, which is a
separate thing to rehearse before it touches anything real), and you've
independently re-verified the two hardcoded addresses in
`script/DeployMainnet.s.sol`:

- `POOL_MANAGER` — cross-checked during development against a CME
  reference page that listed the same address, and confirmed to have
  real contract bytecode on-chain via `eth_getCode` and to pass the full
  fork test suite. Still worth a final check against Robinhood's or
  Uniswap's own docs before spending real money.
- `USDG` — sourced from a single web search during development, and
  confirmed to have real (proxy) contract bytecode on-chain, but its
  *behavior* wasn't independently exercised the way `PoolManager`'s was.
  **Verify the address itself against docs.paxos.com/guides/stablecoin/usdg/mainnet
  or Robinhood's own docs before broadcasting.** This is meant to be the
  real, Paxos-issued Global Dollar — never a stand-in.
- The canonical CREATE2 deployer
  (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, used for `FeeHook`'s
  CREATE2 deploy) — also confirmed present on-chain via `eth_getCode`,
  matching its well-known bytecode.

```bash
PROTOCOL_TREASURY=0x... LIVE_TIER_UPDATER=0x... forge script script/DeployMainnet.s.sol \
  --rpc-url robinhood_mainnet --broadcast
```

`PROTOCOL_TREASURY` is the address that receives the 30% protocol fee
cut — typically a multisig you control, not the deployer EOA.
`LIVE_TIER_UPDATER` works exactly as described in step 4a above — for
mainnet this really should be a multisig, and it must equal whatever
address `PRIVATE_KEY` broadcasts as.

This writes every address to `deployments/mainnet.json`.

### Rehearse the deploy script itself against an anvil fork first (strongly recommended before 4b)

`test/Fork.t.sol` (above) proves the contracts behave correctly against
real mainnet state — it does not exercise `DeployMainnet.s.sol` itself
(the CREATE2 salt mining, the address-prediction ordering, the
first-buy/buyback bootstrap sequence). Rehearsing the actual script
against a local anvil fork is the way to catch a mistake there before it
costs anything real — nothing here is broadcast anywhere but your own
machine:

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com
# in another terminal, against the anvil RPC (usually http://127.0.0.1:8545):
PROTOCOL_TREASURY=0x... forge script script/DeployMainnet.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

Then exercise a full lifecycle against that local fork: create a launch,
buy through the cap into the reserve range, sell back down, claim holder
rewards, trigger a buyback — all before spending anything for real.

If deployment fails partway through, it's almost always one of:
- **Insufficient funds** — get more ETH.
- **`PRIVATE_KEY` not set or missing its `0x` prefix** — check `.env`.
- **Dependency not found** — re-run step 2.
- **Wrong `POOL_MANAGER`** (testnet) — the `initialize` call will revert
  against a contract that isn't a real `PoolManager`.

## 5. Commit the deployment record

```bash
git add deployments/testnet.json   # or deployments/mainnet.json
git commit -m "Deploy to Robinhood Chain Testnet"   # or "...mainnet"
git push
```

`assets/app.js` fetches `deployments/testnet.json` or `mainnet.json` at
page load, picking based on the connected wallet's chain (testnet by
default). Once the right file is pushed, `launch.html` switches from the
"preview mode" notice to actually calling `createLaunch` on the deployed
`Launchpad` — Connect Wallet will also offer to add the right Robinhood
Chain network if it isn't already there.

## 6. Test a launch

Launching needs nothing but ETH — no minting, no approvals, whether or
not you pick a class. On `launch.html`: connect a wallet holding ETH,
fill in a name and ticker, optionally pick a property class, enter a
first-buy amount, and submit. One transaction: the full supply is minted
straight into a real Uniswap v4 pool and your first buy executes in the
same call.

To buy/sell a property-class coin directly (not through a launch), use
`classes.html` — same pattern, pick a coin, buy with ETH or sell back to
ETH at its fixed rate.

To interact from the command line instead (e.g. to script a test buy on
an existing launch — replace `<launch id>` with the id from a
`LaunchCreated` event or the explorer, and `<router address>` with
`deployments/*.json`'s `launchRouter`):

```bash
cast send <router address> "buy(uint256,uint256)" <launch id> 0 \
  --value 0.1ether --rpc-url robinhood_testnet --private-key $PRIVATE_KEY
```

To pull a market's accrued fees and let holders claim (permissionless,
callable by anyone):

```bash
cast send <launchpad address> "collectFees(uint256)" <launch id> \
  --rpc-url robinhood_testnet --private-key $PRIVATE_KEY
cast send <token address> "claimRewards()" \
  --rpc-url robinhood_testnet --private-key $PRIVATE_KEY
```

## Operating the live-tier PegPools

There is no automated feed for these — none of the underlying sources
(Redfin/NAR/Census for housing, USDA/LandSearch/Purdue for farmland, RV
pricing guides, ...) publish faster than monthly, so a live oracle would
be solving a problem that doesn't exist here. When one of them publishes
a new number, whoever holds `LIVE_TIER_UPDATER`'s key runs
`script/RepositionLiveTier.s.sol` by hand:

```bash
TICKER=HOUS USD_PRICE=445000 ETH_USD=3500 \
PRIVATE_KEY=$LIVE_TIER_UPDATER_KEY \
  forge script script/RepositionLiveTier.s.sol \
  --rpc-url robinhood_mainnet --broadcast
```

- `TICKER` — one of the 14 live-tier tickers (RV, TRLR, TINY, CTNR, CABN,
  CNDO, HOUS, DPLX, TOWN, VILA, MANR, FARM, COMM, HIRS). The script looks
  up that class's PegPool address itself from `deployments/mainnet.json`
  (or pass `DEPLOYMENT_FILE=deployments/testnet.json` to target testnet
  instead) — no need to look up or paste a raw contract address.
- `USD_PRICE` — the new reference price in whole dollars (e.g. `445000`
  for $445,000), not wei. The script converts it.
- `ETH_USD` — today's actual ETH/USD price (Coinbase, CoinGecko, whatever
  you'd normally check). Unlike the property indices, this one genuinely
  moves by the hour, so it's supplied fresh on every run rather than read
  back from the deployment file's static `ethUsd` field.

Equivalent raw `cast` command, if you'd rather skip the script (you'll
need the pegpool address from `deployments/*.json`'s `pegPools` map and
to do the USD→wei conversion yourself:
`usdPrice * 1 ether / ethUsd`):

```bash
cast send <pegpool address> "reposition(uint256)" <new wei-per-unit> \
  --rpc-url robinhood_testnet --private-key $LIVE_TIER_UPDATER_KEY
```

Separately, **anyone** can call `harvest()` on a PegPool at any time to
pull ETH out of its ask position and into `ethReserves`, making it
available for sellers to draw on — this doesn't need the updater key:

```bash
cast send <pegpool address> "harvest()" \
  --rpc-url robinhood_testnet --private-key $PRIVATE_KEY
```

## Redeploying

Re-running a deploy script deploys a fresh set of everything and
overwrites the corresponding `deployments/*.json` — old launches created
against the previous `Launchpad` stop showing up anywhere new, since
`index.html`'s markets list reads live from the *current* `Launchpad`'s
on-chain array. Commit and push again after any redeploy. On mainnet,
this also means spending the first-buy ETH again to bootstrap a new
platform token — treat a mainnet redeploy as a last resort, not routine.
