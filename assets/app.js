/**
 * app.js, shared front-end logic for CASTLE.
 *
 * Robinhood Chain Testnet is wired for real: RH_CHAIN below is the
 * network's actual public details, and `loadDeployment()` fetches
 * deployments/testnet.json, written by script/Deploy.s.sol, to learn
 * the live ParcelFactory address. Launches are ETH-native: connect a
 * wallet, send ETH, get tokens. No pair coin, no minting step, nothing to
 * approve before your first buy. Until deployments/testnet.json has a
 * real factory address in it (see DEPLOY.md), the site runs in
 * preview-only mode: everything renders and the bonding-curve math is
 * real, but "Launch" won't submit a transaction.
 */

const RH_CHAIN = {
  chainName: "Robinhood Chain Testnet",
  chainIdHex: "0xb626", // 46630
  rpcUrls: ["https://rpc.testnet.chain.robinhood.com"],
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  blockExplorerUrls: ["https://explorer.testnet.chain.robinhood.com"],
};

// Minimal ABI fragments, just what the site calls.
const FACTORY_ABI = [
  "function createLaunch(string name_, string symbol_, address pairCoin_, uint16 feeBps, string metadataURI, uint256 minTokensOut) payable returns (uint256 launchId, address curveAddr)",
  "function launchCount() view returns (uint256)",
  "function launches(uint256) view returns (address curve, address token, address pairCoin, string propertyClass, address creator, string metadataURI, uint64 createdAt)",
  "event LaunchCreated(uint256 indexed launchId, address indexed creator, address curve, address token, address pairCoin, string propertyClass, uint16 feeBps, string metadataURI)",
];
const CURVE_ABI = [
  "function buy(uint256 minTokensOut) payable returns (uint256 tokensOut)",
  "function sell(uint256 tokenAmountIn, uint256 minEthOut) returns (uint256 ethOut)",
  "function token() view returns (address)",
  "function pairCoin() view returns (address)",
  "function propertyClass() view returns (string)",
  "function creator() view returns (address)",
  "function feeBps() view returns (uint16)",
  "function tokensSold() view returns (uint256)",
  "function migrated() view returns (bool)",
  "function CURVE_SUPPLY() view returns (uint256)",
  "function TOTAL_SUPPLY() view returns (uint256)",
  "function virtualEthReserve() view returns (uint256)",
  "function virtualTokenReserve() view returns (uint256)",
  "event Trade(address indexed trader, bool isBuy, uint256 ethIn, uint256 tokensOut, uint256 ethOut, uint256 tokensIn)",
];
const TOKEN_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
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

/* ---------------------------------------------------------------------- */
/* Deployment loader, reads deployments/testnet.json                     */
/* ---------------------------------------------------------------------- */

let deploymentCache = null;

/** Fetches deployments/testnet.json once and caches it. Returns null
 *  (rather than throwing) if it's missing or still the unfilled
 *  placeholder, so callers can fall back to preview mode. */
async function loadDeployment() {
  if (deploymentCache !== undefined && deploymentCache !== null) return deploymentCache;
  try {
    const res = await fetch("deployments/testnet.json", { cache: "no-store" });
    if (!res.ok) return null;
    const json = await res.json();
    if (!json.factory) return null; // still the placeholder
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

async function ensureRobinhoodTestnet() {
  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: RH_CHAIN.chainIdHex }],
    });
  } catch (switchErr) {
    // 4902 = chain not added to the wallet yet
    if (switchErr.code === 4902) {
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [RH_CHAIN],
      });
    } else {
      throw switchErr;
    }
  }
}

async function connectWallet() {
  const btn = document.querySelector("[data-connect]");
  if (!window.ethereum) {
    alert("No injected wallet found. Install MetaMask, Rabby, or Coinbase Wallet to launch on Robinhood Chain.");
    return;
  }
  try {
    const accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
    currentAccount = accounts[0];
    await ensureRobinhoodTestnet();
    if (btn) {
      btn.dataset.connected = "true";
      btn.textContent = currentAccount.slice(0, 6) + "…" + currentAccount.slice(-4);
    }
    document.dispatchEvent(new CustomEvent("parcel:connected", { detail: currentAccount }));
  } catch (err) {
    console.error("wallet connect failed", err);
    alert("Couldn't connect: " + (err.message || err));
  }
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-connect]").forEach((btn) => {
    btn.addEventListener("click", connectWallet);
  });
  loadDeployment(); // warm the cache; pages read it via Parcel.loadDeployment()
});

