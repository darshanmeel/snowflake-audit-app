// web/src/components/area_ai_storage.tsx -- the AI & apps and Storage sub-tab pages: issue tiles
// first (a % or flagged $, "N of M", the top cause, Open), then the charts that show the driver.
// Every figure is read off the checks' own rows; a check that did not run reads "–" and why.
import React from "react";
import "../styles/css/p_area_ai_storage.css";
import { fmtChange, fmtDayShort, fmtInt, fmtMoney, fmtMoneyOf } from "../format";
import { numOrZero, useFindingAgg, useFindingData } from "./hooks";
import { ChartCard, bandOf } from "./primitives";
import { MiniBar } from "./drill_table";
import { DrawerBus } from "./drawer";
import { notAssessedText } from "./scope";
import { SummaryTileRow, SummaryTileSpark, partialBarKeys, windowShortLabel } from "./overview_tile";
import { MultiLine } from "./charts";
import { Columns } from "./charts_more";
import { windowDayList } from "./run_blocks";
import { DAY_ROWS_MAX, GrainSwitch, fmtMonth, partialMonths, rollUpMonths } from "./grain";
import type { Grain } from "./grain";
import { CsvButton } from "./csv";
import {
  IssueTile, StackedShareBar, fmtShare, pctOf,
} from "./blocks";
import type { IssueTileProps, ShareSegment } from "./blocks";
import { MONEY_KIND_WORD, findingForId, moneyPeriodWord, upToWord, withoutTotalRows } from "../tabs/tab_area";
import { moneyKindOf } from "./waste_total";
import { CortexAgentsPanel, cortexProductCells, useCortexProducts } from "./ai_cortex_agents";
import { CxBars, CxDayStack, CxGridBars, cxMoney, CxKindsNote, CxName, CxRow2, CxSlot, CxStrip, CxTable } from "./cx_c";
import type { CxBarRow, CxStripCell } from "./cx_c";
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
const plural = (n: number, one: string, many?: string) => `${fmtInt(n)} ${n === 1 ? one : (many || `${one}s`)}`;
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
export function MoneyTile({ c, label, badge = true, cause, cur = false }: {
  c: Chk; label: string; badge?: boolean; cause?: (rows: Row[]) => React.ReactNode;
  /** Invoice money in its own currency, "$" for USD ("$1,363", "€1,826"), not "USD 1,363". */
  cur?: boolean;
}) {
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
        headline: cur && m.unit === "currency" ? `${upToWord(f)}${cxMoney(m.currency, numOrZero(part ? m.usd_flagged : m.usd))}` : tileMoney(f),
        unit: period === "per month" ? "/mo" : undefined,
        cause: cause ? cause(rows) : (part ? `of ${cur && m.unit === "currency" ? cxMoney(m.currency, numOrZero(m.usd)) : fmtMoneyOf(m, m.usd, 0)} ${kindWord}` : kindWord),
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
  const products = useCortexProducts(p);
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
  const featTotal = (feat.allRows || []).find((r) => r.is_total_row) || null;
  const unexplainedCell: CxStripCell = (() => {
    const base = { key: "unexplained", label: "No feature explains", onOpen: feat.open };
    if (feat.loading) return { ...base, value: null, loading: true };
    if (feat.why || !feat.rows) return { ...base, value: null, missing: feat.why, status: feat.empty ? null : "not_assessed" };
    const t = featTotal;
    if (!t || t.unexplained_pct === null || t.unexplained_pct === undefined) return { ...base, value: null, missing: "No billed AI total to compare with." };
    return {
      ...base, value: fmtShare(numOrZero(t.unexplained_pct)), unit: "of AI bill",
      lines: [`${fmtCreditsShort(numOrZero(t.unexplained_credits))} of ${fmtCreditsShort(numOrZero(t.billed_credits))} billed.`, "Ties the feature split to the bill."],
    };
  })();
  return (
    <div className="ais-page cx-c">
      <SummaryTileRow compact>
        <CheckTile c={trend} label="AI spend" build={(rows, c) => serviceShare(rows, c, "AI_SERVICES", "AI services", spark, wAi)} />
        <MoneyTile c={pt} label="Idle provisioned throughput" cause={(rows) => {
          const top = [...rows].filter(isFlagged).sort((a, b) => numOrZero(b.est_idle_usd_list) - numOrZero(a.est_idle_usd_list))[0];
          return top ? `${top.throughput_name} sat idle on ${fmtInt(top.idle_days)} of its ${fmtInt(top.paid_days)} paid days.` : "No paid day went unused.";
        }} />
        <CheckTile c={users} label="Top AI functions user" build={(rows, c) => {
          const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
          const prevOf = (r: Row) => (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits));
          const g = groupBy(rows, (r) => String(r.user_name || "(no user)"), s.val, prevOf);
          const total = g.reduce((a, x) => a + x.value, 0);
          const top = [...g].sort((a, b) => b.value - a.value)[0];
          if (!top || total <= 0) return { headline: null, missingReason: "No AI functions spend in this window" };
          return {
            headline: fmtShare(pctOf(top.value, total)), unit: "of AI functions",
            flagged: g.filter((x) => x.status === "CRITICAL").length, population: g.length, noun: "users spiking",
            trend: changeChip(top.value, top.prev, top.status === "CRITICAL"),
            cause: `${top.name}: ${s.fmt(top.value)}.`,
          };
        }} />
      </SummaryTileRow>
      <CxStrip aria="AI bill and spend per Cortex product" cells={[unexplainedCell, ...cortexProductCells(p, products)]} />
      <CxKindsNote>Spend is context. Idle throughput and failed-statement credits are possible waste, counted on their own; products are never added together.</CxKindsNote>
      <CxSlot c={{ ...aiDays.c, rows: aiDays.c.rows ? [] : null }} title={`AI spend per ${grain}`}
        subtitle={`${aiDays.priced ? "$ / day" : "credits / day"} · AI functions, search and analyst (not Cortex Code) · ${grain === "day" ? "today is partial, shown faded" : "partial months are marked"}`}>
        {() => <ServiceDaysChart s={aiDays} what="AI" w={wAi} grain={grain} setGrain={setGrain} />}
      </CxSlot>
      <CxRow2>
        <CxSlot c={feat} title="AI spend by feature" subtitle="Share of the billed AI credits · $ and credits · vs the period before">
          {(rows, c) => <FeatureSplit rows={rows} total={(c.allRows || []).find((r) => r.is_total_row) || null} disc={c.disc} />}
        </CxSlot>
        <CxSlot c={users} title="AI functions spend by user" subtitle="Change vs the period before · warning: grew sharply">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
            const prevOf = (r: Row) => (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits));
            const list = groupBy(rows, (r) => String(r.user_name || "(no user)"), s.val, prevOf).filter((x) => x.value > 0).sort((a, b) => b.value - a.value);
            if (list.length < 2) return null;
            return <CxBars aria="AI functions spend by user" n={8}
              rows={list.map((x) => {
                const ch = fmtChange(x.value, x.prev, false);
                return { key: x.name, name: x.name, value: x.value, status: x.status, onOpen: c.open, cells: [s.fmt(x.value), ch !== "-" ? ch : null].filter((v): v is string => !!v) };
              })} />;
          }}
        </CxSlot>
      </CxRow2>
      <CxSlot c={pt} title="Provisioned throughputs" subtitle="Paid days and the days nothing called the model · spend is context, idle $ is possible waste · open a row">
        {(rows, c) => {
          const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
          const list = [...rows].sort((a, b) => numOrZero(b.idle_day_pct) - numOrZero(a.idle_day_pct) || s.val(b) - s.val(a));
          return (
            <CxTable aria="Provisioned throughputs" n={10}
              cols={[{ label: "Throughput" }, { label: "Paid days", num: true, width: "auto" }, { label: "Idle days", num: true, width: "auto" }, { label: s.priced ? "Spend" : "Credits", num: true, width: "auto" }, { label: "Idle $", num: true, width: "auto" }]}
              rows={list.map((r) => ({
                key: `${r.account_id}|${r.throughput_name}`, status: numOrZero(r.idle_days) > 0 ? r.status : "OK",
                onOpen: () => DrawerBus.open({ id: "sf_ai_provisioned_throughput_use", col: "throughput_name", val: String(r.throughput_name), label: String(r.throughput_name) }),
                cells: [String(r.throughput_name || "(unnamed)"), fmtInt(r.paid_days), `${fmtInt(r.idle_days)} of ${fmtInt(r.paid_days)}`,
                  s.fmt(s.val(r)), s.priced && r.est_idle_usd_list != null && isFlagged(r) ? fmtMoney(numOrZero(r.est_idle_usd_list) * (1 - c.disc), 0) : "–"],
              }))} />
          );
        }}
      </CxSlot>
      <CxRow2>
        <CxSlot c={search} title="Cortex Search spend by service" subtitle="Serving and other credits · change vs the period before · spend, not waste">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
            const list = rows.filter((r) => s.val(r) > 0).sort((a, b) => s.val(b) - s.val(a));
            if (!list.length) return null;
            return <CxBars aria="Cortex Search spend by service" n={8}
              rows={list.map((r) => {
                const ch = r.change_pct === null || r.change_pct === undefined ? null : `${numOrZero(r.change_pct) >= 0 ? "+" : "−"}${fmtShare(Math.abs(numOrZero(r.change_pct)))}`;
                const serving = pctOf(numOrZero(r.serving_credits), numOrZero(r.current_credits));
                return {
                  key: `${r.account_id}|${r.service_id ?? r.service_name}`, name: nameId(r.service_name, r.service_id, "(unnamed service)"), value: s.val(r), status: r.status, onOpen: c.open,
                  cells: [s.priced ? fmtMoney(s.val(r), 0) : fmtCreditsFine(numOrZero(r.current_credits)), serving === null ? null : `${fmtShare(serving)} serving`, ch].filter((v): v is string => !!v),
                };
              })} />;
          }}
        </CxSlot>
        <CxSlot c={stale} title="Search indexes that stopped taking rows" subtitle="Days since the index last embedded new rows · serving bills meanwhile · $ is spend">
          {(rows, c) => {
            const priced = isPriced(rows);
            if (!rows.length) return null;
            return <CxBars aria="Days since each search index took new rows" n={6}
              rows={[...rows].sort((a, b) => numOrZero(b.days_without_new_rows) - numOrZero(a.days_without_new_rows)).map((r) => ({
                key: `${r.account_id}|${r.service_id}`, name: nameId(r.service_full_name, r.service_id), value: numOrZero(r.days_without_new_rows), status: r.status, onOpen: c.open,
                cells: [`${fmtInt(r.days_without_new_rows)} d`, `${priced ? fmtMoney(numOrZero(r.est_serving_usd_list) * (1 - c.disc), 0) : fmtCreditsShort(numOrZero(r.serving_credits))} serving`],
              }))} />;
          }}
        </CxSlot>
      </CxRow2>
      <CxSlot c={fail} title="AI credits on failed statements" subtitle="Tokens bill even when the statement fails or is cancelled · $ is possible waste · open a row">
        {(rows, c) => {
          const priced = isPriced(rows);
          const list = rows.filter((r) => numOrZero(r.failed_credits) > 0).sort((a, b) => numOrZero(b.failed_credits) - numOrZero(a.failed_credits));
          if (!list.length) return null;
          return <CxGridBars aria="AI credits on failed statements" n={8} nameWidth="minmax(180px, 1.6fr)"
            cols={[{ label: priced ? "$ · 30 d" : "Credits", width: "minmax(72px, auto)" }, { label: "How it ended", width: "minmax(150px, auto)" }]}
            rows={list.map((r) => {
              const cause = [["Cancelled", "cancelled_credits"], ["Timed out", "timed_out_credits"], ["Error", "error_credits"]]
                .sort((a, b) => numOrZero(r[b[1]]) - numOrZero(r[a[1]]))[0][0];
              const usd = numOrZero(r.est_wasted_usd_list) * (1 - c.disc);
              const name = `${r.function_name} ${r.model_name && r.model_name !== "(none)" ? r.model_name : ""} · ${r.user_name}`.replace(/\s+·/, " ·");
              return {
                key: `${r.account_id}|${r.user_name}|${r.warehouse_id}|${r.function_name}|${r.model_name}`, name, value: numOrZero(r.failed_credits), status: r.status,
                onOpen: () => DrawerBus.open({ id: "sf_ai_credits_on_failed_queries", col: "user_name", val: String(r.user_name), label: name }),
                cells: [priced && isFlagged(r) ? (usd < 1 ? "under $1" : fmtMoney(usd, 0)) : fmtCreditsShort(numOrZero(r.failed_credits)),
                  `${cause}: ${fmtInt(r.failed_queries)} of ${fmtInt(r.ai_queries)} statements`],
              };
            })} />;
        }}
      </CxSlot>
      <CortexAgentsPanel p={p} k={products} />
      <CxSlot c={access} title="Who can call Cortex" subtitle="Snowflake grants AI to PUBLIC by default · critical or warning: every user can call it">
        {(rows) => (
          <CxTable aria="Ways into Cortex AI functions" n={3}
            cols={[{ label: "Way in" }, { label: "Public", width: "minmax(140px, 1fr)" }, { label: "Other roles", num: true, width: "auto" }]}
            rows={rows.map((r) => ({
              key: `${r.account_id}|${r.access_path}`, status: r.status,
              cells: [String(r.access_label || r.access_path),
                r.status === "NOT_ASSESSED" ? "– not listed"
                  : r.access_path === "models_allowlist" ? `Models allowed: ${r.setting_value}`
                  : r.open_to_public ? `Holds it${r.public_granted_on ? ` since ${fmtDayShort(r.public_granted_on)}` : ""}` : "Revoked",
                r.other_roles == null ? "–" : fmtInt(r.other_roles)],
            }))} />
        )}
      </CxSlot>
    </div>
  );
}

