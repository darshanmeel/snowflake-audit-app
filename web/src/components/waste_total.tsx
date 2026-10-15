// web/src/components/waste_total.tsx -- the ONE place "how much is being wasted" is computed, so
// Overview, Actions, the Waste tab, every area page and the printed summary can never disagree.
//
// Every figure is read from the check's own `money` on GET /api/findings (the API sums the check's
// money column over its CRITICAL and WARN rows, after the materiality floor), so the same check
// shows the same $ on every page. A WASTE_ITEMS entry (tab_registry.tsx) names which column of that
// check may be counted and in which unit; the units are never added together:
//   waste   possible waste over the window        (dollarCol, a waste-kind column)
//   saving  possible saving over the window       (savingCol, e.g. a resize)
//   month   storage $ per month                   (monthCol)
//   flagged only: no $ figure, counted as a flagged check
// A check that did not run has no figure at all ("-" and its reason), never $0.

// The columns whose basis is WASTE (the API's own waste-kind list, app/core/finding_columns.py).
// A resource's own spend is never one of them.
import { FLAGGED_STATUSES, numOrZero, useFindingAgg, useMultiFindingData } from "./hooks";
import { WASTE_ITEMS } from "./tab_registry";
import { bandOf } from "./primitives";
import { getCheckLabel } from "./labels";
import type { Filters, Finding, Row } from "../types";

/** One WASTE_ITEMS entry (tab_registry): the check and which money column of it counts. */
export interface WasteItem {
  id: string;
  area?: string;
  why?: string;
  dollarCol?: string | null;
  savingCol?: string | null;
  monthCol?: string | null;
  [key: string]: any;
}

/** A WASTE_ITEMS entry joined to its finding: what every waste page reads. */
export interface WasteEntry {
  id: string;
  area: any;
  unit: "waste" | "saving" | "month" | null;
  col: string | null;
  why: any;
  title: string;
  band: string;
  ran: boolean;
  isFlagged: boolean;
  usd: number | null;
  flaggedCount: number;
  affected: any;
  rowCount: number | undefined;
  notRunLabel: string | null;
  /** A flagged-only check that still carries its own $ (a saving, spend or context figure shown on
   * its own page): never counted here, but the page says where the figure lives. */
  ownMoney: { usd: number; kind: string; perMonth: boolean } | null;
  /** Storage only: the part of `usd` on tables another storage check prices higher (counted there). */
  overlapUsd: number;
  /** Ran, but the export had no price for its $ column: its figure is "–", never $0. */
  unpriced: boolean;
}

export const WASTE_DOLLAR_COLUMNS = ["est_wasted_usd_list", "total_est_wasted_usd_list", "wasted_usd", "est_idle_usd_list"];
export function isWasteDollarColumn(col: string) {
  return WASTE_DOLLAR_COLUMNS.includes(col);
}

// The unit an item's $ is in: "waste" (window), "saving" (window), "month", or null (flagged only).
export function wasteUnitOf(item: WasteItem): "waste" | "saving" | "month" | null {
  if (item.dollarCol) return "waste";
  if (item.savingCol) return "saving";
  if (item.monthCol) return "month";
  return null;
}

// The kind a check's money figure is shown as: the core's own `money.kind`. A "context" figure (idle
// $ that another check already counts as waste) is never possible waste.
export function moneyKindOf(f: Row | null | undefined) {
  const m = f && f.money;
  return m ? m.kind : null;
}

// A money figure in invoice currency (org views) is never a dollar figure: no "$", no discount.
export function isCurrencyMoney(m: Row | null | undefined) {
  return !!m && m.unit === "currency";
}

export function flaggedRows(rows: Row[] | null | undefined) {
  return (rows || []).filter((r: Row) => r.status === "CRITICAL" || r.status === "WARN");
}