/* ---------------------------------------------------------------------- */
/* Launch submission, real createLaunch() call via ethers v6             */
/* ---------------------------------------------------------------------- */

/**
 * Submits a launch to the deployed ParcelFactory. Requires ethers v6 to
 * be loaded on the page and a deployment to exist. One transaction,
 * ETH-native, no approval step. `pairCoinAddress` is optional: pass a
 * PropertyClassCoin address to pick a class (migration seeds two pools),
 * or omit/pass null for no class (single ETH pool at migration).
 *
 * @returns {Promise<{launchId: string, curve: string, token: string, txHash: string}>}
 */
async function submitLaunch({ name, symbol, pairCoinAddress, feeBps, metadataURI, firstBuyIn }) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  const deployment = await loadDeployment();
  if (!deployment) throw new Error("No live deployment found yet. See DEPLOY.md to deploy the contracts first.");
  if (!window.ethereum) throw new Error("No wallet connected.");

  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer = await provider.getSigner();
  const factory = new ethers.Contract(deployment.factory, FACTORY_ABI, signer);

  const pairCoin = pairCoinAddress || ethers.ZeroAddress;
  const tx = await factory.createLaunch(name, symbol, pairCoin, feeBps, metadataURI, 0n, { value: firstBuyIn });
  const receipt = await tx.wait();

  const iface = new ethers.Interface(FACTORY_ABI);
  let launchId = null, curve = null, token = null;
  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed && parsed.name === "LaunchCreated") {
        launchId = parsed.args.launchId.toString();
        curve = parsed.args.curve;
        token = parsed.args.token;
      }
    } catch (_) { /* not our event, ignore */ }
  }

  return { launchId, curve, token, txHash: receipt.hash };
}

/* ---------------------------------------------------------------------- */
/* Property-class coins, buy/sell against ETH at the fixed rate          */
/* ---------------------------------------------------------------------- */

/** Mint a property-class coin (or USDG) by sending ETH, at its fixed rate. */
async function mintPropertyCoin(coinAddress, ethIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  if (!window.ethereum) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer = await provider.getSigner();
  const coin = new ethers.Contract(coinAddress, PROPERTY_COIN_ABI, signer);
  const tx = await coin.mint(0n, { value: ethIn });
  const receipt = await tx.wait();
  return { txHash: receipt.hash };
}

/** Redeem a property-class coin (or USDG) back to ETH, at its fixed rate. */
async function redeemPropertyCoin(coinAddress, coinIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  if (!window.ethereum) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer = await provider.getSigner();
  const coin = new ethers.Contract(coinAddress, PROPERTY_COIN_ABI, signer);
  const tx = await coin.redeem(coinIn, 0n);
  const receipt = await tx.wait();
  return { txHash: receipt.hash };
}

/** Read-only: a property coin's fixed rate and (if a wallet is connected)
 *  the caller's balance of it. Uses the public RPC, no wallet required
 *  just to read the rate. */
async function readPropertyCoin(coinAddress, account) {
  const deployment = await loadDeployment();
  const provider = typeof ethers !== "undefined" && deployment
    ? new ethers.JsonRpcProvider(deployment.rpcUrl)
    : null;
  if (!provider) return null;
  const coin = new ethers.Contract(coinAddress, PROPERTY_COIN_ABI, provider);
  const weiPerUnit = await coin.weiPerUnit();
  const balance = account ? await coin.balanceOf(account) : 0n;
  return { weiPerUnit, balance };
}

/** Full live state for one property-class coin's own page: rate, current
 *  supply, and the ETH actually held as reserves (a plain balance check,
 *  the coin is fully collateralized by construction, so this should
 *  always equal supply × rate). */
async function fetchPropertyCoinFullState(coinAddress) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return null;
  const provider = new ethers.JsonRpcProvider(deployment.rpcUrl);
  const coin = new ethers.Contract(coinAddress, PROPERTY_COIN_ABI, provider);
  const [name, symbol, weiPerUnit, totalSupply, ethReserves] = await Promise.all([
    coin.name(), coin.symbol(), coin.weiPerUnit(), coin.totalSupply(), provider.getBalance(coinAddress),
  ]);
  return { name, symbol, weiPerUnit, totalSupply, ethReserves };
}

/** Every Minted/Redeemed event for one property-class coin, newest first,
 *  this coin's equivalent of a market's Trade history. */
