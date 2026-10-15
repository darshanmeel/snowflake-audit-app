// web/src/components/run_blocks.tsx -- blocks on the per-day and per-month checks: task runs as a
// grid and as state lines, failed runs vs all runs in the task drawer, a warehouse's hours per day,
// and warehouse spend by calendar month. Each reads one aggregate call; a check that did not run
// reads "–" and why, "…" while loading, and a day or month with no usage keeps its slot.
import React from "react";
import { fmtDayShort, fmtInt, fmtMoney } from "../format";
import { fillDays, numOrZero, useFindingAgg } from "./hooks";
import { aggNote, whNameId } from "./de_blocks";
import { CompareToBaseline, RunGrid, StateBandList } from "./blocks_2";
import type { BaselineRow, Health, RunCell, RunGridRow, StateBandRow } from "./blocks_2";
import { registerDrawerBlock } from "./drawer_blocks";
import type { DrawerBlockProps } from "./drawer";
import { fmtShare, pctOf } from "./blocks";
import type { FetchState, Filters, Meta, Row } from "../types";

const RUNS_ID = "sf_task_runs_daily";
const ATTR_ID = "sf_task_failure_attributes";
const STATE_ID = "sf_wh_state_daily";
const MONTH_ID = "sf_wh_spend_monthly";

const ready = (s: FetchState) => s.phase === "ready" && s.outcome === "ok_rows" && !!s.data;

/** Every day of the window, oldest first; from the data's own days when the export has no as-of date. */
export function windowDayList(meta: Meta | null, windowDays: number, seen: string[]): string[] {
  if (meta && meta.as_of_date) return fillDays([], meta.as_of_date, windowDays, meta.snapshot_days).map((d) => d.day);
  return [...new Set(seen)].sort();
}

/** True when the window's last day is the export's partial day (today, still filling). */
function lastIsPartial(meta: Meta | null, days: string[]): boolean {
  const pd = (meta && meta.cost_cutoff && meta.cost_cutoff.partial_day) || null;
  return !!pd && days[days.length - 1] === String(pd).slice(0, 10);
}

// ═══════════════════════ Task runs per day ═══════════════════════

interface DayRuns { failed: number; ok: number; slow: number; quiet: number; runs: number; err: string | null }
export interface TaskRuns { name: string; id: string | null; failed: number; runs: number; slow: number; lastErr: string | null; days: Map<string, DayRuns> }

/** Runs per task and day from sf_task_runs_daily, plus failed and all runs per day. */
export function useTaskRunDays(filters: Filters) {
  const s = useFindingAgg(RUNS_ID, filters.window, filters.accountIds, ["task_full_name", "run_date"], "sum", "failed_runs",
    { also: ["runs", "succeeded_runs", "skipped_runs", "cancelled_runs", "slow_runs"], pick: ["task_id", "last_error_code"] });
  const data = React.useMemo(() => {
    if (!ready(s)) return null;
    const tasks = new Map<string, TaskRuns>();
    const failedByDay = new Map<string, number>(), runsByDay = new Map<string, number>();
    (s.data.groups || []).forEach((g: Row) => {
      if (!g.key || g.key[0] == null || g.key[1] == null) return;
      const name = String(g.key[0]), day = String(g.key[1]).slice(0, 10);
      const a = g.also || {}, pk = g.pick || {};
      let t = tasks.get(name);
      if (!t) { t = { name, id: pk.task_id != null ? String(pk.task_id) : null, failed: 0, runs: 0, slow: 0, lastErr: null, days: new Map() }; tasks.set(name, t); }
      const failed = numOrZero(g.value), runs = numOrZero(a.runs);
      const cur = t.days.get(day) || { failed: 0, ok: 0, slow: 0, quiet: 0, runs: 0, err: null };
      cur.failed += failed; cur.ok += numOrZero(a.succeeded_runs); cur.slow += numOrZero(a.slow_runs);
      cur.quiet += numOrZero(a.skipped_runs) + numOrZero(a.cancelled_runs); cur.runs += runs;
      if (failed > 0 && pk.last_error_code) cur.err = String(pk.last_error_code);
      t.days.set(day, cur);
      t.failed += failed; t.runs += runs; t.slow += numOrZero(a.slow_runs);
      failedByDay.set(day, (failedByDay.get(day) || 0) + failed);
      runsByDay.set(day, (runsByDay.get(day) || 0) + runs);
    });
    tasks.forEach((t) => {
      const lastFail = [...t.days.entries()].filter(([, d]) => d.failed > 0).sort((a, b) => b[0].localeCompare(a[0]))[0];
      t.lastErr = lastFail ? lastFail[1].err : null;
    });
    const list = [...tasks.values()].sort((a, b) => b.failed - a.failed || b.slow - a.slow || a.name.localeCompare(b.name));
    return { list, failedByDay, runsByDay, seen: [...runsByDay.keys()] };
  }, [s]);
  return { state: s, data };
}

