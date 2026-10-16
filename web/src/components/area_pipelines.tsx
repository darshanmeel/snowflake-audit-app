// web/src/components/area_pipelines.tsx -- the lead of the Tasks & pipelines, Data loading and
// Serverless features sub-tabs: issue tiles (a % or the flagged $), then the chart that shows the
// driver, each bar opening its task or check. One fetch per check feeds both the tiles and charts.
// A check that did not run reads "-" and why; a figure still loading reads "…".
import React from "react";
import "../styles/css/p_area_pipelines.css";
import { fmtBytes, fmtCredits, fmtDayShort, fmtInt, fmtMoney } from "../format";
import { FLAGGED_STATUSES, aggTotal, numOrZero, taskName, useFindingAgg, useFindingData, useMultiFindingData } from "./hooks";
import type { DimMaps } from "./hooks";
import { ChartCard, KindChip, StatusPill, bandOf, bandPillKind } from "./primitives";
import { COST_MONEY_COL } from "./tab_registry";
import { DrillTable } from "./drill_table";
import { CellBar, CxTable, FqnText, SevWord, ShowRows } from "./cx_b";
import { DrawerBus } from "./drawer";
import { rowLabelWidth } from "./charts_more";
import { truncateLeft, useChartWidth } from "./charts";
import { notAssessedText } from "./scope";
import { scrollToAnchor, windowShortLabel } from "./overview_tile";
import { TaskFocus } from "./names";
import { CauseSplitBar, IssueTile, ShareBarList, StackedShareBar, StatusBars, fmtShare, pctOf } from "./blocks";
import type { IssueTileProps, StatusBarItem } from "./blocks";
import { DumbbellRows } from "./blocks_2";
import { TaskRunGrid, useTaskRunDays } from "./run_blocks";
import { CsvButton } from "./csv";
import type { CsvColumn } from "./csv";
import type { DumbbellRow } from "./blocks_2";
import { warehouseNameId, withoutTotalRows } from "../tabs/tab_area";
import type { ApPageProps } from "./area_pages";
import type { Dims, FetchState, Finding, Row } from "../types";

// ═══════════════════════ shared plumbing ═══════════════════════

/** One check's rows as this page reads them: rows, or a one-line note why there are none. */
interface PlCheck {
  id: string;
  f: Finding | null;
  loading: boolean;
  rows: Row[];
  note: string | null;
  disc: number;
  priced: boolean;
}
type PlData = Record<string, PlCheck>;

function readCheck(id: string, f: Finding | null, st: FetchState | undefined, p: ApPageProps): PlCheck {
  const base: PlCheck = { id, f, loading: false, rows: [], note: null, disc: 0, priced: true };
  if (!f) return { ...base, note: "– Not in this export yet: run the export again." };
  if (!st || st.phase === "loading") return { ...base, loading: true };
  if (st.phase === "error") return { ...base, note: `– ${st.error || "Could not load"}` };
  const d = st.data || {};
  const oc = st.outcome;
  if (oc === "not_assessed") return { ...base, note: `– ${notAssessedText(d)}` };
  if (oc === "error") return { ...base, note: `– ${d.error || "The check failed."}` };
  if (oc === "ok_empty_window") {
    const w = windowShortLabel(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
    return { ...base, note: `No data for this in ${w || `the last ${p.filters.window} days`}` };
  }
  if (oc === "ok_empty_filters") {
    return { ...base, note: d.scope && d.scope.none_flagged ? "Nothing flagged in this window." : "Rows exist, but the current filters exclude all of them." };
  }
  if (oc !== "ok_rows") return { ...base, note: "–" };
  const rows = withoutTotalRows(d.rows).filter((r) => r.status !== "NOT_ASSESSED");
  const priced = f.money_reason !== "unpriced" && (rows.length === 0 || rows.some((r) => r.price_basis === undefined || r.price_basis !== "unpriced"));
  return { ...base, rows, disc: numOrZero(d.discount_pct), priced };
}

/** Fetches every check the page reads once, for both its tiles and its charts. */
function usePlData(p: ApPageProps, ids: string[]): PlData {
  const present = ids.filter((id) => (p.findings || []).some((f) => f.query_id === id));
  const multi = useMultiFindingData(present, p.filters.window, p.filters.accountIds as any, 5000);
  const out: PlData = {};
  ids.forEach((id) => {
    const f = (p.findings || []).find((x) => x.query_id === id) || null;
    const st = multi.phase === "loading" ? undefined : multi.byId[id];
    out[id] = readCheck(id, f, st, p);
  });
  return out;
}

const isFlagged = (r: Row) => FLAGGED_STATUSES.includes(String(r.status || "").toUpperCase());
const num = (v: any): number | null => (v === null || v === undefined || v === "" || !Number.isFinite(Number(v)) ? null : Number(v));
const sum = (rows: Row[], col: string) => rows.reduce((s, r) => s + numOrZero(r[col]), 0);
const usd = (c: PlCheck, r: Row, col: string) => numOrZero(r[col]) * (1 - c.disc);
const usdSum = (c: PlCheck, rows: Row[], col: string) => rows.reduce((s, r) => s + usd(c, r, col), 0);

/** "name (id)" unless the name already carries its id. */
function nameId(name: any, id: any): string {
  const n = name === null || name === undefined || name === "" ? "(no name in this export)" : String(name);
  if (id === null || id === undefined || id === "" || n.includes(`(${id})`)) return n;
  return `${n} (${id})`;
}
function taskLabel(r: Row, dims: Dims): string {
  return nameId(taskName(dims as DimMaps, r.task_full_name || r.task_name), r.task_id);
}
function openTask(r: Row) { TaskFocus.open(r.account_id ?? null, r.task_full_name || r.task_name); }

/** A short duration: "45 s", "9 m", "2.3 h". */
function dur(s: any): string {
  const v = num(s);
  if (v === null) return "–";
  if (v < 90) return `${Math.round(v)} s`;
  if (v < 5400) return `${Math.round(v / 60)} m`;
  return `${(v / 3600).toFixed(1)} h`;
}
const usd0 = (v: number) => fmtMoney(v, 0);
/** A $ rate: "$0.45", "$12.5", "$140". */
const usdRate = (v: number) => fmtMoney(v, v >= 100 ? 0 : v >= 1 ? 1 : 2);
const pctText = (v: any) => fmtShare(num(v));
const signedPct = (v: number | null) => (v === null ? "" : `${v >= 0 ? "+" : "−"}${fmtShare(Math.abs(v))}`);
function rowStatus(r: Row): string { return String(r.status || "OK").toUpperCase(); }

/** The tile status word from a check's band of flagged rows. */
function tileStatus(rows: Row[]): IssueTileProps["status"] {
  if (rows.some((r) => rowStatus(r) === "CRITICAL")) return "critical";
  if (rows.some((r) => rowStatus(r) === "WARN")) return "warn";
  return "ok";
}

const STATUS_ORDER = ["critical", "warn", "ok"];
/** The worse of two tile statuses. */
function worseStatus(a: IssueTileProps["status"], b: IssueTileProps["status"]): IssueTileProps["status"] {
  return STATUS_ORDER.indexOf(String(a)) <= STATUS_ORDER.indexOf(String(b)) ? a : b;
}

/** The flagged count and its base as the check summary has it, so counts agree with every page. */
function counts(c: PlCheck, fallbackNoun: string): { flagged: number; population: number | null; noun: string } {
  const a = c.f && c.f.affected;
  if (a && Number.isFinite(Number(a.flagged))) return { flagged: Number(a.flagged), population: num(a.total), noun: a.noun || fallbackNoun };
  return { flagged: c.rows.filter(isFlagged).length, population: c.rows.length, noun: fallbackNoun };
}

/** " of 56 tasks", or " tasks" when the base is unknown. */
const ofPop = (n: { population: number | null; noun: string }) => (n.population != null ? ` of ${fmtInt(n.population)} ${n.noun}` : ` ${n.noun}`);

/** An IssueTile for a check: loading, missing ("-" and why) or the figure `make` builds. */
function PlTile({ c, open, label, make }: { c: PlCheck; open: () => void; label: string; make: (c: PlCheck) => Partial<IssueTileProps> | null }) {
  if (c.loading) return <IssueTile label={label} headline={null} loading onOpen={open} openLabel="Open check →" />;
  // "–" notes did not run; an empty window or filter ran and found nothing.
  if (c.note) return <IssueTile label={label} headline={null} missingReason={c.note.replace(/^– /, "")} status={c.note.startsWith("–") ? "not_assessed" : "neutral"} onOpen={open} openLabel="Open check →" />;
  const t = make(c);
  if (!t) return <IssueTile label={label} headline={null} missingReason="Nothing to measure in this window." onOpen={open} openLabel="Open check →" />;
  return <IssueTile label={label} headline={null} onOpen={open} openLabel="Open check →" {...t} />;
}

/** A chart card on one check: the chart, or the note why there is none. */
function PlCard({ c, title, subtitle, open, children }: {
  c: PlCheck; title: string; subtitle?: string; open: () => void; children: (c: PlCheck) => React.ReactNode;
}) {
  let body: React.ReactNode;
  if (c.loading) body = <div className="chart-note-oneline">…</div>;
  else if (c.note) body = <div className="chart-note-oneline">{c.note}</div>;
  else body = children(c) || <div className="chart-note-oneline">Nothing flagged in this window.</div>;
  return <ChartCard title={title} subtitle={subtitle} onOpenCheck={open} takeaway={null}>{body}</ChartCard>;
}

function Tiles({ children }: { children?: React.ReactNode }) { return <div className="summary-tile-row compact pl-tiles">{children}</div>; }
function Tiles4({ children }: { children?: React.ReactNode }) { return <div className="summary-tile-row compact sx-tiles-4">{children}</div>; }
function Grid({ children }: { children?: React.ReactNode }) { return <div className="pl-grid">{children}</div>; }
function Note({ children }: { children?: React.ReactNode }) { return <div className="chart-note-oneline pl-note">{children}</div>; }

const opener = (p: ApPageProps) => (id: string) => () => p.goTo({ tab: p.area, subtab: p.subtab, focusQueryId: id });

/** Pages that draw their own tiles mark themselves, so the shell can skip its generic ones. */
export type PlPage = ((p: ApPageProps) => React.JSX.Element) & { ownsTiles?: boolean };

// ═══════════════════════ Tasks & pipelines ═══════════════════════

const TASK_CAUSE: Record<string, string> = {
  auto_suspended_after_failures: "auto-suspended",
  started_but_not_running: "not running",
  suspended_stale: "stale",
  never_ran: "never ran",
  silent_failures: "no alert on failure",
  execute_as_user_gone: "runs as a gone user",
  admin_owner: "owned by an admin role",
  allow_all_overlap: "overlap allowed",
};
const taskCause = (code: string) => TASK_CAUSE[code] || code.replace(/_/g, " ").toLowerCase();
export const computeWord = (r: Row) => {
  const v = r.compute || r.warehouse_name;
  if (!v) return "(no compute)";
  return String(v).toUpperCase() === "SERVERLESS" ? "Serverless" : (warehouseNameId(r, String(v)) || String(v));
};

/** Failed runs split by one key; a missing key is the hatched unknown part. */
export function failedSplit(rows: Row[], keyOf: (r: Row) => string | null, aria: string) {
  const m = new Map<string, number>();
  let none = 0;
  rows.forEach((r) => {
    const v = numOrZero(r.failed_runs);
    if (v <= 0) return;
    const k = keyOf(r);
    if (k) m.set(k, (m.get(k) || 0) + v); else none += v;
  });
  const segs = [...m.entries()].map(([label, value]) => ({ key: label, label, value }));
  if (none > 0) segs.push({ key: "__none", label: "(no error code)", value: none, unknown: true } as any);
  return segs.length ? <StackedShareBar segments={segs} pareto valueFmt={(v) => `${fmtInt(v)} runs`} ariaLabel={aria} /> : null;
}

export function PlTasksFailures(p: ApPageProps) {
  const d = usePlData(p, ["sf_task_failures", "sf_task_silent_failures", "sf_task_alerts", "sf_task_alerts_silenced"]);
  const open = opener(p);
  const fail = d.sf_task_failures, silent = d.sf_task_silent_failures, alerts = d.sf_task_alerts, off = d.sf_task_alerts_silenced;
  // One "broken now" for every tile and bar: failed since its last success; older exports read last_state.
  const failingNow = (r: Row) => (r.consecutive_failures !== undefined ? numOrZero(r.consecutive_failures) > 0 : String(r.last_state || "").toUpperCase() === "FAILED");

  // The figures every tile, card and the lede share.
  const runs = sum(fail.rows, "runs");
  const failed = sum(fail.rows, "failed_runs");
  const byErr = new Map<string, number>();
  fail.rows.forEach((r) => { if (r.last_error_code && numOrZero(r.failed_runs) > 0) byErr.set(String(r.last_error_code), (byErr.get(String(r.last_error_code)) || 0) + numOrZero(r.failed_runs)); });
  const topErr = [...byErr.entries()].sort((a, b) => b[1] - a[1])[0];
  const silentN = !silent.loading && !silent.note ? counts(silent, "root tasks") : null;
  const lede = fail.loading ? "…" : runs > 0
    ? `${fmtShare(pctOf(failed, runs))} of task runs failed.${topErr ? ` Error ${topErr[0]} is ${fmtShare(pctOf(topErr[1], failed))} of failed runs.` : ""}${silentN && silentN.flagged > 0 ? ` ${fmtInt(silentN.flagged)}${silentN.population != null ? ` of ${fmtInt(silentN.population)}` : ""} ${silentN.noun} fail without telling anyone.` : ""}`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const drawerFor = (r: Row) => DrawerBus.open({ id: "sf_task_failures", col: "task_full_name", val: String(r.task_full_name || ""), label: taskLabel(r, p.dims) });
  // The run grid needs the per-day check; an older export without it keeps the failure-rate bars.
  const runDays = useTaskRunDays(p.filters);
  const hasRunDays = (p.findings || []).some((f) => f.query_id === "sf_task_runs_daily");
  const alertCheck = (c: PlCheck, title: string, extra: (c: PlCheck) => string | null) => {
    const band = c.f ? bandOf(c.f) : "NOT_ASSESSED";
    const n = c.note || c.loading ? null : counts(c, "alerts");
    return (
      <button type="button" className="ck-row" key={c.id} onClick={() => DrawerBus.open({ id: c.id })}>
        <span className="ck-pill"><StatusPill kind={bandPillKind(band)} /></span>
        <span className="ck-name" title={title}>{title}</span>
        <span className="ck-fact">{c.loading ? "…" : c.note ? c.note : [n ? `${fmtInt(n.flagged)}${ofPop(n)}` : null, extra(c)].filter(Boolean).join(" · ")}</span>
        <span className="ck-rows">{"Rows →"}</span>
      </button>
    );
  };
  const alertSpend = (c: PlCheck) => { const v = usdSum(c, c.rows.filter(isFlagged), "est_alert_usd_list"); return c.priced && v > 0 ? `${usd0(v)} spend` : null; };

  return (
    <div>
      <Tiles>
        <PlTile c={fail} open={open("sf_task_failures")} label="Task runs failed" make={(c) => {
          if (runs <= 0) return null;
          const now = c.rows.filter(failingNow).length;
          const n = counts(c, "tasks");
          return {
            headline: fmtShare(pctOf(failed, runs)), unit: "of runs",
            base: `${fmtInt(failed)} of ${fmtInt(runs)} runs · ${fmtInt(n.flagged)}${ofPop(n)} · ${fmtInt(now)} failing now`,
            cause: topErr ? `err ${topErr[0]} is ${fmtShare(pctOf(topErr[1], failed))} of failed runs.` : undefined,
            status: now > 0 ? "critical" : tileStatus(c.rows),
          };
        }} />
        <PlTile c={silent} open={open("sf_task_silent_failures")} label="Failing with no one told" make={(c) => {
          const n = counts(c, "root tasks");
          const flagged = c.rows.filter(isFlagged);
          const by = new Map<string, number>();
          flagged.forEach((r) => String(r.finding || "").split(/[,;|]/).map((x) => x.trim()).filter(Boolean).forEach((k) => by.set(k, (by.get(k) || 0) + 1)));
          const top = [...by.entries()].sort((a, b) => b[1] - a[1])[0];
          const pct = n.population ? pctOf(n.flagged, n.population) : null;
          return {
            headline: pct != null ? fmtShare(pct) : fmtInt(n.flagged), unit: pct != null ? `of ${n.noun}` : ofPop(n),
            base: `${fmtInt(n.flagged)}${ofPop(n)}${top ? ` · ${taskCause(top[0])}: ${fmtInt(top[1])}` : ""}`,
            cause: "Set ERROR_INTEGRATION on the root task, or add a finalizer that alerts.",
            status: tileStatus(flagged),
          };
        }} />
        <PlTile c={off} open={open("sf_task_alerts_silenced")} label="Alerts that fail or are off" make={(c) => {
          const n = counts(c, "alerts");
          const nf = !alerts.loading && !alerts.note ? counts(alerts, "alerts") : null;
          const spent = alertSpend(alerts);
          return {
            headline: fmtInt(n.flagged), unit: `${ofPop(n).trim()} switched off or stopped`,
            base: [nf ? `${fmtInt(nf.flagged)}${ofPop(nf)} fail when they run` : `failing alerts: ${alerts.note ? alerts.note.replace(/^– /, "") : "…"}`,
              `${fmtInt(n.flagged)}${ofPop(n)} off`].join(" · "),
            cause: spent ? `The failing ones spent ${spent.replace(/ spend$/, "")} to fail: context, not waste.` : undefined,
            status: worseStatus(tileStatus(c.rows.filter(isFlagged)), alerts.rows.length ? tileStatus(alerts.rows.filter(isFlagged)) : "ok"),
          };
        }} />
        <PlTile c={fail} open={open("sf_task_failures")} label="Broken now" make={(c) => {
          if (!c.rows.length) return null;
          // Older exports lack the streak column: say so rather than read clean.
          if (!c.rows.some((r) => r.consecutive_failures !== undefined)) return { headline: null, missingReason: "not in this export: run the export again", status: "not_assessed" };
          // Failed since its last success in the window: still broken at export time.
          const broken = c.rows.filter(failingNow)
            .sort((a, b) => numOrZero(b.consecutive_failures) - numOrZero(a.consecutive_failures));
          const n = counts(c, "tasks");
          const pop = Math.max(n.population ?? c.rows.length, broken.length);
          const top = broken[0];
          return {
            headline: fmtInt(broken.length), unit: `of ${fmtInt(pop)} tasks`,
            base: "failed every run since their last success",
            cause: top ? `Longest: ${taskLabel(top, p.dims)}, ${fmtInt(top.consecutive_failures)} in a row.` : "Every task's latest run succeeded.",
            status: !broken.length ? "ok" : broken.some((r) => rowStatus(r) === "CRITICAL") ? "critical" : "warn",
          };
        }} />
      </Tiles>
      {hasRunDays && (
        <ChartCard title="Runs, by task and day" subtitle="tasks that failed or ran slow · bars on top = failed runs per day · click a task for its panel" onOpenCheck={open("sf_task_runs_daily")} takeaway={null}>
          <TaskRunGrid load={runDays} meta={p.meta} filters={p.filters}
            onTask={(t) => openTask({ task_full_name: t.name, task_id: t.id })} />
        </ChartCard>
      )}
      <Grid>
        {!hasRunDays && <PlCard c={fail} open={open("sf_task_failures")} title="Failure rate, by task" subtitle="failed runs of all runs · dot = the task's status · click a task for its rows">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r.failed_runs) > 0).map((r) => {
              const pct = pctOf(numOrZero(r.failed_runs), numOrZero(r.runs)) ?? 0;
              return {
                key: `${r.account_id}|${r.task_full_name}`, name: taskLabel(r, p.dims), value: pct, row: r,
                status: failingNow(r) ? "CRITICAL" : isFlagged(r) ? "WARN" : "OK",
                valueText: `${fmtShare(pct)} failed · ${fmtInt(r.failed_runs)} of ${fmtInt(r.runs)}${r.last_error_code ? ` · err ${r.last_error_code}` : ""}`,
              };
            });
            if (!items.length) return null;
            return <StatusBars items={items} max={100} n={10} unitLabel="of runs failed" ariaLabel="Failure rate by task" onBarClick={(it) => drawerFor(it.row)} />;
          }}
        </PlCard>}
        <PlCard c={fail} open={open("sf_task_failures")} title="Why runs fail" subtitle={`${fmtInt(failed)} failed runs, by each task's last error code, then by the compute they ran on`}>
          {(c) => {
            const a = failedSplit(c.rows, (r) => (r.last_error_code ? `err ${r.last_error_code}` : null), "Failed runs by error code");
            const b = failedSplit(c.rows, (r) => computeWord(r), "Failed runs by compute");
            if (!a && !b) return null;
            return <div className="pl-stack">{a}{b}</div>;
          }}
        </PlCard>
        <PlCard c={silent} open={open("sf_task_silent_failures")} title="Silent failures, by cause" subtitle={silentN ? `${fmtInt(silentN.flagged)}${ofPop(silentN)} fail and tell no one · why` : "root tasks that fail and tell no one · why"}>
          {(c) => {
            const rows = c.rows.filter(isFlagged);
            return (
              <div>
                {rows.length ? <CauseSplitBar rows={rows} column="finding" noun="tasks" labelFor={taskCause} onCauseClick={() => DrawerBus.open({ id: "sf_task_silent_failures" })} />
                  : <Note>Nothing flagged in this window.</Note>}
                <div className="ck-list pl-alert-checks">
                  {alertCheck(alerts, "Alerts that fail, and what alerts cost", alertSpend)}
                  {alertCheck(off, "Alerts that were switched off or stopped evaluating", () => null)}
                </div>
              </div>
            );
          }}
        </PlCard>
      </Grid>
    </div>
  );
};
(PlTasksFailures as any).ownsLede = true;