async function fetchPropertyCoinActivity(coinAddress, maxResults = 50) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return [];
  const provider = new ethers.JsonRpcProvider(deployment.rpcUrl);
  const coin = new ethers.Contract(coinAddress, PROPERTY_COIN_ABI, provider);
  const [mints, redeems] = await Promise.all([
    coin.queryFilter(coin.filters.Minted(), 0, "latest"),
    coin.queryFilter(coin.filters.Redeemed(), 0, "latest"),
  ]);
  const all = [
    ...mints.map((e) => ({ type: "Mint", who: e.args.who, ethAmount: e.args.ethIn, coinAmount: e.args.coinOut, txHash: e.transactionHash, blockNumber: e.blockNumber, logIndex: e.index })),
    ...redeems.map((e) => ({ type: "Redeem", who: e.args.who, ethAmount: e.args.ethOut, coinAmount: e.args.coinIn, txHash: e.transactionHash, blockNumber: e.blockNumber, logIndex: e.index })),
  ];
  all.sort((a, b) => (a.blockNumber - b.blockNumber) || (a.logIndex - b.logIndex));
  return all.slice(-maxResults).reverse();
}

/* ---------------------------------------------------------------------- */
/* Reading live launches + a single market's state, straight from chain   */
/* ---------------------------------------------------------------------- */

/** Every launch ever created, read directly from ParcelFactory's on-chain
 *  array, no indexer. Returns [] if nothing's deployed yet. */
async function fetchAllLaunches() {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return [];
  const provider = new ethers.JsonRpcProvider(deployment.rpcUrl);
  const factory = new ethers.Contract(deployment.factory, FACTORY_ABI, provider);
  const count = Number(await factory.launchCount());
  const launches = [];
  for (let i = 0; i < count; i++) {
    const l = await factory.launches(i);
    launches.push({
      curve: l.curve, token: l.token, pairCoin: l.pairCoin,
      propertyClass: l.propertyClass, creator: l.creator,
      metadataURI: l.metadataURI, createdAt: Number(l.createdAt),
    });
  }
  return launches.reverse(); // newest first
}

/** Look up a single launch's on-chain record by its curve address, for
 *  pages (like market.html) that only have the curve address in the URL
 *  and need the metadataURI (name, links, image) that goes with it.
 *  Scans every launch client-side; fine at today's testnet scale. */
async function fetchLaunchByCurve(curveAddress) {
  const launches = await fetchAllLaunches();
  const target = curveAddress.toLowerCase();
  return launches.find((l) => l.curve.toLowerCase() === target) || null;
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

/** Full live state for one market's curve, plus its token's name/symbol,
 *  everything a trading page needs, all view calls. */
async function fetchCurveState(curveAddress) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return null;
  const provider = new ethers.JsonRpcProvider(deployment.rpcUrl);
  const curve = new ethers.Contract(curveAddress, CURVE_ABI, provider);
  const tokenAddr = await curve.token();
  const token = new ethers.Contract(tokenAddr, TOKEN_ABI, provider);

  const [name, symbol, pairCoin, propertyClass, creator, feeBps, tokensSold, migrated, curveSupply, totalSupply, virtualEth, virtualToken] =
    await Promise.all([
      token.name(), token.symbol(), curve.pairCoin(), curve.propertyClass(), curve.creator(),
      curve.feeBps(), curve.tokensSold(), curve.migrated(), curve.CURVE_SUPPLY(), curve.TOTAL_SUPPLY(),
      curve.virtualEthReserve(), curve.virtualTokenReserve(),
    ]);

  return {
    tokenAddr, name, symbol, pairCoin, propertyClass, creator,
    feeBps: Number(feeBps), tokensSold, migrated, curveSupply, totalSupply,
    virtualEth, virtualToken,
  };
}

/** Recent Trade events for one curve, straight from chain logs, this is
 *  a trade list, not a price chart (no candles/OHLC aggregation here). */
async function fetchRecentTrades(curveAddress, maxResults = 50) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return [];
  const provider = new ethers.JsonRpcProvider(deployment.rpcUrl);
  const curve = new ethers.Contract(curveAddress, CURVE_ABI, provider);
  const events = await curve.queryFilter(curve.filters.Trade(), 0, "latest");
  return events.slice(-maxResults).reverse().map((e) => ({
    trader: e.args.trader, isBuy: e.args.isBuy,
    ethIn: e.args.ethIn, tokensOut: e.args.tokensOut,
    ethOut: e.args.ethOut, tokensIn: e.args.tokensIn,
    txHash: e.transactionHash,
  }));
}

