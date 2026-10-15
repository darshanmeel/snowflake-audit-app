// web/src/tabs/tab_cost.tsx -- Cost > Trend: spend, change, spike days and the month-end forecast as
// tiles, then what moved, calendar months, spend by day and kind, and the tie to the bill. Registers with AreaContent (primitives.tsx), which
// renders PageIntro + SubTabs + this component + the checks table; this file only owns the cards in
// between. The other Cost sub-tabs open with tab_area.tsx's tiles and charts.
//
// Dollars are credits times the effective $ per credit; a figure that could not be priced reads "-"
// and why. The last day of the window can be today, which is partial (cost_cutoff).

// ── small local presentational helpers: a per-sub-tab metric grid and a one-line caveat ──────────
import React from "react";
import { acctId } from "../api";
import { fmtCredits, fmtDayShort, fmtInt, fmtMoney } from "../format";
import { acctPhrase, resolveName, useNames } from "../components/names";
import { SPIKE_PCT, buildMonthBars, fmtChangePct, aggTotal, numOrZero, sumBy, totalSpikeDays, useFindingAgg, useFindingData } from "../components/hooks";
import { COST_MONEY_COL } from "../components/tab_registry";
import { Card, Facts, KindChip, PatternCard, bandOf, noDataText } from "../components/primitives";
import { AreaContent } from "../area_content";
import { ChartNote, paletteColor } from "../components/charts";
import { DivergingBars, RankedBars } from "../components/charts_more";
import { DayKindTimeline, IssueTile, ReconciliationStrip, fmtShare, pctOf } from "../components/blocks";
import type { ReconStep } from "../components/blocks";
import { NameId } from "../components/blocks_2";
import { DrillTable } from "../components/drill_table";
import { DAY_ROWS_MAX, GrainLines, GrainSwitch, MONTH_ROWS_MAX, fmtMonth, latest, monthOf, monthRun, partialMonths, rollUpMonths } from "../components/grain";
import type { Grain } from "../components/grain";
import { CsvButton } from "../components/csv";
import type { CsvColumn } from "../components/csv";
import { useCostCenterAllocation } from "../components/tag_rollup";
import { NO_PRICE_LEDE, NO_PRICE_READING, isUnpricedAgg, notAssessedText } from "../components/scope";
import { scrollToAnchor, windowShortLabel, windowSpan } from "../components/overview_tile";
import { DAY_KINDS, dayKindOf, fillGaps, sumPick } from "./tab_overview";
import { withoutTotalRows } from "./tab_area";
import type { FactItems } from "../components/primitives";
import type { FetchState, Filters, Finding, GoToFn, Meta, Row } from "../types";
import "../styles/css/p_shared_tabs.css";
import "../styles/css/p_cost_mlai.css";

type MonthBar = ReturnType<typeof buildMonthBars>[number];
type Grid = number[][];
interface ForecastFigures { projected: number | null; lastMonth: number | null; monthToDate: number | null }

export function MetricCard({ label, value, note, tone, facts }: { label: React.ReactNode; value: React.ReactNode; note?: React.ReactNode; tone?: string | null; facts?: FactItems }) {
  return (
    <div className={`metric-card${tone ? ` tone-${tone}` : ""}`}>
      <div className="metric-label">{label}</div>
      <div className="metric-value mono">{value}</div>
      {facts ? <Facts items={facts} /> : (note && <div className="metric-note">{note}</div>)}
    </div>
  );
}
export function MetricGrid({ children }: { children?: React.ReactNode }) {
  return <div className="metric-grid">{children}</div>;
}
export function CaveatNote({ children }: { children?: React.ReactNode }) {
  return <div className="caveat-note">{children}</div>;
}

export function costGridMax(grid: Grid | null | undefined) {
  let m = 0;
  (grid || []).forEach((row) => (row || []).forEach((v) => { if (v > m) m = v; }));
  return m > 0 ? m : 1;
}

// The month-end forecast figures from sf_cost_month_end_forecast: one row per service plus a total
// row (`is_total_row`) per account. Only the total rows are added across accounts (the service rows are
// its parts, so adding them too would double it); with no total row the service rows are added.
export function forecastFigures(rows: Row[], discountPct: any): ForecastFigures;
export function forecastFigures(rows: Row[] | null | undefined, discountPct: any): ForecastFigures | null;
export function forecastFigures(rows: Row[] | null | undefined, discountPct: any): ForecastFigures | null {
  if (!rows) return null;
  const totals = rows.filter((r) => r.is_total_row);
  const use = totals.length ? totals : rows;
  const keep = 1 - numOrZero(discountPct);
  const scaled = (v: number | null | undefined) => (v == null ? null : v * keep);
  return {
    projected: scaled(sumPick(use, ["est_projected_usd_list"])),
    lastMonth: scaled(sumPick(use, ["est_last_month_usd_list"])),
    monthToDate: scaled(sumPick(use, ["est_month_to_date_usd_list"])),
  };
}

// month tone -> its bar colour: "steady" (3 full priors, within +-15%) reads --c1; a month with
// fewer than 3 full priors carries no tone and must never reuse that blue, or it silently reads as a
// verdict ("steady") this app never reached.
export const MONTH_TONE_VAR: Record<string, string> = { crit: "var(--st-crit)", warn: "var(--st-warn)", calm: "var(--st-ok)", steady: "var(--c1)" };
export function monthToneColor(tone: string | null | undefined) { return MONTH_TONE_VAR[tone as string] || "var(--c-other)"; }

export const MONTH_LEGEND: [string | null, string][] = [
  ["crit", "Up 30% or more"],
  ["warn", "Up 15% or more"],
  ["steady", "Steady"],
  ["calm", "Down 15% or more"],
  [null, "Under 3 months of history"],
];
export function MonthBarLegend() {
  return (
    <div className="month-legend">
      <div className="month-legend-title">vs 3-month average</div>
      {MONTH_LEGEND.map(([tone, text]) => (
        <div key={text} className="month-legend-row">
          <span className="month-legend-swatch" style={{ background: monthToneColor(tone) }} />{text}
        </div>
      ))}
      <div className="month-legend-row">
        <span className="month-legend-swatch month-bar-fill partial" />Month in progress (partial)
      </div>
    </div>
  );
}

// MonthChart -- the bars with their key on the right (below on a narrow screen). Money's month
// chart reads the same buildMonthBars output, so a month is never a different colour on two pages.
export function MonthChart({ months }: { months: MonthBar[] }) {
  return (
    <div className="month-chart">
      <CostMonthBars months={months} />
      <MonthBarLegend />
    </div>
  );
}

export function CostMonthBars({ months }: { months: MonthBar[] }) {
  const max = Math.max(1, ...months.map((m) => m.total));
  return (
    <div className="month-bars">
      {months.map((m) => (
        <div className="month-bar-col" key={m.month}>
          <div className="month-bar-track">
            <div
              className={`month-bar-fill${m.partial ? " partial" : ""}`}
              style={{ height: `${Math.max(2, (m.total / max) * 100)}%`, background: m.partial ? undefined : monthToneColor(m.tone) }}
              title={`${m.label}: ${fmtMoney(m.total, 0)}${m.partial ? " (in progress)" : m.changePct != null ? ` (${fmtChangePct(m.changePct)} vs trailing 3-mo avg)` : " (fewer than 3 full months on record)"}`}
            />
          </div>
          <div className="month-bar-label">{m.shortLabel}</div>
        </div>
      ))}
    </div>
  );
}