const START_CAUSE: Record<string, string> = { warehouse_busy: "queued behind other work", warehouse_resume: "warehouse resuming", scheduler: "scheduler late" };

export function PlTasksCost(p: ApPageProps) {
  const d = usePlData(p, ["sf_task_cost", "sf_task_noop_runs", "sf_task_skipped_overlaps", "sf_task_duration_regression", "sf_task_start_delay", "sf_task_run_times"]);
  const open = opener(p);
  const cost = d.sf_task_cost, noop = d.sf_task_noop_runs, skip = d.sf_task_skipped_overlaps, slow = d.sf_task_duration_regression;
  const late = d.sf_task_start_delay, rt = d.sf_task_run_times;
  const slower = (rows: Row[]) => rows.filter((r) => isFlagged(r) && numOrZero(r.p50_growth_pct) > 0);
  const win = `${fmtInt(p.filters.window)} d`;

  // The figures the tiles and the lede share.
  const judged = sum(noop.rows, "noop_runs") + sum(noop.rows, "changed_runs");
  const noopFlagged = noop.rows.filter(isFlagged);
  const sched = sum(skip.rows, "scheduled_runs");
  const slowList = slower(slow.rows).sort((a, b) => numOrZero(b.p50_growth_pct) - numOrZero(a.p50_growth_pct));
  const slowN = !slow.loading && !slow.note ? counts(slow, "tasks") : null;
  const lede = cost.loading || noop.loading || slow.loading ? "…" : [
    slowN && slowList.length ? `${fmtInt(slowList.length)}${ofPop(slowN)} got slower than the ${win} before` : null,
    judged > 0 ? `${fmtShare(pctOf(sum(noop.rows, "noop_runs"), judged))} of judged runs changed nothing` : null,
  ].filter(Boolean).join("; ").replace(/^./, (x) => x.toUpperCase()) || null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede ? (lede === "…" ? lede : `${lede}.`) : null); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div>
      <Tiles>
        <PlTile c={cost} open={open("sf_task_cost")} label="Task spend" make={(c) => {
          if (!c.priced) return { headline: null, missingReason: "No $/credit price in this export." };
          const now = usdSum(c, c.rows, "est_task_usd_list"), prev = usdSum(c, c.rows, "est_prev_usd_list");
          const m = c.f && c.f.money;
          const total = m && m.unit !== "currency" && Number.isFinite(Number(m.usd)) ? Number(m.usd) : now;
          const ch = prev > 0 ? ((now - prev) / prev) * 100 : null;
          const top = [...c.rows].sort((a, b) => numOrZero(b.est_task_usd_list) - numOrZero(a.est_task_usd_list))[0];
          const n = counts(c, "tasks");
          return {
            headline: usd0(total), pill: <StatusPill kind="neutral" />,
            base: [ch === null ? null : `${signedPct(ch)} vs previous ${win}`, `${fmtInt(n.population ?? c.rows.length)} ${n.noun}`].filter(Boolean).join(" · "),
            cause: top ? `Most: ${taskLabel(top, p.dims)}, ${usd0(usd(c, top, "est_task_usd_list"))}${num(top.change_pct) !== null ? `, ${signedPct(num(top.change_pct))}` : ""}.` : undefined,
            status: "neutral",
          };
        }} />
        <PlTile c={noop} open={open("sf_task_noop_runs")} label="Runs that changed nothing" make={(c) => {
          if (judged <= 0) return null;
          const n = counts(c, "tasks");
          const withWhen = noopFlagged.filter((r) => numOrZero(r.runs_with_when) > 0).length;
          const waste = c.priced ? usdSum(c, noopFlagged, "est_wasted_usd_list") : 0;
          return {
            headline: fmtShare(pctOf(sum(c.rows, "noop_runs"), judged)), unit: "of runs",
            base: [`${fmtInt(n.flagged)}${ofPop(n)}`, noopFlagged.length ? `${fmtInt(withWhen)} of the ${fmtInt(noopFlagged.length)} have a WHEN` : null,
              waste > 0 ? `${usd0(waste)} possible waste` : null].filter(Boolean).join(" · "),
            cause: "A WHEN SYSTEM$STREAM_HAS_DATA skips the run without waking the warehouse.",
            status: tileStatus(noopFlagged),
          };
        }} />
        <PlTile c={skip} open={open("sf_task_skipped_overlaps")} label="Scheduled runs skipped" make={(c) => {
          if (sched <= 0) return null;
          const n = counts(c, "tasks");
          const worst = [...c.rows].sort((a, b) => numOrZero(b.p90_duration_to_interval_pct) - numOrZero(a.p90_duration_to_interval_pct))[0];
          return {
            headline: fmtShare(pctOf(sum(c.rows, "overlap_skips") + sum(c.rows, "condition_skips"), sched)), unit: "of scheduled runs",
            base: [`${fmtInt(n.flagged)}${ofPop(n)}`, worst && num(worst.p90_duration_to_interval_pct) !== null ? `worst runs for ${pctText(worst.p90_duration_to_interval_pct)} of its schedule` : null].filter(Boolean).join(" · "),
            cause: "The previous run was still going. Make the task faster, or widen the schedule.",
            status: tileStatus(c.rows.filter(isFlagged)),
          };
        }} />
        <PlTile c={slow} open={open("sf_task_duration_regression")} label="Tasks running slower" make={(c) => {
          const n = counts(c, "tasks");
          if (!slowList.length) return { headline: "0", unit: ofPop(n), cause: "No task got slower in this window.", status: "ok" };
          return {
            headline: fmtInt(slowList.length), unit: ofPop(n).trim(),
            base: `median run vs previous ${win} · slowest ${signedPct(num(slowList[0].p50_growth_pct))}`,
            cause: `${taskLabel(slowList[0], p.dims)}: ${dur(slowList[0].prev_p50_duration_seconds)} → ${dur(slowList[0].p50_duration_seconds)}`,
            status: tileStatus(slowList),
          };
        }} />
        <PlTile c={rt} open={open("sf_task_run_times")} label="Cost of failed task runs" make={(c) => failedCostTile(c, p.dims)} />
      </Tiles>
      <Grid>
        <PlCard c={slow} open={open("sf_task_duration_regression")} title="Slower tasks · earlier → now" subtitle={`median run time, previous ${win} → last ${win} · ${slowN ? `${fmtInt(slowList.length)}${ofPop(slowN)}` : "flagged tasks"}`}>
          {() => {
            if (!slowList.length) return <Note>No task got slower in this window.</Note>;
            const shown = slowList.slice(0, 8);
            const rows: DumbbellRow[] = shown.map((r) => ({
              key: `${r.account_id}|${r.task_full_name}`, name: taskName(p.dims as DimMaps, r.task_full_name || r.task_name), id: r.task_id,
              before: numOrZero(r.prev_p50_duration_seconds), after: numOrZero(r.p50_duration_seconds),
              valueText: `${signedPct(num(r.p50_growth_pct))} ${dur(r.prev_p50_duration_seconds)} → ${dur(r.p50_duration_seconds)}`,
            }));
            return (
              <div>
                <div className="b2-legend"><span className="b2-legend-item"><span className="b2-sw b2-ring" />earlier</span><span className="b2-legend-item"><span className="b2-sw b2-ring now" />now</span></div>
                <DumbbellRows rows={rows} />
                {slowList.length > shown.length && <div className="blk-more">{`+${fmtInt(slowList.length - shown.length)} more not shown`}</div>}
              </div>
            );
          }}
        </PlCard>
        <PlCard c={cost} open={open("sf_task_cost")} title="Task cost" subtitle={`by task · change vs the previous ${win} · context, not waste`}>
          {(c) => {
            const col = c.priced ? "est_task_usd_list" : "credits";
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r[col]) > 0).map((r) => {
              const v = c.priced ? usd(c, r, col) : numOrZero(r[col]);
              const ch = num(r.change_pct);
              return {
                key: `${r.account_id}|${r.task_full_name}`, name: taskLabel(r, p.dims), value: v, row: r, status: rowStatus(r),
                valueText: `${c.priced ? usd0(v) : `${fmtInt(v)} credits`}${ch !== null ? ` · ${signedPct(ch)}` : ""}`,
              };
            });
            return items.length ? <StatusBars items={items} n={8} ariaLabel="Task cost by task" onBarClick={(it) => openTask(it.row)} /> : null;
          }}
        </PlCard>
      </Grid>
      <Grid>
        <PlCard c={noop} open={open("sf_task_noop_runs")} title="Runs that changed nothing" subtitle={`${fmtInt(judged)} judged runs · runs that changed no rows`}>
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r.noop_runs) > 0).map((r) => {
              const judged = numOrZero(r.noop_runs) + numOrZero(r.changed_runs);
              const pct = pctOf(numOrZero(r.noop_runs), judged) ?? 0;
              return {
                key: `${r.account_id}|${r.task_full_name}`, name: taskLabel(r, p.dims), value: pct, row: r, status: rowStatus(r),
                valueText: `${fmtShare(pct)} · ${fmtInt(r.noop_runs)} of ${fmtInt(judged)}${numOrZero(r.runs_with_when) > 0 ? " · has WHEN" : " · no WHEN"}`,
              };
            });
            return items.length ? <StatusBars items={items} max={100} n={8} ariaLabel="No-op runs by task" onBarClick={(it) => openTask(it.row)} /> : null;
          }}
        </PlCard>
        <PlCard c={skip} open={open("sf_task_skipped_overlaps")} title="Skipped runs" subtitle="skipped of scheduled runs · p90 run time vs schedule">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r.overlap_skips) + numOrZero(r.condition_skips) > 0).map((r) => {
              const pct = pctOf(numOrZero(r.overlap_skips) + numOrZero(r.condition_skips), numOrZero(r.scheduled_runs)) ?? numOrZero(r.skip_pct);
              const ratio = num(r.p90_duration_to_interval_pct);
              return {
                key: `${r.account_id}|${r.task_full_name}`, name: taskLabel(r, p.dims), value: pct, row: r, status: rowStatus(r),
                valueText: `${fmtShare(pct)} skipped${ratio !== null ? ` · run time ${fmtShare(ratio)} of schedule` : ""}`,
              };
            });
            return items.length ? <StatusBars items={items} max={100} n={8} ariaLabel="Skipped runs by task" onBarClick={(it) => openTask(it.row)} /> : null;
          }}
        </PlCard>
      </Grid>
      <PlCard c={rt} open={open("sf_task_run_times")} title="Tasks by run time" subtitle={`completed runs in the last ${win} · Snowflake's own tasks left out · click a task for its panel`}>
        {(c) => <TaskRunTimes c={c} dims={p.dims} />}
      </PlCard>
      <PlCard c={late} open={open("sf_task_start_delay")} title="Tasks that start late" subtitle="p90 wait from the scheduled time until the statement runs · what held it back">
        {(c) => {
          const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r.late_runs) > 0).map((r) => ({
            key: `${r.account_id}|${r.task_full_name}`, name: taskLabel(r, p.dims), value: numOrZero(r.p90_delay_s), row: r, status: rowStatus(r),
            valueText: [`p90 ${dur(r.p90_delay_s)}`, `${pctText(r.late_pct)} of runs late`, START_CAUSE[String(r.main_cause)] || null].filter(Boolean).join(" · "),
          }));
          return items.length ? <StatusBars items={items} n={8} ariaLabel="Late task starts by task" onBarClick={(it) => openTask(it.row)} />
            : <Note>{`No task started late in the last ${fmtInt(p.filters.window)} days.`}</Note>;
        }}
      </PlCard>
    </div>
  );
};
/** Failed-run credits, a lower bound from serverless billing rows; context, never part of task spend. */
function failedCostTile(c: PlCheck, dims: Dims): Partial<IssueTileProps> | null {
  if (!c.rows.length) return null;
  const failing = c.rows.filter((r) => numOrZero(r.failed_runs) > 0);
  const n = counts(c, "tasks");
  if (!failing.length) return { headline: "0", unit: "failed runs", base: `0${ofPop(n)} had a failed run`, cause: "No task run failed in this window.", status: "ok" };
  const costed = failing.filter((r) => num(r.failed_run_credits_lower_bound) !== null);
  const notes = new Map<string, number>();
  failing.filter((r) => num(r.failed_run_credits_lower_bound) === null).forEach((r) => { const k = String(r.failed_cost_note || "no cost for this task"); notes.set(k, (notes.get(k) || 0) + 1); });
  const topNote = [...notes.entries()].sort((a, b) => b[1] - a[1])[0];
  if (!costed.length) return { headline: null, missingReason: `${fmtInt(failing.length)} failing ${failing.length === 1 ? "task" : "tasks"} · ${topNote ? topNote[0] : "no cost"}` };
  const credits = sum(costed, "failed_run_credits_lower_bound");
  const usdV = c.priced ? usdSum(c, costed, "est_failed_usd_list") : null;
  const top = [...costed].sort((a, b) => numOrZero(b.failed_run_credits_lower_bound) - numOrZero(a.failed_run_credits_lower_bound))[0];
  const uncosted = failing.length - costed.length;
  return {
    headline: `at least ${creditsText(credits)}`, pill: <KindChip>Context</KindChip>, status: "neutral",
    base: [`${fmtInt(costed.length)} of ${fmtInt(failing.length)} failing tasks costed`, usdV !== null ? `≈ ${usd0(usdV)}${c.disc > 0 ? "" : " list"}` : "$ –: no price in this export"].join(" · "),
    cause: uncosted > 0 && topNote ? `${fmtInt(uncosted)} not costed: ${topNote[0]}.` : top ? `Most: ${taskLabel(top, dims)}.` : undefined,
  };
}
/** Credits with enough decimals for small lower bounds. */
const creditsText = (v: number) => fmtCredits(v, v >= 10 ? 0 : v >= 1 ? 1 : 3);

