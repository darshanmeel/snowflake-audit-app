// web/src/components/cost_chargeback_picker.tsx -- Cost > Chargeback & tags: one card that picks a
// chargeback dimension (warehouse, service, account, database, role, user, query tag, tag value) and
// lists its rows with spend, change vs the period before where the source has it, and the top movers.
//
// Only the picked dimension's check is fetched. Spend is $ when the check has a price, else credits,
// else "–" and why; never $0. Change is $ only, so it reads "–" without a price.
import React from "react";
import "../styles/css/p_shared_tabs.css";
import { fmtInt, fmtMoney } from "../format";
import { fmtChangePct, numOrZero, useFindingData } from "./hooks";
import { PatternCard, noDataText } from "./primitives";
import { NO_PRICE_READING, notAssessedText } from "./scope";
import { fmtShare, pctOf } from "./blocks";
import { NameId } from "./blocks_2";
import { DrawerBus } from "./drawer";
import { DrillTable, MiniBar } from "./drill_table";
import { whNameId } from "./de_blocks";
import { resolveName, useNames } from "./names";
import { CsvButton } from "./csv";
import type { CsvColumn } from "./csv";
// Same service wording as By service; the import is circular but only read at render.
import { costServiceWords } from "./ap_cost";
import { withoutTotalRows } from "../tabs/tab_area";
import type { ApPageProps } from "./area_pages";
import type { FetchState, Row } from "../types";

type DimKey = "warehouse" | "service" | "account" | "database" | "role" | "user" | "query_tag" | "tag_value";
interface Dim { key: DimKey; label: string; one: string; noun: string; id: string; col: string; hasPrev: boolean; caveat: string }

// One check per dimension; `col` is the column a row opens the drawer on.
const DIMS: Dim[] = [
  { key: "warehouse", label: "Warehouse", one: "warehouse", noun: "warehouses", id: "cost_chargeback_by_warehouse", col: "warehouse_id", hasPrev: true,
    caveat: "Metered warehouse compute, idle time included: the warehouse part of the bill." },
  { key: "service", label: "Service", one: "service", noun: "services", id: "cost_chargeback_by_service", col: "billing_origin_product", hasPrev: true,
    caveat: "Every billed service, storage and transfer included; storage is in TB, so it has no credits." },
  { key: "account", label: "Account", one: "account", noun: "accounts", id: "cost_chargeback_by_account", col: "account_id", hasPrev: true,
    caveat: "The whole bill per account; a service with no price is left out of both periods." },
  { key: "database", label: "Database", one: "database", noun: "databases", id: "sf_chg_by_database_schema", col: "database_name", hasPrev: false,
    caveat: "Query attribution (idle time and queries under about 100 ms left out) plus serverless; a query is charged to its session's database. Storage is in the $ view only, when priced." },
  { key: "role", label: "Role", one: "role", noun: "roles", id: "sf_chg_by_role", col: "role_name", hasPrev: false,
    caveat: "From query attribution: it leaves out idle time and queries under about 100 ms, so roles don't add up to the warehouse bill." },
  { key: "user", label: "User", one: "user", noun: "users", id: "sf_cost_query_attribution_by_user", col: "user_name", hasPrev: false,
    caveat: "From query attribution: idle time is its own row and queries under about 100 ms are left out, so users alone don't add up to the warehouse bill." },
  { key: "query_tag", label: "Query tag", one: "query tag", noun: "query tags", id: "sf_cost_query_attribution_by_query_tag", col: "query_tag", hasPrev: false,
    caveat: "From query attribution: idle and untagged spend are their own rows; tags are free text, so variants of one tag split." },
  { key: "tag_value", label: "Tag value", one: "tag value", noun: "tag values", id: "sf_chg_tag_based_allocation", col: "tag_value", hasPrev: false,
    caveat: "The cost tag on the warehouse (hourly metering, so it can differ from the daily Service figure) or on the user who ran the query; never added." },
];
const BASES = [{ key: "warehouse_tag", label: "Warehouse tag" }, { key: "user_tag", label: "User tag" }];
// A move under this many dollars is rounding, not a mover worth naming.
const MIN_MOVER_USD = 10;

/** One row of a dimension in one shape: credits and $ side by side, $ change where the source has it. */
interface CbItem {
  key: string; name: string; id: string | null; special: boolean;
  credits: number | null; usd: number | null; prev: number | null; change: number | null; changePct: number | null;
  hours: number | null; status: string; naReason: string | null; colVal: any;
}