export const WEEKDAY_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
// Row index (Mon = 0) of a heat-map row: by its weekday name when it has one, else its number
// (ISO 1-7 as Snowflake's DAYOFWEEKISO gives it, or 0-6 when a 0 is present).
export function weekdayIndex(r: Row, zeroBased: boolean) {
  const name = String(r.weekday || "").slice(0, 3).toLowerCase();
  const byName = WEEKDAY_SHORT.findIndex((d) => d.toLowerCase() === name);
  if (byName >= 0) return byName;
  const n = Number(r.weekday_num);
  if (!Number.isFinite(n)) return -1;
  const i = zeroBased ? n : n - 1;
  return i >= 0 && i <= 6 ? i : -1;
}
// The time zone the export's hours are in: the rows' own column when the check returns one.
export function hourTimeZone(rows: Row[] | null | undefined) {
  const r = (rows || []).find((x) => x.hour_timezone || x.time_zone || x.timezone || x.tz);
  return r ? String(r.hour_timezone || r.time_zone || r.timezone || r.tz) : null;
}
export function hourCellColor(pct: number) {
  if (!(pct > 0)) return "var(--seq-0)";
  // Single-hue blue: spend per hour is neither good nor bad.
  return `var(--seq-${Math.min(5, Math.max(1, Math.ceil(pct * 5)))})`;
}
// A plain weekday x hour grid (time zone named, native title tooltips), with the tasks and queries running in
// the same slot in the tooltip.
export function CostHourHeatmap({ usdGrid, jobsGrid, queriesGrid, tzLabel }: { usdGrid: Grid; jobsGrid: Grid; queriesGrid: Grid; tzLabel: string; maxUsd?: number }) {
  const max = costGridMax(usdGrid);
  return (
    <div className="hour-heatmap">
      <div className="hh-row hh-header">
        <div className="hh-row-label" />
        {Array.from({ length: 24 }, (_, h) => <div key={h} className="hh-hour-label">{h % 3 === 0 ? h : ""}</div>)}
      </div>
      {WEEKDAY_SHORT.map((wd, wi) => (
        <div className="hh-row" key={wd}>
          <div className="hh-row-label">{wd}</div>
          {Array.from({ length: 24 }, (_, h) => {
            const v = usdGrid[wi][h] || 0;
            const tasks = (jobsGrid[wi] && jobsGrid[wi][h]) || 0;
            const queries = (queriesGrid[wi] && queriesGrid[wi][h]) || 0;
            const tip = `${wd} ${String(h).padStart(2, "0")}:00 ${tzLabel} -- ${fmtMoney(v, 0)}` + (tasks || queries ? ` -- ${fmtInt(tasks)} task run${tasks === 1 ? "" : "s"}, ${fmtInt(queries)} quer${queries === 1 ? "y" : "ies"}` : "");
            return <div key={h} className="hh-cell" style={{ background: hourCellColor(v / max) }} title={tip} />;
          })}
        </div>
      ))}
    </div>
  );
}

// The service type (what Snowflake bills: WAREHOUSE_METERING, AUTO_CLUSTERING, ...) in plain words.
export function serviceWords(code: any) {
  if (code === null || code === undefined || code === "") return "unknown service";
  const WORDS: Record<string, string> = { ai: "AI", cli: "CLI", sql: "SQL", mv: "MV" };
  return String(code).replace(/_/g, " ").toLowerCase().split(" ")
    .map((w, i) => WORDS[w] || (i === 0 ? w.charAt(0).toUpperCase() + w.slice(1) : w)).join(" ");
}
export function serviceOf(r: Row) { return r.service_type || r.billing_origin_product || r.sku_name; }

// ═══════════════════════ Trend ═══════════════════════
// Change against the previous period at one level at a time: service, account or account x service
// (from cost_period_over_period), or warehouse (from its chargeback check, fetched only when picked).
export const CHANGE_LEVELS: { key: string; label: string; qid?: string }[] = [
  { key: "service", label: "Service" },
  { key: "account", label: "Account" },
  { key: "acct_service", label: "Account & service" },
  { key: "warehouse", label: "Warehouse", qid: "cost_chargeback_by_warehouse" },
];

export function periodRowsBy(rows: Row[], keyFn: (r: Row) => any, valueOf: (r: Row) => number) {
  const m = new Map<any, number>();
  rows.forEach((r) => {
    const k = keyFn(r);
    m.set(k, (m.get(k) || 0) + valueOf(r));
  });
  return [...m.entries()].map(([name, value]) => ({ name, value }));
}

// Spend (this window's total) or change vs the previous window, at the same levels. Two views of the
// same rows: never added together.
export const CHANGE_METRICS = [{ key: "spend", label: "Spend" }, { key: "change", label: "Change" }];

export function ChangeBreakdownCard({ periodState, filters, maxCat, meta }: { periodState: FetchState; filters: Filters; maxCat?: number; meta?: Meta | null }) {
  useNames();
  const [level, setLevel] = React.useState("service");
  const [metric, setMetric] = React.useState("spend");
  const isSpend = metric === "spend";
  const lv = CHANGE_LEVELS.find((l) => l.key === level)!;
  const resState = useFindingData(lv.qid || null, filters.window, filters.accountIds);
  // Spend counts every priced row (an unpriced one is left out, never $0); a change is only read where
  // both windows could be priced.
  const judged = (r: Row) => (isSpend ? (r.usd_list != null ? r.usd_list : r.est_current_usd_list) != null : r.status !== "NOT_ASSESSED");
  const periodReady = periodState.phase === "ready" && periodState.outcome === "ok_rows";
  const periodRows = periodReady ? withoutTotalRows(periodState.data.rows).filter(judged) : null;
  let items: { name: any; value: number }[] | null = null, state = periodState;
  if (!lv.qid && periodRows) {
    const net = 1 - numOrZero(periodState.data.discount_pct);
    const valueOf = (r: Row) => numOrZero(isSpend ? r.est_current_usd_list : r.est_change_usd_list) * net;
    items = level === "service" ? periodRowsBy(periodRows, (r) => serviceWords(serviceOf(r)), valueOf)
      : level === "account" ? periodRowsBy(periodRows, (r) => acctPhrase(acctId(r)), valueOf)
      : periodRowsBy(periodRows, (r) => `${serviceWords(serviceOf(r))} · ${acctPhrase(acctId(r))}`, valueOf);
  } else if (lv.qid) {
    state = resState;
    const rows = resState.phase === "ready" && resState.outcome === "ok_rows"
      ? resState.data.rows.filter((r: Row) => judged(r) && (isSpend || !r.is_other)) : null;
    const net = rows ? 1 - numOrZero(resState.data.discount_pct) : 1;
    // The warehouse check names its columns usd_list / change_usd_list; a pooled remainder row is still
    // spend, so it is its own bar and never dropped.
    const valueOf = isSpend
      ? (r: Row) => numOrZero(r.usd_list != null ? r.usd_list : r.est_current_usd_list) * net
      : (r: Row) => numOrZero(r.change_usd_list != null ? r.change_usd_list : r.est_change_usd_list) * net;
    items = rows ? rows.map((r: Row) => ({
      name: r.is_other ? "Other warehouses" : `${resolveName("warehouse", null, r.warehouse_id) || r.warehouse_id} (${r.warehouse_id})`,
      value: valueOf(r),
    })) : null;
  }
  // Rows that exist but could not be read say why, never "no data": no price, or no previous period.
  const rawRows: Row[] = state.phase === "ready" && state.outcome === "ok_rows" ? withoutTotalRows(state.data.rows || []) : [];
  const gap = items && !items.length && rawRows.length
    ? (rawRows.every((r) => r.price_basis === "unpriced") ? `– ${NO_PRICE_READING}` : !isSpend ? "– No previous period to compare in this export." : null)
    : null;
  return (
    <Card
      title={isSpend ? `Spend by ${lv.label.toLowerCase()}` : "Biggest changes vs previous period"}
      right={(
        <div className="ws-actions">
          {CHANGE_METRICS.map((m) => (
            <button key={m.key} type="button" className={m.key === metric ? "on" : ""} onClick={() => setMetric(m.key)}>{m.label}</button>
          ))}
        </div>
      )}
    >
      <div className="ws-actions">
        {CHANGE_LEVELS.map((l) => (
          <button key={l.key} type="button" className={l.key === level ? "on" : ""} onClick={() => setLevel(l.key)}>{l.label}</button>
        ))}
      </div>
      {gap ? <div className="chart-note-oneline">{gap}</div> : items && isSpend ? (
        <RankedBars
          items={items}
          n={maxCat}
          valueFmt={(v) => fmtMoney(v, 0)}
          unitLabel="$"
          emptyText={noDataText(meta, filters.window)}
          note={`Total for the last ${filters.window} days.`}
        />
      ) : items ? (
        <DivergingBars
          items={items}
          n={maxCat}
          valueFmt={(v) => `${v >= 0 ? "+" : "-"}${fmtMoney(Math.abs(v), 0)}`}
          unitLabel="Change"
          note="This period against the one just before it, same length. 25% up is over the warning line, 50% is critical."
        />
      ) : <ChartNote state={state} label={lv.qid || "cost_period_over_period"} />}
    </Card>
  );
}