function cellOf(d: DayRuns | undefined): RunCell {
  if (!d) return "none";
  if (d.failed > 0) return "failed";
  if (d.slow > 0) return "slow";
  if (d.ok > 0) return "ok";
  return "skipped";
}

/** Failing when its last day with runs failed, degraded when any run failed or ran slow. */
function healthOf(t: TaskRuns): Health {
  const last = [...t.days.entries()].filter(([, d]) => d.runs > 0).sort((a, b) => b[0].localeCompare(a[0]))[0];
  if (last && last[1].failed > 0) return "failing";
  if (t.failed > 0 || t.slow > 0) return "degraded";
  return "healthy";
}

/** A task's short name from database.schema.task. */
const shortTask = (full: string) => full.split(".").pop() || full;

/** Rows = the tasks that failed or ran slow, columns = days, failed runs per day on top. */
export function TaskRunGrid({ load, meta, filters, n = 12, onTask }: {
  load: ReturnType<typeof useTaskRunDays>; meta: Meta | null; filters: Filters; n?: number; onTask?: (t: TaskRuns) => void;
}) {
  const note = aggNote(load.state, meta, filters.window);
  if (note) return <div className="chart-note-oneline">{note}</div>;
  const d = load.data!;
  const days = windowDayList(meta, filters.window, d.seen);
  const hit = d.list.filter((t) => t.failed > 0 || t.slow > 0);
  if (!hit.length) return <div className="chart-note-oneline">{`No task run failed or ran slow in the ${fmtInt(d.list.length)} tasks that ran.`}</div>;
  const rows: RunGridRow[] = hit.slice(0, n).map((t) => ({
    key: t.name, name: shortTask(t.name), id: t.id, health: healthOf(t),
    cells: days.map((day) => cellOf(t.days.get(day))),
    metric: [t.runs > 0 ? `${fmtShare(pctOf(t.failed, t.runs))} failed` : null, t.slow > 0 ? `${fmtInt(t.slow)} slow` : null, t.lastErr ? `err ${t.lastErr}` : null].filter(Boolean).join(" · "),
    onClick: onTask ? () => onTask(t) : undefined,
  }));
  const partial = lastIsPartial(meta, days);
  return (
    <div>
      <RunGrid days={days} rows={rows} perDay={days.map((day) => d.failedByDay.get(day) || 0)} partialLast={partial} ariaLabel="Task runs by task and day" />
      <div className="de-more">{`${fmtInt(rows.length)} of ${fmtInt(hit.length)} tasks that failed or ran slow · ${fmtInt(d.list.length)} tasks ran${partial ? " · the last day is partial" : ""} · green ok, red failed, amber slow, grey skipped, hatched no run`}</div>
    </div>
  );
}

