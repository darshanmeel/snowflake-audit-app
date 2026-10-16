// web/src/components/de_blocks.tsx -- blocks the Data engineer pages share: warehouse load over
// the window as one state band per warehouse, and the query pattern table (shapes, never SQL text).
// Each reads one aggregate call; a check that did not run reads "–" and why, "…" while loading.
import React from "react";
import "../styles/css/p_data_engineer.css";
import { fmtBytes, fmtDuration, fmtInt, fmtMoney } from "../format";
import { aggTotal, numOrZero, useFindingAgg } from "./hooks";
import { resolveName, useNames } from "./names";
import { notAssessedText } from "./scope";
import { windowShortLabel } from "./overview_tile";
import { NameId, StateBandList } from "./blocks_2";
import { fmtDur } from "./cx_d";
import type { StateBandRow } from "./blocks_2";
import { fmtShare, pctOf } from "./blocks";
import type { FetchState, Filters, Meta, Row } from "../types";

/** Why an aggregate has no groups, in one line; null when it has them, "…" while loading. */
export function aggNote(s: FetchState, meta: Meta | null, windowDays: number, found = true): string | null {
  if (!found) return "– Not in this export: run the export again.";
  if (s.phase === "loading") return "…";
  // An export older than the check has no table for it: say so, not the raw 404.
  if (s.phase === "error") return String(s.error || "").startsWith("404") ? "– Not in this export: run the export again." : `– ${s.error || "Could not load"}`;
  if (s.outcome === "ok_rows") return null;
  if (s.outcome === "not_assessed") return `– ${notAssessedText(s.data)}`;
  if (s.outcome === "error") return `– ${(s.data && s.data.error) || "The check failed."}`;
  if (s.outcome === "ok_empty_window") {
    const w = windowShortLabel(meta && meta.as_of_date, windowDays, meta && meta.snapshot_days);
    return `No data for this in ${w || `the last ${windowDays} days`}`;
  }
  if (s.outcome === "ok_empty_filters") return "Rows exist, but the current filters exclude all of them.";
  return "–";
}

/** A warehouse id as name and id, from the names the export carries. */
export function whNameId(id: unknown): { name: string; id: string | null } {
  if (id === null || id === undefined || id === "" || String(id) === "null") return { name: "(no warehouse)", id: null };
  return { name: String(resolveName("warehouse", null, id) || id), id: String(id) };
}

// ═══════════════════════ Warehouse load over the window ═══════════════════════

export interface WhLoad {
  id: string;
  name: string;
  /** Hours the warehouse ran (cluster-hours at its size), and the parts of them. */
  billed: number;
  idle: number;
  queuedMs: number;
  spend: number | null;
  /** Per day: up hours, busy and idle hours (null when there is no split), queued share of running time. */
  days: Map<string, { up: number; busy: number | null; idle: number | null; queuedShare: number }>;
}

