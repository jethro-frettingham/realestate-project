/**
 * app.js, shared front-end logic for CASTLE.
 *
 * Every launch is a real Uniswap v4 pool from the block it's created
 * (Launchpad.sol) — there's no separate curve contract and no migration.
 * `loadDeployment()` fetches deployments/mainnet.json, written by
 * script/DeployMainnet.s.sol — this site is mainnet-only, there's no
 * testnet fallback in the wallet-connect path (see ensureRobinhoodChain).
 * Trading always looks like "connect wallet, send ETH, get tokens" from
 * the trader's side, through LaunchRouter — even for a market paired with
 * a property class, which trades against that class's coin under the
 * hood. Until deployments/mainnet.json has a real `launchpad` address in
 * it (see DEPLOY.md), the site runs in preview-only mode.
 */

const RH_MAINNET = {
  chainName: "Robinhood Chain",
  chainIdHex: "0x1237", // 4663
  rpcUrls: ["https://rpc.mainnet.chain.robinhood.com"],
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  blockExplorerUrls: ["https://robinhoodchain.blockscout.com"],
};

// Minimal ABI fragments, just what the site calls. `getLaunch` mirrors
// Launchpad.Launch exactly — field order matters for the tuple decode.
const LAUNCHPAD_ABI = [
  "function createLaunch(string name_, string symbol_, address quoteAsset_, uint16 feeBps, string metadataURI, uint256 minTokensOut) payable returns (uint256 launchId, address token)",
  "function launchCount() view returns (uint256)",
  "function getLaunch(uint256) view returns (tuple(address token, address quoteAsset, address creator, uint16 feeBps, string propertyClass, string metadataURI, uint64 createdAt, tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool tokenIsCurrency1, int24 openTick, int24 capTick, int24 farTick))",
  "function getPoolState(uint256) view returns (uint160 sqrtPriceX96, int24 tick)",
  "function collectFees(uint256 launchId)",
  "event LaunchCreated(uint256 indexed launchId, address indexed creator, address token, address quoteAsset, string propertyClass, uint16 feeBps, string metadataURI)",
  "event Trade(uint256 indexed launchId, address indexed trader, bool isBuy, uint256 quoteIn, uint256 tokensOut, uint256 quoteOut, uint256 tokensIn)",
];
const ROUTER_ABI = [
  "function buy(uint256 launchId, uint256 minTokensOut) payable returns (uint256 tokensOut)",
  "function sell(uint256 launchId, uint256 tokenAmountIn, uint256 minQuoteOut) returns (uint256 quoteOut)",
  "event Trade(uint256 indexed launchId, address indexed trader, bool isBuy, uint256 quoteIn, uint256 tokensOut, uint256 quoteOut, uint256 tokensIn)",
];
const TOKEN_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function totalSupply() view returns (uint256)",
  "function quoteAsset() view returns (address)",
  "function earned(address) view returns (uint256)",
  "function claimRewards() returns (uint256)",
  "event RewardAdded(uint256 amount)",
];
const BUYBACK_ABI = [
  "function executeBuyback() returns (uint256 ethIn, uint256 tokensBurned)",
  "event BuybackExecuted(uint256 ethIn, uint256 tokensBurned)",
];
const PROPERTY_COIN_ABI = [
  "function mint(uint256 minCoinOut) payable returns (uint256 coinOut)",
  "function redeem(uint256 coinIn, uint256 minEthOut) returns (uint256 ethOut)",
  "function weiPerUnit() view returns (uint256)",
  "function classTicker() view returns (string)",
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function totalSupply() view returns (uint256)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "event Minted(address indexed who, uint256 ethIn, uint256 coinOut)",
  "event Redeemed(address indexed who, uint256 coinIn, uint256 ethOut)",
];
// Live-tier classes (a genuine, if infrequently-published, reference
// index — housing, farmland, RVs, ...) trade against a PegPool instead of
// a fixed-rate PropertyClassCoin. See PegPool.sol for why.
const PEGPOOL_ABI = [
  "function buy(uint256 minCoinOut) payable returns (uint256 coinOut)",
  "function sell(uint256 coinIn, uint256 minEthOut) returns (uint256 ethOut)",
  "function weiPerUnit() view returns (uint256)",
  "function ethReserves() view returns (uint256)",
  "function coin() view returns (address)",
  "event Bought(address indexed trader, uint256 ethIn, uint256 coinOut)",
  "event Sold(address indexed trader, uint256 coinIn, uint256 ethOut)",
  "error ZeroAmount()",
  "error InsufficientReserves()",
  "error Slippage()",
];

/** PegPool's custom errors have no ABI-level message string, so without
 *  this, a revert just surfaces to the user as raw ethers CALL_EXCEPTION
 *  JSON (reason=null, revert=null) — technically correct, meaningless to
 *  read. Decodes the revert data (present whether the ABI already let
 *  ethers auto-populate `err.revert`, or not) into the plain-English
 *  explanation this app actually wants to show. Returns null for anything
 *  that isn't one of PegPool's own errors, so callers fall back to the
 *  original error. */
function _describePegPoolError(err) {
  try {
    const data = err?.data || err?.error?.data || err?.info?.error?.data || err?.revert?.data;
    if (!data) return null;
    const parsed = new ethers.Interface(PEGPOOL_ABI).parseError(data);
    if (!parsed) return null;
    if (parsed.name === "InsufficientReserves") {
      return "Not enough ETH has been pulled into this class's pool yet to pay sellers. Try a smaller amount, or check back after more buying activity on this class.";
    }
    if (parsed.name === "Slippage") return "The price moved before this could confirm — try again.";
    if (parsed.name === "ZeroAmount") return "Enter a non-zero amount.";
  } catch (_) { /* not a PegPool error — let the caller fall back */ }
  return null;
}

/* ---------------------------------------------------------------------- */
/* Short-TTL read cache — this is a static site with no shared backend,   */
/* so this can only cut down repeat chain reads within one visitor's own  */
/* session (re-rendering, navigating between pages, a reward panel's      */
/* periodic refresh); it does nothing for many different visitors hitting */
/* the RPC for the first time at the same moment, since each browser tab  */
/* is an independent JS runtime with its own empty cache. Still cheap and */
/* worth having: it also dedupes concurrent in-flight calls for the same  */
/* key within one tab (two widgets both asking for the same data at once  */
/* share one request instead of firing two).                             */
/* ---------------------------------------------------------------------- */

const READ_CACHE_TTL_MS = 15000;
const _readCache = new Map(); // key -> { expires, promise }

// Every read-only function used to create its own fresh JsonRpcProvider —
// harmless with one market on the page, but a page with N markets fires
// N+ of these in parallel (loadMarkets, readPropertyCoin per classed
// market, ...), and each fresh instance does its own network-detection
// round trip before its real call even goes out. Sharing one instance
// per rpcUrl — with the chain id passed in explicitly so ethers never
// needs to probe for it — cuts that down to one setup cost per page
// load instead of one per call.
const _readProviderCache = new Map(); // rpcUrl -> ethers.JsonRpcProvider
function _readProvider(deployment) {
  let provider = _readProviderCache.get(deployment.rpcUrl);
  if (!provider) {
    provider = new ethers.JsonRpcProvider(deployment.rpcUrl, deployment.chainId, { staticNetwork: true });
    _readProviderCache.set(deployment.rpcUrl, provider);
  }
  return provider;
}

/** Like Promise.all(items.map(fn)), but only `limit` calls in flight at
 *  once. A page listing every market fires several RPC calls PER market
 *  (state, volume, and — for a classed one — its class's rate); a
 *  Promise.all across all of them fires that whole burst as one wave of
 *  brand-new connections to a host the browser hasn't talked to yet this
 *  page load, which is exactly the situation observed to intermittently
 *  fail with a bare "Failed to fetch" (no CORS headers on whatever the
 *  real error was for the browser to report anything more specific) —
 *  the same calls always succeed run individually, or after the page
 *  has already warmed up a connection. Capping how many run at once
 *  keeps the market list loading correctly regardless of how many
 *  markets exist. */