type RtSort = "total_run_s" | "avg_run_s" | "p95_run_s" | "max_run_s" | "runs";
const RT_SORTS: { key: RtSort; label: string }[] = [
  { key: "total_run_s", label: "Total time" }, { key: "avg_run_s", label: "Avg" }, { key: "p95_run_s", label: "p95" },
  { key: "max_run_s", label: "Max" }, { key: "runs", label: "Runs" },
];

/** Every task's run time, sortable, 20 or 50 rows; a row opens the task's panel. */
function TaskRunTimes({ c, dims }: { c: PlCheck; dims: Dims }) {
  const [sortBy, setSortBy] = React.useState<RtSort>("total_run_s");
  const [n, setN] = React.useState(20);
  const rows = [...c.rows].sort((a, b) => (num(b[sortBy]) ?? -1) - (num(a[sortBy]) ?? -1));
  const head = (key: RtSort, label: string) => (sortBy === key ? `${label} ↓` : label);
  const csvCols: CsvColumn<Row>[] = [
    { label: "task", value: (r) => taskLabel(r, dims) }, { label: "task_full_name", value: (r) => r.task_full_name },
    { label: "compute", value: (r) => computeWord(r) }, { label: "runs", value: (r) => r.runs }, { label: "succeeded_runs", value: (r) => r.succeeded_runs },
    { label: "failed_runs", value: (r) => r.failed_runs }, { label: "cancelled_runs", value: (r) => r.cancelled_runs }, { label: "runs_with_retry", value: (r) => r.runs_with_retry },
    { label: "avg_run_s", value: (r) => r.avg_run_s }, { label: "p95_run_s", value: (r) => r.p95_run_s }, { label: "max_run_s", value: (r) => r.max_run_s },
    { label: "total_run_s", value: (r) => r.total_run_s }, { label: "failed_run_s", value: (r) => r.failed_run_s },
    { label: "failed_run_credits_lower_bound", value: (r) => r.failed_run_credits_lower_bound },
    // No price: blank, never 0.
    { label: "est_failed_usd_list", value: (r) => (c.priced && num(r.est_failed_usd_list) !== null ? num(r.est_failed_usd_list) : "") },
    { label: "failed_cost_note", value: (r) => r.failed_cost_note }, { label: "last_run_time", value: (r) => r.last_run_time },
    { label: "last_state", value: (r) => r.last_state }, { label: "status", value: (r) => r.status },
  ];
  // Rows are separate grids, so widths are fixed; the sorted metric sits in column 2 so phone width keeps it.
  const NUM = "minmax(56px, 0.6fr)";
  const metric = (key: RtSort, label: string, fmt: (r: Row) => React.ReactNode) => ({ key, col: { label: head(key, label), num: true, width: NUM }, cell: fmt });
  const metrics = [
    metric("runs", "Runs", (r) => fmtInt(r.runs)), metric("avg_run_s", "Avg", (r) => dur(r.avg_run_s)), metric("p95_run_s", "p95", (r) => dur(r.p95_run_s)),
    metric("max_run_s", "Max", (r) => dur(r.max_run_s)), metric("total_run_s", "Total", (r) => dur(r.total_run_s)),
  ];
  const failedCell = (r: Row) => (numOrZero(r.failed_runs) > 0 || numOrZero(r.runs_with_retry) > 0
    ? chip(`${fmtInt(r.failed_runs)}${numOrZero(r.runs_with_retry) > 0 ? ` · ${fmtInt(r.runs_with_retry)} retried` : ""}`, "WARN") : fmtInt(r.failed_runs));
  const cols = [
    ...metrics.filter((m) => m.key === sortBy),
    { key: "failed", col: { label: "Failed", num: true, width: "minmax(120px, 0.9fr)" }, cell: failedCell },
    ...metrics.filter((m) => m.key !== sortBy),
    { key: "compute", col: { label: "Compute", width: "minmax(80px, 1fr)" }, cell: (r: Row) => computeWord(r) },
  ];
  return (
    <div>
      <div className="pl-rt-bar">
        <div className="ws-actions" role="group" aria-label="Sort tasks by">
          {RT_SORTS.map((o) => <button key={o.key} type="button" className={sortBy === o.key ? "on" : ""} aria-pressed={sortBy === o.key} onClick={() => setSortBy(o.key)}>{o.label}</button>)}
        </div>
        <div className="pl-rt-right">
          <div className="ws-actions" role="group" aria-label="Rows shown">
            {[20, 50].map((k) => <button key={k} type="button" className={n === k ? "on" : ""} aria-pressed={n === k} onClick={() => setN(k)}>{k}</button>)}
          </div>
          <CsvButton fileName="tasks_by_run_time" columns={csvCols} rows={rows} />
        </div>
      </div>
      <DrillTable aria="Tasks by run time" n={n}
        cols={[{ label: "Task" }, ...cols.map((x) => x.col)]}
        rows={rows.map((r) => ({
          key: `${r.account_id}|${r.task_full_name}`, status: rowStatus(r), onOpen: () => openTask(r),
          title: r.run_reason ? String(r.run_reason) : undefined,
          cells: [taskLabel(r, dims), ...cols.map((x) => x.cell(r))],
        }))} />
    </div>
  );
}

PlTasksFailures.ownsTiles = true;
PlTasksCost.ownsTiles = true;
(PlTasksCost as any).ownsLede = true;

export function PlTasksHygiene(p: ApPageProps) {
  const d = usePlData(p, ["sf_task_suspended_or_stale", "sf_task_ownership_orphans"]);
  const open = opener(p);
  const stale = d.sf_task_suspended_or_stale, orph = d.sf_task_ownership_orphans;
  // Task settings come from the Failures tab's root-task check and the Cost tab's skip check: context only.
  const roots = useOtherCheck(p, "sf_task_silent_failures");
  const skips = useOtherCheck(p, "sf_task_skipped_overlaps");
  const allTasks = orph.rows.length ? sum(orph.rows, "tasks") : null;
  const staleFlag = stale.rows.filter(isFlagged);
  const staleBase = allTasks && allTasks >= staleFlag.length ? allTasks : counts(stale, "tasks").population;
  const gone = sum(orph.rows, "tasks_owner_role_missing");
  const rootRows = roots.rows || [];
  const overlap = rootRows.filter((r) => /ALLOW/i.test(String(r.overlap_policy || "")));
  const noInt = rootRows.filter((r) => falsy(r.has_error_integration));
  const intSet = rootRows.filter((r) => truthy(r.has_error_integration)).length;
  const failingNoInt = noInt.filter((r) => numOrZero(r.failed_runs_in_graph) > 0);
  const p90Of = new Map((skips.rows || []).map((r) => [`${r.account_id}|${r.task_full_name}`, num(r.p90_duration_to_interval_pct)]));

  const lede = stale.loading ? "…" : staleBase
    ? `${fmtInt(staleFlag.length)} of ${fmtInt(staleBase)} tasks are suspended or no longer run${gone > 0 ? `, and ${fmtInt(gone)} belong to a role that no longer exists` : ""}.`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const staleRows = [...staleFlag].sort((a, b) => (num(b.days_suspended) ?? num(b.stale_days) ?? 0) - (num(a.days_suspended) ?? num(a.stale_days) ?? 0));
  const otherTile = (label: string, src: ReturnType<typeof useOtherCheck>, make: () => Partial<IssueTileProps>, go: () => void) => {
    if (src.loading) return <IssueTile label={label} headline={null} loading />;
    if (!src.rows) return <IssueTile label={label} headline={null} status="not_assessed" missingReason={src.why || "not in this export"} onOpen={go} openLabel="Failures →" />;
    if (!src.rows.length) return <IssueTile label={label} headline={null} missingReason="No root task in this window." onOpen={go} openLabel="Failures →" />;
    return <IssueTile label={label} headline={null} pill={<KindChip>Context</KindChip>} status="neutral" onOpen={go} {...make()} />;
  };
  const toFailures = () => p.goTo({ tab: p.area, subtab: "failures" });
  return (
    <div className="sx-page">
      <Tiles4>
        <PlTile c={stale} open={scrollTo("th-why")} label="Suspended or not running" make={() => {
          const by = new Map<string, number>();
          staleFlag.forEach((r) => { const k = String(r.finding || ""); if (k) by.set(k, (by.get(k) || 0) + 1); });
          const top = [...by.entries()].sort((a, b) => b[1] - a[1])[0];
          return {
            headline: staleBase ? fmtShare(pctOf(staleFlag.length, staleBase)) : fmtInt(staleFlag.length), unit: staleBase ? "of tasks" : "tasks",
            flagged: staleFlag.length, population: staleBase, noun: "tasks",
            cause: top ? `${taskCause(top[0])} leads · ${fmtInt(top[1])} ${top[1] === 1 ? "task" : "tasks"}` : undefined,
            status: tileStatus(staleFlag), openLabel: "By cause ↓",
          };
        }} />
        <PlTile c={orph} open={open("sf_task_ownership_orphans")} label="Owner role dropped" make={(c) => {
          const tasks = sum(c.rows, "tasks");
          if (tasks <= 0) return null;
          return {
            headline: fmtShare(pctOf(gone, tasks)), unit: "of tasks", flagged: gone, population: tasks, noun: "tasks",
            cause: "Nobody can ALTER or RESUME them until ownership moves.", status: gone > 0 ? tileStatus(c.rows) : "ok",
          };
        }} />
        {otherTile("Overlapping runs allowed", roots, () => ({
          headline: fmtInt(overlap.length), unit: `of ${fmtInt(rootRows.length)} root tasks`,
          base: "ALLOW_OVERLAPPING_EXECUTION = TRUE", cause: overlap.length ? "Two runs can write the same table at once." : "No root task allows overlap.",
          openLabel: "Which ↓",
        }), scrollTo("th-settings"))}
        {otherTile("No error integration", roots, () => ({
          headline: fmtInt(noInt.length), unit: `of ${fmtInt(rootRows.length)} root tasks`,
          base: `${fmtInt(intSet)} have ERROR_INTEGRATION set · ${fmtInt(failingNoInt.length)} failing without one`,
          cause: "A failure lands in TASK_HISTORY and nowhere else.", openLabel: "Failures →",
        }), toFailures)}
      </Tiles4>
      <Grid>
        <div id="th-why">
          <PlCard c={stale} open={open("sf_task_suspended_or_stale")} title="Why tasks are not running" subtitle={`${fmtInt(staleFlag.length)} flagged tasks, by cause`}>
            {() => staleFlag.length ? <CauseSplitBar rows={staleFlag} column="finding" noun="tasks" labelFor={taskCause} onCauseClick={() => open("sf_task_suspended_or_stale")()} /> : null}
          </PlCard>
        </div>
        <PlCard c={stale} open={open("sf_task_suspended_or_stale")} title="Days suspended or idle" subtitle="flagged tasks · click a task for its panel">
          {() => {
            const items: StatusBarItem[] = staleRows.map((r) => {
              const days = num(r.days_suspended) ?? num(r.stale_days) ?? 0;
              return {
                key: `${r.account_id}|${r.task_full_name}`, name: taskLabel(r, p.dims), value: days, row: r, status: rowStatus(r),
                valueText: `${fmtInt(days)} d · ${taskCause(String(r.finding || ""))}`,
              };
            });
            return items.length ? <StatusBars items={items} n={10} ariaLabel="Days suspended or idle by task" onBarClick={(it) => openTask(it.row)} /> : null;
          }}
        </PlCard>
      </Grid>
      <Grid>
        <PlCard c={stale} open={open("sf_task_suspended_or_stale")} title="Stopped tasks" subtitle="snapshot at export · state from SHOW TASKS, last run from TASK_HISTORY · click a row">
          {() => (
            <DrillTable aria="Stopped tasks" n={10} empty="Nothing flagged in this window."
              cols={[{ label: "Task" }, { label: "Owner", width: "minmax(80px, 1fr)" }, { label: "State", width: "auto" }, { label: "Last run", width: "auto" }, { label: "Why", width: "minmax(80px, auto)" }]}
              rows={staleRows.map((r) => ({
                key: `${r.account_id}|${r.task_full_name}`, status: rowStatus(r),
                onOpen: openRow("sf_task_suspended_or_stale", "task_full_name", r.task_full_name, taskLabel(r, p.dims)),
                cells: [taskLabel(r, p.dims), String(r.owner || "–"), String(r.state || "–").toLowerCase(),
                  r.last_run_time ? fmtDayShort(r.last_run_time) : "never in lookback",
                  chip(`${taskCause(String(r.finding || ""))}${num(r.days_suspended) != null ? ` · ${fmtInt(r.days_suspended)} d` : ""}`, rowStatus(r))],
              }))} />
          )}
        </PlCard>
        <div id="th-settings">
          <ChartCard title="Settings that bite later" subtitle="root tasks that allow overlapping runs · p90 run time as a share of the schedule · context, not scored here" onOpenCheck={toFailures} takeaway={null}>
            {roots.loading ? <Note>…</Note> : !roots.rows ? <Note>{`– ${roots.why || "not in this export"}`}</Note> : (
              <div className="pl-stack">
                {overlap.length ? <StatusBars n={8} ariaLabel="Root tasks that allow overlapping runs" max={Math.max(100, ...overlap.map((r) => p90Of.get(`${r.account_id}|${r.task_full_name}`) ?? 0))}
                  items={overlap.map((r) => {
                    const ratio = p90Of.get(`${r.account_id}|${r.task_full_name}`) ?? null;
                    return {
                      key: `${r.account_id}|${r.task_full_name}`, name: nameId(taskName(p.dims as DimMaps, r.task_full_name), r.task_id), value: ratio ?? 0, status: ratio != null && ratio > 100 ? "WARN" : "OK",
                      valueText: `${ratio != null ? `${fmtShare(ratio)} of schedule` : "no skip data"}${r.task_schedule ? ` · every ${String(r.task_schedule).toLowerCase()}` : ""}`,
                    };
                  })} /> : <Note>No root task allows overlapping runs.</Note>}
                {rootRows.length > 0 && <div>
                  <div className="pl-note chart-note-oneline">{`ERROR_INTEGRATION set · ${fmtInt(intSet)} of ${fmtInt(rootRows.length)} root tasks`}</div>
                  <StackedShareBar ariaLabel="Root tasks with an error integration" valueFmt={(v) => `${fmtInt(v)} tasks`}
                    segments={[{ key: "set", label: "set", value: intSet }, { key: "none", label: "not set", value: noInt.length, color: "var(--c-other)" }]} />
                </div>}
              </div>
            )}
          </ChartCard>
        </div>
      </Grid>
    </div>
  );
};
PlTasksHygiene.ownsTiles = true;
(PlTasksHygiene as any).ownsLede = true;