// ── shared bits for the Trend cards: one measure per card ($ when priced, else credits) ──
const CREDIT_UNIT = "CREDITS";
const sumOf = (vals: number[]) => vals.reduce((a, b) => a + b, 0);
// Small credit amounts keep two decimals, so a real 0.004 never reads as 0.0.
function fmtCr(v: number | null | undefined) {
  if (v == null || !Number.isFinite(v)) return "–";
  if (v > 0 && v < 0.01) return "<0.01 credits";
  return fmtCredits(v, v < 10 ? 2 : v < 1000 ? 1 : 0);
}
function fmtUsd(v: number | null | undefined) {
  return v == null || !Number.isFinite(v) ? "–" : fmtMoney(v, Math.abs(v) < 100 ? 2 : 0);
}
function aggReady(s: FetchState) { return s.phase === "ready" && s.outcome === "ok_rows" && !!s.data; }

// Every day of the window (and today, partial), so a day with no usage is a real 0 and averages divide
// by the window's days; data days outside it are kept too, never dropped.
function windowDayList(meta: Meta | null | undefined, windowDays: number, dataDays: Iterable<string>): string[] {
  const m = new Map<string, number>();
  for (const d of dataDays) m.set(d, 0);
  const s = windowSpan(meta && meta.as_of_date, windowDays, meta && meta.snapshot_days);
  if (s) {
    m.set(new Date(s.first).toISOString().slice(0, 10), 0);
    m.set(new Date(s.last).toISOString().slice(0, 10), 0);
    if (s.partialDay != null) m.set(new Date(s.partialDay).toISOString().slice(0, 10), 0);
  }
  return fillGaps(m).map((d) => d.day);
}
const daySpan = (days: string[]) => (!days.length ? "" : days.length === 1 ? fmtDayShort(days[0]) : `${fmtDayShort(days[0])} – ${fmtDayShort(days[days.length - 1])}`);
const ONE_MONTH_NOTE = (key: string) => `Only ${fmtMonth(key)} in this window: pick a longer window for a monthly trend.`;

// MultiLine rounds its axis to 1 decimal, so a line under 1 credit gets its scale written here instead.
function SmallScale({ max, fmt, per, children }: { max: number; fmt: (v: number) => string; per: string; children: React.ReactNode }) {
  if (!(max > 0 && max < 1)) return <React.Fragment>{children}</React.Fragment>;
  return (
    <div className="ct-small-scale">
      <div className="ct-scale-note muted">{`Scale: 0 – ${fmt(max)} per ${per}`}</div>
      {children}
    </div>
  );
}

// Month totals as plain bars (Cost's month-bar look, no change colours): a partial month is hatched.
interface PlainMonth { key: string; total: number; partial: boolean; why?: string }
export function PlainMonthBars({ months, fmt }: { months: PlainMonth[]; fmt: (v: number) => string }) {
  const max = Math.max(0, ...months.map((m) => m.total)) || 1;
  return (
    <div className="month-bars ct-month-bars">
      {months.map((m) => (
        <div className="month-bar-col" key={m.key}>
          <div className="month-bar-track">
            <div className={`month-bar-fill${m.partial ? " partial" : ""}`}
              style={{ height: `${Math.max(2, (m.total / max) * 100)}%`, background: m.partial ? undefined : "var(--c1)" }}
              title={`${fmtMonth(m.key)}: ${fmt(m.total)}${m.partial ? ` (partial${m.why ? `: ${m.why}` : ""})` : ""}`} />
          </div>
          <div className="month-bar-label">{fmtMonth(m.key)}</div>
          <div className="month-bar-label ct-month-value">{`${fmt(m.total)}${m.partial ? " · partial" : ""}`}</div>
        </div>
      ))}
    </div>
  );
}

// Months a day list covers, each marked partial when it is still running or starts mid-window.
function monthsOfDays(days: string[], perDay: number[]): PlainMonth[] {
  const r = rollUpMonths(days, [perDay]);
  const { open, cut } = partialMonths(days, true);
  return latest(r.months.map((k, i) => ({
    key: k, total: r.series[0][i],
    partial: k === open || k === cut,
    why: k === open ? "month in progress" : k === cut ? "the window starts mid-month" : undefined,
  })), MONTH_ROWS_MAX);
}

// Spend by weekday and hour from cost_by_hour_of_day: $ per slot, with the slot's task runs and
// queries (repeated on each service row, so counted once per account and slot).
export function CostHourCard({ filters, meta }: { filters: Filters; meta?: Meta | null }) {
  const state = useFindingData("cost_by_hour_of_day", filters.window, filters.accountIds);
  const rows = aggReady(state) ? withoutTotalRows(state.data.rows || []) : null;
  let body: React.ReactNode;
  const drawn = !!rows && !!rows.length && rows.some((r: Row) => r.usd_list != null);
  if (!rows) body = <ChartNote state={state} label="cost_by_hour_of_day" />;
  else if (!rows.length) body = <div className="chart-note-oneline">{noDataText(meta, filters.window)}</div>;
  else if (!rows.some((r: Row) => r.usd_list != null)) body = <div className="chart-note-oneline">– {NO_PRICE_READING}</div>;
  else {
    const zeroBased = rows.some((r: Row) => Number(r.weekday_num) === 0);
    const grid = () => WEEKDAY_SHORT.map(() => Array.from({ length: 24 }, () => 0));
    const usd = grid(), jobs = grid(), queries = grid();
    const seen = new Set<string>();
    const disc = 1 - numOrZero(state.data.discount_pct);
    rows.forEach((r: Row) => {
      const wi = weekdayIndex(r, zeroBased), h = Number(r.hour_of_day);
      if (wi < 0 || !(h >= 0 && h < 24)) return;
      usd[wi][h] += numOrZero(r.usd_list) * disc;
      const slot = `${acctId(r)}|${wi}|${h}`;
      if (seen.has(slot)) return;
      seen.add(slot);
      jobs[wi][h] += numOrZero(r.job_runs_active);
      queries[wi][h] += numOrZero(r.queries_started);
    });
    body = <CostHourHeatmap usdGrid={usd} jobsGrid={jobs} queriesGrid={queries} tzLabel={hourTimeZone(rows) || "UTC"} />;
  }
  return (
    <PatternCard title="Spend by weekday and hour" sub={drawn ? `Darker = more spend in that hour · ${(rows && hourTimeZone(rows)) || "UTC"} · hover a cell for its task runs and queries` : "When in the week the money is spent"}>
      {body}
    </PatternCard>
  );
}