/** Busy, idle and queued hours per warehouse and day (sf_wh_state_daily), plus queue time per warehouse. */
export function useWarehouseLoad(filters: Filters) {
  useNames();
  const day = useFindingAgg("sf_wh_state_daily", filters.window, filters.accountIds,
    ["warehouse_id", "usage_date"], "sum", "up_hours", { also: ["busy_hours", "idle_hours", "queued_hours", "running_hours", "est_compute_usd_list"], pick: ["not_assessed_reason"] });
  const queue = useFindingAgg("query_queuing_waits", filters.window, filters.accountIds,
    ["warehouse_id"], "sum", "waiting_at_capacity_ms_sum");
  const data = React.useMemo(() => {
    if (!(day.phase === "ready" && day.outcome === "ok_rows" && day.data)) return null;
    const disc = numOrZero(day.data.discount_pct);
    const by = new Map<string, WhLoad>();
    const allDays = new Set<string>();
    let priced = false, unsized = 0;
    const unsizedIds = new Set<string>();
    (day.data.groups || []).forEach((g: Row) => {
      if (!g.key || g.key[0] == null || g.key[1] == null) return;
      const id = String(g.key[0]);
      const d = String(g.key[1]).slice(0, 10);
      const a = g.also || {};
      allDays.add(d);
      // No size, no hours: such a warehouse is counted apart, never drawn as idle or off.
      if (g.value == null) { if (g.pick && g.pick.not_assessed_reason === "unknown_size") unsizedIds.add(id); return; }
      const up = numOrZero(g.value);
      let w = by.get(id);
      if (!w) { const n = whNameId(id); w = { id, name: n.name, billed: 0, idle: 0, queuedMs: 0, spend: null, days: new Map() }; by.set(id, w); }
      const idle = a.idle_hours == null ? null : numOrZero(a.idle_hours);
      const busy = a.busy_hours == null || idle == null ? null : numOrZero(a.busy_hours);
      const running = numOrZero(a.running_hours);
      w.billed += up;
      w.idle += idle || 0;
      if (a.est_compute_usd_list != null) { priced = true; w.spend = (w.spend || 0) + numOrZero(a.est_compute_usd_list) * (1 - disc); }
      w.days.set(d, { up, busy, idle, queuedShare: running > 0 ? Math.min(1, numOrZero(a.queued_hours) / running) : 0 });
    });
    unsizedIds.forEach((id) => { if (!by.has(id)) unsized += 1; });
    if (queue.phase === "ready" && queue.outcome === "ok_rows" && queue.data) {
      (queue.data.groups || []).forEach((g: Row) => { const w = g.key && by.get(String(g.key[0])); if (w) w.queuedMs += numOrZero(g.value); });
    }
    const days = fillRange([...allDays].sort());
    const list = [...by.values()].filter((w) => w.billed > 0)
      .sort((a, b) => b.queuedMs - a.queuedMs || (pctOf(b.idle, b.billed) ?? 0) - (pctOf(a.idle, a.billed) ?? 0));
    return { list, days, priced, unsized };
  }, [day, queue]);
  return { day, queue, data };
}

/** Hours with one decimal under 10. */
const hrs1 = (v: number) => (v < 10 ? v.toFixed(1) : fmtInt(Math.round(v)));

/** Every calendar day from the first to the last, so a day with no billing still takes its slot. */
function fillRange(sorted: string[]): string[] {
  if (sorted.length < 2) return sorted;
  const out: string[] = [];
  const end = new Date(`${sorted[sorted.length - 1]}T00:00:00Z`).getTime();
  for (let t = new Date(`${sorted[0]}T00:00:00Z`).getTime(); t <= end; t += 86400000) out.push(new Date(t).toISOString().slice(0, 10));
  return out;
}