/** One state line per task: each day ok, failing, slow or no run, the worst first. */
export function TaskStateBands({ load, meta, filters, n = 6, onRow }: {
  load: ReturnType<typeof useTaskRunDays>; meta: Meta | null; filters: Filters; n?: number; onRow?: (t: TaskRuns) => void;
}) {
  const note = aggNote(load.state, meta, filters.window);
  if (note) return <div className="chart-note-oneline">{note}</div>;
  const d = load.data!;
  if (!d.list.length) return <div className="chart-note-oneline">{aggNote({ phase: "ready", outcome: "ok_empty_window", data: null, error: null }, meta, filters.window)}</div>;
  const days = windowDayList(meta, filters.window, d.seen);
  const partial = lastIsPartial(meta, days);
  const word: Record<RunCell, StateBandRow["segments"][number]["state"]> = { ok: "ok", failed: "failing", slow: "slow", skipped: "ok", none: "none" };
  const rows: StateBandRow[] = d.list.slice(0, n).map((t) => {
    const segs: StateBandRow["segments"] = [];
    days.forEach((day) => {
      const st = word[cellOf(t.days.get(day))];
      const last = segs[segs.length - 1];
      // Runs of the same state merge into one segment.
      if (last && last.state === st) { last.value += 1; last.title = `${last.title!.split(" – ")[0]} – ${fmtDayShort(day)}: ${st}`; }
      else segs.push({ state: st, value: 1, title: `${fmtDayShort(day)}: ${st}` });
    });
    return {
      key: t.name, name: shortTask(t.name), id: t.id, segments: segs, partialLast: partial,
      onClick: onRow ? () => onRow(t) : undefined,
      metrics: `${t.runs > 0 ? `${fmtShare(pctOf(t.failed, t.runs))} failed` : "no runs"} · ${fmtInt(t.runs)} runs`,
    };
  });
  return (
    <div>
      <StateBandList rows={rows} legend={["ok", "failing", "slow", "none"]} ariaLabel="Task state by day" />
      <div className="de-more">{`${fmtInt(rows.length)} of ${fmtInt(d.list.length)} tasks that ran · most failed runs first${partial ? " · the last day is partial" : ""}`}</div>
    </div>
  );
}

// ═══════════════════════ Failed runs vs all runs (task drawer) ═══════════════════════

const ATTR_WORD: Record<string, string> = {
  compute: "compute", owner_role: "owner", schedule: "schedule", graph_position: "graph", database: "database",
  trigger: "trigger", attempt: "attempt", hour_utc: "hour (UTC)", weekday: "weekday",
};
const WEEKDAY = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

function attrValue(attr: string, value: any, id: any): string {
  if (attr === "weekday") return WEEKDAY[Number(value) - 1] || String(value);
  if (attr === "compute" && id != null && String(id) !== "") return `${value} (${id})`;
  return String(value ?? "(none)");
}

/** The task's failed runs against its own runs, or every failed run against all runs when no task is picked. */
function TaskBaselineBlock({ target, filters, meta }: DrawerBlockProps) {
  const s = useFindingAgg(ATTR_ID, filters.window, filters.accountIds, ["task_full_name", "attribute", "attr_value"], "sum", "failed_runs",
    { also: ["runs"], pick: ["attr_id"] });
  const task = target.col === "task_full_name" && target.val ? target.val : null;
  if (target.col && !task) return null;
  if (s.phase === "loading") return <div className="dr-loading">…</div>;
  if (!ready(s)) {
    const why = aggNote(s, meta || null, filters.window);
    return why && why !== "…" ? <div className="dr-section"><div className="dr-eyebrow">Failed runs vs all runs</div><div className="dr-note">{why}</div></div> : null;
  }
  const mine = (s.data.groups || []).filter((g: Row) => g.key && (task ? String(g.key[0]) === task : g.key[0] == null));
  const tot = new Map<string, { f: number; r: number }>();
  mine.forEach((g: Row) => {
    const a = String(g.key[1]);
    const cur = tot.get(a) || { f: 0, r: 0 };
    cur.f += numOrZero(g.value); cur.r += numOrZero(g.also && g.also.runs);
    tot.set(a, cur);
  });
  const rows: BaselineRow[] = mine.map((g: Row) => {
    const a = String(g.key[1]), t = tot.get(a)!;
    return { key: `${a}|${g.key[2]}`, attr: ATTR_WORD[a] || a, value: attrValue(a, g.key[2], g.pick && g.pick.attr_id),
      sel: pctOf(numOrZero(g.value), t.f), all: pctOf(numOrZero(g.also && g.also.runs), t.r) };
  }).filter((r: BaselineRow) => r.sel != null && r.all != null);
  if (!rows.length) return null;
  return (
    <div className="dr-section">
      <CompareToBaseline title={task ? "Failed runs vs all runs of this task" : "Failed runs vs all task runs"} selLabel="failed runs" allLabel="all runs" rows={rows} n={6} />
    </div>
  );
}
registerDrawerBlock("sf_task_failures", TaskBaselineBlock);

// ═══════════════════════ A warehouse's hours per day ═══════════════════════