// ═══ Trend by service, warehouse, task or pipe ═══
const TREND_KINDS = [
  { key: "service", label: "Service", noun: "service", plural: "services" },
  { key: "warehouse", label: "Warehouse", noun: "warehouse", plural: "warehouses" },
  { key: "task", label: "Serverless task", noun: "serverless task", plural: "serverless tasks" },
  { key: "pipe", label: "Pipe", noun: "pipe", plural: "pipes" },
];
const RES_GROUP = ["resource_type", "resource_key", "usage_date", "account_id"];
const RES_OPTS = { also: ["usd_list"], pick: ["warehouse_name", "warehouse_id", "task_full_name", "task_id", "pipe_name", "pipe_id"] };
const TOP_LINES = 5;

interface TrendItem { key: string; name: string; id: string | null; usd: number | null; credits: number | null; usdByDay: Map<string, number>; crByDay: Map<string, number>; noCredits?: boolean }

function addTo(m: Map<string, number>, k: string, v: number) { m.set(k, (m.get(k) || 0) + v); }

// One item per service from cost_dollarized_by_service_day's (day, service, unit) groups. Credits only
// count CREDITS-unit rows; storage and transfer are billed in other units.
function serviceItems(agg: FetchState): TrendItem[] | null {
  if (!aggReady(agg)) return null;
  const disc = 1 - numOrZero(agg.data.discount_pct);
  const by = new Map<string, TrendItem>();
  (agg.data.groups || []).forEach((g: Row) => {
    const day = String(g.key[0]).slice(0, 10), svc = String(g.key[1] == null ? "" : g.key[1]);
    const it = by.get(svc) || { key: svc, name: serviceWords(g.key[1]), id: null, usd: null, credits: null, usdByDay: new Map(), crByDay: new Map(), noCredits: true };
    if (g.value != null) { it.usd = (it.usd || 0) + Number(g.value) * disc; addTo(it.usdByDay, day, Number(g.value) * disc); }
    if (String(g.key[2] || "").toUpperCase() === CREDIT_UNIT) {
      const q = numOrZero(g.also && g.also.net_usage_quantity);
      it.credits = (it.credits || 0) + q; it.noCredits = false; addTo(it.crByDay, day, q);
    }
    by.set(svc, it);
  });
  return [...by.values()];
}

// One item per warehouse, serverless task or pipe (per account) from cost_daily_by_resource.
function resourceItems(agg: FetchState, kind: string, multiAcct: boolean, plural: string): TrendItem[] | null {
  if (!aggReady(agg)) return null;
  const disc = 1 - numOrZero(agg.data.discount_pct);
  const by = new Map<string, TrendItem>();
  (agg.data.groups || []).forEach((g: Row) => {
    if (g.key[0] !== kind) return;
    const rkey = String(g.key[1]), day = String(g.key[2]).slice(0, 10), acct = g.key[3];
    const k = `${acct}|${rkey}`;
    let it = by.get(k);
    if (!it) {
      const pk = g.pick || {};
      const rid = rkey.slice(rkey.indexOf(":") + 1);
      const isOther = rid === "other", isNone = rid === "none";
      const named = kind === "warehouse" ? (pk.warehouse_name || resolveName("warehouse", acct, rid)) : kind === "task" ? pk.task_full_name : pk.pipe_name;
      const name = isOther ? `Other ${plural} (pooled)` : isNone ? "(auto-refresh or Streaming)" : String(named || rid);
      it = { key: k, name: multiAcct ? `${name} · ${acctPhrase(acct)}` : name, id: isOther || isNone ? null : rid, usd: null, credits: 0, usdByDay: new Map(), crByDay: new Map() };
      by.set(k, it);
    }
    const cr = numOrZero(g.value);
    it.credits = (it.credits || 0) + cr; addTo(it.crByDay, day, cr);
    const u = g.also ? g.also.usd_list : null;
    if (u != null) { it.usd = (it.usd || 0) + Number(u) * disc; addTo(it.usdByDay, day, Number(u) * disc); }
  });
  return [...by.values()];
}

const itemLabel = (it: TrendItem) => (it.id ? `${it.name} (${it.id})` : it.name);