/** Total ETH traded on one curve, ever, sums every Trade event's ethIn
 *  (buys) and ethOut (sells). Real, not estimated, but does mean scanning
 *  every log for that curve; fine at today's testnet volumes. */
async function fetchMarketVolumeEth(curveAddress) {
  const deployment = await loadDeployment();
  if (!deployment || typeof ethers === "undefined") return 0n;
  const provider = new ethers.JsonRpcProvider(deployment.rpcUrl);
  const curve = new ethers.Contract(curveAddress, CURVE_ABI, provider);
  const events = await curve.queryFilter(curve.filters.Trade(), 0, "latest");
  return events.reduce((sum, e) => sum + (e.args.isBuy ? e.args.ethIn : e.args.ethOut), 0n);
}

/** Buy on an existing curve, same shape as a launch's first buy. */
async function buyOnCurve(curveAddress, ethIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  if (!window.ethereum) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer = await provider.getSigner();
  const curve = new ethers.Contract(curveAddress, CURVE_ABI, signer);
  const tx = await curve.buy(0n, { value: ethIn });
  const receipt = await tx.wait();
  return { txHash: receipt.hash };
}

/**
 * Buy into a curve using USDG or a property class coin instead of ETH
 * directly, pre-migration, same as every other buy. There's no contract
 * path that takes the coin straight in; this chains two real
 * transactions the coin already supports: redeem the coin for the exact
 * ETH backing it (read back from the coin's own Redeemed event, not
 * estimated), then buy on the curve with that ETH. Two wallet
 * confirmations, not one, that's an honest tradeoff of this being
 * front-end orchestration rather than a single contract call.
 */
async function buyOnCurveWithCoin(curveAddress, coinAddress, coinAmountIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  if (!window.ethereum) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(window.ethereum);
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

  const curve = new ethers.Contract(curveAddress, CURVE_ABI, signer);
  const buyTx = await curve.buy(0n, { value: ethOut });
  const buyReceipt = await buyTx.wait();

  return { redeemTxHash: redeemReceipt.hash, buyTxHash: buyReceipt.hash, ethUsed: ethOut };
}

/** Sell on an existing curve. Needs one approval the first time (the
 *  curve pulls the launch token via transferFrom), then sells. */
async function sellOnCurve(curveAddress, tokenAddress, tokenAmountIn) {
  if (typeof ethers === "undefined") throw new Error("ethers.js didn't load, check your connection and reload.");
  if (!window.ethereum) throw new Error("No wallet connected.");
  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer = await provider.getSigner();
  const account = await signer.getAddress();
  const token = new ethers.Contract(tokenAddress, TOKEN_ABI, signer);
  const curve = new ethers.Contract(curveAddress, CURVE_ABI, signer);

  // ERC20 allowance isn't in TOKEN_ABI's minimal set, check via a raw call.
  const allowanceIface = new ethers.Interface(["function allowance(address,address) view returns (uint256)"]);
  const data = allowanceIface.encodeFunctionData("allowance", [account, curveAddress]);
  const raw = await provider.call({ to: tokenAddress, data });
  const [allowance] = allowanceIface.decodeFunctionResult("allowance", raw);

  if (allowance < tokenAmountIn) {
    const approveTx = await token.approve(curveAddress, tokenAmountIn);
    await approveTx.wait();
  }

  const tx = await curve.sell(tokenAmountIn, 0n);
  const receipt = await tx.wait();
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
/* Bonding curve math, mirrors contracts/BondingCurve.sol                */
/* ---------------------------------------------------------------------- */

const CURVE = {
  totalSupply: 1_000_000_000,
  curveSupply: 800_000_000,
  reserveSupply: 200_000_000,
  virtualEthReserve: 3,             // ETH, matches BondingCurve.VIRTUAL_ETH_RESERVE
  virtualTokenReserve: 1_073_000_000, // matches BondingCurve.VIRTUAL_TOKEN_RESERVE
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
 *  already sold on the curve. Mirrors BondingCurve.buy's constant-product
 *  math (ignoring the trading fee, which the UI shows separately). */
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
  connectWallet, loadDeployment, submitLaunch, ensureRobinhoodTestnet, RH_CHAIN,
  mintPropertyCoin, redeemPropertyCoin, readPropertyCoin, fetchPropertyCoinFullState, fetchPropertyCoinActivity,
  fetchAllLaunches, fetchLaunchByCurve, decodeMetadata, escapeHtml, resizeImageToDataUri,
  fetchCurveState, fetchRecentTrades, fetchMarketVolumeEth, buyOnCurve, buyOnCurveWithCoin, sellOnCurve,
};
