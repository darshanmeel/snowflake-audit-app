// web/src/components/area_ai_storage.tsx -- the AI & apps and Storage sub-tab pages: issue tiles
// first (a % or flagged $, "N of M", the top cause, Open), then the charts that show the driver.
// Every figure is read off the checks' own rows; a check that did not run reads "–" and why.
import React from "react";
import "../styles/css/p_area_ai_storage.css";
import { fmtChange, fmtDayShort, fmtInt, fmtMoney, fmtMoneyOf } from "../format";
import { numOrZero, useFindingAgg, useFindingData } from "./hooks";
import { ChartCard, KindChip, bandOf } from "./primitives";
import { DrillTable, MiniBar, SplitBar } from "./drill_table";
import { DrawerBus } from "./drawer";
import { notAssessedText } from "./scope";
import { SummaryTileRow, SummaryTileSpark, partialBarKeys, windowShortLabel } from "./overview_tile";
import { MultiLine, truncateLeft, useChartWidth } from "./charts";
import { Columns, rowLabelWidth } from "./charts_more";
import { windowDayList } from "./run_blocks";
import { DAY_ROWS_MAX, GrainSwitch, fmtMonth, partialMonths, rollUpMonths } from "./grain";
import type { Grain } from "./grain";
import { CsvButton } from "./csv";
import {
  CauseSplitBar, DayKindTimeline, IssueTile, ShareBarList, StackedShareBar, StatusBars, fmtShare, pctOf,
} from "./blocks";
import type { IssueTileProps, ShareSegment, StatusBarItem } from "./blocks";
import { MONEY_KIND_WORD, findingForId, moneyPeriodWord, upToWord, withoutTotalRows } from "../tabs/tab_area";
import { moneyKindOf } from "./waste_total";
import { CortexAgentsPanel } from "./ai_cortex_agents";
import type { ApPageProps } from "./area_pages";
import type { FetchState, Finding, Row } from "../types";

// ═══════════════════════ shared helpers ═══════════════════════

/** One check as a page reads it: its rows when it ran, else why not. */
export interface Chk {
  f: Finding | null;
  rows: Row[] | null;
  /** Rows with the total/tie-out rows kept. */
  allRows: Row[] | null;
  why: string | null;
  /** An empty window, not a failure: no dash in front. */
  empty: boolean;
  loading: boolean;
  disc: number;
  open: () => void;
}

// A check homed on another sub-tab (churn on Unused) is read from the full index.
const findingAnywhere = (p: ApPageProps, id: string) => findingForId(p.findings, id) || (p.allFindingsIndex ? p.allFindingsIndex[id] || null : null);

export function useCheck(p: ApPageProps, id: string): Chk {
  const f = findingAnywhere(p, id);
  const state = useFindingData(f ? id : null, p.filters.window, p.filters.accountIds, 5000) as FetchState;
  return chkOf(p, id, f, state, (d) => d.rows);
}

/** A check summed by the aggregate route, as a Chk whose rows are its groups ({key, value, also}). */
function useAggCheck(p: ApPageProps, id: string, group: string[], value: string, also: string[]): Chk {
  const f = findingAnywhere(p, id);
  const state = useFindingAgg(f ? id : null, p.filters.window, p.filters.accountIds, group, "sum", value, { also }) as FetchState;
  return { ...chkOf(p, id, f, state, (d) => d.groups), open: () => DrawerBus.open({ id }) };
}

function chkOf(p: ApPageProps, id: string, f: Finding | null, state: FetchState, rowsOf: (d: Row) => Row[] | null | undefined): Chk {
  const open = () => p.goTo({ tab: p.area, subtab: p.subtab, focusQueryId: id });
  const base = { f, rows: null, allRows: null, why: null, empty: false, loading: false, disc: 0, open };
  if (!f) return { ...base, why: "Not in this export yet: run the export again." };
  if (state.phase === "loading") return { ...base, loading: true };
  if (state.phase === "error") return { ...base, why: state.error || "Could not load" };
  const d = state.data || {};
  switch (state.outcome) {
    case "not_assessed": return { ...base, why: notAssessedText(d) };
    case "error": return { ...base, why: d.error || "The check failed." };
    case "ok_empty_window": {
      const w = windowShortLabel(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
      return { ...base, empty: true, why: `No data for this in ${w || `the last ${p.filters.window} days`}` };
    }
    case "ok_empty_filters":
      return { ...base, empty: true, why: d.scope && d.scope.none_flagged ? "Nothing flagged in this window." : "The current filters exclude every row." };
    case "ok_rows": break;
    default: return { ...base, why: "Not in this export." };
  }
  const rows = rowsOf(d) || [];
  return { ...base, allRows: rows, rows: withoutTotalRows(rows), disc: numOrZero(d.discount_pct) };
}

export const isFlagged = (r: Row) => r.status === "CRITICAL" || r.status === "WARN";
export const isPriced = (rows: Row[]) => rows.some((r) => r.price_basis !== "unpriced");
const BIN = 1024 ** 3;
export const gbOf = (bytes: any) => numOrZero(bytes) / BIN;
/** GB or TB, as the checks write them (1 TB = 1,024 GB). */
export function fmtSize(gb: number): string {
  if (!Number.isFinite(gb)) return "–";
  if (gb >= 1024) return `${(gb / 1024).toFixed(gb >= 10240 ? 0 : 1)} TB`;
  // A few KB is not an empty table: below 0.05 GB the size reads in MB or KB, never "0.0 GB".
  if (gb > 0 && gb < 0.05) {
    const mb = gb * 1024;
    return mb >= 1 ? `${mb.toFixed(1)} MB` : `${Math.max(1, Math.round(mb * 1024))} KB`;
  }
  return `${gb >= 10 ? fmtInt(Math.round(gb)) : gb.toFixed(1)} GB`;
}
// Small AI and serving spend reads "0.0021 credits", never "0 credits".
const fmtCreditsShort = (v: number) => fmtCreditsFine(v);
const signedShare = (pct: number | null) => (pct == null ? "–" : `${pct >= 0 ? "+" : "−"}${fmtShare(Math.abs(pct))}`);
/** "name (id)" when the row carries an id. */
export const nameId = (name: any, id: any, empty = "(unnamed)") => {
  const n = name === null || name === undefined || name === "" ? empty : String(name);
  return id === null || id === undefined || id === "" || n.endsWith(`(${id})`) ? n : `${n} (${id})`;
};

/** A row's current $ (after the what-if discount), or its credits when nothing is priced. */
function spendOf(rows: Row[], disc: number, usdCol: string, creditCol: string) {
  const priced = isPriced(rows);
  return {
    priced,
    val: (r: Row) => (priced ? numOrZero(r[usdCol]) * (1 - disc) : numOrZero(r[creditCol])),
    fmt: priced ? (v: number) => fmtMoney(v, 0) : fmtCreditsShort,
  };
}

/** Change chip: "+221%", "new"; tone bad only when the check flagged the row. */
function changeChip(cur: number, prev: number, flagged: boolean): IssueTileProps["trend"] {
  const t = fmtChange(cur, prev, false);
  if (t === "-") return null;
  return { text: `${t} vs before`, direction: cur > prev ? "up" : cur < prev ? "down" : "flat", tone: flagged && cur > prev ? "bad" : "neutral" };
}

export function bandStatus(f: Finding | null): IssueTileProps["status"] {
  const b = f ? bandOf(f) : "NOT_ASSESSED";
  return b === "CRITICAL" ? "critical" : b === "WARN" ? "warn" : b === "OK" || b === "RANKED" ? "ok" : "neutral";
}

/** An IssueTile on one check: "…" while loading, "–" and why when it did not run. `build` gets the rows. */
export function CheckTile({ c, label, badge = false, build }: {
  c: Chk; label: string; badge?: boolean; build: (rows: Row[], c: Chk) => Partial<IssueTileProps>;
}) {
  const common = { label, onOpen: c.open, openLabel: "Open check →" };
  if (c.loading) return <IssueTile {...common} headline={null} loading />;
  if (c.why || !c.rows) return <IssueTile {...common} headline={null} missingReason={c.why} status={c.empty ? "neutral" : "not_assessed"} />;
  return <IssueTile {...common} headline={null} status={badge ? bandStatus(c.f) : "neutral"} {...build(c.rows, c)} />;
}

/** The $ a MoneyTile shows for a check, formatted ("$1,014"), or null when it is not priced. */
export function tileMoney(f: Finding | null): string | null {
  const m = f && f.money;
  if (!f || !m || f.money_reason === "unpriced" || m.usd == null) return null;
  const a = f.affected;
  const part = m.basis === "all" && m.usd_flagged != null && a && a.flagged > 0 && a.flagged < a.total;
  return `${upToWord(f)}${fmtMoneyOf(m, part ? m.usd_flagged : m.usd, 0)}`;
}

/** The check's own money figure (the same $ every other page shows), with "N of M" and a cause. */
export function MoneyTile({ c, label, badge = true, cause }: { c: Chk; label: string; badge?: boolean; cause?: (rows: Row[]) => React.ReactNode }) {
  return (
    <CheckTile c={c} label={label} badge={badge} build={(rows) => {
      const f = c.f!;
      const m = f.money;
      const a = f.affected;
      const pop = a ? { flagged: a.flagged, population: a.total, noun: a.noun } : {};
      if (!m || f.money_reason === "unpriced" || m.usd == null) {
        return { ...pop, headline: null, missingReason: "not priced: no $ price in this export", cause: cause ? cause(rows) : undefined };
      }
      const period = moneyPeriodWord(m.column, m.kind);
      const part = m.basis === "all" && m.usd_flagged != null && a && a.flagged > 0 && a.flagged < a.total;
      const kindWord = MONEY_KIND_WORD[moneyKindOf(f) as string] || "";
      return {
        ...pop,
        headline: tileMoney(f),
        unit: period === "per month" ? "/mo" : undefined,
        cause: cause ? cause(rows) : (part ? `of ${fmtMoneyOf(m, m.usd, 0)} ${kindWord}` : kindWord),
      };
    }} />
  );
}

/** A chart card on one check: "…", "– why" or the body; a null body hides the card. */
export function Slot({ c, title, subtitle, children }: { c: Chk; title: string; subtitle?: string; children: (rows: Row[], c: Chk) => React.ReactNode }) {
  let body: React.ReactNode;
  if (c.loading) body = <div className="chart-note-oneline">…</div>;
  else if (c.why || !c.rows) body = <div className="chart-note-oneline">{c.empty ? c.why : `– ${c.why}`}</div>;
  else body = children(c.rows, c);
  if (!body) return null;
  return <ChartCard title={title} subtitle={subtitle} onOpenCheck={c.open} takeaway={null}>{body}</ChartCard>;
}

export function Row2({ children }: { children?: React.ReactNode }) {
  return <div className="cj-charts-2">{children}</div>;
}

/** One service's spend per day of the window from the daily bill: $ when priced, else credits. */
interface ServiceDays {
  c: Chk;
  days: string[];
  values: number[];
  priced: boolean;
  /** Today, still filling. */
  partial: string[];
  /** Complete days only, for a tile sparkline; null when there is nothing to draw. */
  spark: number[] | null;
}

// `max` when the bill names one service twice (AI_SERVICES and AI_INFERENCE), so a day is not counted twice.
function useServiceDays(p: ApPageProps, match: RegExp, combine: "sum" | "max"): ServiceDays {
  const c = useAggCheck(p, "cost_dollarized_by_service_day", ["usage_date", "billing_origin_product", "usage_unit"], "net_list_cost", ["net_usage_quantity"]);
  const groups = (c.rows || []).filter((g) => match.test(String((g.key || [])[1] || "")));
  const priced = groups.some((g) => g.value !== null && g.value !== undefined);
  // Per day and product first, then across products.
  const byProd = new Map<string, Map<string, number>>();
  groups.forEach((g) => {
    const [day, product, unit] = g.key || [];
    // Credits come only from CREDITS-unit rows; $ from every row.
    const v = priced ? numOrZero(g.value) * (1 - c.disc) : String(unit || "").toUpperCase() === "CREDITS" ? numOrZero(g.also && g.also.net_usage_quantity) : 0;
    const d = String(day).slice(0, 10), m = byProd.get(d) || new Map<string, number>();
    m.set(String(product), (m.get(String(product)) || 0) + v);
    byProd.set(d, m);
  });
  const days = c.rows ? windowDayList(p.meta, p.filters.window, [...byProd.keys()]) : [];
  const values = days.map((d) => {
    const v = [...(byProd.get(d) || new Map<string, number>()).values()];
    return v.length ? (combine === "max" ? Math.max(...v) : v.reduce((a, x) => a + x, 0)) : 0;
  });
  const partial = partialBarKeys(days, false);
  const full = values.filter((_, i) => !partial.includes(days[i]));
  return { c, days, values, priced, partial, spark: full.length >= 2 && full.some((v) => v > 0) ? full : null };
}

/** The days a check reads up to the export date, today named partial: "Sep 15 – Oct 14, Oct 14 partial". */
function spanLabel(days: string[], partial: string[]): string | null {
  if (!days.length) return null;
  const last = days[days.length - 1];
  return `${fmtDayShort(days[0])} – ${fmtDayShort(last)}${partial.includes(last) ? `, ${fmtDayShort(last)} partial` : ""}`;
}

/** Credits at a sensible precision: AI spend on a small account is a few thousandths of a credit. */
function fmtCreditsFine(v: number): string {
  const a = Math.abs(v);
  const n = a >= 100 ? fmtInt(Math.round(v)) : a >= 1 ? v.toFixed(1) : a >= 0.01 ? v.toFixed(2) : a > 0 ? v.toPrecision(2) : "0";
  return `${n} credits`;
}

/** A service's spend per day (today faded) or per month (partial months named), with a Day/Month switch. */
function ServiceDaysChart({ s, what, w, grain, setGrain }: { s: ServiceDays; what: string; w: string | null; grain: Grain; setGrain: (g: Grain) => void }) {
  const fmt = s.priced ? (v: number) => fmtMoney(v, 0) : fmtCreditsFine;
  if (!s.values.some((v) => v > 0)) return <div className="chart-note-oneline">{`No data for this in ${w || "this window"}`}</div>;
  let body: React.ReactNode;
  if (grain === "day") {
    const from = Math.max(0, s.days.length - DAY_ROWS_MAX);
    body = (
      <Columns days={s.days.slice(from)} series={[{ name: `${what} ${s.priced ? "$" : "credits"}`, values: s.values.slice(from) }]}
        valueFmt={fmt} unitLabel={s.priced ? "$" : "credits"} dollarAxis={s.priced} partialDays={s.partial}
        ariaLabel={`${what} spend per day`} note={from > 0 ? `Latest ${fmtInt(DAY_ROWS_MAX)} of ${fmtInt(s.days.length)} days.` : null} />
    );
  } else {
    const r = rollUpMonths(s.days, [s.values]);
    const pm = partialMonths(s.days, true);
    const isPart = (m: string) => m === pm.open || m === pm.cut;
    const full = r.months.filter((m) => !isPart(m)).length;
    const totals = <div className="metric-note">{r.months.map((m, i) => `${fmtMonth(m)}${isPart(m) ? " (partial)" : ""}: ${fmt(r.series[0][i])}`).join(" · ")}</div>;
    // Two partial months joined by a line read as a trend; MultiLine's axis also rounds sub-1 values to 0.
    body = full < 2 || Math.max(...r.series[0]) < 10
      ? (
        <>
          <div className="chart-note-oneline">{full < 2 ? `${fmtInt(full)} complete month${full === 1 ? "" : "s"} in this window: pick a longer window for a monthly trend.` : "Too small for a monthly line; the totals are below."}</div>
          {totals}
        </>
      )
      : (
        <>
          <MultiLine series={[{ label: `${what} ${s.priced ? "$" : "credits"}`, color: "var(--c1)", data: r.series[0] }]}
            xLabels={r.months.map((m) => `${fmtMonth(m)}${isPart(m) ? " (partial)" : ""}`)} />
          {totals}
        </>
      );
  }
  return (
    <>
      <div className="ais-grain-row"><GrainSwitch value={grain} onChange={setGrain} /></div>
      {body}
    </>
  );
}

/** "AI spend 5.9% of bill ▲ +221%" from one service row of sf_ai_services_spend_trend. */
function serviceShare(rows: Row[], c: Chk, service: string, word: string, spark: number[] | null, w: string | null): Partial<IssueTileProps> {
  const mine = rows.filter((x) => String(x.service_type || "").toUpperCase() === service);
  if (!mine.length) return { headline: "0%", unit: " of bill", cause: `No ${word} billed in ${w || "the window"}` };
  const s = spendOf(mine, c.disc, "est_current_usd_list", "current_credits");
  const cur = mine.reduce((a, r) => a + s.val(r), 0);
  const prev = mine.reduce((a, r) => a + (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits)), 0);
  // One row per account: the share is re-weighted by each account's bill, never averaged.
  const bill = mine.reduce((a, r) => a + (numOrZero(r.share_of_bill_pct) > 0 ? numOrZero(r.current_credits) / (numOrZero(r.share_of_bill_pct) / 100) : 0), 0);
  const credits = mine.reduce((a, r) => a + numOrZero(r.current_credits), 0);
  return {
    headline: mine.length === 1 ? fmtShare(numOrZero(mine[0].share_of_bill_pct)) : fmtShare(pctOf(credits, bill)),
    unit: " of bill",
    trend: changeChip(cur, prev, mine.some(isFlagged)),
    cause: (
      <span className="ais-spark-cause">
        <SummaryTileSpark points={spark} />
        <span>{`${s.fmt(cur)} in ${w || "the window"}`}</span>
      </span>
    ),
  };
}