export function TrendByCard({ filters, meta, serviceAgg }: { filters: Filters; meta?: Meta | null; serviceAgg: FetchState }) {
  useNames();
  const [kind, setKind] = React.useState("service");
  const [grain, setGrain] = React.useState<Grain>("day");
  const [picked, setPicked] = React.useState<string | null>(null);
  const [showAll, setShowAll] = React.useState(false);
  const kd = TREND_KINDS.find((k) => k.key === kind) || TREND_KINDS[0];
  const isSvc = kind === "service";
  const resAgg = useFindingAgg(isSvc ? null : "cost_daily_by_resource", filters.window, filters.accountIds, RES_GROUP, "sum", "credits", RES_OPTS);
  const src = isSvc ? serviceAgg : resAgg;
  const multiAcct = aggReady(resAgg) && new Set((resAgg.data.groups || []).map((g: Row) => g.key[3])).size > 1;
  const items = isSvc ? serviceItems(serviceAgg) : resourceItems(resAgg, kind, multiAcct, kd.plural);
  // One measure per card: $ when any of it is priced, else credits (never the two added).
  const priced = !!items && items.some((it) => it.usd != null);
  const valOf = (it: TrendItem) => (priced ? it.usd : it.credits);
  const byDayOf = (it: TrendItem) => (priced ? it.usdByDay : it.crByDay);
  const fmtV = priced ? fmtUsd : fmtCr;

  const dataDays: string[] = [];
  (items || []).forEach((it) => { dataDays.push(...it.usdByDay.keys(), ...it.crByDay.keys()); });
  const days = items ? windowDayList(meta, filters.window, dataDays) : [];
  const partialDay = (meta && meta.cost_cutoff && meta.cost_cutoff.partial_day) || null;
  const wholeDays = days.filter((d) => d !== partialDay);
  const months = monthsOfDays(days, days.map(() => 0));
  const fullMonths = months.filter((m) => !m.partial).map((m) => m.key);

  const rows = (items || [])
    .map((it) => {
      const per = byDayOf(it);
      const vals = days.map((d) => per.get(d) || 0);
      const total = valOf(it);
      let change: number | null = null;
      if (grain === "day" && wholeDays.length >= 14) {
        const w = wholeDays.map((d) => per.get(d) || 0);
        const last = sumOf(w.slice(-7)), prev = sumOf(w.slice(-14, -7));
        change = prev > 0 ? ((last - prev) / prev) * 100 : null;
      } else if (grain === "month" && fullMonths.length >= 2) {
        const mv = (k: string) => sumOf(days.filter((d) => monthOf(d) === k).map((d) => per.get(d) || 0));
        const last = mv(fullMonths[fullMonths.length - 1]), prev = mv(fullMonths[fullMonths.length - 2]);
        change = prev > 0 ? ((last - prev) / prev) * 100 : null;
      }
      const perDay = total != null && wholeDays.length ? sumOf(wholeDays.map((d) => per.get(d) || 0)) / wholeDays.length : null;
      return { it, vals, total, perDay, change };
    })
    .sort((a, b) => (b.total ?? -1) - (a.total ?? -1) || a.it.name.localeCompare(b.it.name));
  const grand = sumOf(rows.map((r) => r.total || 0));
  const sel = picked ? rows.find((r) => r.it.key === picked) || null : null;
  const lineRows = sel ? [sel] : rows.filter((r) => (r.total || 0) > 0).slice(0, TOP_LINES);
  const span = daySpan(days);
  const openMonth = months.find((m) => m.why === "month in progress");
  const hasPartialDay = !!partialDay && days.includes(partialDay);
  const partialNote = grain === "day" ? `${hasPartialDay ? " · the last day is partial" : ""}${days.length > DAY_ROWS_MAX ? ` · chart: last ${DAY_ROWS_MAX} days` : ""}`
    : `${openMonth ? ` · ${fmtMonth(openMonth.key)} is partial` : ""} · months inside this window only`;
  // The axis top of what is drawn, at the chart's grain.
  const drawnMax = Math.max(0, ...lineRows.flatMap((r) => (grain === "day" ? r.vals.slice(-DAY_ROWS_MAX) : rollUpMonths(days, [r.vals]).series[0])));
  const scaleFmt = (v: number) => (priced ? fmtUsd(v) : `${Number(v.toPrecision(2))} credits`);

  const csvCols: CsvColumn<typeof rows[number]>[] = [
    { label: kd.label, value: (r) => itemLabel(r.it) },
    { label: "Credits", value: (r) => (r.it.credits == null ? "" : Math.round(r.it.credits * 10000) / 10000) },
    { label: "USD", value: (r) => (r.it.usd == null ? "" : Math.round(r.it.usd * 100) / 100) },
    ...days.map((d, i) => ({ label: `${d} (${priced ? "USD" : "credits"})`, value: (r: typeof rows[number]) => Math.round(r.vals[i] * 10000) / 10000 })),
  ];

  let body: React.ReactNode;
  if (!items) body = <ChartNote state={src} label={isSvc ? "cost_dollarized_by_service_day" : "cost_daily_by_resource"} />;
  else if (!rows.length || !days.length) body = <div className="chart-note-oneline">{`${noDataText(meta, filters.window)} (no ${kd.plural} with usage).`}</div>;
  else body = (
    <React.Fragment>
      {sel && (
        <div className="ct-picked">
          <span>Showing <NameId name={sel.it.name} id={sel.it.id} /></span>
          <button type="button" className="link-out" onClick={() => setPicked(null)}>{`Back to the top ${TOP_LINES}`}</button>
        </div>
      )}
      {lineRows.length
        ? <SmallScale max={drawnMax} fmt={scaleFmt} per={grain}>
            <GrainLines grain={grain} days={days} series={lineRows.map((r, i) => ({ label: itemLabel(r.it), color: sel ? "var(--c1)" : paletteColor(i), data: r.vals }))} />
          </SmallScale>
        : <div className="chart-note-oneline">{`No ${kd.noun} used any ${priced ? "$" : "credits"} in ${span}.`}</div>}
      <div className="ct-table-head">
        <span className="muted">{`${fmtInt(rows.length)} ${rows.length === 1 ? kd.noun : kd.plural}, most first · click one for its own line`}</span>
        <CsvButton fileName={`trend_by_${kind}_${filters.window}d`} columns={csvCols} rows={rows} />
      </div>
      <DrillTable aria={`${kd.plural} by ${priced ? "spend" : "credits"}`} n={showAll ? rows.length : 10}
        cols={[{ label: kd.label }, { label: "Credits", num: true }, { label: "$", num: true }, { label: "Share", num: true },
          { label: "Per whole day", num: true }, { label: grain === "day" ? "Last 7 days vs 7 before" : "Last full month vs before", num: true }]}
        rows={rows.map((r) => ({
          key: r.it.key, selected: !!sel && sel.it.key === r.it.key, onOpen: () => setPicked(r.it.key),
          cells: [<NameId key="n" name={r.it.name} id={r.it.id} />,
            r.it.noCredits ? "–" : fmtCr(r.it.credits), fmtUsd(r.it.usd),
            grand > 0 && r.total != null ? fmtShare(pctOf(r.total, grand)) : "–",
            r.perDay != null ? fmtV(r.perDay) : "–",
            r.change != null ? fmtChangePct(r.change) : "–"],
        }))}
        more={rows.length > 10 ? <button type="button" className="link-out" onClick={() => setShowAll(!showAll)}>{showAll ? " Show the top 10" : ` Show all ${fmtInt(rows.length)}`}</button> : null} />
      {!priced && <div className="sx-foot">{`$ –: ${NO_PRICE_READING}${isSvc ? " Storage and transfer are not billed in credits." : ""}`}</div>}
      {hasPartialDay && (isSvc || kind === "warehouse") && <div className="sx-foot">Today is partial, and the service and warehouse views fill it at different speeds, so their totals for warehouses can differ.</div>}
    </React.Fragment>
  );

  return (
    <Card title="Trend by service, warehouse, task or pipe" right={<GrainSwitch value={grain} onChange={setGrain} />}>
      <div className="ws-actions">
        {TREND_KINDS.map((k) => (
          <button key={k.key} type="button" className={k.key === kind ? "on" : ""} onClick={() => { setKind(k.key); setPicked(null); setShowAll(false); }}>{k.label}</button>
        ))}
      </div>
      <div className="pc-sub">{`${priced ? "$" : "Credits"} per ${grain} · ${sel ? "one item" : `top ${TOP_LINES}`}${span ? ` · ${span}` : ""}${partialNote}`}</div>
      {body}
    </Card>
  );
}

// ═══ Fastest-growing services, last 12 months (cost_monthly_actuals) ═══
const GROWTH_GROUP = ["billing_origin_product", "month_start", "partial_reason"];

function SvcSparkbars({ values, partial }: { values: number[]; partial: boolean[] }) {
  const max = Math.max(0, ...values) || 1;
  return (
    <div className="sku-spark" aria-hidden="true">
      {values.map((v, i) => <div key={i} className={`sku-spark-bar${partial[i] ? " partial" : ""}`} style={{ height: `${Math.max(4, (v / max) * 100)}%` }} />)}
    </div>
  );
}

