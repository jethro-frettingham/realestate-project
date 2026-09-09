# Parcel

A launchpad on Robinhood Chain where anyone can launch a token, optionally
tethered to a real, statically-pegged property-class coin — a tin storage
shed, a friend's couch, an RV, a villa, a high-rise unit, or plain ETH with
no class at all. Trading on the curve is always plain ETH: connect a
wallet, send ETH, get tokens. No approval step, no minting, whether or not
a class is picked — picking one only changes what migration seeds once
the curve sells out.

**Status: the contracts are real and deployable to Robinhood Chain
Testnet — see [DEPLOY.md](DEPLOY.md) — and the front end wires up to a
live deployment automatically. Still unaudited, testnet-only.** See
[What this repo doesn't do yet](#what-this-repo-doesnt-do-yet) below
before you point real money at any of this.

## Live pages

- `index.html` — markets home, with a live list of every launch read straight from chain
- `classes.html` — buy/sell any of the 20 property-class coins (or USDG) directly, against ETH, at their fixed rate
- `launch.html` — the create-a-market form, with an optional property class
- `market.html?curve=0x...` — a single market's live state, buy/sell, and recent trades
- `coin.html?coin=TICKER` — a single property-class coin's own page: rate, supply chart, activity, mint/redeem
- `docs.html` — how it works (mechanics, fees, migration, the peg)

Open `index.html` directly in a browser, or serve the folder statically
(`npx serve .`, GitHub Pages, Vercel, etc.) — there's no build step.

## Repo layout

```
parcel-launch/
├─ index.html, classes.html, launch.html, market.html, docs.html
├─ assets/
│  ├─ style.css      — design tokens + layout (blueprint/deed aesthetic)
│  ├─ classes.js      — the 20 property classes: ticker, label, unit, tier, icon config
│  └─ app.js          — wallet connect, ABIs, chain reads/writes for launches, coins, and markets
├─ contracts/
│  ├─ ParcelToken.sol         — fixed-supply ERC20 minted once per launch
│  ├─ BondingCurve.sol        — ETH-native curve; migrates to 1 or 2 pools depending on class
│  ├─ PropertyClassCoin.sol   — static-peg, fully-collateralized ETH mint/redeem (used for classes + USDG)
│  ├─ ParcelFactory.sol       — deploys a launch (curve + token) in one tx, ETH-native
│  ├─ TestnetMigrator.sol     — placeholder migration target, ETH or ERC20 (see DEPLOY.md)
│  └─ interfaces/IUniswapV4Migrator.sol
├─ script/Deploy.s.sol        — deploys the stack + 20 class coins + USDG, writes deployments/testnet.json
├─ deployments/testnet.json   — live addresses, read by assets/app.js at page load
├─ test/BondingCurve.t.sol    — Foundry tests: curve math, overshoot cap/refund, one- and two-pool migration
├─ foundry.toml, remappings.txt, .env.example
├─ DEPLOY.md                  — full testnet deployment walkthrough
└─ LICENSE
```

## How a launch works

Full version is on `docs.html`; short version:

1. A launch mints 1,000,000,000 tokens. 800,000,000 sell on a virtual
   constant-product curve priced directly in ETH, using fixed virtual
   reserves (3 ETH / 1,073,000,000 tokens) — opens around a 2.8 ETH
   implied cap, migrates once roughly 8.8 ETH has been raised. This is
   identical whether or not a property class is picked.
2. The creator picks a trading fee (1%–3%), optionally picks a property
   class, and sends their first buy — any amount of ETH — in the same
   transaction that creates the market.
3. Buys that would exceed the curve's remaining supply are automatically
   capped and the unused ETH refunded, rather than reverting.
4. When the curve sells out: **no class picked** → the full reserved
   200,000,000 tokens and all raised ETH move into a single TOKEN/ETH
   pool. **Class picked** → it splits in half — one TOKEN/ETH pool, and
   one TOKEN/&lt;class&gt; pool seeded with real class-coin (minted with
   real ETH first, not a relabeled ETH balance).
5. Every fee splits 70% creator / 30% protocol, paid in ETH. There's no
   holder-reward bucket — nothing to claim just for holding a token.

## Property-class coins

Each of the 20 classes in `assets/classes.js`, plus USDG, is a real
`PropertyClassCoin` — not just a label. `mint()` takes ETH and issues coin
at a **fixed, immutable rate** set once at deployment; `redeem()` burns
coin for exactly the ETH backing it. No oracle, no keeper, nothing
updates the rate. It's fully collateralized by construction: minting only
ever issues coin backed by ETH just deposited, so the peg can't run
short. You can buy/sell any of these directly on `classes.html`, whether
or not you ever launch anything.

## Local setup (contracts)

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-commit
forge build
forge test
```

## Deploying to Robinhood Chain Testnet

See **[DEPLOY.md](DEPLOY.md)** for the full walkthrough. Short version:

```bash
cp .env.example .env   # fill in PRIVATE_KEY with a funded testnet wallet
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
git add deployments/testnet.json && git commit -m "Deploy to testnet" && git push
```

`assets/app.js` fetches `deployments/testnet.json` on every page load —
once it has a real factory address in it, `launch.html` switches from
previewing terms to actually submitting a `createLaunch` transaction,
and "Connect wallet" offers to add Robinhood Chain Testnet to the user's
wallet.

## What this repo doesn't do yet

- **No deployment by default.** Nothing in `/contracts` is deployed,
  audited, or gas-profiled until you run `DEPLOY.md`'s steps yourself.
- **Every class coin's rate is static**, fixed once at deploy time using
  a flat assumed ETH/USD rate to pick starting numbers — it never
  updates. Fine for a demo, wrong for anything real: a real deployment
  needs a live price feed behind each class, and real USDG should just
  be the actual USDG stablecoin rather than a static-rate stand-in (a
  fixed rate breaks a lot faster for something claiming to be a
  stablecoin than for a property class).
- **Uniswap v4 migration is stubbed**, for both pools when a class is
  picked. `IUniswapV4Migrator` defines the interface `BondingCurve` calls
  at sellout; `TestnetMigrator` just holds whatever it's given (ETH, and
  a class coin if applicable) rather than seeding a real pool — a
  migrated market has nowhere to trade until a real AMM integration
  replaces it.
- **The price chart uses trade sequence, not real timestamps** — one
  line, no candles or OHLC aggregation, and no per-trade RPC call to
  fetch exact block times.
- **No legal review.** Tokenizing a specific physical property — a
  named shed, a named villa — may make the resulting token a security,
  a fractional-ownership instrument, or something else regulated,
  depending on jurisdiction and on whether the token actually confers
  any claim on the property.