/** Days until a stream goes stale, around zero: past zero (already stale) red, inside a week amber. */
function StaleDays({ items }: { items: { key: string; name: string; days: number; note: string }[] }) {
  const [ref, W] = useChartWidth(560);
  if (!items.length) return <div ref={ref} />;
  const labelW = rowLabelWidth(W);
  const sorted = [...items].sort((a, b) => a.days - b.days).slice(0, 10);
  const maxAbs = Math.max(1, ...sorted.map((it) => Math.abs(it.days)));
  return (
    <div ref={ref} className="pl-stale" role="list" aria-label="Days until each stream goes stale">
      {sorted.map((it) => {
        const w = (Math.abs(it.days) / maxAbs) * 50;
        const tone = it.days < 0 ? "crit" : it.days < 7 ? "warn" : "ok";
        return (
          <div key={it.key} className="pl-stale-row" role="listitem" title={`${it.name}: ${it.note}`}>
            <span className="pl-stale-name" style={{ width: labelW }}>{truncateLeft(it.name, labelW - 8)}</span>
            <span className="pl-stale-track">
              <span className="pl-stale-axis" />
              <span className={`pl-stale-fill tone-${tone}`} style={it.days < 0 ? { right: "50%", width: `${w}%` } : { left: "50%", width: `${w}%` }} />
            </span>
            <span className="pl-stale-value">{it.note}</span>
          </div>
        );
      })}
      {items.length > sorted.length && <div className="blk-more">{`+${fmtInt(items.length - sorted.length)} more not shown`}</div>}
      <Note>Left of the line: already stale, changes lost. Right: days left.</Note>
    </div>
  );
}

export function PlTasksDynamic(p: ApPageProps) {
  const d = usePlData(p, ["sf_dt_refresh_failures_and_lag", "sf_stream_stale", "sf_stream_consumers", "sf_dt_unread_refresh_cost", "sf_dt_suspended_still_read",
    "sf_dt_downstream_orphans", "sf_dt_lag_keeps_warehouse_awake"]);
  const orph = d.sf_dt_downstream_orphans, awake = d.sf_dt_lag_keeps_warehouse_awake;
  const open = opener(p);
  const dt = d.sf_dt_refresh_failures_and_lag, st = d.sf_stream_stale, cons = d.sf_stream_consumers;
  const unread = d.sf_dt_unread_refresh_cost, susp = d.sf_dt_suspended_still_read;
  const lagRatio = (r: Row) => {
    const t = num(r.target_lag_seconds), o = num(r.p90_observed_lag_seconds);
    return t && t > 0 && o !== null ? o / t : null;
  };
  const isStale = (r: Row) => r.is_stale === true || String(r.is_stale).toLowerCase() === "true" || (num(r.days_to_stale) ?? 1) < 0;
  const dtName = (r: Row) => nameId(r.dt_full_name || r.dt_name, r.dt_id);

  // The figures the tiles and the lede share.
  const withTarget = dt.rows.filter((r) => lagRatio(r) !== null);
  const over = withTarget.filter((r) => (lagRatio(r) as number) > 1).sort((a, b) => (lagRatio(b) as number) - (lagRatio(a) as number));
  const staleNow = st.rows.filter(isStale).length;
  const unreadFlag = unread.rows.filter(isFlagged);
  const lede = dt.loading || st.loading ? "…" : [
    withTarget.length ? `${fmtInt(over.length)} of ${fmtInt(withTarget.length)} dynamic tables run behind their target lag` : null,
    st.rows.length ? `${fmtInt(staleNow)} of ${fmtInt(st.rows.length)} streams have gone stale` : null,
  ].filter(Boolean).join("; ") || null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede ? (lede === "…" ? lede : `${lede}.`) : null); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="sx-page">
      <Tiles4>
        <PlTile c={dt} open={scrollTo("dt-lag")} label="Dynamic tables behind target" make={(c) => {
          if (!withTarget.length) return null;
          return {
            headline: fmtShare(pctOf(over.length, withTarget.length)), unit: "of dynamic tables",
            flagged: over.length, population: withTarget.length, noun: "with a target lag",
            cause: over.length ? `worst ${dtName(over[0])}: p90 ${(lagRatio(over[0]) as number).toFixed(1)}× target` : "all within target lag at p90",
            status: tileStatus(c.rows.filter(isFlagged)), openLabel: "By table ↓",
          };
        }} />
        <PlTile c={st} open={scrollTo("dt-stale")} label="Streams stale" make={(c) => {
          if (!c.rows.length) return null;
          const soon = c.rows.filter((r) => !isStale(r) && (num(r.days_to_stale) ?? 99) < 7).length;
          const consN = sum(cons.rows, "consumer_count"), consOff = sum(cons.rows, "suspended_consumers");
          return {
            headline: fmtInt(staleNow), unit: `of ${fmtInt(c.rows.length)} streams`,
            base: [`${fmtInt(soon)} more go stale within 7 d`, !cons.loading && !cons.note && consN > 0 ? `${fmtInt(consOff)} of ${fmtInt(consN)} consumers suspended` : null].filter(Boolean).join(" · "),
            cause: staleNow ? "A stale stream has lost its changes; the consumer must reload in full." : undefined,
            status: staleNow ? "critical" : soon ? "warn" : "ok", openLabel: "Days left ↓",
          };
        }} />
        <PlTile c={unread} open={unreadFlag[0] ? openRow("sf_dt_unread_refresh_cost", "dt_full_name", unreadFlag[0].dt_full_name, dtName(unreadFlag[0])) : open("sf_dt_unread_refresh_cost")} label="Refreshed for nobody" make={(c) => {
          if (!c.rows.length) return null;
          const n = counts(c, "dynamic tables");
          const waste = c.priced ? usdSum(c, unreadFlag, "est_wasted_usd_list") : 0;
          return {
            headline: fmtInt(n.flagged), unit: ofPop(n).trim(),
            base: [`0 reads in ${fmtInt(p.filters.window)} d`, waste > 0 ? `${usd0(waste)} possible waste` : null].filter(Boolean).join(" · "),
            cause: unreadFlag[0] ? `${dtName(unreadFlag[0])}: ${fmtInt(unreadFlag[0].refreshes)} refreshes, no reader.` : "Every refreshed table was read.",
            status: tileStatus(unreadFlag), openLabel: unreadFlag.length ? "Open the worst →" : "Open check →",
          };
        }} />
        <PlTile c={susp} open={open("sf_dt_suspended_still_read")} label="Suspended but still read" make={(c) => {
          const fl = c.rows.filter(isFlagged);
          const n = counts(c, "dynamic tables");
          const oldest = fl.map((r) => (r.suspended_since ? String(r.suspended_since).slice(0, 10) : null)).filter((x): x is string => !!x).sort()[0];
          return {
            headline: fmtInt(n.flagged), unit: ofPop(n).trim(),
            base: [`${fmtInt(sum(fl, "read_queries"))} reads since they stopped`, oldest ? `oldest suspended ${fmtDayShort(oldest)}` : null].filter(Boolean).join(" · "),
            cause: fl.length ? "Readers get rows frozen on the day the refresh stopped." : undefined,
            status: tileStatus(fl), openLabel: "Refresh state ↓",
          };
        }} />
      </Tiles4>
      <Grid>
        <div id="dt-lag">
        <PlCard c={dt} open={open("sf_dt_refresh_failures_and_lag")} title="Lag vs target, by dynamic table" subtitle="p90 observed lag ÷ target lag · 1× = on target">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => lagRatio(r) !== null).map((r) => {
              const x = lagRatio(r) as number;
              return {
                key: `${r.account_id}|${r.dt_full_name}`, name: dtName(r), value: x, status: rowStatus(r), dtFull: r.dt_full_name,
                valueText: `${x.toFixed(x >= 10 ? 0 : 1)}× (${dur(r.p90_observed_lag_seconds)} vs ${dur(r.target_lag_seconds)})`,
              };
            });
            return items.length ? <StatusBars items={items} n={10} ariaLabel="Observed vs target lag by dynamic table"
              onBarClick={(it) => DrawerBus.open({ id: "sf_dt_refresh_failures_and_lag", col: "dt_full_name", val: String(it.dtFull), label: it.name })} /> : null;
          }}
        </PlCard>
        </div>
        <div id="dt-stale">
        <PlCard c={st} open={open("sf_stream_stale")} title="Days until a stream goes stale" subtitle="with the state of its consuming tasks">
          {(c) => {
            const consBy = new Map<string, Row>();
            cons.rows.forEach((r) => consBy.set(`${r.account_id}|${r.stream_fqn}`, r));
            const items = c.rows.filter((r) => num(r.days_to_stale) !== null).map((r) => {
              const days = num(r.days_to_stale) as number;
              const k = consBy.get(`${r.account_id}|${r.stream_fqn}`);
              let who = "";
              if (k) {
                const n = numOrZero(k.consumer_count);
                who = n === 0 ? "no consumer" : numOrZero(k.suspended_consumers) > 0 ? `${fmtInt(k.suspended_consumers)} of ${fmtInt(n)} consumers suspended` : `${fmtInt(n)} consumer${n === 1 ? "" : "s"} running`;
              } else if (!cons.loading && !cons.note) who = "no consumer";
              const when = isStale(r) ? (days < 0 ? `stale ${fmtInt(Math.abs(Math.round(days)))} d` : "stale") : `${fmtInt(Math.round(days))} d left`;
              return { key: `${r.account_id}|${r.stream_fqn}`, name: String(r.stream_fqn || r.stream_name || "(no name in this export)"), days: isStale(r) && days >= 0 ? -0.5 : days, note: who ? `${when} · ${who}` : when };
            });
            return <StaleDays items={items} />;
          }}
        </PlCard>
        </div>
      </Grid>
      <PlCard c={dt} open={open("sf_dt_refresh_failures_and_lag")} title="Refresh state, by dynamic table"
        subtitle={`${fmtInt(p.filters.window)} d · failed and behind-target share of refreshes · full-refresh share · click a row`}>
        {(c) => {
          const suspBy = new Map(susp.rows.filter(isFlagged).map((r) => [`${r.account_id}|${r.dt_full_name}`, r]));
          const rows = [...c.rows].sort((a, b) => numOrZero(b.failure_pct) + numOrZero(b.lag_breach_pct) - numOrZero(a.failure_pct) - numOrZero(a.lag_breach_pct));
          return (
            <DrillTable aria="Refresh state by dynamic table" n={10}
              cols={[{ label: "Dynamic table" }, { label: "Refreshes", num: true, width: "auto" }, { label: "Failed", num: true, width: "auto" }, { label: "Behind", num: true, width: "auto" }, { label: "Full", num: true, width: "auto" }, { label: "State", width: "minmax(80px, auto)" }]}
              rows={rows.map((r) => {
                const s = suspBy.get(`${r.account_id}|${r.dt_full_name}`);
                return {
                  key: `${r.account_id}|${r.dt_full_name}`, status: rowStatus(r),
                  onOpen: openRow("sf_dt_refresh_failures_and_lag", "dt_full_name", r.dt_full_name, dtName(r)),
                  cells: [dtName(r), fmtInt(r.refreshes), pctText(r.failure_pct), pctText(r.lag_breach_pct), pctText(r.full_pct),
                    s ? chip(`suspended · ${fmtInt(s.read_queries)} reads`, "CRITICAL") : chip(String(r.last_state || "–").toLowerCase(), String(r.last_state || "").toUpperCase() === "FAILED" ? "CRITICAL" : "OK")],
                };
              })} />
          );
        }}
      </PlCard>
      <Grid>
        <PlCard c={awake} open={open("sf_dt_lag_keeps_warehouse_awake")} title="Refreshes that keep a warehouse awake" subtitle="refreshes sooner than the auto-suspend · $ is part of the idle $, not added to it">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r.dt_keepawake_credits) > 0).map((r) => {
              const v = c.priced ? usd(c, r, "est_idle_context_usd_list") : numOrZero(r.dt_keepawake_credits);
              return {
                key: `${r.account_id}|${r.warehouse_id}`, name: nameId(r.warehouse_name, r.warehouse_id), value: v, status: rowStatus(r), wh: r.warehouse_id,
                valueText: [`${c.priced ? usd0(v) : `${fmtInt(Math.round(v))} credits`} of idle`, r.top_dt_full_name ? `${String(r.top_dt_full_name).split(".").pop()} every ${dur(r.top_dt_every_s)}` : null,
                  `auto-suspend ${dur(r.auto_suspend_s)}`].filter(Boolean).join(" · "),
              };
            });
            return items.length ? <StatusBars items={items} n={8} ariaLabel="Warehouses kept awake by dynamic-table refreshes"
              onBarClick={(it) => DrawerBus.open({ id: "sf_dt_lag_keeps_warehouse_awake", col: "warehouse_id", val: String(it.wh), label: it.name })} />
              : <Note>No dynamic table refreshes sooner than its warehouse can suspend.</Note>;
          }}
        </PlCard>
        <PlCard c={orph} open={open("sf_dt_downstream_orphans")} title="DOWNSTREAM tables that never refresh" subtitle="TARGET_LAG = DOWNSTREAM with no running consumer · days since its data">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter(isFlagged).map((r) => ({
              key: `${r.account_id}|${r.dt_full_name}`, name: dtName(r), value: numOrZero(r.days_since_data), status: rowStatus(r), dtFull: r.dt_full_name,
              valueText: `${fmtInt(r.days_since_data)} d old · ${r.finding === "manual_only" ? "refreshed only at creation or by hand" : "no scheduled refresh"}`,
            }));
            const ok = c.rows.filter((r) => r.finding === "ok").length;
            return items.length ? <StatusBars items={items} n={8} ariaLabel="DOWNSTREAM dynamic tables that never refresh"
              onBarClick={(it) => DrawerBus.open({ id: "sf_dt_downstream_orphans", col: "dt_full_name", val: String(it.dtFull), label: it.name })} />
              : <Note>{c.rows.length ? `All ${fmtInt(ok)} DOWNSTREAM tables refresh with a consumer.` : "No dynamic table uses TARGET_LAG = DOWNSTREAM."}</Note>;
          }}
        </PlCard>
      </Grid>
    </div>
  );
};
PlTasksDynamic.ownsTiles = true;
(PlTasksDynamic as any).ownsLede = true;

