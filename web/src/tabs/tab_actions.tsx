// web/src/tabs/tab_actions.tsx -- Actions: the flagged checks turned into a short list of fixes,
// each with its impact ($, risk or not priced), effort, team and how to fix it. Findings from the
// data, not tickets: no owner, no status. Every $ comes from waste_total.tsx, so a fix shows the
// same figure as Overview, Waste & savings and the check's own page. Possible waste, possible
// saving and storage per month are three units and are never added.

// kind: saving (a priced $), risk (security), policy (spend with no owner), hygiene.
// `waste` names the WASTE_ITEMS entry that prices it; `checks` are the checks that open it. `impact`
// names a check whose own saving figure is the action's impact instead (auto-suspend), and `context`
// the waste check that same time is counted in: shown next to the impact, never added to it. The
// `how` text is a change to make: settings a person can run, never below what Snowflake allows
// (auto-suspend below 60 s is not offered).
import React from "react";
import { Api } from "../api";
import { fmtDayShort, fmtInt, fmtMoney, fmtMoneyOf } from "../format";
import { useNames } from "../components/names";
import { FLAGGED_STATUSES, aggTotal, numOrZero, useFindingAgg, useFindingData } from "../components/hooks";
import { AREA_ORDER, AREA_REGISTRY, COST_MONEY_COL, COVERAGE_REF_IDS, homeForQuery } from "../components/tab_registry";
import { IssueTile, StackedShareBar, StatusBars, fmtShare, pctOf } from "../components/blocks";
import { useCostCenterAllocation } from "../components/tag_rollup";
import { KindChip, PatternCard, StatusPill, bandOf } from "../components/primitives";
import { AreaContent } from "../area_content";
import { getCheckLabel } from "../components/labels";
import { ChartNote } from "../components/charts";
import { buildWasteWorklist, moneyKindOf, overlapNote, wasteTotal } from "../components/waste_total";
import { pickNum } from "./tab_overview";
import { worstContract } from "./tab_money";
import { StatStrip } from "../components/blocks_2";
import { CsvButton } from "../components/csv";
import { FixCopyButton } from "../components/fixcopy_button";
import { KpiRow } from "../components/overview_tile";
import { SplitBar } from "../components/cx_a";
import type { CsvColumn } from "../components/csv";
import { emptyLabelFor, pickLabelColumn, rowLabelOf } from "./tab_area";
import type { WasteEntry } from "../components/waste_total";
import type { Dims, FetchState, Filters, Finding, GoToFn, Row } from "../types";
import { GuideHelp } from "../components/guide_links";

type ActionTitleFn = (n: string, w: string) => string;

/** One fix template: the checks that open it, how it is priced and how to make the change. */
export interface ActionTemplate {
  key: string;
  kind: string;
  team: string;
  waste?: string;
  impact?: string;
  context?: string;
  checks: string[];
  noun: string[];
  title: ActionTitleFn;
  effort: string;
  byCheck?: Record<string, { noun: string[]; title: ActionTitleFn }>;
  how: string;
  /** A $ column of the main check's rows to rank and price the "Where" list by (spend, not waste). */
  rowMoney?: string;
}

/** A template with at least one flagged check: its rows, count, impact and label. */
export interface Action extends ActionTemplate {
  rows: Finding[];
  main: Finding;
  n: number | null;
  usd: number | null;
  unit: string | null;
  contextUsd: number | null;
  evidence: { id: string; col: string | null | undefined } | null;
  critical: boolean;
  wasteEntry: WasteEntry | null;
  label: string;
  checkCount: number;
  /** The impact as worded by the page when it is not a waste figure ("$31,030 · 42% untagged"). */
  impactText?: string | null;
  /** The "n of m noun" the count comes from, when the check has one. */
  base: { flagged: number; total: number; noun: string } | null;
}

export const ACTION_TEMPLATES: ActionTemplate[] = [
  { key: "warehouse_autostop", kind: "saving", team: "Platform", waste: "sf_wh_idle_minutes",
    impact: "sf_wh_auto_suspend_tuning", context: "sf_wh_idle_minutes",
    checks: ["sf_wh_idle_minutes", "sf_wh_auto_suspend_tuning"], noun: ["idle warehouse", "idle warehouses"],
    title: (n, w) => `Lower auto-suspend on ${n} ${w}`, effort: "5 min each",
    how: "ALTER WAREHOUSE <name> SET AUTO_SUSPEND = 60; (use 300 instead where the warehouse cache is reused: the Idle detail says which. Below 60 s each resume still bills 60 s.)" },
  { key: "warehouse_resize", kind: "saving", team: "Platform", waste: "sf_wh_oversized",
    checks: ["sf_wh_oversized", "sf_wh_consolidation_candidates"], noun: ["oversized warehouse", "oversized warehouses"],
    title: (n, w) => `Resize ${n} ${w}`, effort: "10 min each",
    byCheck: { sf_wh_consolidation_candidates: { noun: ["warehouse that could be shared", "warehouses that could be shared"], title: (n, w) => `Merge ${n} ${w}` } },
    how: "ALTER WAREHOUSE <name> SET WAREHOUSE_SIZE = <one size down>; then watch queue time and spilling for a week. A resize is a saving, not waste." },
  { key: "failed_statements", kind: "saving", team: "Data eng", waste: "cost_failed_statement_waste",
    checks: ["cost_failed_statement_waste", "sf_query_failed_by_error"], noun: ["warehouse with failing statements", "warehouses with failing statements"],
    title: (n, w) => `Fix statements that keep failing on ${n} ${w}`, effort: "30 min each",
    how: "Queries > Failures groups the errors; fix the query or the object it reads, or stop the schedule that re-runs it." },
  { key: "tasks_on_warehouse", kind: "saving", team: "Data eng", waste: "sf_task_warehouse_vs_serverless",
    checks: ["sf_task_warehouse_vs_serverless"], noun: ["short task", "short tasks"],
    title: (n, w) => `Move ${n} ${w} that keep a warehouse awake`, effort: "15 min each",
    how: "ALTER TASK <name> SET USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL' with the warehouse setting unset. Serverless compute bills at its own credit rate: compare the two before switching." },
  { key: "noop_tasks", kind: "saving", team: "Data eng", waste: "sf_task_noop_runs",
    checks: ["sf_task_noop_runs"], noun: ["task that runs for nothing", "tasks that run for nothing"],
    title: (n, w) => `Skip empty runs of ${n} ${w}`, effort: "15 min each",
    how: "Add WHEN SYSTEM$STREAM_HAS_DATA('<stream>') to the task so it does not wake a warehouse when there is nothing to process." },
  { key: "retention", kind: "saving", team: "Data eng", waste: "sf_storage_retention_policy",
    checks: ["sf_storage_retention_policy", "sf_storage_failsafe_on_staging"], noun: ["database over retention policy", "databases over retention policy"],
    title: (n, w) => `Shorten Time Travel on ${n} ${w}`, effort: "10 min each",
    byCheck: { sf_storage_failsafe_on_staging: { noun: ["staging table paying for Fail-safe", "staging tables paying for Fail-safe"], title: (n, w) => `Make ${n} ${w} transient` } },
    how: "ALTER DATABASE <name> SET DATA_RETENTION_TIME_IN_DAYS = 1; and make staging tables TRANSIENT so they pay no Fail-safe. Saving is per month." },
  { key: "untagged", kind: "policy", team: "FinOps", checks: ["sf_chg_tag_coverage"], rowMoney: "est_usd_list",
    noun: ["object with spend and no cost tag", "objects with spend and no cost tag"], title: (n, w) => `Tag ${n} ${w}`, effort: "1 day",
    how: "CREATE TAG cost_center; then ALTER WAREHOUSE <name> SET TAG cost_center = '<team>' for each warehouse, and tag the users and roles that own the rest." },
  { key: "guardrails", kind: "policy", team: "FinOps", checks: ["sf_cost_resource_monitor_coverage", "sf_acct_budgets", "sf_wh_config_posture"],
    noun: ["warehouse without a spend cap", "warehouses without a spend cap"], title: (n, w) => `Put a resource monitor or budget on ${n} ${w}`, effort: "1 h",
    how: "CREATE RESOURCE MONITOR ... WITH CREDIT_QUOTA = <credits> TRIGGERS ON 90 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND; then ALTER WAREHOUSE <name> SET RESOURCE_MONITOR = <monitor>; and add a budget for serverless spend." },
  { key: "contract", kind: "policy", team: "Finance", checks: ["sf_cost_contract_balance_burn"],
    noun: ["contract against the current burn", "contracts against the current burn"], title: (n, w) => `Review ${n} ${w}`, effort: "1 h",
    how: "Size the next commitment on the current run-rate. If the balance runs out before the end date, renew early or agree overage at the contract rate until renewal." },
  { key: "stale_tasks", kind: "hygiene", team: "Data eng", checks: ["sf_task_suspended_or_stale"],
    noun: ["stale task", "stale tasks"], title: (n, w) => `Suspend or drop ${n} ${w}`, effort: "5 min each",
    how: "ALTER TASK <name> SUSPEND; or DROP TASK <name>; if nobody needs it." },
  { key: "failed_tasks", kind: "hygiene", team: "Data eng", checks: ["sf_task_failures", "sf_task_graph_health"],
    noun: ["failing task", "failing tasks"], title: (n, w) => `Repair ${n} ${w}`, effort: "1-2 h each",
    how: "Open the last error in Tasks & pipelines > Failures, fix the cause and resume. A task that fails back to back is billing for nothing." },
  { key: "no_timeout", kind: "hygiene", team: "Platform", checks: ["sf_acct_parameters_posture", "sf_query_long_running"],
    noun: ["setting or statement without a timeout", "settings or statements without a timeout"], title: (n, w) => `Set a statement timeout on ${n} ${w}`, effort: "10 min",
    how: "ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 7200; (or per warehouse) so one runaway statement cannot bill for a day." },
  { key: "warehouse_pressure", kind: "hygiene", team: "Platform", checks: ["query_warehouse_pressure", "sf_wh_undersized"],
    noun: ["warehouse", "warehouses"], title: (n, w) => `Resize ${n} ${w} that queue or spill`, effort: "10 min each",
    how: "More clusters (MAX_CLUSTER_COUNT) when queries wait for a slot; one size up when they spill to remote storage." },
  { key: "mfa", kind: "risk", team: "Security", checks: ["sf_sec_users_without_mfa"],
    noun: ["person without MFA", "people without MFA"], title: (n, w) => `Enrol ${n} ${w}`, effort: "10 min each",
    how: "Require MFA with an authentication policy (CREATE AUTHENTICATION POLICY ... MFA_ENROLLMENT = REQUIRED) and enrol each person." },
  { key: "network", kind: "risk", team: "Security", checks: ["sf_sec_network_policy_coverage"],
    noun: ["user or account without a network policy", "users or accounts without a network policy"], title: (n, w) => `Restrict ${n} ${w}`, effort: "1 h",
    how: "CREATE NETWORK POLICY ... ALLOWED_IP_LIST = (...); then ALTER ACCOUNT SET NETWORK_POLICY = <policy>; test with an admin session open." },
  { key: "unmasked", kind: "risk", team: "Security", checks: ["sf_gov_sensitive_columns_unprotected"],
    noun: ["sensitive column", "sensitive columns"], title: (n, w) => `Mask ${n} ${w}`, effort: "1 h each table",
    how: "ALTER TABLE <t> MODIFY COLUMN <c> SET MASKING POLICY <policy>; or tag the column and attach one tag-based masking policy." },
  { key: "admin_changes", kind: "risk", team: "Security", checks: ["sf_sec_privileged_grant_changes"],
    noun: ["admin change pattern", "admin change patterns"], title: (n, w) => `Confirm ${n} ${w}`, effort: "30 min",
    how: "Check each change with the person or service that made it; revoke what nobody expected." },
  { key: "broad_grants", kind: "risk", team: "Security", checks: ["access_broad_grants"],
    noun: ["broad grant", "broad grants"], title: (n, w) => `Narrow ${n} ${w}`, effort: "30 min each",
    how: "REVOKE the grant from PUBLIC or the wide role and GRANT only what a named role needs." },
];

