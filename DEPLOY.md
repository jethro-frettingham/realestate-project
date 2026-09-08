# Deploying to Robinhood Chain Testnet

This deploys the full Parcel contract stack — oracle, 20 property-class
coins, factory, and a testnet-only migrator — to Robinhood Chain Testnet,
and wires the live site to it automatically.

Robinhood Chain Testnet:

| | |
|---|---|
| Chain ID | `46630` |
| RPC | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://explorer.testnet.chain.robinhood.com` |
| Faucet | `https://faucet.testnet.chain.robinhood.com` |
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
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-commit
```

## 3. Set up a deployer wallet

Use a **throwaway wallet**, not your main one — its key goes in a local
file and it only ever needs to hold testnet ETH.

1. Create a new wallet in MetaMask (or any wallet) and copy its address
   and private key.
2. `cp .env.example .env` and paste the private key in as `PRIVATE_KEY`.
   `.env` is already in `.gitignore` — it should never be committed.
3. Get testnet ETH for that address from
   [faucet.testnet.chain.robinhood.com](https://faucet.testnet.chain.robinhood.com).
   You only need a small amount — this deploys ~23 contracts but they're
   all small.

## 4. Deploy

```bash
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
```

This deploys `MockUSDG`, `PriceOracle` (seeded with a starting price for
all 20 property classes), one `PropertyClassCoin` per class,
`TestnetMigrator`, and `ParcelFactory` — then writes every address to
`deployments/testnet.json`.

If it fails partway through, it's almost always one of:
- **Insufficient funds** — get more from the faucet.
- **`PRIVATE_KEY` not set** — check `.env` was created and saved.
- **Dependency not found** — re-run step 2.

## 5. Commit the deployment record

```bash
git add deployments/testnet.json
git commit -m "Deploy to Robinhood Chain Testnet"
git push
```

`assets/app.js` fetches `deployments/testnet.json` at page load. Once
this is pushed and GitHub Pages redeploys (a minute or two), `launch.html`
switches from the "demo only" preview to actually calling `createLaunch`
on your deployed `ParcelFactory` — Connect Wallet will also offer to add
Robinhood Chain Testnet to the user's wallet if it isn't already there.

## 6. Get yourself some testnet property-class coin to launch with

The creator's first buy has to be paid in ETH, USDG, or the pair coin —
on testnet that means `MockUSDG` or a `PropertyClassCoin`. `MockUSDG` is
open-mint for exactly this reason:

```bash
cast send <usdg address from deployments/testnet.json> \
  "faucet(uint256)" 1000000000000000000000 \
  --rpc-url robinhood_testnet --private-key $PRIVATE_KEY
```

That mints 1,000 mUSDG to your deployer wallet. Approve and call `mint`
on a `PropertyClassCoin` (addresses under `classCoins` in
`deployments/testnet.json`) to convert some of it into, say, SHED before
launching a market paired with SHED.

## Redeploying

Re-running the script deploys a fresh set of contracts and overwrites
`deployments/testnet.json` — old launches created against the previous
factory won't show up anywhere new (there's no markets-listing indexer
in this repo yet; `index.html`'s tiles are still static class previews,
not live launches). Commit and push again after any redeploy.
