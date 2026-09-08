# Parcel

A launchpad on Robinhood Chain where every market is paired with a
property-class coin instead of a stablecoin — a tin storage shed, a
friend's couch, an RV, a villa, a high-rise unit. Modeled on
commodity-pair launchpad mechanics (fixed supply, virtual-liquidity curve,
migration to a permanent AMM pool), swapped from commodities to real
estate classes.

**Status: front end works as a demo; contracts are a reference
implementation, unaudited, and not deployed anywhere.** See
[What this repo doesn't do yet](#what-this-repo-doesnt-do-yet) before you
point real money at any of this.

## Live pages

- `index.html` — markets home
- `classes.html` — all 20 property classes
- `launch.html` — the create-a-market form
- `docs.html` — how it works (mechanics, fees, migration, the oracle)

Open `index.html` directly in a browser, or serve the folder statically
(`npx serve .`, GitHub Pages, Vercel, etc.) — there's no build step.

## Repo layout

```
parcel-launch/
├─ index.html, classes.html, launch.html, docs.html
├─ assets/
│  ├─ style.css      — design tokens + layout (blueprint/deed aesthetic)
│  ├─ classes.js      — the 20 property classes: ticker, label, unit, tier, icon config
│  └─ app.js          — glyph renderer, wallet connect stub, bonding-curve math preview
├─ contracts/
│  ├─ ParcelToken.sol         — fixed-supply ERC20 minted once per launch
│  ├─ BondingCurve.sol        — virtual-liquidity curve, fee split, migration trigger
│  ├─ PropertyClassCoin.sol   — mint/redeem coin per property class (the "pair coin")
│  ├─ PriceOracle.sol         — reporter-fed USD index price per class
│  ├─ ParcelFactory.sol       — deploys a launch (curve + token) in one tx
│  └─ interfaces/IUniswapV4Migrator.sol
├─ test/BondingCurve.t.sol    — Foundry tests for curve math and fee claims
├─ foundry.toml, remappings.txt
└─ LICENSE
```

## How a launch works

Full version is on `docs.html`; short version:

1. A launch mints 1,000,000,000 tokens. 800,000,000 sell on a virtual
   constant-product curve that opens at a $5,000 market cap and completes
   at $35,000, both fixed in the pair coin at creation.
2. The creator picks a trading fee (1%–3%) and makes a first buy of at
   least $1 in the same transaction that creates the market.
3. When the curve sells out, the pair coin raised and the reserved
   200,000,000 tokens move into a Uniswap v4 pool at the curve's final
   price, permanently.
4. Every fee splits 30% creator / 40% pair-coin holders / 30% protocol,
   on the curve and in the pool alike.

## Property classes and their index price

Commodities have futures markets to read a price from; real estate
doesn't. `PriceOracle.sol` instead takes prices pushed by an approved set
of `reporters` — in production, services pulling comparable sales and
listing data per class (county records, listing APIs, manual comps for
illiquid classes). `BondingCurve` reads that index once at creation to
size its virtual reserves so the curve opens at $5,000 and migrates at
$35,000 in USD terms, whatever the class.

For classes with no real data source yet (a friend's couch, a lean-to),
the intent is a fixed published reference price maintained by Parcel
until a real feed exists — the oracle contract doesn't distinguish these
from real-feed classes today; that's a gap, not a design decision (see
below).

## Local setup (contracts)

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts
forge build
forge test
```

## Wiring the front end to a real deployment

`assets/app.js` has two placeholders at the top:

```js
const RH_CHAIN = { chainIdHex: "0x971b", rpcUrls: ["https://replace-with-robinhood-chain-rpc"], ... };
const FACTORY_ADDRESS = "0x0000000000000000000000000000000000dEaD";
```

Point `rpcUrls` and `FACTORY_ADDRESS` at a real deployment of
`ParcelFactory`, then wire `launch.html`'s submit handler to call
`createLaunch(...)` via ethers.js instead of only previewing the terms —
that hook is the only piece intentionally left out of this demo.

## What this repo doesn't do yet

- **No deployment.** Nothing in `/contracts` has been deployed, audited,
  or gas-profiled. `forge test` covers curve math and fee claims only.
- **No real price pipeline.** `PriceOracle` is a reporter-fed store, not
  an integration with any actual real-estate data source.
- **No staleness enforcement wired into consumers.** `PriceOracle` tracks
  `updatedAt` and reverts stale reads on `currentPrice`, but nothing
  re-checks staleness mid-curve-life the way a production system should
  before trusting the index for a migration.
- **Fee delivery to holders is pull-based, not push.** `docs.html`
  describes holder fees as automatic for readability; the contract uses
  a claim-based reward-per-share accumulator (the same pattern staking
  contracts use) because pushing a transfer to every holder on every
  trade doesn't scale gas-wise. Calling `claimHolderFees()` is a small
  UX gap the front end should paper over with a "claim all" button, not
  something to hide.
- **Uniswap v4 migration is stubbed.** `IUniswapV4Migrator` defines the
  interface `BondingCurve` calls at sellout; there's no real v4
  `PoolManager`/hook integration behind it.
- **No legal review.** Tokenizing a specific physical property — a
  named shed, a named villa — may make the resulting token a security,
  a fractional-ownership instrument, or something else regulated,
  depending on jurisdiction and on whether the token actually confers
  any claim on the property. Nothing in this repo represents, and the
  UI's "novelty" framing for some classes doesn't change, that this is a
  legal question for a lawyer before it touches real money, real
  property titles, or real users — not a configuration choice made in
  code.