/** Credits by feature on fixed columns: share of the billed AI total, $ and credits now, before and the change. */
function FeatureSplit({ rows, total, disc }: { rows: Row[]; total: Row | null; disc: number }) {
  const feats = rows.filter((r) => r.row_kind === "feature");
  const prov = rows.find((r) => r.row_kind === "provisioned");
  if (!feats.length) return null;
  const order = [...feats].sort((a, b) => numOrZero(b.current_credits) - numOrZero(a.current_credits));
  const ptuInBill = total ? numOrZero(total.ptu_in_bill_credits) : 0;
  const unexplained = total ? numOrZero(total.unexplained_credits) : 0;
  const now = order.reduce((a, r) => a + numOrZero(r.current_credits), 0) + ptuInBill + unexplained;
  const before = order.reduce((a, r) => a + numOrZero(r.previous_credits), 0);
  // Rows can all be zero (only the billed-total row, still settling): say so rather than draw empty bars.
  if (now <= 0 && before <= 0) {
    return <div className="chart-note-oneline">No Cortex feature spend in this window yet; the billed AI total settles about 2 days after the day.</div>;
  }
  const billed = total && numOrZero(total.billed_credits) > 0 ? numOrZero(total.billed_credits) : now;
  const priced = isPriced(feats);
  const row = (key: string, name: string, cur: number, prev: number | null, usd: number | null, extra?: Partial<CxBarRow>): CxBarRow => {
    const ch = prev == null ? "-" : fmtChange(cur, prev, false);
    return {
      key, name, value: cur,
      cells: [fmtShare(pctOf(cur, billed)), usd == null ? "–" : fmtMoney(usd, 0), fmtCreditsFine(cur).replace(" credits", ""),
        prev == null ? "–" : fmtCreditsFine(prev).replace(" credits", ""), ch === "-" ? "–" : ch],
      ...extra,
    };
  };
  const list: CxBarRow[] = order.map((r) => row(String(r.feature), String(r.feature), numOrZero(r.current_credits), numOrZero(r.previous_credits),
    priced && r.est_current_usd_list != null ? numOrZero(r.est_current_usd_list) * (1 - disc) : null));
  if (ptuInBill > 0) list.push(row("__ptu", "Provisioned throughput", ptuInBill, null, null, { color: "var(--c-other)" }));
  if (unexplained > 0) list.push(row("__gap", "No feature explains", unexplained, null, null, { hatched: true }));
  return (
    <>
      <CxGridBars aria="AI credits by feature" n={12} nameWidth="minmax(120px, 1.2fr)" legend={false}
        cols={[{ label: "Share" }, { label: "$" }, { label: "Credits" }, { label: "Before" }, { label: "Change" }]}
        rows={list} />
      <div className="metric-note">{`${fmtCreditsShort(now)} this period${total ? " billed" : ""} vs ${fmtCreditsShort(before)} before (features only).`}
        {prov && numOrZero(prov.current_credits) - ptuInBill > 0.005 ? ` Provisioned throughput outside the AI bill: ${fmtCreditsShort(numOrZero(prov.current_credits) - ptuInBill)}.` : ""}</div>
    </>
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
  const poolName = (r: Row) => nameId(r.compute_pool_name, r.compute_pool_id, "(no compute pool)");
  useLede(p, pools.loading || idle.loading, pools.rows && poolS && poolCur > 0
    ? `Compute pools cost ${poolS.fmt(poolCur)} in ${w || "the window"}${idle.rows ? `; ${fmtInt(idleFlag.length)} of ${fmtInt(idle.rows.length)} billed with nothing running on them` : ""}.${code.rows ? ` ${fmtInt(codeFlag.length)} of ${fmtInt(code.rows.length)} functions and procedures are flagged.` : ""}`
    : null);
  return (
    <div className="ais-page cx-c">
      <SummaryTileRow compact>
        <CheckTile c={pools} label="Compute pool spend" build={(rows, c) => {
          const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
          const prev = rows.reduce((a, r) => a + (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits)), 0);
          const ch = fmtChange(poolCur, prev, false);
          return {
            headline: s.fmt(poolCur), status: "neutral",
            base: `${fmtInt(rows.filter((r) => s.val(r) > 0).length)} of ${fmtInt(rows.length)} compute pools billed in ${w || "the window"}${ch !== "-" ? `, ${ch} vs before` : ""}.`,
            cause: <span className="ais-spark-cause"><SummaryTileSpark points={spark} /><span>Spend, not waste.</span></span>,
          };
        }} />
        <MoneyTile c={idle} label="Pools with no live service" cause={(rows) => {
          const top = [...rows].filter(isFlagged).sort((a, b) => numOrZero(b.est_wasted_usd_list) - numOrZero(a.est_wasted_usd_list))[0];
          return top ? `${poolName(top)}: ${fmtInt(top.idle_hours)} idle hours.` : "Every billed pool ran a service.";
        }} />
        <CheckTile c={pools} label="Always-on pools" badge build={(rows, c) => {
          const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
          const total = rows.reduce((a, r) => a + s.val(r), 0);
          const on = rows.filter(alwaysOn);
          const top = [...on].sort((a, b) => s.val(b) - s.val(a))[0];
          return {
            headline: fmtShare(pctOf(on.reduce((a, r) => a + s.val(r), 0), total) ?? 0), unit: "of pool spend",
            flagged: on.length, population: rows.length, noun: "pools never stop",
            status: on.length ? statusWord(on) : "ok",
            cause: top ? `${poolName(top)} is up ${fmtShare(numOrZero(top.always_on_pct))} of hours.` : "No pool is up every hour.",
          };
        }} />
        <CheckTile c={code} label="Functions & procedures at risk" build={(rows) => {
          const flagged = rows.filter(isFlagged);
          const counts = new Map<string, number>();
          flagged.forEach((r) => codeCauses(r).split(";").filter(Boolean).forEach((k) => counts.set(k, (counts.get(k) || 0) + 1)));
          const top = [...counts.entries()].sort((a, b) => b[1] - a[1])[0];
          return {
            headline: `${fmtInt(flagged.length)} of ${fmtInt(rows.length)}`, unit: "flagged",
            base: `${fmtShare(pctOf(flagged.length, rows.length) ?? 0)} of functions and procedures.`,
            cause: top ? `${top[0]}: ${fmtInt(top[1])} of them.` : "None flagged.",
          };
        }} />
      </SummaryTileRow>
      <CxRow2>
        <CxSlot c={pools} title="Compute pools by spend" subtitle="Share of hours each pool was up">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
            const list = [...rows].sort((a, b) => s.val(b) - s.val(a));
            if (list.length < 2) return null;
            return <CxGridBars aria="Compute pool spend" n={8} cols={[{ label: s.priced ? "Spend" : "Credits" }, { label: "Hours up" }]}
              rows={list.map((r) => ({
                key: `${r.account_id}|${r.compute_pool_id ?? r.compute_pool_name}`, name: poolName(r), value: s.val(r), status: r.status, onOpen: c.open,
                cells: [s.fmt(s.val(r)), fmtShare(numOrZero(r.always_on_pct))],
              }))} />;
          }}
        </CxSlot>
        <CxSlot c={code} title="Why functions are flagged" subtitle="Flagged functions and procedures per cause · one can have several causes">
          {(rows, c) => {
            const flagged = rows.filter(isFlagged);
            if (!flagged.length) return null;
            const counts = new Map<string, number>();
            flagged.forEach((r) => codeCauses(r).split(";").filter(Boolean).forEach((k) => counts.set(k, (counts.get(k) || 0) + 1)));
            return <CxBars aria="Why functions and procedures are flagged" n={8} max={flagged.length} legend={false}
              rows={[...counts.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => ({
                key: k, name: k, value: v, onOpen: c.open, cells: [`${fmtInt(v)} of ${fmtInt(flagged.length)}`, fmtShare(pctOf(v, flagged.length))],
              }))} />;
          }}
        </CxSlot>
      </CxRow2>
      <CxRow2>
        <CxSlot c={nb} title="Notebooks: hours billed per active day" subtitle="Warning: a kernel was left up">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
            const list = [...rows].sort((a, b) => numOrZero(b.hours_per_active_day) - numOrZero(a.hours_per_active_day));
            if (list.length < 2) return null;
            return <CxGridBars aria="Notebook hours billed per active day" n={8} max={24} cols={[{ label: "h / day" }, { label: s.priced ? "Spend" : "Credits" }]}
              rows={list.map((r) => ({
                key: `${r.account_id}|${r.notebook_id ?? r.notebook_name}`, name: nameId(r.notebook_name, r.notebook_id, "(no notebook)"),
                value: numOrZero(r.hours_per_active_day), status: r.status, onOpen: c.open,
                cells: [`${numOrZero(r.hours_per_active_day).toFixed(1)} h`, s.fmt(s.val(r))],
              }))} />;
          }}
        </CxSlot>
        <CxSlot c={apps} title="Native apps by spend" subtitle="Change vs the period before">
          {(rows, c) => {
            const s = spendOf(rows, c.disc, "est_current_usd_list", "current_credits");
            const prevOf = (r: Row) => (s.priced ? numOrZero(r.est_previous_usd_list) * (1 - c.disc) : numOrZero(r.previous_credits));
            const list = groupBy(rows, (r) => String(r.app_name || "(no app)"), s.val, prevOf).filter((x) => x.value > 0).sort((a, b) => b.value - a.value);
            if (list.length < 2) return null;
            return <CxBars aria="Native app spend" n={8}
              rows={list.map((x) => {
                const ch = fmtChange(x.value, x.prev, false);
                return { key: x.name, name: x.name, value: x.value, status: x.status, onOpen: c.open, cells: [s.fmt(x.value), ch !== "-" ? ch : null].filter((v): v is string => !!v) };
              })} />;
          }}
        </CxSlot>
      </CxRow2>
      <CxSlot c={ingress} title="Services that can take internet traffic" subtitle="The owner role holds BIND SERVICE ENDPOINT · confirm with SHOW ENDPOINTS IN SERVICE">
        {(rows) => {
          const acct = rows.find((r) => r.row_kind === "account");
          const rank = (r: Row) => (r.status === "CRITICAL" ? 0 : r.status === "WARN" ? 1 : r.status === "NOT_ASSESSED" ? 2 : 3);
          const svc = rows.filter((r) => r.row_kind === "service").sort((a, b) => rank(a) - rank(b));
          const pub = !acct ? null : acct.status === "NOT_ASSESSED" ? "PUBLIC: – the role can't see the grant."
            : acct.owner_can_bind ? "PUBLIC holds BIND SERVICE ENDPOINT: every service owner can open a public endpoint."
            : `PUBLIC does not hold it${acct.public_revoked_on ? ` (revoked ${fmtDayShort(acct.public_revoked_on)})` : ""}; ${fmtInt(acct.other_roles)} other roles do.`;
          const endpoint = (r: Row) => (r.status === "NOT_ASSESSED" ? "– not known" : r.owner_can_bind ? `Can open one (via ${r.bind_via})` : "Cannot open one");
          // The same answer on every row is said once, above the table.
          const same = svc.length > 1 && new Set(svc.map(endpoint)).size === 1;
          return (
            <>
              {pub && <div className="metric-note">{pub}{same ? ` ${svc.length === 1 ? "The service" : `All ${fmtInt(svc.length)} services`}: ${endpoint(svc[0]).toLowerCase()}.` : ""}</div>}
              {svc.length > 0 && (
                <CxTable aria="Container services that can take internet traffic" n={8} minWidth={600}
                  cols={[{ label: "Service" }, { label: "Owner role", width: "minmax(110px, auto)" }, { label: "State", width: "minmax(110px, auto)" },
                    ...(same ? [] : [{ label: "Public endpoint", width: "minmax(130px, auto)" }])]}
                  rows={svc.map((r) => ({
                    key: `${r.account_id}|${r.service_id}`, status: r.status,
                    cells: [<CxName key="n" name={nameId(r.service_full_name, r.service_id)} />, String(r.service_owner || "–"),
                      r.is_running ? "Running" : r.reachable ? "Suspended, resumes on request" : "Suspended",
                      ...(same ? [] : [endpoint(r)])],
                  }))} />
              )}
            </>
          );
        }}
      </CxSlot>
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
  const versionKey = (r: Row) => String(r.model_version_id ?? modelName(r));
  const versions = new Set(svRows.map(versionKey)).size;
  const upAll = new Set(svRows.filter((r) => numOrZero(r.always_on_pct) >= 99.5).map(versionKey)).size;
  // Calls come from the service functions; a NULL means the export has no call count, never zero calls.
  const withCalls = svRows.filter((r) => r.invocations !== null && r.invocations !== undefined && r.invocations !== "");
  const winHours = numOrZero(p.filters.window) * 24;
  useLede(p, sv.loading, sv.rows && svCur > 0
    ? `Model serving cost ${svS.fmt(svCur)} in ${w || "the window"}, inside container and warehouse spend.${upAll ? ` ${fmtInt(upAll)} of ${fmtInt(versions)} model versions ${upAll === 1 ? "is" : "are"} up every hour.` : ""}`
    : null);
  return (
    <div className="ais-page cx-c">
      <SummaryTileRow compact>
        {/* The page's own total, the same $ as the headline and the check's spend in scope. */}
        <CheckTile c={sv} label="Model serving spend" build={(rows) => {
          const cur = rows.reduce((a, r) => a + numOrZero(r.current_credits), 0);
          const prev = rows.reduce((a, r) => a + numOrZero(r.previous_credits), 0);
          const ch = fmtChange(cur, prev, false);
          return {
            headline: svS.fmt(svCur),
            base: `${fmtInt(versions)} model versions in ${w || "the window"}${ch !== "-" ? `, ${ch} vs the period before` : ""}.`,
            cause: `Already inside container and warehouse spend${svS.priced ? "" : "; in credits, no $ price in this export"}.`,
          };
        }} />
        <CheckTile c={sv} label="On always-up services" badge build={(rows, c) => {
          const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
          const total = rows.reduce((a, r) => a + s.val(r), 0);
          const flagged = rows.filter(isFlagged);
          const fl = flagged.reduce((a, r) => a + s.val(r), 0);
          const top = [...flagged].sort((a, b) => s.val(b) - s.val(a))[0];
          return {
            headline: fmtShare(pctOf(fl, total) ?? 0), unit: "of serving spend",
            base: `${s.fmt(fl)} on ${fmtInt(new Set(flagged.map(versionKey)).size)} of ${fmtInt(versions)} model versions.`,
            cause: top ? `${modelName(top)} was up ${fmtShare(numOrZero(top.always_on_pct))} of hours.` : "No service is up all the time.",
          };
        }} />
        <CheckTile c={sv} label="Endpoints with no calls" build={(rows) => {
          if (!withCalls.length) return { headline: null, missingReason: "Call counts are not in this export: run the export again." };
          const none = withCalls.filter((r) => numOrZero(r.invocations) === 0);
          return {
            headline: fmtInt(none.length), unit: `of ${fmtInt(withCalls.length)} endpoints`,
            base: none.length ? `${none.slice(0, 2).map(modelName).join(", ")}${none.length > 2 ? ` and ${fmtInt(none.length - 2)} more` : ""}.` : `None sat idle in ${w || "the window"}.`,
            cause: rows.length > withCalls.length ? `${fmtInt(rows.length - withCalls.length)} more endpoints have no call count.` : undefined,
          };
        }} />
      </SummaryTileRow>
      <CxSlot c={sv} title="Serving spend by how models run" subtitle={`Share of the ${svS.fmt(svCur)} serving spend`}>
        {(rows, c) => {
          const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
          const segs: ShareSegment[] = SERVING_KINDS.map((k) => ({
            key: k.key, label: k.label, color: k.color, value: rows.filter((r) => servingKind(r) === k.key).reduce((a, r) => a + s.val(r), 0),
          }));
          return segs.filter((x) => x.value > 0).length >= 2 ? <StackedShareBar segments={segs} valueFmt={s.fmt} ariaLabel="Serving spend by how models run" /> : null;
        }}
      </CxSlot>
      <CxSlot c={sv} title="Serving spend by model version"
        subtitle={`${fmtInt(svRows.length)} endpoints for ${fmtInt(versions)} model versions · hours a service was up, of the ${fmtInt(winHours)} h in the window · open a row`}>
        {(rows, c) => {
          const s = spendOf(rows, c.disc, "est_within_usd_list", "current_credits");
          const list = [...rows].sort((a, b) => s.val(b) - s.val(a));
          // A version on both a warehouse and a service is two rows: say what they add up to.
          const twice = groupBy(rows, versionKey, s.val).filter((x) => x.rows > 1).map((x) => {
            const r = rows.find((y) => versionKey(y) === x.name)!;
            return `${modelName(r)} runs on more than one kind of compute, ${s.fmt(x.value)} in all.`;
          });
          return (
            <>
              <CxTable aria="Serving spend by model version" n={10} minWidth={680}
                cols={[{ label: "Model version" }, { label: "Runs on", width: "minmax(120px, auto)" }, { label: "Hours up", width: "minmax(200px, 1.4fr)" },
                  { label: "Calls", num: true, width: "auto" }, { label: s.priced ? "Spend" : "Credits", num: true, width: "auto" }]}
                rows={list.map((r) => {
                  const kind = servingKind(r);
                  return {
                    key: `${r.account_id}|${r.model_version_id ?? modelName(r)}|${r.service_id ?? ""}`, status: r.status,
                    onOpen: () => DrawerBus.open({ id: "sf_ai_model_serving_spend", col: "model_version_id", val: r.model_version_id != null ? String(r.model_version_id) : null, label: modelName(r) }),
                    cells: [modelName(r), (SERVING_KINDS.find((k) => k.key === kind) || SERVING_KINDS[0]).label,
                      kind === "WAREHOUSE"
                        ? <span key="h" className="cx-sub">No service, so no hours up</span>
                        : <span key="h" className="cx-hours"><MiniBar value={numOrZero(r.active_hours)} max={winHours} /><span className="cx-num">{`${fmtInt(r.active_hours)} h`}</span></span>,
                      r.invocations == null || r.invocations === "" ? "–" : fmtInt(r.invocations), <b key="s">{s.fmt(s.val(r))}</b>],
                  };
                })} />
              {twice.length > 0 && <div className="metric-note">{twice.join(" ")} Calls are counted only for warehouse models.</div>}
            </>
          );
        }}
      </CxSlot>
    </div>
  );
}

