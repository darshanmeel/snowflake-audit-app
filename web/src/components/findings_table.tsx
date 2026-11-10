// web/src/components/findings_table.tsx -- the checks-list vocabulary every list shares: the six
// status tabs (TAB_ORDER, tabOf), the status words, search text, sort order and the checks CSV.
// tab_findings.tsx and checks_list.tsx both read these, so they never disagree about what
// "Critical" or "No data" means.
import { BAND_LABEL } from "./primitives";
import { getCheckLabel } from "./labels";
import { moneyKindOf } from "./waste_total";
import { MONEY_KIND_WORD } from "../tabs/tab_area";
import type { Filters, Meta, Row } from "../types";


export const TAB_ORDER = ["CRITICAL", "WARN", "OK", "COULDNT", "NODATA", "REFERENCE"];

// tabOf: a finding forced into "Reference" regardless of its own band (an inventory list, or an
// id the registry marks refIds for this sub-tab: INVENTORY already means "no status column at all",
// which is exactly a reference table), else the six-tab bucket its band belongs to. RANKED and a
// verified OK both read as the OK tab; a genuinely empty window and "hidden by your filters" both
// read as No data (the two still differ per row via GROUP_REASON).
export function tabOf(row: Row, band: string, refIdSet: { has(id: any): boolean }): string {
  if (band === "INVENTORY") return "REFERENCE";
  // A reference list that flags rows counts like any check: its Critical pill is a Critical.
  if (band === "CRITICAL") return "CRITICAL";
  if (band === "WARN") return "WARN";
  if (refIdSet.has(row.query_id)) return "REFERENCE";
  if (band === "NOT_ASSESSED" || band === "ERROR") return "COULDNT";
  if (band === "EMPTY_WINDOW" || band === "EMPTY_FILTERS") return "NODATA";
  return "OK"; // OK or RANKED
}

// The words statusText/CSV/search all share for a row's status -- BAND_LABEL for a band with no
// real per-row breakdown, or the CRITICAL/WARN/OK/NOT_ASSESSED counts a finding does carry.
export function statusText(row: Row, band: string): string {
  const sc = row.status_counts;
  if (sc) {
    const parts = ["CRITICAL", "WARN", "NOT_ASSESSED", "OK"]
      .filter((k) => (sc[k] || 0) > 0)
      .map((k) => `${sc[k]} ${(BAND_LABEL as Record<string, string>)[k]}`);
    if (parts.length) return parts.join(", ");
  }
  return (BAND_LABEL as Record<string, string>)[band] || band;
}

export function findingSearchText(row: Row, band: string, label: { title: string }): string {
  return [label.title, row.query_id, statusText(row, band)]
    .filter((v) => v !== null && v !== undefined)
    .join(" ")
    .toLowerCase();
}

// The checks as a CSV file. New columns are appended after these, never inserted before or renamed.
export function downloadChecksCsv(rows: { row: Row; band: string }[], filters: Filters, meta: Meta | null | undefined) {
  const lines = [[
    "Finding", "Query ID", "Domain", "Tier", "Status", "Rows",
    "Possible waste $", "Other $", "Other $ kind", "Money currency", "Affected", "Affected of", "Affected noun",
    "Window days", "As of",
  ].map(csvField).join(",")];
  const asOf = (meta && meta.as_of_date) || "";
  rows.forEach(({ row, band }) => {
    const m = row.money;
    const kind = m ? moneyKindOf(row) : null;
    const unpriced = row.money_reason === "unpriced";
    // An unpriced or missing figure is blank, never 0.
    const usd = m && !unpriced && m.usd != null && !m.mixed_currency ? m.usd : "";
    const a = row.affected;
    lines.push([
      csvField(getCheckLabel(row.query_id, row.title).title),
      csvField(row.query_id),
      csvField(row.domain),
      csvField(row.tier),
      csvField(statusText(row, band)),
      csvField(row.row_count === null || row.row_count === undefined ? "" : row.row_count),
      csvField(kind === "waste" ? usd : ""),
      csvField(kind && kind !== "waste" ? usd : ""),
      csvField(kind && kind !== "waste" ? (MONEY_KIND_WORD[kind] || kind) : ""),
      csvField(m && m.unit === "currency" ? (m.currency || "invoice currency") : (m ? "USD (list price)" : "")),
      csvField(a ? a.flagged : ""),
      csvField(a ? a.total : ""),
      csvField(a ? a.noun : ""),
      csvField(row.windowed === false ? "snapshot" : (row.window_days ?? filters.window)),
      csvField(asOf),
    ].join(","));
  });
  const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "checks.csv";
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

// Severity, when the two $ figures tie (most rows carry no money at all) -- Critical first, worst
// to least certain last. Shared by findings_table.tsx and tab_findings.tsx so the two orderings
// never disagree given the same rows.
export const SEVERITY_RANK: Record<string, number> = { CRITICAL: 0, WARN: 1, OK: 2, RANKED: 3, NOT_ASSESSED: 4, ERROR: 5, EMPTY_WINDOW: 6, EMPTY_FILTERS: 7, INVENTORY: 8 };

// The three kinds of $ never add together -- sort by possible waste first, then every other $
// figure (change/spend/saving/gap), then severity, then title for a stable final order.
export function sortByWasteThenMoney<T extends { row: Row; band: string }>(rows: T[]): T[] {
  const wasteOf = (f: T) => (moneyKindOf(f.row) === "waste" ? f.row.money.usd : 0) || 0;
  const otherOf = (f: T) => (f.row.money && moneyKindOf(f.row) !== "waste" ? f.row.money.usd : 0) || 0;
  return [...rows].sort((a, b) => {
    const w = wasteOf(b) - wasteOf(a);
    if (w) return w;
    const o = otherOf(b) - otherOf(a);
    if (o) return o;
    const s = (SEVERITY_RANK[a.band] ?? 9) - (SEVERITY_RANK[b.band] ?? 9);
    if (s) return s;
    return getCheckLabel(a.row.query_id, a.row.title).title.localeCompare(getCheckLabel(b.row.query_id, b.row.title).title);
  });
}

export function csvField(value: any): string {
  if (value === null || value === undefined) return "";
  const s = String(value);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

