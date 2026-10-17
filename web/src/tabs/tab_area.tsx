// web/src/tabs/tab_area.tsx -- the content every drill-down sub-tab opens with, charts first:
// up to four tiles (a label, a number, one line and a link) and up to two charts from the checks the
// sub-tab owns. The checks table (findings_table.tsx) follows for drill-down. Nothing here knows a
// check by name: a tile reads the check's own `money`/`affected` off GET /api/findings, and a chart
// reads the money column and the entity column the check itself returns. A check that did not run
// reads "-" and why, never $0; a figure still loading reads "…".
//
// Sub-tabs with a bespoke page (Overview, Cost > Trend, Waste, Actions, Coverage, ...) register their
// own content; every other sub-tab is registered here with registerAreaContent().

// "context" is a $ that explains another check's figure (idle cost behind an auto-suspend saving):
// shown, never counted as waste.
import React from "react";
import { fmtDayShort, fmtInt, fmtMoneyOf } from "../format";
import { TaskFocus, resolveName } from "../components/names";
import { numOrZero, taskName, useFindingData, warehouseName } from "../components/hooks";
import type { DimMaps } from "../components/hooks";
import { dimNotApplied } from "../components/filters";
import { AREA_REGISTRY } from "../components/tab_registry";
import { Card, ChartCard, KindChip, bandOf } from "../components/primitives";
import { DrawerBus } from "../components/drawer";
import { AreaContent } from "../area_content";
import { getCheckLabel } from "../components/labels";
import { ChartNote } from "../components/charts";
import { TagRollupView } from "../components/tag_rollup";
import { Columns, DivergingBars, EmptyChart, RankedBars } from "../components/charts_more";
import { isSettingColumn } from "../components/columns";
import { SummaryTile, SummaryTileRow, partialBarKeys, tileFromFinding, windowShortLabel } from "../components/overview_tile";
import { moneyKindOf } from "../components/waste_total";
import { AREA_CHART_PAGES } from "../components/area_pages";
import { COMPUTE_PAGES } from "../components/area_compute";
import type { Dims, FetchState, Filters, Finding, GoToFn, Meta, Row } from "../types";
import { GuideHelp } from "../components/guide_links";

/** A column as GET /api/finding lists it. */
type Col = { name: string; [key: string]: any };

export const MONEY_KIND_WORD: Record<string, string> = {
  waste: "possible waste", saving: "possible saving", saving_month: "possible saving per month", spend: "spend", spend_month: "storage",
  change: "change vs previous period", gap: "gap", balance: "balance", context: "context, not counted as waste",
};
export const MONEY_KIND_ORDER: Record<string, number> = { waste: 0, saving: 1, saving_month: 2, change: 3, spend: 4, spend_month: 5, gap: 6, balance: 7, context: 8 };

// A check's money column is monthly (storage) rather than over the window.
export function moneyPeriodWord(col: string | null | undefined, kind?: string | null) {
  if (kind === "saving_month" || kind === "spend_month") return "per month";
  return /_usd_month(_|$)/.test(String(col || "")) ? "per month" : null;
}

// Checks whose $ is an upper bound (the storage a backup set may hold), read "up to $X", never a plain amount.
export const UPPER_BOUND_IDS = new Set(["sf_storage_backup_snapshot"]);
export function upToWord(f: Finding | null | undefined) { return f && UPPER_BOUND_IDS.has(f.query_id) ? "up to " : ""; }

// A figure's currency word lives in format.tsx; re-exported for the pages that import it from here.
export { fmtMoneyOf } from "../format";

