/**
 * brand.js , CASTLE brand layer (PROTOTYPE)
 * ------------------------------------------------------------------
 * Brand only. It does not build, move or reorder anything: it finds the
 * tiles the existing pages already rendered and hands each one its own
 * colour as a CSS variable. Everything visual is done in brand.css.
 *
 * Twenty colours, one per class, taken from the property-board palette and
 * run cheapest to dearest. No browns or tans , every step stays a saturated
 * board hue, and each tier holds a hue family so the ladder reads at a
 * glance: novelty purples, mobile blues into magentas, residential oranges
 * into reds, estate yellows into greens into deep blue.
 */

const CLASS_COLOR = {
  // novelty , purples into light blue
  COUCH: "#B06BD4",
  TENT:  "#9B4DBF",
  LEAN:  "#7B2D8E",
  SHED:  "#AAE0FA",
  // mobile , blues into magentas
  VAN:   "#6FC3EE",
  CTNR:  "#2FA8C7",
  TRLR:  "#F06CB0",
  RV:    "#D93A96",
  TINY:  "#A61E6D",
  // residential , oranges into reds
  SHTY:  "#FBB040",
  CABN:  "#F7941D",
  CNDO:  "#E2701A",
  HOUS:  "#F4534B",
  DPLX:  "#ED1B24",
  TOWN:  "#B5121A",
  // estate , yellows into greens into deep blue
  HIRS:  "#FFE44D",
  COMM:  "#EBCE1C",   // was #FEF200, which read neon
  FARM:  "#56C878",
  VILA:  "#1FB25A",
  MANR:  "#0072BB",
  // the stablecoin sits outside the ladder
  USDG:  "#5B6A66",   // sits outside the ladder, so it stays neutral
};

/* Pick black or white for the label sitting on the colour block. Twenty
   hues from near-white light blue to deep navy means one fixed ink colour
   would be unreadable on several of them. */
function readableInk(hex) {
  const n = parseInt(hex.slice(1), 16);
  const chan = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  });
  const L = 0.2126 * chan[0] + 0.7152 * chan[1] + 0.0722 * chan[2];
  return L > 0.42 ? "#0B0B0B" : "#FFFFFF";
}

/* Real class art. Add a file to assets/class-art/ and a line here, and the
   tile swaps its line glyph for the render. Anything without an entry keeps
   the glyph, so the set can land one class at a time. */
const CLASS_ART = {
  COUCH: "assets/class-art/couch.png",
  TENT:  "assets/class-art/tent.png",
  LEAN:  "assets/class-art/lean-to.png",
  SHED:  "assets/class-art/shed.png",
  VAN:   "assets/class-art/van.png",
  CTNR:  "assets/class-art/container.png",
  TRLR:  "assets/class-art/trailer.png",
  RV:    "assets/class-art/motorhome.png",
  TINY:  "assets/class-art/tinyhome.png",
  SHTY:  "assets/class-art/shanty.png",
  CABN:  "assets/class-art/cabin.png",
  CNDO:  "assets/class-art/condo.png",
  HOUS:  "assets/class-art/house.png",
  DPLX:  "assets/class-art/duplex.png",
  TOWN:  "assets/class-art/townhouse.png",
  HIRS:  "assets/class-art/highrise.png",
  COMM:  "assets/class-art/commercial.png",
  FARM:  "assets/class-art/farmland.png",
  VILA:  "assets/class-art/villa.png",
  MANR:  "assets/class-art/manor.png",
  USDG:  "assets/class-art/castles.png",
};

function paintTiles(root) {
  (root || document).querySelectorAll(".tile[data-ticker]").forEach((el) => {
    const hex = CLASS_COLOR[el.dataset.ticker];
    if (!/^#[0-9a-f]{6}$/i.test(hex || "")) {
      if (hex) console.warn("CASTLE: bad colour for", el.dataset.ticker, hex);
      return;
    }
    el.style.setProperty("--c", hex);
    el.style.setProperty("--ci", readableInk(hex));

    const art = CLASS_ART[el.dataset.ticker];
    const slot = el.querySelector(".glyph");
    if (art && slot && !slot.querySelector("img")) {
      slot.innerHTML = '<img src="' + art + '" alt="" loading="lazy">';
    }
    // an explicit class rather than :has(), so the sizing never depends on
    // selector support or on when the image was injected
    if (art && slot) el.classList.add("has-art");
  });
}