/** Busy and idle hours per day for one warehouse (sf_wh_state_daily), each day its own column. */
export function WarehouseHoursPerDay({ warehouseId, filters, meta }: { warehouseId: string; filters: Filters; meta?: Meta | null }) {
  const s = useFindingAgg(STATE_ID, filters.window, filters.accountIds, ["warehouse_id", "usage_date"], "sum", "up_hours",
    { also: ["busy_hours", "idle_hours", "queued_hours", "running_hours"] });
  const head = <div className="dr-eyebrow">Hours per day · busy vs idle</div>;
  if (s.phase === "loading") return <div className="dr-section">{head}<div className="dr-loading">…</div></div>;
  const why = aggNote(s, meta || null, filters.window);
  if (why) return <div className="dr-section">{head}<div className="dr-note">{why}</div></div>;
  const byDay = new Map<string, { busy: number | null; idle: number | null; up: number | null }>();
  (s.data.groups || []).forEach((g: Row) => {
    if (!g.key || String(g.key[0]) !== warehouseId || g.key[1] == null) return;
    const a = g.also || {};
    byDay.set(String(g.key[1]).slice(0, 10), {
      up: g.value == null ? null : numOrZero(g.value),
      busy: a.busy_hours == null ? null : numOrZero(a.busy_hours), idle: a.idle_hours == null ? null : numOrZero(a.idle_hours),
    });
  });
  if (!byDay.size) return <div className="dr-section">{head}<div className="dr-note">No billed hours for this warehouse in this window.</div></div>;
  const days = windowDayList(meta || null, filters.window, [...byDay.keys()]);
  const max = Math.max(1, ...[...byDay.values()].map((v) => numOrZero(v.up)));
  const vals = [...byDay.values()];
  const split = vals.filter((v) => v.idle != null);
  const sizeUnknown = vals.every((v) => v.up == null);
  const busyAvg = split.length ? split.reduce((a, v) => a + numOrZero(v.busy), 0) / days.length : null;
  const idleAvg = split.length ? split.reduce((a, v) => a + numOrZero(v.idle), 0) / days.length : null;
  const h = (v: number) => (v < 10 ? v.toFixed(1) : fmtInt(Math.round(v)));
  const partial = lastIsPartial(meta || null, days);
  return (
    <div className="dr-section">
      {head}
      {sizeUnknown ? <div className="dr-note">– Its size is not known (adaptive, or SHOW WAREHOUSES does not list it), so credits are not turned into hours.</div> : (
        <>
          <div className="rb-hours" role="img" aria-label="Busy and idle hours per day">
            {days.map((day, i) => {
              const v = byDay.get(day);
              const up = v ? numOrZero(v.up) : 0;
              const known = !!v && v.idle != null;
              const busy = known ? numOrZero(v!.busy) : 0, idle = known ? numOrZero(v!.idle) : 0;
              const title = !v ? `${fmtDayShort(day)}: not running` : known ? `${fmtDayShort(day)}: ${h(busy)} h busy, ${h(idle)} h idle` : `${fmtDayShort(day)}: ${h(up)} h, no busy/idle split`;
              return (
                <span key={day} className={`rb-hcol${partial && i === days.length - 1 ? " partial" : ""}`} title={title}>
                  {known ? <>
                    <span className="rb-h-idle" style={{ height: `${(100 * idle) / max}%` }} />
                    <span className="rb-h-busy" style={{ height: `${(100 * busy) / max}%` }} />
                  </> : v ? <span className="rb-h-none" style={{ height: `${(100 * up) / max}%` }} /> : null}
                </span>
              );
            })}
          </div>
          <div className="rb-hours-axis b2-mono"><span>{fmtDayShort(days[0])}</span><span>{fmtDayShort(days[days.length - 1])}</span></div>
          <div className="b2-legend rb-hours-legend">
            <span className="b2-legend-item"><span className="b2-sw s-busy" />{busyAvg != null ? `busy ${h(busyAvg)} h / day` : "busy"}</span>
            <span className="b2-legend-item"><span className="b2-sw s-idle" />{idleAvg != null ? `idle ${h(idleAvg)} h / day` : "idle"}</span>
            {split.length < vals.length && <span className="b2-legend-item"><span className="b2-sw s-none" />no busy/idle split</span>}
          </div>
        </>
      )}
    </div>
  );
}

function WarehouseHoursBlock({ target, filters, meta }: DrawerBlockProps) {
  if (target.col !== "warehouse_id" || target.val == null) return null;
  return <WarehouseHoursPerDay warehouseId={target.val} filters={filters} meta={meta} />;
}
registerDrawerBlock("sf_wh_load_utilization", WarehouseHoursBlock);