// The columns that can label a bar, most specific first. A database/schema/table triple reads as
// one dotted name; a task or warehouse resolves to its name.
export const LABEL_COLUMNS = [
  "dt_full_name", "task_full_name", "job_id", "pipe_name", "pipe_full_name", "dynamic_table_name", "dt_name", "table_fqn", "tag_value", "compute_pool_name", "budget_name",
  "root_task_name", "runtime_name", "notebook_name", "model_name", "alert_full_name", "stage_full_name", "set_name", "listing_global_name",
  "tag_name", "source_view", "app_fqn", "app_name", "stage_scope", "statement_shape", "client", "warehouse_name", "warehouse", "warehouse_id", "throughput_name", "pipe_display_name",
  "object_name", "integration_name", "policy_name", "group_name", "reader_account_name",
  "account_name", "role_name", "user_name", "principal", "grantee", "client_application", "tool", "usage_type", "service_type",
  "sku_name", "billing_origin_product", "query_tag", "feature", "database_name", "schema_name", "row_type",
];

// What a row with no entity reads as, by the column that would have named it.
export const EMPTY_LABELS: Record<string, string> = {
  pipe_name: "(no pipe)", pipe_full_name: "(no pipe)", tag_value: "(untagged)", compute_pool_name: "(no compute pool)",
  dt_full_name: "(no dynamic table)", dt_name: "(no dynamic table)", budget_name: "(no budget)", app_name: "(no app)", app_fqn: "(no app)",
  warehouse_name: "(no warehouse)", warehouse_id: "(no warehouse)", warehouse: "(no warehouse)", user_name: "(no user)", role_name: "(no role)",
  query_tag: "(no query tag)", stage_scope: "(no stage)", root_task_name: "(no task)", set_name: "(no backup set)",
};
export function emptyLabelFor(labelCol: string | null) {
  return EMPTY_LABELS[labelCol as string] || "(unattributed)";
}

// `avoid` skips a label the chart beside it already uses, so two charts never draw the same bars.
export function pickLabelColumn(cols: Col[] | null | undefined, avoid?: string | null) {
  const names = new Set((cols || []).map((c) => c.name));
  if (names.has("table_name") && avoid !== "table_name") return "table_name";
  return LABEL_COLUMNS.find((n) => names.has(n) && n !== avoid) || LABEL_COLUMNS.find((n) => names.has(n)) || null;
}
const TASK_LABELS = new Set(["task_full_name", "job_id"]);

// A warehouse always reads name (id) when the row carries its id, the same as Money's top 10.
export function warehouseNameId(row: Row, rawName: string | null) {
  const id = row.warehouse_id;
  if (id === null || id === undefined || id === "") return rawName;
  const name = rawName || resolveName("warehouse", null, id) || String(id);
  return `${name} (${id})`;
}

export function rowLabelOf(row: Row, labelCol: string | null, dims: Dims) {
  if (!labelCol) return null;
  const raw = row[labelCol];
  if (raw === null || raw === undefined || raw === "") return null;
  if (labelCol === "table_name") {
    return [row.database_name, row.schema_name, raw].filter((p) => p !== null && p !== undefined && p !== "").join(".");
  }
  if (labelCol === "schema_name") return [row.database_name, raw].filter((p) => p !== null && p !== undefined && p !== "").join(".");
  // A warehouse in no SHOW and not dropped is "not visible to this role", never "deleted".
  const hidden = row.warehouse_not_visible === true ? " - not visible to this role" : "";
  if (labelCol === "warehouse_id") return warehouseNameId(row, warehouseName(dims as DimMaps, raw)) + hidden;
  if (labelCol === "warehouse_name" || labelCol === "warehouse") return warehouseNameId(row, String(raw)) + hidden;
  // A root task reads name (id), never the bare id.
  if (labelCol === "root_task_name") return row.root_task_id ? `${raw} (${row.root_task_id})` : String(raw);
  if (labelCol === "task_full_name" || labelCol === "job_id") return taskName(dims as DimMaps, raw);
  return String(raw);
}

// The rows a bar chart may add up without counting the same money twice: no total or tie-out row
// next to its parts (the core marks them `is_total_row`), and one basis when the rows repeat per basis.
export function withoutTotalRows(rows: Row[] | null | undefined): Row[] {
  return (rows || []).filter((r) => !r.is_total_row);
}
export function chartRowsFor(rows: Row[], cols: Col[] | null | undefined, valueOf: (r: Row) => number) {
  const names = new Set((cols || []).map((c) => c.name));
  let out = withoutTotalRows(rows);
  let basis: [any, number] | null = null;
  if (names.has("basis")) {
    const totals = new Map<any, number>();
    out.forEach((r) => totals.set(r.basis, (totals.get(r.basis) || 0) + valueOf(r)));
    basis = [...totals.entries()].sort((a, b) => b[1] - a[1])[0];
    if (basis) out = out.filter((r) => r.basis === basis![0]);
  }
  return { rows: out, basis: basis ? String(basis[0]) : null };
}