export const ACTION_KIND_LABEL: Record<string, string> = { saving: "Savings", risk: "Risks", policy: "Policies", hygiene: "Hygiene" };
export const ACTION_KIND_ORDER = ["saving", "risk", "policy", "hygiene"];

// One action per template with at least one flagged check the role can see. N comes from the main
// check's own "N of M" count, so the title never counts rows.
export function buildActions(templates: ActionTemplate[], index: Record<string, Finding>, worklist: WasteEntry[] | null | undefined, allowedAreas: Set<string>) {
  const wasteById: Record<string, WasteEntry> = {};
  (worklist || []).forEach((w) => { wasteById[w.id] = w; });
  return templates.map((t): Action | null => {
    const rows = t.checks.map((id) => index[id]).filter(Boolean)
      .filter((row) => allowedAreas.has(homeForQuery(row).tab));
    const flagged = rows.filter((row) => { const b = bandOf(row); return b === "CRITICAL" || b === "WARN"; });
    if (!flagged.length) return null;
    const main = flagged[0];
    let n: number | null = main.affected && main.affected.flagged ? main.affected.flagged : null;
    const ov = (t.byCheck || {})[main.query_id];
    const noun = ov ? ov.noun : t.noun;
    const titleFn = ov ? ov.title : t.title;
    const word = n === 1 ? noun[0] : noun[1];
    // The noun, the count and the $ all come from the check that flagged; a sibling with its own
    // waste entry prices the action, and one with none stays "not priced".
    const w = wasteById[main.query_id] || null;
    const usd = w && w.ran && w.isFlagged && w.usd != null ? w.usd : null;
    const critical = flagged.some((row) => bandOf(row) === "CRITICAL");
    // An action with its own impact check shows that check's saving; the waste it overlaps is context.
    let impactUsd: number | null = null, contextUsd: number | null = null, evidence: Action["evidence"] = null;
    const baseOf = (f: Finding) => (f.affected && f.affected.total ? { flagged: numOrZero(f.affected.flagged), total: numOrZero(f.affected.total), noun: String(f.affected.noun || "") } : null);
    let base = baseOf(main);
    if (t.impact) {
      const f = index[t.impact];
      const b = f ? bandOf(f) : null;
      if ((b === "CRITICAL" || b === "WARN") && f.money && moneyKindOf(f) === "saving" && Number.isFinite(Number(f.money.usd))) {
        impactUsd = Number(f.money.usd);
        evidence = { id: f.query_id, col: f.money.column };
        // The title counts what the "Where" list and the impact come from.
        if (f.affected && f.affected.flagged) { n = f.affected.flagged; base = baseOf(f) || base; }
      }
      const cw = wasteById[t.context!];
      if (cw && cw.ran && cw.isFlagged && cw.usd != null) contextUsd = cw.usd;
    }
    return {
      ...t, rows: flagged, main, n,
      usd: t.impact ? impactUsd : usd, unit: t.impact ? (impactUsd != null ? "saving" : null) : (w ? w.unit : null),
      contextUsd, evidence, critical, wasteEntry: w,
      label: n != null ? titleFn(fmtInt(n), word) : titleFn("", noun[1]).replace(/\s+/g, " "),
      checkCount: flagged.length, base,
    };
  }).filter(Boolean) as Action[];
}

export const IMPACT_SUB: Record<string, (w: number) => string> = { waste: (w) => `possible waste, last ${w} days`, saving: (w) => `possible saving, last ${w} days`, month: () => "per month" };

export function actionImpact(a: Action) {
  if (a.impactText) return { text: a.impactText, tone: "none" };
  if (a.usd != null) return { text: fmtMoney(a.usd, 0) + (a.unit === "month" ? "/mo" : ""), tone: "money" };
  if (a.impact) return { text: "not priced", tone: "muted" };
  if (a.kind === "risk") return { text: a.critical ? "Critical" : "Warning", tone: a.critical ? "crit" : "warn" };
  return { text: "not priced", tone: "muted" };
}