// ═══════════════════════ Warehouse spend by calendar month ═══════════════════════

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const PALETTE = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)"];

/** Spend per calendar month for the top warehouses and the rest; this month is partial, a month before the history is hatched. */
export function WarehouseSpendMonths({ filters, meta, n = 4 }: { filters: Filters; meta?: Meta | null; n?: number }) {
  const s = useFindingAgg(MONTH_ID, filters.window, filters.accountIds, ["warehouse_id", "month_start", "partial_reason"], "sum", "usd_list",
    { pick: ["warehouse_name"] });
  const note = aggNote(s, meta || null, filters.window);
  if (note) return <div className="chart-note-oneline">{note}</div>;
  const disc = numOrZero(s.data.discount_pct);
  const months = new Map<string, { reason: string | null; by: Map<string, number> }>();
  const totals = new Map<string, number>();
  const names = new Map<string, string>();
  let priced = 0;
  (s.data.groups || []).forEach((g: Row) => {
    if (!g.key || g.key[1] == null) return;
    const id = String(g.key[0]), m = String(g.key[1]).slice(0, 7), reason = g.key[2] == null ? null : String(g.key[2]);
    const cur = months.get(m) || { reason, by: new Map() };
    if (reason) cur.reason = reason;
    if (g.value != null) {
      const v = numOrZero(g.value) * (1 - disc);
      cur.by.set(id, (cur.by.get(id) || 0) + v);
      if (reason !== "month_in_progress") totals.set(id, (totals.get(id) || 0) + v);
      priced += 1;
    }
    months.set(m, cur);
    if (g.pick && g.pick.warehouse_name) names.set(id, String(g.pick.warehouse_name));
  });
  if (!priced && months.size) return <div className="chart-note-oneline">– Not priced: this export has no $ per credit.</div>;
  const top = [...totals.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([id]) => id);
  const keys = [...months.keys()].sort();
  const stack = (m: string) => {
    const by = months.get(m)!.by;
    const segs = top.map((id, i) => ({ key: id, color: PALETTE[i], v: by.get(id) || 0 }));
    const rest = [...by.entries()].filter(([id]) => !top.includes(id)).reduce((a, [, v]) => a + v, 0);
    return [...segs, { key: "__other", color: "var(--c-other)", v: rest }];
  };
  const sums = keys.map((m) => stack(m).reduce((a, x) => a + x.v, 0));
  const max = Math.max(1, ...sums);
  const label = (m: string) => MONTHS[Number(m.slice(5, 7)) - 1] || m;
  const nameOf = (id: string) => `${names.get(id) || whNameId(id).name} (${id})`;
  const otherN = new Set([...months.values()].flatMap((x) => [...x.by.keys()])).size - top.length;
  return (
    <div>
      <div className="rb-months" role="img" aria-label="Warehouse spend by calendar month">
        {keys.map((m, i) => {
          const r = months.get(m)!.reason;
          const noHist = r === "no_history";
          const part = r === "month_in_progress" || r === "history_starts_mid_month";
          const segs = stack(m);
          return (
            <div key={m} className="rb-mcol">
              <div className={`rb-mtrack${part ? " partial" : ""}${noHist ? " blk-hatch" : ""}`}
                title={noHist ? `${label(m)}: before the usage history starts` : `${label(m)} ${m.slice(0, 4)}${part ? (r === "month_in_progress" ? " (so far)" : " (history starts mid-month)") : ""}: ${fmtMoney(sums[i], 0)}`}>
                {!noHist && segs.map((x) => x.v > 0 && <span key={x.key} style={{ height: `${(100 * x.v) / max}%`, background: x.color }} />)}
              </div>
              <div className="rb-mlabel">{`${label(m)}${r === "month_in_progress" ? " ½" : ""}`}</div>
            </div>
          );
        })}
      </div>
      <div className="b2-legend rb-months-legend">
        {top.map((id, i) => <span key={id} className="b2-legend-item"><span className="b2-sw" style={{ background: PALETTE[i] }} />{nameOf(id)}</span>)}
        {otherN > 0 && <span className="b2-legend-item"><span className="b2-sw" style={{ background: "var(--c-other)" }} />{`${fmtInt(otherN)} other warehouses`}</span>}
      </div>
      <div className="de-more">{`${fmtInt(keys.length)} months · ½ = this month so far, never scaled up · spend, not waste`}</div>
    </div>
  );
}