// One WASTE_ITEMS entry -> its worklist entry. `usd` is null (never 0) unless the check ran, flagged rows and its
// money column is the one the item names (an OK check's $ is a plain total, not a waste figure); `ran` says whether it did.
export function buildWasteEntry(item: WasteItem, f: Finding | null | undefined): WasteEntry {
  const band = f ? bandOf(f) : "NOT_ASSESSED";
  const ran = !!f && band !== "NOT_ASSESSED" && band !== "ERROR";
  const isFlagged = band === "CRITICAL" || band === "WARN";
  const unit = wasteUnitOf(item);
  const col = item.dollarCol || item.savingCol || item.monthCol || null;
  const m = f && f.money;
  // Only a figure of the item's own kind on flagged rows is counted (a storage run-rate over every
  // table is spend, not a saving); a check whose core figure is another kind stays unpriced.
  const KIND_OF_UNIT: Record<string, string> = { waste: "waste", saving: "saving", month: "saving_month" };
  const fits = !!m && !isCurrencyMoney(m) && m.kind === KIND_OF_UNIT[unit!] && m.basis === "flagged" && (unit === "month" || m.column === col);
  const usd = ran && isFlagged && unit && fits && Number.isFinite(Number(m.usd)) ? Number(m.usd) : null;
  const flaggedCount = f && f.affected ? f.affected.flagged : (f && f.status_counts ? (f.status_counts.CRITICAL || 0) + (f.status_counts.WARN || 0) : 0);
  return {
    id: item.id,
    area: item.area,
    unit,
    col,
    why: item.why,
    title: getCheckLabel(item.id, f && f.title).title,
    band, ran, isFlagged, usd, flaggedCount,
    affected: f ? f.affected : null,
    rowCount: f ? f.row_count : 0,
    notRunLabel: f && f.not_assessed ? f.not_assessed.label : (f ? null : "not in this export"),
    ownMoney: ownMoneyOf(unit, ran && isFlagged, m),
    overlapUsd: usd != null && m && Number.isFinite(Number(m.overlap_usd)) ? Number(m.overlap_usd) : 0,
    unpriced: ran && !!f && (f.money_reason === "unpriced" || (!!m && m.price_basis === "unpriced") || noExportPrice(unit, f)),
  };
}

// The export has no price for this unit: storage $ needs the storage price, the rest the credit price.
function noExportPrice(unit: string | null, f: Finding) {
  const p = f.export_price;
  if (!p || !unit) return false;
  return (unit === "month" ? p.storage_price_usd_tb_month : p.credit_price_usd) == null;
}

// A flagged-only check's own $ (its flagged part when the figure covers every row), or null.
function ownMoneyOf(unit: string | null, flagged: boolean, m: Row | null | undefined): WasteEntry["ownMoney"] {
  if (unit || !flagged || !m || isCurrencyMoney(m)) return null;
  const v = Number(m.basis === "all" && m.usd_flagged != null ? m.usd_flagged : m.usd);
  return Number.isFinite(v) && v > 0 ? { usd: v, kind: String(m.kind || "spend"), perMonth: m.kind === "saving_month" } : null;
}

// Every WASTE_ITEMS entry, in order -- the single call every page makes. `findingsById` is the
// loaded findings index.
export function buildWasteWorklist(findingsById: Record<string, Finding> | null | undefined): WasteEntry[] {
  return WASTE_ITEMS.map((item: WasteItem) => buildWasteEntry(item, (findingsById || {})[item.id]));
}

