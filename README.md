# CASTLE

A launchpad on Robinhood Chain where anyone can launch a token, optionally
tethered to a real property-class coin — a tin storage shed, a friend's
couch, an RV, a villa, a high-rise unit, or plain ETH with no class at
all. A launch mints its full supply straight into a real Uniswap v4 pool
in the same transaction — there's no migration step and nothing ever
sells out. Trading always looks like connect a wallet, send ETH, get
tokens: no approval step, no minting, whether or not a class is picked —
picking one just means the market trades against that class's coin for
its whole life instead of ETH.

**Status: real Uniswap v4 integration, tested against both a real
(locally-deployed) `PoolManager` and the actual live Robinhood Chain
mainnet `PoolManager` itself — see [DEPLOY.md](DEPLOY.md) for deploying.
Still unaudited.** See
[What this repo doesn't do yet](#what-this-repo-doesnt-do-yet) below
before you point real money at any of this.

## Live pages

- `index.html` / `browse.html` — markets home, with a live list of every launch read straight from chain
- `classes.html` — buy/sell any of the 20 property-class coins (or USDG) directly, against ETH
- `launch.html` — the create-a-market form, with an optional (static-tier) property class
- `market.html?launch=<id>` — a single market's live state, buy/sell, recent trades, and holder-reward claim
- `coin.html?coin=TICKER` — a single property-class coin's own page: rate, supply chart, activity, mint/redeem
- `docs.html` — how it works (mechanics, fees, the peg)

Open `index.html` directly in a browser, or serve the folder statically
(`npx serve .`, GitHub Pages, Vercel, etc.) — there's no build step.

## Repo layout

```
parcel-launch/
├─ index.html, browse.html, classes.html, launch.html, market.html, coin.html, docs.html
├─ assets/
│  ├─ style.css      — design tokens + layout (blueprint/deed aesthetic)
│  ├─ classes.js      — the 20 property classes: ticker, label, unit, tier, icon config
│  └─ app.js          — wallet connect, ABIs, chain reads/writes for launches, coins, and markets
├─ contracts/
│  ├─ ParcelToken.sol         — fixed-supply ERC20 minted once per launch; pull-based holder rewards
│  ├─ Launchpad.sol           — singleton: mints a launch's supply into a real v4 pool (curve + reserve ranges), collects/splits fees
│  ├─ LaunchRouter.sol        — the ongoing buy/sell entry point after a launch, mints/burns the class coin under the hood
│  ├─ FeeHook.sol             — minimal v4 hook, stamps each pool with the creator's fee, nothing else
│  ├─ Buyback.sol             — permissionless swap-and-burn of the buyback fee cut against the platform token
│  ├─ PropertyClassCoin.sol   — static-tier peg: fully-collateralized ETH mint/redeem (6 classes + USDG)
│  ├─ PegPool.sol             — live-tier peg: single-sided v4 ask + harvested-reserves sell (14 classes)
│  ├─ LiveClassCoin.sol       — the ERC20 a PegPool mints/burns; no direct mint/redeem of its own
│  └─ libraries/              — LiquidityAmounts, LaunchMath (tick/price sizing helpers)
├─ script/
│  ├─ Deploy.s.sol            — testnet deploy (needs POOL_MANAGER env var — see DEPLOY.md)
│  ├─ DeployMainnet.s.sol     — mainnet deploy, real PoolManager + real USDG
│  ├─ DeployCommon.sol        — shared deploy logic both scripts call
│  └─ HookMiner.sol           — CREATE2 salt mining for the fee hook's address flags
├─ deployments/{testnet,mainnet}.json — live addresses, read by assets/app.js at page load
├─ test/Launchpad.t.sol       — Foundry tests against a real locally-deployed Uniswap v4 PoolManager
├─ test/PegPool.t.sol         — same, for the live-tier peg (ask/sell/harvest/reposition)
├─ test/Fork.t.sol            — same key scenarios, re-run against the real mainnet PoolManager (needs network)
├─ foundry.toml, remappings.txt, .env.example
├─ DEPLOY.md                  — full deployment walkthrough (testnet + mainnet)
└─ LICENSE
```

## How a launch works

Full version is on `docs.html`; short version:

1. A launch mints 1,000,000,000 tokens directly into a new Uniswap v4
   pool, as two concentrated liquidity ranges seeded in the same
   transaction: 800,000,000 tokens from a $5,000 opening cap to a $35,000
   cap (the "curve"), and 200,000,000 tokens in a reserve range above the
   cap, so the pool keeps quoting with no cliff once it's crossed. This is
   identical whether or not a property class is picked, and there is no
   migration step — it's real liquidity from block one.
2. The creator picks a trading fee (1%–3%), optionally picks a property
   class — the market trades against that class's coin for its whole life
   — and sends their first buy — any amount of ETH — in the same
   transaction that creates the market.
3. Trading never stops: selling works exactly the same whether the price
   sits inside the curve range or has moved into the reserve range above
   the cap, since it's the same real AMM liquidity throughout.
4. Every trade's LP fee splits 40% holders / 30% buyback / 30% protocol.
   Anyone can permissionlessly call `collectFees()` to pull a market's
   accrued fees and route them; holders then call `claimRewards()` on the
   token any time (pull-based, no keeper). The buyback share is swapped
   for the platform token and burned — also permissionless.

## Property-class coins

Each of the 20 classes in `assets/classes.js`, plus USDG, is a real coin,
not just a label — split into two tiers:

- **Static tier** (couch, tent, shed, lean-to, van, shanty — no real
  market to track): a `PropertyClassCoin`. `mint()` takes ETH and issues
  coin at a **fixed, immutable rate** set once at deployment; `redeem()`
  burns coin for exactly the ETH backing it. No oracle, fully
  collateralized by construction.
- **Live tier** (the other 14 — housing, farmland, RVs, and similar, all
  with genuine if infrequently-published reference data): a `PegPool`. A
  mutable-rate mint/redeem contract would be unsound here (a rate
  increase could leave it unable to honor old, lower-rate deposits), so
  these coins are never redeemed at a promised rate at all — see
  `contracts/PegPool.sol`'s top comment for the real mechanism (a
  single-sided, router-composable Uniswap v4 ask, and sells capped
  exactly at ETH the pool has actually harvested from it).