/** Sum value and previous value per key, keeping the worst status. */
export function groupBy(rows: Row[], key: (r: Row) => string, val: (r: Row) => number, prev?: (r: Row) => number) {
  const m = new Map<string, { name: string; value: number; prev: number; status: string; rows: number }>();
  const rank: Record<string, number> = { CRITICAL: 3, WARN: 2, NOT_ASSESSED: 1 };
  rows.forEach((r) => {
    const k = key(r);
    const cur = m.get(k) || { name: k, value: 0, prev: 0, status: "OK", rows: 0 };
    cur.value += val(r);
    if (prev) cur.prev += prev(r);
    cur.rows += 1;
    if ((rank[r.status] || 0) > (rank[cur.status] || 0)) cur.status = r.status;
    m.set(k, cur);
  });
  return [...m.values()];
}

/** Sets the page-head lede from the page's own numbers ("…" while its checks load). */
export function useLede(p: ApPageProps, loading: boolean, text: string | null) {
  const v = loading ? "…" : text;
  React.useEffect(() => { if (p.setLede) p.setLede(v); }, [v]); // eslint-disable-line react-hooks/exhaustive-deps
}
/** A small status chip in a drill table cell: red for critical, amber for warning. */
export const dtChip = (text: string, status: any) => <span className={`dt-chip${status === "CRITICAL" ? " tone-crit" : status === "WARN" ? " tone-warn" : ""}`}>{text}</span>;
export const sumCol = (rows: Row[], col: string) => rows.reduce((a, r) => a + numOrZero(r[col]), 0);
const statusWord = (rows: Row[]): IssueTileProps["status"] => (rows.some((r) => r.status === "CRITICAL") ? "critical" : rows.some((r) => r.status === "WARN") ? "warn" : "ok");