// ═══════════════════════ Data loading ═══════════════════════

export function PlLoadingPipes(p: ApPageProps) {
  const d = usePlData(p, ["sf_pipe_cost_and_files", "sf_pipe_inactive", "sf_load_snowpipe_latency", "sf_load_streaming_channel_errors", "sf_pipe_invalid_or_unnotified"]);
  const alerts = d.sf_pipe_invalid_or_unnotified;
  const alertsN = counts(alerts, "pipes");
  const open = opener(p);
  const pc = d.sf_pipe_cost_and_files, pi = d.sf_pipe_inactive, lat = d.sf_load_snowpipe_latency, ch = d.sf_load_streaming_channel_errors;
  const pipeName = (r: Row) => nameId(r.pipe_full_name || r.pipe_name, r.pipe_id);

  // The figures the tiles and the lede share.
  const gbAll = sum(pc.rows, "gb_inserted");
  const rate = (r: Row) => (numOrZero(r.gb_inserted) > 0 ? (pc.priced ? usd(pc, r, "est_pipe_usd_list") : numOrZero(r.credits)) / numOrZero(r.gb_inserted) : 0);
  const rateAll = gbAll > 0 ? (pc.priced ? usdSum(pc, pc.rows, "est_pipe_usd_list") : sum(pc.rows, "credits")) / gbAll : null;
  const worstPipe = [...pc.rows].filter((r) => numOrZero(r.gb_inserted) > 0).sort((a, b) => rate(b) - rate(a))[0];
  const rateText = (v: number) => (pc.priced ? `${usdRate(v)} / GB` : `${v.toFixed(2)} credits / GB`);
  const silentN = !pi.loading && !pi.note ? counts(pi, "pipes") : null;
  const lede = pc.loading || pi.loading ? "…" : [
    worstPipe && rateAll ? `${pipeName(worstPipe)} pays ${(rate(worstPipe) / rateAll).toFixed(rate(worstPipe) / rateAll >= 10 ? 0 : 1)}× the all-pipe cost per GB, on ${Number(numOrZero(worstPipe.avg_file_mb)).toFixed(1)} MB files` : null,
    silentN && silentN.flagged > 0 ? `${fmtInt(silentN.flagged)}${ofPop(silentN)} have gone quiet` : null,
  ].filter(Boolean).join("; ") || null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede ? (lede === "…" ? lede : `${lede}.`) : null); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div>
      <Tiles>
        <PlTile c={pc} open={open("sf_pipe_cost_and_files")} label="Snowpipe cost per GB" make={(c) => {
          if (gbAll <= 0 || rateAll === null) return null;
          const n = counts(c, "pipes");
          return {
            headline: pc.priced ? usdRate(rateAll) : rateAll.toFixed(2), unit: pc.priced ? "/ GB, all pipes" : "credits / GB, all pipes",
            base: [`${fmtInt(n.population ?? c.rows.length)} pipes`, worstPipe ? `worst ${pipeName(worstPipe)}: ${rateText(rate(worstPipe))}` : null].filter(Boolean).join(" · "),
            cause: "Snowpipe bills per file as well as per GB: small files cost more per GB.",
            status: tileStatus(c.rows.filter(isFlagged)),
          };
        }} />
        <PlTile c={pi} open={open("sf_pipe_inactive")} label="Silent pipes" make={(c) => {
          const flagged = c.rows.filter(isFlagged);
          const n = counts(c, "pipes");
          const longest = Math.max(0, ...flagged.map((r) => numOrZero(r.days_since_load)));
          const lastFailed = flagged.filter((r) => /fail|error/i.test(String(r.last_copy_status || ""))).length;
          return {
            headline: fmtInt(n.flagged), unit: ofPop(n).trim(),
            base: flagged.length ? [longest > 0 ? `longest ${fmtInt(longest)} d without a load` : "no load in the lookback", `${fmtInt(lastFailed)} last load failed`].join(" · ") : "every pipe loaded recently",
            cause: flagged.length ? "Nothing alerts when a pipe stops receiving files." : undefined,
            status: tileStatus(flagged),
          };
        }} />
        <PlTile c={lat} open={open("sf_load_snowpipe_latency")} label="Slowest p95 load" make={(c) => {
          const w = [...c.rows].filter((r) => num(r.p95_latency_seconds) !== null).sort((a, b) => numOrZero(b.p95_latency_seconds) - numOrZero(a.p95_latency_seconds))[0];
          if (!w) return null;
          const n = counts(c, "pipes");
          return {
            headline: dur(w.p95_latency_seconds), unit: "file staged → loaded",
            base: `${fmtInt(n.flagged)}${ofPop(n)} flagged · ${String(w.pipe_display_name || pipeName(w))}`,
            status: tileStatus(c.rows.filter(isFlagged)),
          };
        }} />
        <PlTile c={ch} open={open("sf_load_streaming_channel_errors")} label="Streaming rows rejected" make={(c) => {
          const parsed = sum(c.rows, "parsed_rows_window");
          if (parsed <= 0) return null;
          const n = counts(c, "channels");
          const w = [...c.rows].filter((r) => numOrZero(r.parsed_rows_window) > 0)
            .sort((a, b) => numOrZero(b.error_rows_window) / numOrZero(b.parsed_rows_window) - numOrZero(a.error_rows_window) / numOrZero(a.parsed_rows_window))[0];
          return {
            headline: fmtShare(pctOf(sum(c.rows, "error_rows_window"), parsed)), unit: "of rows",
            base: [`${fmtInt(n.flagged)}${ofPop(n)}`, w && numOrZero(w.error_rows_window) > 0 ? `${nameId(w.channel_full_name, w.channel_id)} rejects ${fmtShare(pctOf(numOrZero(w.error_rows_window), numOrZero(w.parsed_rows_window)))}` : null].filter(Boolean).join(" · "),
            status: tileStatus(c.rows.filter(isFlagged)),
          };
        }} />
      </Tiles>
      <Grid>
        <PlCard c={pc} open={open("sf_pipe_cost_and_files")} title="Cost per GB rises as files shrink" subtitle="by pipe, with its average file size · dot = status">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r.gb_inserted) > 0).map((r) => ({
              key: `${r.account_id}|${r.pipe_full_name}`, name: pipeName(r), value: rate(r), status: rowStatus(r),
              valueText: `${rateText(rate(r))} · ${Number(numOrZero(r.avg_file_mb)).toFixed(1)} MB files`,
            }));
            if (!items.length) return null;
            // Spend by the pipe's average file size: where the per-file overhead lands.
            const bins: [string, (mb: number) => boolean][] = [["files under 1 MB", (mb) => mb < 1], ["1–10 MB", (mb) => mb >= 1 && mb < 10], ["10–100 MB", (mb) => mb >= 10 && mb < 100], ["100 MB and up", (mb) => mb >= 100]];
            const col = c.priced ? "est_pipe_usd_list" : "credits";
            const val = (r: Row) => (c.priced ? usd(c, r, col) : numOrZero(r[col]));
            const segs = bins.map(([label, test]) => ({ key: label, label, value: c.rows.filter((r) => r.avg_file_mb != null && test(numOrZero(r.avg_file_mb))).reduce((s, r) => s + val(r), 0) }))
              .concat([{ key: "none", label: "(no file size)", value: c.rows.filter((r) => r.avg_file_mb == null).reduce((s, r) => s + val(r), 0), unknown: true } as any])
              .filter((s) => s.value > 0);
            return (
              <div className="pl-stack">
                <StatusBars items={items} n={8} ariaLabel="Cost per GB by pipe" />
                {segs.length > 1 && <div>
                  <div className="pl-note chart-note-oneline">{`Snowpipe ${c.priced ? "spend" : "credits"} by the pipe's average file size · context`}</div>
                  <StackedShareBar segments={segs} valueFmt={c.priced ? usd0 : (v) => `${fmtInt(Math.round(v))} credits`} ariaLabel="Snowpipe spend by average file size" />
                </div>}
              </div>
            );
          }}
        </PlCard>
        <PlCard c={lat} open={open("sf_load_snowpipe_latency")} title="p95 load latency, by pipe" subtitle="file staged → loaded">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => num(r.p95_latency_seconds) !== null).map((r) => ({
              key: `${r.account_id}|${r.pipe_full_name}|${r.table_id}`, name: String(r.pipe_display_name || pipeName(r)), value: numOrZero(r.p95_latency_seconds), status: rowStatus(r),
              valueText: `${dur(r.p95_latency_seconds)} · ${fmtInt(r.files)} files`,
            }));
            return items.length ? <StatusBars items={items} n={10} ariaLabel="p95 load latency by pipe" /> : null;
          }}
        </PlCard>
      </Grid>
      <Grid>
        <PlCard c={pi} open={open("sf_pipe_inactive")} title="Silent pipes" subtitle="days since the last load">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter(isFlagged).map((r) => {
              const days = num(r.days_since_load);
              return {
                key: `${r.account_id}|${r.pipe_full_name}`, name: pipeName(r), value: days ?? 0, status: rowStatus(r),
                valueText: `${days !== null ? `${fmtInt(days)} d` : "no load in lookback"}${r.last_copy_status ? ` · ${String(r.last_copy_status).toLowerCase()}` : ""}`,
              };
            });
            return items.length ? <StatusBars items={items} n={10} ariaLabel="Days since last load by pipe" /> : null;
          }}
        </PlCard>
        <PlCard c={ch} open={open("sf_load_streaming_channel_errors")} title="Rows rejected, by channel" subtitle="error rows of parsed rows">
          {(c) => {
            const items = c.rows.filter((r) => numOrZero(r.parsed_rows_window) > 0).map((r) => ({
              key: `${r.account_id}|${r.channel_id}`, name: nameId(r.channel_full_name, r.channel_id), value: numOrZero(r.error_rows_window), total: numOrZero(r.parsed_rows_window), status: rowStatus(r),
            }));
            return items.length ? <ShareBarList items={items} n={10} noun="rows" /> : null;
          }}
        </PlCard>
      </Grid>
      <PlCard c={alerts} open={open("sf_pipe_invalid_or_unnotified")} title="Broken pipes, and failures nobody hears about"
        subtitle={`${fmtInt(alertsN.flagged)}${ofPop(alertsN)} · invalid, or auto-ingest with no error integration · failed files in ${fmtInt(p.filters.window)} d`}>
        {(c) => {
          const rank = (r: Row) => (rowStatus(r) === "CRITICAL" ? 0 : 1);
          const rows = c.rows.filter(isFlagged).sort((a, b) => rank(a) - rank(b) || numOrZero(b.failed_files) - numOrZero(a.failed_files));
          if (!rows.length) return null;
          return (
            <DrillTable aria="Pipes that are broken or send no error alerts" n={8}
              cols={[{ label: "Pipe" }, { label: "Failed files", num: true, width: "auto" }, { label: "Why", width: "minmax(80px, auto)" }]}
              rows={rows.map((r) => ({
                key: `${r.account_id}|${r.pipe_full_name}`, status: rowStatus(r),
                onOpen: openRow("sf_pipe_invalid_or_unnotified", "pipe_full_name", r.pipe_full_name, nameId(r.pipe_full_name, r.pipe_id)),
                cells: [nameId(r.pipe_full_name, r.pipe_id), fmtInt(r.failed_files),
                  chip(r.finding === "invalid" ? "invalid" : r.finding === "failing_unnotified" ? "files fail, no error alert" : "no error alert", rowStatus(r))],
              }))} />
          );
        }}
      </PlCard>
    </div>
  );
};
PlLoadingPipes.ownsTiles = true;
(PlLoadingPipes as any).ownsLede = true;

