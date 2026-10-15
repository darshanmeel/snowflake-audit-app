// web/src/tabs/tab_overview_de.tsx -- the Data engineer's Overview: four tiles (failed task runs,
// median task duration, time queued for a slot, credits per day; a sparkline where a daily series
// exists), warehouse load over the window and the top query patterns. Every figure is a check's own;
// a check that did not run reads "–" and why, "…" while loading. Spend is context, never added to waste.
import React from "react";
import { fmtDayShort, fmtDuration, fmtInt, fmtMoney } from "../format";
import { IgnoredFilterTracker, fillDays, numOrZero, totalSpikeDays, useFindingAgg, useFindingData } from "../components/hooks";
import { FreshnessLine, PageFooter, PageIntro, PatternCard, StatusPill, bandOf, pageEyebrow } from "../components/primitives";
import { useNames } from "../components/names";
import { IssueTile, fmtShare, pctOf } from "../components/blocks";
import { QueryPatternTable, WarehouseLoadBands, aggNote, useQueryPatterns, useWarehouseLoad, whNameId } from "../components/de_blocks";
import { TaskStateBands, useTaskRunDays, windowDayList } from "../components/run_blocks";
import { withoutTotalRows } from "./tab_area";
import { ChecksRanStrip, OV_CREDITS, OV_TOTAL_CREDITS, OV_USD, fillGaps, pickNum, sumPick } from "./tab_overview";
import type { FetchState, Filters, Finding, GoToFn, Meta, Row } from "../types";

type Sev = "critical" | "warn" | "ok" | "not_assessed" | "neutral";
function sevOf(f: Finding | undefined): Sev {
  if (!f) return "not_assessed";
  const b = bandOf(f);
  if (b === "NOT_ASSESSED" || b === "ERROR") return "not_assessed";
  if (b === "CRITICAL") return "critical";
  if (b === "WARN") return "warn";
  return "ok";
}
const okRows = (s: FetchState) => s.phase === "ready" && s.outcome === "ok_rows";
const settled = (s: FetchState) => s.phase !== "loading";
const isFlagged = (r: Row) => r.status === "CRITICAL" || r.status === "WARN";
const signed = (v: number) => `${v >= 0 ? "+" : "−"}${fmtShare(Math.abs(v))}`;