async function mapWithConcurrency(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

function _cachedRead(key, fn) {
  const hit = _readCache.get(key);
  if (hit && hit.expires > Date.now()) return hit.promise;
  const promise = fn().catch((err) => {
    _readCache.delete(key); // never cache a failure
    throw err;
  });
  _readCache.set(key, { expires: Date.now() + READ_CACHE_TTL_MS, promise });
  return promise;
}

/** Called after any successful on-chain write (buy, sell, launch, claim,
 *  collect, buyback, mint, redeem) so the next read reflects it
 *  immediately instead of serving a pre-transaction snapshot for up to
 *  READ_CACHE_TTL_MS. Clearing everything (rather than just the affected
 *  keys) is deliberately simple — the cache is cheap to rebuild and this
 *  can't miss an invalidation path as new read functions get cached. */
function _invalidateReadCache() {
  _readCache.clear();
}

/* ---------------------------------------------------------------------- */
/* Deployment loader, reads deployments/mainnet.json                      */
/* ---------------------------------------------------------------------- */

let deploymentCache = null;

/** Fetches deployments/mainnet.json and caches it. Returns null (rather
 *  than throwing) if it's missing or still the unfilled placeholder, so
 *  callers can fall back to preview mode. Mainnet-only — see
 *  ensureRobinhoodChain() for why there's no testnet fallback here. */
async function loadDeployment() {
  if (deploymentCache) return deploymentCache;
  try {
    const res = await fetch("deployments/mainnet.json", { cache: "no-store" });
    if (!res.ok) return null;
    const json = await res.json();
    if (!json.launchpad) return null; // still the placeholder
    deploymentCache = json;
    return json;
  } catch (err) {
    console.warn("No deployment found yet, running in preview mode.", err);
    return null;
  }
}

/* ---------------------------------------------------------------------- */
/* Wallet connect, real network add/switch, ethers v6 where loaded       */
/* ---------------------------------------------------------------------- */

let currentAccount = null;

// Set once the user picks a specific wallet out of the connect picker (or
// on page load, if a previous pick can be re-matched via EIP-6963 — see
// _restoreActiveProvider). Every wallet-facing call in this file should go
// through _getProvider() rather than window.ethereum directly: with more
// than one extension installed, window.ethereum is whichever one won the
// injection race (often Coinbase Wallet or Phantom, regardless of what the
// user actually picked in our own UI), not necessarily the one the user
// chose — that mismatch was the root cause of "picked MetaMask, got a
// Coinbase/Phantom popup instead" reports.
let _activeProvider = null;
function _getProvider() {
  return _activeProvider || window.ethereum || null;
}

const WALLET_RDNS_KEY = "castle_wallet_rdns";

/** EIP-6963 (Multi Injected Provider Discovery) lets every installed
 *  wallet announce itself with a stable id (`info.rdns`) instead of all of
 *  them fighting over the single window.ethereum global. Supported by
 *  current MetaMask, Rabby, Coinbase Wallet and Phantom's EVM provider;
 *  wallets that don't support it yet just won't show up here, and callers
 *  fall back to window.ethereum + its isX flags (see _detectWallets). */
function _collectEip6963Providers() {
  return new Promise((resolve) => {
    const found = [];
    const onAnnounce = (e) => found.push(e.detail);
    window.addEventListener("eip6963:announceProvider", onAnnounce);
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    setTimeout(() => {
      window.removeEventListener("eip6963:announceProvider", onAnnounce);
      resolve(found);
    }, 200);
  });
}

/** Re-selects whichever wallet the user connected with last time (by
 *  rdns, via EIP-6963) so a page navigation on this multi-page site keeps
 *  using the SAME wallet instead of silently falling back to whatever
 *  window.ethereum happens to point at right now. No-op if nothing was
 *  saved, or that wallet isn't announcing this time. */
async function _restoreActiveProvider() {
  const savedRdns = localStorage.getItem(WALLET_RDNS_KEY);
  if (!savedRdns) return;
  try {
    const announced = await _collectEip6963Providers();
    const match = announced.find((a) => a.info && a.info.rdns === savedRdns);
    if (match) _activeProvider = match.provider;
  } catch (_) { /* fine — falls back to window.ethereum */ }
}

/** Adds/switches the connected wallet to Robinhood Chain mainnet — the
 *  site is mainnet-only, so there's nothing to branch on here. (This used
 *  to pick testnet vs mainnet based on the loaded deployment, which broke
 *  on a fresh connect — see loadDeployment()'s docs — and testnet doesn't
 *  need supporting here anyway: there's no live deployment to trade
 *  against there.) */
async function ensureRobinhoodChain() {
  const eth = _getProvider();
  try {
    await eth.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: RH_MAINNET.chainIdHex }],
    });
  } catch (switchErr) {
    // 4902 = chain not added to the wallet yet
    if (switchErr.code === 4902) {
      // wallet_addEthereumChain has a strict, EIP-3085 param shape — it
      // wants `chainId`, not our own internal `chainIdHex` field name.
      // Spreading the whole RH_MAINNET object here used to send an extra
      // `chainIdHex` key that recent MetaMask versions reject outright
      // ("Received unexpected keys on object parameter").
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: RH_MAINNET.chainIdHex,
          chainName: RH_MAINNET.chainName,
          rpcUrls: RH_MAINNET.rpcUrls,
          nativeCurrency: RH_MAINNET.nativeCurrency,
          blockExplorerUrls: RH_MAINNET.blockExplorerUrls,
        }],
      });
    } else {
      throw switchErr;
    }
  }
}

function _setConnectedUi(account) {
  currentAccount = account;
  document.querySelectorAll("[data-connect]").forEach((btn) => {
    btn.dataset.connected = "true";
    btn.textContent = account.slice(0, 6) + "…" + account.slice(-4);
    btn.title = "Click to disconnect";
  });
}

function _setDisconnectedUi() {
  currentAccount = null;
  document.querySelectorAll("[data-connect]").forEach((btn) => {
    delete btn.dataset.connected;
    btn.textContent = "Connect wallet";
    btn.removeAttribute("title");
  });
}

/** @param provider Specific EIP-1193 provider to connect (from the wallet
 *    picker's EIP-6963 discovery). Falls back to window.ethereum when
 *    omitted — the picker only omits it for a wallet it found by flag-
 *    sniffing rather than EIP-6963 (see _detectWallets).
 *  @param rdns The wallet's EIP-6963 rdns id, so a later page load can
 *    re-select the same wallet instead of guessing (see
 *    _restoreActiveProvider). Omitted for the flag-sniffed fallback path. */
async function connectWallet(provider, rdns) {
  const eth = provider || window.ethereum;
  if (!eth) {
    alert("No injected wallet found. Install MetaMask, Rabby, or Coinbase Wallet to launch on Robinhood Chain.");
    return;
  }
  try {
    const accounts = await eth.request({ method: "eth_requestAccounts" });
    _activeProvider = eth;
    if (rdns) localStorage.setItem(WALLET_RDNS_KEY, rdns);
    else localStorage.removeItem(WALLET_RDNS_KEY);
    await ensureRobinhoodChain();
    _setConnectedUi(accounts[0]);
    eth.on?.("accountsChanged", _onActiveProviderAccountsChanged);
    document.dispatchEvent(new CustomEvent("parcel:connected", { detail: accounts[0] }));
  } catch (err) {
    console.error("wallet connect failed", err);
    alert("Couldn't connect: " + (err.message || err));
  }
}

function _onActiveProviderAccountsChanged(accounts) {
  if (accounts.length === 0) {
    _setDisconnectedUi();
    document.dispatchEvent(new CustomEvent("parcel:disconnected"));
  } else if (accounts[0] !== currentAccount) {
    _setConnectedUi(accounts[0]);
    document.dispatchEvent(new CustomEvent("parcel:connected", { detail: accounts[0] }));
  }
}

/** A dApp can't force a wallet extension to forget the site (that's the
 *  wallet's own permission, not ours to revoke) — this is a "soft"
 *  disconnect: it resets our own UI and stops treating the page as
 *  connected, and best-effort asks newer wallets (EIP-2255) to drop the
 *  permission too. If the wallet doesn't support that, the wallet stays
 *  connected under the hood but the site acts disconnected until you
 *  click Connect again (which most wallets satisfy without a fresh
 *  approval prompt, since the permission is still there). */
async function disconnectWallet() {
  try {
    await _getProvider()?.request({
      method: "wallet_revokePermissions",
      params: [{ eth_accounts: {} }],
    });
  } catch (_) { /* not supported by this wallet — fine, soft-disconnect still applies */ }
  _activeProvider = null;
  localStorage.removeItem(WALLET_RDNS_KEY);
  _setDisconnectedUi();
  document.dispatchEvent(new CustomEvent("parcel:disconnected"));
}