// The worst flagged rows of the action's main check, one per object, named. A priced check ranks by
// its own money column, so this page names the same worst objects as the Waste page.
export function ActionEvidence({ action, filters, dims }: { action: Action; filters: Filters; dims?: Dims | null }) {
  const srcId = action.evidence ? action.evidence.id : action.main.query_id;
  const state = useFindingData(srcId, filters.window, filters.accountIds, 200, FLAGGED_STATUSES) as FetchState;
  if (state.phase !== "ready") return <div className="dr-loading">…</div>;
  if (state.outcome !== "ok_rows") return <ChartNote state={state} label={srcId} />;
  const cols = state.data!.columns;
  const labelCol = pickLabelColumn(cols);
  const moneyCol = action.evidence ? action.evidence.col
    : action.wasteEntry && action.wasteEntry.col && action.wasteEntry.id === action.main.query_id ? action.wasteEntry.col
    : action.rowMoney && (cols || []).some((c: { name: string }) => c.name === action.rowMoney) ? action.rowMoney : null;
  const disc = numOrZero(state.data!.discount_pct);
  const rank = (r: Row) => (r.status === "CRITICAL" ? 0 : 1);
  const byName = new Map<string, { name: string; rank: number; usd: number | null }>();
  state.data!.rows.forEach((r: Row) => {
    const name = rowLabelOf(r, labelCol, dims as Dims) || actionRowLabel(r) || emptyLabelFor(labelCol);
    const v = moneyCol ? pickNum(r, [moneyCol]) : null;
    const cur = byName.get(name) || { name, rank: 9, usd: null };
    cur.rank = Math.min(cur.rank, rank(r));
    if (v !== null) cur.usd = (cur.usd || 0) + v * (1 - disc);
    byName.set(name, cur);
  });
  const items = [...byName.values()].sort((a, b) => (b.usd || 0) - (a.usd || 0) || a.rank - b.rank);
  const rows = items.slice(0, 5);
  const total = action.n != null ? Math.max(action.n, items.length) : items.length;
  const maxUsd = Math.max(0, ...rows.map((r) => r.usd || 0));
  return (
    <div className="dr-section">
      <div className="dr-eyebrow">{`Where · worst ${fmtInt(rows.length)} of ${fmtInt(total)}`}</div>
      <div className="dr-where">
        {rows.map((r) => (
          <div key={r.name} className="dr-where-row cx-where-row">
            <span className="dr-dot" style={{ background: r.rank === 0 ? "var(--st-crit)" : "var(--st-warn)" }} aria-hidden="true" />
            <span className="dr-where-name" title={r.name}>{r.name}</span>
            <span className="dr-where-val">{r.usd != null ? fmtMoney(r.usd, 0) : (r.rank === 0 ? "Critical" : "Warning")}</span>
            {maxUsd > 0 && r.usd != null && <span className="cx-where-bar" aria-hidden="true"><span style={{ width: `${Math.max(1.5, (100 * r.usd) / maxUsd)}%` }} /></span>}
          </div>
        ))}
      </div>
      {rows.some((r) => r.rank === 0) && rows.some((r) => r.rank !== 0) && <div className="cx-fix-text muted">Red dot = critical, orange = warning.</div>}
    </div>
  );
}

// A readable name for a flagged row with no object column: a grant, an admin action, a sign-in.
export function actionRowLabel(r: Row): string | null {
  if (r.securable != null) return `${r.securable} → ${r.grantee} · ${r.privilege_type}`;
  if (r.actor != null) return [r.actor, r.action_name].filter(Boolean).join(" · ");
  if (r.principal != null) return [r.principal, r.source_ip_address].filter(Boolean).join(" · ");
  if (r.table_name != null) return [r.database_name, r.schema_name, r.table_name].filter(Boolean).join(".");
  return null;
}

// ─────────── Effort, kind words and the order of the list ───────────

/** Minutes per object from the catalog's effort text ("5 min each", "1-2 h each", "1 day"); the upper end of a range. */
export function effortMinutes(effort: string | null | undefined): number | null {
  const m = /(\d+(?:\.\d+)?)(?:\s*-\s*(\d+(?:\.\d+)?))?\s*(min|h|day)/i.exec(String(effort || ""));
  if (!m) return null;
  const v = Number(m[2] || m[1]);
  const u = m[3].toLowerCase();
  return u === "min" ? v : u === "h" ? v * 60 : v * 480;
}
export const EFFORT_BUCKETS: { key: string; label: string; max: number }[] = [
  { key: "quick", label: "under 15 min", max: 15 },
  { key: "hour", label: "15 min – 1 h", max: 60 },
  { key: "long", label: "hours to a day", max: Infinity },
];
export function effortBucket(effort: string | null | undefined): string | null {
  const m = effortMinutes(effort);
  if (m == null) return null;
  return (EFFORT_BUCKETS.find((b) => m <= b.max) || EFFORT_BUCKETS[EFFORT_BUCKETS.length - 1]).key;
}

/** The kind under an impact figure: which money it is, or that it is a risk with no $. */
export function actionKindWord(a: Action, windowDays: number): string {
  if (a.impactText) return "policy";
  if (a.usd != null) return a.unit === "month" ? "storage · per month" : a.unit === "saving" ? `possible saving · ${windowDays} d` : `possible waste · ${windowDays} d`;
  if (a.kind === "risk") return "risk · not priced";
  return a.kind === "policy" ? "policy · not priced" : "not priced";
}

/** "21 of 43 warehouses · Platform". */
export function actionBaseText(a: Action): string {
  const b = a.base;
  return [b ? `${fmtInt(b.flagged)} of ${fmtInt(b.total)} ${b.noun}` : null, a.team].filter(Boolean).join(" · ");
}

/** Critical first, then the largest $ in the window, then storage per month; "This week" is the
 * first three with different owners, so the top of the list spans the areas, not $ alone. */
export function rankActions(actions: Action[]): { week: Action[]; then: Action[] } {
  const inWin = (a: Action) => (a.usd != null && a.unit !== "month" ? a.usd : -1);
  const perMonth = (a: Action) => (a.usd != null && a.unit === "month" ? a.usd : -1);
  const sorted = [...actions].sort((a, b) => Number(b.critical) - Number(a.critical) || inWin(b) - inWin(a) || perMonth(b) - perMonth(a)
    || ACTION_KIND_ORDER.indexOf(a.kind) - ACTION_KIND_ORDER.indexOf(b.kind));
  const week: Action[] = [];
  const teams = new Set<string>();
  sorted.forEach((a) => { if (week.length < 3 && !teams.has(a.team)) { week.push(a); teams.add(a.team); } });
  sorted.forEach((a) => { if (week.length < 3 && !week.includes(a)) week.push(a); });
  return { week, then: sorted.filter((a) => !week.includes(a)) };
}

/** Every action the role can see, with the tagging fix carrying its untagged spend. */
export function useActions(index: Record<string, Finding>, roleAreas: string[] | null | undefined, filters: Filters) {
  const allowedAreas = React.useMemo(() => new Set(roleAreas && roleAreas.length ? roleAreas : AREA_ORDER), [roleAreas]);
  const worklist = React.useMemo(() => buildWasteWorklist(index), [index]);
  const wt = React.useMemo(() => wasteTotal(worklist), [worklist]);
  const built = React.useMemo(() => buildActions(ACTION_TEMPLATES, index, worklist, allowedAreas), [index, worklist, allowedAreas]);
  const cc = useCostCenterAllocation(filters);
  const ccRows: Row[] | null = cc.phase === "ready" && cc.outcome === "ok_rows" ? (cc.data.by_value || []) : null;
  const ccTotal = ccRows ? ccRows.reduce((s: number, e: Row) => s + numOrZero(e.metrics && e.metrics.usd), 0) : null;
  const ccUntagged = ccRows ? ccRows.filter((e: Row) => e.value === "__untagged__").reduce((s: number, e: Row) => s + numOrZero(e.metrics && e.metrics.usd), 0) : null;
  const untaggedPct = pctOf(ccUntagged, ccTotal);
  const actions = built.map((a) => (a.key === "untagged" && ccUntagged != null && ccUntagged > 0
    ? { ...a, impactText: `${fmtShare(untaggedPct)} untagged` } : a));
  return { allowedAreas, worklist, wt, actions, cc, ccTotal, ccUntagged, untaggedPct, ready: Object.keys(index).length > 0 };
}

// ─────────── ActionList rows ───────────

export function ActionRow({ a, rank, windowDays, selected, onOpen }: { a: Action; rank: number; windowDays: number; selected?: boolean; onOpen: () => void }) {
  const imp = actionImpact(a);
  return (
    <button type="button" className={`al-row${selected ? " on" : ""}`} onClick={onOpen} aria-pressed={!!selected}>
      <span className="al-rank">{rank}</span>
      <span className="al-what">
        <span className="al-title" title={a.label}>{a.label}</span>
        <span className="al-base">{actionBaseText(a)}</span>
      </span>
      <span className="al-impact">
        <span className={`al-impact-v tone-${imp.tone || "none"}`}>{imp.text}</span>
        <span className="al-kind">{actionKindWord(a, windowDays)}</span>
      </span>
      <span className="al-effort">{a.effort}</span>
      <span className="al-open">{"Open →"}</span>
    </button>
  );
}