// ═══════════════════════ Storage > Growth & stages ═══════════════════════

/** "+$503 / month", "< $1 / month": storage $ added per month, never "+<$1/mo". */
const perMonthAdd = (v: number) => (v < 1 ? "< $1 / month" : `+${fmtMoney(v, 0)} / month`);
// "BASE TABLE" reads "Base table".
const sentenceCase = (v: any) => { const s = String(v ?? "").replace(/_/g, " ").toLowerCase(); return s.charAt(0).toUpperCase() + s.slice(1); };

export function ApStorageGrowth(p: ApPageProps) {
  const gr = useCheck(p, "sf_storage_growth_by_database");
  const stage = useCheck(p, "sf_storage_stage_bytes");
  const stale = useCheck(p, "sf_storage_stale_stage_files");
  const arch = useCheck(p, "sf_storage_archive_retrieval");
  const types = useAggCheck(p, "table_inventory_type", ["table_type"], "table_count", ["table_bytes"]);
  const gStart = sumCol(gr.rows || [], "start_bytes"), gEnd = sumCol(gr.rows || [], "end_bytes");
  const staleN = (stale.rows || []).filter(isFlagged).length;
  useLede(p, gr.loading || stale.loading, gr.rows && gStart > 0
    ? `Storage ${gEnd >= gStart ? "grew" : "shrank"} ${fmtShare(Math.abs(pctOf(gEnd - gStart, gStart) ?? 0))} to ${fmtSize(gbOf(gEnd))} in the window.${stale.rows ? ` ${fmtInt(staleN)} of ${fmtInt(stale.rows.length)} stages hold files nobody cleaned up.` : ""}`
    : null);
  return (
    <div className="ais-page cx-c">
      <SummaryTileRow compact>
        <CheckTile c={gr} label="Storage growth" build={(rows, c) => {
          const start = sumCol(rows, "start_bytes"), end = sumCol(rows, "end_bytes");
          const added = sumCol(rows, "projected_added_usd_month") * (1 - c.disc);
          const top = [...rows].sort((a, b) => numOrZero(b.growth_bytes) - numOrZero(a.growth_bytes))[0];
          const priced = isPriced(rows);
          return {
            headline: signedShare(pctOf(end - start, start)), unit: `${fmtSize(gbOf(start))} → ${fmtSize(gbOf(end))}`, status: statusWord(rows),
            base: `${priced && added > 0 ? `Adds ${perMonthAdd(added).replace(/^\+/, "")}. ` : ""}${fmtInt(rows.filter(isFlagged).length)} of ${fmtInt(rows.length)} databases flagged.`,
            cause: top && numOrZero(top.growth_bytes) > 0 ? `${nameId(top.database_name, top.database_id)} grew ${fmtSize(gbOf(top.growth_bytes))}.` : "No database grew.",
          };
        }} />
        <CheckTile c={stage} label="Internal stages" build={(rows, c) => {
          const usd = sumCol(rows, "est_storage_usd_month") * (1 - c.disc);
          return {
            headline: fmtSize(sumCol(rows, "end_stage_gb")), unit: `${fmtShare(pctOf(sumCol(rows, "end_stage_bytes"), sumCol(rows, "end_total_bytes")))} of storage`,
            base: `${isPriced(rows) ? `${fmtMoney(usd, 0)} / month. ` : ""}${fmtInt(sumCol(rows, "stale_named_stages"))} of ${fmtInt(sumCol(rows, "internal_named_stages"))} named stages are stale.`,
            cause: "Stage files bill like tables but never show in a schema.",
          };
        }} />
        <MoneyTile c={stale} label="Stale stage files" cause={(rows) => {
          const top = [...rows].filter(isFlagged).sort((a, b) => numOrZero(b.stage_gb) - numOrZero(a.stage_gb))[0];
          return top ? `Largest: ${nameId(top.stage_full_name, top.stage_id, "(unnamed stage)")}, ${fmtSize(numOrZero(top.stage_gb))}${top.newest_file_age_days != null ? ` untouched for ${fmtInt(top.newest_file_age_days)} days` : ""}.` : "No stale stage.";
        }} />
        <CheckTile c={arch} label="Pulled back from archive" build={(rows) => {
          const objs = rows.filter((r) => r.row_kind === "object");
          const list = objs.length ? objs : rows;
          const top = [...list].sort((a, b) => numOrZero(b.gb_retrieved) - numOrZero(a.gb_retrieved))[0];
          return {
            headline: fmtSize(sumCol(list, "gb_retrieved")), flagged: list.filter(isFlagged).length, population: list.length, noun: "archived objects",
            cause: top && numOrZero(top.gb_retrieved) > 0 ? `Largest: ${[top.database_name, top.schema_name, top.object_name].filter(Boolean).join(".")}, ${fmtSize(numOrZero(top.gb_retrieved))}.` : "Nothing pulled back.",
          };
        }} />
      </SummaryTileRow>
      <CxRow2>
        <CxSlot c={gr} title="Growth by database" subtitle="% added in the window · projected $ a month it adds">
          {(rows, c) => {
            const list = rows.filter((r) => numOrZero(r.growth_bytes) > 0)
              .map((r) => ({ r, pct: pctOf(numOrZero(r.growth_bytes), numOrZero(r.start_bytes)) ?? 0 })).sort((a, b) => b.pct - a.pct);
            if (!list.length) return <div className="chart-note-oneline">No database grew in this window.</div>;
            return <CxGridBars aria="Storage growth by database" n={8} cols={[{ label: "Growth" }, { label: "Adds" }]}
              rows={list.map(({ r, pct }) => {
                const add = numOrZero(r.projected_added_usd_month) * (1 - c.disc);
                return {
                  key: String(r.database_id ?? r.database_name), name: `${nameId(r.database_name, r.database_id, "(unnamed database)")}${r.dropped_at ? " - dropped" : ""}`,
                  value: pct, status: r.status, onOpen: c.open, cells: [signedShare(pct), isPriced([r]) ? perMonthAdd(add) : "–"],
                };
              })} />;
          }}
        </CxSlot>
        <CxSlot c={stale} title="Stage files by size" subtitle="Size, and how long since anyone touched them">
          {(rows, c) => {
            const list = rows.filter((r) => numOrZero(r.stage_gb) > 0).sort((a, b) => numOrZero(b.stage_gb) - numOrZero(a.stage_gb));
            if (list.length < 2) return null;
            return <CxBars aria="Stage size" n={8}
              rows={list.map((r) => {
                const age = r.newest_file_age_days == null ? null : numOrZero(r.newest_file_age_days);
                const what = r.finding === "ok" || !r.finding
                  ? (age == null ? "in use" : age === 0 ? "in use today" : `in use ${fmtInt(age)} d ago`)
                  : `${String(r.finding).replace(/_/g, " ")}${age != null ? ` ${fmtInt(age)} d` : ""}`;
                return { key: String(r.stage_id ?? r.stage_full_name), name: nameId(r.stage_full_name, r.stage_id, "(unnamed stage)"), value: numOrZero(r.stage_gb), status: r.status, onOpen: c.open, cells: [fmtSize(numOrZero(r.stage_gb)), what] };
              })} />;
          }}
        </CxSlot>
      </CxRow2>
      <CxSlot c={types} title="Tables by type" subtitle="Share of objects · snapshot at export">
        {(rows) => {
          const list = rows.map((g) => {
            const bytes = g.also ? g.also.table_bytes : null;
            return { type: String((g.key || [])[0] || "(no type)"), n: numOrZero(g.value), bytes: bytes === null || bytes === undefined ? null : Number(bytes) };
          }).filter((x) => x.n > 0).sort((a, b) => b.n - a.n);
          const total = list.reduce((a, x) => a + x.n, 0);
          if (!list.length) return null;
          // A size column that is "–" on most rows says nothing: keep it only when Snowflake recorded sizes.
          const sized = list.filter((x) => x.bytes !== null && x.bytes > 0).length;
          const withSize = sized > 0 && sized >= list.length / 2;
          return (
            <>
              <div className="metric-note">{`${fmtInt(total)} tables and views.`}</div>
              <CxGridBars aria="Tables and views by type" n={12} max={total} legend={false} nameWidth="minmax(160px, 1fr)"
                cols={[{ label: "Objects" }, { label: "Share" }, ...(withSize ? [{ label: "Size" }] : [])]}
                rows={list.map((x) => ({ key: x.type, name: sentenceCase(x.type), value: x.n, cells: [fmtInt(x.n), fmtShare(pctOf(x.n, total)), ...(withSize ? [x.bytes === null ? "–" : fmtSize(gbOf(x.bytes))] : [])] }))} />
              {!withSize && <div className="metric-note">Size is left out: Snowflake keeps no size for views, and none was recorded for most of these types.</div>}
            </>
          );
        }}
      </CxSlot>
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
  const said = parts.map(([c, x], i) => { const v = monthOf(c); return v ? `${v}${i === 0 ? " a month" : ""} ${x}` : null; }).filter(Boolean);
  useLede(p, unused.loading || churn.loading || dropped.loading, said.length ? `Storage nobody reads costs ${said.join(", ")}.` : null);
  return (
    <div className="ais-page cx-c">
      <SummaryTileRow compact>
        <MoneyTile c={unused} label="Tables nobody has read" cause={(rows) => {
          const top = [...rows].filter(isFlagged).sort((a, b) => numOrZero(b.total_gb) - numOrZero(a.total_gb))[0];
          return top ? `Largest: ${nameId(top.table_fqn, top.table_id)}, ${fmtSize(numOrZero(top.total_gb))}.` : "Every table was read.";
        }} />
        <MoneyTile c={{ ...churn, open: () => p.goTo({ tab: p.area, subtab: "retention", focusQueryId: "sf_storage_churn_unread" }) }} label="Rewritten, never read" cause={(rows) => {
          const fl = rows.filter(isFlagged);
          return fl.length ? `${fmtSize(sumCol(fl, "time_travel_gb") + sumCol(fl, "failsafe_gb"))} of history kept for tables nobody reads.` : "None flagged.";
        }} />
        <MoneyTile c={dropped} label="Dropped, still billed" cause={(rows) => {
          const next = rows.map((r) => (r.purge_by ? String(r.purge_by).slice(0, 10) : null)).filter((d): d is string => !!d && (!asOf || d >= asOf)).sort()[0];
          return next ? `Fail-safe cannot be freed early; the next one leaves the bill ${fmtDayShort(next)}.` : "Fail-safe end dates unknown.";
        }} />
        <MoneyTile c={clones} label="Clones nobody reads" cause={(rows) => {
          const gb = rows.filter(isFlagged).reduce((a, r) => a + numOrZero(r.own_gb) + numOrZero(r.retained_for_clone_gb), 0);
          return `${fmtSize(gb)} kept alive only by clones.`;
        }} />
      </SummaryTileRow>
      <CxSlot c={unused} title="Unread tables by storage" subtitle="$ a month to keep each one">
        {(rows, c) => {
          const priced = isPriced(rows);
          // An export from before written_in_window has no such key: no toggle, all unread tables.
          const hasWrite = rows.some((r) => Object.prototype.hasOwnProperty.call(r, "written_in_window"));
          // NULL written_in_window is unknown: it sits in neither group.
          const inGroup = hasWrite ? rows.filter((r) => r.written_in_window === (writeView === "written")) : rows;
          const unknown = rows.filter((r) => r.written_in_window === null || r.written_in_window === undefined).length;
          const usdOf = (r: Row) => numOrZero(r.est_storage_usd_month) * (1 - c.disc);
          const list = [...inGroup].sort((a, b) => (priced ? usdOf(b) - usdOf(a) : numOrZero(b.total_gb) - numOrZero(a.total_gb)));
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
              {list.length ? (
                <CxGridBars aria="Unread tables by storage" n={8} nameWidth="minmax(220px, 1.6fr)" cols={[...(priced ? [{ label: "Per month" }] : []), { label: "Size" }]}
                  foot={<span className="cx-sub">{hasWrite
                    ? `${fmtInt(inGroup.length)} of ${fmtInt(rows.length)} unread tables${unknown ? `; ${fmtInt(unknown)} with write history unknown sit in neither group` : ""}.`
                    : "This export predates the written-or-not split; export again to see it."}</span>}
                  rows={list.map((r) => ({
                    key: `${r.account_id}|${r.table_id}`, name: nameId(r.table_fqn, r.table_id, "(unnamed table)"), value: priced ? usdOf(r) : numOrZero(r.total_gb), status: r.status, onOpen: c.open,
                    cells: [...(priced ? [fmtMoney(usdOf(r), 0)] : []), fmtSize(numOrZero(r.total_gb))],
                  }))} />
              ) : <div className="chart-note-oneline">{`None of the ${fmtInt(rows.length)} unread tables was ${writeView === "written" ? "written" : "left unwritten"} in ${w || "this window"}.`}</div>}
            </>
          );
        }}
      </CxSlot>
      <CxRow2>
        <CxSlot c={dropped} title="When dropped tables leave the bill" subtitle="GB by the day their Fail-safe ends · by database">
          {(rows, c) => {
            const ev = rows.filter((r) => r.purge_by && numOrZero(r.billed_gb) > 0)
              // A Fail-safe table keeps no name: it is named by its table id instead.
              .map((r) => ({ day: String(r.purge_by).slice(0, 10), kind: r.database_name && r.database_name !== "(unnamed)" ? nameId(r.database_name, r.database_id) : nameId(null, r.table_id, "(dropped, name not kept)"), value: numOrZero(r.billed_gb) }));
            if (!ev.length) return null;
            const days = ev.map((e) => e.day).sort();
            const first = asOf && asOf < days[0] ? asOf : days[0];
            const all: string[] = [];
            for (let t = Date.parse(`${first}T00:00:00Z`), end = Date.parse(`${days[days.length - 1]}T00:00:00Z`); t <= end && all.length < 120; t += 86400000) all.push(new Date(t).toISOString().slice(0, 10));
            return <CxDayStack rows={ev} days={all} unit="GB / day" word="GB" valueFmt={(v) => fmtInt(Math.round(v))} aria="Dropped table storage by the day its Fail-safe ends" onOpen={c.open} />;
          }}
        </CxSlot>
        <CxSlot c={sprawl} title="Unread share, flagged schemas" subtitle="Share of each schema's bytes in tables nobody reads">
          {(rows, c) => {
            const fl = rows.filter(isFlagged).sort((a, b) => numOrZero(b.unread_bytes) / Math.max(1, numOrZero(b.total_bytes)) - numOrZero(a.unread_bytes) / Math.max(1, numOrZero(a.total_bytes)));
            if (!fl.length) return <div className="chart-note-oneline">No schema flagged.</div>;
            return <CxBars aria="Unread share of flagged schemas" n={8} max={1} legend={false}
              foot={<span className="cx-sub">{`${fmtInt(fl.length)} of ${plural(rows.length, "schema")} flagged.`}</span>}
              rows={fl.map((r) => ({
                key: String(r.schema_id ?? r.schema_fqn), name: nameId(r.schema_fqn, r.schema_id, "(unnamed schema)"), status: r.status, onOpen: c.open,
                value: numOrZero(r.total_bytes) > 0 ? numOrZero(r.unread_bytes) / numOrZero(r.total_bytes) : 0,
                cells: [fmtShare(pctOf(numOrZero(r.unread_bytes), numOrZero(r.total_bytes))), fmtSize(gbOf(r.unread_bytes))],
              }))} />;
          }}
        </CxSlot>
      </CxRow2>
      <CxSlot c={oldest} title="Oldest untouched tables" subtitle="Live tables, longest unchanged first · $ is what each costs to keep a month, not a saving · open a row">
        {(all, c) => {
          // A table with no database name is internal or orphaned, never a live customer table: kept off the list.
          const rows = all.filter((r) => r.database_name != null && r.database_name !== "");
          const noDb = all.length - rows.length;
          const priced = isPriced(rows);
          const usdNum = (r: Row) => (r.price_basis !== "unpriced" && r.est_storage_usd_month != null ? numOrZero(r.est_storage_usd_month) * (1 - c.disc) : null);
          const usdOf = (r: Row) => { const v = usdNum(r); return v == null ? "–" : fmtMoney(v, 0); };
          const day = (v: any) => (v ? fmtDayShort(v) : "–");
          return (
            <>
              <CxTable aria="Oldest untouched tables" n={10} minWidth={760} empty="No live table with a database name in this export."
                cols={[{ label: "Table" }, { label: "Type", width: "auto" }, { label: "Created", width: "auto" }, { label: "Last changed", width: "auto" },
                  { label: "Unchanged", num: true, width: "auto" }, { label: "Size", num: true, width: "auto" }, { label: "Per month", num: true, width: "auto" }]}
                rows={rows.map((r) => ({
                  key: `${r.account_id}|${r.table_id}`, status: r.status,
                  onOpen: () => DrawerBus.open({ id: "sf_storage_oldest_untouched_tables", col: "table_id", val: String(r.table_id), label: nameId(r.table_name, r.table_id) }),
                  cells: [<CxName key="n" name={`${[r.database_name, r.schema_name, r.table_name].filter(Boolean).join(".")}${r.table_id != null ? ` (${r.table_id})` : ""}`} />, sentenceCase(r.table_type || "–"),
                    day(r.created), day(r.last_altered), r.days_since_altered == null ? "–" : `${fmtInt(r.days_since_altered)} d`, r.total_gb == null ? "–" : fmtSize(numOrZero(r.total_gb)), usdOf(r)],
                }))}
                foot={<CsvButton fileName="oldest-untouched-tables" rows={rows} columns={[
                  { label: "table", value: (r: Row) => nameId(r.table_name, r.table_id) }, { label: "database", value: (r: Row) => r.database_name }, { label: "schema", value: (r: Row) => r.schema_name },
                  { label: "type", value: (r: Row) => r.table_type }, { label: "created", value: (r: Row) => r.created }, { label: "last_altered", value: (r: Row) => r.last_altered },
                  { label: "days_since_altered", value: (r: Row) => r.days_since_altered }, { label: "total_gb", value: (r: Row) => r.total_gb },
                  // The same discounted $ the table shows.
                  { label: priced ? "est_storage_usd_month" : "est_storage_usd_month (unpriced)", value: (r: Row) => usdNum(r) },
                  { label: "status", value: (r: Row) => r.status },
                ]} />} />
              {noDb > 0 && <div className="metric-note">{`${fmtInt(noDb)} of ${fmtInt(all.length)} tables have no database name (internal or orphaned) and are left out.`}</div>}
            </>
          );
        }}
      </CxSlot>
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
  const sums = (rows: Row[]) => ({ a: sumCol(rows, "active_bytes"), t: sumCol(rows, "time_travel_bytes"), f: sumCol(rows, "failsafe_bytes") });
  const ts = sums(tt.rows || []);
  useLede(p, tt.loading, tt.rows && ts.a + ts.t + ts.f > 0
    ? `${fmtShare(pctOf(ts.t + ts.f, ts.a + ts.t + ts.f))} of the bytes on ${fmtInt(tt.rows.length)} tables are history: ${fmtSize(gbOf(ts.t))} of Time Travel and ${fmtSize(gbOf(ts.f))} of Fail-safe, against ${fmtSize(gbOf(ts.a))} of live data.`
    : null);
  return (
    <div className="ais-page cx-c">
      <SummaryTileRow compact>
        <CheckTile c={tt} label="History share" build={(rows) => {
          const s = sums(rows);
          return {
            headline: fmtShare(pctOf(s.t + s.f, s.a + s.t + s.f)), unit: "of bytes",
            base: `Time Travel ${fmtSize(gbOf(s.t))} · Fail-safe ${fmtSize(gbOf(s.f))}.`,
            cause: `${fmtInt(rows.filter(isFlagged).length)} of ${fmtInt(rows.length)} tables flagged.`,
          };
        }} />
        <MoneyTile c={pol} label="Retention over policy" cause={(rows) => {
          const top = [...rows].sort((a, b) => numOrZero(b.over_policy_tt_bytes) - numOrZero(a.over_policy_tt_bytes))[0];
          return top && numOrZero(top.over_policy_tables) > 0
            ? `${nameId(top.database_name, top.database_id)} keeps ${fmtInt(top.over_policy_tables)} tables over ${fmtInt(top.max_retention_days)} days.`
            : "No table above the policy.";
        }} />
        <MoneyTile c={stg} label="Fail-safe on staging" cause={(rows) => {
          const gb = rows.filter(isFlagged).reduce((a, r) => a + numOrZero(r.failsafe_gb), 0);
          return `${fmtSize(gb)} in Fail-safe that a transient table would not keep.`;
        }} />
        <CheckTile c={heavy} label="Write-heavy tables" badge build={(rows, c) => {
          const fl = rows.filter(isFlagged);
          const priced = isPriced(fl.length ? fl : rows);
          const usd = sumCol(fl, "est_history_usd_month") * (1 - c.disc);
          const hist = sumCol(fl, "time_travel_gb") + sumCol(fl, "failsafe_gb");
          const top = [...fl].sort((a, b) => numOrZero(b.est_history_usd_month) - numOrZero(a.est_history_usd_month))[0];
          return {
            headline: priced ? fmtMoney(usd, 0) : fmtSize(hist), unit: priced ? "/ month of history" : "of history",
            base: `${fmtInt(fl.length)} of ${fmtInt(rows.length)} tables · ${fmtSize(hist)} of history.`,
            cause: top ? `Largest: ${nameId([top.database_name, top.schema_name, top.table_name].filter(Boolean).join("."), top.table_id)}.` : "No table rewrites itself heavily.",
          };
        }} />
      </SummaryTileRow>
      <CxRow2>
        <CxSlot c={tt} title="Active vs history, by database" subtitle="Bytes on the tables listed · bar = history's share of each database's bytes">
          {(rows) => {
            const s = sums(rows);
            const segs: ShareSegment[] = [
              { key: "a", label: "Active", value: gbOf(s.a), color: "var(--c1)" },
              { key: "t", label: "Time Travel", value: gbOf(s.t), color: "var(--c2)" },
              { key: "f", label: "Fail-safe", value: gbOf(s.f), color: "var(--c3)" },
            ];
            const byDb = new Map<string, { rows: Row[]; a: number; h: number }>();
            rows.forEach((r) => {
              const k = nameId(r.database_name, r.database_id, "(unnamed database)");
              const cur = byDb.get(k) || { rows: [], a: 0, h: 0 };
              cur.rows.push(r); cur.a += numOrZero(r.active_bytes); cur.h += numOrZero(r.time_travel_bytes) + numOrZero(r.failsafe_bytes);
              byDb.set(k, cur);
            });
            const dbs = [...byDb.entries()].sort((x, y) => y[1].h - x[1].h);
            return (
              <>
                {segs.filter((x) => x.value > 0).length >= 2 && <StackedShareBar segments={segs} valueFmt={fmtSize} totalLabel={`${fmtSize(gbOf(s.a + s.t + s.f))} on ${fmtInt(rows.length)} tables`} ariaLabel="Active, Time Travel and Fail-safe bytes" />}
                <CxGridBars aria="History share by database" n={8} max={100} cols={[{ label: "History" }, { label: "Share" }]}
                  foot={<span className="cx-sub">History = Time Travel + Fail-safe.</span>}
                  rows={dbs.map(([name, v]) => ({
                    key: name, name, value: pctOf(v.h, v.a + v.h) ?? 0,
                    status: v.rows.some((r) => r.status === "CRITICAL") ? "CRITICAL" : v.rows.some((r) => r.status === "WARN") ? "WARN" : "OK",
                    cells: [fmtSize(gbOf(v.h)), fmtShare(pctOf(v.h, v.a + v.h))],
                  }))} />
              </>
            );
          }}
        </CxSlot>
        <CxSlot c={pol} title="Time Travel kept over policy" subtitle="Tables per database keeping Time Travel longer than the account policy">
          {(rows, c) => {
            const list = rows.filter((r) => numOrZero(r.tables_total) > 0)
              .sort((a, b) => numOrZero(b.over_policy_tables) - numOrZero(a.over_policy_tables) || numOrZero(b.tables_total) - numOrZero(a.tables_total));
            if (!list.length) return null;
            const pols = [...new Set(list.map((r) => r.max_retention_days).filter((v) => v != null).map(Number))];
            return <CxBars aria="Tables over the Time Travel policy, per database" n={8} max={1} legend={false}
              foot={pols.length === 1 ? <span className="cx-sub">{`Policy: ${fmtInt(pols[0])} days.`}</span> : undefined}
              rows={list.map((r) => {
                const total = numOrZero(r.tables_total), over = numOrZero(r.over_policy_tables);
                return {
                  key: String(r.database_id ?? r.database_name), name: nameId(r.database_name, r.database_id, "(unnamed database)"), value: total > 0 ? over / total : 0, onOpen: c.open,
                  cells: r.max_retention_days == null ? [`${fmtInt(total)} tables`, "no policy"] : [`${fmtInt(over)} of ${fmtInt(total)} tables`],
                };
              })} />;
          }}
        </CxSlot>
      </CxRow2>
      <CxSlot c={stg} title="Permanent staging tables paying for Fail-safe" subtitle="Bytes in Fail-safe a transient table would not keep · $ a month at your rate">
        {(rows, c) => {
          const priced = isPriced(rows);
          // Only flagged rows carry a saving: the others read "Not flagged", never $0.
          const usdOf = (r: Row) => (r.est_saving_usd_month == null ? null : numOrZero(r.est_saving_usd_month) * (1 - c.disc));
          const list = rows.filter((r) => numOrZero(r.failsafe_gb) > 0).sort((a, b) => (priced ? (usdOf(b) ?? -1) - (usdOf(a) ?? -1) : 0) || numOrZero(b.failsafe_gb) - numOrZero(a.failsafe_gb));
          if (!list.length) return null;
          return <CxGridBars aria="Staging tables paying for Fail-safe" n={8} nameWidth="minmax(240px, 1.6fr)" cols={[...(priced ? [{ label: "Per month" }] : []), { label: "Fail-safe" }]}
            rows={list.map((r) => ({
              key: `${r.account_id}|${r.table_id}`, name: nameId(r.table_fqn, r.table_id, "(unnamed table)"), value: priced ? (usdOf(r) ?? 0) : numOrZero(r.failsafe_gb), status: r.status,
              onOpen: () => DrawerBus.open({ id: "sf_storage_failsafe_on_staging", col: "table_id", val: String(r.table_id), label: nameId(r.table_fqn, r.table_id) }),
              cells: [...(priced ? [usdOf(r) != null ? fmtMoney(usdOf(r)!, 0) : "Not flagged"] : []), fmtSize(numOrZero(r.failsafe_gb))],
            }))} />;
        }}
      </CxSlot>
      <CxSlot c={slp} title="Storage lifecycle policies" subtitle="Daily expire and archive runs · a failed run keeps rows past their expiry · open a row">
        {(rows) => {
          const rank = (r: Row) => (r.status === "CRITICAL" ? 0 : r.status === "WARN" ? 1 : 2);
          const list = [...rows].sort((a, b) => rank(a) - rank(b) || numOrZero(b.failures_in_a_row) - numOrZero(a.failures_in_a_row));
          const word: Record<string, string> = { failing: "Failing", not_running: "Stopped running", no_runs: "Never ran", recovered: "Failed, then recovered", ok: "Runs clean" };
          return (
            <CxTable aria="Storage lifecycle policies by table" n={8} minWidth={760}
              cols={[{ label: "Policy" }, { label: "Table", width: "minmax(160px, 1.4fr)" }, { label: "Last run", width: "auto" }, { label: "Failed in a row", num: true, width: "auto" }, { label: "What happened", width: "minmax(140px, auto)" }]}
              rows={list.map((r) => ({
                key: `${r.account_id}|${r.policy_full_name}|${r.table_full_name}`, status: r.status,
                onOpen: () => DrawerBus.open({ id: "sf_storage_lifecycle_policy_failures", col: "policy_full_name", val: String(r.policy_full_name), label: String(r.policy_full_name) }),
                cells: [<CxName key="p" name={String(r.policy_full_name)} />, <CxName key="t" name={String(r.table_full_name)} />, r.last_run_time ? fmtDayShort(r.last_run_time) : "–", fmtInt(r.failures_in_a_row),
                  `${word[String(r.finding)] || String(r.finding)}${r.failed_tasks && r.finding !== "ok" ? `: ${String(r.failed_tasks).toLowerCase()}` : ""}`],
              }))} />
          );
        }}
      </CxSlot>
    </div>
  );
}

// ═══════════════════════ Storage > Backups ═══════════════════════

// One colour per expiry kind, the same in the bar, the ranked list and the table.
const BACKUP_KINDS = [
  { key: "none", label: "No policy, never expires", color: "var(--c2)" },
  { key: "policy", label: "Expires by policy", color: "var(--c3)" },
  { key: "snapshot", label: "Snapshot, deprecated", color: "var(--c5)" },
];
const backupKind = (r: Row) => (String(r.set_kind || "").toLowerCase() === "snapshot" ? "snapshot" : r.policy_name ? "policy" : "none");
const kindColor = (k: string) => (BACKUP_KINDS.find((x) => x.key === k) || BACKUP_KINDS[0]).color;
/** "GOV_DB.BACKUPS.SET_BIG (9503)", or "Set 9505 · name not in this export" when the role could not list it. */
function setName(r: Row): string {
  const unlisted = r.set_name == null || /^\(set .* not listed\)$/i.test(String(r.set_name));
  const base = unlisted ? `Set ${r.set_id ?? "?"} · name not in this export` : nameId(r.set_name, r.set_id, "(unnamed backup set)");
  return `${base}${r.set_deleted ? " · deleted" : ""}`;
}

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
    <div className="ais-page cx-c">
      <SummaryTileRow compact>
        <CheckTile c={bk} label="Backup storage" badge build={(rows, c) => {
          const usd = sumCol(rows, "est_storage_usd_month") * (1 - c.disc);
          const gb = gbOf(sumCol(rows, "retained_bytes_upper"));
          return {
            headline: isPriced(rows) ? fmtMoney(usd, 0) : fmtSize(gb), unit: isPriced(rows) ? "/ month at most" : "at most",
            base: `All ${plural(rows.length, "set")} · up to ${fmtSize(gb)}.`,
            cause: "An upper bound: a backup shares bytes with its table until the table changes.",
          };
        }} />
        <CheckTile c={bk} label="Sets that never expire" badge build={(rows) => {
          const none = rows.filter(neverExpires);
          const gone = rows.filter((r) => backupKind(r) === "none" && r.set_deleted);
          return {
            headline: `${fmtInt(none.length)} of ${fmtInt(rows.length)}`, unit: "sets",
            base: none.length ? `No policy expires them · up to ${fmtSize(gbOf(sumCol(none, "retained_bytes_upper")))}.` : "Every set has an expiring policy.",
            cause: gone.length ? `${plural(gone.length, "more set")} with no policy ${gone.length === 1 ? "is" : "are"} deleted but still listed.` : undefined,
          };
        }} />
        <CheckTile c={bk} label="Deprecated snapshots" build={(rows) => {
          const snaps = rows.filter((r) => backupKind(r) === "snapshot");
          return {
            headline: fmtInt(snaps.length), unit: `of ${plural(rows.length, "set")}`,
            base: snaps.length ? `Up to ${fmtSize(gbOf(sumCol(snaps, "retained_bytes_upper")))}.` : "No snapshot sets.",
            cause: snaps.length ? "Move them to backup sets." : undefined,
          };
        }} />
      </SummaryTileRow>
      <CxSlot c={bk} title="Backup storage by set" subtitle="The most each set may hold · colour = what expires it · snapshot at export">
        {(rows, c) => {
          const segs: ShareSegment[] = BACKUP_KINDS.map((k) => {
            const of = rows.filter((r) => backupKind(r) === k.key);
            return { key: k.key, label: `${k.label} · ${plural(of.length, "set")}`, color: k.color, value: gbOf(sumCol(of, "retained_bytes_upper")) };
          });
          const list = [...rows].filter((r) => numOrZero(r.retained_bytes_upper) > 0).sort((a, b) => numOrZero(b.retained_bytes_upper) - numOrZero(a.retained_bytes_upper));
          if (!list.length) return null;
          return (
            <>
              <div className="cx-group-head">What expires the backups · share of bytes</div>
              <StackedShareBar segments={segs} valueFmt={fmtSize} ariaLabel="Backup bytes by what expires them" />
              <div className="cx-group-head">By set</div>
              <CxGridBars aria="Backup storage by set, upper bound" n={10} legend={false} nameWidth="minmax(220px, 1.4fr)"
                cols={[{ label: "Up to" }, ...(isPriced(rows) ? [{ label: "Per month" }] : [])]}
                rows={list.map((r) => ({
                  key: String(r.set_id ?? r.set_name), name: setName(r), value: gbOf(r.retained_bytes_upper), color: kindColor(backupKind(r)), onOpen: c.open,
                  cells: [fmtSize(gbOf(r.retained_bytes_upper)), ...(isPriced(rows) ? [r.price_basis !== "unpriced" ? fmtMoney(numOrZero(r.est_storage_usd_month) * (1 - c.disc), 0) : "–"] : [])],
                }))} />
            </>
          );
        }}
      </CxSlot>
      <CxSlot c={bk} title="Backup sets" subtitle="What each set protects, how many backups it holds and what stops it growing · open a row">
        {(rows, c) => (
          <CxTable aria="Backup sets" n={10} minWidth={720}
            cols={[{ label: "Set" }, { label: "Protects", width: "minmax(100px, 1fr)" }, { label: "Expiry", width: "minmax(150px, auto)" }, { label: "Backups", num: true, width: "auto" },
              { label: "Up to", num: true, width: "auto" }, { label: "Per month", num: true, width: "auto" }]}
            rows={[...rows].sort((a, b) => numOrZero(b.retained_bytes_upper) - numOrZero(a.retained_bytes_upper)).map((r) => {
              const kind = backupKind(r);
              return {
                key: `${r.account_id}|${r.set_id ?? r.set_name}`, status: r.status,
                onOpen: () => DrawerBus.open({ id: "sf_storage_backup_snapshot", col: "set_name", val: String(r.set_name), label: setName(r) }),
                cells: [<CxName key="n" name={setName(r)} />, String(r.object_name || "–"),
                  <span key="k" className="cx-legend-item"><span className="cx-sw" style={{ background: kindColor(kind) }} />{kind === "none" ? "No policy" : kind === "snapshot" ? "Snapshot, deprecated" : `${r.policy_name} policy`}</span>,
                  fmtInt(r.backups), fmtSize(gbOf(r.retained_bytes_upper)), r.price_basis !== "unpriced" ? fmtMoney(numOrZero(r.est_storage_usd_month) * (1 - c.disc), 0) : "–"],
              };
            })} />
        )}
      </CxSlot>
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
