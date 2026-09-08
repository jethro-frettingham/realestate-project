/**
 * PROPERTY_CLASSES
 * ------------------------------------------------------------------
 * Every launch on Parcel is paired with one of these classes instead
 * of a stablecoin. Each class has its own coin (e.g. SHED, VILA) whose
 * price tracks an index for that asset type — see /docs for how the
 * index is sourced. `unit` is the reference unit the index prices.
 *
 * tier is cosmetic (drives the small tag on each tile) and groups
 * classes from novelty assets through to real housing stock.
 */
const PROPERTY_CLASSES = [
  // ---- joke / novelty tier -------------------------------------------------
  { ticker: "COUCH", label: "Friend's Couch", unit: "1 COUCH = 1 month of couch rights", tier: "joke",
    glyph: { type: "couch" } },
  { ticker: "TENT",  label: "Tent Pad", unit: "1 TENT = 1 campsite pad", tier: "joke",
    glyph: { roof: "tent", w: 30, h: 16 } },
  { ticker: "SHED",  label: "Tin Shed / Storage Unit", unit: "1 SHED = 1 storage unit (100 sq ft)", tier: "joke",
    glyph: { roof: "flat", w: 34, h: 18, door: 1 } },
  { ticker: "LEAN",  label: "Lean-to", unit: "1 LEAN = 1 lean-to structure", tier: "joke",
    glyph: { roof: "lean", w: 30, h: 16 } },

  // ---- mobile / small tier -------------------------------------------------
  { ticker: "VAN",   label: "Converted Van", unit: "1 VAN = 1 camper conversion", tier: "mobile",
    glyph: { roof: "curve", w: 40, h: 16, wheels: 2 } },
  { ticker: "RV",    label: "RV / Motorhome", unit: "1 RV = 1 Class C motorhome", tier: "mobile",
    glyph: { roof: "flat", w: 46, h: 20, wheels: 2, windows: 3 } },
  { ticker: "TRLR",  label: "Single-wide Trailer", unit: "1 TRLR = 1 single-wide", tier: "mobile",
    glyph: { roof: "flat", w: 48, h: 18, wheels: 3, windows: 2 } },
  { ticker: "TINY",  label: "Tiny Home", unit: "1 TINY = 1 tiny home (400 sq ft)", tier: "mobile",
    glyph: { roof: "gable", w: 36, h: 20, door: 1, windows: 1 } },
  { ticker: "CTNR",  label: "Container Home", unit: "1 CTNR = 1 shipping-container home", tier: "mobile",
    glyph: { roof: "flat", w: 40, h: 18, door: 1, windows: 2, corrugated: true } },

  // ---- fixed residential tier ----------------------------------------------
  { ticker: "SHTY",  label: "Shanty", unit: "1 SHTY = 1 informal dwelling unit", tier: "fixed",
    glyph: { roof: "lean", w: 34, h: 20, door: 1, patched: true } },
  { ticker: "CABN",  label: "Cabin", unit: "1 CABN = 1 rural cabin", tier: "fixed",
    glyph: { roof: "gable", w: 34, h: 22, door: 1, windows: 1, chimney: true } },
  { ticker: "CNDO",  label: "Condo Unit", unit: "1 CNDO = 1 condo unit", tier: "fixed",
    glyph: { roof: "flat", w: 32, h: 30, windows: 4, stacked: true } },
  { ticker: "HOUS",  label: "Single-family House", unit: "1 HOUS = 1 median SFH", tier: "fixed",
    glyph: { roof: "gable", w: 42, h: 24, door: 1, windows: 2, chimney: true } },
  { ticker: "DPLX",  label: "Duplex", unit: "1 DPLX = 1 duplex (both units)", tier: "fixed",
    glyph: { roof: "gable", w: 52, h: 24, door: 2, windows: 2 } },
  { ticker: "TOWN",  label: "Townhouse", unit: "1 TOWN = 1 townhouse", tier: "fixed",
    glyph: { roof: "flat", w: 30, h: 32, windows: 3, stacked: true, door: 1 } },

  // ---- estate / commercial tier --------------------------------------------
  { ticker: "VILA",  label: "Villa", unit: "1 VILA = 1 villa", tier: "estate",
    glyph: { roof: "hip", w: 50, h: 22, door: 1, windows: 3 } },
  { ticker: "MANR",  label: "Manor Estate", unit: "1 MANR = 1 manor estate", tier: "estate",
    glyph: { roof: "hip", w: 56, h: 26, door: 1, windows: 4, wings: true } },
  { ticker: "FARM",  label: "Farmland", unit: "1 FARM = 1 acre with structures", tier: "estate",
    glyph: { roof: "gable", w: 30, h: 22, silo: true } },
  { ticker: "COMM",  label: "Commercial Unit", unit: "1 COMM = 1 small commercial unit", tier: "estate",
    glyph: { roof: "flat", w: 44, h: 26, windows: 5, sign: true } },
  { ticker: "HIRS",  label: "High-rise Unit", unit: "1 HIRS = 1 high-rise unit", tier: "estate",
    glyph: { roof: "flat", w: 26, h: 40, windows: 8, stacked: true } },
];

const TIER_LABEL = {
  joke: "novelty",
  mobile: "mobile",
  fixed: "residential",
  estate: "estate",
};