// The fix split in two: the SQL alone in the mono block (what Copy takes), the explanation as plain text.
export function splitFix(how: string): { sql: string | null; text: string | null } {
  const s = String(how || "").trim();
  const m = /^((?:ALTER|CREATE|GRANT|REVOKE|DROP|SELECT|USE|SHOW|EXECUTE|CALL|COMMENT|UNSET)\b[^;]*;)\s*(.*)$/is.exec(s);
  if (!m) return { sql: null, text: s || null };
  let rest = m[2].trim();
  if (/^\(.*\)\.?$/s.test(rest)) rest = rest.replace(/^\(/, "").replace(/\)\.?$/, "");
  rest = rest.replace(/^then\b/i, "Then");
  return { sql: m[1].trim(), text: rest ? rest.charAt(0).toUpperCase() + rest.slice(1) : null };
}

function ActionFix({ how }: { how: string }) {
  const { sql, text } = splitFix(how);
  return (
    <div className="dr-section">
      <div className="fx-head">
        <div className="dr-eyebrow">The fix</div>
        {sql && <FixCopyButton text={sql} />}
      </div>
      {sql && <pre className="dr-fix">{sql}</pre>}
      {text && <p className="cx-fix-text">{text}</p>}
    </div>
  );
}

function FigBox({ eyebrow, value, sub }: { eyebrow: string; value: React.ReactNode | null; sub?: React.ReactNode }) {
  const missing = value === null || value === undefined || value === "";
  return (
    <div className={`dr-fig${missing ? " is-missing" : ""}`}>
      <div className="dr-eyebrow">{eyebrow}</div>
      <div className="dr-fig-value">{missing ? "–" : value}</div>
      {sub && <div className="dr-fig-sub">{sub}</div>}
    </div>
  );
}

/** The selected fix: chips, title, base line, one box per figure kind, the fix, where, links. */
export function ActionDrawer({ action, filters, dims, goTo, onClose }: { action: Action; filters: Filters; dims?: Dims | null; goTo: GoToFn; onClose: () => void }) {
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  const imp = actionImpact(action);
  const priced = action.usd != null || !!action.impactText;
  return (
    <aside className="dr al-drawer" aria-label={action.label}>
      <div className="dr-head">
        <div className="dr-chips">
          <KindChip>{action.team}</KindChip>
          <KindChip>{ACTION_KIND_LABEL[action.kind]}</KindChip>
          <StatusPill kind={action.critical ? "critical" : "warn"} />
        </div>
        <button type="button" className="dr-close" aria-label="Close" onClick={onClose}>×</button>
      </div>
      <h3 className="dr-title">{action.label}</h3>
      <div className="dr-base">{actionBaseText(action)}</div>
      <div className="dr-figs">
        <FigBox eyebrow="Impact" value={priced ? imp.text : null} sub={actionKindWord(action, filters.window)} />
        {action.contextUsd != null && (
          <FigBox eyebrow="Idle cost behind it" value={fmtMoney(action.contextUsd, 0)} sub={`possible waste · ${filters.window} d · counted on Waste & savings, not added`} />
        )}
        <FigBox eyebrow="Effort" value={action.effort} sub="per object" />
      </div>
      <ActionFix how={action.how} />
      <ActionEvidence action={action} filters={filters} dims={dims} />
      <div className="dr-links">
        {action.rows.map((row) => (
          <span key={row.query_id} className="dr-link-pair">
            <button type="button" className="dr-link"
              onClick={() => goTo({ tab: homeForQuery(row).tab, subtab: homeForQuery(row).subtab, focusQueryId: row.query_id })}>
              {`${getCheckLabel(row.query_id, row.title).title} →`}
            </button>
            <GuideHelp id={row.query_id} label={getCheckLabel(row.query_id, row.title).title} />
          </span>
        ))}
      </div>
    </aside>
  );
}

// ─────────── Who has the work · How long each takes ───────────

// Owners and effort never share a colour, so the two bars are not read as one key.
const OWNER_COLORS = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)", "var(--seq-2)"];
const EFFORT_COLORS = ["var(--st-ref)", "var(--c5)", "var(--heat-4)"];

export function teamSplit(actions: Action[]) {
  const by = new Map<string, number>();
  actions.forEach((a) => by.set(a.team, (by.get(a.team) || 0) + 1));
  return [...by.entries()].sort((a, b) => b[1] - a[1]);
}

export function WorkSplitCards({ actions, role, second }: { actions: Action[]; role?: string | null; second?: React.ReactNode }) {
  if (!actions.length) return null;
  const n = actions.length;
  const word = (v: number) => `${fmtInt(v)} action${v === 1 ? "" : "s"}`;
  const byBucket = EFFORT_BUCKETS.map((b) => ({ ...b, n: actions.filter((a) => effortBucket(a.effort) === b.key).length }));
  const unknown = actions.filter((a) => effortBucket(a.effort) == null).length;
  const quick = byBucket[0].n;
  const crit = actions.filter((a) => a.critical).length;
  const priced = actions.filter((a) => a.usd != null).length;
  return (
    <div className="cj-charts-2">
      <PatternCard title={role === "finops" ? "Who to talk to" : "Who has the work"}
        sub={`${word(n)}, by owner${priced === 0 ? " · none is priced" : ""}`}>
        {teamSplit(actions).length <= 5
          ? <SplitBar ariaLabel="Actions by owner" parts={teamSplit(actions).map(([team, v], i) => ({ key: team, label: team, value: v, sub: word(v), color: OWNER_COLORS[i] }))} />
          : <StackedShareBar height={26} valueFmt={word} ariaLabel="Actions by owner"
            segments={teamSplit(actions).map(([team, v]) => ({ key: team, label: team, value: v }))} />}
        {role === "governance" && (
          <div className="ln-notlist">
            <StackedShareBar height={22} valueFmt={word} totalLabel="By severity" ariaLabel="Actions by severity"
              segments={[{ key: "crit", label: "critical", value: crit, color: "var(--st-crit)" }, { key: "warn", label: "warning", value: n - crit, color: "var(--st-warn)" }]} />
          </div>
        )}
      </PatternCard>
      {second || <PatternCard title="How long each takes" sub={`Per object · ${fmtInt(quick)} of ${fmtInt(n)} under 15 minutes`}>
        <SplitBar ariaLabel="Actions by effort"
          parts={[...byBucket.map((b, i) => ({ key: b.key, label: b.label.charAt(0).toUpperCase() + b.label.slice(1), value: b.n, sub: word(b.n), color: EFFORT_COLORS[i] })),
            { key: "none", label: "No estimate", value: unknown, sub: word(unknown), hatch: true }]} />
      </PatternCard>}
    </div>
  );
}