// The dollar column a bar chart ranks by: the check's own money column when it is a spend, waste or
// saving figure; else the first current-period dollar column (a chargeback's usd_list rather than
// its change).
export function pickValueColumn(cols: Col[] | null | undefined, f?: Finding | null) {
  const names = (cols || []).map((c) => c.name);
  const m = f && f.money;
  if (m && names.includes(m.column!) && !isSettingColumn(m.column)) return m.column;
  const skip = /_disc$|prev|previous|baseline|per_|_share|_pct|change|gap|_by_|price/;
  // A setting (auto-suspend, cluster count, size, retention days) is never a value to rank or chart.
  const cands = names.filter((n) => /usd/.test(n) && !skip.test(n) && !isSettingColumn(n));
  return cands.find((n) => /current|window|^usd_list$|^est_usd_list$/.test(n)) || cands[0] || null;
}

export function pickDayColumn(cols: Col[] | null | undefined) {
  const hit = (cols || []).find((c) => /^(usage_date|day|date|month_start)$/.test(c.name));
  return hit ? hit.name : null;
}

export function findingForId(findings: Finding[] | null | undefined, id: string) {
  return (findings || []).find((f) => f.query_id === id) || null;
}

// One check's chart: a daily column chart when its rows span at least four days, else the top rows
// as ranked bars. Reads a useFindingData state, so a loading, empty or not-assessed check says so
// in the chart's own slot.
export interface CheckChartCardProps {
  f: Finding;
  state: FetchState;
  dims: Dims;
  maxCat?: number;
  meta: Meta;
  filters: Filters;
  onOpen: () => void;
  /** The label column the chart beside this one uses. */
  avoidLabel?: string | null;
}
export function CheckChartCard({ f, state, dims, maxCat, meta, filters, onOpen, avoidLabel }: CheckChartCardProps) {
  const label = getCheckLabel(f.query_id, f.title);
  const kind = moneyKindOf(f);
  const m = f.money;
  // The tile sums the money column over the rows the core says it counts (`basis`); the chart reads
  // the same column over the same rows and skips total rows, so the two show one figure.
  const onlyFlagged = !!m && m.basis === "flagged";
  const rows0 = readyRowsOf(state);
  const rows = rows0 ? withoutTotalRows(rows0).filter((r) => !onlyFlagged || r.status === "CRITICAL" || r.status === "WARN") : rows0;
  const cols = state && state.data && state.data.columns;
  const valueCol = rows ? pickValueColumn(cols, f) : null;
  const dayCol = rows ? pickDayColumn(cols) : null;
  const subtitle = [upToWord(f) ? "upper bound" : null, moneyPeriodWord(valueCol, kind) || windowShortLabel(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days), kind ? MONEY_KIND_WORD[kind as string] : null].filter(Boolean).join(" · ");
  let body: React.ReactNode;
  let basisNote: string | null = null;
  if (!rows) {
    body = <ChartNote state={state} label={f.query_id} />;
  } else if (m && m.mixed_currency) {
    body = <EmptyChart text="These amounts are in more than one currency, so they are not charted or added; the rows are below." />;
  } else if (!valueCol) {
    body = <EmptyChart text="This check has no dollar column to chart; the rows are below." />;
  } else {
    // Invoice-currency amounts are never discounted.
    const disc = state.data && !(m && m.unit === "currency") ? numOrZero(state.data.discount_pct) : 0;
    const val = (r: Row) => numOrZero(r[valueCol]) * (1 - disc);
    const days = dayCol ? [...new Set(rows.map((r) => String(r[dayCol]).slice(0, 10)))].sort() : [];
    if (days.length >= 4) {
      const totals = new Map<string, number>(days.map((d) => [d, 0]));
      rows.forEach((r) => { const d = String(r[dayCol!]).slice(0, 10); totals.set(d, totals.get(d)! + val(r)); });
      const partial = partialBarKeys(days, dayCol === "month_start");
      body = (
        <Columns
          days={days}
          series={[{ name: label.title, values: days.map((d) => totals.get(d)) }]}
          partialDays={partial}
          note={partial.length ? (dayCol === "month_start" ? "The faded bar is the month in progress: partial." : `The faded bar is today (${fmtDayShort(partial[0])}): partial.`) : null}
          valueFmt={(v: number) => `${upToWord(f)}${fmtMoneyOf(m, v, 0)}`} unitLabel={m && m.unit === "currency" ? (m.currency || "") : "$"} dollarAxis={!(m && m.unit === "currency")} ariaLabel={label.title}
        />
      );
    } else {
      const labelCol = pickLabelColumn(cols, avoidLabel);
      const names = new Set((cols || []).map((c: Col) => c.name));
      // A check that carries the previous period draws the change, which its title promises.
      const changeCol = names.has("change_amount") && names.has("prev_amount") ? "change_amount" : null;
      const agg = new Map<string, { value: number; accountId: any; id: any }>();
      const picked = chartRowsFor(rows, cols, val);
      picked.rows.forEach((r) => {
        const k = rowLabelOf(r, labelCol, dims) || emptyLabelFor(labelCol);
        const cur = agg.get(k) || { value: 0, accountId: r.account_id, id: labelCol ? r[labelCol] : null };
        cur.value += changeCol ? numOrZero(r[changeCol]) * (1 - disc) : val(r);
        agg.set(k, cur);
      });
      // The "(no ...)" bucket is drawn hatched and never folded into Other, as on the tag charts.
      const empty = emptyLabelFor(labelCol);
      const fmt = (v: number) => `${upToWord(f)}${fmtMoneyOf(m, v, 0)}`;
      const unit = m && m.unit === "currency" ? (m.currency || "") : "$";
      if (picked.basis) basisNote = `by ${picked.basis.replace(/_/g, " ")}`;
      if (changeCol) {
        basisNote = [basisNote, "change vs the previous period"].filter(Boolean).join(" · ");
        const items = [...agg.entries()].map(([name, v]) => ({ name, value: v.value }));
        body = <DivergingBars items={items} n={maxCat || 8} valueFmt={(v: number) => `${v > 0 ? "+" : ""}${fmt(v)}`} unitLabel={unit} ariaLabel={`${label.title}: change`} />;
      } else {
        const items = [...agg.entries()].map(([name, v]) => ({ name, value: v.value, untagged: name === empty, accountId: v.accountId, taskId: v.id })).filter((it) => it.value > 0);
        // A task bar opens the task panel.
        const onTask = labelCol && TASK_LABELS.has(labelCol) ? (it: Row) => { if (it.taskId != null) TaskFocus.open(it.accountId, it.taskId); } : null;
        // Any other bar opens the check's drawer on that one object's rows.
        const onBar = (it: Row) => { if (it.untagged || it.taskId == null) DrawerBus.open({ id: f.query_id }); else DrawerBus.open({ id: f.query_id, col: labelCol, val: String(it.taskId), label: String(it.name) }); };
        body = <RankedBars items={items} n={maxCat || 8} valueFmt={fmt} unitLabel={unit} ariaLabel={label.title} emptyText="Every value is zero in this window." onItemClick={onTask || onBar} />;
      }
    }
  }
  return (
    <ChartCard title={<React.Fragment>{label.title} <GuideHelp id={f.query_id} label={label.title} /></React.Fragment>} subtitle={[subtitle, basisNote].filter(Boolean).join(" · ")} onOpenCheck={onOpen} takeaway={null}>
      {body}
    </ChartCard>
  );
}

