// web/src/tabs/tab_overview.tsx -- Overview: shared helpers, the CTO's posture page, and the
// AreaPage Content that picks the FinOps or Governance Overview (tab_landing.tsx).
//
// Dollars are credits times the effective $ per credit. A figure that could not be computed reads
// "–" and why, never $0; while a figure loads it reads "…".
import React from "react";
import { CREDITS_COLUMNS, TOTAL_CREDITS_COLUMNS } from "../api";
import { fmtDuration, fmtInt, fmtMoney } from "../format";
import { IgnoredFilterTracker, aggTotal, numOrZero, useFindingAgg, useFindingData } from "../components/hooks";
import { AREA_REGISTRY, COST_MONEY_COL, MONEY_SCOPE } from "../components/tab_registry";
import {
  FreshnessLine, PageFooter, PageIntro, PatternCard, bandOf, discountIgnoredReason, noDataText, pageEyebrow, priceLabelOf, ranCountsOf,
} from "../components/primitives";
import { useNames } from "../components/names";
import { reconciliationLine, useCostCenterAllocation } from "../components/tag_rollup";
import { DayKindTimeline } from "../components/blocks";
import { computeWord } from "../components/area_pipelines";
import { SpendMoversCard, buildSpendMovers, whLabel } from "./tab_money";
import { AreaContent } from "../area_content";
import { ChartNote } from "../components/charts";
import { NO_PRICE_LEDE, NO_PRICE_READING, isUnpricedAgg, notAssessedText } from "../components/scope";
import { KpiRow, windowShortLabel } from "../components/overview_tile";
import { CxBars, RanLine, ReconChain, TieLine, plural } from "../components/cx_a";
import type { CxBarItem } from "../components/cx_a";
import { IssueTile, fmtShare, pctOf } from "../components/blocks";
import { withoutTotalRows } from "./tab_area";
import { DoTheseFirst, rankActions, useActions } from "./tab_actions";
import { FinopsOverviewContent, GovOverviewContent } from "./tab_landing";
import type { Dims, FetchState, Filters, Finding, GoToFn, Meta, Row } from "../types";

/** The props the area shell passes to Overview. */
export interface OverviewProps {
  filters: Filters;
  dims: Dims;
  meta: Meta | null;
  goTo: GoToFn;
  setVerdict?: ((sentence: string | null) => void) | null;
  allFindingsIndex?: Record<string, Finding> | null;
  roleAreas?: string[] | null;
  role?: string | null;
  [key: string]: any;
}

export const OV_CREDITS = CREDITS_COLUMNS;
export const OV_TOTAL_CREDITS = TOTAL_CREDITS_COLUMNS;
export const OV_USD = ["net_list_cost_usd", "est_usd_list", "usd_list"];

// The tag filter emptied an account-level check whose only tag link is the account itself.
export function tagAccountOnly(s: FetchState | null | undefined) {
  if (!s || s.phase !== "ready" || s.outcome !== "ok_empty_filters") return false;
  const chain = (s.data && s.data.scope && s.data.scope.tag && s.data.scope.tag.chain) || [];
  return chain.length === 1 && chain[0] === "account";
}
export const TAG_ACCOUNT_ONLY_TEXT = "Not filtered by tag: an account-level total";

export function pickNum(row: Row | null | undefined, names: string[]) {
  for (let i = 0; i < names.length; i += 1) {
    const v = row ? row[names[i]] : undefined;
    if (v !== null && v !== undefined && Number.isFinite(Number(v))) return Number(v);
  }
  return null;
}

// Sum a column over rows; null (not 0) when no row carries a value at all, so an unpriced or
// not-run figure never reads as a real zero.
export function sumPick(rows: Row[] | null | undefined, names: string[]) {
  let any = false, total = 0;
  (rows || []).forEach((r) => {
    const v = pickNum(r, names);
    if (v !== null) { any = true; total += v; }
  });
  return any ? total : null;
}