export function FastestGrowingCard({ filters, maxCat }: { filters: Filters; maxCat?: number }) {
  const agg = useFindingAgg("cost_monthly_actuals", filters.window, filters.accountIds, GROWTH_GROUP, "sum", "net_list_cost_usd");
  const ready = aggReady(agg);
  const groups: Row[] = ready ? agg.data.groups || [] : [];
  const partialKeys = new Set(groups.filter((g) => g.key[2]).map((g) => String(g.key[1]).slice(0, 10)));
  const monthKeys = latest(monthRun(groups.map((g) => String(g.key[1]).slice(0, 10))), 13);
  const full = monthKeys.filter((k) => !partialKeys.has(k));
  const covers = monthKeys.length
    ? `This export covers ${fmtInt(monthKeys.length)} month${monthKeys.length === 1 ? "" : "s"} (${fmtMonth(monthKeys[0])}${monthKeys.length > 1 ? ` – ${fmtMonth(monthKeys[monthKeys.length - 1])}` : ""}), ${fmtInt(full.length)} full.`
    : "";
  // Average of the last n full months against the n before; n is 3 when the export holds 6 full months.
  const n = Math.min(3, Math.floor(full.length / 2));
  const disc = ready ? 1 - numOrZero(agg.data.discount_pct) : 1;
  const by = new Map<string, Map<string, number>>();
  groups.forEach((g) => {
    if (g.value == null) return;
    const svc = String(g.key[0] == null ? "" : g.key[0]);
    if (!by.has(svc)) by.set(svc, new Map());
    addTo(by.get(svc)!, String(g.key[1]).slice(0, 10), Number(g.value) * disc);
  });
  const svcRows = [...by.entries()].map(([svc, m]) => {
    const vals = monthKeys.map((k) => m.get(k) || 0);
    const fullVals = full.map((k) => m.get(k) || 0);
    const last = n ? sumOf(fullVals.slice(-n)) / n : null;
    const prev = n ? sumOf(fullVals.slice(-2 * n, -n)) / n : null;
    const growth = last != null && prev != null && prev > 0 ? ((last - prev) / prev) * 100 : null;
    const isNew = last != null && prev === 0 && last > 0;
    return { svc, vals, last, growth, isNew };
  }).sort((a, b) => Number(b.isNew) - Number(a.isNew) || (b.growth ?? -Infinity) - (a.growth ?? -Infinity) || (b.last || 0) - (a.last || 0));
  const shown = svcRows.slice(0, maxCat || 8);

  let body: React.ReactNode;
  const drawn = ready && !!groups.length && !isUnpricedAgg(agg.data);
  if (!ready) body = <ChartNote state={agg} label="cost_monthly_actuals" />;
  else if (!groups.length) body = <div className="chart-note-oneline">No billed months in this export.</div>;
  else if (isUnpricedAgg(agg.data)) body = <div className="chart-note-oneline">{`– ${NO_PRICE_READING} ${covers}`}</div>;
  else body = (
    <React.Fragment>
      <div className="sku-trend-list">
        {shown.map((s) => (
          <div className="sku-trend-row" key={s.svc}>
            <div className="sku-trend-name" title={serviceWords(s.svc || null)}>{serviceWords(s.svc || null)}{s.isNew && <span className="faint"> · new</span>}</div>
            <SvcSparkbars values={s.vals} partial={monthKeys.map((k) => partialKeys.has(k))} />
            <div className={`sku-trend-growth${s.growth != null && s.growth >= 100 ? " tone-crit" : s.growth != null && s.growth >= 50 ? " tone-warn" : ""}`}>
              {s.isNew ? "new" : s.growth != null ? fmtChangePct(s.growth) : "–"}
            </div>
            <div className="sku-trend-usd mono">{s.last != null ? `${fmtMoney(s.last, 0)}/mo` : "–"}</div>
          </div>
        ))}
      </div>
      {n < 1 && <div className="sx-foot">{`Growth needs 2 full months. ${covers}`}</div>}
    </React.Fragment>
  );
  return (
    <PatternCard title="Fastest-growing services, last 12 months"
      sub={drawn ? `${n >= 1 ? `Last ${n} full month${n === 1 ? "" : "s"} vs the ${n} before` : "Month by month"} · hatched bar = partial month${monthKeys.length < 13 ? ` · ${covers}` : ""}` : "Each service's monthly spend, ranked by growth"}>
      {body}
    </PatternCard>
  );
}

/** Services by change vs the previous window, net of the discount; the rest closes the gap exactly. */
function costMovers(rows: Row[], discountPct: any) {
  const keep = 1 - numOrZero(discountPct);
  const judged = rows.filter((r) => r.status !== "NOT_ASSESSED" && r.est_current_usd_list != null);
  // Nothing priced and compared: no change to show, never a $0 one.
  if (!judged.length) return null;
  const by = new Map<string, { svc: string; cur: number; prev: number }>();
  judged.forEach((r) => {
    const k = String(serviceOf(r) || "");
    const g = by.get(k) || { svc: k, cur: 0, prev: 0 };
    g.cur += numOrZero(r.est_current_usd_list) * keep;
    g.prev += numOrZero(r.est_previous_usd_list) * keep;
    by.set(k, g);
  });
  const all = [...by.values()].map((g) => ({ ...g, delta: g.cur - g.prev }));
  const cur = all.reduce((s, g) => s + g.cur, 0), prev = all.reduce((s, g) => s + g.prev, 0);
  return { all, cur, prev, delta: cur - prev, services: all.filter((g) => g.cur > 0).length };
}

const MONTH_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const signedUsd = (v: number) => `${v >= 0 ? "+" : "−"}${fmtMoney(Math.abs(v), 0)}`;
type TileSev = "critical" | "warn" | "ok" | "not_assessed" | "neutral";
function sevOfFinding(f: Finding | null | undefined): TileSev {
  if (!f) return "neutral";
  const b = bandOf(f);
  return b === "CRITICAL" ? "critical" : b === "WARN" ? "warn" : b === "NOT_ASSESSED" || b === "ERROR" ? "not_assessed" : "ok";
}
const SEV_RANK: Record<string, number> = { critical: 0, warn: 1, ok: 2, neutral: 3, not_assessed: 4 };