export function readyRowsOf(state: FetchState | null | undefined): Row[] | null {
  return state && state.phase === "ready" && state.outcome === "ok_rows" ? state.data!.rows : null;
}

// Checks whose $ repeats another check's figure (the idle time seen again): never a tile of their own.
const CONTEXT_TILE_IDS = new Set(["sf_cost_warehouse_idle_credits_daily", "sf_task_warehouse_vs_serverless"]);

const SEVERITY_RANK: Record<string, number> = { CRITICAL: 0, WARN: 1, OK: 2, RANKED: 2, INVENTORY: 3, EMPTY_WINDOW: 3, EMPTY_FILTERS: 3, NOT_ASSESSED: 4, ERROR: 4 };

// Which owned checks get a tile. The set is fixed per sub-tab (the lead, then registry order), so a
// tile never changes identity with the window; within it, Critical comes first, then the larger $.
export function pickTileChecks(owned: Finding[], n: number, leadId?: string | null) {
  const pool = owned.filter((f) => !CONTEXT_TILE_IDS.has(f.query_id));
  const lead = leadId ? pool.find((f) => f.query_id === leadId) : null;
  const set = (lead ? [lead, ...pool.filter((f) => f !== lead)] : pool).slice(0, n);
  const usd = (f: Finding) => (f.money && Number.isFinite(Number(f.money.usd)) ? Number(f.money.usd) : -1);
  return set.map((f, i) => ({ f, i })).sort((a, b) =>
    (SEVERITY_RANK[bandOf(a.f)] ?? 3) - (SEVERITY_RANK[bandOf(b.f)] ?? 3) || usd(b.f) - usd(a.f) || a.i - b.i).map((x) => x.f);
}