// One value per calendar day between the first and last day returned, 0 for a day with no row: a
// sparse series would skip zero-usage days, which misaligns any trailing average or spike scan.
export function fillGaps(byDay: Map<string, number>) {
  const keys = [...byDay.keys()].sort();
  if (!keys.length) return [];
  const out: { day: string; value: number }[] = [];
  const end = Date.parse(`${keys[keys.length - 1]}T00:00:00Z`);
  for (let t = Date.parse(`${keys[0]}T00:00:00Z`); t <= end; t += 86400000) {
    const day = new Date(t).toISOString().slice(0, 10);
    out.push({ day, value: byDay.get(day) || 0 });
  }
  return out;
}

// The price basis in words, from the API's own `price_basis.label`; when the Settings discount is not
// applied (the $/credit is already the invoice rate) the API's reason is added, never a what-if.
export function priceBasisText(meta: Meta | null | undefined) {
  const p = meta && meta.price_basis;
  if (!p) return meta ? null : "…";
  if (p.credit_price_usd == null) return "No $ price for this export: dollars read “-”. Pass a credit price to the export.";
  const ignored = discountIgnoredReason(meta);
  const price = priceLabelOf(meta) || `$${Number(p.credit_price_usd).toFixed(2)} per credit`;
  return ignored ? `${price}. Discount not applied: ${ignored}` : price;
}

// ─────────── CTO lens: posture across cost, reliability, performance and security ───────────

type Sev = "critical" | "warn" | "ok" | "not_assessed" | "neutral";
function sevOf(f: Finding | undefined): Sev {
  if (!f) return "neutral";
  const b = bandOf(f);
  if (b === "NOT_ASSESSED" || b === "ERROR") return "not_assessed";
  if (b === "CRITICAL") return "critical";
  if (b === "WARN") return "warn";
  return "ok";
}
const okRows = (s: FetchState) => s.phase === "ready" && s.outcome === "ok_rows";

// The day's spend kind from the metered service: compute, serverless and AI, storage and transfer.
export const DAY_KINDS = ["Warehouse compute", "Serverless, AI & features", "Storage & transfer"];
export function dayKindOf(sku: unknown): string {
  const s = String(sku || "").toUpperCase();
  if (s.startsWith("WAREHOUSE_METERING")) return DAY_KINDS[0];
  if (s.startsWith("STORAGE") || s === "DATA_TRANSFER") return DAY_KINDS[2];
  return DAY_KINDS[1];
}

/** Security checks per area as crit / warn / ok / reference / not run, one thin bar each. */
export interface ScoreRow { tab: string; subtab?: string; label: string }
export const SEC_ROWS: ScoreRow[] = [
  { tab: "access", subtab: "roles", label: "Access › Roles & grants" },
  { tab: "access", subtab: "users", label: "Access › Users & sign-ins" },
  { tab: "access", subtab: "perimeter", label: "Access › Perimeter" },
  { tab: "pii", label: "PII & policies" },
  { tab: "audit", label: "Audit" },
  { tab: "sharing", label: "Sharing & org" },
];
const SC_PARTS: { key: "crit" | "warn" | "ok" | "ref" | "na"; word: string }[] = [
  { key: "crit", word: "critical" }, { key: "warn", word: "warning" }, { key: "ok", word: "ok" }, { key: "ref", word: "reference" }, { key: "na", word: "not run" },
];
function scoreOf(byId: Record<string, Finding>, ids: string[], refIds: string[]) {
  const c = { crit: 0, warn: 0, ok: 0, ref: 0, na: 0 };
  [...ids, ...refIds].forEach((id) => {
    const f = byId[id];
    if (!f) return;
    const b = bandOf(f);
    if (b === "CRITICAL") c.crit += 1;
    else if (b === "WARN") c.warn += 1;
    else if (b === "NOT_ASSESSED" || b === "ERROR") c.na += 1;
    else if (refIds.includes(id) || b === "RANKED" || b === "INVENTORY") c.ref += 1;
    else c.ok += 1;
  });
  return c;
}
export function SecurityScorecard({ byId, goTo, areas = SEC_ROWS }: { byId: Record<string, Finding>; goTo: GoToFn; areas?: ScoreRow[] }) {
  const rows = areas.map((r) => {
    const area = AREA_REGISTRY[r.tab];
    const subs = (area ? area.subtabs : []).filter((s: { key: string }) => !r.subtab || s.key === r.subtab);
    const ids = subs.flatMap((s: { ids?: string[] }) => s.ids || []);
    const refIds = subs.flatMap((s: { refIds?: string[] }) => s.refIds || []);
    return { ...r, c: scoreOf(byId, ids, refIds) };
  }).filter((r) => SC_PARTS.some((p) => r.c[p.key] > 0));
  if (!rows.length) return <div className="chart-note-oneline">No security check in this export.</div>;
  return (
    <div className="sc-list">
      {rows.map((r) => {
        const n = SC_PARTS.reduce((s, p) => s + r.c[p.key], 0);
        const text = [r.c.crit ? `${fmtInt(r.c.crit)} crit` : null, r.c.warn ? `${fmtInt(r.c.warn)} warn` : null, r.c.ok ? `${fmtInt(r.c.ok)} ok` : null,
          r.c.ref ? `${fmtInt(r.c.ref)} ref` : null].filter(Boolean).join(" · ") || "none ran";
        return (
          <button type="button" key={r.label} className="sc-row" onClick={() => goTo({ tab: r.tab, subtab: r.subtab || null })}>
            <span className="sc-label">{r.label}</span>
            <span className="sc-bar" role="img" aria-label={`${r.label}: ${text} of ${n}`}>
              {SC_PARTS.map((p) => (r.c[p.key] > 0
                ? <span key={p.key} className={`sc-seg s-${p.key}`} style={{ flexBasis: `${(100 * r.c[p.key]) / n}%` }} title={`${fmtInt(r.c[p.key])} ${p.word}`} />
                : null))}
            </span>
            <span className="sc-val">{`${text} of ${fmtInt(n)}${r.c.na ? ` · ${fmtInt(r.c.na)} not run` : ""}`}</span>
          </button>
        );
      })}
      <div className="b2-legend">
        {SC_PARTS.map((p) => <span key={p.key} className="b2-legend-item"><span className={`sc-sw s-${p.key}`} />{p.word}</span>)}
      </div>
    </div>
  );
}