export function useWindowLabel(p: ApPageProps) {
  return windowShortLabel(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
}

// ═══════════════════════ small charts this page needs ═══════════════════════

/** Ranked bars with a colour per item and a legend of the kinds (policy state, invocation type). */
function ColorBars({ items, kinds, n = 10, onBarClick, ariaLabel }: {
  items: { key?: string; name: string; value: number; kind: string; valueText: string }[];
  kinds: { key: string; label: string; color: string }[];
  n?: number; onBarClick?: (() => void) | null; ariaLabel?: string;
}) {
  const [ref, W] = useChartWidth(560);
  const sorted = [...items].filter((it) => it.value > 0).sort((a, b) => b.value - a.value);
  if (!sorted.length) return <div ref={ref} className="chart-note-oneline">Every value is zero in this window.</div>;
  const shown = sorted.slice(0, n);
  const max = shown[0].value || 1;
  const labelW = rowLabelWidth(W);
  const colorOf = (k: string) => (kinds.find((x) => x.key === k) || { color: "var(--c-other)" }).color;
  const present = kinds.filter((k) => shown.some((it) => it.kind === k.key));
  return (
    <div ref={ref} className="blk-sbars" role="list" aria-label={ariaLabel}>
      {present.length >= 2 && (
        <div className="blk-legend">
          {present.map((k) => <span key={k.key} className="blk-legend-item"><span className="blk-sw" style={{ background: k.color }} />{k.label}</span>)}
        </div>
      )}
      {shown.map((it, i) => {
        const inner = (
          <>
            <span className="blk-row-label" style={{ width: labelW }} title={it.name}>{truncateLeft(it.name, labelW - 8)}</span>
            <span className="blk-sbar-track"><span className="blk-sbar-fill" style={{ width: `${Math.max(0, (it.value / max) * 100)}%`, background: colorOf(it.kind) }} /></span>
            <span className="blk-sbar-value ais-value">{it.valueText}</span>
          </>
        );
        const tip = `${it.name}: ${it.valueText}`;
        return onBarClick
          ? <button type="button" role="listitem" key={it.key || `${it.name}-${i}`} className="blk-sbar blk-row-btn" title={tip} onClick={onBarClick}>{inner}</button>
          : <div role="listitem" key={it.key || `${it.name}-${i}`} className="blk-sbar" title={tip}>{inner}</div>;
      })}
      {sorted.length > shown.length && <div className="blk-more">{`+${fmtInt(sorted.length - shown.length)} more not shown`}</div>}
    </div>
  );
}

// Time Travel bands of sf_storage_retention_policy: [column, label, lowest days in the band].
const RETENTION_BANDS: [string, string, number][] = [
  ["tables_0d", "0 d", 0], ["tables_1d", "1 d", 1], ["tables_2_7d", "2–7 d", 2], ["tables_8_30d", "8–30 d", 8], ["tables_31_90d", "31–90 d", 31],
];
const BAND_COLORS = ["var(--seq-1)", "var(--seq-2)", "var(--seq-3)", "var(--seq-4)", "var(--seq-5)"];

/** Tables per database by Time Travel band; bands wholly above the account policy are red. */
function RetentionBands({ rows, n = 8, onOpen }: { rows: Row[]; n?: number; onOpen: () => void }) {
  const [ref, W] = useChartWidth(560);
  const list = rows.filter((r) => numOrZero(r.tables_total) > 0)
    .sort((a, b) => numOrZero(b.over_policy_tables) - numOrZero(a.over_policy_tables) || numOrZero(b.tables_total) - numOrZero(a.tables_total));
  if (!list.length) return <div ref={ref} className="chart-note-oneline">No tables to show.</div>;
  const shown = list.slice(0, n);
  const labelW = rowLabelWidth(W);
  const policy = (r: Row) => (r.max_retention_days === null || r.max_retention_days === undefined ? null : Number(r.max_retention_days));
  return (
    <div ref={ref} className="ais-bands" role="list" aria-label="Tables by Time Travel days, per database">
      <div className="blk-legend">
        {RETENTION_BANDS.map(([, label], i) => <span key={label} className="blk-legend-item"><span className="blk-sw" style={{ background: BAND_COLORS[i] }} />{label}</span>)}
        <span className="blk-legend-item"><span className="blk-sw" style={{ background: "var(--st-crit)" }} />above the account policy</span>
      </div>
      {shown.map((r) => {
        const total = numOrZero(r.tables_total);
        const pol = policy(r);
        const name = nameId(r.database_name, r.database_id, "(unnamed database)");
        const over = numOrZero(r.over_policy_tables);
        const text = pol === null ? `${fmtInt(total)} tables` : `${fmtInt(over)} of ${fmtInt(total)} over ${fmtInt(pol)} d`;
        return (
          <button type="button" role="listitem" key={name} className="blk-sbar blk-row-btn" onClick={onOpen} title={`${name}: ${text}`}>
            <span className="blk-row-label" style={{ width: labelW }}>{truncateLeft(name, labelW - 8)}</span>
            <span className="ais-band-bar">
              {RETENTION_BANDS.map(([col, label, low], i) => {
                const v = numOrZero(r[col]);
                if (v <= 0) return null;
                const above = pol !== null && low > pol;
                return <span key={col} className="ais-band-seg" title={`${label}: ${fmtInt(v)} table${v === 1 ? "" : "s"}${above ? " (above policy)" : ""}`}
                  style={{ width: `${(v / total) * 100}%`, background: above ? "var(--st-crit)" : BAND_COLORS[i] }} />;
              })}
            </span>
            <span className="blk-sbar-value ais-value">{text}</span>
          </button>
        );
      })}
      {list.length > shown.length && <div className="blk-more">{`+${fmtInt(list.length - shown.length)} more not shown`}</div>}
    </div>
  );
}

// ═══════════════════════ AI & apps > Cortex ═══════════════════════

export function ApAiCortex(p: ApPageProps) {
  const trend = useCheck(p, "sf_ai_services_spend_trend");
  const feat = useCheck(p, "sf_ai_spend_by_feature_reconciled");
  const users = useCheck(p, "sf_ai_functions_spend_by_user");
  const pt = useCheck(p, "sf_ai_provisioned_throughput_use");
  const fail = useCheck(p, "sf_ai_credits_on_failed_queries");
  const stale = useCheck(p, "sf_ai_cortex_search_stale_index_serving");
  const access = useCheck(p, "sf_ai_access_open_to_all");
  const search = useCheck(p, "sf_ai_cortex_search_spend");
  // The same two bill names sf_ai_services_spend_trend reads as AI services.
  const aiDays = useServiceDays(p, /^(AI_SERVICES|AI_INFERENCE)$/i, "max");
  const spark = aiDays.spark;
  const [grain, setGrain] = React.useState<Grain>("day");
  const w = useWindowLabel(p);
  // sf_ai_services_spend_trend reads up to the export date, today included: name the same days the chart draws.
  const wAi = spanLabel(aiDays.days, aiDays.partial) || w;
  const aiRows = (trend.rows || []).filter((r) => String(r.service_type || "").toUpperCase() === "AI_SERVICES");
  const aiCur = sumCol(aiRows, "current_credits"), aiPrev = sumCol(aiRows, "previous_credits");
  const ptIdle = (pt.rows || []).filter((r) => isFlagged(r) && numOrZero(r.idle_days) > 0);
  useLede(p, trend.loading || pt.loading, trend.rows && aiCur > 0
    ? `Cortex used ${fmtCreditsShort(aiCur)} in ${wAi || "the window"}${aiPrev > 0 ? `, ${fmtChange(aiCur, aiPrev, false)} vs the period before` : ""}.${ptIdle.length ? ` ${fmtInt(ptIdle.length)} provisioned throughput${ptIdle.length === 1 ? " sat" : "s sat"} idle on paid days.` : ""}`
    : null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <CheckTile c={trend} label="AI spend" build={(rows, c) => ({ ...serviceShare(rows, c, "AI_SERVICES", "AI services", spark, wAi), pill: <KindChip>Context</KindChip> })} />
        <MoneyTile c={pt} label="Idle provisioned throughput" cause={(rows) => {
          const top = [...rows].filter(isFlagged).sort((a, b) => numOrZero(b.est_idle_usd_list) - numOrZero(a.est_idle_usd_list))[0];
          return top ? `${top.throughput_name} idle ${fmtInt(top.idle_days)} of ${fmtInt(top.paid_days)} paid days` : "No paid day went unused";
        }} />
        <CheckTile c={users} label="Top AI functions user" build={(rows, c) => {
          const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
          const prevOf = (r: Row) => (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits));
          const g = groupBy(rows, (r) => String(r.user_name || "(no user)"), s.val, prevOf);
          const total = g.reduce((a, x) => a + x.value, 0);
          const top = [...g].sort((a, b) => b.value - a.value)[0];
          if (!top || total <= 0) return { headline: null, missingReason: "No AI functions spend in this window" };
          return {
            headline: fmtShare(pctOf(top.value, total)), unit: " of AI functions",
            flagged: g.filter((x) => x.status === "CRITICAL").length, population: g.length, noun: "users spiking",
            trend: changeChip(top.value, top.prev, top.status === "CRITICAL"),
            cause: `${top.name} · ${s.fmt(top.value)}`,
          };
        }} />
        <CheckTile c={feat} label="AI bill no feature explains" build={(_rows, c) => {
          const t = (c.allRows || []).find((r) => r.is_total_row);
          if (!t || t.unexplained_pct === null || t.unexplained_pct === undefined) return { headline: null, missingReason: "No billed AI total to compare with" };
          return {
            headline: fmtShare(numOrZero(t.unexplained_pct)), unit: " of AI bill",
            cause: `${fmtCreditsShort(numOrZero(t.unexplained_credits))} of ${fmtCreditsShort(numOrZero(t.billed_credits))} billed`,
          };
        }} />
      </SummaryTileRow>
      <Slot c={{ ...aiDays.c, rows: aiDays.c.rows ? [] : null }} title={`AI spend per ${grain}`}
        subtitle={`${aiDays.priced ? "$" : "credits"} · AI functions, search, analyst (not Cortex Code) · ${grain === "day" ? "today is partial (faded)" : "partial months are marked"}`}>
        {() => <ServiceDaysChart s={aiDays} what="AI" w={wAi} grain={grain} setGrain={setGrain} />}
      </Slot>
      <Row2>
        <Slot c={feat} title="AI spend by feature" subtitle="credits · this period vs the one before">
          {(rows, c) => <FeatureSplit rows={rows} total={(c.allRows || []).find((r) => r.is_total_row) || null} />}
        </Slot>
        <Slot c={users} title="AI functions spend by user" subtitle="red: grew sharply vs the period before">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
            const prevOf = (r: Row) => (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits));
            const items: StatusBarItem[] = groupBy(rows, (r) => String(r.user_name || "(no user)"), s.val, prevOf)
              .filter((x) => x.value > 0)
              .map((x) => {
                const ch = fmtChange(x.value, x.prev, false);
                return { name: x.name, value: x.value, status: x.status, valueText: `${s.fmt(x.value)}${ch !== "-" ? ` · ${ch}` : ""}` };
              });
            return items.length >= 2 ? <StatusBars items={items} n={8} onBarClick={c.open} unitLabel={s.priced ? "$" : "credits"} ariaLabel="AI functions spend by user" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={pt} title="Provisioned throughputs" subtitle="paid days and the days nothing called the model · spend is context, idle $ is possible waste · click a row">
        {(rows, c) => {
          const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
          const list = [...rows].sort((a, b) => numOrZero(b.idle_day_pct) - numOrZero(a.idle_day_pct) || s.val(b) - s.val(a));
          return (
            <DrillTable aria="Provisioned throughputs" n={10}
              cols={[{ label: "Throughput" }, { label: "Paid days", num: true, width: "auto" }, { label: "Idle", width: "minmax(80px, auto)" }, { label: s.priced ? "Spend" : "Credits", num: true, width: "auto" }, { label: "Idle $", num: true, width: "auto" }]}
              rows={list.map((r) => ({
                key: `${r.account_id}|${r.throughput_name}`, status: r.status,
                onOpen: () => DrawerBus.open({ id: "sf_ai_provisioned_throughput_use", col: "throughput_name", val: String(r.throughput_name), label: String(r.throughput_name) }),
                cells: [String(r.throughput_name || "(unnamed)"), fmtInt(r.paid_days), dtChip(`${fmtInt(r.idle_days)} of ${fmtInt(r.paid_days)} d idle`, numOrZero(r.idle_days) > 0 ? r.status : "OK"),
                  s.fmt(s.val(r)), s.priced && r.est_idle_usd_list != null && isFlagged(r) ? fmtMoney(numOrZero(r.est_idle_usd_list) * (1 - c.disc), 0) : "–"],
              }))} />
          );
        }}
      </Slot>
      <Row2>
        <Slot c={search} title="Cortex Search spend by service" subtitle="serving and other credits · change vs the period before · spend, not waste">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
            const items: StatusBarItem[] = rows.filter((r) => s.val(r) > 0).map((r) => {
              const ch = r.change_pct === null || r.change_pct === undefined ? null : `${numOrZero(r.change_pct) >= 0 ? "+" : "−"}${fmtShare(Math.abs(numOrZero(r.change_pct)))}`;
              const serving = pctOf(numOrZero(r.serving_credits), numOrZero(r.current_credits));
              return {
                key: `${r.account_id}|${r.service_id ?? r.service_name}`, name: nameId(r.service_name, r.service_id, "(unnamed service)"), value: s.val(r), status: r.status,
                valueText: [s.priced ? fmtMoney(s.val(r), 0) : fmtCreditsFine(numOrZero(r.current_credits)), serving === null ? null : `${fmtShare(serving)} serving`, ch].filter(Boolean).join(" · "),
              };
            });
            return <StatusBars items={items} n={8} onBarClick={c.open} unitLabel={s.priced ? "$" : "credits"} ariaLabel="Cortex Search spend by service"
              emptyText={`No Cortex Search spend in ${w || "this window"}.`} />;
          }}
        </Slot>
        <Slot c={stale} title="Search indexes that stopped taking rows" subtitle="days since the index last embedded new rows · serving bills meanwhile · $ is spend">
          {(rows, c) => {
            const priced = isPriced(rows);
            const items: StatusBarItem[] = rows.map((r) => ({
              key: `${r.account_id}|${r.service_id}`, name: nameId(r.service_full_name, r.service_id), value: numOrZero(r.days_without_new_rows), status: r.status,
              valueText: `${fmtInt(r.days_without_new_rows)} d · ${priced ? fmtMoney(numOrZero(r.est_serving_usd_list) * (1 - c.disc), 0) : fmtCreditsShort(numOrZero(r.serving_credits))} serving`,
            }));
            return items.length ? <StatusBars items={items} n={6} unitLabel="days" onBarClick={c.open} ariaLabel="Days since each search index took new rows" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={fail} title="AI credits on failed statements" subtitle="tokens bill even when the statement fails or is cancelled · $ is possible waste · click a row">
        {(rows, c) => {
          const priced = isPriced(rows);
          const items: StatusBarItem[] = rows.filter((r) => numOrZero(r.failed_credits) > 0).map((r) => {
            const cause = [["cancelled", "cancelled_credits"], ["timed out", "timed_out_credits"], ["error", "error_credits"]]
              .sort((a, b) => numOrZero(r[b[1]]) - numOrZero(r[a[1]]))[0][0];
            const usd = numOrZero(r.est_wasted_usd_list) * (1 - c.disc);
            return {
              key: `${r.account_id}|${r.user_name}|${r.warehouse_id}|${r.function_name}|${r.model_name}`,
              name: `${r.function_name} ${r.model_name && r.model_name !== "(none)" ? r.model_name : ""} · ${r.user_name}`.replace(/\s+·/, " ·"),
              value: numOrZero(r.failed_credits), status: r.status, user: r.user_name,
              valueText: [priced && isFlagged(r) ? fmtMoney(usd, 0) : fmtCreditsShort(numOrZero(r.failed_credits)), cause,
                `${fmtInt(r.failed_queries)} of ${fmtInt(r.ai_queries)} statements`].join(" · "),
            };
          });
          return items.length ? <StatusBars items={items} n={8} unitLabel="credits" ariaLabel="AI credits on failed statements"
            onBarClick={(it) => DrawerBus.open({ id: "sf_ai_credits_on_failed_queries", col: "user_name", val: String(it.user), label: it.name })} /> : null;
        }}
      </Slot>
      <CortexAgentsPanel {...p} />
      <Slot c={access} title="Who can call Cortex" subtitle="Snowflake grants AI to PUBLIC by default · red or amber: every user can call it">
        {(rows) => (
          <DrillTable aria="Ways into Cortex AI functions" n={3}
            cols={[{ label: "Way in" }, { label: "PUBLIC", width: "minmax(80px, auto)" }, { label: "Other roles", num: true, width: "auto" }]}
            rows={rows.map((r) => ({
              key: `${r.account_id}|${r.access_path}`, status: r.status,
              cells: [String(r.access_label || r.access_path),
                r.status === "NOT_ASSESSED" ? "– not listed"
                  : r.access_path === "models_allowlist" ? dtChip(`models: ${r.setting_value}`, r.status)
                  : dtChip(r.open_to_public ? `holds it${r.public_granted_on ? ` since ${fmtDayShort(r.public_granted_on)}` : ""}` : "revoked", r.status),
                r.other_roles == null ? "–" : fmtInt(r.other_roles)],
            }))} />
        )}
      </Slot>
    </div>
  );
}