// One base per noun on a page: the largest population any of its checks counted, so every tile
// on the page reads "N of the same M".
export function pagePopulations(owned: Finding[]): Record<string, number> {
  const out: Record<string, number> = {};
  owned.forEach((f) => {
    const a = f.affected;
    if (a && a.noun && Number.isFinite(Number(a.total))) out[a.noun] = Math.max(out[a.noun] || 0, Number(a.total));
  });
  return out;
}

// A check that reads the account as it is now, not over the window.
export function isSnapshot(f: Finding | null | undefined) { return !!f && f.windowed === false; }

export function tileForCheck(f: Finding, area: string, subtab: string, goTo: GoToFn, pops?: Record<string, number>) {
  const label = getCheckLabel(f.query_id, f.title).title;
  const m = f.money;
  const band = bandOf(f);
  const period = m ? moneyPeriodWord(m.column, m.kind) : null;
  const a = f.affected;
  const base = a ? Math.max(Number(a.total) || 0, (pops && pops[a.noun]) || 0) : 0;
  // The check assessed fewer than the page's base: said once, after the count.
  const assessed = a && base > Number(a.total) ? ` (${fmtInt(a.total)} assessed)` : "";
  // The mono base line: "17 of 56 warehouses flagged".
  const flagged = a ? `${fmtInt(a.flagged)} of ${fmtInt(base)} ${a.noun}${assessed} flagged` : null;
  const kindWord = MONEY_KIND_WORD[moneyKindOf(f) as string] || null;
  // The figure's unit is its kind, then its period when the kind does not already say it.
  const moneyUnit = [kindWord, period && !(kindWord || "").includes(period) ? period : null].filter(Boolean).join(" ");
  const zeroUnpriced = !!m && m.usd != null && m.unit !== "currency" && Number(m.usd) === 0 && !(Number(m.usd_flagged) > 0);
  // A count leads with its share of the base, the count itself on the base line.
  const countFigure = (extra: string | null) => {
    const pct = base > 0 && Number(a.flagged) > 0 ? (100 * Number(a.flagged)) / base : null;
    return pct != null
      ? { value: `${pct < 10 && pct % 1 ? pct.toFixed(1) : Math.round(pct)}%`, unit: ` of ${a.noun} flagged`, base: flagged, reading: extra }
      : { value: fmtInt(a.flagged), unit: ` flagged`, base: `${fmtInt(a.flagged)} of ${fmtInt(base)} ${a.noun}${assessed}`, reading: extra };
  };
  let figure: { value: string; unit: string | null; base?: string | null; reading: string | null } | null = null;
  if (f.money_reason === "unpriced" || zeroUnpriced) {
    // Ran and flagged nothing: "nothing flagged", never "not priced". Flagged but unpriced: the count.
    if (band === "OK") figure = a ? { ...countFigure(null), reading: "nothing flagged" } : { value: "0", unit: " flagged", reading: "nothing flagged" };
    else if (a) figure = countFigure("not priced");
    else figure = { value: "-", unit: null, reading: "not priced" };
  } else if (m && m.mixed_currency) {
    figure = { value: "-", unit: null, reading: "more than one currency: not added" };
  } else if (m && Number.isFinite(Number(m.usd))) {
    const part = m.basis === "all" && m.usd_flagged != null && a && a.flagged > 0 && a.flagged < a.total;
    // An every-row figure (spend, context) leads with the flagged rows' part, the whole after it.
    if (part) figure = {
      value: fmtMoneyOf(m, m.usd_flagged, 0),
      unit: moneyUnit ? ` ${moneyUnit}` : null,
      base: [`of ${fmtMoneyOf(m, m.usd, 0)}`, flagged].join(" · "),
      reading: null,
    };
    else figure = {
      value: `${upToWord(f)}${fmtMoneyOf(m, m.usd, 0)}`,
      unit: moneyUnit ? ` ${moneyUnit}` : null,
      base: flagged,
      reading: null,
    };
  } else if (a) {
    figure = countFigure(null);
  } else if (f.row_count != null) {
    figure = { value: fmtInt(f.row_count), unit: " rows", reading: f.status_counts ? "in this check" : "listed" };
  }
  const t = tileFromFinding(label, f, false, figure);
  const notRun = t.severity === "not_assessed";
  const notFiltered = dimNotApplied(f.dim_applied);
  let reading = notRun ? (f.not_assessed && f.not_assessed.label) || String(t.reading || "").replace(/^Not assessed: /, "") : t.reading;
  if (notFiltered.length && !notRun) reading = [reading, `not filtered by ${notFiltered.join(" or ")}`].filter(Boolean).join(" · ");
  const kind = moneyKindOf(f);
  // A spend or context figure carries no status: its kind is the chip.
  const pill = !notRun && t.severity === "neutral" && kind ? <KindChip>{kind === "context" ? "Context" : capitalizeWord(kindWord || kind)}</KindChip> : undefined;
  return {
    ...t,
    facts: undefined,
    base: figure && !notRun ? figure.base : null,
    reading,
    pill,
    scope: isSnapshot(f) ? "Snapshot: the window does not apply" : undefined,
    // A check that did not run links to what to grant; one that ran opens its drawer.
    href: notRun ? "What to grant" : "Open check",
    onClick: notRun ? () => goTo({ tab: "coverage", subtab: null }) : () => goTo({ tab: area, subtab, focusQueryId: f.query_id }),
  };
}