/** Security checks per area on fixed columns (CRIT | WARN | REF | ALL), most critical first; bar length = checks in the area. */
export function SecurityAreaTable({ byId, goTo, areas = SEC_ROWS }: { byId: Record<string, Finding>; goTo: GoToFn; areas?: ScoreRow[] }) {
  const rows = areas.map((r) => {
    const area = AREA_REGISTRY[r.tab];
    const subs = (area ? area.subtabs : []).filter((s: { key: string }) => !r.subtab || s.key === r.subtab);
    const ids = subs.flatMap((s: { ids?: string[] }) => s.ids || []);
    const refIds = subs.flatMap((s: { refIds?: string[] }) => s.refIds || []);
    const c = scoreOf(byId, ids, refIds);
    return { ...r, c, all: c.crit + c.warn + c.ok + c.ref + c.na };
  }).filter((r) => r.all > 0).sort((a, b) => b.c.crit - a.c.crit || b.c.warn - a.c.warn);
  if (!rows.length) return <div className="chart-note-oneline">No security check in this export.</div>;
  const max = Math.max(...rows.map((r) => r.all));
  const tot = rows.reduce((s, r) => ({ crit: s.crit + r.c.crit, ok: s.ok + r.c.ok, na: s.na + r.c.na, all: s.all + r.all }), { crit: 0, ok: 0, na: 0, all: 0 });
  const n = (v: number) => (v ? fmtInt(v) : "–");
  return (
    <div className="cx-sec" role="table" aria-label="Security checks by area">
      <div className="cx-sec-tr cx-sec-th" role="row">
        <span role="columnheader">Area</span><span aria-hidden="true" />
        <span role="columnheader" className="crit">Crit</span><span role="columnheader">Warn</span><span role="columnheader">Ref</span><span role="columnheader">All</span>
      </div>
      {rows.map((r) => (
        <button type="button" role="row" key={r.label} className="cx-sec-tr" onClick={() => goTo({ tab: r.tab, subtab: r.subtab || null })}>
          <span role="cell" className="cx-sec-name">{r.label.replace(/^Access › /, "")}</span>
          <span role="cell" className="cx-sec-bar" aria-hidden="true">
            {(["crit", "warn", "ok", "ref", "na"] as const).map((k) => (r.c[k] > 0
              ? <span key={k} className={`sc-seg s-${k}`} style={{ width: `${(100 * r.c[k]) / max}%` }} /> : null))}
          </span>
          <span role="cell" className="crit">{n(r.c.crit)}</span><span role="cell">{n(r.c.warn)}</span>
          <span role="cell">{n(r.c.ref)}</span><span role="cell" className="all">{fmtInt(r.all)}</span>
        </button>
      ))}
      <div className="cx-sec-foot">{`${fmtInt(tot.crit)} critical of ${fmtInt(tot.all)} checks across ${fmtInt(rows.length)} areas · ${tot.ok ? `${fmtInt(tot.ok)} ok` : "none passed outright"}${tot.na ? ` · ${fmtInt(tot.na)} not run` : ""}`}</div>
    </div>
  );
}

