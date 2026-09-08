/**
 * app.js — shared front-end logic for Parcel.
 *
 * This is a static demo: there is no backend and no live chain
 * connection wired up yet. `connectWallet()` and the launch form use
 * the ethers.js CDN build so the plumbing (address, chainId, a real
 * signed tx to the contracts in /contracts) is a few lines away from
 * working once RH_CHAIN below is pointed at a live RPC and the
 * factory address is filled in.
 */

const RH_CHAIN = {
  chainName: "Robinhood Chain",
  chainIdHex: "0x971b",     // placeholder — replace with the real chain id
  rpcUrls: ["https://replace-with-robinhood-chain-rpc"],
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  blockExplorerUrls: ["https://robinhoodchain.blockscout.com"],
};

const FACTORY_ADDRESS = "0x0000000000000000000000000000000000dEaD"; // TODO: deployed factory

/* ---------------------------------------------------------------------- */
/* Wallet connect (stub, wired for ethers v6 via CDN)                     */
/* ---------------------------------------------------------------------- */

let currentAccount = null;

async function connectWallet() {
  const btn = document.querySelector("[data-connect]");
  if (!window.ethereum) {
    alert("No injected wallet found. Install MetaMask, Rabby, or Coinbase Wallet to launch on Robinhood Chain.");
    return;
  }
  try {
    const accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
    currentAccount = accounts[0];
    if (btn) {
      btn.dataset.connected = "true";
      btn.textContent = currentAccount.slice(0, 6) + "…" + currentAccount.slice(-4);
    }
    document.dispatchEvent(new CustomEvent("parcel:connected", { detail: currentAccount }));
  } catch (err) {
    console.error("wallet connect failed", err);
  }
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-connect]").forEach((btn) => {
    btn.addEventListener("click", connectWallet);
  });
});

/* ---------------------------------------------------------------------- */
/* Glyph renderer — small elevation-sketch icons per property class       */
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
      <div class="ticker">${cls.ticker}</div>
      <div class="label">${cls.label}</div>
      <div class="unit">${cls.unit}</div>
    </article>`;
}

/* ---------------------------------------------------------------------- */
/* Bonding curve math — mirrors contracts/BondingCurve.sol                */
/* ---------------------------------------------------------------------- */

const CURVE = {
  totalSupply: 1_000_000_000,
  curveSupply: 800_000_000,
  reserveSupply: 200_000_000,
  openCapUSD: 5_000,
  migrateCapUSD: 35_000,
};

/**
 * Constant-product virtual curve, parameterised so it opens at
 * openCapUSD and finishes at migrateCapUSD once all curveSupply
 * tokens are sold. See contracts/BondingCurve.sol `_virtualReserves`
 * for the on-chain version of this same formula.
 */
function virtualReserves() {
  const { curveSupply, openCapUSD, migrateCapUSD, totalSupply } = CURVE;
  const startPrice = openCapUSD / totalSupply;
  const endPrice = migrateCapUSD / totalSupply;
  const k = startPrice * (curveSupply * (endPrice / startPrice)) / (endPrice / startPrice - 1) * -1;
  // Simplify with explicit virtual reserves instead (more stable numerically):
  const virtualTokens = curveSupply / (Math.sqrt(endPrice / startPrice) - 1);
  const virtualPair = virtualTokens * startPrice;
  return { virtualTokens, virtualPair, startPrice, endPrice };
}

function quoteBuy(pairAmountIn, tokensSoldSoFar) {
  const { virtualTokens, virtualPair } = virtualReserves();
  const tIn = tokensSoldSoFar;
  const pairReserve = virtualPair + (tIn > 0 ? (virtualTokens * virtualPair) / (virtualTokens - tIn) - virtualPair : 0);
  const tokenReserve = virtualTokens - tIn;
  const k = pairReserve * tokenReserve;
  const newPairReserve = pairReserve + pairAmountIn;
  const newTokenReserve = k / newPairReserve;
  const tokensOut = tokenReserve - newTokenReserve;
  return Math.max(0, tokensOut);
}

window.Parcel = { parcelGlyph, renderClassTile, virtualReserves, quoteBuy, CURVE, connectWallet };