/** One band per warehouse: each day split busy / idle (billed) / not running, with idle %, queue time and spend. */
export function WarehouseLoadBands({ load, meta, filters, n = 6, onRow, more }: {
  load: ReturnType<typeof useWarehouseLoad>; meta: Meta | null; filters: Filters; n?: number;
  onRow?: (w: WhLoad) => void; more?: React.ReactNode;
}) {
  const note = aggNote(load.day, meta, filters.window);
  if (note) return <div className="chart-note-oneline">{note}</div>;
  const d = load.data;
  if (!d || !d.list.length) return <div className="chart-note-oneline">{aggNote({ phase: "ready", outcome: "ok_empty_window", data: null, error: null }, meta, filters.window)}</div>;
  const partialDay = (meta && meta.cost_cutoff && meta.cost_cutoff.partial_day) || null;
  const lastPartial = !!partialDay && d.days[d.days.length - 1] === partialDay;
  const queueKnown = load.queue.phase === "ready" && load.queue.outcome === "ok_rows";
  const rows: StateBandRow[] = d.list.slice(0, n).map((w) => {
    const segs: StateBandRow["segments"] = [];
    d.days.forEach((day) => {
      const x = w.days.get(day);
      const up = x ? x.up : 0;
      // A day is one slot: 24 h, or more when several clusters ran at once.
      const slot = Math.max(24, up);
      if (x && x.busy != null && x.idle != null) {
        // Queued is the part of busy time with a query waiting for a slot, never added to it.
        const queued = x.busy * x.queuedShare, busy = x.busy - queued;
        if (busy > 0) segs.push({ state: "busy", value: busy / slot, title: `${day}: ${hrs1(busy)} h busy` });
        if (queued > 0) segs.push({ state: "queued", value: queued / slot, title: `${day}: ${hrs1(queued)} h busy with queries queued` });
        if (x.idle > 0) segs.push({ state: "idle", value: x.idle / slot, title: `${day}: ${hrs1(x.idle)} h idle, paying` });
      } else if (up > 0) segs.push({ state: "none", value: up / slot, title: `${day}: ${hrs1(up)} h running, no busy/idle split` });
      if (slot - up > 0) segs.push({ state: "off", value: (slot - up) / slot, title: `${day}: not running` });
    });
    return {
      key: w.id, name: w.name, id: w.id, segments: segs, partialLast: lastPartial,
      onClick: onRow ? () => onRow(w) : undefined,
      metrics: [
        `${fmtShare(pctOf(w.idle, w.billed))} idle`,
        queueKnown ? (w.queuedMs > 0 ? `${fmtDuration(w.queuedMs / 1000)} queued` : "no queue") : "queue –",
        d.priced && w.spend != null ? fmtMoney(w.spend, 0) : "$ –",
      ].join(" · "),
    };
  });
  return (
    <div>
      <StateBandList rows={rows} legend={["busy", "queued", "idle", "off"]} ariaLabel="Warehouse load by day" />
      <div className="de-more">
        {`${fmtInt(Math.min(n, d.list.length))} of ${fmtInt(d.list.length + d.unsized)} warehouses that billed${d.unsized ? ` · ${fmtInt(d.unsized)} of unknown size not drawn` : ""}${lastPartial ? " · the last day is partial" : ""} · compute spend is context`}
        {more}
      </div>
    </div>
  );
}

// ═══════════════════════ Query patterns ═══════════════════════

// One group per check row (the check's own grain); the costliest first.
export const SHAPE_KEY = ["account_id", "warehouse_id", "group_kind", "group_id", "statement_type", "status"];

export interface PatternRow {
  key: string;
  shape: string;
  groupId: string;
  wh: { name: string; id: string | null };
  user: string | null;
  runs: number;
  usd: number;
  readBytes: number | null;
  avgMs: number | null;
  cacheShare: number | null;
  status: string;
}

/** The top statement shapes by $, with runs, bytes read, time and result-cache share. */
export function useQueryPatterns(filters: Filters, top: number) {
  useNames();
  const s = useFindingAgg("query_top_by_cost", filters.window, filters.accountIds, SHAPE_KEY, "sum", "est_cost_usd_list",
    { top, also: ["runs", "read_bytes", "total_exec_ms"], pick: ["statement_shape", "top_user", "from_result_cache_share"] });
  const rows = React.useMemo((): PatternRow[] | null => {
    if (!(s.phase === "ready" && s.outcome === "ok_rows" && s.data)) return null;
    const disc = numOrZero(s.data.discount_pct);
    return (s.data.groups || []).filter((g: Row) => g.key).map((g: Row, i: number) => {
      const k = g.key, a = g.also || {}, p = g.pick || {};
      const type = String(k[4] || "").replace(/_/g, " ");
      const runs = numOrZero(a.runs);
      return {
        key: `${k.join("|")}|${i}`,
        shape: p.statement_shape ? String(p.statement_shape) : `${type || "statement"}${k[3] ? ` #${String(k[3]).slice(0, 8)}` : ""}`,
        groupId: String(k[3] ?? ""),
        wh: whNameId(k[1]), user: p.top_user ? String(p.top_user) : null, runs,
        usd: numOrZero(g.value) * (1 - disc),
        readBytes: a.read_bytes != null ? numOrZero(a.read_bytes) : null,
        avgMs: runs > 0 && a.total_exec_ms != null ? numOrZero(a.total_exec_ms) / runs : null,
        cacheShare: p.from_result_cache_share != null ? numOrZero(p.from_result_cache_share) : null,
        status: String(k[5] || "OK"),
      };
    }).sort((a: PatternRow, b: PatternRow) => b.usd - a.usd);
  }, [s]);
  const shapes = s.phase === "ready" && s.outcome === "ok_rows" && s.data ? numOrZero(s.data.group_count) : null;
  const total = s.phase === "ready" && s.outcome === "ok_rows" && s.data ? aggTotal(s.data) : null;
  return { state: s, rows, shapes, total };
}