You can buy/sell any of these directly on `classes.html`, whether or not
you ever launch anything — though only static-tier classes can currently
be picked as a launch's pairing (`Launchpad` expects the fixed-rate
mint/redeem interface a PegPool-backed coin doesn't implement).

## Local setup (contracts)

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts Uniswap/v4-core --no-commit
forge build
forge test --no-match-path 'test/Fork.t.sol'   # network-free
forge test                                     # includes the fork suite too (needs network)
```

`test/Launchpad.t.sol` and `test/PegPool.t.sol` deploy a real `PoolManager`
from the vendored `v4-core` source for every test — no network access or
mock needed to exercise genuine Uniswap v4 settlement, liquidity, and swap
mechanics (including the zero-liquidity reprice trick
`PegPool.reposition()` relies on). `test/Fork.t.sol` re-runs the key
scenarios from both against the **real, currently-deployed** mainnet
`PoolManager` (via `vm.createSelectFork` — read-only simulation, nothing
broadcast or spent) to catch anything a freshly-deployed local instance
wouldn't: a different version, owner, or fee configuration than the
vendored source assumes. It needs network access to
`rpc.mainnet.chain.robinhood.com`; skip it with the flag above if you're
offline.

## Deploying

See **[DEPLOY.md](DEPLOY.md)** for the full walkthrough, including a
pre-mainnet checklist and how to rehearse the deploy script against a
local fork before it touches anything real. Short version:

```bash
cp .env.example .env   # fill in PRIVATE_KEY
PROTOCOL_TREASURY=0x... forge script script/DeployMainnet.s.sol --rpc-url robinhood_mainnet --broadcast
git add deployments/mainnet.json && git commit -m "Deploy to mainnet" && git push
```

`assets/app.js` fetches the deployment file matching the connected
wallet's chain on every page load — once it has a real `launchpad`
address in it, `launch.html` switches from previewing terms to actually
submitting a `createLaunch` transaction. `DEPLOY.md` also covers
deploying this same stack to a pre-production network first, for anyone
who wants to exercise it before mainnet.