export function DeOverview({ filters, meta, findingsById, goTo, role }: {
  filters: Filters; meta: Meta | null; findingsById: Record<string, Finding> | null; goTo: GoToFn; role: string | null;
}) {
  useNames();
  React.useEffect(() => { IgnoredFilterTracker.reset(); }, []);
  const acct = filters.accountIds, win = filters.window;
  const byId: Record<string, Finding> = findingsById || {};
  const findingsReady = Object.keys(byId).length > 0;
  // Why a tile has no figure: the check is missing or did not run, its fetch says why, or it ran and found nothing.
  const why = (id: string | null, s: FetchState, ranEmpty: string): string | undefined => {
    if (id && findingsReady) {
      const f = byId[id];
      if (!f) return "not in this export";
      if (["NOT_ASSESSED", "ERROR"].includes(bandOf(f))) return (f.not_assessed && f.not_assessed.label) || "did not run";
    }
    if (okRows(s)) return ranEmpty;
    const n = aggNote(s, meta, win);
    return n ? n.replace(/^– /, "").replace(/^Not assessed: /, "") : undefined;
  };

  const failState = useFindingData("sf_task_failures", win, acct, 5000);
  const slowState = useFindingData("sf_task_duration_regression", win, acct, 5000);
  const trendState = useFindingData("overview_daily_credits_trend", win, acct, 5000);
  const spendState = useFindingData("overview_spend_estimate", win, acct, 500);
  const curAgg = useFindingAgg("cost_period_over_period", win, acct, [], "sum", "est_current_usd_list");
  const prevAgg = useFindingAgg("cost_period_over_period", win, acct, [], "sum", "est_previous_usd_list");
  const qDay = useFindingAgg("query_queuing_waits", win, acct, ["day"], "sum", "waiting_at_capacity_ms_sum");
  const load = useWarehouseLoad(filters);
  const taskDays = useTaskRunDays(filters);
  const pat = useQueryPatterns(filters, 8);

  // Failed task runs, from the task check's own rows.
  const fRows = okRows(failState) ? withoutTotalRows(failState.data!.rows).filter((r) => r.status !== "NOT_ASSESSED") : null;
  const runs = fRows ? fRows.reduce((s, r) => s + numOrZero(r.runs), 0) : 0;
  const failed = fRows ? fRows.reduce((s, r) => s + numOrZero(r.failed_runs), 0) : 0;
  const tfAff = byId.sf_task_failures && byId.sf_task_failures.affected;
  // Failed runs per day, every day of the window kept, from the per-day check.
  const fDays = taskDays.data ? windowDayList(meta, win, taskDays.data.seen).map((day) => ({ day, value: taskDays.data!.failedByDay.get(day) || 0 })) : null;
  const fSpikes = fDays ? new Set(totalSpikeDays(fDays).map((s) => s.day)) : new Set<string>();
  const fWorst = fDays && fDays.length ? fDays.reduce((a, b) => (b.value > a.value ? b : a)) : null;

  // Median task duration: the middle task's change in median run time, of tasks that ran in both periods.
  const sRows = okRows(slowState) ? withoutTotalRows(slowState.data!.rows).filter((r) => r.status !== "NOT_ASSESSED") : null;
  const growth = (sRows || []).filter((r) => numOrZero(r.prev_p50_duration_seconds) > 0 && r.p50_duration_seconds != null)
    .map((r) => (numOrZero(r.p50_duration_seconds) / numOrZero(r.prev_p50_duration_seconds) - 1) * 100).sort((a, b) => a - b);
  const medianGrowth = growth.length ? (growth.length % 2 ? growth[(growth.length - 1) / 2] : (growth[growth.length / 2 - 1] + growth[growth.length / 2]) / 2) : null;
  const slower = (sRows || []).filter((r) => isFlagged(r) && numOrZero(r.p50_growth_pct) > 0);
  const twice = slower.filter((r) => numOrZero(r.p50_growth_pct) >= 100).length;
  const sdAff = byId.sf_task_duration_regression && byId.sf_task_duration_regression.affected;
  const taskBase = sdAff && sdAff.total ? sdAff.total : sRows ? sRows.length : null;

  // Queued for a slot: per day (zero days kept, today left out) and the warehouse with most of it.
  const qDays = okRows(qDay) ? fillDays((qDay.data!.groups || []).filter((g: Row) => g.key && g.key[0]).map((g: Row) => ({ day: String(g.key[0]).slice(0, 10), value: numOrZero(g.value) / 1000 })),
    meta && meta.as_of_date, win, meta && meta.snapshot_days) : null;
  const qTotal = okRows(qDay) ? numOrZero(qDay.data!.total_value) / 1000 : null;
  const qGroups: { id: any; s: number }[] = okRows(load.queue) ? (load.queue.data!.groups || []).map((g: Row) => ({ id: g.key && g.key[0], s: numOrZero(g.value) / 1000 })).filter((g: { s: number }) => g.s > 0) : [];
  const qTop = qGroups.sort((a, b) => b.s - a.s)[0];
  const qSpikes = qDays ? new Set(totalSpikeDays(qDays).map((s) => s.day)) : new Set<string>();

  // Credits per day: the same daily series and spend the Cost pages read.
  const partialDay = (meta && meta.cost_cutoff && meta.cost_cutoff.partial_day) || null;
  const trendRows = okRows(trendState) ? trendState.data!.rows : null;
  const daily = React.useMemo(() => {
    if (!trendRows) return null;
    const m = new Map<string, number>();
    withoutTotalRows(trendRows).forEach((r) => {
      const d = String(r.usage_date || "").slice(0, 10);
      const v = pickNum(r, OV_CREDITS);
      if (d && v !== null) m.set(d, (m.get(d) || 0) + v);
    });
    return fillGaps(m);
  }, [trendRows]);
  const fullDays = daily ? daily.filter((d) => d.day !== partialDay) : null;
  const perDay = fullDays && fullDays.length ? fullDays.reduce((s, d) => s + d.value, 0) / fullDays.length : null;
  const cSpikes = fullDays ? new Set(totalSpikeDays(fullDays).map((s) => s.day)) : new Set<string>();
  const spendRows = okRows(spendState) ? spendState.data!.rows : null;
  const credits = spendRows ? sumPick(spendRows, OV_TOTAL_CREDITS) : null;
  const usdRaw = spendRows ? sumPick(spendRows, OV_USD) : null;
  const usd = usdRaw != null ? usdRaw * (1 - numOrZero(spendState.data && spendState.data.discount_pct)) : null;
  const cur = okRows(curAgg) ? numOrZero(curAgg.data!.total_value) : null;
  const prev = okRows(prevAgg) ? numOrZero(prevAgg.data!.total_value) : null;
  const changePct = cur != null && prev != null && prev > 0 ? ((cur - prev) / prev) * 100 : null;

  const allSettled = findingsReady && settled(failState) && settled(slowState) && settled(qDay);
  const lede = !allSettled ? "…" : [
    runs > 0 ? `${fmtShare(pctOf(failed, runs))} of task runs failed` : null,
    taskBase ? `${fmtInt(slower.length)} of ${fmtInt(taskBase)} tasks got slower` : null,
    qTotal != null && qTotal > 0 ? `queries waited ${fmtDuration(qTotal)} for a warehouse slot${qTop ? `, most on ${whNameId(qTop.id).name}` : ""}` : null,
  ].filter(Boolean).join("; ").replace(/^./, (c) => c.toUpperCase()).concat(".").replace(/^\.$/, "Pipelines and queries could not be assessed for this export.");

  const goTasks = (sub: string) => () => goTo({ tab: "tasks", subtab: sub });
  const sparkOf = (days: { day: string; value: number }[] | null, spikes: Set<string>) =>
    days && days.length >= 2 ? { spark: days.map((d) => d.value), sparkAnomalies: days.map((d, i) => (spikes.has(d.day) ? i : -1)).filter((i) => i >= 0) } : {};

  return (
    <div>
      <PageIntro overline={pageEyebrow(role, "Overview", meta, win)} title="Overview" verdict={lede} />
      <FreshnessLine findingsById={byId} goTo={goTo} />
      <div className="summary-tile-row cto-tiles">
        <IssueTile label="Failed task runs" loading={!findingsReady || failState.phase === "loading"} status={sevOf(byId.sf_task_failures)}
          headline={runs > 0 ? fmtShare(pctOf(failed, runs)) : null} unit="of runs"
          missingReason={why("sf_task_failures", failState, "no task ran in this window")}
          base={runs > 0 ? `${fmtInt(failed)} of ${fmtInt(runs)} runs${tfAff && tfAff.total ? ` · ${fmtInt(tfAff.flagged)} of ${fmtInt(tfAff.total)} ${tfAff.noun}` : ""}` : null}
          cause={runs > 0 ? `About ${fmtInt(Math.round(failed / Math.max(1, win)))} failed runs a day${fWorst && fWorst.value > 0 ? `; worst ${fmtDayShort(fWorst.day)}: ${fmtInt(fWorst.value)}` : ""}.` : null}
          {...sparkOf(fDays, fSpikes)}
          onOpen={goTasks("failures")} openLabel="Tasks › Failures →" />
        <IssueTile label="Median task duration" loading={!findingsReady || slowState.phase === "loading"} status={sevOf(byId.sf_task_duration_regression)}
          headline={medianGrowth != null ? signed(medianGrowth) : null} unit={`vs previous ${fmtInt(win)} days`}
          missingReason={why("sf_task_duration_regression", slowState, "no task ran in both periods")}
          base={taskBase ? `${fmtInt(slower.length)} of ${fmtInt(taskBase)} tasks slower · ${fmtInt(twice)} by more than 2×` : null}
          onOpen={goTasks("cost")} openLabel="Tasks › Cost & timing →" />
        <IssueTile label="Queued for a slot" loading={!findingsReady || qDay.phase === "loading"} status={sevOf(byId.query_queuing_waits)}
          headline={qTotal != null ? fmtDuration(qTotal) : null} unit={`in ${fmtInt(win)} days`}
          missingReason={why("query_queuing_waits", qDay, "no queries in this window")}
          base={qTotal != null ? `${fmtDuration(qTotal / Math.max(1, win))} / day${qTop && qTotal > 0 ? ` · ${whNameId(qTop.id).name} (${qTop.id}) ${fmtShare(pctOf(qTop.s, qTotal))}` : ""}` : null}
          {...sparkOf(qDays, qSpikes)}
          onOpen={() => goTo({ tab: "queries", subtab: "waiting" })} openLabel="Queries › Waiting →" />
        <IssueTile label="Credits per day" loading={trendState.phase === "loading" || spendState.phase === "loading"} status="neutral" pill={<StatusPill kind="neutral" />}
          headline={perDay != null ? fmtInt(Math.round(perDay)) : null} unit="credits / day"
          missingReason={why(null, trendState, "no usage in this window")}
          base={perDay != null ? [credits != null ? `${fmtInt(Math.round(credits))} credits` : null, usd != null ? fmtMoney(usd, 0) : null,
            changePct != null ? `${signed(changePct)} $ vs previous` : null].filter(Boolean).join(" · ") : null}
          cause={cSpikes.size ? `${fmtInt(cSpikes.size)} day${cSpikes.size === 1 ? "" : "s"} above the week before (dots).` : partialDay ? "Today is partial and left out." : null}
          {...sparkOf(fullDays, cSpikes)}
          onOpen={() => goTo({ tab: "cost" })} openLabel="Cost →" />
      </div>

      <PatternCard title={`Pipelines · state over ${fmtInt(win)} days`} sub="Each task's days: ran OK, failed, ran slow or no run · most failed runs first"
        link="Tasks › Failures →" onLink={goTasks("failures")}>
        <TaskStateBands load={taskDays} meta={meta} filters={filters} n={6} onRow={goTasks("failures")} />
      </PatternCard>

      <PatternCard title={`Warehouses · load over ${fmtInt(win)} days`} sub="Each day split busy, busy with queries queued, idle but billed, and not running · most queued first"
        link="Warehouses › Load & scaling →" onLink={() => goTo({ tab: "warehouses", subtab: "load" })}>
        <WarehouseLoadBands load={load} meta={meta} filters={filters} n={6} onRow={() => goTo({ tab: "warehouses", subtab: "load" })} />
      </PatternCard>

      <PatternCard title={`Query patterns · last ${fmtInt(win)} days`} sub="Statements grouped by shape; the SQL text is never shown · sort any column"
        link={pat.shapes != null ? `All ${fmtInt(pat.shapes)} shapes →` : "Queries › Heavy →"} onLink={() => goTo({ tab: "queries", subtab: "heavy" })}>
        {pat.rows && pat.rows.length
          ? <QueryPatternTable rows={pat.rows} n={8} onOpen={() => goTo({ tab: "queries", subtab: "heavy", focusQueryId: "query_top_by_cost" })} />
          : <div className="chart-note-oneline">{aggNote(pat.state, meta, win, !findingsReady || !!byId.query_top_by_cost) || "No statement cost in this window."}</div>}
      </PatternCard>

      <ChecksRanStrip meta={meta} byId={byId} goTo={goTo} />
      <PageFooter meta={meta} />
    </div>
  );
}