/** "246 of 248 checks ran · 137 critical · …": the one ran count (meta) and every check's band. */
export function ChecksRanStrip({ meta, byId, goTo }: { meta: Meta | null; byId: Record<string, Finding>; goTo: GoToFn }) {
  const ran = ranCountsOf(meta);
  const all = Object.values(byId);
  // Same rule as the ran count: a check whose every row is not assessed did not run, whatever its band.
  const didNotRun = (f: Finding) => ["NOT_ASSESSED", "ERROR"].includes(bandOf(f)) || (!!f.not_assessed && f.not_assessed.code === "all_rows_not_assessed");
  const n = (bands: string[]) => all.filter((f) => !didNotRun(f) && bands.includes(bandOf(f))).length;
  const notRun = all.filter(didNotRun);
  const reasons = new Map<string, number>();
  notRun.forEach((f) => { const r = (f.not_assessed && f.not_assessed.label) || "did not run"; reasons.set(r, (reasons.get(r) || 0) + 1); });
  const top = [...reasons.entries()].sort((a, b) => b[1] - a[1])[0];
  return (
    <div className="nj-strip">
      <span className="nj-count">{ran ? `${fmtInt(ran.assessed)} of ${fmtInt(ran.total)} ${ran.unit} ran` : "…"}</span>
      {all.length > 0 && <span className="nj-count">{`${fmtInt(n(["CRITICAL"]))} critical · ${fmtInt(n(["WARN"]))} warning · ${fmtInt(n(["OK"]))} ok · ${fmtInt(n(["RANKED", "INVENTORY"]))} reference`}</span>}
      {notRun.length > 0 && top && <span className="nj-pill">{`– ${fmtInt(notRun.length)} not assessed${top[1] === notRun.length ? `: ${top[0]}` : `, most: ${top[0]}`}`}</span>}
      <span className="nj-spacer" />
      <button type="button" className="ck-link" onClick={() => goTo({ tab: "coverage" })}>{"Coverage & gaps →"}</button>
    </div>
  );
}

// Failed runs grouped by `keyOf` as ranked rows: the top 6, then the rest as one grey "Other (n)" row.
function failedRankRows(rows: Row[], keyOf: (r: Row) => string | null, noKey: string): CxBarItem[] {
  const m = new Map<string, number>();
  rows.forEach((r) => {
    const v = numOrZero(r.failed_runs);
    if (v <= 0) return;
    const k = keyOf(r) || noKey;
    m.set(k, (m.get(k) || 0) + v);
  });
  const all = [...m.entries()].sort((a, b) => b[1] - a[1]);
  const total = all.reduce((s, e) => s + e[1], 0);
  const share = (v: number) => fmtShare(pctOf(v, total));
  const cut = all.length === 7 ? 7 : 6;
  const items: CxBarItem[] = all.slice(0, cut).map(([k, v]) => ({ key: k, label: k, value: v, valueText: fmtInt(v), share: share(v) }));
  const rest = all.slice(cut);
  if (rest.length) {
    const v = rest.reduce((s, e) => s + e[1], 0);
    items.push({ key: "__other__", label: `Other (${fmtInt(rest.length)})`, value: v, valueText: fmtInt(v), share: share(v), tone: "other" });
  }
  return items;
}