export function PlLoadingCopy(p: ApPageProps) {
  const d = usePlData(p, ["sf_load_copy_errors", "sf_load_small_files", "sf_obj_iceberg_compaction_cost", "sf_obj_external_tables", "sf_obj_iceberg_tables",
    "sf_load_bulk_copy_vs_snowpipe", "sf_load_copy_listing_overhead"]);
  const bulk = d.sf_load_bulk_copy_vs_snowpipe, listing = d.sf_load_copy_listing_overhead;
  const open = opener(p);
  const ce = d.sf_load_copy_errors, sf = d.sf_load_small_files, ic = d.sf_obj_iceberg_compaction_cost;
  const ext = d.sf_obj_external_tables, ice = d.sf_obj_iceberg_tables;
  const tableName = (r: Row) => nameId(r.table_full_name || r.table_fqn || r.table_name, r.table_id);
  const bad = (r: Row) => numOrZero(r.failed_files) + numOrZero(r.partial_files);

  // The figures the tiles and the lede share.
  const files = sum(ce.rows, "files"), badAll = ce.rows.reduce((s, r) => s + bad(r), 0);
  const ceN = !ce.loading && !ce.note ? counts(ce, "tables") : null;
  const extFlag = ext.rows.filter(isFlagged);
  const lede = ce.loading ? "…" : files > 0 && ceN
    ? `${fmtShare(pctOf(badAll, files))} of files failed or loaded in part, on ${fmtInt(ceN.flagged)}${ofPop(ceN)}.`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  // An error message cut to its kind: the text before any position, file or value.
  const errKind = (msg: any) => {
    const s = String(msg || "").trim();
    if (!s) return "";
    return s.replace(/[,:;(].*$/, "").replace(/\s+(at|in|on)\s.*$/i, "").slice(0, 48).trim().toLowerCase();
  };
  return (
    <div className="sx-page">
      <Tiles4>
        <PlTile c={ce} open={scrollTo("lc-failed")} label="Files failed or partly loaded" make={(c) => {
          if (files <= 0) return null;
          const n = counts(c, "tables");
          const worst = [...c.rows].sort((a, b) => numOrZero(b.failed_or_partial_pct) - numOrZero(a.failed_or_partial_pct))[0];
          return {
            headline: fmtShare(pctOf(badAll, files)), unit: "of files",
            base: `${fmtInt(badAll)} of ${fmtInt(files)} files · ${fmtInt(n.flagged)}${ofPop(n)}`,
            cause: worst && bad(worst) > 0 ? `worst ${tableName(worst)}: ${pctText(worst.failed_or_partial_pct)}` : undefined,
            status: tileStatus(c.rows.filter(isFlagged)), openLabel: "By table ↓",
          };
        }} />
        <PlTile c={sf} open={scrollTo("lc-small")} label="Small files" make={(c) => {
          const files = sum(c.rows, "files");
          if (files <= 0) return null;
          const small = c.rows.reduce((s, r) => s + numOrZero(r.files) * numOrZero(r.small_file_pct) / 100, 0);
          const n = counts(c, "tables");
          return {
            headline: fmtShare(pctOf(small, files)), unit: "of files",
            base: `${fmtInt(n.flagged)}${ofPop(n)} · avg ${(sum(c.rows, "total_gb") * 1024 / files).toFixed(1)} MB per file`,
            cause: "Each file pays a fixed load overhead: batch them to 100–250 MB.",
            status: tileStatus(c.rows.filter(isFlagged)), openLabel: "By table ↓",
          };
        }} />
        <PlTile c={ic} open={scrollTo("lc-ice")} label="Iceberg compaction nobody reads" make={(c) => {
          if (!c.priced) return { headline: null, missingReason: "No $/credit price in this export." };
          const flagged = c.rows.filter(isFlagged);
          const m = c.f && c.f.money;
          const total = m && m.unit !== "currency" && Number.isFinite(Number(m.usd)) ? Number(m.usd) : usdSum(c, flagged, "est_wasted_usd_list");
          const n = counts(c, "tables");
          return {
            headline: usd0(total), unit: "possible waste",
            base: `${fmtInt(n.flagged)}${ofPop(n)} · ${fmtInt(flagged.filter((r) => numOrZero(r.read_queries) === 0).length)} with 0 reads`,
            status: tileStatus(flagged), openLabel: "By table ↓",
          };
        }} />
        <PlTile c={ext} open={scrollTo("lc-fresh")} label="External tables broken or stale" make={(c) => {
          if (!c.rows.length) return null;
          const n = counts(c, "external tables");
          const invalid = extFlag.filter((r) => truthy(r.is_invalid));
          const top = invalid[0] || extFlag[0];
          return {
            headline: fmtInt(n.flagged), unit: ofPop(n).trim(),
            base: [`${fmtInt(invalid.length)} invalid`, `${fmtInt(extFlag.filter((r) => numOrZero(r.read_queries) === 0).length)} with 0 reads`].join(" · "),
            cause: top ? `${nameId(top.table_fqn, top.table_id)}: ${String(top.reasons || "flagged").split(";")[0]}` : "Every external table is valid and read.",
            status: tileStatus(extFlag), openLabel: "Freshness ↓",
          };
        }} />
      </Tiles4>
      <Grid>
        <div id="lc-failed">
        <PlCard c={ce} open={open("sf_load_copy_errors")} title="Failed % by table" subtitle="failed or partly loaded files, of all files · why, by each table's last error">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => bad(r) > 0).map((r) => {
              const pct = pctOf(bad(r), numOrZero(r.files)) ?? 0;
              return {
                key: `${r.account_id}|${r.table_id}|${r.pipe_full_name}`, name: tableName(r), value: pct, status: rowStatus(r), tableId: r.table_id,
                valueText: `${fmtShare(pct)} · ${fmtInt(r.failed_files)} failed + ${fmtInt(r.partial_files)} partial of ${fmtInt(r.files)}`,
              };
            });
            if (!items.length) return null;
            const m = new Map<string, number>();
            let none = 0;
            c.rows.forEach((r) => { const b = bad(r); if (b <= 0) return; const k = errKind(r.last_error_message); if (k) m.set(k, (m.get(k) || 0) + b); else none += b; });
            const segs = [...m.entries()].map(([label, value]) => ({ key: label, label, value }));
            if (none > 0) segs.push({ key: "__none", label: "(no error message)", value: none, unknown: true } as any);
            return (
              <div className="pl-stack">
                <StatusBars items={items} max={100} n={8} ariaLabel="Failed files by table" onBarClick={(it) => DrawerBus.open({ id: "sf_load_copy_errors", col: "table_id", val: String(it.tableId), label: it.name })} />
                {segs.length > 0 && <StackedShareBar segments={segs} pareto valueFmt={(v) => `${fmtInt(v)} files`} ariaLabel="Failed files by error kind" />}
              </div>
            );
          }}
        </PlCard>
        </div>
        <div id="lc-small">
        <PlCard c={sf} open={open("sf_load_small_files")} title="Small files by table" subtitle="share of files under the small-file mark · avg MB">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r.files) > 0).map((r) => ({
              key: `${r.account_id}|${r.table_id}|${r.pipe_full_name}`, name: tableName(r), value: numOrZero(r.small_file_pct), status: rowStatus(r),
              valueText: `${pctText(r.small_file_pct)} small · avg ${Number(numOrZero(r.avg_file_mb)).toFixed(1)} MB`,
            }));
            return items.length ? <StatusBars items={items} max={100} n={10} ariaLabel="Small files by table" /> : null;
          }}
        </PlCard>
        </div>
      </Grid>
      <Grid>
        <PlCard c={bulk} open={open("sf_load_bulk_copy_vs_snowpipe")} title="Frequent small COPY loads · Snowpipe estimate"
          subtitle="COPY run time on the warehouse vs Snowpipe's credits per GB · an estimate, never added to savings">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => r.verdict === "snowpipe_fits").map((r) => {
              const v = c.priced ? usd(c, r, "est_saving_usd_list") : numOrZero(r.est_saving_credits);
              return {
                key: `${r.account_id}|${r.warehouse_id}|${r.user_name}`, name: `${nameId(r.warehouse_name, r.warehouse_id)} · ${r.user_name}`, value: v, status: rowStatus(r),
                wh: r.warehouse_id,
                valueText: [`est. ${c.priced ? usd0(v) : `${fmtInt(Math.round(v))} credits`}`, `${fmtInt(r.copies_per_day)} a day`, `${Number(numOrZero(r.median_mb)).toFixed(1)} MB each`,
                  num(r.auto_suspend_s) === 0 ? "auto-suspend off" : null].filter(Boolean).join(" · "),
              };
            });
            return items.length ? <StatusBars items={items} n={8} ariaLabel="Frequent small COPY loads by warehouse and user"
              onBarClick={(it) => DrawerBus.open({ id: "sf_load_bulk_copy_vs_snowpipe", col: "warehouse_id", val: String(it.wh), label: it.name })} />
              : <Note>No frequent, small COPY load runs on a warehouse.</Note>;
          }}
        </PlCard>
        <PlCard c={listing} open={open("sf_load_copy_listing_overhead")} title="COPY time spent listing files"
          subtitle="share of COPY time listing the stage path · runs in cloud services, so no $">
          {(c) => {
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r.list_minutes) > 0).map((r) => ({
              key: `${r.account_id}|${r.warehouse_id}|${r.user_name}`, name: `${nameId(r.warehouse_name, r.warehouse_id)} · ${r.user_name}`, value: numOrZero(r.list_pct), status: rowStatus(r),
              valueText: `${pctText(r.list_pct)} · ${dur(numOrZero(r.list_minutes) * 60)} listing in ${fmtInt(r.copies)} COPYs`,
            }));
            return items.length ? <StatusBars items={items} max={100} n={8} ariaLabel="COPY listing time by warehouse and user" /> : null;
          }}
        </PlCard>
      </Grid>
      <Grid>
        <div id="lc-ice">
        <PlCard c={ic} open={open("sf_obj_iceberg_compaction_cost")} title="Iceberg compaction vs reads" subtitle="compaction cost by table, with its reads">
          {(c) => {
            const col = c.priced ? "est_compaction_usd_list" : "compaction_credits";
            const items: StatusBarItem[] = c.rows.filter((r) => numOrZero(r[col]) > 0).map((r) => {
              const v = c.priced ? usd(c, r, col) : numOrZero(r[col]);
              const dropped = r.is_dropped === true || String(r.is_dropped).toLowerCase() === "true";
              return {
                key: `${r.account_id}|${r.table_id}`, name: nameId(r.table_fqn, r.table_id), value: v, status: rowStatus(r),
                valueText: `${c.priced ? usd0(v) : `${fmtInt(v)} credits`} · ${fmtInt(r.read_queries)} reads${dropped ? " · dropped" : ""}`,
              };
            });
            return items.length ? <StatusBars items={items} n={10} ariaLabel="Iceberg compaction cost by table" /> : null;
          }}
        </PlCard>
        </div>
        <div id="lc-fresh">
        <PlCard c={{ ...ext, loading: ext.loading || ice.loading, note: ext.note && ice.note ? ext.note : null }} open={open("sf_obj_external_tables")}
          title="External and Iceberg tables · freshness" subtitle="snapshot at export · days since the last refresh or change · reads in the window · click a row">
          {() => {
            const asOf = p.meta && p.meta.as_of_date ? Date.parse(String(p.meta.as_of_date).slice(0, 10)) : NaN;
            const daysSince = (v: any) => { const t = v ? Date.parse(String(v).slice(0, 10)) : NaN; return Number.isFinite(t) && Number.isFinite(asOf) ? Math.max(0, Math.round((asOf - t) / 86400000)) : null; };
            const list = [
              ...ext.rows.map((r) => ({ r, id: "sf_obj_external_tables", kind: "external", days: daysSince(r.last_refreshed_on) })),
              ...ice.rows.map((r) => ({ r, id: "sf_obj_iceberg_tables", kind: "Iceberg", days: num(r.days_since_change) })),
            ].sort((a, b) => (isFlagged(b.r) ? 1 : 0) - (isFlagged(a.r) ? 1 : 0) || (b.days ?? -1) - (a.days ?? -1));
            return (
              <DrillTable aria="External and Iceberg tables, freshness" n={10} empty="No external or Iceberg tables in this export."
                more={ext.note || ice.note ? <span>{` ${ext.note ? `External tables: ${ext.note.replace(/^– /, "")}` : `Iceberg tables: ${String(ice.note).replace(/^– /, "")}`}`}</span> : null}
                cols={[{ label: "Table" }, { label: "Kind", width: "auto" }, { label: "Days since", num: true, width: "auto" }, { label: "Reads", num: true, width: "auto" }, { label: "Why", width: "minmax(80px, auto)" }]}
                rows={list.map((o) => ({
                  key: `${o.kind}|${o.r.account_id}|${o.r.table_fqn}`, status: rowStatus(o.r),
                  onOpen: openRow(o.id, "table_fqn", o.r.table_fqn, nameId(o.r.table_fqn, o.r.table_id)),
                  cells: [nameId(o.r.table_fqn, o.r.table_id), o.kind, o.days != null ? `${fmtInt(o.days)} d` : "–", fmtInt(o.r.read_queries),
                    isFlagged(o.r) ? chip(String(o.r.reasons || "flagged").split(";")[0].slice(0, 40), rowStatus(o.r)) : chip("ok", "OK")],
                }))} />
            );
          }}
        </PlCard>
        </div>
      </Grid>
    </div>
  );
};
PlLoadingCopy.ownsTiles = true;
(PlLoadingCopy as any).ownsLede = true;

// ═══════════════════════ Serverless features ═══════════════════════

const featureWord = (v: any) => {
  const s = String(v || "(no feature)").replace(/_/g, " ").toLowerCase();
  return s.charAt(0).toUpperCase() + s.slice(1);
};
const openRow = (id: string, col: string, val: any, label: string) => () =>
  DrawerBus.open({ id, col: val != null ? col : null, val: val != null ? String(val) : null, label });
const scrollTo = (anchor: string) => () => scrollToAnchor(anchor);
const chip = (text: string, status: string) => <span className={`dt-chip${status === "CRITICAL" ? " tone-crit" : status === "WARN" ? " tone-warn" : ""}`}>{text}</span>;

/** A check homed on another Serverless sub-tab, read for one tile: its rows, or null and why. */
function useOtherCheck(p: ApPageProps, id: string) {
  const st = useFindingData(id, p.filters.window, p.filters.accountIds as any, 5000) as FetchState;
  const rows = st.phase === "ready" && st.outcome === "ok_rows" && st.data ? withoutTotalRows(st.data.rows).filter((r) => r.status !== "NOT_ASSESSED") : null;
  return { rows, loading: st.phase === "loading", why: st.phase === "ready" && st.outcome !== "ok_rows" ? notAssessedText(st.data) : st.phase === "error" ? (st.error || "could not load") : null };
}