async function _handleConnectButtonClick(e) {
  if (e.currentTarget.dataset.connected === "true") {
    await disconnectWallet();
  } else {
    _toggleWalletPicker(e.currentTarget);
  }
}

/** Finds each wallet's OWN provider object, not just whether one is
 *  installed — picking "MetaMask" in the UI must call eth_requestAccounts
 *  on MetaMask's actual provider, never the ambiguous window.ethereum
 *  (which, with more than one extension installed, is whichever one won
 *  the injection race — commonly Coinbase Wallet or Phantom, regardless of
 *  what the user picked). EIP-6963 is the primary path since it's
 *  collision-free by design; flag-sniffing window.ethereum (and its
 *  .providers array, from wallets still using the older EIP-5749-ish
 *  pattern) is only a fallback for a wallet that hasn't adopted EIP-6963
 *  yet — in that fallback case there's still only one thing to point at,
 *  so the ambiguity risk doesn't apply. Robinhood Wallet's rdns/flag are a
 *  best guess (no official docs found) — worst case it just shows as "Not
 *  detected" instead of breaking anything. */
async function _detectWallets() {
  const announced = await _collectEip6963Providers();
  const byRdnsOrName = (needle) =>
    announced.find(
      (a) => (a.info?.rdns || "").toLowerCase().includes(needle) || (a.info?.name || "").toLowerCase().includes(needle)
    );

  const rabbyAnnounced = byRdnsOrName("rabby");
  const metamaskAnnounced = byRdnsOrName("metamask");
  const robinhoodAnnounced = byRdnsOrName("robinhood");

  // Fallback for wallets not announcing via EIP-6963 yet: only trust
  // window.ethereum's own flags when nothing else claimed the slot via
  // EIP-6963, since a 6963-aware wallet can still leave stale flags on a
  // window.ethereum it doesn't actually own.
  const eth = window.ethereum;
  const legacyProviders = (eth && eth.providers) || (eth ? [eth] : []);
  const legacyHas = (flag) => legacyProviders.some((p) => p && p[flag]);

  const rabby = rabbyAnnounced || (announced.length === 0 && legacyHas("isRabby") ? { provider: eth, info: { rdns: null, name: "Rabby" } } : null);
  const metamask =
    metamaskAnnounced ||
    (announced.length === 0 && legacyHas("isMetaMask") && !legacyHas("isRabby")
      ? { provider: eth, info: { rdns: null, name: "MetaMask" } }
      : null);
  const robinhood =
    robinhoodAnnounced ||
    (announced.length === 0 && (legacyHas("isRobinhoodWallet") || legacyHas("isRobinhood"))
      ? { provider: eth, info: { rdns: null, name: "Robinhood Wallet" } }
      : null);

  return { rabby, metamask, robinhood };
}

let _walletPickerEl = null;

function _closeWalletPicker() {
  if (_walletPickerEl) {
    _walletPickerEl.remove();
    _walletPickerEl = null;
    document.removeEventListener("click", _onWalletPickerOutsideClick, true);
    document.removeEventListener("keydown", _onWalletPickerEscape);
  }
}

function _onWalletPickerOutsideClick(e) {
  if (_walletPickerEl && !_walletPickerEl.contains(e.target) && e.target.closest("[data-connect]") !== _walletPickerEl._anchor) {
    _closeWalletPicker();
  }
}

function _onWalletPickerEscape(e) {
  if (e.key === "Escape") _closeWalletPicker();
}

async function _toggleWalletPicker(anchorBtn) {
  if (_walletPickerEl) {
    _closeWalletPicker();
    return;
  }

  // Placeholder while providers announce themselves (near-instant, but
  // still async) — avoids a blank gap between click and dropdown.
  const picker = document.createElement("div");
  picker.className = "wallet-picker";
  picker._anchor = anchorBtn;
  const loading = document.createElement("div");
  loading.className = "wallet-picker-head";
  loading.textContent = "Connect a wallet";
  picker.appendChild(loading);
  document.body.appendChild(picker);
  _positionWalletPicker(picker, anchorBtn);
  _walletPickerEl = picker;

  const found = await _detectWallets();
  if (_walletPickerEl !== picker) return; // closed while we were detecting

  const wallets = [
    {
      key: "phantom",
      name: "Phantom",
      sub: "Phantom cannot sign Robinhood Chain transactions for websites yet. Use Rabby, MetaMask, or Robinhood Wallet.",
      icon: "👻",
      iconBg: "linear-gradient(180deg,#AB9FF2,#6851C7)",
      status: "unsupported",
    },
    {
      key: "rabby",
      name: "Rabby",
      sub: found.rabby ? "Detected" : "Not detected",
      icon: "🐰",
      iconBg: "linear-gradient(180deg,#7A88FF,#4C5FEB)",
      status: found.rabby ? "connect" : "install",
      installUrl: "https://rabby.io",
      match: found.rabby,
    },
    {
      key: "metamask",
      name: "MetaMask",
      sub: found.metamask ? "Detected" : "Not detected",
      icon: "🦊",
      iconBg: "linear-gradient(180deg,#FF9A3D,#E8821A)",
      status: found.metamask ? "connect" : "install",
      installUrl: "https://metamask.io/download",
      match: found.metamask,
    },
    {
      key: "robinhood",
      name: "Robinhood Wallet",
      sub: found.robinhood ? "Detected" : "Not detected",
      icon: "R",
      iconBg: "#0A0D0C",
      status: found.robinhood ? "connect" : "install",
      installUrl: "https://robinhood.com/us/en/support/articles/robinhood-wallet/",
      match: found.robinhood,
    },
  ];

  picker.innerHTML = "";
  const header = document.createElement("div");
  header.className = "wallet-picker-head";
  header.textContent = "Connect a wallet";
  picker.appendChild(header);

  wallets.forEach((w) => {
    const row = document.createElement("div");
    row.className = "wallet-row" + (w.status === "unsupported" ? " is-unsupported" : "");

    const icon = document.createElement("div");
    icon.className = "wallet-row-icon";
    icon.style.background = w.iconBg;
    icon.textContent = w.icon;
    row.appendChild(icon);

    const text = document.createElement("div");
    text.className = "wallet-row-text";
    text.innerHTML = "<b>" + w.name + "</b><span>" + w.sub + "</span>";
    row.appendChild(text);

    const status = document.createElement(w.status === "unsupported" ? "span" : "button");
    status.className = "wallet-row-status status-" + w.status;
    if (w.status === "connect") {
      status.textContent = "Connect";
      status.type = "button";
      status.addEventListener("click", async () => {
        _closeWalletPicker();
        await connectWallet(w.match.provider, w.match.info?.rdns || null);
      });
    } else if (w.status === "install") {
      status.textContent = "Install";
      status.type = "button";
      status.addEventListener("click", () => window.open(w.installUrl, "_blank", "noopener"));
    } else {
      status.textContent = "Unsupported";
    }
    row.appendChild(status);

    picker.appendChild(row);
  });

  _positionWalletPicker(picker, anchorBtn);
  setTimeout(() => {
    document.addEventListener("click", _onWalletPickerOutsideClick, true);
    document.addEventListener("keydown", _onWalletPickerEscape);
  }, 0);
}

function _positionWalletPicker(picker, anchorBtn) {
  const rect = anchorBtn.getBoundingClientRect();
  picker.style.position = "fixed";
  picker.style.top = rect.bottom + 8 + "px";
  const left = Math.min(rect.right - picker.offsetWidth, window.innerWidth - picker.offsetWidth - 12);
  picker.style.left = Math.max(12, left) + "px";
}

document.addEventListener("DOMContentLoaded", async () => {
  document.querySelectorAll("[data-connect]").forEach((btn) => {
    btn.addEventListener("click", _handleConnectButtonClick);
  });
  loadDeployment(); // warm the cache; pages read it via Parcel.loadDeployment()

  // Silently restore the connected state on every fresh page load — this
  // is a multi-page site (a real navigation, not client-side routing), so
  // without this the button would forget it was connected on every click
  // to another page even though the wallet extension itself still
  // considers the site authorized. eth_accounts (unlike
  // eth_requestAccounts) never prompts, it just reports what's already
  // approved. Re-selects the SAME wallet as last time first (by rdns) so a
  // navigation doesn't silently switch to whatever window.ethereum
  // happens to point at with multiple extensions installed.
  await _restoreActiveProvider();
  const eth = _getProvider();
  if (eth) {
    try {
      const accounts = await eth.request({ method: "eth_accounts" });
      if (accounts.length > 0) {
        _setConnectedUi(accounts[0]);
        document.dispatchEvent(new CustomEvent("parcel:connected", { detail: accounts[0] }));
      }
    } catch (_) { /* wallet not ready yet, or refused — stay disconnected */ }

    eth.on?.("accountsChanged", _onActiveProviderAccountsChanged);
  }
});

