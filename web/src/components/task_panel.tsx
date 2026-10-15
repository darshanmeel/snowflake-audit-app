// web/src/components/task_panel.tsx -- the task focus panel: clicking a task name anywhere (any
// <Ref kind="task">) opens this right-hand drawer with what the existing task checks already say
// about that one task. Each check is scoped server-side (job_id = the task's full name), so every
// row that comes back is this task's own. A check that did not run reads "–" with why, never a
// clean zero. Mounted once by App.tsx; the open task lives in the URL hash (task=<full name>).

// The checks that carry a task column and answer this panel's questions.
import React from "react";
import { Api } from "../api";
import { fmtCredits, fmtDuration, fmtInt, fmtMoney } from "../format";
import { CopyLinkButton } from "./hash_state";
import { Names, SnowLink, TaskFocus, acctPhrase, resolveName, useNames } from "./names";
import { fmtChangePct, numOrZero } from "./hooks";
import { ErrorBoundary, StatusPill } from "./primitives";
import { enumLabel } from "./labels";
import { HBarList } from "./charts";
import { notAssessedText } from "./scope";
import { rankOfStatus } from "./finding_detail";
import type { Row } from "../types";

/** The task checks' responses, by check id. */
export type TaskPanelById = Record<string, any>;

export const TASK_PANEL_IDS = [
  "sf_task_failures", "sf_task_cost", "sf_task_duration_regression", "sf_task_silent_failures",
  "sf_task_skipped_overlaps", "sf_task_suspended_or_stale", "sf_task_warehouse_vs_serverless",
  "sf_task_graph_health",
];

export const TASK_PANEL_CHECK_NAMES: Record<string, string> = {
  sf_task_failures: "Failures",
  sf_task_cost: "Cost",
  sf_task_duration_regression: "Run time",
  sf_task_silent_failures: "Failure alerts and setup",
  sf_task_skipped_overlaps: "Skipped runs",
  sf_task_suspended_or_stale: "Suspended or stale",
  sf_task_warehouse_vs_serverless: "Warehouse or serverless",
  sf_task_graph_health: "Task graph",
};

export const TASK_PANEL_FINDING_TEXT: Record<string, string> = {
  auto_suspended_after_failures: "Snowflake suspended this task after repeated failures",
  started_but_not_running: "started but has not run recently",
  suspended_stale: "has been suspended for a long time",
  never_ran: "was created and never resumed",
  silent_failures: "fails with no error integration or finalizer, so no one is told",
  execute_as_user_gone: "runs as a user who is disabled or gone",
  admin_owner: "is owned by an admin role",
  allow_all_overlap: "may start a second copy while one is running",
};