function capitalizeWord(s: string) { return s ? s[0].toUpperCase() + s.slice(1) : s; }

// The verdict sentence: how many checks flagged, how many did not run. Counts name their unit.
export function subtabVerdict(owned: Finding[]) {
  if (!owned.length) return null;
  let crit = 0, warn = 0, notRun = 0;
  owned.forEach((f) => {
    const b = bandOf(f);
    if (b === "CRITICAL") crit += 1;
    else if (b === "WARN") warn += 1;
    else if (b === "NOT_ASSESSED" || b === "ERROR") notRun += 1;
  });
  const parts: string[] = [];
  const flagged = crit + warn;
  parts.push(flagged
    ? `${fmtInt(flagged)} of ${fmtInt(owned.length)} checks flagged${crit ? ` (${fmtInt(crit)} critical)` : ""}`
    : `Nothing flagged in the ${fmtInt(owned.length - notRun)} of ${fmtInt(owned.length)} checks that ran`);
  if (notRun && flagged) parts.push(`${fmtInt(notRun)} did not run`);
  else if (notRun) parts.push(`${fmtInt(notRun)} did not run (see Coverage & Gaps)`);
  return `${parts.join("; ")}.`;
}

/** One sub-tab of AREA_REGISTRY, as this page reads it. */
interface AreaSubtabDef {
  key?: string;
  ids?: string[];
  lead?: string;
  [key: string]: any;
}
export interface AreaSubtabProps {
  area: string;
  subtab: string;
  findings: Finding[];
  filters: Filters;
  dims: Dims;
  maxCat?: number;
  meta: Meta;
  goTo: GoToFn;
  onVerdict?: (verdict: string | null) => void;
  allFindingsIndex?: Record<string, Finding> | null;
}
export function AreaSubtabContent({ area, subtab, findings, filters, dims, maxCat, meta, goTo, onVerdict, allFindingsIndex }: AreaSubtabProps) {
  const def: AreaSubtabDef = (((AREA_REGISTRY as Record<string, any>)[area] || {}).subtabs || []).find((s: AreaSubtabDef) => s.key === subtab) || { ids: [] };
  const owned = (def.ids || []).map((id) => findingForId(findings, id)).filter(Boolean) as Finding[];
  // Warehouses and Queries draw their whole top section (area_compute.tsx).
  const ownPage = COMPUTE_PAGES[area] ? COMPUTE_PAGES[area][subtab] || null : null;
  const tiles = pickTileChecks(owned, 4, def.lead);
  const pops = pagePopulations(owned);
  const tileIds = new Set(tiles.map((f) => f.query_id));
  // Flagged checks outside the fixed tile set are counted in one tile, never dropped.
  const moreFlagged = owned.filter((f) => !tileIds.has(f.query_id) && !CONTEXT_TILE_IDS.has(f.query_id) && (bandOf(f) === "CRITICAL" || bandOf(f) === "WARN"));

  // Charts: the first two owned checks that ran, returned rows and carry a money figure.
  // The purpose-built charts for this sub-tab (area_*.tsx) lead; with them the generic charts would repeat.
  const ChartPage: any = !ownPage && typeof AREA_CHART_PAGES !== "undefined" && AREA_CHART_PAGES[area] ? AREA_CHART_PAGES[area][subtab] : null;
  const ownsTiles = !!(ChartPage && ChartPage.ownsTiles);
  const chartChecks = ownPage || ChartPage ? [] : owned
    .filter((f) => f.outcome === "ok_rows" && (f.row_count ?? 0) > 0 && f.money && Number(f.money.usd) > 0 && !CONTEXT_TILE_IDS.has(f.query_id))
    // the lead check first, a context figure (the same idle cost seen again) last
    .sort((a, b) => ((b.query_id === def.lead) as unknown as number) - ((a.query_id === def.lead) as unknown as number) || ((moneyKindOf(a) === "context") as unknown as number) - ((moneyKindOf(b) === "context") as unknown as number))
    .slice(0, 2);
  const s1 = useFindingData(chartChecks[0] ? chartChecks[0].query_id : null, filters.window, filters.accountIds, 5000) as FetchState;
  const s2 = useFindingData(chartChecks[1] ? chartChecks[1].query_id : null, filters.window, filters.accountIds, 5000) as FetchState;
  const states = [s1, s2];
  const firstLabel = s1.phase === "ready" && s1.data ? pickLabelColumn(s1.data.columns) : null;

  // A page that builds its own lede from its numbers says so (ownsLede) and gets setLede.
  const ledeOwned = !!((ownPage && (ownPage as any).ownsLede) || (ChartPage && ChartPage.ownsLede));
  const verdict = subtabVerdict(owned);
  React.useEffect(() => { if (onVerdict && !ledeOwned) onVerdict(verdict); }, [verdict, ledeOwned]); // eslint-disable-line react-hooks/exhaustive-deps

  // A sub-tab that only reads other tabs' feeds (Before & after, Queries > Trend) still draws its own page.
  if (!owned.length && !ownPage && !ChartPage) return null;
  // A snapshot sub-tab says so once, in the page eyebrow.
  const shell = { area, subtab, findings, filters, dims, meta, goTo, allFindingsIndex, setLede: ledeOwned ? onVerdict || null : null };
  return (
    <div>
      {ownPage ? React.createElement(ownPage, shell) : (
        <React.Fragment>
          {ChartPage && <ChartPage {...shell} />}
          {!ownsTiles && owned.length > 0 && <SummaryTileRow compact>
            {tiles.map((f) => <SummaryTile key={f.query_id} {...tileForCheck(f, area, subtab, goTo, pops)} />)}
            {moreFlagged.length > 0 && (
              <SummaryTile label="Also flagged on this tab" value={fmtInt(moreFlagged.length)} unit={` of ${fmtInt(owned.length)} checks`}
                severity={moreFlagged.some((f) => bandOf(f) === "CRITICAL") ? "critical" : "warn"}
                reading={moreFlagged.map((f) => getCheckLabel(f.query_id, f.title).title).join(" · ")}
                href="Open check" onClick={() => goTo({ tab: area, subtab, focusQueryId: moreFlagged[0].query_id })} />
            )}
          </SummaryTileRow>}
          {chartChecks.length > 0 && (
            <div className="cj-charts-2">
              {chartChecks.map((f, i) => (
                <CheckChartCard
                  key={f.query_id} f={f} state={states[i]} dims={dims} maxCat={maxCat} meta={meta} filters={filters}
                  avoidLabel={i === 1 ? firstLabel : null}
                  onOpen={() => goTo({ tab: area, subtab, focusQueryId: f.query_id })}
                />
              ))}
            </div>
          )}
        </React.Fragment>
      )}
    </div>
  );
}