/** Two 100% bars of credits by feature: now (with the hatched part no feature explains) and before. */
function FeatureSplit({ rows, total }: { rows: Row[]; total: Row | null }) {
  const feats = rows.filter((r) => r.row_kind === "feature");
  const prov = rows.find((r) => r.row_kind === "provisioned");
  if (!feats.length) return null;
  const palette = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)", "var(--c5)", "var(--seq-3)"];
  const order = [...feats].sort((a, b) => numOrZero(b.current_credits) - numOrZero(a.current_credits));
  const colorOf = new Map(order.map((r, i) => [String(r.feature), palette[i % palette.length]]));
  const seg = (r: Row, col: string, withChange: boolean): ShareSegment => {
    const ch = withChange ? fmtChange(numOrZero(r.current_credits), numOrZero(r.previous_credits), false) : "-";
    return { key: String(r.feature), label: `${r.feature}${ch !== "-" ? ` ${ch}` : ""}`, value: numOrZero(r[col]), color: colorOf.get(String(r.feature)) };
  };
  const now = order.map((r) => seg(r, "current_credits", true));
  // provisioned throughput that fits in the bill's gap is part of the billed total
  const ptuInBill = total ? numOrZero(total.ptu_in_bill_credits) : 0;
  if (ptuInBill > 0) now.push({ key: "__ptu", label: "Provisioned throughput", value: ptuInBill, color: "var(--seq-2)" });
  const unexplained = total ? numOrZero(total.unexplained_credits) : 0;
  if (unexplained > 0) now.push({ key: "__gap", label: "No feature explains", value: unexplained, unknown: true });
  const before = order.map((r) => seg(r, "previous_credits", false));
  const sum = (s: ShareSegment[]) => s.reduce((a, x) => a + x.value, 0);
  // Rows can all be zero (only the billed-total row, still settling): say so rather than draw an empty bar.
  if (sum(now) <= 0 && sum(before) <= 0) {
    return <div className="chart-note-oneline">No Cortex feature spend in this window yet; the billed AI total settles about 2 days after the day.</div>;
  }
  return (
    <div className="ais-stack-pair">
      <StackedShareBar segments={now} valueFmt={fmtCreditsShort} maxSegments={6}
        totalLabel={`This period · ${fmtCreditsShort(sum(now))}${total ? " billed" : ""}`} ariaLabel="AI credits by feature, this period" />
      {sum(before) > 0 && (
        <StackedShareBar segments={before} valueFmt={fmtCreditsShort} maxSegments={6} height={14}
          totalLabel={`Period before · ${fmtCreditsShort(sum(before))} (features only)`} ariaLabel="AI credits by feature, the period before" />
      )}
      {prov && numOrZero(prov.current_credits) - ptuInBill > 0.005 && (
        <div className="chart-note-oneline">{`Provisioned throughput outside the AI bill: ${fmtCreditsShort(numOrZero(prov.current_credits) - ptuInBill)}.`}</div>
      )}
    </div>
  );
}

// ═══════════════════════ AI & apps > Containers, apps & code ═══════════════════════

// The causes in sf_obj_udfs_procedures.reasons, as one word each (the free text names objects).
function codeCause(text: string): string {
  const t = text.toLowerCase();
  if (/out of support/.test(t)) return "Runtime out of support";
  if (/nearing end of support/.test(t)) return "Runtime nearing end of support";
  if (/network/.test(t)) return "Can reach the network";
  if (/owned by/.test(t)) return "Owned by an admin role";
  if (/no call/.test(t)) return "Not called in the window";
  return text.trim();
}
function codeCauses(r: Row): string {
  return [...new Set(String(r.reasons || "").split(";").map((x) => x.trim()).filter(Boolean).map(codeCause))].join(";");
}