/* ---------------------------------------------------------------------- */
/* Launch submission, real createLaunch() call via ethers v6             */
/* ---------------------------------------------------------------------- */

/**
 * Submits a launch to the deployed Launchpad — one transaction that mints
 * the full supply straight into a real Uniswap v4 pool (800M curve range +
 * 200M reserve range) and executes the first buy in the same call. Requires
 * ethers v6 to be loaded and a deployment to exist. ETH-native, no
 * approval step. `pairCoinAddress` is optional: pass a PropertyClassCoin
 * address to pick a class (the market trades against that coin for its
 * whole life), or omit/pass null for a plain ETH market.
 *
 * @returns {Promise<{launchId: string, token: string, txHash: string}>}
 */
async function submitLaunch({ name, symbol, pairCoinAddress, feeBps, metadataURI, firstBuyIn }) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  const deployment = await loadDeployment();
  if (!deployment) throw new Error("No live deployment found yet. See DEPLOY.md to deploy the contracts first.");
  if (!_getProvider()) throw new Error("No wallet connected.");

  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  const launchpad = new ethers.Contract(deployment.launchpad, LAUNCHPAD_ABI, signer);

  const quoteAsset = pairCoinAddress || ethers.ZeroAddress;
  const tx = await launchpad.createLaunch(name, symbol, quoteAsset, feeBps, metadataURI, 0n, { value: firstBuyIn });
  const receipt = await tx.wait();

  const iface = new ethers.Interface(LAUNCHPAD_ABI);
  let launchId = null, token = null;
  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed && parsed.name === "LaunchCreated") {
        launchId = parsed.args.launchId.toString();
        token = parsed.args.token;
      }
    } catch (_) { /* not our event, ignore */ }
  }

  _invalidateReadCache();
  return { launchId, token, txHash: receipt.hash };
}

/* ---------------------------------------------------------------------- */
/* Property-class coins — static tier (fixed-rate mint/redeem) or         */
/* live tier (a PegPool's AMM peg) — dispatched by ticker so callers      */
/* don't need to care which one a given class is.                        */
/* ---------------------------------------------------------------------- */

/** Resolves a class ticker to its trading venue. USDG is always
 *  static-tier. Returns null if the ticker isn't deployed at all. */
function classVenue(deployment, ticker) {
  const pegPoolAddress = ticker !== "USDG" && deployment.pegPools ? deployment.pegPools[ticker] : null;
  if (pegPoolAddress && pegPoolAddress !== ethers.ZeroAddress) return { tier: "live", pegPoolAddress };
  const coinAddress = ticker === "USDG" ? deployment.usdg : (deployment.classCoins || {})[ticker];
  return coinAddress ? { tier: "static", coinAddress } : null;
}

/** Buy a property-class coin (or USDG) by sending ETH — mints at a fixed
 *  rate (static tier) or swaps against the class's AMM peg (live tier). */
async function mintPropertyCoin(ticker, ethIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  if (!_getProvider()) throw new Error("No wallet connected.");
  const deployment = await loadDeployment();
  if (!deployment) throw new Error("No live deployment found yet.");
  const venue = classVenue(deployment, ticker);
  if (!venue) throw new Error("Unknown or undeployed coin: " + ticker);
  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  if (venue.tier === "live") {
    const pool = new ethers.Contract(venue.pegPoolAddress, PEGPOOL_ABI, signer);
    try {
      const tx = await pool.buy(0n, { value: ethIn });
      const receipt = await tx.wait();
      _invalidateReadCache();
      return { txHash: receipt.hash };
    } catch (err) {
      throw new Error(_describePegPoolError(err) || err.message || String(err));
    }
  }
  const coin = new ethers.Contract(venue.coinAddress, PROPERTY_COIN_ABI, signer);
  const tx = await coin.mint(0n, { value: ethIn });
  const receipt = await tx.wait();
  _invalidateReadCache();
  return { txHash: receipt.hash };
}

/** Sell a property-class coin (or USDG) back for ETH — redeem at the
 *  fixed rate (static tier) or against the AMM peg, capped at what it's
 *  collected (live tier; see PegPool.sol). */
async function redeemPropertyCoin(ticker, coinIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  if (!_getProvider()) throw new Error("No wallet connected.");
  const deployment = await loadDeployment();
  if (!deployment) throw new Error("No live deployment found yet.");
  const venue = classVenue(deployment, ticker);
  if (!venue) throw new Error("Unknown or undeployed coin: " + ticker);
  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  if (venue.tier === "live") {
    const pool = new ethers.Contract(venue.pegPoolAddress, PEGPOOL_ABI, signer);
    try {
      const tx = await pool.sell(coinIn, 0n);
      const receipt = await tx.wait();
      _invalidateReadCache();
      return { txHash: receipt.hash };
    } catch (err) {
      throw new Error(_describePegPoolError(err) || err.message || String(err));
    }
  }
  const coin = new ethers.Contract(venue.coinAddress, PROPERTY_COIN_ABI, signer);
  const tx = await coin.redeem(coinIn, 0n);
  const receipt = await tx.wait();
  _invalidateReadCache();
  return { txHash: receipt.hash };
}

/** Read-only: a class's current rate and (if a wallet is connected) the
 *  caller's balance of it. Uses the public RPC, no wallet required just
 *  to read the rate. */
async function readPropertyCoin(ticker, account) {
  return _cachedRead("readPropertyCoin:" + ticker + ":" + (account || ""), () => _readPropertyCoinUncached(ticker, account));
}

async function _readPropertyCoinUncached(ticker, account) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return null;
  const venue = classVenue(deployment, ticker);
  if (!venue) return null;
  const provider = _readProvider(deployment);
  if (venue.tier === "live") {
    const pool = new ethers.Contract(venue.pegPoolAddress, PEGPOOL_ABI, provider);
    const [weiPerUnit, coinAddr] = await Promise.all([pool.weiPerUnit(), pool.coin()]);
    const balance = account ? await new ethers.Contract(coinAddr, PROPERTY_COIN_ABI, provider).balanceOf(account) : 0n;
    return { weiPerUnit, balance };
  }
  const coin = new ethers.Contract(venue.coinAddress, PROPERTY_COIN_ABI, provider);
  const weiPerUnit = await coin.weiPerUnit();
  const balance = account ? await coin.balanceOf(account) : 0n;
  return { weiPerUnit, balance };
}

/** Full live state for one class's own page: rate, current supply, and
 *  the ETH backing it. For a static-tier coin that backing is a plain
 *  balance check (fully collateralized by construction, so it should
 *  always equal supply × rate); for a live-tier coin it's `ethReserves`
 *  — only what's been harvested from the peg's ask so far, not a claim
 *  the coin makes about being collateralized (it isn't — see PegPool.sol). */
async function fetchPropertyCoinFullState(ticker) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return null;
  const venue = classVenue(deployment, ticker);
  if (!venue) return null;
  const provider = _readProvider(deployment);
  if (venue.tier === "live") {
    const pool = new ethers.Contract(venue.pegPoolAddress, PEGPOOL_ABI, provider);
    const coinAddr = await pool.coin();
    const coin = new ethers.Contract(coinAddr, PROPERTY_COIN_ABI, provider);
    const [name, symbol, weiPerUnit, totalSupply, ethReserves] = await Promise.all([
      coin.name(), coin.symbol(), pool.weiPerUnit(), coin.totalSupply(), pool.ethReserves(),
    ]);
    return { name, symbol, weiPerUnit, totalSupply, ethReserves, tier: "live", coinAddress: coinAddr, pegPoolAddress: venue.pegPoolAddress };
  }
  const coin = new ethers.Contract(venue.coinAddress, PROPERTY_COIN_ABI, provider);
  const [name, symbol, weiPerUnit, totalSupply, ethReserves] = await Promise.all([
    coin.name(), coin.symbol(), coin.weiPerUnit(), coin.totalSupply(), provider.getBalance(venue.coinAddress),
  ]);
  return { name, symbol, weiPerUnit, totalSupply, ethReserves, tier: "static", coinAddress: venue.coinAddress };
}