// The three $ totals, each over the entries of that unit that ran, plus the flagged-only list and
// the checks that did not run. A total is null (not $0) when none of its checks ran.
// `belowFloorById` (useBelowFloorWaste's result, optional) adds belowFloorUsd / belowFloorRows / floor:
// the waste $ each check's materiality floor left OUT of the waste total. Shown as a note, never added.
export function wasteTotal(worklist: WasteEntry[] | null | undefined, belowFloorById?: Record<string, any> | null) {
  const list = worklist || [];
  const byUnit = (unit: string) => list.filter((w) => w.unit === unit);
  const sum = (entries: WasteEntry[]) => {
    const ran = entries.filter((w) => w.ran);
    if (!ran.length) return { usd: null, ran: 0, total: entries.length, flagged: 0, entries, overlapUsd: 0, noPrice: false };
    // No check that ran has a price (an empty one carries no money at all): a sum would read $0, so "–".
    const noPrice = ran.some((w) => w.unpriced) && !ran.some((w) => w.usd != null);
    if (noPrice) return { usd: null, ran: ran.length, total: entries.length, flagged: ran.filter((w) => w.isFlagged).length, entries, overlapUsd: 0, noPrice };
    const priced = ran.filter((w) => w.usd != null);
    // Flagged checks with no figure of this unit's kind: a total of the rest would read $0 or too low.
    const unpriced = ran.filter((w) => w.isFlagged && w.usd == null).length;
    // A table two storage checks both name is counted once, at the larger $ (the API marks the rest).
    const overlapUsd = priced.reduce((s, w) => s + w.overlapUsd, 0);
    return {
      usd: priced.length === 0 && unpriced > 0 ? null : priced.reduce((s, w) => s + (w.usd as number), 0) - overlapUsd,
      overlapUsd,
      ran: ran.length, total: entries.length, unpriced, noPrice,
      flagged: ran.filter((w) => w.isFlagged).length,
      entries,
    };
  };
  const bandRank: Record<string, number> = { CRITICAL: 0, WARN: 1 };
  const flaggedOnly = list
    .filter((w) => w.unit === null && w.isFlagged)
    .sort((a, b) => (bandRank[a.band] ?? 2) - (bandRank[b.band] ?? 2));
  let belowFloorUsd = 0, belowFloorRows = 0, floor: any = null, belowFloorReady = false, belowFloorPending = false;
  if (belowFloorById) {
    list.filter((w) => w.unit === "waste" && w.col).forEach((w) => {
      const st = belowFloorById[w.id];
      // Every item must have settled, or the figure would grow as requests land.
      if (!st || (st.phase !== "ready" && st.phase !== "error")) belowFloorPending = true;
      if (st && st.phase === "ready" && st.outcome === "ok_rows") {
        belowFloorReady = true;
        belowFloorUsd += numOrZero(st.data.total_value) * (1 - numOrZero(st.data.discount_pct));
        belowFloorRows += numOrZero(st.data.matched_rows);
        if (!floor && st.data.floor) floor = st.data.floor;
      }
    });
  }
  return {
    belowFloorUsd: belowFloorReady && !belowFloorPending ? belowFloorUsd : null, belowFloorRows, floor,
    waste: sum(byUnit("waste")),
    saving: sum(byUnit("saving")),
    month: sum(byUnit("month")),
    flaggedOnly,
    notRun: list.filter((w) => !w.ran),
    ran: list.filter((w) => w.ran).length,
    total: list.length,
  };
}

// useBelowFloorWaste: for every waste item, the $ its own materiality floor moved from CRITICAL/WARN to
// OK (Api.aggregate belowFloor), so the total can say what it leaves out. WASTE_ITEMS is a fixed list,
// so the same number of hooks runs on every render.
export function useBelowFloorWaste(filters: Filters) {
  const states = WASTE_ITEMS.map((item: WasteItem) => useFindingAgg(
    item.dollarCol ? item.id : null, filters.window, filters.accountIds, [], "sum", item.dollarCol, { belowFloor: true }
  ));
  const byId: Record<string, any> = {};
  WASTE_ITEMS.forEach((item: WasteItem, i: number) => { byId[item.id] = states[i]; });
  return byId;
}

// The top flagged rows of the checks that carry a $ figure, for a "where" line: at most `perCheck`
// rows each, fetched once for the whole list.
export function useWasteTopRows(worklist: WasteEntry[] | null | undefined, filters: Filters, perCheck?: number) {
  const ids = (worklist || []).filter((w) => w.unit && w.isFlagged).map((w) => w.id);
  return useMultiFindingData(ids, filters.window, filters.accountIds, perCheck || 3, FLAGGED_STATUSES);
}

// The one line a storage total carries when checks name the same table: what it left out.
export function overlapNote(fig: { usd: number | null; overlapUsd?: number } | null | undefined, fmt: (v: number) => string): string | null {
  return fig && fig.usd != null && (fig.overlapUsd || 0) > 0 ? `Each table counted once: ${fmt(fig.overlapUsd as number)} where checks overlap is left out.` : null;
}