export function useTaskPanelData(accountId: any, taskId: any, windowDays: number) {
  const key = `${accountId}|${taskId}|${windowDays}`;
  const [state, setState] = React.useState<{ phase: string; byId: TaskPanelById }>({ phase: "loading", byId: {} });
  React.useEffect(() => {
    let cancelled = false;
    setState({ phase: "loading", byId: {} });
    if (taskId === undefined || taskId === null || taskId === "") return undefined;
    const accounts = accountId === null || accountId === undefined ? [] : [accountId];
    Promise.all(TASK_PANEL_IDS.map((id) =>
      Api.finding(id, windowDays, accounts, 50, 0, taskId)
        .then((d: any) => [id, d])
        .catch((e: any) => [id, { outcome: "error", error: e.message || String(e), header: {} }])
    )).then((pairs) => {
      if (cancelled) return;
      const byId: TaskPanelById = {};
      pairs.forEach(([id, d]: any[]) => { byId[id] = d; });
      setState({ phase: "ready", byId });
    });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return state;
}

export function taskPanelRow(data: Row | null | undefined): Row | null {
  if (!data || data.outcome !== "ok_rows" || !data.rows || !data.rows.length) return null;
  return data.rows[0];
}

// Why a check has no row for this task: "–" plus the reason, never a zero.
export function taskPanelGap(data: Row | null | undefined) {
  if (!data) return "not loaded";
  if (data.outcome === "not_assessed") return notAssessedText(data);
  if (data.outcome === "error") return "the check failed";
  return "no row for this task in this window";
}

export function taskPanelNum(v: any) { return v === null || v === undefined || v === "" ? null : Number(v); }

// The worst status across the checks that ran for this task; NOT_ASSESSED only when none did.
export function taskPanelStatus(byId: TaskPanelById) {
  let best: any = null;
  TASK_PANEL_IDS.forEach((id) => {
    const row = taskPanelRow(byId[id]);
    if (!row || !row.status || row.status === "NOT_ASSESSED") return;
    const r = rankOfStatus(row.status);
    if (r !== undefined && (best === null || r < rankOfStatus(best)!)) best = row.status;
  });
  return best;
}

export function TaskPanelKpis({ byId, windowDays }: { byId: TaskPanelById; windowDays: number }) {
  const fail = taskPanelRow(byId.sf_task_failures);
  const cost = taskPanelRow(byId.sf_task_cost);
  const dur = taskPanelRow(byId.sf_task_duration_regression);
  const failTitle = fail ? undefined : taskPanelGap(byId.sf_task_failures);
  const costOk = cost && cost.est_task_usd_list != null && cost.price_basis !== "unpriced";
  const costUsd = numOrZero(cost && cost.est_task_usd_list) * (1 - numOrZero(byId.sf_task_cost && byId.sf_task_cost.discount_pct));
  const costTitle = costOk ? undefined : (cost ? "No $/credit price in this export" : taskPanelGap(byId.sf_task_cost));
  const p50 = dur ? taskPanelNum(dur.p50_duration_seconds) : null;
  return (
    <div className="jrp-kpis">
      <div className="jrp-kpi" title={failTitle}>
        <span className="jrp-kpi-label">{`Failed, ${windowDays}d`}</span>
        <span className={`jrp-kpi-value ${fail && fail.failed_runs > 0 ? "crit" : ""}`}>
          {fail ? `${fmtInt(fail.failed_runs)} of ${fmtInt(fail.runs)} runs` : "–"}
        </span>
      </div>
      <div className="jrp-kpi" title={failTitle}>
        <span className="jrp-kpi-label">In a row, now</span>
        <span className={`jrp-kpi-value ${fail && fail.consecutive_failures > 0 ? "crit" : ""}`}>
          {fail ? fmtInt(fail.consecutive_failures) : "–"}
        </span>
      </div>
      <div className="jrp-kpi" title={costTitle}>
        <span className="jrp-kpi-label">{`Cost, ${windowDays}d`}</span>
        <span className="jrp-kpi-value">{costOk ? fmtMoney(costUsd, 0) : "–"}</span>
      </div>
      <div className="jrp-kpi" title={dur ? undefined : taskPanelGap(byId.sf_task_duration_regression)}>
        <span className="jrp-kpi-label">Median run</span>
        <span className="jrp-kpi-value">{p50 != null ? fmtDuration(p50) : "–"}</span>
      </div>
    </div>
  );
}

// Run outcomes and run time as ranked bars (the existing HBarList), no new chart type.
export function TaskPanelRunsChart({ byId }: { byId: TaskPanelById }) {
  const fail = taskPanelRow(byId.sf_task_failures);
  const dur = taskPanelRow(byId.sf_task_duration_regression);
  if (!fail && !dur) {
    return <div className="jrp-gap-note">{`–  ${taskPanelGap(byId.sf_task_failures)}`}</div>;
  }
  const outcomeItems = fail ? [
    { name: "Succeeded", value: numOrZero(fail.succeeded_runs), color: "var(--st-ok)" },
    { name: "Failed", value: numOrZero(fail.failed_runs), color: "var(--st-crit)" },
    { name: "Cancelled", value: numOrZero(fail.cancelled_runs), color: "var(--text-faint)" },
    { name: "Skipped", value: numOrZero(fail.skipped_runs), color: "var(--text-faint)" },
  ].filter((i) => i.value > 0) : [];
  const timeItems = dur ? [
    { name: "Median run, before", value: taskPanelNum(dur.prev_p50_duration_seconds), color: "var(--text-faint)" },
    { name: "Median run, now", value: taskPanelNum(dur.p50_duration_seconds), color: "var(--c1)" },
    { name: "Slowest 10%, before", value: taskPanelNum(dur.prev_p90_duration_seconds), color: "var(--text-faint)" },
    { name: "Slowest 10%, now", value: taskPanelNum(dur.p90_duration_seconds), color: "var(--c1)" },
  ].filter((i) => i.value != null) : [];
  return (
    <React.Fragment>
      {outcomeItems.length > 0 && <HBarList items={outcomeItems} valueFmt={(v: number | null) => `${fmtInt(v)} runs`} />}
      {timeItems.length > 0 && <div style={{ marginTop: 8 }}><HBarList items={timeItems} valueFmt={(v: number | null) => fmtDuration(v)} /></div>}
      {!dur && <div className="jrp-gap-note" style={{ marginTop: 6 }}>{`Run time: –  ${taskPanelGap(byId.sf_task_duration_regression)}`}</div>}
    </React.Fragment>
  );
}

// Failure causes from the failure, silent-failure, suspended and skipped-run checks, one line each.
export function taskPanelProblems(byId: TaskPanelById) {
  const out: { text: any; detail?: string | null }[] = [];
  const fail = taskPanelRow(byId.sf_task_failures);
  if (fail && fail.failed_runs > 0) {
    out.push({
      text: fail.failure_reason || `${fmtInt(fail.failed_runs)} of ${fmtInt(fail.runs)} runs failed`,
      detail: fail.last_error_code ? `Error code ${fail.last_error_code}` : null,
    });
  }
  // A root task whose graph was stopped by another task in it: name that task and its error code,
  // which say more than this task's own runs (its own failures are above).
  const graph = taskPanelRow(byId.sf_task_graph_health);
  const graphBad = graph ? numOrZero(graph.failed_runs) + numOrZero(graph.cancelled_runs) : 0;
  const firstTask = graph ? graph.last_first_error_task_name : null;
  if (graph && graphBad > 0 && firstTask && String(firstTask).toUpperCase() !== String(graph.root_task_name || "").toUpperCase()) {
    out.push({
      text: `${fmtInt(graphBad)} of ${fmtInt(graph.runs)} runs of this task's graph failed or were cancelled; the latest stopped at task ${firstTask}.`,
      detail: graph.last_first_error_code ? `Error code ${graph.last_first_error_code}` : null,
    });
  }
  const silent = taskPanelRow(byId.sf_task_silent_failures);
  if (silent && silent.finding && silent.finding !== "ok") {
    out.push({ text: `This task ${TASK_PANEL_FINDING_TEXT[silent.finding] || enumLabel(silent.finding)}.` });
  }
  const susp = taskPanelRow(byId.sf_task_suspended_or_stale);
  if (susp && susp.finding && susp.finding !== "ok") {
    out.push({
      text: `This task ${TASK_PANEL_FINDING_TEXT[susp.finding] || enumLabel(susp.finding)}.`,
      detail: susp.finding === "auto_suspended_after_failures" && susp.last_error_code ? `Error code ${susp.last_error_code}` : null,
    });
  }
  const skip = taskPanelRow(byId.sf_task_skipped_overlaps);
  if (skip && numOrZero(skip.overlap_skips) > 0) out.push({ text: skip.skip_reason });
  return out;
}

export function TaskPanelProblems({ byId }: { byId: TaskPanelById }) {
  const items = taskPanelProblems(byId);
  if (!items.length) return null;
  return (
    <div>
      <div className="jrp-section-head"><h3 className="jrp-section-title">What is going wrong</h3></div>
      <ul className="jrp-fail-groups">
        {items.map((p, i) => (
          <li key={i}>
            {p.text}
            {p.detail && <div className="jrp-sql-error">{p.detail}</div>}
          </li>
        ))}
      </ul>
    </div>
  );
}

// What changed against the window before. The $ change is a change, never added to the spend above.
export function TaskPanelChanges({ byId }: { byId: TaskPanelById }) {
  const dur = taskPanelRow(byId.sf_task_duration_regression);
  const cost = taskPanelRow(byId.sf_task_cost);
  const rows: { attr: string; diff: string; changed: boolean }[] = [];
  if (dur && dur.prev_p50_duration_seconds != null && dur.p50_duration_seconds != null) {
    rows.push({
      attr: "Median run time",
      diff: `${fmtDuration(dur.prev_p50_duration_seconds)} → ${fmtDuration(dur.p50_duration_seconds)}`
        + (dur.p50_growth_pct != null ? ` (${fmtChangePct(dur.p50_growth_pct)})` : ""),
      changed: dur.status === "WARN" || dur.status === "CRITICAL",
    });
    if (dur.definition_changed_recently != null) {
      rows.push({
        attr: "Task definition",
        diff: dur.definition_changed_recently ? "changed in the last two windows" : "not changed recently",
        changed: !!dur.definition_changed_recently,
      });
    }
  }
  if (cost && cost.credits != null && cost.prev_credits != null) {
    rows.push({
      attr: "Credits used",
      diff: `${fmtCredits(cost.prev_credits)} → ${fmtCredits(cost.credits)}`
        + (cost.change_pct != null ? ` (${fmtChangePct(cost.change_pct)})` : ""),
      changed: cost.status === "WARN" || cost.status === "CRITICAL",
    });
  }
  if (!rows.length) {
    return <div className="jrp-gap-note">{`–  ${taskPanelGap(byId.sf_task_duration_regression)}`}</div>;
  }
  return (
    <div className="jrp-changes-table">
      {rows.map((r, i) => (
        <div className="jrp-changes-row" key={i}>
          <span className="jrp-changes-attr">{r.attr}</span>
          <span className={`jrp-changes-diff ${r.changed ? "changed" : ""}`}>{r.diff}</span>
        </div>
      ))}
    </div>
  );
}

// Every step carries a number or a concrete setting, root cause first.
export function taskPanelWhatToDo(byId: TaskPanelById) {
  const steps: string[] = [];
  const fail = taskPanelRow(byId.sf_task_failures);
  if (fail && fail.failed_runs > 0) {
    steps.push(`Read the last error${fail.last_error_code ? ` (${fail.last_error_code})` : ""} and fix the SQL, grants or upstream data: ${fmtInt(fail.failed_runs)} of ${fmtInt(fail.runs)} runs failed.`);
    if (fail.consecutive_failures >= 2) steps.push(`It has failed ${fmtInt(fail.consecutive_failures)} times in a row: check that the earlier runs share one cause.`);
  }
  const silent = taskPanelRow(byId.sf_task_silent_failures);
  if (silent && silent.finding === "silent_failures") steps.push("Set ERROR_INTEGRATION on the root task, or add a finalizer task that alerts.");
  if (silent && silent.finding === "execute_as_user_gone") steps.push("Set EXECUTE AS USER to a live service user.");
  if (silent && silent.finding === "admin_owner") steps.push("Move ownership from the admin role to a task role.");
  if (silent && silent.finding === "allow_all_overlap") steps.push("Turn off ALLOW_OVERLAPPING_EXECUTION so a slow run does not pile up copies.");
  const susp = taskPanelRow(byId.sf_task_suspended_or_stale);
  if (susp && susp.finding === "auto_suspended_after_failures") steps.push("Fix the cause, then ALTER TASK ... RESUME (or drop the task if nobody needs it).");
  else if (susp && susp.finding === "started_but_not_running") steps.push("Check the schedule and that the root task is resumed.");
  else if (susp && (susp.finding === "suspended_stale" || susp.finding === "never_ran")) steps.push("Drop the task if it is no longer needed, so the inventory stays true.");
  const skip = taskPanelRow(byId.sf_task_skipped_overlaps);
  if (skip && numOrZero(skip.overlap_skips) > 0) steps.push(`Widen the schedule or make each run shorter: ${fmtInt(skip.overlap_skips)} runs were skipped because the last run was still going.`);
  const dur = taskPanelRow(byId.sf_task_duration_regression);
  if (dur && (dur.status === "WARN" || dur.status === "CRITICAL")) steps.push(`Compare the query profile of a recent and an older run: median run time went ${dur.regression_reason ? dur.regression_reason.replace("median run ", "") : "up"}.`);
  const cost = taskPanelRow(byId.sf_task_cost);
  if (cost && (cost.status === "WARN" || cost.status === "CRITICAL") && cost.cost_reason) steps.push(`Run it less often or only when a stream has data: ${cost.cost_reason}.`);
  const wh = taskPanelRow(byId.sf_task_warehouse_vs_serverless);
  if (wh && wh.serverless_candidate) steps.push(`Drop the WAREHOUSE parameter to make it serverless: ${wh.candidate_reason}.`);
  if (!steps.length) steps.push("Nothing flagged for this task right now.");
  return steps;
}

// One line per check that has no row for this task: "–" plus why, so a gap never reads as clean.
export function TaskPanelGaps({ byId }: { byId: TaskPanelById }) {
  // Graph health has rows only for root tasks: no row for another task is not a gap.
  const gaps = TASK_PANEL_IDS.filter((id) => !taskPanelRow(byId[id])
    && !(id === "sf_task_graph_health" && String((byId[id] || {}).outcome).startsWith("ok")));
  if (!gaps.length) return null;
  return (
    <div>
      <h3 className="jrp-section-title" style={{ marginBottom: 6 }}>Checks with no result for this task</h3>
      <div className="jrp-owner-grid">
        {gaps.map((id) => (
          <React.Fragment key={id}>
            <span className="jrp-owner-key">{TASK_PANEL_CHECK_NAMES[id]}</span>
            <span>{`–  ${taskPanelGap(byId[id])}`}</span>
          </React.Fragment>
        ))}
      </div>
    </div>
  );
}

export function TaskPanel({ accountId, taskId, windowDays, onClose }: { accountId: any; taskId: any; windowDays: number; onClose: () => void }) {
  useNames();
  const focus = useTaskPanelData(accountId, taskId, windowDays);

  React.useEffect(() => {
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    document.addEventListener("keydown", onEsc);
    return () => document.removeEventListener("keydown", onEsc);
  }, [onClose]);

  const byId = focus.byId;
  const ready = focus.phase === "ready";
  const anyRow = ready && TASK_PANEL_IDS.some((id) => taskPanelRow(byId[id]));
  const status = ready ? taskPanelStatus(byId) : null;
  const headerStatus = !ready ? null
    : status === "CRITICAL" ? { word: "Critical", kind: "critical" }
    : status === "WARN" ? { word: "Warning", kind: "warn" }
    : status === "OK" ? { word: "OK", kind: "ok" }
    : { word: "Not assessed", kind: "not_assessed" };

  const fail = ready ? taskPanelRow(byId.sf_task_failures) : null;
  const numId = Names.taskNumericId(taskId);
  const name = resolveName("task", accountId, taskId) || taskId;
  const root = ready ? taskPanelRow(byId.sf_task_failures) || taskPanelRow(byId.sf_task_cost) : null;
  const acctName = accountId != null ? acctPhrase(accountId) : null;

  return (
    <React.Fragment>
      <div className="jrp-backdrop" onClick={onClose}></div>
      <div className="jrp-panel" role="dialog" aria-modal="true" aria-label={name}>
        <div className="jrp-head">
          <div className="jrp-head-row">
            {headerStatus ? <StatusPill kind={headerStatus.kind} word={headerStatus.word} /> : <span className="muted">…</span>}
            <button type="button" className="jrp-close" title="Close" onClick={onClose}>{"✕"}</button>
          </div>
          <h2 className="jrp-title">{numId ? `${name} (${numId})` : name}</h2>
          <SnowLink kind="task" id={taskId} />
          <div className="jrp-sub">
            {[acctName, fail ? `${fmtInt(fail.runs)} runs in ${windowDays}d` : null,
              root && root.root_task_full_name && root.root_task_full_name !== taskId ? `root task ${root.root_task_full_name}` : null]
              .filter(Boolean).join(" · ")}
          </div>
        </div>

        <div className="jrp-body">
          {!ready && <div className="loading-note">…</div>}
          {ready && !anyRow && (
            <div className="jrp-gap-note">{`No check has a row for this task in the last ${fmtInt(windowDays)} days.`}</div>
          )}
          {ready && <TaskPanelKpis byId={byId} windowDays={windowDays} />}
          {ready && <TaskPanelProblems byId={byId} />}
          {ready && (
            <div>
              <div className="jrp-section-head">
                <h3 className="jrp-section-title">Runs and run time</h3>
                <span className="jrp-section-hint">{`last ${windowDays} days`}</span>
              </div>
              <TaskPanelRunsChart byId={byId} />
            </div>
          )}
          {ready && (
            <div>
              <div className="jrp-section-head"><h3 className="jrp-section-title">What changed since the window before</h3></div>
              <TaskPanelChanges byId={byId} />
            </div>
          )}
          {ready && (
            <div>
              <h3 className="jrp-section-title" style={{ marginBottom: 6 }}>What to do</h3>
              <ol className="jrp-todo">
                {taskPanelWhatToDo(byId).map((s, i) => <li key={i}>{s}</li>)}
              </ol>
              <div className="jrp-actions" style={{ marginTop: 10 }}>
                <CopyLinkButton label="Copy task link" />
              </div>
            </div>
          )}
          {ready && <TaskPanelGaps byId={byId} />}
        </div>
      </div>
    </React.Fragment>
  );
}

// Mounted by App.tsx; reads the open task from TaskFocus so a click anywhere opens it.
export function TaskPanelOverlay({ windowDays }: { windowDays?: number | null }) {
  const [state, setState] = React.useState(TaskFocus.getState());
  React.useEffect(() => TaskFocus.subscribe(setState), []);
  if (!state.open) return null;
  // Keyed by task so switching tasks while open remounts a fresh fetch.
  return (
    <ErrorBoundary key={`${state.accountId}:${state.taskId}`}>
      <TaskPanel accountId={state.accountId} taskId={state.taskId} windowDays={windowDays || 30} onClose={TaskFocus.close} />
    </ErrorBoundary>
  );
}