// The pages render their tiles in an inline script that runs after this
// file, so paint once on DOMContentLoaded and again on any later injection.
window.CASTLES_ART = CLASS_ART;

/* Tiles are rendered by each page's own inline script, which may run before
   or after this file depending on the page. Rather than depend on that
   ordering, watch the whole document until every tile is painted. */
/* The coin page renders its own icon from the line glyph. Swap in the real
   class art and key the whole head to that class's colour. */
function paintCoinHead() {
  const head = document.getElementById("co-head");
  if (!head) return;
  const t = new URLSearchParams(location.search).get("coin");
  if (!t) return;
  const hex = CLASS_COLOR[t];
  const art = CLASS_ART[t];
  const slot = document.getElementById("co-icon");
  if (art && slot && !slot.querySelector("img")) {
    // same card treatment as the grid: colour band with the tier on it,
    // the render underneath
    const cls = (typeof PROPERTY_CLASSES !== "undefined")
      ? PROPERTY_CLASSES.find((c) => c.ticker === t) : null;
    const tier = cls ? (TIER_LABEL[cls.tier] || cls.tier) : "";
    slot.innerHTML =
      '<span class="band">' + tier + "</span>" +
      '<img src="' + art + '" alt="">';
    slot.classList.add("has-band");
  }
  if (!hex) return;
  head.style.setProperty("--c", hex);

  // Paint the gradient with real hex stops rather than color-mix in the
  // stylesheet: if color-mix fails to resolve, background-clip:text leaves
  // the heading transparent and the title disappears entirely.
  // The heading stays plain black. Tinting it per class, whether flat,
  // darkened or as a gradient, never read well against the light ground.
  const h1 = document.getElementById("co-name");
  if (h1) {
    h1.style.backgroundImage = "none";
    h1.style.webkitTextFillColor = "#0B0B0B";
    h1.style.webkitTextStroke = "0";
    h1.style.color = "#0B0B0B";
  }

  // Tickers always carry the $ so they read the same everywhere
  const tag = document.getElementById("co-tag");
  if (tag && tag.textContent && tag.textContent.trim()[0] !== "$" && tag.textContent.trim() !== "Loading…") {
    tag.textContent = "$" + tag.textContent.trim();
  }
  // the Robinhood mark leads the ticker, set on the same line
  if (tag && tag.textContent.trim() !== "Loading…" && !tag.querySelector(".rh-badge")) {
    tag.insertAdjacentHTML("afterbegin", '<i class="rh-badge"></i>');
  }
}