export function ApAiApps(p: ApPageProps) {
  const idle = useCheck(p, "sf_ai_spcs_pool_no_live_service");
  const pools = useCheck(p, "sf_ai_snowpark_container_services");
  const code = useCheck(p, "sf_obj_udfs_procedures");
  const nb = useCheck(p, "sf_ai_notebook_runtime_by_notebook");
  const apps = useCheck(p, "sf_cost_native_app_spend");
  const ingress = useCheck(p, "sf_ai_spcs_public_endpoints");
  const spark = useServiceDays(p, /SNOWPARK_CONTAINER/i, "sum").spark;
  const w = useWindowLabel(p);
  // Always on: up in every hour of the window.
  const alwaysOn = (r: Row) => numOrZero(r.always_on_pct) >= 99.5;
  const poolS = pools.rows ? spendOf(pools.rows, pools.disc, "est_current_usd_list", "current_credits") : null;
  const poolCur = pools.rows && poolS ? pools.rows.reduce((a, r) => a + poolS.val(r), 0) : 0;
  const idleFlag = (idle.rows || []).filter(isFlagged);
  const codeFlag = (code.rows || []).filter(isFlagged);
  useLede(p, pools.loading || idle.loading, pools.rows && poolS && poolCur > 0
    ? `Compute pools cost ${poolS.fmt(poolCur)} in ${w || "the window"}${idle.rows ? `; ${fmtInt(idleFlag.length)} of ${fmtInt(idle.rows.length)} billed with nothing running on them` : ""}.${code.rows ? ` ${fmtInt(codeFlag.length)} of ${fmtInt(code.rows.length)} functions and procedures are flagged.` : ""}`
    : null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <CheckTile c={pools} label="Compute pool spend" build={(rows, c) => {
          const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
          const prev = rows.reduce((a, r) => a + (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits)), 0);
          const ch = fmtChange(poolCur, prev, false);
          return {
            headline: s.fmt(poolCur), pill: <KindChip>Context</KindChip>, status: "neutral",
            base: `${fmtInt(rows.filter((r) => s.val(r) > 0).length)} of ${fmtInt(rows.length)} compute pools billed${ch !== "-" ? ` · ${ch} vs before` : ""}`,
            cause: <span className="ais-spark-cause"><SummaryTileSpark points={spark} /><span>Spend, not waste.</span></span>,
          };
        }} />
        <MoneyTile c={idle} label="Pools with no live service" cause={(rows) => {
          const top = [...rows].filter(isFlagged).sort((a, b) => numOrZero(b.est_wasted_usd_list) - numOrZero(a.est_wasted_usd_list))[0];
          return top ? `${nameId(top.compute_pool_name, top.compute_pool_id)} · ${fmtInt(top.idle_hours)} idle h` : "Every billed pool ran a service";
        }} />
        <CheckTile c={pools} label="Always-on pools" badge build={(rows, c) => {
          const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
          const total = rows.reduce((a, r) => a + s.val(r), 0);
          const on = rows.filter(alwaysOn);
          const top = [...on].sort((a, b) => s.val(b) - s.val(a))[0];
          return {
            headline: fmtShare(pctOf(on.reduce((a, r) => a + s.val(r), 0), total) ?? 0), unit: "of pool spend",
            flagged: on.length, population: rows.length, noun: "pools",
            status: on.length ? statusWord(on) : "ok",
            cause: top ? `${nameId(top.compute_pool_name, top.compute_pool_id)} up ${fmtShare(numOrZero(top.always_on_pct))} of hours; nodes stay up between jobs.` : "No pool is up every hour.",
          };
        }} />
        <CheckTile c={code} label="Functions & procedures at risk" build={(rows) => {
          const flagged = rows.filter(isFlagged);
          const counts = new Map<string, number>();
          flagged.forEach((r) => codeCauses(r).split(";").filter(Boolean).forEach((k) => counts.set(k, (counts.get(k) || 0) + 1)));
          const top = [...counts.entries()].sort((a, b) => b[1] - a[1])[0];
          return {
            headline: fmtShare(pctOf(flagged.length, rows.length) ?? 0), unit: " flagged",
            flagged: flagged.length, population: rows.length, noun: "objects",
            cause: top ? `${top[0]}: ${fmtInt(top[1])}` : "None flagged",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={pools} title="Compute pools by spend" subtitle="colour: status · value: spend and share of hours up">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
            const items: StatusBarItem[] = rows.map((r) => ({
              name: String(r.compute_pool_name || "(no compute pool)"), value: s.val(r), status: r.status,
              valueText: `${s.fmt(s.val(r))} · up ${fmtShare(numOrZero(r.always_on_pct))}`,
            }));
            return items.length >= 2 ? <StatusBars items={items} n={8} onBarClick={c.open} ariaLabel="Compute pool spend" /> : null;
          }}
        </Slot>
        <Slot c={code} title="Why functions & procedures are flagged" subtitle="share of flagged objects per cause">
          {(rows, c) => {
            const flagged = rows.filter(isFlagged).map((r) => ({ ...r, cause: codeCauses(r) }));
            return flagged.length ? <CauseSplitBar rows={flagged} column="cause" noun="objects" labelFor={(x) => x} onCauseClick={() => c.open()} /> : null;
          }}
        </Slot>
      </Row2>
      <Row2>
        <Slot c={nb} title="Notebooks: hours billed per active day" subtitle="red or amber: a kernel left up">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
            const items: StatusBarItem[] = rows.map((r) => ({
              name: nameId(r.notebook_name, r.notebook_id, "(no notebook)"), value: numOrZero(r.hours_per_active_day), status: r.status,
              valueText: `${numOrZero(r.hours_per_active_day).toFixed(1)} h/day · ${s.fmt(s.val(r))}`,
            }));
            return items.length >= 2 ? <StatusBars items={items} n={8} max={24} onBarClick={c.open} ariaLabel="Notebook hours billed per active day" /> : null;
          }}
        </Slot>
        <Slot c={apps} title="Native apps by spend" subtitle="value: spend and change vs the period before">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
            const prevOf = (r: Row) => (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits));
            const items: StatusBarItem[] = groupBy(rows, (r) => String(r.app_name || "(no app)"), s.val, prevOf).filter((x) => x.value > 0).map((x) => {
              const ch = fmtChange(x.value, x.prev, false);
              return { name: x.name, value: x.value, status: x.status, valueText: `${s.fmt(x.value)}${ch !== "-" ? ` · ${ch}` : ""}` };
            });
            return items.length >= 2 ? <StatusBars items={items} n={8} onBarClick={c.open} ariaLabel="Native app spend" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={ingress} title="Services that can take internet traffic" subtitle="the owner role holds BIND SERVICE ENDPOINT · confirm with SHOW ENDPOINTS IN SERVICE">
        {(rows) => {
          const acct = rows.find((r) => r.row_kind === "account");
          const rank = (r: Row) => (r.status === "CRITICAL" ? 0 : r.status === "WARN" ? 1 : r.status === "NOT_ASSESSED" ? 2 : 3);
          const svc = rows.filter((r) => r.row_kind === "service").sort((a, b) => rank(a) - rank(b));
          const pub = !acct ? null : acct.status === "NOT_ASSESSED" ? "PUBLIC: – the role can't see the grant"
            : acct.owner_can_bind ? "PUBLIC holds BIND SERVICE ENDPOINT: every service owner can open a public endpoint."
            : `PUBLIC does not hold it${acct.public_revoked_on ? ` (revoked ${fmtDayShort(acct.public_revoked_on)})` : ""}; ${fmtInt(acct.other_roles)} other roles do.`;
          return (
            <div className="ais-stack-pair">
              {pub && <div className="chart-note-oneline">{pub}</div>}
              {svc.length > 0 && (
                <DrillTable aria="Container services that can take internet traffic" n={8}
                  cols={[{ label: "Service" }, { label: "Owner" }, { label: "State", width: "minmax(80px, auto)" }, { label: "Public endpoint", width: "minmax(80px, auto)" }]}
                  rows={svc.map((r) => ({
                    key: `${r.account_id}|${r.service_id}`, status: r.status,
                    cells: [String(r.service_full_name), String(r.service_owner || "–"),
                      r.is_running ? "running" : r.reachable ? "resumes on request" : "suspended",
                      r.status === "NOT_ASSESSED" ? "– not known" : dtChip(r.owner_can_bind ? `can open (via ${r.bind_via})` : "cannot", r.status)],
                  }))} />
              )}
            </div>
          );
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ AI & apps > Model serving ═══════════════════════

const SERVING_KINDS = [
  { key: "SERVICE", label: "Container service", color: "var(--c1)" },
  { key: "JOB", label: "Container job", color: "var(--c2)" },
  { key: "WAREHOUSE", label: "Warehouse", color: "var(--c3)" },
];
const servingKind = (r: Row) => (String(r.invocation_type || "").toUpperCase() === "WAREHOUSE" ? "WAREHOUSE" : String(r.workload_type || "").toUpperCase() === "JOB" ? "JOB" : "SERVICE");
const modelName = (r: Row) => nameId([r.model_name, r.model_version_name].filter(Boolean).join(" ") || "(no model)", r.model_version_id);

export function ApAiServing(p: ApPageProps) {
  const sv = useCheck(p, "sf_ai_model_serving_spend");
  const w = useWindowLabel(p);
  const svRows = sv.rows || [];
  const svS = spendOf(svRows, sv.disc, "est_within_usd_list", "current_credits");
  const svCur = svRows.reduce((a, r) => a + svS.val(r), 0);
  const upAll = svRows.filter((r) => numOrZero(r.always_on_pct) >= 99.5);
  // Calls come from the service functions; a NULL means the export has no call count, never zero calls.
  const withCalls = svRows.filter((r) => r.invocations !== null && r.invocations !== undefined && r.invocations !== "");
  const winHours = numOrZero(p.filters.window) * 24;
  useLede(p, sv.loading, sv.rows && svCur > 0
    ? `Model serving cost ${svS.fmt(svCur)} in ${w || "the window"}, inside container and warehouse spend.${upAll.length ? ` ${fmtInt(upAll.length)} of ${fmtInt(svRows.length)} model versions are up every hour.` : ""}`
    : null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <MoneyTile c={sv} label="Model serving spend" badge={false} cause={(rows) => {
          const s = spendOf(rows, sv.disc, "est_within_usd_list", "current_credits");
          const cur = rows.reduce((a, r) => a + numOrZero(r.current_credits), 0);
          const prev = rows.reduce((a, r) => a + numOrZero(r.previous_credits), 0);
          const ch = fmtChange(cur, prev, false);
          return `inside container and warehouse spend${ch !== "-" ? ` · ${ch} vs before` : ""}${s.priced ? "" : " · credits"}`;
        }} />
        <CheckTile c={sv} label="Spend on always-up services" build={(rows, c) => {
          const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
          const total = rows.reduce((a, r) => a + s.val(r), 0);
          const flagged = rows.filter(isFlagged);
          const top = [...flagged].sort((a, b) => s.val(b) - s.val(a))[0];
          return {
            headline: fmtShare(pctOf(flagged.reduce((a, r) => a + s.val(r), 0), total) ?? 0), unit: " of serving spend",
            flagged: flagged.length, population: rows.length, noun: "model versions",
            cause: top ? `${modelName(top)} up ${fmtShare(numOrZero(top.always_on_pct))} of hours` : "No service is up all the time",
          };
        }} />
        <CheckTile c={sv} label="Endpoints with no calls" build={(rows) => {
          if (!withCalls.length) return { headline: null, missingReason: "Call counts are not in this export: run the export again." };
          const none = withCalls.filter((r) => numOrZero(r.invocations) === 0);
          return {
            headline: fmtInt(none.length), unit: `of ${fmtInt(withCalls.length)} endpoints`, pill: <KindChip>Context</KindChip>,
            base: none.slice(0, 2).map(modelName).join(" · ") || `0 idle · ${w || "in the window"}`,
            cause: rows.length > withCalls.length ? `${fmtInt(rows.length - withCalls.length)} more have no call count.` : undefined,
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={sv} title="Serving spend by model version" subtitle="colour: status · value: spend and share of hours up">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
            const items: StatusBarItem[] = groupBy(rows, modelName, s.val).filter((x) => x.value > 0).map((x) => {
              const r = rows.find((y) => modelName(y) === x.name)!;
              const up = r.always_on_pct === null || r.always_on_pct === undefined ? "on a warehouse" : `up ${fmtShare(numOrZero(r.always_on_pct))}`;
              return { name: x.name, value: x.value, status: x.status, valueText: `${s.fmt(x.value)} · ${up}` };
            });
            return items.length ? <StatusBars items={items} n={8} onBarClick={c.open} ariaLabel="Model serving spend by version" /> : null;
          }}
        </Slot>
        <Slot c={sv} title="Serving spend by how models run" subtitle="share of serving spend">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
            const segs: ShareSegment[] = SERVING_KINDS.map((k) => ({
              key: k.key, label: k.label, color: k.color, value: rows.filter((r) => servingKind(r) === k.key).reduce((a, r) => a + s.val(r), 0),
            }));
            return segs.filter((x) => x.value > 0).length >= 2 ? <StackedShareBar segments={segs} valueFmt={s.fmt} ariaLabel="Serving spend by how models run" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={sv} title="Endpoints · hours up" subtitle={`hours a service was up, of the ${fmtInt(winHours)} h in the window · calls and spend alongside · warehouse models have no service · click a row`}>
        {(rows, c) => {
          const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
          const list = [...rows].sort((a, b) => s.val(b) - s.val(a));
          return (
            <DrillTable aria="Model endpoints, hours up" n={10}
              cols={[{ label: "Model version" }, { label: "Runs on", width: "auto" }, { label: "Hours up", width: "minmax(70px, 1.4fr)" }, { label: "", num: true, width: "auto" }, { label: "Calls", num: true, width: "auto" }, { label: s.priced ? "Spend" : "Credits", num: true, width: "auto" }]}
              rows={list.map((r) => {
                const kind = servingKind(r);
                const onWh = kind === "WAREHOUSE";
                return {
                  key: `${r.account_id}|${r.model_version_id ?? modelName(r)}|${r.service_id ?? ""}`, status: r.status,
                  onOpen: () => DrawerBus.open({ id: "sf_ai_model_serving_spend", col: "model_version_id", val: r.model_version_id != null ? String(r.model_version_id) : null, label: modelName(r) }),
                  cells: [modelName(r), (SERVING_KINDS.find((k) => k.key === kind) || SERVING_KINDS[0]).label.toLowerCase(),
                    <MiniBar key="b" value={onWh ? winHours : numOrZero(r.active_hours)} max={winHours} hatched={onWh} />,
                    onWh ? "–" : `${fmtInt(r.active_hours)} h`,
                    r.invocations == null || r.invocations === "" ? "–" : fmtInt(r.invocations), s.fmt(s.val(r))],
                };
              })} />
          );
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Storage > Growth & stages ═══════════════════════

export function ApStorageGrowth(p: ApPageProps) {
  const gr = useCheck(p, "sf_storage_growth_by_database");
  const stage = useCheck(p, "sf_storage_stage_bytes");
  const stale = useCheck(p, "sf_storage_stale_stage_files");
  const arch = useCheck(p, "sf_storage_archive_retrieval");
  const types = useAggCheck(p, "table_inventory_type", ["table_type"], "table_count", ["table_bytes"]);
  const gStart = sumCol(gr.rows || [], "start_bytes"), gEnd = sumCol(gr.rows || [], "end_bytes");
  const staleN = (stale.rows || []).filter(isFlagged).length;
  useLede(p, gr.loading || stale.loading, gr.rows && gStart > 0
    ? `${fmtSize(gbOf(gEnd))} of storage, ${signedShare(pctOf(gEnd - gStart, gStart))} in the window.${stale.rows ? ` ${fmtInt(staleN)} of ${fmtInt(stale.rows.length)} stages hold files nobody cleaned up.` : ""}`
    : null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <CheckTile c={gr} label="Storage growth" build={(rows, c) => {
          const start = rows.reduce((a, r) => a + numOrZero(r.start_bytes), 0);
          const end = rows.reduce((a, r) => a + numOrZero(r.end_bytes), 0);
          const added = rows.reduce((a, r) => a + numOrZero(r.projected_added_usd_month), 0) * (1 - c.disc);
          const top = [...rows].sort((a, b) => numOrZero(b.growth_bytes) - numOrZero(a.growth_bytes))[0];
          const priced = isPriced(rows);
          return {
            headline: signedShare(pctOf(end - start, start)), unit: " in the window", status: statusWord(rows),
            base: `${fmtSize(gbOf(start))} → ${fmtSize(gbOf(end))} · ${fmtInt(rows.filter(isFlagged).length)} of ${fmtInt(rows.length)} databases flagged`,
            trend: priced && added > 0 ? { text: `+${fmtMoney(added, 0)}/mo in 30 d`, direction: "up", tone: rows.some((r) => r.status === "CRITICAL") ? "bad" : "neutral" } : null,
            cause: top && numOrZero(top.growth_bytes) > 0 ? `${nameId(top.database_name, top.database_id)} +${fmtSize(gbOf(top.growth_bytes))}` : "No database grew",
          };
        }} />
        <CheckTile c={stage} label="Internal stages" build={(rows, c) => {
          const sum = (col: string) => rows.reduce((a, r) => a + numOrZero(r[col]), 0);
          const usd = sum("est_storage_usd_month") * (1 - c.disc);
          return {
            headline: fmtSize(sum("end_stage_gb")), unit: ` · ${fmtShare(pctOf(sum("end_stage_bytes"), sum("end_total_bytes")))} of storage`, pill: <KindChip>Context</KindChip>,
            base: [isPriced(rows) ? `${fmtMoney(usd, 0)}/mo storage` : null, `${fmtInt(sum("stale_named_stages"))} of ${fmtInt(sum("internal_named_stages"))} named stages stale`].filter(Boolean).join(" · "),
            cause: "Stage files bill like tables but never show in a schema.",
          };
        }} />
        <MoneyTile c={stale} label="Stale stage files" cause={(rows) => {
          const top = [...rows].filter(isFlagged).sort((a, b) => numOrZero(b.stage_gb) - numOrZero(a.stage_gb))[0];
          return top ? `${nameId(top.stage_full_name, top.stage_id, "(unnamed stage)")} · ${fmtSize(numOrZero(top.stage_gb))} · ${top.finding}` : "No stale stage";
        }} />
        <CheckTile c={arch} label="Pulled back from archive" build={(rows) => {
          const objs = rows.filter((r) => r.row_kind === "object");
          const list = objs.length ? objs : rows;
          const gb = list.reduce((a, r) => a + numOrZero(r.gb_retrieved), 0);
          const top = [...list].sort((a, b) => numOrZero(b.gb_retrieved) - numOrZero(a.gb_retrieved))[0];
          return {
            headline: fmtSize(gb), flagged: list.filter(isFlagged).length, population: list.length, noun: "objects",
            cause: top && numOrZero(top.gb_retrieved) > 0 ? `${[top.database_name, top.schema_name, top.object_name].filter(Boolean).join(".")} · ${fmtSize(numOrZero(top.gb_retrieved))}` : "Nothing pulled back",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={gr} title="Growth by database" subtitle="% added in the window · projected $/mo added in 30 days">
          {(rows, c) => {
            const items: StatusBarItem[] = rows.filter((r) => numOrZero(r.growth_bytes) > 0).map((r) => {
              const add = numOrZero(r.projected_added_usd_month) * (1 - c.disc);
              const pct = pctOf(numOrZero(r.growth_bytes), numOrZero(r.start_bytes));
              return {
                name: `${nameId(r.database_name, r.database_id, "(unnamed database)")}${r.dropped_at ? " - dropped" : ""}`,
                value: pct ?? 0, status: r.status,
                valueText: `${signedShare(pct)}${isPriced([r]) && add > 0 ? ` · +${fmtMoney(add, 0)}/mo` : ""}`,
              };
            });
            return items.length ? <StatusBars items={items} n={8} onBarClick={c.open} ariaLabel="Storage growth by database" emptyText="No database grew in this window." /> : null;
          }}
        </Slot>
        <Slot c={stale} title="Stage files by size" subtitle="colour: status · value: size and why">
          {(rows, c) => {
            const items: StatusBarItem[] = rows.filter((r) => numOrZero(r.stage_gb) > 0).map((r) => ({
              name: nameId(r.stage_full_name, r.stage_id, "(unnamed stage)"), value: numOrZero(r.stage_gb), status: r.status,
              valueText: `${fmtSize(numOrZero(r.stage_gb))} · ${r.finding === "ok" ? "in use" : String(r.finding || "").replace(/_/g, " ")}${r.newest_file_age_days != null ? ` · ${fmtInt(r.newest_file_age_days)} d` : ""}`,
            }));
            return items.length >= 2 ? <StatusBars items={items} n={8} onBarClick={c.open} ariaLabel="Stage size" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={types} title="Tables by type" subtitle="share of objects · size where Snowflake keeps one (views hold no bytes: –) · snapshot at export">
        {(rows) => {
          const list = rows.map((g) => {
            const bytes = g.also ? g.also.table_bytes : null;
            return { type: String((g.key || [])[0] || "(no type)"), n: numOrZero(g.value), bytes: bytes === null || bytes === undefined ? null : Number(bytes) };
          }).filter((x) => x.n > 0).sort((a, b) => b.n - a.n);
          const total = list.reduce((a, x) => a + x.n, 0);
          const palette = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)", "var(--c5)", "var(--seq-3)"];
          const segs: ShareSegment[] = list.map((x, i) => ({ key: x.type, label: x.type.toLowerCase(), value: x.n, color: palette[i % palette.length] }));
          return (
            <div className="ais-stack-pair">
              <StackedShareBar segments={segs} valueFmt={(v) => fmtInt(v)} totalLabel={`${fmtInt(total)} tables and views`} ariaLabel="Tables and views by type" />
              <DrillTable aria="Tables by type" n={8}
                cols={[{ label: "Type" }, { label: "Objects", num: true, width: "auto" }, { label: "Share", num: true, width: "auto" }, { label: "Size", num: true, width: "auto" }]}
                rows={list.map((x) => ({ key: x.type, cells: [x.type.toLowerCase(), fmtInt(x.n), fmtShare(pctOf(x.n, total)), x.bytes === null ? "–" : fmtSize(gbOf(x.bytes))] }))} />
            </div>
          );
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Storage > Unused & sprawl ═══════════════════════

export function ApStorageUnused(p: ApPageProps) {
  const unused = useCheck(p, "sf_storage_unused_tables");
  const sprawl = useCheck(p, "sf_storage_schema_sprawl");
  const clones = useCheck(p, "sf_use_unused_clones");
  const dropped = useCheck(p, "sf_storage_dropped_not_purged");
  // Homed on Time Travel & Fail-safe; shown here because rewritten-but-unread is unused storage too.
  const churn = useCheck(p, "sf_storage_churn_unread");
  const oldest = useCheck(p, "sf_storage_oldest_untouched_tables");
  const [writeView, setWriteView] = React.useState<"written" | "idle">("written");
  const w = useWindowLabel(p);
  const asOf = p.meta && p.meta.as_of_date ? String(p.meta.as_of_date).slice(0, 10) : null;
  const monthOf = (c: Chk) => (c.rows ? tileMoney(c.f) : null);
  const parts = [[unused, "in tables never read"], [churn, "in tables rewritten but never read"], [dropped, "in dropped tables still billed"]] as [Chk, string][];
  const said = parts.map(([c, w]) => { const v = monthOf(c); return v ? `${v}/mo ${w}` : null; }).filter(Boolean);
  useLede(p, unused.loading || churn.loading || dropped.loading, said.length ? `Storage nobody reads: ${said.join(", ")}. Per month, kept apart from compute waste.` : null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <MoneyTile c={unused} label="Tables nobody has read · per month" cause={(rows) => {
          const top = [...rows].filter(isFlagged).sort((a, b) => numOrZero(b.total_gb) - numOrZero(a.total_gb))[0];
          return top ? `${nameId(top.table_fqn, top.table_id)} · ${fmtSize(numOrZero(top.total_gb))}` : "Every table was read";
        }} />
        <MoneyTile c={{ ...churn, open: () => p.goTo({ tab: p.area, subtab: "retention", focusQueryId: "sf_storage_churn_unread" }) }} label="Rewritten but never read · per month" cause={(rows) => {
          const fl = rows.filter(isFlagged);
          return fl.length ? `${fmtSize(sumCol(fl, "time_travel_gb") + sumCol(fl, "failsafe_gb"))} of history kept for tables nobody reads` : "None flagged";
        }} />
        <MoneyTile c={dropped} label="Dropped, still billed · per month" cause={(rows) => {
          const next = rows.map((r) => (r.purge_by ? String(r.purge_by).slice(0, 10) : null)).filter((d): d is string => !!d && (!asOf || d >= asOf)).sort()[0];
          return next ? `Nothing frees Fail-safe early; the next leaves the bill ${fmtDayShort(next)}.` : "Fail-safe end dates unknown";
        }} />
        <MoneyTile c={clones} label="Clones nobody reads · per month" cause={(rows) => {
          const gb = rows.filter(isFlagged).reduce((a, r) => a + numOrZero(r.own_gb) + numOrZero(r.retained_for_clone_gb), 0);
          return `${fmtSize(gb)} kept alive only by clones`;
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={unused} title="Unread tables by storage" subtitle="$ per month · colour: status">
          {(rows, c) => {
            const priced = isPriced(rows);
            // An export from before written_in_window has no such key: no toggle, all unread tables.
            const hasWrite = rows.some((r) => Object.prototype.hasOwnProperty.call(r, "written_in_window"));
            // NULL written_in_window is unknown: it sits in neither group.
            const inGroup = hasWrite ? rows.filter((r) => r.written_in_window === (writeView === "written")) : rows;
            const unknown = rows.filter((r) => r.written_in_window === null || r.written_in_window === undefined).length;
            const items: StatusBarItem[] = inGroup.map((r) => {
              const usd = numOrZero(r.est_storage_usd_month) * (1 - c.disc);
              return {
                name: nameId(r.table_fqn, r.table_id, "(unnamed table)"), value: priced ? usd : numOrZero(r.total_gb), status: r.status,
                valueText: priced ? `${fmtMoney(usd, 0)}/mo · ${fmtSize(numOrZero(r.total_gb))}` : fmtSize(numOrZero(r.total_gb)),
              };
            });
            return (
              <>
                {hasWrite && (
                  <div className="ais-grain-row">
                    <div className="ws-actions" role="group" aria-label="Written in the window or not">
                      <button type="button" className={writeView === "written" ? "on" : ""} onClick={() => setWriteView("written")}>Written but never read</button>
                      <button type="button" className={writeView === "idle" ? "on" : ""} onClick={() => setWriteView("idle")}>Neither read nor written</button>
                    </div>
                  </div>
                )}
                <StatusBars items={items} n={8} onBarClick={c.open} ariaLabel="Unread tables by storage"
                  emptyText={`None of the ${fmtInt(rows.length)} unread tables was ${writeView === "written" ? "written" : "left unwritten"} in ${w || "this window"}.`} />
                <div className="metric-note">{hasWrite
                  ? `${fmtInt(inGroup.length)} of ${fmtInt(rows.length)} unread tables${unknown ? ` · ${fmtInt(unknown)} with write history unknown read "–" and sit in neither group` : ""}.`
                  : "This export predates the written-or-not split; re-export to see it."}</div>
              </>
            );
          }}
        </Slot>
        <Slot c={sprawl} title="Unread share, flagged schemas" subtitle="bytes in tables nobody read">
          {(rows, c) => {
            const items = rows.filter(isFlagged).map((r) => ({
              key: String(r.schema_id ?? r.schema_fqn), name: nameId(r.schema_fqn, r.schema_id, "(unnamed schema)"),
              value: numOrZero(r.unread_bytes), total: numOrZero(r.total_bytes), status: r.status, onClick: c.open,
            }));
            return items.length ? <ShareBarList items={items} n={8} valueFmt={(v) => fmtSize(v / BIN)} /> : <div className="chart-note-oneline">No schema flagged.</div>;
          }}
        </Slot>
      </Row2>
      <Row2>
        <Slot c={dropped} title="When dropped tables leave the bill" subtitle="GB by the day their Fail-safe ends">
          {(rows, c) => {
            const ev = rows.filter((r) => r.purge_by && numOrZero(r.billed_gb) > 0)
              // A Fail-safe table keeps no name: it is named by its table id instead.
              .map((r) => ({ day: String(r.purge_by).slice(0, 10), kind: r.database_name && r.database_name !== "(unnamed)" ? nameId(r.database_name, r.database_id) : nameId(null, r.table_id, "(dropped, name not kept)"), value: numOrZero(r.billed_gb) }));
            if (!ev.length) return null;
            const days = ev.map((e) => e.day).sort();
            const first = asOf && asOf < days[0] ? asOf : days[0];
            const all: string[] = [];
            for (let t = Date.parse(`${first}T00:00:00Z`), end = Date.parse(`${days[days.length - 1]}T00:00:00Z`); t <= end && all.length < 120; t += 86400000) all.push(new Date(t).toISOString().slice(0, 10));
            return <DayKindTimeline rows={ev} days={all} valueFmt={fmtSize} unitLabel="" onDayClick={() => c.open()} ariaLabel="Dropped table storage by purge day" />;
          }}
        </Slot>
      </Row2>
      <Slot c={oldest} title="Oldest untouched tables" subtitle="live tables, longest unchanged first · $ is what each costs to keep a month, not a saving · click a row">
        {(all, c) => {
          // A table with no database name is internal or orphaned, never a live customer table: kept off the list.
          const rows = all.filter((r) => r.database_name != null && r.database_name !== "");
          const noDb = all.length - rows.length;
          const priced = isPriced(rows);
          const usdNum = (r: Row) => (r.price_basis !== "unpriced" && r.est_storage_usd_month != null ? numOrZero(r.est_storage_usd_month) * (1 - c.disc) : null);
          const usdOf = (r: Row) => { const v = usdNum(r); return v == null ? "–" : fmtMoney(v, 0); };
          const word: Record<string, string> = { CRITICAL: "critical", WARN: "unchanged too long", OK: "ok", NOT_ASSESSED: "–" };
          const day = (v: any) => (v ? fmtDayShort(v) : "–");
          return (
            <div className="ais-oldest">
            <DrillTable aria="Oldest untouched tables" n={10} empty="No live table with a database name in this export."
              cols={[{ label: "Table" }, { label: "Database", width: "minmax(64px, 1fr)" }, { label: "Schema", width: "minmax(64px, 1fr)" }, { label: "Type", width: "auto" },
                { label: "Created", width: "auto" }, { label: "Last changed", width: "auto" }, { label: "Unchanged", num: true, width: "auto" }, { label: "Size", num: true, width: "auto" },
                { label: "$/mo", num: true, width: "auto" }, { label: "", width: "minmax(64px, auto)" }]}
              rows={rows.map((r) => ({
                key: `${r.account_id}|${r.table_id}`, status: r.status,
                onOpen: () => DrawerBus.open({ id: "sf_storage_oldest_untouched_tables", col: "table_id", val: String(r.table_id), label: nameId(r.table_name, r.table_id) }),
                cells: [nameId(r.table_name, r.table_id, "(unnamed table)"), nameId(r.database_name, r.database_id, "–"), nameId(r.schema_name, r.schema_id, "–"), String(r.table_type || "–").toLowerCase(),
                  day(r.created), day(r.last_altered), r.days_since_altered == null ? "–" : `${fmtInt(r.days_since_altered)} d`, r.total_gb == null ? "–" : fmtSize(numOrZero(r.total_gb)),
                  usdOf(r), dtChip(word[String(r.status)] || String(r.status || "–").toLowerCase(), r.status)],
              }))}
              more={<CsvButton fileName="oldest-untouched-tables" rows={rows} columns={[
                { label: "table", value: (r: Row) => nameId(r.table_name, r.table_id) }, { label: "database", value: (r: Row) => r.database_name }, { label: "schema", value: (r: Row) => r.schema_name },
                { label: "type", value: (r: Row) => r.table_type }, { label: "created", value: (r: Row) => r.created }, { label: "last_altered", value: (r: Row) => r.last_altered },
                { label: "days_since_altered", value: (r: Row) => r.days_since_altered }, { label: "total_gb", value: (r: Row) => r.total_gb },
                // The same discounted $ the table shows.
                { label: priced ? "est_storage_usd_month" : "est_storage_usd_month (unpriced)", value: (r: Row) => usdNum(r) },
                { label: "status", value: (r: Row) => r.status },
              ]} />} />
            {noDb > 0 && <div className="metric-note">{`${fmtInt(noDb)} of ${fmtInt(all.length)} tables have no database name (internal or orphaned) and are left out.`}</div>}
            </div>
          );
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Storage > Time Travel & Fail-safe ═══════════════════════

export function ApStorageRetention(p: ApPageProps) {
  const tt = useCheck(p, "sf_storage_time_travel_heavy");
  const pol = useCheck(p, "sf_storage_retention_policy");
  const stg = useCheck(p, "sf_storage_failsafe_on_staging");
  const heavy = useCheck(p, "sf_use_table_churn");
  const slp = useCheck(p, "sf_storage_lifecycle_policy_failures");
  const sums = (rows: Row[]) => ({
    a: rows.reduce((s, r) => s + numOrZero(r.active_bytes), 0),
    t: rows.reduce((s, r) => s + numOrZero(r.time_travel_bytes), 0),
    f: rows.reduce((s, r) => s + numOrZero(r.failsafe_bytes), 0),
  });
  const ts = sums(tt.rows || []);
  useLede(p, tt.loading, tt.rows && ts.a + ts.t + ts.f > 0
    ? `${fmtShare(pctOf(ts.t + ts.f, ts.a + ts.t + ts.f))} of the bytes on ${fmtInt(tt.rows.length)} tables are history: ${fmtSize(gbOf(ts.t))} of Time Travel and ${fmtSize(gbOf(ts.f))} of Fail-safe against ${fmtSize(gbOf(ts.a))} of live data.`
    : null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <CheckTile c={tt} label="History share" build={(rows) => {
          const s = sums(rows);
          return {
            headline: fmtShare(pctOf(s.t + s.f, s.a + s.t + s.f)), unit: " of bytes are history",
            flagged: rows.filter(isFlagged).length, population: rows.length, noun: "tables flagged",
            cause: `Time Travel ${fmtSize(gbOf(s.t))} · Fail-safe ${fmtSize(gbOf(s.f))}`,
          };
        }} />
        <MoneyTile c={pol} label="Retention above policy" cause={(rows) => {
          const top = [...rows].sort((a, b) => numOrZero(b.over_policy_tt_bytes) - numOrZero(a.over_policy_tt_bytes))[0];
          return top && numOrZero(top.over_policy_tables) > 0
            ? `${nameId(top.database_name, top.database_id)}: ${fmtInt(top.over_policy_tables)} tables over ${fmtInt(top.max_retention_days)} d`
            : "No table above the policy";
        }} />
        <MoneyTile c={stg} label="Fail-safe on staging tables" cause={(rows) => {
          const gb = rows.filter(isFlagged).reduce((a, r) => a + numOrZero(r.failsafe_gb), 0);
          return `${fmtSize(gb)} in Fail-safe a transient table would not keep`;
        }} />
        <CheckTile c={heavy} label="Write-heavy tables · per month" badge build={(rows, c) => {
          const fl = rows.filter(isFlagged);
          const priced = isPriced(fl.length ? fl : rows);
          const usd = sumCol(fl, "est_history_usd_month") * (1 - c.disc);
          const top = [...fl].sort((a, b) => numOrZero(b.est_history_usd_month) - numOrZero(a.est_history_usd_month))[0];
          return {
            headline: priced ? fmtMoney(usd, 0) : fmtSize(sumCol(fl, "time_travel_gb") + sumCol(fl, "failsafe_gb")), unit: priced ? "/mo history storage" : "of history",
            base: `${fmtInt(fl.length)} of ${fmtInt(rows.length)} tables · ${fmtSize(sumCol(fl, "time_travel_gb") + sumCol(fl, "failsafe_gb"))} of history`,
            cause: top ? `${nameId([top.database_name, top.schema_name, top.table_name].filter(Boolean).join("."), top.table_id)} is most of it.` : "No table rewrites itself heavily.",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={tt} title="Active vs history, by database" subtitle="bytes on the tables listed · blue active, sand Time Travel + Fail-safe · dot = the database's worst status">
          {(rows) => {
            const s = sums(rows);
            const segs: ShareSegment[] = [
              { key: "a", label: "Active", value: gbOf(s.a), color: "var(--c1)" },
              { key: "t", label: "Time Travel", value: gbOf(s.t), color: "var(--c2)" },
              { key: "f", label: "Fail-safe", value: gbOf(s.f), color: "var(--c-other)" },
            ];
            const byDb = new Map<string, { rows: Row[]; a: number; h: number }>();
            rows.forEach((r) => {
              const k = nameId(r.database_name, r.database_id, "(unnamed database)");
              const cur = byDb.get(k) || { rows: [], a: 0, h: 0 };
              cur.rows.push(r); cur.a += numOrZero(r.active_bytes); cur.h += numOrZero(r.time_travel_bytes) + numOrZero(r.failsafe_bytes);
              byDb.set(k, cur);
            });
            const dbs = [...byDb.entries()].sort((x, y) => y[1].h - x[1].h);
            const max = Math.max(1, ...dbs.map(([, v]) => v.a + v.h));
            return (
              <div className="ais-stack-pair">
                {segs.filter((x) => x.value > 0).length >= 2 && <StackedShareBar segments={segs} valueFmt={fmtSize} totalLabel={`${fmtSize(gbOf(s.a + s.t + s.f))} on ${fmtInt(rows.length)} tables`} ariaLabel="Active, Time Travel and Fail-safe bytes" />}
                <DrillTable aria="Active vs history by database" n={8}
                  cols={[{ label: "Database" }, { label: "Active · history", width: "minmax(80px, 1.6fr)" }, { label: "History", num: true, width: "auto" }, { label: "Share", num: true, width: "auto" }]}
                  rows={dbs.map(([name, v]) => ({
                    key: name, status: v.rows.some((r) => r.status === "CRITICAL") ? "CRITICAL" : v.rows.some((r) => r.status === "WARN") ? "WARN" : "OK",
                    cells: [name, <SplitBar key="b" max={max} parts={[{ value: v.a, color: "var(--c1)" }, { value: v.h, color: "var(--c-other)" }]} />, fmtSize(gbOf(v.h)), fmtShare(pctOf(v.h, v.a + v.h))],
                  }))} />
              </div>
            );
          }}
        </Slot>
        <Slot c={pol} title="Time Travel days by database" subtitle="tables per retention band · red: above the account policy">
          {(rows, c) => <RetentionBands rows={rows} onOpen={c.open} />}
        </Slot>
      </Row2>
      <Slot c={stg} title="Permanent staging tables paying for Fail-safe" subtitle="bytes in Fail-safe a transient table would not keep · $ per month at your rate · dot = status">
        {(rows, c) => {
          const priced = isPriced(rows);
          const items: StatusBarItem[] = rows.filter((r) => numOrZero(r.failsafe_gb) > 0).map((r) => {
            // Only flagged rows carry a saving: the others read "not flagged", never $0.
            const usd = r.est_saving_usd_month == null ? null : numOrZero(r.est_saving_usd_month) * (1 - c.disc);
            return {
              key: `${r.account_id}|${r.table_id}`, name: nameId(r.table_fqn, r.table_id, "(unnamed table)"), value: priced ? (usd ?? 0) : numOrZero(r.failsafe_gb), status: r.status, tableId: r.table_id,
              valueText: priced ? `${usd != null ? `${fmtMoney(usd, 0)}/mo` : "– not flagged"} · ${fmtSize(numOrZero(r.failsafe_gb))}` : fmtSize(numOrZero(r.failsafe_gb)),
            };
          });
          return items.length ? <StatusBars items={items} n={8} ariaLabel="Staging tables paying for Fail-safe"
            onBarClick={(it) => DrawerBus.open({ id: "sf_storage_failsafe_on_staging", col: "table_id", val: String(it.tableId), label: it.name })} /> : null;
        }}
      </Slot>
      <Slot c={slp} title="Storage lifecycle policies" subtitle="daily expire and archive runs · a failed run keeps rows past their expiry · click a row">
        {(rows) => {
          const rank = (r: Row) => (r.status === "CRITICAL" ? 0 : r.status === "WARN" ? 1 : 2);
          const list = [...rows].sort((a, b) => rank(a) - rank(b) || numOrZero(b.failures_in_a_row) - numOrZero(a.failures_in_a_row));
          const word: Record<string, string> = { failing: "failing", not_running: "stopped running", no_runs: "never ran", recovered: "failed, recovered", ok: "runs clean" };
          return (
            <DrillTable aria="Storage lifecycle policies by table" n={8}
              cols={[{ label: "Policy" }, { label: "Table" }, { label: "Last run", width: "auto" }, { label: "Failed in a row", num: true, width: "auto" }, { label: "", width: "minmax(80px, auto)" }]}
              rows={list.map((r) => ({
                key: `${r.account_id}|${r.policy_full_name}|${r.table_full_name}`, status: r.status,
                onOpen: () => DrawerBus.open({ id: "sf_storage_lifecycle_policy_failures", col: "policy_full_name", val: String(r.policy_full_name), label: String(r.policy_full_name) }),
                cells: [String(r.policy_full_name), String(r.table_full_name), r.last_run_time ? fmtDayShort(r.last_run_time) : "–", fmtInt(r.failures_in_a_row),
                  dtChip(`${word[String(r.finding)] || String(r.finding)}${r.failed_tasks && r.finding !== "ok" ? ` · ${String(r.failed_tasks).toLowerCase()}` : ""}`, r.status)],
              }))} />
          );
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Storage > Backups ═══════════════════════

const BACKUP_KINDS = [
  { key: "none", label: "No policy: never expires", color: "var(--st-crit)" },
  { key: "snapshot", label: "Snapshot (deprecated)", color: "var(--st-warn)" },
  { key: "policy", label: "Expires by policy", color: "var(--c-other)" },
];
const backupKind = (r: Row) => (String(r.set_kind || "").toLowerCase() === "snapshot" ? "snapshot" : r.policy_name ? "policy" : "none");

export function ApStorageBackups(p: ApPageProps) {
  const bk = useCheck(p, "sf_storage_backup_snapshot");
  const bkRows = bk.rows || [];
  // A deleted set cannot grow, so it is not one that "never expires".
  const neverExpires = (r: Row) => backupKind(r) === "none" && !r.set_deleted;
  const never = bkRows.filter(neverExpires);
  const bkPriced = isPriced(bkRows);
  const neverUsd = sumCol(never, "est_storage_usd_month") * (1 - bk.disc);
  useLede(p, bk.loading, bk.rows && bkRows.length
    ? `${fmtInt(never.length)} of ${fmtInt(bkRows.length)} backup sets have nothing that expires them${never.length ? `, so they can grow to ${fmtSize(gbOf(sumCol(never, "retained_bytes_upper")))}${bkPriced ? ` and up to ${fmtMoney(neverUsd, 0)} a month` : ""}` : ""}.`
    : null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <CheckTile c={bk} label="Backup storage · per month" badge build={(rows, c) => {
          const usd = sumCol(rows, "est_storage_usd_month") * (1 - c.disc);
          const gb = gbOf(sumCol(rows, "retained_bytes_upper"));
          return {
            headline: isPriced(rows) ? `up to ${fmtMoney(usd, 0)}` : `up to ${fmtSize(gb)}`, unit: isPriced(rows) ? "/mo storage" : undefined,
            base: `at most · ${fmtInt(rows.length)} sets · ${fmtSize(gb)}`,
            cause: "An upper bound: a backup shares bytes with its table until the table changes.",
          };
        }} />
        <CheckTile c={bk} label="Sets that never expire" badge build={(rows) => {
          const none = rows.filter(neverExpires);
          const gb = none.reduce((a, r) => a + gbOf(r.retained_bytes_upper), 0);
          return {
            headline: fmtInt(none.length), unit: ` of ${fmtInt(rows.length)} sets`,
            cause: none.length ? `no backup policy expires them · up to ${fmtSize(gb)}` : "Every set has an expiring policy",
          };
        }} />
        <CheckTile c={bk} label="Deprecated snapshots" build={(rows) => {
          const snaps = rows.filter((r) => backupKind(r) === "snapshot");
          return {
            headline: fmtInt(snaps.length), unit: ` of ${fmtInt(rows.length)} sets`,
            cause: snaps.length ? `up to ${fmtSize(snaps.reduce((a, r) => a + gbOf(r.retained_bytes_upper), 0))} · move to backup sets` : "No snapshot sets",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={bk} title="Backup storage by set" subtitle="up to: the most each set may hold · colour: policy state">
          {(rows, c) => (
            <ColorBars kinds={BACKUP_KINDS} onBarClick={c.open} ariaLabel="Backup storage by set, upper bound"
              items={rows.map((r) => {
                const usd = numOrZero(r.est_storage_usd_month) * (1 - c.disc);
                const gb = gbOf(r.retained_bytes_upper);
                return {
                  key: String(r.set_id ?? r.set_name), name: `${nameId(r.set_name, r.set_id, "(unnamed backup set)")}${r.set_deleted ? " - deleted" : ""}`,
                  value: gb, kind: backupKind(r),
                  valueText: `up to ${fmtSize(gb)}${r.price_basis !== "unpriced" ? ` · ${fmtMoney(usd, 0)}/mo` : ""}`,
                };
              })} />
          )}
        </Slot>
        <Slot c={bk} title="What expires the backups" subtitle="upper-bound bytes by policy state · snapshot at export">
          {(rows) => {
            const segs: ShareSegment[] = BACKUP_KINDS.map((k) => {
              const of = rows.filter((r) => backupKind(r) === k.key);
              // Neutral series colours: the status sits on the pill and the table, never on the bar.
              const color = k.key === "none" ? "var(--c1)" : k.key === "policy" ? "var(--c3)" : "var(--c-other)";
              return { key: k.key, label: `${k.label} · ${fmtInt(of.length)} set${of.length === 1 ? "" : "s"}`, color, value: gbOf(sumCol(of, "retained_bytes_upper")) };
            });
            return segs.some((x) => x.value > 0) ? <StackedShareBar segments={segs} valueFmt={fmtSize} ariaLabel="Backup bytes by what expires them" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={bk} title="Backup sets" subtitle="what each set protects, how many backups it holds and what stops it growing · click a row">
        {(rows, c) => (
          <DrillTable aria="Backup sets" n={10}
            cols={[{ label: "Set" }, { label: "Protects", width: "minmax(80px, 1fr)" }, { label: "Expiry", width: "auto" }, { label: "Backups", num: true, width: "auto" }, { label: "Up to", num: true, width: "auto" }, { label: "$/mo", num: true, width: "auto" }]}
            rows={[...rows].sort((a, b) => numOrZero(b.retained_bytes_upper) - numOrZero(a.retained_bytes_upper)).map((r) => {
              const kind = backupKind(r);
              return {
                key: `${r.account_id}|${r.set_id ?? r.set_name}`, status: r.status,
                onOpen: () => DrawerBus.open({ id: "sf_storage_backup_snapshot", col: "set_name", val: String(r.set_name), label: nameId(r.set_name, r.set_id) }),
                cells: [`${nameId(r.set_name, r.set_id, "(unnamed backup set)")}${r.set_deleted ? " - deleted" : ""}`, String(r.object_name || "–"),
                  dtChip(kind === "none" ? "no policy" : kind === "snapshot" ? "snapshot" : String(r.policy_name), kind === "none" ? "CRITICAL" : kind === "snapshot" ? "WARN" : "OK"),
                  fmtInt(r.backups), fmtSize(gbOf(r.retained_bytes_upper)), r.price_basis !== "unpriced" ? fmtMoney(numOrZero(r.est_storage_usd_month) * (1 - c.disc), 0) : "–"],
              };
            })} />
        )}
      </Slot>
    </div>
  );
}

/** The sub-tab pages this file owns, by area and sub-tab key. They lead with their own tiles, so the
 * generic tile row and money charts below them are not needed (`ownsTiles`). */
export const AI_STORAGE_PAGES: Record<string, Record<string, (p: ApPageProps) => React.JSX.Element>> = {
  ai: { cortex: ApAiCortex, apps: ApAiApps, serving: ApAiServing },
  storage: { growth: ApStorageGrowth, unused: ApStorageUnused, retention: ApStorageRetention, backups: ApStorageBackups },
};
Object.values(AI_STORAGE_PAGES).forEach((m) => Object.values(m).forEach((fn) => { (fn as any).ownsTiles = true; (fn as any).ownsLede = true; }));