/** Every buy/sell event for one class, newest first — Minted/Redeemed for
 *  a static-tier coin, Bought/Sold for a live-tier PegPool, normalized
 *  into the same shape either way. */
async function fetchPropertyCoinActivity(ticker, maxResults = 50) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return [];
  const venue = classVenue(deployment, ticker);
  if (!venue) return [];
  const provider = _readProvider(deployment);
  const fromBlock = deployment.deployedBlock || 0;

  let all;
  if (venue.tier === "live") {
    const pool = new ethers.Contract(venue.pegPoolAddress, PEGPOOL_ABI, provider);
    const [boughts, solds] = await Promise.all([
      pool.queryFilter(pool.filters.Bought(), fromBlock, "latest"),
      pool.queryFilter(pool.filters.Sold(), fromBlock, "latest"),
    ]);
    all = [
      ...boughts.map((e) => ({ type: "Mint", who: e.args.trader, ethAmount: e.args.ethIn, coinAmount: e.args.coinOut, txHash: e.transactionHash, blockNumber: e.blockNumber, logIndex: e.index })),
      ...solds.map((e) => ({ type: "Redeem", who: e.args.trader, ethAmount: e.args.ethOut, coinAmount: e.args.coinIn, txHash: e.transactionHash, blockNumber: e.blockNumber, logIndex: e.index })),
    ];
  } else {
    const coin = new ethers.Contract(venue.coinAddress, PROPERTY_COIN_ABI, provider);
    const [mints, redeems] = await Promise.all([
      coin.queryFilter(coin.filters.Minted(), fromBlock, "latest"),
      coin.queryFilter(coin.filters.Redeemed(), fromBlock, "latest"),
    ]);
    all = [
      ...mints.map((e) => ({ type: "Mint", who: e.args.who, ethAmount: e.args.ethIn, coinAmount: e.args.coinOut, txHash: e.transactionHash, blockNumber: e.blockNumber, logIndex: e.index })),
      ...redeems.map((e) => ({ type: "Redeem", who: e.args.who, ethAmount: e.args.ethOut, coinAmount: e.args.coinIn, txHash: e.transactionHash, blockNumber: e.blockNumber, logIndex: e.index })),
    ];
  }
  all.sort((a, b) => (a.blockNumber - b.blockNumber) || (a.logIndex - b.logIndex));
  return all.slice(-maxResults).reverse();
}

/* ---------------------------------------------------------------------- */
/* Reading live launches + a single market's state, straight from chain   */
/* ---------------------------------------------------------------------- */

/** Every launch ever created, read directly from Launchpad's on-chain
 *  array, no indexer. Returns [] if nothing's deployed yet. Each entry's
 *  `launchId` is what identifies the market everywhere in the UI now —
 *  there's no more per-market curve contract address to key off. */
async function fetchAllLaunches() {
  return _cachedRead("fetchAllLaunches", async () => {
    const deployment = await loadDeployment();
    if (!deployment || typeof ethers === "undefined") return [];
    const provider = _readProvider(deployment);
    const launchpad = new ethers.Contract(deployment.launchpad, LAUNCHPAD_ABI, provider);
    const count = Number(await launchpad.launchCount());
    // Parallel, not sequential — a for-loop of N awaited round-trips means
    // page-load time scales with launch count for every visitor; Promise.all
    // fires them together instead.
    const launches = await Promise.all(
      Array.from({ length: count }, (_, i) =>
        launchpad.getLaunch(i).then((l) => ({
          launchId: i, token: l.token, quoteAsset: l.quoteAsset,
          propertyClass: l.propertyClass, creator: l.creator, feeBps: Number(l.feeBps),
          metadataURI: l.metadataURI, createdAt: Number(l.createdAt),
          tokenIsCurrency1: l.tokenIsCurrency1,
        }))
      )
    );
    return launches.reverse(); // newest first
  });
}

/** Look up a single launch's on-chain record by id, for pages (like
 *  market.html) that need the metadataURI (name, links, image) that goes
 *  with it. Scans every launch client-side; fine at today's scale. */
async function fetchLaunchById(launchId) {
  const launches = await fetchAllLaunches();
  return launches.find((l) => String(l.launchId) === String(launchId)) || null;
}

/** Decodes a launch's metadataURI (a base64 data: URI of JSON) back into
 *  a plain object. Returns {} on anything malformed rather than throwing,
 *  since this is display-only. */