/** CFO: the worst contract at the current burn: how long the balance lasts against the days left. */
export function ContractBurnCard({ filters, goTo }: { filters: Filters; goTo: GoToFn }) {
  const state = useFindingData("sf_cost_contract_balance_burn", filters.window, filters.accountIds);
  const rows = state.phase === "ready" && state.outcome === "ok_rows" ? state.data!.rows : null;
  const c = worstContract(rows);
  const open = () => goTo({ tab: "cost", subtab: "contract" });
  if (!c) {
    return (
      <PatternCard title="Contract at the current burn" sub="Balance, burn per day and the end date" link="Contract & rate →" onLink={open}>
        {state.phase === "loading" ? <div className="chart-note-oneline">…</div>
          : rows ? <div className="chart-note-oneline">– no contract with a drawdown in this export</div> : <ChartNote state={state} label="sf_cost_contract_balance_burn" />}
      </PatternCard>
    );
  }
  const cur = { unit: "currency", currency: c.currency };
  const money = (v: unknown) => (v == null || !Number.isFinite(Number(v)) ? null : fmtMoneyOf(cur, Number(v), 0));
  const endDays = pickNum(c, ["days_to_contract_end"]);
  const runway = pickNum(c, ["runway_days"]);
  const covered = endDays != null && endDays > 0 && runway != null ? Math.min(100, (100 * runway) / endDays) : null;
  const gapDays = endDays != null && runway != null && runway < endDays ? endDays - runway : null;
  return (
    <PatternCard title="Contract at the current burn"
      sub={[money(c.prepaid_balance) ? `${money(c.prepaid_balance)} balance` : null, gapDays != null ? `the balance ends ${fmtInt(Math.round(gapDays))} d before the contract does` : "the balance lasts to the end date"].filter(Boolean).join(" · ")}
      link="Contract & rate →" onLink={open}>
      <div className="ln-runway">
        {covered != null && (
          <div className="ln-runway-bar" role="img" aria-label={`Balance lasts ${fmtInt(Math.round(runway!))} of ${fmtInt(Math.round(endDays!))} days left`}>
            <span className="ln-runway-fill" style={{ width: `${covered}%` }} />
            {covered < 100 && <span className="ln-runway-gap" style={{ left: `${covered}%`, right: 0 }} />}
          </div>
        )}
        {covered != null && (
          <div className="ln-runway-legend">
            <span><span className="blk-sw" style={{ background: "var(--c1)" }} />{`covered by the balance · ${fmtInt(Math.round(Math.min(runway!, endDays!)))} d`}</span>
            {gapDays != null && <span><span className="blk-sw blk-hatch" />{`uncovered · ${fmtInt(Math.round(gapDays))} d`}</span>}
          </div>
        )}
        <StatStrip ariaLabel="Contract runway" cells={[
          { key: "burn", label: "Per day", value: money(c.daily_burn), base: "average drawdown" },
          { key: "runs", label: "Balance runs out", value: c.projected_depletion_date ? fmtDayShort(c.projected_depletion_date) : null, base: runway != null ? `lasts ${fmtInt(Math.round(runway))} d` : null, missing: "no drawdown seen" },
          { key: "end", label: "Contract ends", value: endDays != null ? `${fmtInt(Math.round(endDays))} d` : null, base: c.contract_end_date ? fmtDayShort(c.contract_end_date) : null, missing: "no end date" },
        ]} />
      </div>
    </PatternCard>
  );
}

/** A risk or reliability fix kept off a money list: pill · what · base · Open. */
export function NotOnListRows({ actions, onOpen }: { actions: Action[]; onOpen: (a: Action) => void }) {
  if (!actions.length) return null;
  return (
    <div className="ln-notlist">
      <div className="al-group">{`Not on this list · ${fmtInt(actions.length)} action${actions.length === 1 ? "" : "s"} that change risk or reliability, not money`}</div>
      {actions.map((a) => (
        <button key={a.key} type="button" className="ln-notlist-row" onClick={() => onOpen(a)}>
          <StatusPill kind={a.critical ? "critical" : "warn"} />
          <span className="al-title" title={a.label}>{a.label}</span>
          <span className="ln-notlist-base">{actionBaseText(a)}</span>
          <span className="al-open">{"Open →"}</span>
        </button>
      ))}
    </div>
  );
}

// ─────────── CTO Overview: "Do these 3 first" ───────────

export function DoTheseFirst({ actions, ready, filters, goTo }: { actions: Action[]; ready: boolean; filters: Filters; goTo: GoToFn }) {
  const { week } = rankActions(actions);
  const quick = actions.filter((a) => effortBucket(a.effort) === "quick").length;
  const open = () => goTo({ tab: "actions" });
  return (
    <PatternCard title="Do these 3 first" sub="Picked across the areas, not by $ alone · effort is per object"
      link={actions.length ? `All ${fmtInt(actions.length)} actions →` : null} onLink={open}>
      {!ready ? <div className="chart-note-oneline">…</div>
        : !week.length ? <div className="chart-note-oneline">Nothing flagged that a fix covers.</div>
        : (
          <div className="al-list">
            {week.map((a, i) => <ActionRow key={a.key} a={a} rank={i + 1} windowDays={filters.window} onOpen={open} />)}
          </div>
        )}
      {ready && actions.length > 0 && (
        <div className="pc-foot">
          {`Who has the work: ${teamSplit(actions).map(([t, v]) => `${t} ${fmtInt(v)}`).join(" · ")} of ${fmtInt(actions.length)} actions · ${fmtInt(quick)} take under 15 min per object`}
        </div>
      )}
    </PatternCard>
  );
}

// Fix these first (GET /api/fix-first, contract 11.8): three groups that are never added. Each
// item's usd is the finding's own money.usd, so it agrees with Overview and Waste & savings.
/** One GET /api/fix-first item. */
export interface FixFirstItem {
  query_id: string;
  domain?: string;
  group?: string;
  title?: string;
  usd?: number | null;
  money_reason?: string | null;
  per?: string | null;
  critical?: number | null;
  affected?: { flagged?: number | null; total?: number | null; noun?: string } | null;
  [key: string]: any;
}

/** GET /api/fix-first: the items, their per-group counts and the price basis. */
export interface FixFirstData {
  items?: FixFirstItem[];
  counts?: Record<string, any>;
  price_basis?: { label?: string } | null;
  discount?: { ignored?: boolean; reason?: string } | null;
  note?: string | null;
  [key: string]: any;
}

export interface FixFirstState {
  phase: "loading" | "ready" | "error";
  data: FixFirstData | null;
  error?: string;
}