function relLum(hex) {
  const c = [1, 3, 5].map((i) => {
    const v = parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

function contrast(a, b) {
  const la = relLum(a), lb = relLum(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/* Walk the colour toward black only as far as it has to go. These titles are
   44px, so 3:1 is the right threshold, not the 4.5:1 body-text one; at 4.5
   the yellows and pale blues went muddy olive instead of staying vibrant.
   Small steps so it stops at the first shade that works. */
function darkenUntilReadable(hex, against, target) {
  let out = hex;
  for (let i = 0; i < 40 && contrast(out, against) < target; i++) {
    out = mix(out, "#000000", 0.05);
  }
  return out;
}

/* blend two hex colours, so gradient stops can be computed without relying
   on color-mix() resolving at paint time */
function mix(a, b, t) {
  const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16));
  const c = pa.map((v, i) => Math.round(v + (pb[i] - v) * t));
  return "#" + c.map((v) => v.toString(16).padStart(2, "0")).join("");
}

/* The launch page builds its class picker from the data, so colour each
   option and drop that class's render in beside the name. */
function paintPicker() {
  document.querySelectorAll(".class-opt[data-ticker]").forEach((el) => {
    const t = el.dataset.ticker;
    const hex = CLASS_COLOR[t];
    if (!/^#[0-9a-f]{6}$/i.test(hex || "")) return;
    el.style.setProperty("--c", hex);
    el.style.setProperty("--ci", readableInk(hex));
    if (el.querySelector(".chip")) return;
    const art = CLASS_ART[t];
    const chip = document.createElement("span");
    chip.className = "chip";
    if (art) chip.innerHTML = '<img src="' + art + '" alt="">';
    el.insertBefore(chip, el.firstChild);
  });
}

function paintAll() {
  paintTiles();
  paintCoinHead();
  paintPicker();
  const pending = [...document.querySelectorAll(".tile[data-ticker]")]
    .filter((el) => CLASS_ART[el.dataset.ticker] && !el.querySelector(".glyph img"));
  return pending.length === 0;
}

paintAll();
document.addEventListener("DOMContentLoaded", paintAll);

/* Any class tile, on any page, opens that class's coin page. The classes
   page wires this itself; this covers the home page preview, which did not. */
document.addEventListener("click", (e) => {
  const tile = e.target.closest(".tile[data-ticker]");
  if (!tile || tile.closest("a")) return;
  const t = tile.dataset.ticker;
  if (t) location.href = "coin.html?coin=" + encodeURIComponent(t);
});
window.addEventListener("load", paintAll);
new MutationObserver(paintAll).observe(document.documentElement, {
  childList: true,
  subtree: true,
});


/* ---------------------------------------------------------------------
   Class search. The placeholder types an example, pauses, deletes it and
   moves to the next, which shows what the field is for without a label.
   It stops the moment the field is focused or has anything in it, so the
   animation never fights the person typing.
   --------------------------------------------------------------------- */
(function () {
  const input = document.getElementById("class-search");
  if (!input) return;

  const countEl = document.getElementById("class-count");
  const emptyEl = document.getElementById("class-empty");
  const grid = document.getElementById("all-classes");

  /* --- filter --- */
  function apply() {
    const q = input.value.trim().toLowerCase();
    let shown = 0;
    grid.querySelectorAll(".tile[data-ticker]").forEach((el) => {
      const hit = !q || el.textContent.toLowerCase().includes(q);
      el.style.display = hit ? "" : "none";
      if (hit) shown++;
    });
    // USDG is a stablecoin, not a property class, so it is not counted
    const classes = [...grid.querySelectorAll('.tile[data-ticker]')]
      .filter((el) => el.dataset.ticker !== "USDG" && el.style.display !== "none").length;
    if (countEl) countEl.textContent = classes + (classes === 1 ? " class" : " classes");
    if (emptyEl) emptyEl.style.display = shown ? "none" : "";
  }
  input.addEventListener("input", apply);
  new MutationObserver(apply).observe(grid, { childList: true });
  apply();

  /* --- typing placeholder --- */
  const EXAMPLES = ["House", "Van", "High-rise", "Couch", "Manor"];
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduced) {
    input.placeholder = "Search a property class";
    return;
  }

  let word = 0, chars = 0, deleting = false, timer;
  function tick() {
    if (document.activeElement === input || input.value) {
      input.placeholder = "";
      timer = setTimeout(tick, 400);
      return;
    }
    const target = EXAMPLES[word];
    chars += deleting ? -1 : 1;
    input.placeholder = target.slice(0, chars);

    let wait = deleting ? 45 : 95;
    if (!deleting && chars === target.length) { deleting = true; wait = 1100; }
    else if (deleting && chars === 0) { deleting = false; word = (word + 1) % EXAMPLES.length; wait = 350; }
    timer = setTimeout(tick, wait);
  }
  tick();
})();


/* ---------------------------------------------------------------------
   Docs page furniture: a contents list built from the headings, a reading
   progress bar, and active-section highlighting. Nothing is hard-coded, so
   adding a section to the page adds it to the contents.
   --------------------------------------------------------------------- */
(function () {
  const main = document.querySelector("main");
  if (!main || !/docs\.html/.test(location.pathname)) return;

  const heads = [...main.querySelectorAll("h2")];
  if (heads.length < 2) return;

  document.body.classList.add("has-toc");

  // vertical progress track, living inside the contents rail
  const track = document.createElement("div");
  track.className = "track";
  track.innerHTML = "<i></i>";
  const fill = track.firstElementChild;

  const nav = document.createElement("nav");
  nav.className = "toc";
  nav.innerHTML = "<h4>On this page</h4><ul></ul>";
  nav.insertBefore(track, nav.firstChild);
  const ul = nav.querySelector("ul");

  heads.forEach((h, i) => {
    if (!h.id) h.id = "sec-" + (i + 1);
    const li = document.createElement("li");
    li.innerHTML = '<a href="#' + h.id + '">' + h.textContent.trim() + "</a>";
    ul.appendChild(li);
  });

  const sheet = document.createElement("div");
  sheet.className = "doc-sheet";
  const firstSection = main.querySelector("section");
  if (firstSection) {
    main.insertBefore(sheet, firstSection);
    main.insertBefore(nav, sheet);
  }

  const links = [...ul.querySelectorAll("a")];
  function onScroll() {
    const doc = document.documentElement;
    const max = doc.scrollHeight - window.innerHeight;
    fill.style.height = (max > 0 ? Math.min(100, (window.scrollY / max) * 100) : 0) + "%";

    let current = 0;
    heads.forEach((h, i) => { if (h.getBoundingClientRect().top < 140) current = i; });
    links.forEach((a, i) => a.classList.toggle("on", i === current));
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();
})();


/* Footer addresses copy on click, with the label confirming it. */
document.addEventListener("click", (e) => {
  const row = e.target.closest(".foot-row[data-copy]");
  if (!row) return;
  const val = row.dataset.copy;
  const b = row.querySelector("b");
  navigator.clipboard.writeText(val).then(() => {
    const was = b.textContent;
    b.textContent = "copied";
    setTimeout(() => { b.textContent = was; }, 1100);
  });
});




/* ---------------------------------------------------------------------
   Browse markets filters. Own dropdowns rather than native selects, so the
   open list is branded, and the class list is built from the data.
   --------------------------------------------------------------------- */
(function initDropdowns() {
  const wrap = document.getElementById("browse-filters");
  if (!wrap) return;

  const OPTIONS = {
    class: [{ v: "", l: "All property classes" }].concat(
      (typeof PROPERTY_CLASSES !== "undefined" ? PROPERTY_CLASSES : []).map((c) => ({
        v: c.ticker, l: c.displayName, art: CLASS_ART[c.ticker], c: CLASS_COLOR[c.ticker],
      }))
    ),
    status: [
      { v: "all", l: "All markets" },
      { v: "new", l: "New pairs" },
      { v: "migrated", l: "Past cap" },
    ],
    sort: [
      { v: "new", l: "Newest first" },
      { v: "mcap", l: "Market cap, high to low" },
      { v: "mcap-asc", l: "Market cap, low to high" },
      { v: "vol", l: "Volume, high to low" },
      { v: "prog", l: "Closest to cap" },
    ],
  };

  const state = { class: "", status: "all", sort: "new" };

  wrap.querySelectorAll(".dd").forEach((dd) => {
    const key = dd.dataset.dd;
    const btn = dd.querySelector(".dd-btn");
    const menu = dd.querySelector(".dd-menu");

    menu.innerHTML = OPTIONS[key].map((o) =>
      '<button type="button" data-v="' + o.v + '" aria-selected="' + (state[key] === o.v) + '">' +
      (o.art ? '<img class="sw" src="' + o.art + '" alt="">'
             : o.c ? '<span class="sw sw-dot" style="background:' + o.c + '"></span>' : "") +
      o.l + "</button>"
    ).join("");

    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const wasOpen = dd.classList.contains("open");
      wrap.querySelectorAll(".dd").forEach((o) => o.classList.remove("open"));
      dd.classList.toggle("open", !wasOpen);
    });

    menu.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b) return;
      state[key] = b.dataset.v;
      menu.querySelectorAll("button").forEach((o) => o.setAttribute("aria-selected", String(o === b)));
      btn.childNodes[0].nodeValue = b.textContent.trim();
      dd.classList.remove("open");
      apply();
    });
  });

  document.addEventListener("click", () => wrap.querySelectorAll(".dd").forEach((o) => o.classList.remove("open")));

  const grid = document.getElementById("markets-grid");
  const countEl = document.getElementById("browse-count");
  const search = document.getElementById("market-search");

  function apply() {
    if (!grid) return;
    const q = (search && search.value.trim().toLowerCase()) || "";
    const cards = [...grid.children];
    let shown = 0;
    cards.forEach((el) => {
      const txt = el.textContent.toLowerCase();
      let ok = !q || txt.includes(q);
      if (ok && state.class) {
        const badge = el.querySelector("[data-ticker]");
        ok = badge ? badge.dataset.ticker === state.class : false;
      }
      // "migrated" here really means "price has crossed the market's cap" —
      // detected via the progress-fill's own class, not by matching display
      // text, since the card no longer says the literal word "migrated".
      const pastCap = !!el.querySelector(".market-progress-fill.migrated");
      if (ok && state.status === "migrated") ok = pastCap;
      if (ok && state.status === "new") ok = !pastCap;
      el.style.display = ok ? "" : "none";
      if (ok) shown++;
    });

    const order = { mcap: -1, "mcap-asc": 1 };
    if (state.sort in order || state.sort === "vol" || state.sort === "prog") {
      const num = (el, re) => {
        const m = el.textContent.match(re);
        return m ? parseFloat(m[1].replace(/,/g, "")) : 0;
      };
      const pick = state.sort === "vol" ? /Vol\s([\d.]+)/
                 : state.sort === "prog" ? /([\d.]+)%\sof curve range/
                 : /\$([\d,]+)/;
      const dir = state.sort === "mcap-asc" ? 1 : -1;
      cards.sort((a, b) => (num(a, pick) - num(b, pick)) * dir)
           .forEach((el) => grid.appendChild(el));
    }

    if (countEl) countEl.textContent = shown + (shown === 1 ? " market" : " markets");
  }

  if (search) search.addEventListener("input", apply);
  new MutationObserver(apply).observe(grid, { childList: true });
  apply();
})();