function decodeMetadata(uri) {
  try {
    const b64 = uri.split(",")[1];
    return JSON.parse(decodeURIComponent(escape(atob(b64))));
  } catch (_) {
    return {};
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

/** Reads an <input type=file> image, downscales it to at most maxDim on
 *  its longer side, and re-encodes it as a compressed JPEG data URI.
 *  This runs entirely in the browser (canvas), no upload anywhere, the
 *  resulting string is what gets embedded in the launch's on-chain
 *  metadata, so keeping it small matters: metadataURI is a string in
 *  contract calldata, and gas cost scales with its size. A few KB is
 *  cheap; a multi-MB photo would make launching noticeably more
 *  expensive. Resolves to null if no file is given.
 */
function resizeImageToDataUri(file, maxDim = 200, quality = 0.72) {
  return new Promise((resolve, reject) => {
    if (!file) { resolve(null); return; }
    const reader = new FileReader();
    reader.onerror = () => reject(new Error("Couldn't read the image file."));
    reader.onload = () => {
      const img = new Image();
      img.onerror = () => reject(new Error("Couldn't decode the image file."));
      img.onload = () => {
        const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
        const w = Math.max(1, Math.round(img.width * scale));
        const h = Math.max(1, Math.round(img.height * scale));
        const canvas = document.createElement("canvas");
        canvas.width = w;
        canvas.height = h;
        canvas.getContext("2d").drawImage(img, 0, 0, w, h);
        resolve(canvas.toDataURL("image/jpeg", quality));
      };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
  });
}

/** Converts a v4 sqrtPriceX96 + which side the launch token is on into a
 *  human "quote units per token" price. Display-only (uses Number, not
 *  exact BigInt math) — fine for showing a price, not for settlement. */
function priceFromSqrtPriceX96(sqrtPriceX96, tokenIsCurrency1) {
  const ratio = Number(sqrtPriceX96) / 2 ** 96;
  const price1over0 = ratio * ratio; // currency1 per currency0
  return tokenIsCurrency1 ? 1 / price1over0 : price1over0;
}

/** Full live state for one market: its token's name/symbol, the launch
 *  record, and the pool's current price — everything a trading page
 *  needs, all view calls. There's no `migrated` flag to check anymore:
 *  the same pool is tradeable before and after the price crosses the cap. */
async function fetchMarketState(launchId) {
  return _cachedRead("fetchMarketState:" + launchId, async () => {
    const deployment = await loadDeployment();
    if (!deployment || typeof ethers === "undefined") return null;
    const provider = _readProvider(deployment);
    const launchpad = new ethers.Contract(deployment.launchpad, LAUNCHPAD_ABI, provider);

    const l = await launchpad.getLaunch(launchId);
    const token = new ethers.Contract(l.token, TOKEN_ABI, provider);
    const [name, symbol, totalSupply, sqrtTick] = await Promise.all([
      token.name(), token.symbol(), token.totalSupply(), launchpad.getPoolState(launchId),
    ]);

    const quotePerToken = priceFromSqrtPriceX96(sqrtTick.sqrtPriceX96, l.tokenIsCurrency1);
    const pastCap = l.tokenIsCurrency1 ? sqrtTick.tick < l.capTick : sqrtTick.tick > l.capTick;

    return {
      tokenAddr: l.token, name, symbol, quoteAsset: l.quoteAsset, propertyClass: l.propertyClass,
      creator: l.creator, feeBps: Number(l.feeBps), totalSupply, tokenIsCurrency1: l.tokenIsCurrency1,
      tick: Number(sqrtTick.tick), openTick: Number(l.openTick), capTick: Number(l.capTick), pastCap, quotePerToken,
    };
  });
}

/** How far the pool's price sits across the 800M-token curve range, 0-100,
 *  clamped — the closest equivalent to the old "% sold on the curve"
 *  progress bar now that the curve is real liquidity with no sellout
 *  event. 100% just means the price has crossed into the reserve range,
 *  not that the market is done trading — it never is. */
function curveProgressPct(state) {
  const { tick, openTick, capTick, tokenIsCurrency1 } = state;
  const span = tokenIsCurrency1 ? openTick - capTick : capTick - openTick;
  const progressed = tokenIsCurrency1 ? openTick - tick : tick - openTick;
  if (span === 0) return 0;
  return Math.min(100, Math.max(0, (progressed / span) * 100));
}

/** Recent Trade events for one market, straight from chain logs (the
 *  Launchpad's Trade for the first buy, LaunchRouter's for everything
 *  after) — a trade list, not a price chart (no candles/OHLC here). */
async function fetchRecentTrades(launchId, maxResults = 50) {
  return _cachedRead("fetchRecentTrades:" + launchId + ":" + maxResults, async () => {
    const deployment = await loadDeployment();
    if (!deployment || typeof ethers === "undefined") return [];
    const provider = _readProvider(deployment);
    const launchpad = new ethers.Contract(deployment.launchpad, LAUNCHPAD_ABI, provider);
    const router = new ethers.Contract(deployment.launchRouter, ROUTER_ABI, provider);
    const fromBlock = deployment.deployedBlock || 0;

    const [fromLaunchpad, fromRouter] = await Promise.all([
      launchpad.queryFilter(launchpad.filters.Trade(launchId), fromBlock, "latest"),
      router.queryFilter(router.filters.Trade(launchId), fromBlock, "latest"),
    ]);
    const all = [...fromLaunchpad, ...fromRouter].map((e) => ({
      trader: e.args.trader, isBuy: e.args.isBuy,
      ethIn: e.args.quoteIn, tokensOut: e.args.tokensOut,
      ethOut: e.args.quoteOut, tokensIn: e.args.tokensIn,
      txHash: e.transactionHash, blockNumber: e.blockNumber, logIndex: e.index,
    }));
    all.sort((a, b) => (a.blockNumber - b.blockNumber) || (a.logIndex - b.logIndex));
    return all.slice(-maxResults).reverse();
  });
}

/** Total quote-asset volume traded on one market, ever, sums every Trade
 *  event's quoteIn (buys) and quoteOut (sells). Real, not estimated, but
 *  does mean scanning every log for that market; fine at today's scale. */
async function fetchMarketVolumeEth(launchId) {
  const trades = await fetchRecentTrades(launchId, Number.MAX_SAFE_INTEGER);
  return trades.reduce((sum, t) => sum + (t.isBuy ? t.ethIn : t.ethOut), 0n);
}

/**
 * Protocol-wide totals for the homepage rewards panel, read straight from
 * chain, no indexer:
 *   - paidToHoldersEthEquiv: every market's RewardAdded events, summed.
 *     Each market pays holders in its own quote asset (ETH, or a property
 *     class's coin), so a classed market's total is converted to an
 *     ETH-equivalent using that class's *current* rate — an estimate for
 *     classes whose rate has moved since the reward was added, exact for
 *     ETH-quoted markets and any that haven't repriced.
 *   - ethSpentOnBuybacks / castleBurned: Buyback's own BuybackExecuted
 *     events — one contract, one event, exact.
 * Returns null if there's no live deployment yet.
 */
async function fetchRewardsStats() {
  return _cachedRead("fetchRewardsStats", async () => {
    const deployment = await loadDeployment();
    if (!deployment || typeof ethers === "undefined") return null;
    const provider = _readProvider(deployment);
    const fromBlock = deployment.deployedBlock || 0;

    const launches = await fetchAllLaunches();
    let paidToHoldersEthEquiv = 0n;
    await Promise.all(launches.map(async (l) => {
      const token = new ethers.Contract(l.token, TOKEN_ABI, provider);
      let added;
      try {
        added = await token.queryFilter(token.filters.RewardAdded(), fromBlock, "latest");
      } catch (_) {
        return; // token predates this event, or the RPC hiccuped — skip, don't fail the whole panel
      }
      if (added.length === 0) return;
      const total = added.reduce((sum, e) => sum + e.args.amount, 0n);
      if (l.quoteAsset === ethers.ZeroAddress) {
        paidToHoldersEthEquiv += total;
      } else {
        try {
          const rate = await readPropertyCoin(l.propertyClass, null); // tier-aware: static or live peg
          if (rate) paidToHoldersEthEquiv += (total * rate.weiPerUnit) / (10n ** 18n);
        } catch (_) { /* couldn't resolve a rate for this class — skip its contribution */ }
      }
    }));

    let ethSpentOnBuybacks = 0n;
    let castleBurned = 0n;
    if (deployment.buyback) {
      const buyback = new ethers.Contract(deployment.buyback, BUYBACK_ABI, provider);
      const events = await buyback.queryFilter(buyback.filters.BuybackExecuted(), fromBlock, "latest");
      ethSpentOnBuybacks = events.reduce((sum, e) => sum + e.args.ethIn, 0n);
      castleBurned = events.reduce((sum, e) => sum + e.args.tokensBurned, 0n);
    }

    return { paidToHoldersEthEquiv, ethSpentOnBuybacks, castleBurned };
  });
}

/** Estimates the block N seconds in the past by empirically measuring this
 *  chain's actual seconds-per-block from two real blocks, rather than
 *  assuming a fixed block time — a wrong hardcoded guess would silently
 *  mis-scope every "last 24h" style query. Falls back to a 2s/block
 *  assumption only if the chain is too young to have a distinct sample
 *  block yet (can't divide by zero blocks of difference). */
async function _estimateBlockSecondsAgo(provider, seconds) {
  const latest = await provider.getBlock("latest");
  const sampleNumber = Math.max(0, latest.number - 5000);
  const sample = sampleNumber === latest.number ? latest : await provider.getBlock(sampleNumber);
  const blockDelta = latest.number - sample.number;
  const secondsPerBlock = blockDelta > 0 ? (latest.timestamp - sample.timestamp) / blockDelta : 2;
  const blocksAgo = Math.ceil(seconds / Math.max(secondsPerBlock, 0.001));
  return Math.max(0, latest.number - blocksAgo);
}

/**
 * Headline protocol-wide stats for the homepage's dark stats strip, read
 * straight from chain like everything else here:
 *   - markets: total launches ever created.
 *   - properties: distinct property classes that have actually been used
 *     as a launch's pairing so far (not the fixed 20-class catalog size —
 *     this one only grows as classes actually get used).
 *   - volume24hEthEquiv: every market's buy/sell volume from roughly the
 *     last 24h, each converted to an ETH-equivalent using that market's
 *     quote asset's *current* rate (same approach as fetchRewardsStats).
 *     "Roughly" because the 24h cutoff is a block-number estimate (see
 *     _estimateBlockSecondsAgo), not a per-trade timestamp lookup — exact
 *     would mean one extra RPC call per unique block across every trade.
 *   - valueLockedEthEquiv: net ETH-equivalent currently sitting in every
 *     market's pool (cumulative buys minus cumulative sells, all-time),
 *     same ETH-equivalent conversion. An approximation, not a real TVL
 *     read of each pool's actual reserves — those aren't a simple balance
 *     check under Uniswap v4's singleton PoolManager accounting.
 */
async function fetchProtocolStats() {
  return _cachedRead("fetchProtocolStats", async () => {
    const deployment = await loadDeployment();
    if (!deployment || typeof ethers === "undefined") return null;
    const provider = _readProvider(deployment);

    const launches = await fetchAllLaunches();
    const markets = launches.length;
    const properties = new Set(launches.map((l) => l.propertyClass).filter(Boolean)).size;

    const cutoffBlock = await _estimateBlockSecondsAgo(provider, 24 * 60 * 60);

    let volume24hEthEquiv = 0n;
    let valueLockedEthEquiv = 0n;
    await Promise.all(launches.map(async (l) => {
      const trades = await fetchRecentTrades(l.launchId, Number.MAX_SAFE_INTEGER);
      let rateWeiPerUnit = 10n ** 18n; // ETH-quoted: 1:1, no conversion needed
      if (l.quoteAsset !== ethers.ZeroAddress) {
        try {
          const rate = await readPropertyCoin(l.propertyClass, null);
          if (rate) rateWeiPerUnit = rate.weiPerUnit;
        } catch (_) { /* couldn't resolve a rate — this market's contribution stays at 0 */ }
      }
      for (const t of trades) {
        const quoteAmount = t.isBuy ? t.ethIn : t.ethOut;
        const ethEquiv = (quoteAmount * rateWeiPerUnit) / (10n ** 18n);
        if (t.blockNumber >= cutoffBlock) volume24hEthEquiv += ethEquiv;
        valueLockedEthEquiv += t.isBuy ? ethEquiv : -ethEquiv;
      }
    }));
    if (valueLockedEthEquiv < 0n) valueLockedEthEquiv = 0n; // shouldn't happen, but never show a negative TVL

    return { markets, properties, volume24hEthEquiv, valueLockedEthEquiv };
  });
}

/** Pulls a market's accrued LP fees out of its two Uniswap v4 positions
 *  and routes them 40% holders / 30% buyback / 30% protocol. Permissionless
 *  — anyone holding no stake in the market can call this for anyone else's
 *  benefit, there's no keeper and no restriction on who triggers it. */
async function collectFeesOnMarket(launchId) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  const deployment = await loadDeployment();
  if (!deployment) throw new Error("No live deployment found yet.");
  if (!_getProvider()) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  const launchpad = new ethers.Contract(deployment.launchpad, LAUNCHPAD_ABI, signer);
  const tx = await launchpad.collectFees(launchId);
  const receipt = await tx.wait();
  _invalidateReadCache();
  return { txHash: receipt.hash };
}

/** Swaps every ETH balance Buyback.sol holds for the platform token and
 *  burns it. Permissionless — anyone can trigger this, anytime, whether
 *  or not they hold the platform token themselves. */
async function executeBuyback() {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  const deployment = await loadDeployment();
  if (!deployment || !deployment.buyback) throw new Error("No live deployment found yet.");
  if (!_getProvider()) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  const buyback = new ethers.Contract(deployment.buyback, BUYBACK_ABI, signer);
  const tx = await buyback.executeBuyback();
  const receipt = await tx.wait();
  _invalidateReadCache();
  return { txHash: receipt.hash };
}

/** Buy into an existing market with ETH, through LaunchRouter. Works
 *  identically whether the price is inside the curve range or the
 *  reserve range above the cap. */
async function buyOnMarket(launchId, ethIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  const deployment = await loadDeployment();
  if (!deployment) throw new Error("No live deployment found yet.");
  if (!_getProvider()) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  const router = new ethers.Contract(deployment.launchRouter, ROUTER_ABI, signer);
  const tx = await router.buy(launchId, 0n, { value: ethIn });
  const receipt = await tx.wait();
  _invalidateReadCache();
  return { txHash: receipt.hash };
}

/**
 * Buy into a market using USDG or a property class coin instead of ETH
 * directly — same convenience path the old curve offered. There's no
 * contract path that takes the coin straight in; this chains two real
 * transactions the coin already supports: redeem the coin for the exact
 * ETH backing it (read back from the coin's own Redeemed event, not
 * estimated), then buy through the router with that ETH. Two wallet
 * confirmations, not one — an honest tradeoff of front-end orchestration
 * rather than a single contract call.
 */
async function buyOnMarketWithCoin(launchId, coinAddress, coinAmountIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  const deployment = await loadDeployment();
  if (!deployment) throw new Error("No live deployment found yet.");
  if (!_getProvider()) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  const coin = new ethers.Contract(coinAddress, PROPERTY_COIN_ABI, signer);

  const redeemTx = await coin.redeem(coinAmountIn, 0n);
  const redeemReceipt = await redeemTx.wait();

  const iface = new ethers.Interface(PROPERTY_COIN_ABI.concat([
    "event Redeemed(address indexed who, uint256 coinIn, uint256 ethOut)",
  ]));
  let ethOut = null;
  for (const log of redeemReceipt.logs) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed && parsed.name === "Redeemed") ethOut = parsed.args.ethOut;
    } catch (_) { /* not our event */ }
  }
  if (ethOut === null) throw new Error("Couldn't confirm the redeem amount, try again.");

  const router = new ethers.Contract(deployment.launchRouter, ROUTER_ABI, signer);
  const buyTx = await router.buy(launchId, 0n, { value: ethOut });
  const buyReceipt = await buyTx.wait();

  _invalidateReadCache();
  return { redeemTxHash: redeemReceipt.hash, buyTxHash: buyReceipt.hash, ethUsed: ethOut };
}