export function CostTrendContent({ findings, filters, meta, maxCat, onVerdict, goTo }: { findings?: Finding[] | null; filters: Filters; meta?: Meta | null; maxCat?: number; onVerdict?: ((sentence: string | null) => void) | null; goTo?: GoToFn | null }) {
  useNames();
  const acct = filters.accountIds;
  // The unit and quantity ride along so credits can stand in when there is no price.
  const dayKindAgg = useFindingAgg("cost_dollarized_by_service_day", filters.window, acct, ["usage_date", "sku_name", "usage_unit"], "sum", COST_MONEY_COL, { also: ["net_usage_quantity"] });
  const [dayGrain, setDayGrain] = React.useState<Grain>("day");
  const periodState = useFindingData("cost_period_over_period", filters.window, acct);
  const monthAgg = useFindingAgg("cost_monthly_actuals", filters.window, acct, ["month_start", "partial_reason"], "sum", "net_list_cost_usd");
  const forecastState = useFindingData("sf_cost_month_end_forecast", filters.window, acct);
  const anomalyState = useFindingData("sf_cost_anomalies_vs_spikes", filters.window, acct);
  const invoiceState = useFindingData("sf_cost_invoice_vs_metered", filters.window, acct);
  const alloc = useCostCenterAllocation(filters);
  const fById = (id: string) => (findings || []).find((f) => f.query_id === id) || null;
  const range = (windowShortLabel(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days) || "").split(",")[0] || `last ${filters.window} days`;

  // Spend by day and kind, discounted once; $ when priced, else credits by kind (storage and transfer
  // have no credits). Every day of the window is in, so a day with no usage is a real 0, never skipped.
  const dkReady = dayKindAgg.phase === "ready" && dayKindAgg.outcome === "ok_rows";
  const unpricedSpend = isUnpricedAgg(dayKindAgg.data);
  const disc = dkReady ? numOrZero(dayKindAgg.data.discount_pct) : 0;
  const dayRows = dkReady ? (dayKindAgg.data.groups || []).map((g: Row) => ({ day: String(g.key[0]).slice(0, 10), kind: dayKindOf(g.key[1]), value: numOrZero(g.value) * (1 - disc) })) : null;
  const crRows = dkReady ? (dayKindAgg.data.groups || []).filter((g: Row) => String(g.key[2] || "").toUpperCase() === CREDIT_UNIT)
    .map((g: Row) => ({ day: String(g.key[0]).slice(0, 10), kind: dayKindOf(g.key[1]), value: numOrZero(g.also && g.also.net_usage_quantity) })) : null;
  const chartRows = unpricedSpend ? crRows : dayRows;
  const byDay = new Map<string, number>();
  (chartRows || []).forEach((r: { day: string; value: number }) => byDay.set(r.day, (byDay.get(r.day) || 0) + r.value));
  const chartDays = dkReady ? windowDayList(meta, filters.window, byDay.keys()) : [];
  const daily = dkReady ? chartDays.map((day) => ({ day, value: byDay.get(day) || 0 })) : null;
  const dayFmt = unpricedSpend ? fmtCr : (v: number) => fmtMoney(v, 0);
  const spend = dkReady ? aggTotal(dayKindAgg.data) : null;
  const avg = daily && daily.length ? (spend ?? 0) / daily.length : null;
  const partialDay = (meta && meta.cost_cutoff && meta.cost_cutoff.partial_day) || null;

  // Spike days: this audit's rule (on what the daily chart draws) or Snowflake's anomaly flag, one set.
  const anomalyRows = anomalyState.phase === "ready" && anomalyState.outcome === "ok_rows" ? withoutTotalRows(anomalyState.data.rows || []) : null;
  const sfDays = new Set<string>((anomalyRows || []).filter((r: Row) => [r.snowflake_anomaly, r.our_spike].some((v) => v === true || v === "true")).map((r: Row) => String(r.usage_date).slice(0, 10)));
  const auditSpikes = daily ? totalSpikeDays(daily) : [];
  const auditByDay = new Map(auditSpikes.map((s) => [s.day, s]));
  const spikeDays = (daily || []).map((d) => d.day).filter((d) => auditByDay.has(d) || sfDays.has(d));
  const worst = auditSpikes.length ? [...auditSpikes].sort((a, b) => b.pct - a.pct)[0] : null;
  const aboveExpected = anomalyRows ? sumBy(anomalyRows, "est_change_usd_list") * (1 - numOrZero(anomalyState.data.discount_pct)) : null;
  const spikeSev = [sevOfFinding(fById("cost_daily_spikes")), sevOfFinding(fById("sf_cost_anomalies_vs_spikes"))].sort((a, b) => SEV_RANK[a] - SEV_RANK[b])[0];

  // Change vs the previous window, and how much of the rise the top risers carry.
  const periodRows = periodState.phase === "ready" && periodState.outcome === "ok_rows" ? withoutTotalRows(periodState.data.rows) : null;
  const mv = periodRows ? costMovers(periodRows, periodState.data.discount_pct) : null;
  const periodGap = periodState.phase !== "ready" ? undefined : !periodRows ? notAssessedText(periodState.data)
    : periodRows.length && periodRows.every((r: Row) => r.price_basis === "unpriced") ? NO_PRICE_READING
    : periodRows.some((r: Row) => r.not_assessed_reason === "previous_window_not_covered") ? `The previous ${filters.window} days are not in this export.`
    : "No previous period to compare.";
  const changePct = mv && mv.prev > 0 ? (mv.delta / mv.prev) * 100 : null;
  const risers = mv ? mv.all.filter((g) => g.delta > 0).sort((a, b) => b.delta - a.delta) : [];
  const rise = risers.reduce((s, g) => s + g.delta, 0);
  const topRisers = risers.slice(0, 5);
  const riseShare = rise > 0 ? pctOf(topRisers.reduce((s, g) => s + g.delta, 0), rise) : null;

  // Calendar months and the month-end forecast.
  const monthReady = monthAgg.phase === "ready" && monthAgg.outcome === "ok_rows";
  const months = monthReady && !isUnpricedAgg(monthAgg.data) ? buildMonthBars(monthAgg.data.groups, monthAgg.data.discount_pct, 13) : null;
  const lastFull = months ? [...months].reverse().find((m) => !m.partial) : null;
  const fRows = forecastState.phase === "ready" && forecastState.outcome === "ok_rows" ? forecastState.data.rows : null;
  const forecast = forecastFigures(fRows, forecastState.data && forecastState.data.discount_pct);
  const projected = forecast ? forecast.projected : null;
  const refDay = String((meta && meta.cost_cutoff && (meta.cost_cutoff.data_through || meta.cost_cutoff.partial_day)) || (meta && meta.as_of_date) || "").slice(0, 10);
  const monthName = refDay ? MONTH_LONG[Number(refDay.slice(5, 7)) - 1] || "" : "";

  // Metered -> Invoice -> Allocated: the totals this page could quote, with the gap between each.
  const invRows = invoiceState.phase === "ready" && invoiceState.outcome === "ok_rows" ? withoutTotalRows(invoiceState.data.rows || []) : null;
  const invCurrencies = invRows ? [...new Set(invRows.map((r: Row) => String(r.currency || "").toUpperCase()).filter(Boolean))] : [];
  const invForeign = invCurrencies.find((c) => c !== "USD");
  const allocData = alloc.phase === "ready" && alloc.data && alloc.data.outcome === "ok_rows" ? alloc.data : null;
  const allocRecon = allocData && allocData.reconciliation;
  const allocRaw = allocRecon && allocRecon.rollup_usd != null ? allocRecon.rollup_usd : allocData && allocData.total ? allocData.total.usd : null;
  const allocUsd = allocRaw != null ? numOrZero(allocRaw) : null;
  // Invoice lines with no amount are not a $0 invoice.
  const invPriced = invRows ? invRows.filter((r: Row) => r.invoice_amount != null) : [];
  const outsideSplit = allocRecon ? numOrZero(allocRecon.outside_split_usd) : 0;
  const reconSteps: ReconStep[] = [
    { key: "metered", label: "Metered (usage views)", value: spend, note: "credits × your effective $ per credit",
      missingReason: dayKindAgg.phase !== "ready" ? "…" : unpricedSpend ? NO_PRICE_READING : notAssessedText(dayKindAgg.data) },
    { key: "invoice", label: invCurrencies.length === 1 ? `Invoiced (${invCurrencies[0]})` : "Invoiced", value: invPriced.length && !invForeign ? sumBy(invPriced, "invoice_amount") : null,
      note: "invoice lines; lag up to 72 h",
      missingReason: invForeign ? `In ${invForeign}: not comparable with $` : invoiceState.phase !== "ready" ? "…" : invoiceState.outcome === "ok_rows" ? "No invoice lines" : notAssessedText(invoiceState.data) },
    { key: "allocated", label: "Allocated by cost center", value: allocUsd, note: outsideSplit > 0 ? `storage & transfer ${fmtMoney(outsideSplit, 0)} not split` : "split by cost center",
      missingReason: alloc.phase === "loading" ? "…" : alloc.phase === "error" ? "Could not load the split" : allocData && unpricedSpend ? NO_PRICE_READING : "No cost-center split" },
  ];

  const loadingAll = dayKindAgg.phase === "loading" || periodState.phase === "loading" || forecastState.phase === "loading";
  const lede = loadingAll ? "…" : spend == null ? (unpricedSpend ? NO_PRICE_LEDE : "Spend could not be assessed for this window.")
    : [`${fmtMoney(spend, 0)} over the last ${daily ? daily.length : filters.window} days`,
      changePct != null && mv ? `, ${fmtChangePct(changePct)} (${signedUsd(mv.delta)}) vs the previous ${filters.window}` : "",
      ".",
      daily ? ` ${fmtInt(spikeDays.length)} of ${fmtInt(daily.length)} days spiked` : "",
      projected != null ? `; the month is heading for ${fmtMoney(projected, 0)}.` : (daily ? "." : "")].join("");
  React.useEffect(() => { if (onVerdict) onVerdict(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const go = (subtab: string) => (goTo ? () => goTo({ tab: "cost", subtab }) : undefined);
  const moverItems = mv ? [...mv.all].filter((g) => Math.abs(g.delta) >= 0.5).sort((a, b) => Math.abs(b.delta) - Math.abs(a.delta)) : [];
  const shownMovers = moverItems.slice(0, 5);
  const restDelta = mv ? mv.delta - shownMovers.reduce((s, g) => s + g.delta, 0) : 0;
  const moverBars = [
    ...shownMovers.map((g) => ({ name: serviceWords(g.svc || null) + (g.prev < 1 && g.cur >= 1 ? " · new" : ""), value: g.delta })),
    ...(moverItems.length > shownMovers.length && Math.abs(restDelta) >= 0.5 ? [{ name: `${fmtInt(moverItems.length - shownMovers.length)} others`, value: restDelta }] : []),
  ];
  const spikeList = spikeDays.slice(0, 5).map((d) => fmtDayShort(d)).join(", ");

  // The daily chart's month view sums the same window days.
  const dayMonths = monthsOfDays(chartDays, (daily || []).map((d) => d.value));
  const dayOpenMonth = dayMonths.find((m) => m.why === "month in progress");

  return (
    <div className="sx-page">
      <div className="summary-tile-row compact sx-tiles-4">
        <IssueTile label={`Spend · ${filters.window} days`} loading={dayKindAgg.phase === "loading"} pill={<KindChip>Context</KindChip>}
          headline={spend != null ? fmtMoney(spend, 0) : null} missingReason={notAssessedText(dayKindAgg.data)}
          base={spend != null ? [range, avg != null ? `daily avg ${fmtMoney(avg, 0)}` : null, mv ? `${fmtInt(mv.services)} services` : null].filter(Boolean).join(" · ") : null}
          cause="Metered at your effective $ per credit." onOpen={go("service")} openLabel="By service →" />
        <IssueTile label={`Change vs previous ${filters.window} days`} loading={periodState.phase === "loading"} pill={<KindChip>Context</KindChip>}
          headline={changePct != null ? fmtChangePct(changePct) : null} unit={mv ? signedUsd(mv.delta) : undefined}
          missingReason={periodGap}
          base={mv && changePct != null ? `${fmtMoney(mv.prev, 0)} → ${fmtMoney(mv.cur, 0)}${riseShare != null ? ` · ${fmtInt(topRisers.length)} services are ${fmtShare(riseShare)} of the rise` : ""}` : null}
          cause="A change, never added to spend or waste." onOpen={() => scrollToAnchor("ct-movers")} openLabel="What moved spend ↓" />
        <IssueTile label="Spike days" loading={dayKindAgg.phase === "loading" || anomalyState.phase === "loading"} status={daily ? (spikeDays.length ? spikeSev : "ok") : "neutral"}
          headline={daily ? `${fmtInt(spikeDays.length)} of ${fmtInt(daily.length)}` : null} unit="days" missingReason={notAssessedText(dayKindAgg.data)}
          base={worst ? `Worst ${fmtDayShort(worst.day)} · ${dayFmt(worst.value)} · ${(worst.value / worst.median).toFixed(1)}× the 7-day median` : null}
          cause={aboveExpected != null && aboveExpected > 0 ? `${fmtMoney(aboveExpected, 0)} above expected on flagged days: a change, not added to spend.` : `Rule: ${unpricedSpend ? "credits " : ""}${SPIKE_PCT}%+ over the 7-day median, or Snowflake's anomaly flag.`}
          onOpen={() => scrollToAnchor("ct-days")} openLabel="Spend by day ↓" />
        <IssueTile label="Month-end forecast" loading={forecastState.phase === "loading"} status={projected != null ? sevOfFinding(fById("sf_cost_month_end_forecast")) : "neutral"}
          headline={projected != null ? fmtMoney(projected, 0) : null} unit={monthName || undefined}
          missingReason={forecastState.phase === "ready" ? notAssessedText(forecastState.data) : undefined}
          base={projected != null ? [forecast && forecast.monthToDate != null ? `${fmtMoney(forecast.monthToDate, 0)} to date` : null,
            lastFull ? `last full month ${fmtMoney(lastFull.total, 0)} (${lastFull.shortLabel})` : null].filter(Boolean).join(" · ") : null}
          cause={projected != null && lastFull && lastFull.total > 0 ? `${fmtChangePct((projected / lastFull.total - 1) * 100)} vs ${lastFull.label}; a projection, partial.` : null}
          onOpen={() => scrollToAnchor("ct-months")} openLabel="By calendar month ↓" />
      </div>

      <div className="cj-charts-2">
        <div id="ct-movers">
          <PatternCard title={mv ? `What moved spend ${signedUsd(mv.delta)}` : "What moved spend"}
            sub={`Change vs the previous ${filters.window} days, by service${riseShare != null ? ` · ${fmtInt(topRisers.length)} services are ${fmtShare(riseShare)} of the rise` : ""}`}
            link="By service →" onLink={go("service") || null}>
            {mv ? (moverBars.length ? <DivergingBars items={moverBars} n={6} valueFmt={signedUsd} unitLabel="Change" ariaLabel="Change in spend by service" />
              : <div className="chart-note-oneline">{`No service changed in ${range}.`}</div>)
              : periodRows ? <div className="chart-note-oneline">{`– ${periodGap}`}</div>
              : <ChartNote state={periodState} label="cost_period_over_period" />}
            {mv && <div className="sx-foot">{`${fmtMoney(mv.prev, 0)} → ${fmtMoney(mv.cur, 0)} · change is its own kind: shown apart, never added to waste or saving.`}</div>}
          </PatternCard>
        </div>
        <div id="ct-months">
          <PatternCard title="By calendar month" sub="Last 12 months and this month · metered at your effective rate · this month is partial">
            {months && months.length ? <MonthChart months={months} />
              : monthReady && isUnpricedAgg(monthAgg.data) ? <div className="chart-note-oneline">{`– ${NO_PRICE_READING}`}</div>
              : <ChartNote state={monthAgg} label="cost_monthly_actuals" />}
          </PatternCard>
        </div>
      </div>

      <div id="ct-days">
        <Card title={dayGrain === "day" ? (unpricedSpend ? "Credits by day, by kind" : "Spend by day, by kind") : (unpricedSpend ? "Credits by month" : "Spend by month")}
          right={<GrainSwitch value={dayGrain} onChange={setDayGrain} />}>
          <div className="pc-sub">{dayGrain === "day"
            ? `${range}${partialDay ? " · the last day is partial" : ""}${spikeDays.length ? ` · spike days ${spikeList}${spikeDays.length > 5 ? "…" : ""}` : ""}`
            : `The window's days summed by month${dayOpenMonth ? ` · ${fmtMonth(dayOpenMonth.key)} is partial` : ""}`}</div>
          {chartRows && daily ? (dayGrain === "day" ? (
            <DayKindTimeline rows={chartRows} days={chartDays} kinds={DAY_KINDS} partialDay={partialDay} height={200}
              kindColors={{ [DAY_KINDS[0]]: "var(--c1)", [DAY_KINDS[1]]: "var(--c2)", [DAY_KINDS[2]]: "var(--c-other)" }}
              valueFmt={dayFmt} ariaLabel={unpricedSpend ? "Credits by day, by kind" : "Spend by day, by kind"} />
          ) : dayMonths.length < 2
            ? <div className="chart-note ok"><div className="chart-note-text">{ONE_MONTH_NOTE(dayMonths.length ? dayMonths[0].key : monthOf(chartDays[0] || ""))}</div></div>
            : <PlainMonthBars months={dayMonths} fmt={dayFmt} />) : <ChartNote state={dayKindAgg} label="cost_dollarized_by_service_day" />}
          {unpricedSpend && dkReady && <div className="sx-foot">{`$ –: ${NO_PRICE_READING} Storage and transfer are not billed in credits, so they are not here.`}</div>}
        </Card>
      </div>

      <TrendByCard filters={filters} meta={meta} serviceAgg={dayKindAgg} />

      <div className="cj-charts-2">
        <ChangeBreakdownCard periodState={periodState} filters={filters} maxCat={maxCat} meta={meta} />
        <FastestGrowingCard filters={filters} maxCat={maxCat} />
      </div>

      <CostHourCard filters={filters} meta={meta} />

      <PatternCard title="Ties to the bill" sub="Metered → invoiced → allocated · the invoice view lags up to 72 h" link="Contract & rate →" onLink={go("contract") || null}>
        {dayKindAgg.phase === "loading" || invoiceState.phase === "loading" || alloc.phase === "loading"
          ? <div className="chart-note-oneline">…</div> : <ReconciliationStrip steps={reconSteps} />}
      </PatternCard>
    </div>
  );
}
AreaContent.register("cost", "trend", CostTrendContent);
