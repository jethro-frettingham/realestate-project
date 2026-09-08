# Deploying to Robinhood Chain Testnet

Deploys the Parcel stack to Robinhood Chain Testnet, and wires the live
site to it automatically: a `TestnetMigrator`, one `PropertyClassCoin` per
property class (20 total) plus USDG, and a `ParcelFactory`. Every coin's
peg is static — fixed at deploy time from a flat assumed ETH/USD rate, no
oracle, no keeper.

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
2. `cp .env.example .env` and paste the private key in as `PRIVATE_KEY`
   — **with a `0x` prefix**, which MetaMask's copy doesn't include by
   default (`PRIVATE_KEY=0xabc123...`). `.env` is already in
   `.gitignore` — it should never be committed.
3. Get testnet ETH for that address from
   [faucet.testnet.chain.robinhood.com](https://faucet.testnet.chain.robinhood.com).
   This deployment is 23 small contracts (migrator, factory, 20 class
   coins, USDG) — still cheap, but get a bit more than a trivial amount.

## 4. Deploy

```bash
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
```

This deploys `TestnetMigrator`, all 20 property-class coins, USDG, and
`ParcelFactory`, then writes every address to `deployments/testnet.json`
(class coins under a `classCoins` map, keyed by ticker).

If it fails partway through, it's almost always one of:
- **Insufficient funds** — get more from the faucet.
- **`PRIVATE_KEY` not set or missing its `0x` prefix** — check `.env`.
- **Dependency not found** — re-run step 2.

## 5. Commit the deployment record

```bash
git add deployments/testnet.json
git commit -m "Deploy to Robinhood Chain Testnet"
git push
```

`assets/app.js` fetches `deployments/testnet.json` at page load. Once
this is pushed and GitHub Pages redeploys (a minute or two), `launch.html`
switches from the "preview mode" notice to actually calling `createLaunch`
on your deployed `ParcelFactory` — Connect Wallet will also offer to add
Robinhood Chain Testnet to the user's wallet if it isn't already there.

## 6. Test a launch

Once deployed, launching needs nothing but testnet ETH — no minting, no
approvals, whether or not you pick a class. On `launch.html`: connect a
wallet holding testnet ETH, fill in a name and ticker, optionally pick a
property class, enter a first-buy amount in ETH, and submit. One
transaction, one wallet confirmation.

To buy/sell a property-class coin directly (not through a launch), use
`classes.html` — same pattern, pick a coin, buy with ETH or sell back to
ETH at its fixed rate.

To interact from the command line instead (e.g. to script a test buy on
an existing launch):

```bash
# Buy into a curve directly — replace the address with a curve's address
# from a LaunchCreated event or the explorer.
cast send <curve address> "buy(uint256)" 0 \
  --value 0.1ether --rpc-url robinhood_testnet --private-key $PRIVATE_KEY
```

## Redeploying

Re-running the script deploys a fresh set of everything (migrator, class
coins, USDG, factory) and overwrites `deployments/testnet.json` — old
launches created against the previous factory and previous class coins
stop showing up anywhere new, since `index.html`'s markets list reads
live from the *current* factory's on-chain array. Commit and push again
after any redeploy.