/** Sell `tokenAmountIn` of a market's token back for its quote asset
 *  (ETH, or the property class coin if one was picked — LaunchRouter
 *  hands the coin itself to the seller, same as CME's own behavior).
 *  Needs one approval the first time (the router pulls the token via
 *  transferFrom), then sells. */
async function sellOnMarket(launchId, tokenAddress, tokenAmountIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  const deployment = await loadDeployment();
  if (!deployment) throw new Error("No live deployment found yet.");
  if (!_getProvider()) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  const account = await signer.getAddress();
  const token = new ethers.Contract(tokenAddress, TOKEN_ABI, signer);
  const router = new ethers.Contract(deployment.launchRouter, ROUTER_ABI, signer);

  const allowanceIface = new ethers.Interface(["function allowance(address,address) view returns (uint256)"]);
  const data = allowanceIface.encodeFunctionData("allowance", [account, deployment.launchRouter]);
  const raw = await provider.call({ to: tokenAddress, data });
  const [allowance] = allowanceIface.decodeFunctionResult("allowance", raw);

  if (allowance < tokenAmountIn) {
    const approveTx = await token.approve(deployment.launchRouter, tokenAmountIn);
    await approveTx.wait();
  }

  const tx = await router.sell(launchId, tokenAmountIn, 0n);
  const receipt = await tx.wait();
  _invalidateReadCache();
  return { txHash: receipt.hash };
}

/** A market token holder's currently-unclaimed reward share, and (if a
 *  wallet is connected) a way to claim it — paid in the market's quote
 *  asset (ETH, or the class coin), pull-based, no keeper. */
async function fetchEarnedRewards(tokenAddress, account) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined" || !account) return 0n;
  const provider = _readProvider(deployment);
  const token = new ethers.Contract(tokenAddress, TOKEN_ABI, provider);
  return token.earned(account);
}

async function claimMarketRewards(tokenAddress) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  if (!_getProvider()) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(_getProvider());
  const signer = await provider.getSigner();
  const token = new ethers.Contract(tokenAddress, TOKEN_ABI, signer);
  const tx = await token.claimRewards();
  const receipt = await tx.wait();
  _invalidateReadCache();
  return { txHash: receipt.hash };
}

/* ---------------------------------------------------------------------- */
/* Glyph renderer, small elevation-sketch icons per property class       */
/* ---------------------------------------------------------------------- */