/* Spinner on the markets status line, but only while it is still working.
   The page sets this text directly, so watch it rather than wrap it. */
(function marketsStatusSpinner() {
  const el = document.getElementById("markets-status");
  if (!el) return;
  const WORKING = /checking|loading|reading|connecting/i;
  const sync = () => el.classList.toggle("is-loading", WORKING.test(el.textContent));
  new MutationObserver(sync).observe(el, { childList: true, characterData: true, subtree: true });
  sync();
})();


/* Ground treatment picker. ?bg=1..4 to compare, no parameter leaves the
   ground untouched. Remove this once one is chosen. */
(function groundVariation() {
  const n = new URLSearchParams(location.search).get("bg");
  if (n && /^[1-4]$/.test(n)) document.body.setAttribute("data-bg", n);
})();


/* ---------------------------------------------------------------------
   Hero board. A plane of property squares seen at three quarters, the way
   a board game sits on a table. Each square carries its class colour down
   the right edge with the tier written on it, and the render stands up off
   the square rather than lying flat on it.
   --------------------------------------------------------------------- */
(function heroBoard() {
  const el = document.getElementById("hero-board");
  if (!el || typeof PROPERTY_CLASSES === "undefined") return;

  const PICKS = ["COUCH", "SHED", "RV", "CTNR", "SHTY", "HOUS", "HIRS"];

  /* The house and high-rise renders fill their class-art frame edge to edge,
     so their shadow was cut off and their feet sat lower than every other
     piece. The board takes its own cut of those two, on a roomier canvas. */
  const BOARD_ART = {
    HOUS: "assets/board-art/house.png",
    HIRS: "assets/board-art/highrise.png",
  };

  el.innerHTML = PICKS.map((t, i) => {
    const cls = PROPERTY_CLASSES.find((c) => c.ticker === t);
    if (!cls) return "";
    const hex = CLASS_COLOR[t] || "#4C5A56";
    const art = BOARD_ART[t] || CLASS_ART[t];
    const name = cls.displayName || cls.ticker;
    return '<a class="sq" data-class="' + t + '" href="coin.html?coin=' + t + '" style="--c:' + hex +
      ";--ci:" + readableInk(hex) + ";--i:" + i + '">' +
      '<span class="name">' + name + '<i class="rh-badge"></i></span>' +
      (art ? '<span class="art"><img src="' + art + '" alt=""></span>' : "") +
      "</a>";
  }).join("");
})();