export function PlServerlessFeature(p: ApPageProps) {
  const d = usePlData(p, ["sf_cost_serverless_features", "sf_cost_openflow_spend"]);
  const open = opener(p);
  const c0 = d.sf_cost_serverless_features, of = d.sf_cost_openflow_spend;
  const clus = useOtherCheck(p, "sf_storage_clustering_value");
  const spendAgg = useFindingAgg("cost_dollarized_by_service_day", p.filters.window, p.filters.accountIds as any, ["usage_date"], "sum", COST_MONEY_COL) as FetchState;
  const acctSpend = spendAgg.phase === "ready" && spendAgg.outcome === "ok_rows" && spendAgg.data ? aggTotal(spendAgg.data) : null;
  const nowCol = c0.priced ? "est_current_usd_list" : "current_credits";
  const prevCol = c0.priced ? "est_previous_usd_list" : "previous_credits";
  const val = (r: Row, col: string) => (c0.priced ? usd(c0, r, col) : numOrZero(r[col]));
  const fmtV = c0.priced ? usd0 : (v: number) => `${fmtInt(v)} credits`;
  const feats = (() => {
    const m = new Map<string, { now: number; prev: number }>();
    c0.rows.forEach((r) => {
      const k = featureWord(r.feature);
      const cur = m.get(k) || { now: 0, prev: 0 };
      cur.now += val(r, nowCol); cur.prev += val(r, prevCol);
      m.set(k, cur);
    });
    return [...m.entries()].sort((a, b) => b[1].now - a[1].now);
  })();
  const now = feats.reduce((s, [, v]) => s + v.now, 0), prev = feats.reduce((s, [, v]) => s + v.prev, 0);
  const ch = prev > 0 ? ((now - prev) / prev) * 100 : null;
  const objects = c0.rows.filter((r) => val(r, nowCol) > 0);
  const risen = c0.rows.filter((r) => val(r, nowCol) - val(r, prevCol) > 0.5);
  const ac = feats.find(([k]) => k === "Auto clustering");
  const cn = counts(c0, "serverless objects");
  // Openflow: the runtime rows say how many hours each billed; the service rows carry the $.
  const runtimes = of.rows.filter((r) => r.row_kind === "runtime");
  const ofFlag = runtimes.filter(isFlagged);
  const ofUsd = usdSum(of, of.rows.filter((r) => r.row_kind === "service"), "est_current_usd_list");
  const clusFlag = clus.rows ? clus.rows.filter(isFlagged).length : null;

  const lede = c0.loading ? "…" : now > 0
    ? `${fmtInt(feats.length)} serverless features cost ${fmtV(now)} in the last ${fmtInt(p.filters.window)} days${ch != null ? `, ${ch >= 0 ? "up" : "down"} ${fmtShare(Math.abs(ch))}` : ""}.${feats[0] ? ` ${feats[0][0]} is the largest, at ${fmtV(feats[0][1].now)}.` : ""}`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const objRows = [...objects].sort((a, b) => val(b, nowCol) - val(a, nowCol));
  const objMax = objRows.length ? val(objRows[0], nowCol) : 1;
  const live = feats.filter(([, v]) => v.now > 0);
  // Six features by name, the rest as one grey row; bars scale to the largest.
  const featRows = live.slice(0, 6).map(([k, v]) => ({ k, ...v, other: false }));
  if (live.length > 6) {
    const rest = live.slice(6);
    featRows.push({ k: `Other (${fmtInt(rest.length)})`, now: rest.reduce((s, [, v]) => s + v.now, 0), prev: rest.reduce((s, [, v]) => s + v.prev, 0), other: true });
  }
  const pcOf = (n: number, pv: number) => (pv > 0 ? ((n - pv) / pv) * 100 : null);
  const fastest = [...live].filter(([, v]) => v.prev > 0).sort((a, b) => numOrZero(pcOf(b[1].now, b[1].prev)) - numOrZero(pcOf(a[1].now, a[1].prev)))[0];
  const movers = c0.rows.map((r) => ({ r, d: val(r, nowCol) - val(r, prevCol) })).filter((m) => Math.abs(m.d) >= 0.5)
    .sort((a, b) => Math.abs(b.d) - Math.abs(a.d)).slice(0, 8);
  const moveMax = Math.max(1, ...movers.map((m) => Math.abs(m.d)));
  const signedV = (v: number) => `${v >= 0 ? "+" : "−"}${fmtV(Math.abs(v))}`;
  return (
    <div className="sx-page ac-page">
      <Tiles4>
        <PlTile c={c0} open={scrollTo("sv-feature")} label="Serverless spend" make={() => now > 0 ? {
          headline: fmtV(now), status: "neutral",
          base: `${[`Last ${fmtInt(p.filters.window)} days`, acctSpend && c0.priced ? `${fmtShare(pctOf(now, acctSpend))} of ${usd0(acctSpend)} total spend` : null, `${fmtInt(objects.length)} objects across ${fmtInt(feats.length)} features`].filter(Boolean).join(" · ")}.`,
          cause: "Billed as serverless credits, not through a warehouse.", openLabel: "By feature ↓",
        } : null} />
        <PlTile c={c0} open={scrollTo("sv-movers")} label="Change" make={(c) => ch == null ? null : {
          headline: signedPct(ch), status: tileStatus(c.rows.filter(isFlagged)),
          base: `Vs previous ${fmtInt(p.filters.window)} days: ${now - prev >= 0 ? "+" : "−"}${fmtV(Math.abs(now - prev))} · ${fmtInt(risen.length)} of ${fmtInt(cn.population ?? objects.length)} objects rose.`,
          cause: "A change in spend, not waste.", openLabel: "Biggest movers ↓",
        }} />
        <PlTile c={c0} open={() => p.goTo({ tab: p.area, subtab: "clustering" })} label="Auto clustering" make={() => ac && now > 0 ? {
          headline: fmtV(ac[1].now), status: clus.rows ? tileStatus(clus.rows.filter(isFlagged)) : "neutral",
          base: `${fmtShare(pctOf(ac[1].now, now))} of serverless spend${clus.rows ? ` · ${fmtInt(clusFlag)} of ${fmtInt(clus.rows.length)} clustered tables flagged` : ""}.`,
          openLabel: "Clustering →",
        } : null} />
        <PlTile c={of} open={open("sf_cost_openflow_spend")} label="Openflow runtimes billing every hour" make={(c) => runtimes.length ? {
          headline: `${fmtInt(ofFlag.length)} of ${fmtInt(runtimes.length)}`, unit: "runtimes", status: tileStatus(c.rows.filter(isFlagged)),
          base: `${c.priced ? usd0(ofUsd) : "–"} Openflow spend in total, as context.`,
          cause: ofFlag[0] ? `${nameId(ofFlag[0].runtime_name, ofFlag[0].runtime_key)}: ${ofFlag[0].reasons || "bills every hour"}.` : "A runtime bills while it is up, flows or not.",
        } : null} />
      </Tiles4>
      <div className="cx-row">
        <div id="sv-feature">
          <PlCard c={c0} open={open("sf_cost_serverless_features")} title="Spend by feature" subtitle={`${fmtV(now)} across ${fmtInt(live.length)} features · change vs previous ${fmtInt(p.filters.window)} days`}>
            {() => !featRows.length ? null : (
              <CxTable aria="Serverless spend by feature" phone={{ cols: [0, 2, 3, 4], widths: "minmax(0, 1fr) 64px 44px 52px" }} minWidth={420}
                cols={[{ label: "Feature", width: "minmax(130px, 1.2fr)" }, { label: "", width: "minmax(60px, 1fr)" }, { label: "Spend", width: "72px", num: true }, { label: "Share", width: "52px", num: true }, { label: "Vs prev.", width: "64px", num: true }]}
                rows={featRows.map((f) => {
                  const pc = pcOf(f.now, f.prev);
                  return {
                    key: f.k,
                    cells: [f.k, <CellBar key="b" value={f.now} max={featRows[0].now} color={f.other ? "var(--c-other)" : undefined} />, <b key="s">{fmtV(f.now)}</b>,
                      <span key="h" className="cx-muted">{fmtShare(pctOf(f.now, now))}</span>,
                      <span key="c" className={pc != null && pc > 0 ? "cx-up" : "cx-muted"}>{f.other ? "–" : pc == null ? "new" : signedPct(pc)}</span>],
                  };
                })}
                foot={fastest && pcOf(fastest[1].now, fastest[1].prev) != null && numOrZero(pcOf(fastest[1].now, fastest[1].prev)) > 0
                  ? <span className="cx-muted">{`${fastest[0]} grew fastest, ${signedPct(pcOf(fastest[1].now, fastest[1].prev))}.${live.length > 6 ? ` Other is ${fmtInt(live.length - 6)} smaller feature${live.length - 6 === 1 ? "" : "s"}.` : ""}`}</span> : undefined} />
            )}
          </PlCard>
        </div>
        <div id="sv-movers">
          <PlCard c={c0} open={open("sf_cost_serverless_features")} title="Biggest movers" subtitle={`Top ${fmtInt(movers.length)} objects by change vs previous ${fmtInt(p.filters.window)} days${movers.length && movers.every((m) => m.d > 0) ? " · all rose" : ""}`}>
            {() => !movers.length ? null : (
              <CxTable aria="Serverless spend change by object" phone={{ cols: [0, 2], widths: "minmax(0, 1fr) 64px" }} minWidth={400}
                cols={[{ label: "Object", width: "minmax(200px, 2.2fr)" }, { label: "", width: "minmax(50px, 1fr)" }, { label: "Change", width: "72px", num: true }]}
                rows={movers.map(({ r, d }) => ({
                  key: `${r.account_id}|${r.feature}|${r.object_id ?? r.object_name}`,
                  onOpen: openRow("sf_cost_serverless_features", "object_id", r.object_id, nameId(r.object_name, r.object_id)),
                  cells: [<span key="n"><FqnText text={nameId(r.object_name, r.object_id)} /><span className="cx-sub">{featureWord(r.feature)}</span></span>,
                    <CellBar key="b" value={Math.abs(d)} max={moveMax} color={d >= 0 ? "var(--c2)" : "var(--c3)"} />,
                    <b key="v" className={d >= 0 ? "cx-up" : undefined}>{signedV(d)}</b>],
                }))} />
            )}
          </PlCard>
        </div>
      </div>
      <PlCard c={c0} open={open("sf_cost_serverless_features")} title="Serverless objects, by spend" subtitle={`${fmtInt(objects.length)} objects · bars on one scale · open a row for its days and the fix`}>
        {() => (
          <ShowRows n={10} total={objRows.length} noun="more">{(k) => (
            <CxTable aria="Serverless objects by spend" phone={{ cols: [1, 3], widths: "minmax(0, 1fr) 64px" }} minWidth={820}
              cols={[{ label: "Flag", width: "92px" }, { label: "Object", width: "minmax(240px, 2fr)" }, { label: "Feature", width: "minmax(130px, 1fr)" }, { label: "Spend", width: "76px", num: true }, { label: "Vs prev.", width: "68px", num: true }, { label: "Share of top object", width: "minmax(110px, 1fr)" }]}
              rows={objRows.slice(0, k).map((r) => {
                const delta = val(r, nowCol) - val(r, prevCol);
                return {
                  key: `${r.account_id}|${r.feature}|${r.object_id ?? r.object_name}`,
                  onOpen: openRow("sf_cost_serverless_features", "object_id", r.object_id, nameId(r.object_name, r.object_id)),
                  cells: [<SevWord key="s" band={rowStatus(r)} />, <FqnText key="n" text={nameId(r.object_name, r.object_id)} />, featureWord(r.feature),
                    <b key="v">{fmtV(val(r, nowCol))}</b>, <span key="d" className={delta > 0.5 ? "cx-up" : "cx-muted"}>{signedV(delta)}</span>,
                    <CellBar key="b" value={val(r, nowCol)} max={objMax} />],
                };
              })} />
          )}</ShowRows>
        )}
      </PlCard>
    </div>
  );
};
PlServerlessFeature.ownsTiles = true;
(PlServerlessFeature as any).ownsLede = true;

const truthy = (v: any) => v === true || String(v).toLowerCase() === "true";
const falsy = (v: any) => v === false || String(v).toLowerCase() === "false";