export function useFixFirst(filters: Filters, limit?: number) {
  const key = JSON.stringify([filters.window, filters.accountIds || [], limit || 10, Api.tagFilterKey(), Api.ownerFilterKey(), Api.dimFilterKey()]);
  const [state, setState] = React.useState<FixFirstState>({ phase: "loading", data: null });
  React.useEffect(() => {
    let live = true;
    setState({ phase: "loading", data: null });
    Api.fixFirst(filters.window, filters.accountIds, limit || 10)
      .then((d: FixFirstData) => { if (live) setState({ phase: "ready", data: d }); })
      .catch((e: any) => { if (live) setState({ phase: "error", data: null, error: e.message || String(e) }); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return state;
}

// Coverage-only ids (data lag) and areas the role cannot open are left out of the lists.
export function fixFirstVisible(items: FixFirstItem[] | null | undefined, allowedAreas?: Set<string> | null) {
  return (items || []).filter((it) => {
    if (COVERAGE_REF_IDS.includes(it.query_id)) return false;
    return !allowedAreas || allowedAreas.has(homeForQuery({ query_id: it.query_id, domain: it.domain }).tab);
  });
}

export function fixFirstUsd(item: FixFirstItem) {
  if (item.usd == null || item.money_reason === "unpriced") return "-";
  return fmtMoney(item.usd, 0) + (item.per === "month" ? "/mo" : "");
}

export function fixFirstAffected(item: FixFirstItem) {
  const a = item.affected;
  if (!a || a.flagged == null || a.total == null) return null;
  return `${fmtInt(a.flagged)} of ${fmtInt(a.total)} ${a.noun}`;
}

export const FIX_FIRST_GROUPS: { key: string; title: (w: number) => string; sub: string }[] = [
  { key: "priced_window", title: (w) => `Priced, last ${w} days`, sub: "possible waste, saving or gap in the window" },
  { key: "priced_month", title: () => "Priced, per month", sub: "storage that could be freed each month" },
  { key: "critical_no_usd", title: () => "Critical, not priced", sub: "critical checks with no $ figure, by area" },
];

// The money kinds "Fix these first" groups by, in order. Each group is its own unit: never added.
export const FIX_KIND_GROUPS: { kind: string; title: (w: number) => string; per: string }[] = [
  { kind: "waste", title: (w) => `Possible waste · last ${w} days`, per: "" },
  { kind: "saving", title: (w) => `Possible saving · last ${w} days`, per: "" },
  { kind: "gap", title: (w) => `Billing gap · last ${w} days`, per: "" },
  { kind: "saving_month", title: () => "Storage that could be freed · per month", per: "/mo" },
];

export function fixKindOf(item: FixFirstItem): string {
  if (item.kind && FIX_KIND_GROUPS.some((g) => g.kind === item.kind)) return item.kind;
  return item.group === "priced_month" ? "saving_month" : "waste";
}

export function openFixItem(item: FixFirstItem, index: Record<string, Finding>, goTo: GoToFn) {
  const row = index[item.query_id] || { query_id: item.query_id, domain: item.domain };
  const home = homeForQuery(row);
  goTo({ tab: home.tab, subtab: home.subtab, focusQueryId: item.query_id });
}

// One ranked row: rank, check, a $ bar scaled to its group's largest, the $ and "N of M".
export function FixItemRow({ item, rank, max, per, onOpen }: { item: FixFirstItem; rank: number; max: number; per: string; onOpen: () => void }) {
  const usd = item.usd != null && item.money_reason !== "unpriced" ? Number(item.usd) : null;
  const w = usd != null && max > 0 ? Math.max(2, (usd / max) * 100) : 0;
  const aff = fixFirstAffected(item);
  const title = getCheckLabel(item.query_id, item.title).title;
  return (
    // A div, not a button, so the row can hold the Guide link beside the title.
    <div role="button" tabIndex={0} className="ff-item" onClick={onOpen}
      onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onOpen(); } }}>
      <span className="ff-item-rank mono">{rank}</span>
      <span className="ff-item-text">
        <span className="ff-item-title" title={title}>{title} <GuideHelp id={item.query_id} label={title} /></span>
        {aff && <span className="ff-item-aff">{aff}</span>}
      </span>
      <span className="ff-item-track" aria-hidden="true">{w > 0 && <span className="ff-item-fill" style={{ width: `${w}%` }} />}</span>
      <span className={`ff-item-usd mono${usd == null && item.group === "critical_no_usd" ? " tone-crit" : ""}`}>
        {usd != null ? `${fmtMoney(usd, 0)}${per}` : item.group === "critical_no_usd" ? "Critical" : "-"}
      </span>
    </div>
  );
}

// "Critical, not priced": how many critical checks with no $ each area holds, one bar per area.
export function CriticalByArea({ items, index, goTo }: { items: FixFirstItem[]; index: Record<string, Finding>; goTo: GoToFn }) {
  const byArea = new Map<string, { tab: string; first: FixFirstItem; n: number }>();
  items.forEach((it) => {
    const home = homeForQuery(index[it.query_id] || { query_id: it.query_id, domain: it.domain });
    const cur = byArea.get(home.tab) || { tab: home.tab, first: it, n: 0 };
    cur.n += 1;
    byArea.set(home.tab, cur);
  });
  const bars = [...byArea.values()].map((a) => ({
    key: a.tab, name: (AREA_REGISTRY[a.tab] || { label: a.tab }).label || a.tab, value: a.n, status: "CRITICAL",
    valueText: `${fmtInt(a.n)} check${a.n === 1 ? "" : "s"}`, first: a.first,
  }));
  return (
    <StatusBars items={bars} n={12} unitLabel="critical checks with no $" ariaLabel="Critical checks with no dollar figure, by area"
      onBarClick={(b) => openFixItem(b.first as FixFirstItem, index, goTo)} emptyText="No critical check without a $ figure." />
  );
}

export function FixFirstGroups({ filters, index, goTo, allowedAreas, perGroup = 5 }: {
  filters: Filters; index: Record<string, Finding>; goTo: GoToFn; allowedAreas: Set<string>; perGroup?: number;
}) {
  // Every item comes back, so the counts follow the role's areas; a few per kind are shown.
  const state = useFixFirst(filters, 500);
  const [expanded, setExpanded] = React.useState<Record<string, boolean>>({});
  if (state.phase === "loading") return <div className="card"><div className="card-title">Fix these first</div><div className="muted">…</div></div>;
  if (state.phase === "error") return <div className="card"><div className="card-title">Fix these first</div><div className="chart-note-oneline">{`Could not load: ${state.error}`}</div></div>;
  const d = state.data!;
  const items = fixFirstVisible(d.items, allowedAreas);
  const priced = items.filter((it) => it.group !== "critical_no_usd");
  const critical = items.filter((it) => it.group === "critical_no_usd");
  const groups = FIX_KIND_GROUPS.map((g) => ({ ...g, all: priced.filter((it) => fixKindOf(it) === g.kind) })).filter((g) => g.all.length);
  return (
    <div className="card ff-card">
      <div className="card-head">
        <div>
          <div className="card-title">Fix these first</div>
          <div className="metric-note">{[d.price_basis && d.price_basis.label, d.discount && d.discount.ignored ? d.discount.reason : null].filter(Boolean).join(". ") || "Largest first, by kind of $. Kinds are never added."}</div>
        </div>
      </div>
      {groups.length === 0 && critical.length === 0 && <div className="muted">Nothing flagged in the checks that ran.</div>}
      <div className="ff-cols">
        {groups.length > 0 && (
          <div className="ff-priced">
            {groups.map((g) => {
              const open = !!expanded[g.kind];
              const shown = open ? g.all : g.all.slice(0, perGroup);
              const max = Math.max(0, ...g.all.map((it) => Number(it.usd) || 0));
              return (
                <div key={g.kind} className="ff-kind">
                  <div className="ff-kind-head"><span>{g.title(filters.window)}</span><span className="faint">{`${fmtInt(g.all.length)} check${g.all.length === 1 ? "" : "s"}`}</span></div>
                  {shown.map((it, i) => <FixItemRow key={it.query_id} item={it} rank={i + 1} max={max} per={g.per} onOpen={() => openFixItem(it, index, goTo)} />)}
                  {g.all.length > perGroup && (
                    <button type="button" className="ov-link-btn ff-more" onClick={() => setExpanded({ ...expanded, [g.kind]: !open })}>
                      {open ? "Show fewer" : `${fmtInt(g.all.length - perGroup)} more`}
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        )}
        {critical.length > 0 && (
          <div className="ff-crit">
            <div className="ff-kind-head"><span>Critical, not priced</span><span className="faint">{`${fmtInt(critical.length)} check${critical.length === 1 ? "" : "s"}`}</span></div>
            <CriticalByArea items={critical} index={index} goTo={goTo} />
          </div>
        )}
      </div>
    </div>
  );
}

// The CTO's "Do these 3 first": the largest priced fixes in the window, then storage, then the
// critical checks with no $.
export function FixTopThree({ filters, index, goTo }: { filters: Filters; index: Record<string, Finding>; goTo: GoToFn }) {
  const state = useFixFirst(filters, 500);
  if (state.phase !== "ready") {
    return <div className="card ff-card"><div className="card-title">Do these 3 first</div><div className="muted">{state.phase === "error" ? `Could not load: ${state.error}` : "…"}</div></div>;
  }
  const items = fixFirstVisible(state.data!.items);
  const inWindow = items.filter((it) => it.group === "priced_window").sort((a, b) => (Number(b.usd) || 0) - (Number(a.usd) || 0));
  const top = [...inWindow, ...items.filter((it) => it.group === "priced_month"), ...items.filter((it) => it.group === "critical_no_usd")].slice(0, 3);
  const max = Math.max(0, ...top.map((it) => (it.group === "priced_window" ? Number(it.usd) || 0 : 0)));
  return (
    <div className="card ff-card">
      <div className="card-title">Do these 3 first</div>
      {top.length === 0 ? <div className="muted">Nothing flagged in the checks that ran.</div>
        : top.map((it, i) => (
          <FixItemRow key={it.query_id} item={it} rank={i + 1} max={it.group === "priced_window" ? max : 0}
            per={it.group === "priced_month" ? "/mo" : ""} onOpen={() => openFixItem(it, index, goTo)} />
        ))}
    </div>
  );
}

// The template noun for a bare count, so a count in the CSV always names its unit.
function actionNoun(a: Action): string {
  const by = a.byCheck && a.byCheck[a.main.query_id];
  const noun = (by && by.noun) || a.noun || [];
  return String((a.n === 1 ? noun[0] : noun[1]) || noun[0] || "");
}

// The fix list as a CSV: money stays in its own kind column, so waste and saving are never summed.
function actionCsvColumns(windowDays: number): CsvColumn<Action>[] {
  return [
    { label: "Fix", value: (a) => a.label },
    { label: "Check", value: (a) => getCheckLabel(a.main.query_id).title },
    { label: "Check id", value: (a) => a.main.query_id },
    { label: "Area", value: (a) => { const t = homeForQuery(a.main).tab; return (AREA_REGISTRY[t] && AREA_REGISTRY[t].label) || t; } },
    { label: "Status", value: (a) => (a.critical ? "Critical" : "Warning") },
    { label: "Money ($, unit in Money kind)", value: (a) => (a.usd != null ? Math.round(a.usd) : "") },
    { label: "Money kind", value: (a) => actionKindWord(a, windowDays).replace(/ · /g, " - ") },
    { label: "Impact note", value: (a) => a.impactText || "" },
    { label: "Flagged", value: (a) => (a.base ? a.base.flagged : a.n != null ? a.n : "") },
    { label: "Total", value: (a) => (a.base ? a.base.total : "") },
    { label: "Unit", value: (a) => (a.base ? a.base.noun : a.n != null ? actionNoun(a) : "") },
    { label: "Flagged checks", value: (a) => a.checkCount },
    { label: "Team", value: (a) => a.team },
    { label: "Effort", value: (a) => a.effort },
    { label: "How", value: (a) => a.how },
  ];
}

const wideScreen = () => { try { return window.matchMedia("(min-width: 1100px)").matches; } catch (e) { return false; } };
const SHOW_ROWS = 12;

// "8 fixes, grouped by who acts on them. 4 of 8 sit with Platform, and 5 of 8 take under 15 minutes per object."
function finopsVerdict(actions: Action[], quick: number): string {
  const n = actions.length;
  const top = teamSplit(actions)[0];
  return [`${fmtInt(n)} fix${n === 1 ? "" : "es"}, grouped by who acts on them.`,
    `${top ? `${fmtInt(top[1])} of ${fmtInt(n)} sit with ${top[0]}, and ` : ""}${fmtInt(quick)} of ${fmtInt(n)} take under 15 minutes per object.`].join(" ");
}

export function ActionsPanel({ filters, dims, allFindingsIndex, goTo, roleAreas, role, onVerdict }: {
  filters: Filters; dims?: Dims | null; allFindingsIndex?: Record<string, Finding> | null; goTo: GoToFn;
  roleAreas?: string[] | null; role?: string | null; onVerdict?: ((verdict: string) => void) | null;
}) {
  useNames();
  const index: Record<string, Finding> = allFindingsIndex || {};
  const { allowedAreas, wt, actions, cc, ccTotal, ccUntagged, untaggedPct, ready } = useActions(index, roleAreas, filters);

  // Spend: the % base for the money tiles.
  const spendAgg = useFindingAgg("cost_dollarized_by_service_day", filters.window, filters.accountIds, ["usage_date"], "sum", COST_MONEY_COL);
  const spend = spendAgg.phase === "ready" && spendAgg.outcome === "ok_rows"
    ? aggTotal(spendAgg.data) : null;

  const ranked = rankActions(actions);
  const weekKeys = new Set(ranked.week.map((a) => a.key));
  const order = [...ranked.week, ...ranked.then];
  const [kind, setKind] = React.useState<string | null>(null);
  const [selectedKey, setSelectedKey] = React.useState<string | null>(() => (wideScreen() ? "__first" : null));
  const [all, setAll] = React.useState(false);
  const shown = order.filter((a) => !kind || a.kind === kind);
  const selected = selectedKey === "__first" ? (shown[0] || null) : (shown.find((a) => a.key === selectedKey) || null);
  const close = React.useCallback(() => setSelectedKey(null), []);

  // Every flagged check the role can see, and how many of them a fix covers.
  const flaggedIds = Object.values(index).filter((row) => {
    const b = bandOf(row);
    return (b === "CRITICAL" || b === "WARN") && !COVERAGE_REF_IDS.includes(row.query_id) && allowedAreas.has(homeForQuery(row).tab);
  }).map((row) => row.query_id);
  const covered = new Set(actions.flatMap((a) => a.rows.map((row) => row.query_id)));
  const uncovered = flaggedIds.filter((id) => !covered.has(id)).length;
  const quick = actions.filter((a) => effortBucket(a.effort) === "quick").length;

  const moneyCount = actions.filter((a) => a.usd != null || !!a.impactText || a.key === "contract").length;
  const verdict = !ready ? null : actions.length
    ? (role === "finops" ? finopsVerdict(actions, quick)
      : role === "cfo"
      ? `${fmtInt(Math.min(5, moneyCount))} action${moneyCount === 1 ? "" : "s"} that move money, out of ${fmtInt(actions.length)} the audit found; ${fmtInt(quick)} take under 15 minutes per object.`
      : `${fmtInt(actions.length)} action${actions.length === 1 ? "" : "s"} from ${fmtInt(flaggedIds.length)} flagged checks; ${fmtInt(quick)} take under 15 minutes per object.`)
    : "Nothing flagged that a fix on this page covers.";
  React.useEffect(() => { if (onVerdict && verdict) onVerdict(verdict); }, [verdict, onVerdict]);

  // Tiles: label · number + unit · mono base · one line. Kinds of money are never added.
  const notRun = (fig: { ran: number }) => (fig.ran > 0 ? "flagged, not priced in this export" : "none of these checks ran");
  const checksWord = (n: number) => `${fmtInt(n)} check${n === 1 ? "" : "s"}`;
  const wasteTile = (
    <IssueTile key="waste" label="Possible waste" loading={!ready}
      headline={wt.waste.usd != null ? fmtMoney(wt.waste.usd, 0) : null} unit={`last ${filters.window} days`} missingReason={notRun(wt.waste)}
      base={wt.waste.usd != null ? (spend ? `${fmtShare(pctOf(wt.waste.usd, spend))} of spend, across ${checksWord(wt.waste.flagged)}.` : `Across ${checksWord(wt.waste.flagged)}.`) : null}
      onOpen={() => goTo({ tab: "waste" })} openLabel="Waste & savings →" />
  );
  const savingTile = (
    <IssueTile key="saving" label="Possible saving" loading={!ready}
      headline={wt.saving.usd != null ? fmtMoney(wt.saving.usd, 0) : null} missingReason={notRun(wt.saving)}
      unit={wt.saving.usd != null && spend ? `${fmtShare(pctOf(wt.saving.usd, spend))} of spend` : undefined}
      base={wt.saving.usd != null ? `From resizing, across ${checksWord(wt.saving.flagged)}. Counted apart from waste.` : null}
      onOpen={() => goTo({ tab: "waste" })} openLabel="Waste & savings →" />
  );
  const storageTile = (
    <IssueTile key="storage" label="Storage to free" loading={!ready}
      headline={wt.month.usd != null ? fmtMoney(wt.month.usd, 0) : null} unit="per month" missingReason={notRun(wt.month)}
      base={wt.month.usd != null ? `${checksWord(wt.month.flagged)}.` : null}
      cause={overlapNote(wt.month, (v) => fmtMoney(v, 0))}
      onOpen={() => goTo({ tab: "storage" })} openLabel="Storage →" />
  );
  const untaggedTile = (
    <IssueTile key="untagged" label="No cost center" loading={cc.phase === "loading"}
      headline={untaggedPct != null ? fmtShare(untaggedPct) : null} unit="of the split"
      missingReason={cc.data ? "no cost-center split for this window" : "cost-center split not in this export"}
      base={untaggedPct != null && ccUntagged != null ? `${fmtMoney(ccUntagged, 0)} of ${fmtMoney(ccTotal, 0)} has no cost center tag.` : null}
      status={untaggedPct != null && untaggedPct > 20 ? "warn" : "neutral"}
      onOpen={() => goTo({ tab: "cost", subtab: "chargeback" })} openLabel="Chargeback & tags →" />
  );
  const secAll = Object.values(index).filter((row) => row.domain === "governance_access" && allowedAreas.has(homeForQuery(row).tab));
  const secFlagged = secAll.filter((row) => { const b = bandOf(row); return b === "CRITICAL" || b === "WARN"; });
  const secCritical = secFlagged.filter((row) => bandOf(row) === "CRITICAL").length;
  const risks = actions.filter((a) => a.kind === "risk");
  const secTile = (
    <IssueTile key="sec" label="Security checks flagged" loading={!ready} headline={fmtInt(secFlagged.length)} unit={`of ${fmtInt(secAll.length)} checks`}
      base={`${fmtInt(secCritical)} critical · ${fmtInt(risks.length)} with a fix here`} status={secCritical ? "critical" : secFlagged.length ? "warn" : "ok"} />
  );
  const tf = index.sf_task_failures;
  const tfAff = tf && tf.affected;
  const taskTile = (
    <IssueTile key="tasks" label="Tasks failing" loading={!ready} headline={tfAff ? fmtShare(pctOf(tfAff.flagged, tfAff.total)) : null} unit="of tasks"
      missingReason={tf ? ((tf.not_assessed && tf.not_assessed.label) || "did not run") : "not in this export"}
      base={tfAff ? `${fmtInt(tfAff.flagged)} of ${fmtInt(tfAff.total)} ${tfAff.noun}` : null}
      status={tfAff && tfAff.flagged > 0 ? (bandOf(tf) === "CRITICAL" ? "critical" : "warn") : "neutral"}
      onOpen={() => goTo({ tab: "tasks", subtab: "failures" })} openLabel="Tasks › Failures →" />
  );
  const otherTile = (
    <IssueTile key="other" label="Other flagged checks" loading={!ready} headline={fmtInt(uncovered)} unit={`of ${fmtInt(flaggedIds.length)} checks`}
      base="no fix template yet" onOpen={() => goTo({ tab: "findings" })} openLabel="All findings →" />
  );
  // CFO: the auto-suspend saving leads; resizing is a second estimate of the same minutes.
  const autostop = actions.find((a) => a.key === "warehouse_autostop" && a.usd != null && a.unit === "saving");
  const autostopTile = autostop ? (
    <IssueTile key="autostop" label="Possible saving" loading={!ready} pill={<KindChip>{`${filters.window} d`}</KindChip>}
      headline={fmtMoney(autostop.usd, 0)}
      base={["auto-suspend", autostop.base ? `${fmtInt(autostop.base.flagged)} of ${fmtInt(autostop.base.total)} ${autostop.base.noun}` : null, `${filters.window} d`].filter(Boolean).join(" · ")}
      cause={wt.saving.usd != null ? `Resizing is a second estimate, ${fmtMoney(wt.saving.usd, 0)}: the two overlap and are not added.` : null}
      onOpen={() => setSelectedKey(autostop.key)} openLabel="Open →" />
  ) : savingTile;
  // Governance: one tile per risk, from the check's own "n of m".
  const actionFor = (id: string) => { const i = order.findIndex((a) => a.checks.includes(id)); return i >= 0 ? { a: order[i], rank: i + 1 } : null; };
  const riskTile = (key: string, label: string, id: string, tab: string, subtab: string, link: string) => {
    const f = index[id];
    const b = f ? bandOf(f) : null;
    const a = f && f.affected && f.affected.total ? f.affected : null;
    const by = actionFor(id);
    if (!f || b === "NOT_ASSESSED" || b === "ERROR") {
      return <IssueTile key={key} label={label} loading={!ready} headline={null} status={ready ? "not_assessed" : "neutral"}
        missingReason={f && f.not_assessed && f.not_assessed.label ? f.not_assessed.label : "not in this export"} onOpen={() => goTo({ tab, subtab, focusQueryId: id })} openLabel={link} />;
    }
    return (
      <IssueTile key={key} label={label} loading={!ready} status={a && a.flagged === 0 ? "ok" : b === "CRITICAL" ? "critical" : b === "WARN" ? "warn" : "ok"}
        headline={a ? fmtShare(pctOf(a.flagged, a.total)) : null} unit={a ? `of ${a.noun}` : undefined} missingReason="no count for this check"
        base={a ? `${fmtInt(a.flagged)} of ${fmtInt(a.total)} ${a.noun}${f.windowed === false ? " · snapshot" : ` · ${filters.window} d`}` : null}
        cause={by ? `Action ${fmtInt(by.rank)}: ${by.a.label}.` : null}
        onOpen={by ? () => setSelectedKey(by.a.key) : () => goTo({ tab, subtab, focusQueryId: id })} openLabel={by ? "Open →" : link} />
    );
  };
  const govTiles = [
    riskTile("mfa", "No MFA", "sf_sec_users_without_mfa", "access", "users", "Users & sign-ins →"),
    riskTile("pii", "Unmasked PII", "sf_gov_sensitive_columns_unprotected", "pii", "sensitive", "PII & policies →"),
    riskTile("public", "Reachable by PUBLIC", "sf_gov_public_role_grants", "access", "roles", "Roles & grants →"),
    riskTile("broad", "Broad grants", "access_broad_grants", "access", "roles", "Roles & grants →"),
  ];
  const tiles: React.ReactNode[] = role === "governance" ? (index.sf_sec_users_without_mfa || index.access_broad_grants ? govTiles : [secTile, otherTile])
    : role === "data_engineer" ? [taskTile, wasteTile, savingTile, otherTile]
    : role === "cfo" ? [autostopTile, wasteTile, storageTile, untaggedTile]
    : [wasteTile, savingTile, storageTile, untaggedTile];

  const weekShown = shown.filter((a) => weekKeys.has(a.key));
  const thenAll = shown.filter((a) => !weekKeys.has(a.key));
  const thenShown = all ? thenAll : thenAll.slice(0, Math.max(0, SHOW_ROWS - weekShown.length));
  const row = (a: Action, i: number) => (
    <ActionRow key={a.key} a={a} rank={i + 1} windowDays={filters.window} selected={!!selected && selected.key === a.key}
      onOpen={() => setSelectedKey(selected && selected.key === a.key ? null : a.key)} />
  );
  // CFO: the fixes that move money, then the rest named on one line each. FinOps: grouped by kind.
  const movesMoney = (a: Action) => a.usd != null || !!a.impactText || a.key === "contract";
  const moneyList = role === "cfo" && !kind ? order.filter(movesMoney).slice(0, 5) : null;
  const restList = moneyList ? order.filter((a) => !moneyList.includes(a)) : [];
  const kindGroups = role === "finops" && !kind
    ? ACTION_KIND_ORDER.map((k) => ({ k, list: shown.filter((a) => a.kind === k) })).filter((g) => g.list.length) : null;
  let listBody: React.ReactNode;
  if (moneyList) {
    listBody = (
      <div className="al-list">
        <div className="al-group">{`The ${fmtInt(moneyList.length)} that move money · each in its own kind, never added`}</div>
        {moneyList.map((a, i) => row(a, i))}
        <NotOnListRows actions={restList} onOpen={(a) => setSelectedKey(a.key)} />
      </div>
    );
  } else if (kindGroups) {
    let rank = 0;
    listBody = (
      <div className="al-list">
        {kindGroups.map((g) => (
          <React.Fragment key={g.k}>
            <div className="al-group">{`${ACTION_KIND_LABEL[g.k]} · ${fmtInt(g.list.length)}`}</div>
            {g.list.map((a) => { rank += 1; return row(a, rank - 1); })}
          </React.Fragment>
        ))}
      </div>
    );
  } else {
    listBody = (
      <div className="al-list">
        {weekShown.length > 0 && <div className="al-group">This week</div>}
        {weekShown.map((a, i) => row(a, i))}
        {thenShown.length > 0 && <div className="al-group">Then</div>}
        {thenShown.map((a, i) => row(a, weekShown.length + i))}
        {thenAll.length > thenShown.length && (
          <button type="button" className="ck-link" onClick={() => setAll(true)}>{`Show ${fmtInt(thenAll.length - thenShown.length)} more`}</button>
        )}
      </div>
    );
  }

  return (
    <div>
      <KpiRow className="al-kpi">{tiles}</KpiRow>
      <WorkSplitCards actions={actions} role={role} second={role === "cfo" ? <ContractBurnCard filters={filters} goTo={goTo} /> : null} />
      <div className={`dr-layout${selected ? " open" : ""}`}>
        <div className="dr-main">
          <div className="card al-card">
            <div className="al-tabs" role="group" aria-label="Filter by kind">
              {[null, ...ACTION_KIND_ORDER].map((k) => {
                const count = k ? actions.filter((a) => a.kind === k).length : actions.length;
                if (k && !count) return null;
                return (
                  <button key={k || "all"} type="button" className={`al-tab${kind === k ? " on" : ""}`} aria-pressed={kind === k}
                    onClick={() => { setKind(k); setSelectedKey(wideScreen() ? "__first" : null); setAll(false); }}>
                    {`${k ? ACTION_KIND_LABEL[k] : "All"} `}<span className="al-tab-n">{fmtInt(count)}</span>
                  </button>
                );
              })}
              {ready && <span className="al-csv"><CsvButton fileName={`actions-${kind || "all"}`} columns={actionCsvColumns(filters.window)} rows={shown} /></span>}
            </div>
            {!ready ? <div className="chart-note-oneline">…</div>
              : shown.length === 0 ? <div className="chart-note-oneline">No fix of this kind for the checks flagged in this window.</div>
              : listBody}
          </div>
          {ready && uncovered > 0 && (
            <div className="nj-strip">
              <span className="cx-ck-summary">{`${fmtInt(uncovered)} of ${fmtInt(flaggedIds.length)} flagged checks have no fix template here yet.`}</span>
              <span className="nj-spacer" />
              <button type="button" className="ck-link" onClick={() => goTo({ tab: "findings" })}>{"All findings →"}</button>
            </div>
          )}
        </div>
        {selected && <ActionDrawer key={selected.key} action={selected} filters={filters} dims={dims} goTo={goTo} onClose={close} />}
      </div>
    </div>
  );
}
AreaContent.register("actions", null, ActionsPanel);