/* The Robinhood mark, set after each class name the way a verified tick sits
   after a handle. */
(function rhBadges() {
  const add = () => {
    document.querySelectorAll(".tile .ticker").forEach((el) => {
      if (!el.querySelector(".rh-badge")) el.insertAdjacentHTML("beforeend", '<i class="rh-badge"></i>');
    });
  };
  add();
  const grid = document.querySelector(".tile-grid");
  if (grid) new MutationObserver(add).observe(grid, { childList: true, subtree: true });
})();


/* Market cards carry their class: a colour band across the top and the class
   name as a badge in that colour, the same treatment the launch picks use. */
(function paintMarketCards() {
  const paint = () => {
    document.querySelectorAll(".market-card").forEach((card) => {
      const badge = card.querySelector("[data-ticker]");
      if (!badge) return;
      const hex = CLASS_COLOR[badge.dataset.ticker];
      if (!hex || !/^#[0-9a-f]{6}$/i.test(hex)) return;
      card.style.setProperty("--c", hex);
      // the darker gradient stop, computed here rather than with color-mix
      card.style.setProperty("--c2", mix(hex, "#000000", 0.2));
      card.style.setProperty("--ci", readableInk(hex));
      card.classList.add("has-class");
    });
  };
  paint();
  const grid = document.getElementById("markets-grid");
  if (grid) new MutationObserver(paint).observe(grid, { childList: true, subtree: true });
})();