function parcelGlyph(cfg) {
  const stroke = 'stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"';
  const W = 64, H = 56, base = 44;

  if (cfg.type === "couch") {
    return `<svg viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">
      <line x1="4" y1="${base}" x2="60" y2="${base}" ${stroke} stroke-opacity="0.4"/>
      <path d="M10 34 v-6 a4 4 0 0 1 4-4 h30 a4 4 0 0 1 4 4 v6" ${stroke}/>
      <path d="M8 34 v10 a2 2 0 0 0 2 2 h2 v-6 h36 v6 h2 a2 2 0 0 0 2-2 v-10 a3 3 0 0 0-3-3 H11 a3 3 0 0 0-3 3 z" ${stroke}/>
      <line x1="12" y1="46" x2="12" y2="50" ${stroke}/>
      <line x1="46" y1="46" x2="46" y2="50" ${stroke}/>
    </svg>`;
  }

  const w = cfg.w || 36, h = cfg.h || 20;
  const x0 = (W - w) / 2, y0 = base - h;
  let out = `<svg viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">`;
  out += `<line x1="4" y1="${base}" x2="60" y2="${base}" ${stroke} stroke-opacity="0.4"/>`;

  // body
  out += `<rect x="${x0}" y="${y0}" width="${w}" height="${h}" ${stroke}/>`;
  if (cfg.corrugated) {
    for (let x = x0 + 4; x < x0 + w - 2; x += 5) {
      out += `<line x1="${x}" y1="${y0}" x2="${x}" y2="${y0 + h}" ${stroke} stroke-width="1" stroke-opacity="0.5"/>`;
    }
  }
  if (cfg.patched) {
    out += `<line x1="${x0 + 4}" y1="${y0 + 4}" x2="${x0 + w - 6}" y2="${y0 + h - 4}" ${stroke} stroke-width="1"/>`;
  }
  if (cfg.stacked) {
    const rows = 3;
    for (let i = 1; i < rows; i++) {
      const y = y0 + (h / rows) * i;
      out += `<line x1="${x0}" y1="${y}" x2="${x0 + w}" y2="${y}" ${stroke} stroke-width="1" stroke-opacity="0.6"/>`;
    }
  }

  // roof
  const roof = cfg.roof || "flat";
  if (roof === "gable") {
    out += `<path d="M${x0 - 4} ${y0} L${x0 + w / 2} ${y0 - 14} L${x0 + w + 4} ${y0}" ${stroke}/>`;
    if (cfg.chimney) out += `<line x1="${x0 + w - 10}" y1="${y0 - 8}" x2="${x0 + w - 10}" y2="${y0 - 20}" ${stroke}/>`;
  } else if (roof === "hip") {
    out += `<path d="M${x0 - 4} ${y0} L${x0 + w * 0.3} ${y0 - 10} L${x0 + w * 0.7} ${y0 - 10} L${x0 + w + 4} ${y0}" ${stroke}/>`;
    if (cfg.wings) {
      out += `<rect x="${x0 - 14}" y="${y0 + h * 0.3}" width="10" height="${h * 0.7}" ${stroke}/>`;
      out += `<rect x="${x0 + w + 4}" y="${y0 + h * 0.3}" width="10" height="${h * 0.7}" ${stroke}/>`;
    }
  } else if (roof === "tent") {
    out += `<path d="M${x0 - 6} ${y0 + h} L${x0 + w / 2} ${y0 - 12} L${x0 + w + 6} ${y0 + h}" ${stroke}/>`;
    out.replace(`<rect x="${x0}" y="${y0}" width="${w}" height="${h}" ${stroke}/>`, "");
  } else if (roof === "lean") {
    out += `<line x1="${x0 - 4}" y1="${y0 + h * 0.3}" x2="${x0 + w + 4}" y2="${y0}" ${stroke}/>`;
  } else if (roof === "curve") {
    out += `<path d="M${x0} ${y0} Q${x0 + w / 2} ${y0 - 12} ${x0 + w} ${y0}" ${stroke}/>`;
  } else if (roof === "dome") {
    out += `<path d="M${x0 + 2} ${y0} Q${x0 + w / 2} ${y0 - 16} ${x0 + w - 2} ${y0}" ${stroke}/>`;
  } // flat: none needed, top of rect is the roofline

  // door
  if (cfg.door) {
    const dw = Math.min(8, w / (cfg.door * 3));
    for (let i = 0; i < cfg.door; i++) {
      const dx = x0 + w / 2 - (cfg.door * (dw + 4)) / 2 + i * (dw + 4);
      out += `<rect x="${dx}" y="${base - 12}" width="${dw}" height="12" ${stroke}/>`;
    }
  }

  // windows
  const winCount = cfg.windows || 0;
  if (winCount) {
    const cols = Math.min(winCount, 4);
    const rows = Math.ceil(winCount / cols);
    const pad = 4;
    const cellW = (w - pad * 2) / cols;
    for (let i = 0; i < winCount; i++) {
      const col = i % cols, row = Math.floor(i / cols);
      const wx = x0 + pad + col * cellW + cellW / 2 - 3;
      const wy = y0 + 5 + row * ((h - 10) / rows);
      out += `<rect x="${wx}" y="${wy}" width="6" height="6" ${stroke} stroke-width="1.4"/>`;
    }
  }

  // wheels
  if (cfg.wheels) {
    const positions = cfg.wheels === 2
      ? [x0 + w * 0.25, x0 + w * 0.75]
      : [x0 + w * 0.18, x0 + w * 0.5, x0 + w * 0.82];
    positions.forEach((cx) => {
      out += `<circle cx="${cx}" cy="${base + 3}" r="3.4" ${stroke}/>`;
    });
  }

  // silo (farm)
  if (cfg.silo) {
    out += `<rect x="${x0 + w + 6}" y="${base - 30}" width="9" height="30" rx="4" ${stroke}/>`;
    out += `<path d="M${x0 + w + 6} ${base - 30} q4.5 -8 9 0" ${stroke}/>`;
  }

  // sign (commercial)
  if (cfg.sign) {
    out += `<rect x="${x0}" y="${y0 - 10}" width="${w * 0.4}" height="7" ${stroke} stroke-width="1.4"/>`;
  }

  out += "</svg>";
  return out;
}

function renderClassTile(cls, { withGlyph = true } = {}) {
  return `
    <article class="tile" data-ticker="${cls.ticker}">
      <span class="tier tier-${cls.tier}">${TIER_LABEL[cls.tier]}</span>
      ${withGlyph ? `<div class="glyph">${parcelGlyph(cls.glyph)}</div>` : ""}
      <div class="ticker">${cls.displayName || cls.ticker}</div>
      <div class="label">${cls.label} <span style="font-family:var(--font-mono); opacity:0.55;">$${cls.ticker}</span></div>
      <div class="unit">${cls.unit}</div>
      <div class="tile-price" data-price-for="${cls.ticker}" style="margin-top:8px; font-family:var(--font-mono); font-size:12px; color:var(--brass-bright);"></div>
    </article>`;
}

/** Looks up a property class's full display name from its on-chain
 *  ticker (e.g. "HOUS" -> "House") for UI text. Falls back to the raw
 *  ticker for USDG or anything not found, so it's always safe to call. */
function classDisplayName(ticker) {
  if (!ticker) return ticker;
  if (ticker === "USDG") return "USDG";
  const cls = PROPERTY_CLASSES.find((c) => c.ticker === ticker);
  return cls ? cls.displayName : ticker;
}

/* ---------------------------------------------------------------------- */
/* Curve preview math — an ESTIMATE only, for launch.html's "you'll get   */
/* about N tokens" preview before a real transaction. The real pricing on */
/* Launchpad.sol is genuine Uniswap v4 concentrated liquidity across two  */
/* ranges, not a constant-product virtual curve — replicating that exactly*/
/* in JS would mean porting v4's full tick-crossing swap math. This keeps */
/* the same constant-product *shape* the old BondingCurve used, resized so*/
/* it opens around the new $5,000 cap at a $3,500/ETH reference, which is */
/* close enough for a pre-transaction estimate. minTokensOut is always 0  */
/* on-chain either way, so nothing here affects actual slippage safety.  */
/* ---------------------------------------------------------------------- */

const CURVE = {
  totalSupply: 1_000_000_000,
  curveSupply: 800_000_000,
  reserveSupply: 200_000_000,
  virtualEthReserve: (5_000 / 3_500) * (1_073_000_000 / 1_000_000_000), // ~1.53 ETH, opens near $5,000 at $3,500/ETH
  virtualTokenReserve: 1_073_000_000,
};

/** Fixed virtual reserves, straight from the constants above, this is a
 *  read, not a derivation; the contract doesn't compute these from
 *  anything either. */
function virtualReserves() {
  return {
    virtualTokens: CURVE.virtualTokenReserve,
    virtualEth: CURVE.virtualEthReserve,
  };
}

/** Estimate tokens received for `ethIn` ETH, given `tokensSoldSoFar` have
 *  already sold on the curve range. A constant-product approximation for
 *  launch.html's pre-transaction preview only — see the CURVE block
 *  comment above for why this isn't the real Launchpad.sol math. */
function quoteBuy(ethIn, tokensSoldSoFar) {
  const { virtualTokens, virtualEth } = virtualReserves();
  const tIn = tokensSoldSoFar;
  const ethReserve = virtualEth + (tIn > 0 ? (virtualTokens * virtualEth) / (virtualTokens - tIn) - virtualEth : 0);
  const tokenReserve = virtualTokens - tIn;
  const k = ethReserve * tokenReserve;
  const newEthReserve = ethReserve + ethIn;
  const newTokenReserve = k / newEthReserve;
  const tokensOut = tokenReserve - newTokenReserve;
  return Math.max(0, tokensOut);
}

window.Parcel = {
  parcelGlyph, renderClassTile, classDisplayName, virtualReserves, quoteBuy, CURVE,
  connectWallet, disconnectWallet, loadDeployment, submitLaunch, ensureRobinhoodChain, RH_MAINNET,
  mintPropertyCoin, redeemPropertyCoin, readPropertyCoin, fetchPropertyCoinFullState, fetchPropertyCoinActivity,
  fetchAllLaunches, fetchLaunchById, decodeMetadata, escapeHtml, resizeImageToDataUri, priceFromSqrtPriceX96, curveProgressPct,
  fetchMarketState, fetchRecentTrades, fetchMarketVolumeEth, buyOnMarket, buyOnMarketWithCoin, sellOnMarket,
  fetchEarnedRewards, claimMarketRewards, fetchRewardsStats, fetchProtocolStats, collectFeesOnMarket, executeBuyback,
  mapWithConcurrency,
};