export function CtoOverview({ filters, meta, findingsById, goTo, role, roleAreas }: {
  filters: Filters; meta: Meta | null; findingsById: Record<string, Finding> | null; goTo: GoToFn; role: string | null; roleAreas?: string[] | null;
}) {
  useNames();
  React.useEffect(() => { IgnoredFilterTracker.reset(); }, []);
  const acct = filters.accountIds;
  const byId: Record<string, Finding> = findingsById || {};
  const findingsReady = Object.keys(byId).length > 0;

  const dayKindAgg = useFindingAgg("cost_dollarized_by_service_day", filters.window, acct, ["usage_date", "sku_name"], "sum", COST_MONEY_COL);
  const periodState = useFindingData("cost_period_over_period", filters.window, acct);
  const failState = useFindingData("sf_task_failures", filters.window, acct, 5000);
  const slotAgg = useFindingAgg("query_queuing_waits", filters.window, acct, ["warehouse_id"], "sum", "waiting_at_capacity_ms_sum");
  const ccAlloc = useCostCenterAllocation(filters);
  const { actions, ready: actionsReady, wt, worklist } = useActions(byId, roleAreas, filters);
  const ranked = rankActions(actions);

  // Spend, and spend by day and kind; the discount applies once, to every figure.
  const dk = okRows(dayKindAgg) ? dayKindAgg.data! : null;
  const disc = dk ? numOrZero(dk.discount_pct) : 0;
  const dayRows: { day: string; kind: string; value: number }[] | null = dk ? (dk.groups || []).map((g: { key: any[]; value: number }) => ({ day: String(g.key[0]).slice(0, 10), kind: dayKindOf(g.key[1]), value: numOrZero(g.value) * (1 - disc) })) : null;
  const spend = dk ? aggTotal(dk) : null;
  const movers = okRows(periodState) ? buildSpendMovers(periodState.data!.rows, periodState.data!.discount_pct) : null;
  const delta = movers && movers.totalPrev > 0 ? movers.totalDelta : null;
  const deltaPct = movers && movers.totalPrev > 0 ? (movers.totalDelta / movers.totalPrev) * 100 : null;
  const partialDay = (meta && meta.cost_cutoff && meta.cost_cutoff.partial_day) || null;

  // Cost: possible waste as a share of spend, never added to it.
  const wastePct = wt.waste.usd != null ? pctOf(wt.waste.usd, spend) : null;
  const topWaste = worklist.filter((w) => w.unit === "waste" && w.ran && w.isFlagged && w.usd != null && w.usd > 0).sort((a, b) => b.usd! - a.usd!)[0];

  // Reliability: failed runs of all runs, from the task check's own rows.
  const tf = byId.sf_task_failures;
  const fRows = okRows(failState) ? withoutTotalRows(failState.data!.rows).filter((r) => r.status !== "NOT_ASSESSED") : null;
  const runs = fRows ? fRows.reduce((s, r) => s + numOrZero(r.runs), 0) : 0;
  const failed = fRows ? fRows.reduce((s, r) => s + numOrZero(r.failed_runs), 0) : 0;
  const byErr = new Map<string, number>();
  (fRows || []).forEach((r) => { if (r.last_error_code && numOrZero(r.failed_runs) > 0) byErr.set(String(r.last_error_code), (byErr.get(String(r.last_error_code)) || 0) + numOrZero(r.failed_runs)); });
  const topErr = [...byErr.entries()].sort((a, b) => b[1] - a[1])[0];
  const silent = byId.sf_task_silent_failures;
  const tfAff = tf && tf.affected;

  // Performance: time queries waited for a slot, by warehouse (seconds).
  const qw = byId.query_queuing_waits;
  const slotGroups: { id: any; s: number }[] | null = okRows(slotAgg) ? (slotAgg.data!.groups || []).map((g: { key: any[]; value: number }) => ({ id: g.key[0], s: numOrZero(g.value) / 1000 })).filter((g: { s: number }) => g.s > 0) : null;
  const slotTotal = okRows(slotAgg) ? numOrZero(slotAgg.data!.total_value) / 1000 : null;
  const slotTop = slotGroups && slotGroups.length ? [...slotGroups].sort((a, b) => b.s - a.s)[0] : null;
  const sd = byId.sf_task_duration_regression;

  // Security: people with no MFA; PUBLIC's reach and broad grants as the one line.
  const mfa = byId.sf_sec_users_without_mfa;
  const pub = byId.sf_gov_public_role_grants;
  const broad = byId.access_broad_grants;
  const aff = (f: Finding | undefined) => (f && f.affected && f.affected.total ? f.affected : null);
  const naReason = (f: Finding | undefined) => (f ? ((f.not_assessed && f.not_assessed.label) || "did not run") : (findingsReady ? "not in this export" : undefined));

  const sev = {
    cost: wt.waste.usd == null ? "not_assessed" as Sev : wt.waste.flagged > 0 ? "warn" as Sev : "ok" as Sev,
    rel: sevOf(tf), perf: sevOf(qw), sec: sevOf(mfa),
  };
  const critAreas = Object.values(sev).filter((s) => s === "critical").length;
  const settled = dayKindAgg.phase !== "loading" && periodState.phase !== "loading" && findingsReady && actionsReady;
  const unpricedSpend = isUnpricedAgg(dk);
  const lede = !settled ? "…" : spend == null ? (unpricedSpend ? NO_PRICE_LEDE : "Spend could not be assessed for this export.")
    : [deltaPct != null && Math.abs(deltaPct) >= 0.5
        ? `Spend ${deltaPct >= 0 ? "rose" : "fell"} ${fmtShare(Math.abs(deltaPct))} to ${fmtMoney(spend, 0)}.`
        : `Spend was ${fmtMoney(spend, 0)} over the last ${filters.window} days.`,
      `${fmtInt(critAreas)} of the 4 areas ${critAreas === 1 ? "is" : "are"} critical, and ${fmtInt(ranked.week.length)} of ${fmtInt(actions.length)} actions are worth doing this week.`].join(" ");

  // Spend by day: weekday and weekend averages over full days only.
  const dayTotals = new Map<string, number>();
  (dayRows || []).forEach((r) => dayTotals.set(r.day, (dayTotals.get(r.day) || 0) + r.value));
  const full = fillGaps(dayTotals).filter((d) => d.day !== partialDay);
  const avg = (xs: number[]) => (xs.length ? xs.reduce((s, v) => s + v, 0) / xs.length : null);
  const isWeekend = (d: string) => { const w = new Date(`${d}T00:00:00Z`).getUTCDay(); return w === 0 || w === 6; };
  const wdAvg = avg(full.filter((d) => !isWeekend(d.day)).map((d) => d.value));
  const weAvg = avg(full.filter((d) => isWeekend(d.day)).map((d) => d.value));
  const allDays = fillGaps(dayTotals).map((d) => d.day);

  const recon = ccAlloc.data && ccAlloc.data.reconciliation ? ccAlloc.data.reconciliation : null;
  const tie = reconciliationLine(recon);
  const failRows = fRows || [];

  return (
    <div>
      <PageIntro guideTab="overview" overline={pageEyebrow(role, "Overview", meta, filters.window)} title="Overview" verdict={lede} scope={MONEY_SCOPE} />
      <FreshnessLine findingsById={byId} goTo={goTo} />
      <KpiRow>
        <IssueTile label="Cost" loading={!findingsReady || dayKindAgg.phase === "loading"} status={sev.cost}
          headline={wastePct != null ? fmtShare(wastePct) : null} unit="of spend is possible waste"
          missingReason={wt.waste.usd == null ? "none of the waste checks ran" : notAssessedText(dayKindAgg.data)}
          base={wt.waste.usd != null && spend != null ? `${fmtMoney(wt.waste.usd, 0)} of ${fmtMoney(spend, 0)}, flagged by ${fmtInt(wt.waste.flagged)} of ${fmtInt(wt.waste.ran)} checks.` : null}
          cause={topWaste ? `Largest: ${topWaste.title}, ${fmtMoney(topWaste.usd, 0)}${topWaste.affected ? ` on ${fmtInt(topWaste.affected.flagged)} of ${fmtInt(topWaste.affected.total)} ${topWaste.affected.noun}` : ""}.` : null}
          onOpen={() => goTo({ tab: "waste" })} openLabel="Waste & savings →" />
        <IssueTile label="Reliability" loading={!findingsReady || failState.phase === "loading"} status={sev.rel}
          headline={runs > 0 ? fmtShare(pctOf(failed, runs)) : null} unit="of task runs failed"
          missingReason={naReason(tf) || notAssessedText(failState.data)}
          base={runs > 0 ? `${fmtInt(failed)} of ${fmtInt(runs)} runs${tfAff ? `, across ${fmtInt(tfAff.flagged)} of ${fmtInt(tfAff.total)} ${tfAff.noun}` : ""}.` : null}
          cause={[topErr ? `Error ${topErr[0]} causes ${fmtShare(pctOf(topErr[1], failed))} of the failures.` : null,
            aff(silent) ? `${fmtInt(aff(silent)!.flagged)} of ${fmtInt(aff(silent)!.total)} ${aff(silent)!.noun} alert no one.` : null].filter(Boolean).join(" ") || null}
          onOpen={() => goTo({ tab: "tasks", subtab: "failures" })} openLabel="Tasks & pipelines →" />
        <IssueTile label="Performance" loading={!findingsReady || slotAgg.phase === "loading"} status={sev.perf}
          headline={slotTotal != null ? fmtDuration(slotTotal) : null} unit="queries waited for a slot"
          missingReason={naReason(qw) || notAssessedText(slotAgg.data)}
          base={slotTop && slotTotal ? `${whLabel(slotTop.id)} is ${fmtDuration(slotTop.s)} of it, ${fmtShare(pctOf(slotTop.s, slotTotal))}.` : null}
          cause={aff(sd) ? `${fmtInt(aff(sd)!.flagged)} of ${fmtInt(aff(sd)!.total)} ${aff(sd)!.noun} ran slower than the period before.` : null}
          onOpen={() => goTo({ tab: "queries", subtab: "waiting" })} openLabel="Queries →" />
        <IssueTile label="Security" loading={!findingsReady} status={sev.sec}
          headline={aff(mfa) ? fmtShare(pctOf(aff(mfa)!.flagged, aff(mfa)!.total)) : null} unit="of users have no MFA"
          missingReason={naReason(mfa)}
          base={aff(mfa) ? `${fmtInt(aff(mfa)!.flagged)} of ${fmtInt(aff(mfa)!.total)} ${aff(mfa)!.noun}, as of the export.` : null}
          cause={[aff(pub) ? `The PUBLIC role can reach ${fmtInt(aff(pub)!.flagged)} of ${fmtInt(aff(pub)!.total)} ${aff(pub)!.noun}.` : null,
            aff(broad) ? `${fmtInt(aff(broad)!.flagged)} broad ${aff(broad)!.noun}.` : null].filter(Boolean).join(" ") || null}
          onOpen={() => goTo({ tab: "access", subtab: "users" })} openLabel="Access →" />
      </KpiRow>

      <DoTheseFirst actions={actions} ready={actionsReady} filters={filters} goTo={goTo} />

      <div className="cj-charts-2 cx-top">
        <SpendMoversCard periodState={periodState} filters={filters} meta={meta}
          title={delta != null ? `Why spend is ${delta >= 0 ? "up" : "down"}` : "Why spend moved"}
          sub={`Change vs the previous ${filters.window} days, by service`} link="Cost › Trend →" onLink={() => goTo({ tab: "cost", subtab: "trend" })} />
        <PatternCard title="Why task runs fail" sub={failed > 0 ? `${fmtInt(failed)} failed runs, by each task's last error code, then by compute` : "Failed runs, by error code and compute"}
          link="Tasks › Failures →" onLink={() => goTo({ tab: "tasks", subtab: "failures" })}>
          {fRows ? (failed > 0 ? (
            <div className="cx-fail">
              {(() => {
                const byCode = failedRankRows(failRows, (r) => (r.last_error_code ? `Error ${r.last_error_code}` : null), "No error code");
                const byCompute = failedRankRows(failRows, (r) => computeWord(r), "Unknown compute");
                return (
                  <>
                    <div className="cx-eyebrow">{`By last error code · ${plural(byCode.length, "code")}`}</div>
                    <CxBars items={byCode} ariaLabel="Failed runs by error code" labelWidth={170} />
                    <div className="cx-eyebrow">{"By compute"}</div>
                    <CxBars items={byCompute} ariaLabel="Failed runs by compute" labelWidth={170} />
                  </>
                );
              })()}
            </div>
          ) : <div className="chart-note-oneline">{`No failed task runs in ${windowShortLabel(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days) || `the last ${filters.window} days`}.`}</div>)
            : <ChartNote state={failState} label="sf_task_failures" />}
        </PatternCard>
      </div>

      <div className="cj-charts-2 cx-top">
        <PatternCard title="Where queries wait" sub={slotTotal != null ? `${fmtDuration(slotTotal)} waiting for a slot, by warehouse. A full warehouse: add clusters or spread the load.` : "Waiting for a slot, by warehouse"}
          link="Queries › Waiting →" onLink={() => goTo({ tab: "queries", subtab: "waiting" })}>
          {slotGroups ? (slotGroups.length ? (
            <div>
              <CxBars ariaLabel="Time waiting for a slot, by warehouse" labelWidth={190}
                items={[...slotGroups].sort((a, b) => b.s - a.s).slice(0, 6).map((g) => ({ key: String(g.id), label: whLabel(g.id), value: g.s, valueText: fmtDuration(g.s), share: fmtShare(pctOf(g.s, slotTotal)) }))} />
              {slotGroups.length > 6 && <div className="cx-moved-note">{`${fmtInt(slotGroups.length - 6)} more warehouse${slotGroups.length - 6 === 1 ? "" : "s"} wait less and share the rest.`}</div>}
            </div>
          ) : <div className="chart-note-oneline">{noDataText(meta, filters.window)}</div>) : <ChartNote state={slotAgg} label="query_queuing_waits" />}
        </PatternCard>
        <PatternCard title="Security checks by area" sub="Checks that ran · most critical first · bar length = checks in the area" link="Access →" onLink={() => goTo({ tab: "access" })}>
          {findingsReady ? <SecurityAreaTable byId={byId} goTo={goTo} /> : <div className="chart-note-oneline">…</div>}
        </PatternCard>
      </div>

      <div className="cto-spend-row">
        <PatternCard title="Spend by day, by kind" sub={`${windowShortLabel(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days) || `last ${filters.window} days`}${partialDay ? " · the last day is partial" : ""}`}>
          {unpricedSpend ? <div className="chart-note-oneline">– {NO_PRICE_READING}</div> : dayRows ? (
            <div>
              <DayKindTimeline rows={dayRows} days={allDays} kinds={DAY_KINDS} partialDay={partialDay} height={180}
                kindColors={{ [DAY_KINDS[0]]: "var(--c1)", [DAY_KINDS[1]]: "var(--c2)", [DAY_KINDS[2]]: "var(--c-other)" }}
                valueFmt={(v) => fmtMoney(v, 0)} ariaLabel="Spend by day, by kind" />
              {wdAvg != null && weAvg != null && <div className="pc-foot">{`Weekdays average ${fmtMoney(wdAvg, 0)}, weekends ${fmtMoney(weAvg, 0)}`}</div>}
            </div>
          ) : <ChartNote state={dayKindAgg} label="cost_dollarized_by_service_day" />}
        </PatternCard>
        <PatternCard title="Ties to the bill" sub="From metered usage to what each cost center carries" link="Chargeback & tags →" onLink={() => goTo({ tab: "cost", subtab: "chargeback" })}>
          {recon && recon.spend_usd != null ? (
            <div>
              <ReconChain steps={[
                { key: "spend", label: "Metered", value: recon.spend_usd },
                { key: "billed", label: "Billed to split", value: recon.billing_usd },
                { key: "split", label: "Allocated", value: recon.rollup_usd },
              ]} />
              <TieLine tie={tie} />
            </div>
          ) : <div className="chart-note-oneline">{ccAlloc.phase === "loading" ? "…" : "The cost-center split is not in this export."}</div>}
        </PatternCard>
      </div>

      <div className="nj-strip"><RanLine meta={meta} byId={byId} goTo={goTo} /></div>
      <PageFooter meta={meta} tab="overview" />
    </div>
  );
}

export function OverviewContent(props: OverviewProps) {
  return props.role === "governance" ? <GovOverviewContent {...props} /> : <FinopsOverviewContent {...props} />;
}

AreaContent.register("overview", null, OverviewContent);