type SortKey = "runs" | "usd" | "per" | "read" | "avg" | "cache";
const COLS: { k: SortKey; label: string }[] = [
  { k: "runs", label: "Runs" }, { k: "usd", label: "Total $" }, { k: "per", label: "$ / run" },
  { k: "read", label: "Scanned" }, { k: "avg", label: "Avg time" }, { k: "cache", label: "Cache hits" },
];

/** Shapes as a sortable table: shape · warehouse · user, runs, $, $/run, bytes scanned, avg time, cache hits. */
export function QueryPatternTable({ rows, n = 10, onOpen }: { rows: PatternRow[]; n?: number; onOpen?: (r: PatternRow) => void }) {
  const [sort, setSort] = React.useState<SortKey>("usd");
  const val = (r: PatternRow, k: SortKey): number => {
    if (k === "runs") return r.runs;
    if (k === "usd") return r.usd;
    if (k === "per") return r.runs > 0 ? r.usd / r.runs : -1;
    if (k === "read") return r.readBytes ?? -1;
    if (k === "avg") return r.avgMs ?? -1;
    return r.cacheShare ?? -1;
  };
  const shown = [...rows].sort((a, b) => val(b, sort) - val(a, sort)).slice(0, n);
  // A cache column that reads 0% on every shape says nothing: drop it and say so once under the table.
  const noCache = shown.length > 0 && shown.every((r) => r.cacheShare == null || r.cacheShare === 0);
  const cols = noCache ? COLS.filter((c) => c.k !== "cache") : COLS;
  return (
    <div>
    <div className="b2-scroll de-qp-box">
      <table className="de-qp">
        <thead>
          <tr>
            <th scope="col">Shape · warehouse · user</th>
            {cols.map((c) => (
              <th key={c.k} scope="col" className="num" aria-sort={sort === c.k ? "descending" : undefined}>
                <button type="button" className={`de-sort${sort === c.k ? " on" : ""}`} onClick={() => setSort(c.k)}>{c.label}{sort === c.k ? " ↓" : ""}</button>
              </th>
            ))}
            <th scope="col" aria-label="Open" />
          </tr>
        </thead>
        <tbody>
          {shown.map((r) => (
            <tr key={r.key}>
              <td>
                <span className="de-qp-shape">
                  <span className="de-qp-chip">{r.shape}</span>
                  <span className="de-qp-sub"><NameId name={r.wh.name} id={r.wh.id} />{r.user ? ` · ${r.user}` : ""}</span>
                </span>
              </td>
              <td className="num">{fmtInt(r.runs)}</td>
              <td className="num"><b>{fmtMoney(r.usd, 0)}</b></td>
              <td className="num">{r.runs > 0 ? fmtMoney(r.usd / r.runs, r.usd / r.runs >= 100 ? 0 : 2) : "–"}</td>
              <td className="num">{r.readBytes != null ? fmtBytes(r.readBytes) : "–"}</td>
              <td className="num">{r.avgMs != null ? fmtDur(r.avgMs / 1000) : "–"}</td>
              {!noCache && <td className="num">{r.cacheShare != null ? fmtShare(r.cacheShare * 100) : "–"}</td>}
              <td className="num">{onOpen && <button type="button" className="ck-link" onClick={() => onOpen(r)}>{"Runs →"}</button>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
    {noCache && <div className="de-more">{`None of these ${fmtInt(shown.length)} shapes was served from the result cache (0% cache hits on every one), so the column is left out.`}</div>}
    </div>
  );
}
