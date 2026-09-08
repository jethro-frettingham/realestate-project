# Parcel

A launchpad on Robinhood Chain where anyone can launch a token tethered
to a property class — a tin storage shed, a friend's couch, an RV, a
villa, a high-rise unit. Trading is always plain ETH: connect a wallet,
send ETH, get tokens. No pair coin, no minting step, nothing to approve
before a first buy, for the creator or for anyone buying after them.
Fixed supply, virtual-liquidity bonding curve, migration to a permanent
AMM pool on sellout — the same shape as the dominant real launchpad on
this chain (Pons V2), with property classes as a display tag instead of
a meme category.

**Status: the contracts are real and deployable to Robinhood Chain
Testnet — see [DEPLOY.md](DEPLOY.md) — and the front end wires up to a
live deployment automatically. Still unaudited, testnet-only.** See
[What this repo doesn't do yet](#what-this-repo-doesnt-do-yet) below
before you point real money at any of this.

## Live pages

- `index.html` — markets home
- `classes.html` — all 20 property classes
- `launch.html` — the create-a-market form
- `docs.html` — how it works (mechanics, fees, migration)

Open `index.html` directly in a browser, or serve the folder statically
(`npx serve .`, GitHub Pages, Vercel, etc.) — there's no build step.

## Repo layout

```
parcel-launch/
├─ index.html, classes.html, launch.html, docs.html
├─ assets/
│  ├─ style.css      — design tokens + layout (blueprint/deed aesthetic)
│  ├─ classes.js      — the 20 property classes: ticker, label, unit, tier, icon config
│  └─ app.js          — glyph renderer, wallet connect, bonding-curve math preview, tx submission
├─ contracts/
│  ├─ ParcelToken.sol         — fixed-supply ERC20 minted once per launch
│  ├─ BondingCurve.sol        — ETH-native virtual-liquidity curve, fee split, migration trigger
│  ├─ ParcelFactory.sol       — deploys a launch (curve + token) in one tx, ETH-native
│  ├─ TestnetMigrator.sol     — placeholder migration target (see DEPLOY.md)
│  ├─ PriceOracle.sol         — optional, currently unused (see docs.html)
│  └─ interfaces/IUniswapV4Migrator.sol
├─ script/Deploy.s.sol        — deploys the stack, writes deployments/testnet.json
├─ deployments/testnet.json   — live addresses, read by assets/app.js at page load
├─ test/BondingCurve.t.sol    — Foundry tests for curve math, capped/refunded overshoot buys, fee claims
├─ foundry.toml, remappings.txt, .env.example
├─ DEPLOY.md                  — full testnet deployment walkthrough
└─ LICENSE
```

## How a launch works

Full version is on `docs.html`; short version:

1. A launch mints 1,000,000,000 tokens. 800,000,000 sell on a virtual
   constant-product curve priced directly in ETH, using fixed virtual
   reserves (3 ETH / 1,073,000,000 tokens) — opens around a 2.8 ETH
   implied cap, migrates once roughly 8.8 ETH has been raised.
2. The creator picks a trading fee (1%–3%) and sends their first buy —
   any amount of ETH — in the same transaction that creates the market.
3. Buys that would exceed the curve's remaining supply are automatically
   capped and the unused ETH refunded, rather than reverting.
4. When the curve sells out, the ETH raised and the reserved 200,000,000
   tokens move into a Uniswap v4 pool at the curve's final price,
   permanently.
5. Every fee splits 30% creator / 40% token holders / 30% protocol, paid
   in ETH, on the curve and in the pool alike.

## Property classes

Each of the 20 classes in `assets/classes.js` is a plain string tag
passed to `createLaunch` — it's stored in the launch's on-chain metadata
and shown in the UI, and that's the whole extent of what it does.
Nothing about buying, selling, or launching depends on which class is
picked, or requires holding, minting, or approving anything beyond ETH.
`PriceOracle.sol` is kept in the repo as an optional, currently-unused
piece for eventually displaying a "worth roughly N sheds" style
comparison — no live contract reads from it today.

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
- **Fee delivery to holders is pull-based, not push.** `docs.html`
  is explicit about this: the contract uses a claim-based
  reward-per-share accumulator (the same pattern staking contracts use)
  because pushing a transfer to every holder on every trade doesn't
  scale gas-wise. A production front end should surface a "claim"
  button, not imply it happens automatically.
- **Uniswap v4 migration is stubbed.** `IUniswapV4Migrator` defines the
  interface `BondingCurve` calls at sellout; `TestnetMigrator` just
  holds the ETH and reserved tokens rather than seeding a real pool —
  there's no real v4 `PoolManager`/hook integration behind it, and a
  migrated market has nowhere to trade until one exists.
- **No markets index.** `index.html` shows the static class list, not
  live launches — finding a specific market means reading
  `LaunchCreated` events or checking the explorer.
- **No legal review.** Tokenizing a specific physical property — a
  named shed, a named villa — may make the resulting token a security,
  a fractional-ownership instrument, or something else regulated,
  depending on jurisdiction and on whether the token actually confers
  any claim on the property. Nothing in this repo represents, and the
  UI's "novelty" framing for some classes doesn't change, that this is
  a legal question for a lawyer before it touches real money, real
  property titles, or real users — not a configuration choice made in
  code.