// Registers AreaSubtabContent for one area/sub-tab pair (a closure, since AreaContent passes only
// the shared tab props).
// `Extra` (optional) renders after the tiles and charts: the tag rollup on the sub-tabs that host it.
export function registerAreaContent(area: string, subtab: string, Extra?: React.ComponentType<any> | null) {
  AreaContent.register(area, subtab, (props: Omit<AreaSubtabProps, "area" | "subtab">) => (
    <div>
      <AreaSubtabContent area={area} subtab={subtab} {...props} />
      {Extra && <Extra {...props} />}
    </div>
  ));
}

export function CostTagRollup({ filters, meta }: { filters: Filters; meta: Meta }) {
  return <Card title="Spend by tag"><TagRollupView filters={filters} area="cost" meta={meta} /></Card>;
}
export function QueryTagRollup({ filters, meta }: { filters: Filters; meta: Meta }) {
  return <div className="cxd-tagroll"><Card title="Statements by tag"><TagRollupView filters={filters} area="performance" meta={meta} /></Card></div>;
}

// Every drill-down sub-tab without a bespoke page. Cost > Trend, Waste, Actions, Overview and
// Coverage register their own.
([
  ["cost", ["service", "who", "chargeback", "before", "contract", "budgets"]],
  ["warehouses", ["idle", "sizing", "load"]],
  ["serverless", ["feature", "clustering", "mvso"]],
  ["queries", ["heavy", "efficiency", "failures", "waiting", "team", "trend"]],
  ["tasks", ["failures", "cost", "hygiene", "dynamic"]],
  ["loading", ["pipes", "copy"]],
  ["ai", ["cortex", "apps", "serving"]],
  ["access", ["roles", "users", "perimeter"]],
  ["audit", ["admins", "changes"]],
  ["pii", ["sensitive", "policies", "reads", "quality"]],
  ["lineage", ["dependencies", "usage"]],
  ["sharing", ["shares", "accounts", "spend", "replication"]],
  ["storage", ["growth", "unused", "retention", "backups"]],
] as [string, string[]][]).forEach(([area, subtabs]) => subtabs.forEach((s) => {
  // Cost › Chargeback draws its own tag card (ap_cost.tsx).
  const extra = area === "queries" && s === "team" ? QueryTagRollup : null;
  registerAreaContent(area, s, extra);
}));