export function PlServerlessClustering(p: ApPageProps) {
  const d = usePlData(p, ["sf_storage_clustering_key_mismatch", "sf_storage_clustering_value"]);
  const open = opener(p);
  const km = d.sf_storage_clustering_key_mismatch, cv = d.sf_storage_clustering_value;
  const cvTotal = usdSum(cv, cv.rows, "est_clustering_usd_list");
  const cvFlag = cv.rows.filter(isFlagged);
  const neverRead = cv.rows.filter((r) => numOrZero(r.read_queries) === 0 && numOrZero(r.clustering_credits) > 0);
  const worst = [...cvFlag].sort((a, b) => numOrZero(b.usd_per_read) - numOrZero(a.usd_per_read))[0];
  const kmTotal = usdSum(km, km.rows, "est_clustering_usd_list");
  const kmOff = km.rows.filter((r) => falsy(r.key_matches));
  const kmOffUsd = usdSum(km, kmOff, "est_clustering_usd_list");
  const keyOf = new Map(cv.rows.map((r) => [`${r.account_id}|${r.table_id}`, r.clustering_key]));
  const win = `${fmtInt(p.filters.window)} d`;

  const lede = cv.loading ? "…" : cv.priced && cvTotal > 0
    ? `${fmtShare(pctOf(usdSum(cv, cvFlag, "est_clustering_usd_list"), cvTotal))} of the ${usd0(cvTotal)} of automatic clustering lands on tables that are rarely read or clustered on the wrong key.${neverRead.length ? ` ${fmtInt(neverRead.length)} table${neverRead.length === 1 ? " was" : "s were"} re-sorted for nobody.` : ""}`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const cvMax = Math.max(1, ...cv.rows.map((r) => usd(cv, r, "est_clustering_usd_list")));
  const cvOk = cv.rows.filter((r) => rowStatus(r) === "OK");
  const kmOffN = km.rows.filter((r) => falsy(r.key_matches)).length;
  return (
    <div className="sx-page ac-page">
      <Tiles>
        <PlTile c={cv} open={scrollTo("sc-reads")} label="Clustering $ on flagged tables" make={(c) => {
          if (!c.priced) return { headline: null, missingReason: "No $/credit price in this export." };
          if (cvTotal <= 0) return null;
          const n = counts(c, "clustered tables");
          return {
            headline: fmtShare(pctOf(usdSum(c, cvFlag, "est_clustering_usd_list"), cvTotal)), unit: "of clustering $",
            base: `${usd0(usdSum(c, cvFlag, "est_clustering_usd_list"))} of ${usd0(cvTotal)} is on ${fmtInt(n.flagged)}${ofPop(n)} flagged · ${win}.`,
            cause: worst && num(worst.usd_per_read) !== null ? `Worst: ${nameId(worst.table_fqn, worst.table_id)}, ${usdRate(usd(c, worst, "usd_per_read"))} of re-sorting for each read.` : undefined,
            status: tileStatus(cvFlag), openLabel: "Cost vs reads ↓",
          };
        }} />
        <PlTile c={km} open={scrollTo("sc-key")} label="Clustering on a mismatched key" make={(c) => {
          if (!c.priced) return { headline: null, missingReason: "No $/credit price in this export." };
          if (kmTotal <= 0) return null;
          return {
            headline: fmtShare(pctOf(kmOffUsd, kmTotal)), unit: "of clustering $",
            base: `${usd0(kmOffUsd)} of ${usd0(kmTotal)} · ${fmtInt(kmOff.length)} of ${fmtInt(c.rows.length)} tables.`,
            cause: "The key is not the column most queries filter on, so the sort prunes nothing.", status: kmOff.length ? tileStatus(c.rows.filter(isFlagged)) : "ok", openLabel: "Key vs filter ↓",
          };
        }} />
        <PlTile c={cv} open={neverRead[0] ? openRow("sf_storage_clustering_value", "table_id", neverRead[0].table_id, nameId(neverRead[0].table_fqn, neverRead[0].table_id)) : open("sf_storage_clustering_value")} label="Reclustered, never read" make={(c) => c.rows.length ? {
          headline: fmtInt(neverRead.length), unit: `of ${fmtInt(c.rows.length)} tables`, status: neverRead.length ? tileStatus(neverRead) : "ok",
          base: neverRead.length ? `${[c.priced ? `${usd0(usdSum(c, neverRead, "est_clustering_usd_list"))} spend` : null, `0 reads in ${win}`].filter(Boolean).join(", ")}: ${nameId(neverRead[0].table_fqn, neverRead[0].table_id)}.` : "Every clustered table was read.",
          cause: neverRead.length ? "Suspend reclustering today: nothing benefits." : undefined, openLabel: neverRead.length ? "The fix →" : "Open check →",
        } : null} />
      </Tiles>
      <div id="sc-reads">
        <PlCard c={cv} open={open("sf_storage_clustering_value")} title="Clustering $ vs the reads that benefit"
          subtitle={`${fmtInt(cv.rows.length)} clustered tables, ${fmtInt(cvFlag.length)} flagged · what each pays to stay sorted, and what it gets back · open a table for its days`}>
          {(c) => (
            <CxTable aria="Clustering cost vs reads, by table" phone={{ cols: [1, 3, 6], widths: "minmax(0, 1fr) 56px 64px" }} minWidth={860}
              cols={[{ label: "Status", width: "92px" }, { label: "Table", width: "minmax(240px, 2fr)" }, { label: "Rewritten", width: "84px", num: true }, { label: `$ · ${win}`, width: "72px", num: true },
                { label: "", width: "minmax(80px, 1.2fr)" }, { label: "Reads", width: "60px", num: true }, { label: "$ per read", width: "80px", num: true }]}
              rows={[...c.rows].sort((a, b) => usd(c, b, "est_clustering_usd_list") - usd(c, a, "est_clustering_usd_list")).map((r) => {
                const v = usd(c, r, "est_clustering_usd_list");
                const reads = numOrZero(r.read_queries);
                const per = num(r.usd_per_read);
                return {
                  key: `${r.account_id}|${r.table_id}`,
                  onOpen: openRow("sf_storage_clustering_value", "table_id", r.table_id, nameId(r.table_fqn, r.table_id)),
                  cells: [<SevWord key="s" band={rowStatus(r)} />, <FqnText key="n" text={nameId(r.table_fqn, r.table_id)} />,
                    r.bytes_reclustered != null ? fmtBytes(r.bytes_reclustered) : "–",
                    <b key="v">{c.priced ? usd0(v) : `${fmtInt(r.clustering_credits)} cr`}</b>, <CellBar key="b" value={v} max={cvMax} />, fmtInt(reads),
                    reads === 0 ? <span key="p" className="cx-crit">No reads</span> : per !== null && c.priced ? usdRate(per * (1 - c.disc)) : "–"],
                };
              })}
              foot={c.priced && cvTotal > 0 ? <span className="cx-muted">{`Total ${usd0(cvTotal)} across ${fmtInt(c.rows.length)} tables.${cvOk.length ? ` ${cvOk.length === 1 ? "Only " : ""}${cvOk.map((r) => nameId(r.table_fqn, r.table_id)).slice(0, 3).join(", ")}${cvOk.length > 3 ? ` and ${fmtInt(cvOk.length - 3)} more` : ""} ${cvOk.length === 1 ? "earns its" : "earn their"} clustering.` : ""}`}</span> : undefined} />
          )}
        </PlCard>
      </div>
      <div id="sc-key">
        <PlCard c={km} open={open("sf_storage_clustering_key_mismatch")} title="Clustering key vs the column queries filter on"
          subtitle={`Top filter column from the WHERE and JOIN clauses of each table's queries · ${fmtInt(kmOffN)} of ${fmtInt(km.rows.length)} tables mismatched`}>
          {(c) => (
            <CxTable aria="Clustering key vs top filter column" phone={{ cols: [0, 3], widths: "minmax(0, 1fr) 84px" }} minWidth={760}
              cols={[{ label: "Table", width: "minmax(240px, 2fr)" }, { label: "Clustering key", width: "minmax(130px, 1fr)" }, { label: "Top filter", width: "minmax(120px, 1fr)" }, { label: "Key vs filter", width: "110px" }, { label: `$ · ${win}`, width: "76px", num: true }]}
              rows={[...c.rows].sort((a, b) => usd(c, b, "est_clustering_usd_list") - usd(c, a, "est_clustering_usd_list")).map((r) => {
                const key = keyOf.get(`${r.account_id}|${r.table_id}`);
                const verdict = truthy(r.key_matches) ? "match" : falsy(r.key_matches) ? "mismatch" : null;
                return {
                  key: `${r.account_id}|${r.table_id}`,
                  onOpen: openRow("sf_storage_clustering_key_mismatch", "table_id", r.table_id, nameId(r.table_fqn, r.table_id)),
                  cells: [<FqnText key="n" text={nameId(r.table_fqn, r.table_id)} />,
                    key ? <span key="k" className="cx-token cx-code">{String(key).replace(/^\(|\)$/g, "")}</span> : <span key="k" className="cx-muted">–</span>,
                    r.top_filter_column ? <span key="f" className="cx-token cx-code">{String(r.top_filter_column)}</span> : <span key="f" className="cx-muted">no filter data</span>,
                    verdict === "match" ? <span key="v" className="cx-sev cx-sev-ok"><span className="cx-sev-dot" aria-hidden="true" />Match</span>
                      : verdict === "mismatch" ? <span key="v" className="cx-sev cx-sev-warn"><span className="cx-sev-dot" aria-hidden="true" />Mismatch</span>
                      : <span key="v" className="cx-muted">–</span>,
                    <b key="u">{c.priced ? usd0(usd(c, r, "est_clustering_usd_list")) : `${fmtInt(r.clustering_credits)} cr`}</b>],
                };
              })} />
          )}
        </PlCard>
      </div>
    </div>
  );
};
PlServerlessClustering.ownsTiles = true;
(PlServerlessClustering as any).ownsLede = true;

export function PlServerlessMvso(p: ApPageProps) {
  const d = usePlData(p, ["sf_storage_mv_value", "sf_storage_search_optimization_value"]);
  const open = opener(p);
  const mv = d.sf_storage_mv_value, so = d.sf_storage_search_optimization_value;
  const win = `${fmtInt(p.filters.window)} d`;
  const mvFlag = mv.rows.filter(isFlagged), soFlag = so.rows.filter(isFlagged);
  const mvAll = usdSum(mv, mv.rows, "est_refresh_usd_list"), soAll = usdSum(so, so.rows, "est_search_optimization_usd_list");
  const pays = so.rows.filter((r) => !isFlagged(r) && numOrZero(r.scans_helped) > 0).sort((a, b) => numOrZero(b.scans_helped) - numOrZero(a.scans_helped));
  const perRead = (c: PlCheck, r: Row, col: string) => { const reads = numOrZero(r.read_queries); return reads > 0 ? usd(c, r, col) / reads : null; };
  const worstMv = [...mvFlag].sort((a, b) => numOrZero(perRead(mv, b, "est_refresh_usd_list")) - numOrZero(perRead(mv, a, "est_refresh_usd_list")))[0];

  const lede = mv.loading || so.loading ? "…" : mv.rows.length || so.rows.length
    ? [mv.rows.length ? `${fmtInt(mvFlag.length)} of ${fmtInt(mv.rows.length)} materialized views are refreshed more than they are read` : null,
      so.rows.length ? `${fmtInt(soFlag.length)} of ${fmtInt(so.rows.length)} search-optimized tables are barely used` : null].filter(Boolean).join(", and ") + "."
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const mvCol = mv.priced ? "est_refresh_usd_list" : "refresh_credits";
  const soCol = so.priced ? "est_search_optimization_usd_list" : "search_optimization_credits";
  const mvV = (r: Row) => (mv.priced ? usd(mv, r, mvCol) : numOrZero(r[mvCol]));
  const soV = (r: Row) => (so.priced ? usd(so, r, soCol) : numOrZero(r[soCol]));
  const mvSorted = mv.rows.filter((r) => numOrZero(r[mvCol]) > 0).sort((a, b) => mvV(b) - mvV(a));
  const soSorted = so.rows.filter((r) => numOrZero(r[soCol]) > 0).sort((a, b) => soV(b) - soV(a));
  const money = (c: PlCheck, v: number) => (c.priced ? usd0(v) : `${fmtInt(v)} cr`);
  const perReadText = (c: PlCheck, v: number, reads: number) => (reads > 0 && c.priced ? usdRate(v / reads) : "–");
  return (
    <div className="sx-page ac-page">
      <Tiles>
        <PlTile c={mv} open={scrollTo("sm-mv")} label="MVs refreshed more than read" make={(c) => c.rows.length ? {
          headline: fmtInt(mvFlag.length), unit: `of ${fmtInt(c.rows.length)} materialized views`, status: tileStatus(mvFlag),
          base: c.priced ? `${usd0(usdSum(c, mvFlag, "est_refresh_usd_list"))} of the ${usd0(mvAll)} spent on MV refresh · ${win}.` : `${fmtInt(mvFlag.length)} flagged.`,
          cause: worstMv ? `Worst: ${nameId(worstMv.mv_fqn || worstMv.mv_name, worstMv.mv_id)}, refreshed ${fmtInt(worstMv.refreshes)} times for ${fmtInt(worstMv.read_queries)} reads.` : undefined,
          openLabel: "MV refresh vs reads ↓",
        } : null} />
        <PlTile c={so} open={scrollTo("sm-so")} label="Search optimization, little use" make={(c) => c.rows.length ? {
          headline: fmtInt(soFlag.length), unit: `of ${fmtInt(c.rows.length)} tables`, status: tileStatus(soFlag),
          base: c.priced ? `${usd0(usdSum(c, soFlag, "est_search_optimization_usd_list"))} of the ${usd0(soAll)} spent on search optimization · ${win}.` : `${fmtInt(soFlag.length)} flagged.`,
          cause: soFlag[0] ? `${nameId(soFlag[0].table_fqn, soFlag[0].table_id)}: ${fmtInt(soFlag[0].scans_helped)} scans helped in ${fmtInt(soFlag[0].read_queries)} reads.` : undefined,
          openLabel: "Search optimization vs reads ↓",
        } : null} />
        <PlTile c={so} open={pays[0] ? openRow("sf_storage_search_optimization_value", "table_id", pays[0].table_id, nameId(pays[0].table_fqn, pays[0].table_id)) : open("sf_storage_search_optimization_value")} label="Search optimization that pays" make={(c) => c.rows.length ? {
          headline: fmtInt(pays.length), unit: `of ${fmtInt(c.rows.length)} tables`, status: "neutral",
          base: pays[0] ? `${nameId(pays[0].table_fqn, pays[0].table_id)}: ${fmtInt(pays[0].scans_helped)} scans helped.` : "No table had a scan helped.",
          cause: pays[0] && c.priced && perRead(c, pays[0], "est_search_optimization_usd_list") != null ? `${usd0(usd(c, pays[0], "est_search_optimization_usd_list"))} in ${win}, or ${usdRate(perRead(c, pays[0], "est_search_optimization_usd_list")!)} a read.` : undefined,
          openLabel: "Compare →",
        } : null} />
      </Tiles>
      <div id="sm-mv">
        <PlCard c={mv} open={open("sf_storage_mv_value")} title="MV refresh $ vs reads"
          subtitle={`${mvSorted.length > 10 ? `Top 10 of ${fmtInt(mvSorted.length)}` : `All ${fmtInt(mvSorted.length)}`} materialized views by refresh $ · ${fmtInt(mvFlag.length)} flagged · open a row for its days and the fix`}>
          {(c) => !mvSorted.length ? null : (
            <ShowRows n={10} total={mvSorted.length}>{(k) => (
              <CxTable aria="MV refresh cost vs reads" phone={{ cols: [1, 2, 5], widths: "minmax(0, 1fr) 52px 56px" }} minWidth={880}
                cols={[{ label: "Status", width: "92px" }, { label: "Materialized view", width: "minmax(240px, 2fr)" }, { label: `$ · ${win}`, width: "72px", num: true }, { label: "", width: "minmax(80px, 1fr)" },
                  { label: "Reads", width: "60px", num: true }, { label: "$ per read", width: "80px", num: true }, { label: "Why", width: "minmax(170px, 1.2fr)" }]}
                rows={mvSorted.slice(0, k).map((r) => {
                  const v = mvV(r), reads = numOrZero(r.read_queries);
                  const name = nameId(r.mv_fqn || r.mv_name, r.mv_id);
                  return {
                    key: `${r.account_id}|${r.mv_id ?? name}`,
                    onOpen: openRow("sf_storage_mv_value", "mv_id", r.mv_id, name),
                    cells: [<SevWord key="s" band={rowStatus(r)} />, <FqnText key="n" text={name} />, <b key="v">{money(c, v)}</b>, <CellBar key="b" value={v} max={mvV(mvSorted[0])} />,
                      fmtInt(reads), perReadText(c, v, reads),
                      <span key="w" className="cx-muted">{!isFlagged(r) ? "–" : reads === 0 ? "Never read" : `Refreshed ${fmtInt(r.refreshes)} times, read ${fmtInt(reads)}`}</span>],
                  };
                })} />
            )}</ShowRows>
          )}
        </PlCard>
      </div>
      <div id="sm-so">
        <PlCard c={so} open={open("sf_storage_search_optimization_value")} title="Search optimization $ vs reads"
          subtitle={`${soSorted.length > 10 ? `Top 10 of ${fmtInt(soSorted.length)}` : `All ${fmtInt(soSorted.length)}`} search-optimized tables by maintenance $ · ${fmtInt(soFlag.length)} flagged · scans helped = scans search optimization actually sped up`}>
          {(c) => !soSorted.length ? null : (
            <ShowRows n={10} total={soSorted.length}>{(k) => (
              <CxTable aria="Search optimization cost vs reads" phone={{ cols: [1, 2, 6], widths: "minmax(0, 1fr) 52px 84px" }} minWidth={880}
                cols={[{ label: "Status", width: "92px" }, { label: "Table", width: "minmax(240px, 2fr)" }, { label: `$ · ${win}`, width: "72px", num: true }, { label: "", width: "minmax(80px, 1fr)" },
                  { label: "Reads", width: "60px", num: true }, { label: "$ per read", width: "80px", num: true }, { label: "Scans helped", width: "minmax(130px, 1fr)" }]}
                rows={soSorted.slice(0, k).map((r) => {
                  const v = soV(r), reads = numOrZero(r.read_queries), helped = numOrZero(r.scans_helped);
                  const name = nameId(r.table_fqn, r.table_id);
                  return {
                    key: `${r.account_id}|${r.table_id ?? name}`,
                    onOpen: openRow("sf_storage_search_optimization_value", "table_id", r.table_id, name),
                    cells: [<SevWord key="s" band={rowStatus(r)} />, <FqnText key="n" text={name} />, <b key="v">{money(c, v)}</b>, <CellBar key="b" value={v} max={soV(soSorted[0])} />,
                      fmtInt(reads), perReadText(c, v, reads),
                      <span key="h" className={helped > 0 ? undefined : "cx-muted"}>{helped > 0 ? fmtInt(helped) : reads === 0 ? "None · never read" : "None"}</span>],
                  };
                })} />
            )}</ShowRows>
          )}
        </PlCard>
      </div>
    </div>
  );
};
PlServerlessMvso.ownsTiles = true;
(PlServerlessMvso as any).ownsLede = true;