const num = (v: any): number | null => (v === null || v === undefined || v === "" || !Number.isFinite(Number(v)) ? null : Number(v));
const fmtCr = (v: number) => {
  const a = Math.abs(v);
  if (v === 0) return "0 credits";
  if (a < 0.01) return "<0.01 credits";
  return `${v.toLocaleString(undefined, { minimumFractionDigits: a < 10 ? 2 : a < 1000 ? 1 : 0, maximumFractionDigits: a < 10 ? 2 : a < 1000 ? 1 : 0 })} credits`;
};
const usd0 = (v: number) => fmtMoney(v, 0);
const signedUsd = (v: number) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${fmtMoney(Math.abs(v), 0)}`;

// Each check's own columns, read into the one shape; `keep` is 1 minus the configured discount.
function toItems(dim: Dim, rows: Row[], keep: number, basis: string): CbItem[] {
  const usdOf = (v: any) => { const n = num(v); return n == null ? null : n * keep; };
  const base = (r: Row) => ({
    status: String(r.status || "OK"), naReason: r.not_assessed_reason ? String(r.not_assessed_reason) : null,
    prev: null as number | null, change: null as number | null, changePct: null as number | null, hours: null as number | null, special: false,
  });
  // prev/change only count when this period itself is priced: a 0.0 prev beside a NULL spend is no price, not $0.
  const withChange = (r: Row, usd: number | null) => usd == null ? {} : {
    prev: usdOf(r.prev_usd_list), change: usdOf(r.change_usd_list), changePct: num(r.change_pct),
  };
  switch (dim.key) {
    case "warehouse": return rows.map((r) => {
      const n = whNameId(r.warehouse_id);
      const usd = usdOf(r.usd_list);
      const pooled = r.is_other === true || r.is_other === "true";
      return { ...base(r), ...withChange(r, usd), key: pooled ? `other|${r.status}` : String(r.warehouse_id), special: pooled,
        name: pooled ? `Other (${fmtInt(numOrZero(r.pooled_count))} warehouses)` : n.name, id: pooled ? null : n.id,
        credits: null, usd, hours: num(r.billed_hours), colVal: pooled ? null : r.warehouse_id };
    });
    case "service": return rows.map((r) => {
      const code = r.billing_origin_product;
      const usd = usdOf(r.usd_list);
      const isCredits = String(r.usage_unit || "").toUpperCase() === "CREDITS";
      return { ...base(r), ...withChange(r, usd), key: String(code ?? "(none)"), name: code ? costServiceWords(code) : String(r.service_label || "Unattributed"), id: null,
        credits: isCredits ? num(r.usage_quantity) : null, usd, colVal: code };
    });
    case "account": return rows.map((r) => {
      const usd = usdOf(r.usd_list);
      const nm = r.account_id == null ? "(no single account)" : String(resolveName("account", r.account_id, r.account_id) || r.account_id);
      return { ...base(r), ...withChange(r, usd), key: String(r.account_id ?? "(none)"), name: nm, id: r.account_id == null ? null : String(r.account_id),
        credits: null, usd, colVal: r.account_id };
    });
    case "database": return rows.filter((r) => r.row_kind === "database").map((r) => {
      const cr = num(r.query_credits), sv = num(r.serverless_credits);
      return { ...base(r), key: `${r.account_id}|${r.database_id ?? r.database_name}`, name: String(r.database_name || "(no name)"),
        id: r.database_id == null ? null : String(r.database_id), special: r.database_id == null && /^\(/.test(String(r.database_name || "")),
        credits: cr == null && sv == null ? null : numOrZero(cr) + numOrZero(sv), usd: usdOf(r.est_total_usd_list), colVal: r.database_name };
    });
    case "role": {
      // A role name can repeat per account: kept apart per account, named with it when several are in scope.
      const multi = new Set(rows.map((r) => String(r.account_id ?? ""))).size > 1;
      const by = new Map<string, CbItem>();
      rows.forEach((r) => {
        const k = `${r.account_id}|${r.role_name}`;
        const nm = String(r.role_name || "(no role)");
        const acct = r.account_id == null ? "" : String(resolveName("account", r.account_id, r.account_id) || r.account_id);
        const g = by.get(k) || { ...base(r), key: k, name: multi && acct ? `${nm} · ${acct}` : nm, id: null, credits: null, usd: null, colVal: r.role_name };
        const cr = num(r.attributed_credits), u = usdOf(r.est_attributed_usd_list);
        if (cr != null) g.credits = numOrZero(g.credits) + cr;
        if (u != null) g.usd = numOrZero(g.usd) + u;
        if (r.status === "CRITICAL" || (r.status === "WARN" && g.status !== "CRITICAL")) g.status = String(r.status);
        by.set(k, g);
      });
      return [...by.values()];
    }
    case "user":
    case "query_tag": {
      const nameCol = dim.key === "user" ? "user_name" : "query_tag";
      return rows.map((r) => ({
        ...base(r), key: `${r.account_id}|${r.row_kind}|${r[nameCol]}`, special: r.row_kind === "idle" || r.row_kind === "untagged",
        name: r.row_kind === "idle" ? "Warehouse idle (no one ran it)" : r.row_kind === "untagged" ? "(no query tag)" : String(r[nameCol] || "(unknown)"),
        id: null, credits: num(r.attributed_credits), usd: usdOf(r.est_attributed_usd_list), colVal: r[nameCol],
      }));
    }
    case "tag_value": return rows.filter((r) => String(r.basis) === basis).map((r) => ({
      ...base(r), key: `${r.account_id}|${r.tag_value}`, special: /^\(/.test(String(r.tag_value || "")),
      name: String(r.tag_value || "(blank value)"), id: null, credits: num(r.credits), usd: usdOf(r.est_usd_list), colVal: r.tag_value,
    }));
    default: return [];
  }
}

// The picked check's rows, or the one line that says why there are none.
function useDimRows(p: ApPageProps, id: string) {
  // User, role and service are homed on other Cost sub-tabs, so the whole export's index is read too.
  const f = (p.findings || []).find((x) => x.query_id === id) || (p.allFindingsIndex && p.allFindingsIndex[id]) || null;
  const state = useFindingData(f ? id : null, p.filters.window, p.filters.accountIds, 5000) as FetchState;
  // Right after a switch the hook still holds the last check's rows for one render: read that as loading.
  const stale = state.phase !== "loading" && !!state.data && state.data.query_id !== id;
  let note: string | null = null;
  if (!f) note = "– Not in this export yet: run the export again.";
  else if (state.phase === "loading" || stale) note = "…";
  else if (state.phase === "error") note = `– ${state.error || "Could not load"}`;
  else if (state.outcome === "not_assessed") note = `– ${notAssessedText(state.data)}`;
  else if (state.outcome === "error") note = `– ${(state.data && state.data.error) || "The check failed."}`;
  else if (state.outcome === "ok_empty_window") note = noDataText(p.meta, p.filters.window);
  else if (state.outcome === "ok_empty_filters") note = "Rows exist, but the current filters exclude all of them.";
  const rows: Row[] | null = note == null && state.data ? withoutTotalRows(state.data.rows || []) : null;
  const keep = 1 - numOrZero(state.data && state.data.discount_pct);
  const reasons: Record<string, string> = (state.data && state.data.header && state.data.header.not_assessed_reasons) || {};
  return { rows, note, keep, reasons };
}

function Chip({ it }: { it: CbItem }) {
  if (it.change == null) return <span className="cost-delta tone-neutral">–</span>;
  if (!(numOrZero(it.prev) > 0)) return <span className="cost-delta tone-neutral">{numOrZero(it.usd) > 0 ? "new" : "–"}</span>;
  const pct = it.changePct ?? (it.change / numOrZero(it.prev)) * 100;
  const tone = pct >= 50 ? "crit" : pct >= 25 ? "warn" : pct <= -15 ? "good" : "neutral";
  return <span className={`cost-delta tone-${tone}`} title={`${signedUsd(it.change)} vs the period before`}>{fmtChangePct(pct)}</span>;
}

export function ChargebackByDimension({ p }: { p: ApPageProps }) {
  useNames(); // re-render once warehouse and account names are ready
  const [dimKey, setDimKey] = React.useState<DimKey>("warehouse");
  const [view, setView] = React.useState<"spend" | "change">("spend");
  const [basis, setBasis] = React.useState("warehouse_tag");
  const dim = DIMS.find((d) => d.key === dimKey) || DIMS[0];
  const src = useDimRows(p, dim.id);

  const items = src.rows ? toItems(dim, src.rows, src.keep, basis) : null;
  // One unit per dimension: $ when any row is priced, else credits, else none ("–").
  const unit: "usd" | "credits" | null = !items ? null : items.some((it) => it.usd != null) ? "usd" : items.some((it) => it.credits != null) ? "credits" : null;
  const valOf = (it: CbItem) => (unit === "usd" ? it.usd : unit === "credits" ? it.credits : null);
  const fmtV = unit === "usd" ? usd0 : fmtCr;
  // With no unit the warehouse list still ranks by billed hours, so the names stay useful.
  const rankOf = (it: CbItem) => (unit == null ? it.hours ?? 0 : valOf(it) ?? 0);
  const sorted = items ? [...items].sort((a, b) => Number(a.special) - Number(b.special) || rankOf(b) - rankOf(a)) : [];
  const total = sorted.reduce((s, it) => s + numOrZero(valOf(it)), 0);
  const maxRank = Math.max(0, ...sorted.map(rankOf));
  // No unit on warehouses: billed hours stand in, as a count of hours, never as spend.
  const hoursOnly = unit == null && dim.key === "warehouse";
  const totalHours = sorted.reduce((s, it) => s + numOrZero(it.hours), 0);
  const unpricedNote = unit === "usd" && sorted.some((it) => it.usd == null && (it.credits != null || it.hours != null || dim.key === "service"))
    ? "Rows with no price read “–” and are left out of the total." : null;
  const noUnitNote = items && unit == null ? `– ${NO_PRICE_READING} This check carries $ only.` : null;

  // Change: $ only, from the checks that compare with the period before.
  const changed = sorted.filter((it) => it.change != null && !it.special);
  const naWords = [...new Set(sorted.filter((it) => it.status === "NOT_ASSESSED" && it.naReason).map((it) => it.naReason!))]
    .map((c) => src.reasons[c] || c.replace(/_/g, " "));
  const changeWhy = !dim.hasPrev ? "– This source has one period only: no change to compare."
    : unit !== "usd" ? `– Change is in $ only. ${NO_PRICE_READING}`
    : naWords.length ? `– No change: ${naWords[0]}.` : null;
  const movers = [...changed].filter((it) => Math.abs(numOrZero(it.change)) >= MIN_MOVER_USD).sort((a, b) => Math.abs(numOrZero(b.change)) - Math.abs(numOrZero(a.change)));
  const up = movers.filter((m) => numOrZero(m.change) > 0)[0], down = movers.filter((m) => numOrZero(m.change) < 0)[0];
  const moveMax = Math.max(1, ...movers.map((m) => Math.abs(numOrZero(m.change))));
  const range = noDataText(p.meta, p.filters.window).replace(/^No data for this in /, "");

  const open = (it: CbItem) => (it.colVal == null ? null : () => DrawerBus.open({ id: dim.id, col: dim.col, val: String(it.colVal), label: it.name }));
  const nameCell = (it: CbItem) => it.special ? <span className="muted">{it.name}</span> : <NameId name={it.name} id={it.id} />;
  const realCount = sorted.filter((it) => !it.special).length;

  const csvCols: CsvColumn<CbItem>[] = [
    { label: dim.label, value: (it) => it.name },
    { label: "Id", value: (it) => it.id },
    { label: "Credits", value: (it) => it.credits },
    { label: "Spend $ (effective)", value: (it) => (it.usd == null ? null : Math.round(it.usd * 100) / 100) },
    { label: "Previous period $", value: (it) => (it.change == null || it.prev == null ? null : Math.round(it.prev * 100) / 100) },
    { label: "Change $", value: (it) => (it.change == null ? null : Math.round(it.change * 100) / 100) },
    { label: "Change %", value: (it) => (it.change == null || it.changePct == null ? null : Math.round(it.changePct * 10) / 10) },
    { label: "Status", value: (it) => it.status },
  ];

  // Idle, untagged and pooled rows are named apart, so the count stays one of real objects.
  const extras = sorted.filter((it) => it.special).map((it) => it.name);
  const sub = src.note === "…" ? "…" : items
    ? [unit ? `${fmtV(total)} in all` : null, `${fmtInt(realCount)} ${realCount === 1 ? dim.one : dim.noun}${extras.length ? ` plus ${extras.slice(0, 2).join(", ")}${extras.length > 2 ? ` and ${fmtInt(extras.length - 2)} more` : ""}` : ""}`, range].filter(Boolean).join(" · ")
    : `By ${dim.label.toLowerCase()} · ${range}`;

  return (
    <PatternCard title="Chargeback by dimension" sub={sub}>
      <div className="subtabs" role="group" aria-label="Chargeback dimension">
        {DIMS.map((d) => (
          <button key={d.key} type="button" className={d.key === dim.key ? "active" : ""} onClick={() => setDimKey(d.key)}>{d.label}</button>
        ))}
      </div>
      <div className="row wrap" style={{ gap: 8, justifyContent: "space-between" }}>
        <div className="row wrap" style={{ gap: 8 }}>
          <div className="ws-actions grain-switch" role="group" aria-label="Spend or change">
            <button type="button" className={view === "spend" ? "on" : ""} onClick={() => setView("spend")}>Spend</button>
            <button type="button" className={view === "change" ? "on" : ""} onClick={() => setView("change")}>Change</button>
          </div>
          {dim.key === "tag_value" && (
            <div className="ws-actions grain-switch" role="group" aria-label="Tag on">
              {BASES.map((b) => <button key={b.key} type="button" className={basis === b.key ? "on" : ""} onClick={() => setBasis(b.key)}>{b.label}</button>)}
            </div>
          )}
        </div>
        <CsvButton fileName={`chargeback_by_${dim.key}${dim.key === "tag_value" ? `_${basis}` : ""}_${p.filters.window}d`} columns={csvCols} rows={sorted} />
      </div>
      <div className="chart-note-oneline">{dim.caveat}</div>

      {src.note ? <div className="chart-note-oneline">{src.note}</div> : view === "spend" ? (
        <div>
          {noUnitNote && <div className="chart-note-oneline">{noUnitNote}</div>}
          <DrillTable aria={`Spend by ${dim.label.toLowerCase()}`} n={10} empty={noDataText(p.meta, p.filters.window)}
            cols={[
              { label: dim.label },
              // Value before the bar: on a phone only the first two cells show.
              // Fixed widths: each row is its own grid, so auto columns would make the bars start unevenly.
              { label: hoursOnly ? "Billed hours" : unit === "credits" ? "Credits" : "Spend", num: true, width: "120px" },
              { label: "", width: "minmax(60px, 1fr)" },
              { label: "Share", num: true, width: "88px" },
              ...(dim.hasPrev ? [{ label: "Change", num: true, width: "72px" }] : []),
            ]}
            rows={sorted.map((it) => {
              const v = valOf(it);
              return {
                key: it.key, status: it.status, onOpen: open(it),
                cells: [
                  nameCell(it),
                  hoursOnly ? (it.hours == null ? "–" : `${fmtInt(it.hours)} h`) : v == null ? "–" : fmtV(v),
                  <MiniBar key="b" value={rankOf(it)} max={maxRank} hatched={it.special} />,
                  hoursOnly ? (it.hours == null ? "–" : fmtShare(pctOf(it.hours, totalHours))) : v == null ? "–" : fmtShare(pctOf(v, total)),
                  ...(dim.hasPrev ? [<Chip key="c" it={it} />] : []),
                ],
              };
            })} />
          {unpricedNote && <div className="sx-foot">{unpricedNote}</div>}
          {(up || down) && (
            <div className="sx-foot">
              {[up ? `Biggest rise: ${up.name} ${signedUsd(numOrZero(up.change))}` : null, down ? `biggest fall: ${down.name} ${signedUsd(numOrZero(down.change))}` : null].filter(Boolean).join(" · ")}
            </div>
          )}
        </div>
      ) : changeWhy && !changed.length ? <div className="chart-note-oneline">{changeWhy}</div> : (
        <DrillTable aria={`Top movers by ${dim.label.toLowerCase()}`} n={10}
          empty={`No ${dim.label.toLowerCase()} moved ${usd0(MIN_MOVER_USD)} or more vs the period before, in ${range}.`}
          cols={[{ label: dim.label }, { label: "Change", num: true, width: "100px" }, { label: "", width: "minmax(60px, 1fr)" }, { label: "This period", num: true, width: "110px" }, { label: "", num: true, width: "72px" }]}
          rows={movers.map((it) => ({
            key: it.key, status: it.status, onOpen: open(it),
            cells: [nameCell(it), signedUsd(numOrZero(it.change)), <MiniBar key="b" value={Math.abs(numOrZero(it.change))} max={moveMax} tone={numOrZero(it.change) > 0 ? "warn" : null} />,
              it.usd == null ? "–" : usd0(it.usd), <Chip key="c" it={it} />],
          }))} />
      )}
    </PatternCard>
  );
}
