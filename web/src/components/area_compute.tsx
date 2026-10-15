// web/src/components/area_compute.tsx -- the Warehouses and Queries sub-tabs: a headline row (the
// issue as a % or the flagged $), the chart that shows its driver, and a click into the rows. Each
// figure reads the check's own rows; a check that did not run reads "–" and why, never 0. Spend,
// waste and saving figures sit side by side and are never added together.
import React from "react";
import "../styles/css/p_area_compute.css";
import { fmtCredits, fmtDate, fmtDayShort, fmtDuration, fmtInt, fmtMoney } from "../format";
import { GrainSwitch, GrainLines, partialMonths, fmtMonth } from "./grain";
import type { Grain } from "./grain";
import { MultiLine } from "./charts";
import { FLAGGED_STATUSES, groupsToRows, aggTotal, numOrZero, useFindingAgg, useFindingData } from "./hooks";
import type { AggOpts } from "./hooks";
import { ChartCard, KindChip, StatusPill, bandOf } from "./primitives";
import { COST_MONEY_COL, WASTE_ITEMS } from "./tab_registry";
import { buildWasteEntry, wasteTotal } from "./waste_total";
import { DrillTable, MiniBar, SplitBar } from "./drill_table";
import { Columns, rowLabelWidth } from "./charts_more";
import { chartLabel, truncateLeft, useChartWidth } from "./charts";
import { notAssessedText } from "./scope";
import { REASON_INFO } from "./labels";
import { partialBarKeys, scrollToAnchor, windowShortLabel } from "./overview_tile";
import { rowLabelOf, withoutTotalRows } from "../tabs/tab_area";
import { DrawerBus, useDrawer } from "./drawer";
import { IssueTile, ShareBarList, StackedShareBar, StatusBars, DayKindTimeline, statusBarColor, WeekHourHeatmap, WEEKDAYS_ISO, emptyWeekHourGrid, fmtShare, pctOf } from "./blocks";
import type { ShareItem, ShareSegment, StatusBarItem, WeekHourGrid } from "./blocks";
import { ClusterDots } from "./blocks_2";
import { SUSPEND_BANDS, TopOffenders, suspendText } from "./wh_idle_detail";
import type { Offender } from "./wh_idle_detail";
import { QueryPatternTable, WarehouseLoadBands, aggNote, useQueryPatterns, useWarehouseLoad } from "./de_blocks";
import { WarehouseSpendMonths, windowDayList } from "./run_blocks";
import { QTrend } from "./query_trend";
import type { ApPageProps } from "./area_pages";
import type { FetchState, Finding, Row } from "../types";

// ═══════════════════════ shared plumbing ═══════════════════════

type TileStatus = "critical" | "warn" | "ok" | "not_assessed" | "neutral";

// A check homed on another tab (the monitor coverage on Idle) is read from the full index.
function findingOf(p: ApPageProps, id: string): Finding | null {
  return (p.findings || []).find((f) => f.query_id === id) || (p.allFindingsIndex ? p.allFindingsIndex[id] || null : null);
}

/** One check's rows for this page, or null while it loads / when it did not return rows. */
function useRows(p: ApPageProps, id: string, statuses?: string[] | null) {
  const f = findingOf(p, id);
  const state = useFindingData(f ? id : null, p.filters.window, p.filters.accountIds, 5000, statuses) as FetchState;
  return { id, f, state, flaggedOnly: false, group: null as string[] | null, value: null as string | null };
}
type Src = ReturnType<typeof useRows>;

/** Only the check's flagged rows, fetched server-side; none flagged reads as an empty list. */
function useFlaggedRows(p: ApPageProps, id: string): Src {
  return { ...useRows(p, id, FLAGGED_STATUSES), flaggedOnly: true };
}

// `off` skips the fetch (a drill-down that opens on click); `flaggedOnly` reads an empty flagged set
// as "no rows", not as a filter that left everything out.
function useAgg(p: ApPageProps, id: string, group: string[], agg: string, value: string | null, opts?: AggOpts & { off?: boolean; flaggedOnly?: boolean }): Src {
  const f = findingOf(p, id);
  const state = useFindingAgg(f && !(opts && opts.off) ? id : null, p.filters.window, p.filters.accountIds, group, agg, value, opts) as FetchState;
  return { id, f, state, flaggedOnly: !!(opts && opts.flaggedOnly), group, value };
}

/** The check's rows; for an aggregate source, one row per group (see groupsToRows). */
function rowsOf(s: Src): Row[] | null {
  if (s.flaggedOnly && s.state.phase === "ready" && s.state.outcome === "ok_empty_filters") return [];
  if (!(s.state.phase === "ready" && s.state.outcome === "ok_rows" && s.state.data)) return null;
  return s.group ? groupsToRows(s.state.data, s.group, s.value) : withoutTotalRows(s.state.data.rows);
}
function groupsOf(s: Src): { key: any[]; value: number }[] | null {
  return s.state.phase === "ready" && s.state.outcome === "ok_rows" && s.state.data ? (s.state.data.groups || []) : null;
}
/** The groups with one of their `also` sums as the value. */
function alsoGroups(s: Src, col: string): { key: any[]; value: number }[] | null {
  const g = groupsOf(s);
  return g ? g.map((x: any) => ({ key: x.key, value: x.also ? x.also[col] : null })) : null;
}
function discOf(s: Src): number {
  return s.state.data ? numOrZero(s.state.data.discount_pct) : 0;
}
function loading(s: Src) { return !!s.f && s.state.phase === "loading"; }

/** Why a source has no rows, in one line ("…" while loading); null when it has rows. */
function noteOf(s: Src, p: ApPageProps): string | null {
  if (!s.f) return "– Not in this export: run the export again.";
  const st = s.state;
  if (s.flaggedOnly && st.phase === "ready" && st.outcome === "ok_empty_filters") return null;
  if (st.phase === "loading") return "…";
  if (st.phase === "error") return `– ${st.error || "Could not load"}`;
  if (st.outcome === "ok_rows") return null;
  if (st.outcome === "not_assessed") return `– ${notAssessedText(st.data)}`;
  if (st.outcome === "error") return `– ${(st.data && st.data.error) || "The check failed."}`;
  if (st.outcome === "ok_empty_window") return `No data for this in ${rangeOf(p) || `the last ${p.filters.window} days`}`;
  if (st.outcome === "ok_empty_filters") {
    return st.data && st.data.scope && st.data.scope.none_flagged ? "Nothing flagged in this window." : "Rows exist, but the current filters exclude all of them.";
  }
  return "–";
}
/** The short reason a tile's figure is missing. */
function missingOf(s: Src, p: ApPageProps): string {
  const n = noteOf(s, p);
  return n ? n.replace(/^– /, "").replace(/^Not assessed: /, "") : "";
}
function rangeOf(p: ApPageProps) {
  return windowShortLabel(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
}

function statusOf(f: Finding | null | undefined): TileStatus {
  if (!f) return "not_assessed";
  const b = bandOf(f);
  if (b === "CRITICAL") return "critical";
  if (b === "WARN") return "warn";
  if (b === "OK") return "ok";
  if (b === "NOT_ASSESSED" || b === "ERROR") return "not_assessed";
  return "neutral";
}
const isFlagged = (r: Row) => r.status === "CRITICAL" || r.status === "WARN";

function openCheck(p: ApPageProps, id: string) {
  return () => p.goTo({ tab: p.area, subtab: p.subtab, focusQueryId: id });
}

/** A chart card, or its one-line note when the source has no rows. */
function Panel({ p, src, title, subtitle, children }: { p: ApPageProps; src: Src; title: string; subtitle?: string; children?: React.ReactNode }) {
  const note = noteOf(src, p);
  return (
    <ChartCard title={title} subtitle={subtitle} onOpenCheck={src.f ? openCheck(p, src.id) : null} takeaway={null}>
      {note ? <div className="chart-note-oneline">{note}</div> : children}
    </ChartCard>
  );
}

function Row2({ children }: { children?: React.ReactNode }) { return <div className="cj-charts-2">{children}</div>; }
function Tiles({ children }: { children?: React.ReactNode }) { return <div className="summary-tile-row compact ac-tiles">{children}</div>; }

/** "WH_ETL (1001)": a warehouse always reads name (id). */
function whLabel(r: Row, p: ApPageProps): string {
  return rowLabelOf(r, r.warehouse_name ? "warehouse_name" : r.warehouse_id != null ? "warehouse_id" : "warehouse", p.dims) || "(no warehouse)";
}
function whKey(r: Row): string { return `${r.account_id ?? ""}|${r.warehouse_id ?? r.warehouse_name ?? r.warehouse ?? ""}`; }

/** Warehouses in scope: the one base every warehouse count on these pages reads. */
function warehousePopulation(p: ApPageProps, ...seen: (number | null | undefined)[]): number | null {
  const maps = p.dims && (p.dims as any).warehouses;
  let n = 0;
  if (maps && typeof maps.forEach === "function") {
    const ids = p.filters.accountIdSet;
    maps.forEach((w: Row) => { if (!w.deleted_on && !w.delete_time && (!ids || !ids.size || ids.has(String(w.account_id)))) n += 1; });
  }
  const best = Math.max(n, ...seen.map((x) => numOrZero(x)));
  return best > 0 ? best : null;
}

/** Sum of value per key, keeping the first row's label. */
function sumBy<T extends string>(rows: Row[], key: (r: Row) => string, label: (r: Row) => string, cols: Record<T, (r: Row) => number>) {
  const m = new Map<string, { name: string; rows: Row[] } & Record<T, number>>();
  rows.forEach((r) => {
    const k = key(r);
    let cur = m.get(k);
    if (!cur) {
      cur = { name: label(r), rows: [] } as any;
      (Object.keys(cols) as T[]).forEach((c) => { (cur as any)[c] = 0; });
      m.set(k, cur!);
    }
    cur!.rows.push(r);
    (Object.keys(cols) as T[]).forEach((c) => { (cur as any)[c] += numOrZero(cols[c](r)); });
  });
  return [...m.values()];
}
function worstStatus(rows: Row[]): string {
  if (rows.some((r) => r.status === "CRITICAL")) return "CRITICAL";
  if (rows.some((r) => r.status === "WARN")) return "WARN";
  if (rows.length && rows.every((r) => r.status === "NOT_ASSESSED")) return "NOT_ASSESSED";
  return "OK";
}

/** A ranked list that collapses to one line when it holds a single row. */
function RankedOrLine({ items, valueFmt, unitLabel, onBarClick, emptyText, ariaLabel, n = 8, max }: {
  items: StatusBarItem[]; valueFmt?: (v: number) => string; unitLabel?: string;
  onBarClick?: ((it: StatusBarItem) => void) | null; emptyText: string; ariaLabel: string; n?: number; max?: number;
}) {
  if (!items.length) return <div className="chart-note-oneline">{emptyText}</div>;
  if (items.length === 1) {
    const it = items[0];
    return <div className="chart-note-oneline ac-one-line"><strong>{it.name}</strong>{` · ${it.valueText || (valueFmt ? valueFmt(it.value) : fmtInt(it.value))}`}</div>;
  }
  return <StatusBars items={items} n={n} valueFmt={valueFmt} unitLabel={unitLabel} onBarClick={onBarClick} ariaLabel={ariaLabel} max={max} />;
}

/** A finding's own headline money, or null when it has none. */
function moneyOf(f: Finding | null | undefined): number | null {
  const v = f && f.money ? f.money.usd : null;
  return v != null && Number.isFinite(Number(v)) ? Number(v) : null;
}
/** "-" and why for a money tile whose check ran but priced nothing, else the $. */
function moneyHeadline(f: Finding | null | undefined): { headline: string | null; why?: string } {
  if (!f) return { headline: null, why: "not in this export" };
  const b = bandOf(f);
  if (b === "NOT_ASSESSED" || b === "ERROR") return { headline: null, why: (f.not_assessed && f.not_assessed.label) || "did not run" };
  if (b === "OK") return { headline: "None", why: undefined };
  const v = moneyOf(f);
  if (v === null) return { headline: null, why: f.money_reason === "unpriced" ? "flagged, not priced" : "no $ figure" };
  return { headline: fmtMoney(v, 0) };
}
// moneyHeadline's "None" (ran, nothing flagged) reads as words, never a raw "None $".
const savingWords = (h: string) => (h === "None" ? "no possible saving" : `${h} possible saving`);
function affectedOf(f: Finding | null | undefined) {
  const a = f && f.affected;
  return a ? { flagged: numOrZero(a.flagged), total: numOrZero(a.total), noun: String(a.noun || "") } : null;
}

const minFmt = (v: number) => `${fmtInt(Math.round(v))} min`;
const usdFmt = (v: number) => fmtMoney(v, 0);
// Above 0 but under 0.05 reads "<0.1", never "0.0", so real activity never looks like none.
const secFmt = (v: number) => (v > 0 && v < 0.05 ? "<0.1 s" : v >= 120 ? `${(v / 60).toFixed(1)} min` : `${v >= 10 ? Math.round(v) : v.toFixed(1)} s`);
const smallFmt = (v: number, some: boolean) => ((v > 0 && v < 0.05) || (some && v === 0) ? "<0.1" : v.toFixed(1));

// ═══════════════════════ Warehouses > Idle & settings ═══════════════════════

function WhIdle(p: ApPageProps) {
  const idle = useRows(p, "sf_wh_idle_minutes");
  const tune = useRows(p, "sf_wh_auto_suspend_tuning");
  const cfg = useRows(p, "sf_wh_config_current");
  const mon = useRows(p, "sf_cost_resource_monitor_coverage");
  const keep = useRows(p, "sf_wh_keepalive_pollers");
  const churn = useRows(p, "sf_wh_resume_churn");
  const last = useRows(p, "sf_wh_last_activity");
  const over = useRows(p, "sf_wh_oversized");
  const under = useRows(p, "sf_wh_undersized");
  const mcs = useRows(p, "sf_wh_multicluster_scaling");

  const idleRows = rowsOf(idle);
  const disc = discOf(idle);
  const priced = !!idleRows && idleRows.some((r) => r.price_basis !== "unpriced" && r.est_usd_list != null);
  const perWh = idleRows ? sumBy(idleRows.filter((r) => r.status !== "NOT_ASSESSED"), whKey, (r) => whLabel(r, p), {
    busy: (r) => r.busy_minutes, idle: (r) => r.idle_minutes, up: (r) => r.up_minutes,
    spend: (r) => numOrZero(r.est_usd_list) * (1 - disc),
    idleUsd: (r) => (r.est_wasted_usd_list != null ? numOrZero(r.est_wasted_usd_list) : numOrZero(r.est_usd_list) * numOrZero(r.idle_share_pct) / 100) * (1 - disc),
  }) : null;
  const spendAll = perWh ? perWh.reduce((s, w) => s + w.spend, 0) : 0;
  const idleUsdAll = perWh ? perWh.reduce((s, w) => s + w.idleUsd, 0) : 0;
  const upAll = perWh ? perWh.reduce((s, w) => s + w.up, 0) : 0;
  const idleMinAll = perWh ? perWh.reduce((s, w) => s + w.idle, 0) : 0;
  // The headline $ is the check's own waste figure, the same one Waste & savings and Actions show.
  const wasteUsd = moneyOf(idle.f);
  const sharePct = priced ? pctOf(wasteUsd ?? idleUsdAll, spendAll) : pctOf(idleMinAll, upAll);
  const ranked = perWh ? [...perWh].sort((a, b) => (priced ? b.idleUsd - a.idleUsd : b.idle - a.idle)) : [];
  const top = ranked[0];
  const topIdlePct = top && top.busy + top.idle > 0 ? pctOf(top.idle, top.busy + top.idle) : null;
  const spendOf = new Map(ranked.map((w) => [w.rows[0] ? whKey(w.rows[0]) : w.name, w.spend]));

  // Snowflake suspends an adaptive warehouse itself: it has no auto-suspend setting, so it is left out here.
  const cfgAll = rowsOf(cfg);
  const cfgRows = cfgAll ? cfgAll.filter((r) => String(r.warehouse_type || "").toUpperCase() !== "ADAPTIVE") : null;
  const adaptiveN = cfgAll && cfgRows ? cfgAll.length - cfgRows.length : 0;
  const suspendOff = cfgRows ? cfgRows.filter((r) => r.auto_stop_minutes == null || numOrZero(r.auto_stop_minutes) <= 0) : null;
  const suspendLong = cfgRows ? cfgRows.filter((r) => numOrZero(r.auto_stop_minutes) > 10) : null;
  // A warehouse the check could not judge is neither covered nor uncovered: left out of count and total.
  const monRows = rowsOf(mon) ? rowsOf(mon)!.filter((r) => r.status !== "NOT_ASSESSED") : null;
  const noMonitor = monRows ? sumBy(monRows, whKey, (r) => whLabel(r, p), { susp: (r) => (r.has_suspend === true ? 1 : 0) }).filter((w) => w.susp === 0) : null;
  const risky = cfgRows ? new Set([...suspendOff!, ...suspendLong!].map(whKey)).size : null;
  // Each count is out of the warehouses its own check saw, the same total as its row in the checks list.
  const cfgPop = cfgRows ? cfgRows.length : null;
  const monPop = monRows ? new Set(monRows.map(whKey)).size : null;

  const tuneSaving = moneyHeadline(tune.f);
  const idleAff = affectedOf(idle.f);
  const tuneRows = rowsOf(tune);
  const tDisc = discOf(tune);
  const tuneBy = new Map((tuneRows || []).map((r) => [`${r.account_id ?? ""}|${r.warehouse_id}`, r]));
  const offenders: Offender[] = ranked.map((w) => {
    const r0 = w.rows[0] || {};
    const t = tuneBy.get(`${r0.account_id ?? ""}|${r0.warehouse_id}`) || null;
    return {
      key: whKey(r0), id: r0.warehouse_id, name: w.name, size: (t && t.warehouse_size) || r0.warehouse_size || null,
      autoSuspendS: t && t.auto_suspend_s != null ? numOrZero(t.auto_suspend_s) : r0.auto_stop_minutes != null ? numOrZero(r0.auto_stop_minutes) * 60 : null,
      busyMin: w.busy, idleMin: w.idle, spendUsd: priced ? w.spend : null,
      busyUsd: priced ? Math.max(w.spend - w.idleUsd, 0) : null, idleUsd: priced ? w.idleUsd : null, status: worstStatus(w.rows), tune: t,
    };
  });
  // Warehouses by their current auto-suspend, counted once each.
  const bands: ShareSegment[] | null = cfgRows ? SUSPEND_BANDS.map((b) => ({
    key: b.key, label: b.label, color: b.color,
    value: cfgRows.filter((r) => b.test(r.auto_stop_minutes == null ? null : numOrZero(r.auto_stop_minutes) * 60)).length,
  })) : null;
  const resumeItems: StatusBarItem[] = (tuneRows || []).filter((r) => numOrZero(r.observed_resumes) > 0)
    .sort((a, b) => numOrZero(b.observed_resumes) - numOrZero(a.observed_resumes))
    .map((r) => ({
      key: whKey(r), name: whLabel(r, p), value: numOrZero(r.observed_resumes), status: r.status,
      valueText: [`${fmtInt(r.observed_resumes)} resumes`, r.resume_p95_s != null ? `p95 ${secFmt(numOrZero(r.resume_p95_s))} to resume` : null,
        r.resume_wait_p95_s != null ? `queries waited p95 ${secFmt(numOrZero(r.resume_wait_p95_s))}` : null].filter(Boolean).join(" · "),
    }));

  // What keeps warehouses up: each is part of the idle $ above, shown on its own and never added to it.
  const kDisc = discOf(keep);
  const keepItems: StatusBarItem[] = (rowsOf(keep) || []).filter((r) => numOrZero(r.poll_runs) > 0).map((r) => {
    const usd = r.est_idle_context_usd_list != null ? numOrZero(r.est_idle_context_usd_list) * (1 - kDisc) : null;
    return {
      key: whKey(r), name: whLabel(r, p), value: usd ?? numOrZero(r.keepalive_credits), status: r.status,
      valueText: [usd != null ? `${fmtMoney(usd, 0)} of idle` : `${fmtInt(Math.round(numOrZero(r.keepalive_credits)))} credits of idle`,
        r.top_poll_every_s != null ? `a poll every ${suspendText(numOrZero(r.top_poll_every_s))}` : null,
        r.top_poll_user_name ? String(r.top_poll_user_name) : null].filter(Boolean).join(" · "),
      title: `${fmtInt(r.poll_runs)} polls, ${fmtShare(numOrZero(r.poll_share_pct))} of its queries · kept up ${fmtInt(Math.round(numOrZero(r.keepalive_hours)))} h`,
    };
  });
  const cDisc = discOf(churn);
  const churnItems: StatusBarItem[] = (rowsOf(churn) || []).filter((r) => numOrZero(r.short_runs) > 0).map((r) => {
    const usd = r.est_idle_context_usd_list != null ? numOrZero(r.est_idle_context_usd_list) * (1 - cDisc) : null;
    const ender = numOrZero(r.by_manual) >= numOrZero(r.short_runs) / 2 ? `suspended by ${r.top_suspend_user_name || "a script"}`
      : numOrZero(r.by_cluster) >= numOrZero(r.short_runs) / 2 ? "extra clusters" : numOrZero(r.by_monitor) >= numOrZero(r.short_runs) / 2 ? "resource monitor" : "auto-suspend";
    return {
      key: whKey(r), name: whLabel(r, p), value: numOrZero(r.short_runs), status: r.status,
      valueText: [`${fmtInt(r.short_runs)} of ${fmtInt(r.runs)} runs`, usd != null ? `${fmtMoney(usd, 0)} minimum` : null, ender].filter(Boolean).join(" · "),
    };
  });

  // The lede, from this page's own numbers.
  const lede = loading(idle) ? "…" : sharePct != null
    ? `${fmtShare(sharePct)} of warehouse ${priced ? "spend" : "up time"} ran no query${top ? `; ${top.name} is the largest share` : ""}.`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const usdOrDash = (r: Row) => { const v = spendOf.get(whKey(r)); return v != null && priced ? fmtMoney(v, 0) : ""; };
  return (
    <div className="ac-page">
      <Tiles>
        <IssueTile
          label="Idle share of warehouse spend" loading={loading(idle)}
          headline={sharePct != null ? fmtShare(sharePct) : null} unit={priced ? "of warehouse $" : "of up time"}
          missingReason={missingOf(idle, p)}
          base={sharePct != null ? `${priced ? `${fmtMoney(wasteUsd ?? idleUsdAll, 0)} possible waste` : `${minFmt(idleMinAll)} idle`}${idleAff ? ` · ${fmtInt(idleAff.flagged)} of ${fmtInt(idleAff.total)} warehouses` : ""}` : null}
          cause={top ? `Most: ${top.name}${topIdlePct != null ? `, ${fmtShare(topIdlePct)} idle` : ""}${priced ? `, ${fmtMoney(top.idleUsd, 0)}` : ""}.` : null}
          status={statusOf(idle.f)} onOpen={() => DrawerBus.open({ id: "sf_wh_idle_minutes" })} openLabel="Open →" />
        <IssueTile
          label="Shorter auto-suspend would save" loading={loading(tune)}
          headline={tuneSaving.headline} missingReason={tuneSaving.why || missingOf(tune, p)}
          base={affectedOf(tune.f) ? `possible saving · ${p.filters.window} d · ${fmtInt(affectedOf(tune.f)!.flagged)} of ${fmtInt(affectedOf(tune.f)!.total)} warehouses` : null}
          cause="Part of the idle $, not added to it. 60 s, or 5 min where the cache is reused."
          status={statusOf(tune.f)} onOpen={() => DrawerBus.open({ id: "sf_wh_auto_suspend_tuning" })} openLabel="Open →" />
        <IssueTile
          label="Auto-suspend off or over 10 min" loading={loading(cfg)}
          headline={risky != null && cfgPop ? fmtShare(pctOf(risky, cfgPop)) : null} unit="of warehouses"
          missingReason={missingOf(cfg, p)}
          base={risky != null && cfgPop ? `${fmtInt(risky)} of ${fmtInt(cfgPop)} warehouses${suspendOff && suspendLong ? ` · ${fmtInt(suspendOff.length)} off · ${fmtInt(suspendLong.length)} over 10 min` : ""}` : null}
          cause={adaptiveN ? `${fmtInt(adaptiveN)} adaptive left out: Snowflake suspends ${adaptiveN === 1 ? "it" : "them"}.` : null}
          // The tile's own counts, not the posture check's worst row (which also covers other settings).
          status={risky == null ? statusOf(findingOf(p, "sf_wh_config_posture")) : suspendOff!.length ? "critical" : risky ? "warn" : "ok"}
          onOpen={() => scrollToAnchor("ac-setup-risk")} openLabel="Setup risk ↓" />
      </Tiles>

      <Panel p={p} src={idle} title="Busy vs idle, by warehouse" subtitle={`${priced ? "ranked by idle $" : "ranked by idle minutes"} · each bar is that warehouse's own up time, split busy / idle · click a row for its rows`}>
        {perWh && (
          <BusyIdleBars
            items={ranked.map((w) => ({
              key: w.rows[0] ? whKey(w.rows[0]) : w.name, id: w.rows[0] ? w.rows[0].warehouse_id : null, name: w.name, busy: w.busy, idle: w.idle,
              money: priced ? w.idleUsd : null, spend: priced ? w.spend : null, status: worstStatus(w.rows),
            }))} />
        )}
      </Panel>

      <Panel p={p} src={idle} title="Top 5 offenders" subtitle={`${priced ? "sorted by idle cost" : "sorted by idle time"} · auto-suspend options are estimates, each on its own · click a name for the detail`}>
        {perWh && <TopOffenders items={offenders} disc={tDisc} windowDays={p.filters.window} />}
      </Panel>

      <Row2>
        <Panel p={p} src={cfg} title="Warehouses by auto-suspend" subtitle={`${cfgPop != null ? `${fmtInt(cfgPop)} warehouses in scope` : "warehouses in scope: –"}${adaptiveN ? ` · ${fmtInt(adaptiveN)} adaptive left out` : ""} · current setting`}>
          {bands && <StackedShareBar segments={bands} valueFmt={(v) => `${fmtInt(v)} of ${fmtInt(cfgRows!.length)} warehouses`} ariaLabel="Warehouses by auto-suspend setting" />}
        </Panel>
        <Panel p={p} src={tune} title="Resumes and resume time" subtitle={`resumes in ${fmtInt(p.filters.window)} days · time to resume and query wait, p95 · a shorter auto-suspend adds resumes`}>
          <RankedOrLine items={resumeItems} unitLabel="resumes" ariaLabel="Resumes by warehouse" emptyText={`No resumes in ${rangeOf(p) || "this window"}.`}
            onBarClick={(it) => { const r = (tuneRows || []).find((x) => whKey(x) === it.key); if (r) DrawerBus.open({ id: "sf_wh_idle_minutes", col: "warehouse_id", val: String(r.warehouse_id), label: it.name }); }} />
        </Panel>
      </Row2>

      <Row2>
        <Panel p={p} src={keep} title="Kept awake by repeated polls" subtitle="a tiny statement that repeats sooner than the auto-suspend · $ is part of the idle $ above, not added to it">
          <RankedOrLine items={keepItems} valueFmt={usdFmt} unitLabel="$" ariaLabel="Warehouses kept awake by polls" emptyText={`No warehouse kept awake by polls in ${rangeOf(p) || "this window"}.`}
            onBarClick={(it) => { const r = (rowsOf(keep) || []).find((x) => whKey(x) === it.key); if (r) DrawerBus.open({ id: "sf_wh_keepalive_pollers", col: "warehouse_id", val: String(r.warehouse_id), label: it.name }); }} />
        </Panel>
        <Panel p={p} src={churn} title="Runs under the 60 s minimum" subtitle="each resume bills at least 60 s · runs that ended sooner, and what ended them · $ is part of the idle $">
          <RankedOrLine items={churnItems} unitLabel="short runs" ariaLabel="Warehouses with runs under 60 seconds" emptyText={`No run under 60 s in ${rangeOf(p) || "this window"}.`}
            onBarClick={(it) => { const r = (rowsOf(churn) || []).find((x) => whKey(x) === it.key); if (r) DrawerBus.open({ id: "sf_wh_resume_churn", col: "warehouse_id", val: String(r.warehouse_id), label: it.name }); }} />
        </Panel>
      </Row2>

      <div id="ac-setup-risk">
        <ChartCard title="Setup risk" subtitle={`${cfgPop != null ? `${fmtInt(cfgPop)} warehouses in scope` : "warehouses in scope: –"} · three settings that keep a warehouse running`} onOpenCheck={() => DrawerBus.open({ id: "sf_wh_config_posture" })} takeaway={null}>
          <div className="ac-multiples">
            <RiskMultiple title="Auto-suspend off" src={cfg} p={p} pop={cfgPop} status="CRITICAL"
              list={suspendOff ? suspendOff.map((r) => ({ name: whLabel(r, p), val: usdOrDash(r) })) : null} />
            <RiskMultiple title="Auto-suspend over 10 min" src={cfg} p={p} pop={cfgPop} status="WARN"
              list={suspendLong ? suspendLong.map((r) => ({ name: whLabel(r, p), val: `${fmtInt(r.auto_stop_minutes)} min` })) : null} />
            <RiskMultiple title="No monitor that suspends" src={mon} p={p} pop={monPop} status="WARN"
              list={noMonitor ? noMonitor.map((w) => ({ name: w.name, val: "" })) : null} />
          </div>
        </ChartCard>
      </div>

      <SettingChanges p={p} tune={tune} cfg={cfg} over={over} under={under} mc={mcs} pop={cfgAll ? cfgAll.length : null} />
      <LastActivity p={p} src={last} />
    </div>
  );
}
(WhIdle as any).ownsLede = true;

/** One 100% bar per warehouse: busy (blue) then idle (sand); the status rides on the dot, not the bar. */
function BusyIdleBars({ items, n = 10 }: {
  items: { key: string; id: any; name: string; busy: number; idle: number; money: number | null; spend: number | null; status: string }[]; n?: number;
}) {
  const [ref, W] = useChartWidth(560);
  const labelW = rowLabelWidth(W);
  const open = useDrawer();
  const list = items.filter((it) => it.busy + it.idle > 0);
  if (!list.length) return <div className="chart-note-oneline">Every warehouse was busy whenever it ran.</div>;
  const shown = list.slice(0, n);
  return (
    <div className="ac-busy" ref={ref}>
      <div className="blk-legend">
        <span className="blk-legend-item"><span className="blk-sw" style={{ background: "var(--c1)" }} />busy</span>
        <span className="blk-legend-item"><span className="blk-sw" style={{ background: "var(--c-other)" }} />idle</span>
        <span className="blk-legend-item"><span className="blk-dot" style={{ background: "var(--st-crit)" }} />critical</span>
        <span className="blk-legend-item"><span className="blk-dot" style={{ background: "var(--st-warn)" }} />warning</span>
      </div>
      {shown.map((it) => {
        const total = it.busy + it.idle;
        const ip = (it.idle / total) * 100;
        const val = it.money != null ? `${fmtMoney(it.money, 0)} · ${fmtShare(ip)} idle${it.spend != null ? ` of ${fmtMoney(it.spend, 0)}` : ""}` : `${fmtShare(ip)} idle`;
        const isOpen = !!open && open.id === "sf_wh_idle_minutes" && open.val === String(it.id);
        return (
          <button type="button" key={it.key} className={`ac-busy-row blk-row-btn${isOpen ? " selected" : ""}`}
            title={`${it.name}: ${minFmt(it.busy)} busy, ${minFmt(it.idle)} idle`} aria-pressed={isOpen}
            onClick={() => DrawerBus.open({ id: "sf_wh_idle_minutes", col: it.id != null ? "warehouse_id" : null, val: it.id != null ? String(it.id) : null, label: it.name })}>
            <span className="ac-busy-label" style={{ flexBasis: labelW }}>
              <span className="blk-dot" style={{ background: statusBarColor(it.status) }} aria-hidden="true" />{truncateLeft(it.name, labelW - 22)}
            </span>
            <span className="ac-busy-track">
              <span style={{ width: `${100 - ip}%`, background: "var(--c1)" }} />
              <span style={{ width: `${ip}%`, background: "var(--c-other)" }} />
            </span>
            <span className="ac-busy-val">{val}</span>
          </button>
        );
      })}
      {list.length > shown.length && <div className="blk-more">{`+${fmtInt(list.length - shown.length)} more not shown`}</div>}
    </div>
  );
}

export function WhIdleDetail({ p, w, tune, onClose }: { p: ApPageProps; w: { name: string; rows: Row[] }; tune: Src; onClose: () => void }) {
  const r0 = w.rows[0] || {};
  const same = (r: Row) => String(r.account_id ?? "") === String(r0.account_id ?? "") && String(r.warehouse_id) === String(r0.warehouse_id);
  const ID = "sf_cost_warehouse_idle_credits_daily";
  // The idle check's rows are per warehouse hour, so they are read summed, never row by row.
  const busyDay = useAgg(p, ID, ["warehouse_id", "usage_date"], "sum", "query_credits", { also: ["idle_credits"] });
  const idleDay = busyDay;
  const busyHour = useAgg(p, ID, ["warehouse_id", "day_of_week", "hour_of_day"], "sum", "query_credits", { also: ["idle_credits"] });
  const idleHour = busyHour;
  const mine = (g: { key: any[] }) => String(g.key[0]) === String(r0.warehouse_id);
  const bd = groupsOf(busyDay), id = alsoGroups(idleDay, "idle_credits");
  const dayMap = (gs: { key: any[]; value: number }[] | null) => {
    const m = new Map<string, number>();
    (gs || []).filter(mine).forEach((g) => { const d = String(g.key[1]).slice(0, 10); m.set(d, (m.get(d) || 0) + numOrZero(g.value)); });
    return m;
  };
  const bMap = dayMap(bd), iMap = dayMap(id);
  const days = [...new Set([...bMap.keys(), ...iMap.keys()])].sort();
  const partial = partialBarKeys(days, false);
  const bh = groupsOf(busyHour), ih = alsoGroups(idleHour, "idle_credits");
  const hourOf = (gs: { key: any[]; value: number }[] | null) => {
    const m = new Map<string, number>();
    (gs || []).filter(mine).forEach((g) => { const k = `${Number(g.key[1])}|${Number(g.key[2])}`; m.set(k, (m.get(k) || 0) + numOrZero(g.value)); });
    return m;
  };
  const bHour = hourOf(bh), iHour = hourOf(ih);
  const grid = emptyWeekHourGrid();
  new Set([...bHour.keys(), ...iHour.keys()]).forEach((k) => {
    const [dw, h] = k.split("|").map(Number);
    if (dw < 1 || dw > 7 || !(h >= 0 && h <= 23)) return;
    const busy = bHour.get(k) || 0, idle = iHour.get(k) || 0;
    grid[dw - 1][h] = busy + idle > 0 ? (pctOf(idle, busy + idle) ?? 0) : null;
  });
  const hourTip = (wd: string, h: number, v: number | null) => {
    const k = `${WEEKDAYS_ISO.indexOf(wd) + 1}|${h}`;
    const busy = bHour.get(k) || 0, idle = iHour.get(k) || 0;
    return `${wd} ${String(h).padStart(2, "0")}:00 UTC: ${v == null ? "not billed" : `${fmtShare(v)} idle · ${fmtInt(Math.round(busy))} busy, ${fmtInt(Math.round(idle))} idle credits`}`;
  };
  const t = (rowsOf(tune) || []).find(same);
  const tDisc = discOf(tune);
  const setting = r0.auto_stop_minutes != null ? `${fmtInt(r0.auto_stop_minutes)} min` : (t && t.auto_suspend_s != null ? secFmt(numOrZero(t.auto_suspend_s)) : "off");
  const facts = [
    `Auto-suspend: ${setting}`,
    t && t.est_saving_60s_usd_list != null ? `at 60 s saves ${fmtMoney(numOrZero(t.est_saving_60s_usd_list) * (1 - tDisc), 0)}` : null,
    t && t.est_saving_300s_usd_list != null ? `at 5 min saves ${fmtMoney(numOrZero(t.est_saving_300s_usd_list) * (1 - tDisc), 0)}` : null,
  ].filter(Boolean).join(" · ");
  const hourNote = busyHour.f && busyHour.state.phase === "error" ? "– This export has no hour of day for this check: run the export again." : noteOf(busyHour, p);
  return (
    <ChartCard title={`${w.name}: busy and idle by day and hour`} subtitle={facts} onOpenCheck={onClose} takeaway={null}>
      {(busyDay.f && busyDay.state.phase === "error" ? "– This export has no hour of day for this check: run the export again." : noteOf(busyDay, p)) || (days.length < 2
        ? <div className="chart-note-oneline">{`No daily rows for ${w.name} in ${rangeOf(p) || "this window"}.`}</div>
        : <Columns
            days={days} partialDays={partial} unitLabel="credits" ariaLabel={`${w.name} busy and idle credits by day`}
            series={[
              { name: "Busy (ran queries)", values: days.map((d) => bMap.get(d) || 0) },
              { name: "Idle", values: days.map((d) => iMap.get(d) || 0) },
            ]}
            valueFmt={(v: number) => `${fmtInt(Math.round(v))} credits`}
            note={partial.length ? `The faded bar is today (${fmtDayShort(partial[0])}): partial.` : null} />)}
      <div className="ac-sub-title">Idle share by weekday and hour (UTC) · darker is more idle</div>
      {hourNote ? <div className="chart-note-oneline">{hourNote}</div>
        : <WeekHourHeatmap grid={grid} ariaLabel={`${w.name} idle share by weekday and hour`} max={100}
            legendLow="mostly busy" legendHigh="mostly idle" tip={hourTip} />}
      <button type="button" className="ac-close" onClick={onClose}>Close</button>
    </ChartCard>
  );
}

function RiskMultiple({ title, src, p, list, pop, status }: {
  title: string; src: Src; p: ApPageProps; list: { name: string; val: string }[] | null; pop: number | null; status: string;
}) {
  const note = noteOf(src, p);
  return (
    <div className="ac-multiple">
      <div className="ac-multiple-title">{title}</div>
      {note || !list ? <div className={`chart-note-oneline${note && note.startsWith("–") ? " ac-notrun" : ""}`}>{note || "–"}</div> : (
        <>
          <div className="ac-multiple-figure">{fmtInt(list.length)}<span className="summary-tile-unit">{pop != null ? `of ${fmtInt(pop)} warehouses${pop ? ` · ${fmtShare(pctOf(list.length, pop))}` : ""}` : "warehouses"}</span></div>
          <div className="ac-mini-track" aria-hidden="true">
            <span style={{ width: `${pop ? Math.min(100, (100 * list.length) / pop) : 0}%`, background: list.length ? "var(--c1)" : "var(--c-other)" }} />
          </div>
          {list.length > 0 && (
            <ul className="ac-multiple-list">
              {list.slice(0, 3).map((it) => <li key={it.name} title={it.name}><span className="ac-ml-name">{it.name}</span><span className="ac-ml-val">{it.val}</span></li>)}
              {list.length > 3 && <li className="blk-more">{`+${fmtInt(list.length - 3)} more`}</li>}
            </ul>
          )}
        </>
      )}
    </div>
  );
}

// ═══════════════════════ Idle & settings: what to change, by warehouse ═══════════════════════

/** A check's possible saving in $ when priced, else in credits; one figure per change, never summed. */
function savingText(r: Row, disc: number): string | null {
  if (r.price_basis !== "unpriced" && r.est_saving_usd_list != null && Number(r.est_saving_usd_list) > 0) return `${fmtMoney(numOrZero(r.est_saving_usd_list) * (1 - disc), 0)} possible saving`;
  if (r.est_saving_credits != null && Number(r.est_saving_credits) > 0) return `${fmtCredits(r.est_saving_credits, 1)} possible saving`;
  return null;
}

// sf_wh_multicluster_scaling.scaling_hint values that are a setting to change (the flagged ones).
const CLUSTER_CHANGE: Record<string, (r: Row) => { what: string; why: string }> = {
  ENABLE_MULTI_CLUSTER: (r) => ({ what: "MAX_CLUSTER_COUNT 1 → 2", why: `${fmtShare(numOrZero(r.queued_pct))} of load queued on one cluster (Enterprise)` }),
  RAISE_MAX_CLUSTERS: (r) => ({ what: `MAX_CLUSTER_COUNT ${fmtInt(r.max_clusters)} → ${fmtInt(numOrZero(r.max_clusters) + 1)}`, why: `${fmtShare(numOrZero(r.queued_pct))} queued at the ceiling` }),
  SWITCH_TO_STANDARD: (r) => ({ what: "SCALING_POLICY ECONOMY → STANDARD", why: `${fmtShare(numOrZero(r.queued_pct))} of load queued` }),
  LOWER_MIN_CLUSTERS: (r) => ({ what: `MIN_CLUSTER_COUNT ${fmtInt(r.min_clusters)} → 1`, why: "extra minimum clusters bill whenever it runs" }),
};

// Short row-level reasons a check could not judge a warehouse; others fall back to the shared label.
const ROW_SKIP: Record<string, string> = { too_few_queries: "too few queries", unknown_size: "size unknown", no_load_history: "no load history", too_few_gaps: "too few idle gaps" };
const skipText = (code: string) => ROW_SKIP[code] || (REASON_INFO[code] ? REASON_INFO[code][0].toLowerCase() : code.replace(/_/g, " "));

/** How many warehouses a check judged, and why the rest were not: a check whose rows are all NOT_ASSESSED did not run. */
function judgedOf(s: Src) {
  const rows = rowsOf(s);
  if (!rows || !rows.length) return null;
  const all = new Set<string>(), judged = new Set<string>(), why = new Map<string, number>();
  rows.forEach((r) => {
    const k = whKey(r);
    all.add(k);
    if (r.status !== "NOT_ASSESSED") judged.add(k);
    else { const c = String(r.not_assessed_reason || "not_assessed"); why.set(c, (why.get(c) || 0) + 1); }
  });
  const reasons = [...why.entries()].sort((a, b) => b[1] - a[1]).map(([c, n]) => `${fmtInt(n)} ${skipText(c)}`).join(", ");
  return { judged: judged.size, total: all.size, reasons };
}

/** One line per warehouse: the settings its checks' flagged rows point at; warehouses with none are left out. */
function SettingChanges({ p, tune, cfg, over, under, mc, pop }: { p: ApPageProps; tune: Src; cfg: Src; over: Src; under: Src; mc: Src; pop: number | null }) {
  const srcs: [Src, string][] = [[tune, "auto-suspend"], [cfg, "settings"], [over, "size (too big)"], [under, "size (too small)"], [mc, "clusters"]];
  const notes = srcs.map(([s, label]) => {
    const j = judgedOf(s);
    // Rows that are all NOT_ASSESSED count as not run, never as "nothing to change".
    const note = noteOf(s, p) || (j && j.judged === 0 ? `– judged on 0 of ${fmtInt(j.total)} warehouses: ${j.reasons}` : null);
    return { label, note, partial: j && j.judged > 0 && j.judged < j.total ? `${label} on ${fmtInt(j.judged)} of ${fmtInt(j.total)} warehouses (${j.reasons})` : null };
  });
  const anyLoading = notes.some((n) => n.note === "…");
  const notRun = notes.filter((n) => n.note && n.note.startsWith("–"));
  const partial = notes.map((n) => n.partial).filter(Boolean) as string[];
  const by = new Map<string, { name: string; rows: Row[]; ids: string[]; changes: { what: string; why: string }[] }>();
  const add = (id: string, r: Row, what: string, why: string) => {
    const k = whKey(r);
    const cur = by.get(k) || { name: whLabel(r, p), rows: [], ids: [], changes: [] };
    cur.rows.push(r); cur.ids.push(id); cur.changes.push({ what, why });
    by.set(k, cur);
  };
  const tDisc = discOf(tune), oDisc = discOf(over);
  const tuned = new Set<string>();
  (rowsOf(tune) || []).filter((r) => isFlagged(r) && r.recommended_auto_suspend_s != null).forEach((r) => {
    tuned.add(whKey(r));
    add(tune.id, r, `AUTO_SUSPEND ${suspendText(r.auto_suspend_s == null ? null : numOrZero(r.auto_suspend_s))} → ${suspendText(numOrZero(r.recommended_auto_suspend_s))}`,
      [r.keep_warm === "keep_warm" ? "cache is reused, so 5 min" : null, savingText(r, tDisc)].filter(Boolean).join(" · ") || "idle gaps bill until it suspends");
  });
  // Auto-suspend off where the replay gave no setting; adaptive warehouses suspend themselves.
  (rowsOf(cfg) || []).filter((r) => String(r.warehouse_type || "").toUpperCase() !== "ADAPTIVE" && (r.auto_stop_minutes == null || numOrZero(r.auto_stop_minutes) <= 0) && !tuned.has(whKey(r)))
    .forEach((r) => add(cfg.id, { ...r, status: "CRITICAL" }, "AUTO_SUSPEND off → 60 s", "never suspends: every idle minute bills"));
  (rowsOf(over) || []).filter((r) => isFlagged(r) && r.suggested_size).forEach((r) =>
    add(over.id, r, `SIZE ${r.warehouse_size || "?"} → ${r.suggested_size}`, [`${fmtShare(numOrZero(r.small_query_pct))} of queries small`, savingText(r, oDisc)].filter(Boolean).join(" · ")));
  (rowsOf(under) || []).filter((r) => isFlagged(r) && r.suggested_size).forEach((r) =>
    add(under.id, r, `SIZE ${r.warehouse_size || "?"} → ${r.suggested_size}`, "queries spill to remote storage; tune the top spillers first"));
  (rowsOf(mc) || []).filter((r) => isFlagged(r) && CLUSTER_CHANGE[String(r.scaling_hint)]).forEach((r) => {
    const c = CLUSTER_CHANGE[String(r.scaling_hint)](r);
    add(mc.id, r, c.what, c.why);
  });
  const list = [...by.values()].sort((a, b) => b.changes.length - a.changes.length || a.name.localeCompare(b.name));
  const ran = srcs.length - notRun.length;
  const notRunText = notRun.map((n) => `${n.label} (${n.note!.replace(/^– /, "")})`).join("; ");
  const body = anyLoading ? <div className="chart-note-oneline">…</div>
    : !ran ? <div className="chart-note-oneline">{`– None of the checks could judge a warehouse: ${notRunText}`}</div>
      : (
        <>
          <DrillTable aria="Settings to change, by warehouse" n={12}
            empty={`No setting to change in ${rangeOf(p) || "this window"}, from the ${fmtInt(ran)} of ${fmtInt(srcs.length)} checks that judged at least one warehouse.`}
            cols={[{ label: "Warehouse" }, { label: "Change", width: "minmax(140px, 1.4fr)" }, { label: "Why", width: "minmax(140px, 1.6fr)" }]}
            rows={list.map((w) => ({
              key: whKey(w.rows[0]), status: worstStatus(w.rows),
              // The drawer opens on the check behind the row's first change.
              onOpen: () => DrawerBus.open({ id: w.ids[0], col: w.rows[0].warehouse_id != null ? "warehouse_id" : null, val: w.rows[0].warehouse_id != null ? String(w.rows[0].warehouse_id) : null, label: w.name }),
              cells: [w.name,
                <span key="c" className="ac-set-chips">{w.changes.map((c) => <span key={c.what} className="dt-chip">{c.what}</span>)}</span>,
                w.changes.map((c) => c.why).join(" · ")],
            }))} />
          {notRun.length > 0 && <div className="chart-note-oneline">{`– Not judged: ${notRunText}`}</div>}
          {partial.length > 0 && <div className="chart-note-oneline">{`Judged only in part: ${partial.join("; ")}`}</div>}
        </>
      );
  return (
    <div id="ac-set-changes">
      <ChartCard title="Change these settings"
        subtitle={`${anyLoading ? "…" : `${fmtInt(list.length)}${pop != null ? ` of ${fmtInt(pop)}` : ""} warehouses`} · flagged rows of the auto-suspend, size and cluster checks · each saving is its own estimate, never added`}
        onOpenCheck={() => DrawerBus.open({ id: "sf_wh_auto_suspend_tuning" })} takeaway={null}>
        {body}
      </ChartCard>
    </div>
  );
}

// sf_wh_last_activity.activity_band, oldest last; dropped and unlisted warehouses are listed, not counted.
const ACTIVITY_BANDS: { key: string; label: string; color: string }[] = [
  { key: "<30", label: "Under 30 days", color: "var(--c1)" },
  { key: "30-89", label: "30–89 days", color: "var(--c2)" },
  { key: "90-179", label: "90–179 days", color: "var(--st-warn)" },
  { key: "180+", label: "180+ days", color: "var(--st-crit)" },
  { key: "never", label: "Never", color: "var(--c-other)" },
];
const GONE_STATES = new Set(["DROPPED", "NOT_IN_SHOW"]);
const stamp = (v: any) => (v == null ? "never" : fmtDate(String(v).slice(0, 10)));

function LastActivity({ p, src }: { p: ApPageProps; src: Src }) {
  const rows = rowsOf(src);
  const gone = (r: Row) => GONE_STATES.has(String(r.state || "").toUpperCase());
  const listed = rows ? rows.filter((r) => !gone(r)) : null;
  const flagged = listed ? listed.filter(isFlagged).sort((a, b) => numOrZero(b.days_since_activity) - numOrZero(a.days_since_activity)) : [];
  const dropped = rows ? rows.filter(gone) : [];
  const segs: ShareSegment[] | null = listed ? ACTIVITY_BANDS.map((b) => ({ key: b.key, label: b.label, color: b.color, value: listed.filter((r) => String(r.activity_band) === b.key).length })) : null;
  const n = listed ? listed.length : 0;
  return (
    <Panel p={p} src={src} title="Warehouses by last activity"
      subtitle={`days since the last query, resume or billed hour, up to a year back${listed ? ` · ${fmtInt(flagged.length)} of ${fmtInt(n)} warehouses flagged (90+ days idle, or never used and not new)` : ""}${dropped.length ? ` · ${fmtInt(dropped.length)} dropped or not listed: in the table, not counted` : ""}`}>
      {segs && (
        <div className="pl-stack">
          {n > 0 ? <StackedShareBar segments={segs} valueFmt={(v) => `${fmtInt(v)} of ${fmtInt(n)} warehouses`} ariaLabel="Warehouses by days since last activity" />
            : <div className="chart-note-oneline">No warehouse listed by SHOW WAREHOUSES for this role.</div>}
          <DrillTable aria="Inactive and dropped warehouses" n={10}
            empty="No warehouse idle 90 days or more, and none dropped."
            // Days comes second: a phone shows only the first two columns.
            cols={[{ label: "Warehouse" }, { label: "Days idle", num: true, width: "minmax(64px, 0.7fr)" }, { label: "Finding", width: "minmax(120px, 1.6fr)" }, { label: "Last activity", width: "minmax(90px, 1fr)" },
              { label: "Size", width: "minmax(64px, 0.7fr)" }, { label: "Credits · 30 d", num: true, width: "minmax(80px, 0.9fr)" }]}
            rows={[...flagged, ...dropped].map((r) => ({
              key: whKey(r), status: r.status,
              onOpen: () => DrawerBus.open({ id: "sf_wh_last_activity", col: "warehouse_id", val: r.warehouse_id != null ? String(r.warehouse_id) : null, label: whLabel(r, p) }),
              cells: [whLabel(r, p), r.days_since_activity != null ? fmtInt(r.days_since_activity) : "–", String(r.finding || "–"), stamp(r.last_activity_time),
                r.size ? String(r.size) : "–", r.credits_last_30d != null ? fmtCredits(r.credits_last_30d, 1) : "–"],
            }))} />
        </div>
      )}
    </Panel>
  );
}

// ═══════════════════════ Warehouses > Sizing ═══════════════════════

function WhSizing(p: ApPageProps) {
  const over = useRows(p, "sf_wh_oversized");
  const under = useRows(p, "sf_wh_undersized");
  const cons = useRows(p, "sf_wh_consolidation_candidates");
  const sof = useRows(p, "sf_wh_snowpark_optimized_fit");
  const g2 = useRows(p, "sf_wh_gen2_fit");
  const spendAgg = useFindingAgg("cost_dollarized_by_service_day", p.filters.window, p.filters.accountIds, ["usage_date"], "sum", COST_MONEY_COL) as FetchState;
  const spend = spendAgg.phase === "ready" && spendAgg.outcome === "ok_rows" && spendAgg.data ? aggTotal(spendAgg.data) : null;
  const pop = warehousePopulation(p, affectedOf(over.f)?.total, affectedOf(under.f)?.total);

  const overRows = rowsOf(over);
  const oDisc = discOf(over);
  const resize = (overRows || []).filter(isFlagged).map((r) => ({ r, usd: numOrZero(r.est_saving_usd_list) * (1 - oDisc) })).sort((a, b) => b.usd - a.usd);
  const smallPcts = resize.map((x) => numOrZero(x.r.small_query_pct)).filter((v) => v > 0);
  const smallRange = smallPcts.length ? (Math.round(Math.min(...smallPcts)) === Math.round(Math.max(...smallPcts)) ? fmtShare(smallPcts[0]) : `${Math.round(Math.min(...smallPcts))}–${fmtShare(Math.max(...smallPcts))}`) : null;
  const consRows = rowsOf(cons);
  const cDisc = discOf(cons);
  const pairs: StatusBarItem[] = (consRows || []).filter(isFlagged).map((r) => {
    const usd = numOrZero(r.est_saving_usd_list) * (1 - cDisc);
    return {
      // The partner rides in the value text: two names in one label get cut from both ends.
      key: whKey(r), name: whLabel(r, p), value: usd, status: r.status,
      valueText: [fmtMoney(usd, 0), r.partners ? `with ${String(r.partners).split(",")[0].trim()}${String(r.partners).includes(",") ? " …" : ""}` : null, `${fmtInt(r.shared_hours)} h together`].filter(Boolean).join(" · "),
      title: r.partners ? `Shares hours with ${r.partners}` : undefined,
    };
  });
  const underRows = rowsOf(under);
  const spill: ShareItem[] = (underRows || []).filter((r) => numOrZero(r.query_count) > 0 && numOrZero(r.spilling_queries) > 0)
    .map((r) => ({ key: whKey(r), name: `${whLabel(r, p)} · ${r.warehouse_size || "?"}`, value: numOrZero(r.spilling_queries), total: numOrZero(r.query_count), status: r.status,
      onClick: () => DrawerBus.open({ id: "sf_wh_undersized", col: r.warehouse_id != null ? "warehouse_id" : null, val: r.warehouse_id != null ? String(r.warehouse_id) : null, label: whLabel(r, p) }) }));
  const underAff = affectedOf(under.f);
  const uDisc = discOf(under);
  const spillSpend = (underRows || []).filter(isFlagged).reduce((s, r) => s + numOrZero(r.est_spilling_usd_list) * (1 - uDisc), 0);
  const topSpill = [...spill].sort((a, b) => numOrZero(pctOf(b.value, b.total)) - numOrZero(pctOf(a.value, a.total)))[0];
  const oM = moneyHeadline(over.f), cM = moneyHeadline(cons.f);
  // The three saving checks, read the way Waste & savings and Overview read them, so the $ agrees.
  const entries = [over, cons, sof].map((s) => buildWasteEntry(WASTE_ITEMS.find((w) => w.id === s.id)!, s.f));
  const [oE, cE, sE] = entries;
  const oUsd = oE.usd, cUsd = cE.usd, sUsd = sE.usd;
  const saving = wasteTotal(entries).saving.usd;
  const savingPct = saving != null ? pctOf(saving, spend) : null;
  // A part that ran and flagged nothing is none; one that did not run or is unpriced is "–".
  const partText = (e: typeof oE) => (e.usd != null ? fmtMoney(e.usd, 0) : e.ran && !e.isFlagged ? "none" : "–");
  // Distinct warehouses: one can be flagged by more than one check.
  const sofRows = rowsOf(sof);
  const flaggedWh = overRows || consRows || sofRows
    ? new Set([...(overRows || []), ...(consRows || []), ...(sofRows || [])].filter(isFlagged).map(whKey)).size
    : entries.reduce((s, e) => s + e.flaggedCount, 0);
  // One denominator for the combined tile: the most warehouses any of the three checks saw.
  const sizePop = Math.max(0, ...[over, cons, sof].map((s) => affectedOf(s.f)?.total ?? 0)) || pop;
  const biggest = [{ u: cUsd ?? 0, t: "mostly warehouses lightly loaded at the same hours that could share one" },
    { u: oUsd ?? 0, t: "mostly large warehouses that run small queries" },
    { u: sUsd ?? 0, t: "mostly Snowpark-optimized warehouses that run plain SQL" }].sort((a, b) => b.u - a.u)[0];

  const lede = loading(over) || loading(cons) || loading(sof) ? "…" : saving != null && saving > 0
    ? `Resizing would save ${savingPct != null ? `${fmtShare(savingPct)} of spend` : fmtMoney(saving, 0)}: ${biggest.t}.`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const maxSave = resize.length ? resize[0].usd : 1;
  // Snowpark-optimized warehouses: what their work is, and the premium where it is plain SQL (possible saving).
  const sDisc = discOf(sof);
  const soItems: StatusBarItem[] = (rowsOf(sof) || []).filter((r) => r.verdict != null).map((r) => {
    const usd = numOrZero(r.est_saving_usd_list) * (1 - sDisc);
    const what = r.verdict === "plain_sql" ? `plain SQL · ${usd > 0 ? `${fmtMoney(usd, 0)} possible saving` : "premium under the floor"}`
      : r.verdict === "no_premium" ? "same rate as standard" : "Snowpark work: keep it";
    return {
      key: whKey(r), name: whLabel(r, p), value: r.verdict === "plain_sql" ? usd : 0, status: r.status,
      valueText: [what, `${fmtShare(numOrZero(r.call_exec_pct))} in procedures`, numOrZero(r.spill_exec_pct) > 0 ? `${fmtShare(numOrZero(r.spill_exec_pct))} spills` : null,
        r.resource_constraint ? String(r.resource_constraint) : null].filter(Boolean).join(" · "),
    };
  });
  // Gen1 warehouses whose run time is mostly delete, update and merge: a Gen2 test, never a saving.
  const g2Rows = rowsOf(g2) || [];
  const gen2: StatusBarItem[] = g2Rows.filter((r) => r.verdict === "test_gen2")
    .map((r) => ({ key: whKey(r), name: whLabel(r, p), value: numOrZero(r.dml_exec_pct), status: "neutral",
      valueText: `${fmtShare(numOrZero(r.dml_exec_pct))} of run time · ${r.warehouse_size || "?"}` }));
  const conversions = g2Rows.filter((r) => r.converted_at != null);
  return (
    <div className="ac-page">
      <div className="summary-tile-row compact sx-tiles-4">
        <IssueTile label={`Possible saving from resizing · ${p.filters.window} d`} loading={loading(over) || loading(cons) || loading(sof)} pill={<KindChip>kept apart</KindChip>}
          headline={saving != null ? (savingPct != null ? fmtShare(savingPct) : fmtMoney(saving, 0)) : null} unit={savingPct != null ? "of spend" : undefined}
          missingReason={oM.why || cM.why || missingOf(over, p)}
          base={saving != null ? [`${fmtMoney(saving, 0)}${spend != null ? ` of ${fmtMoney(spend, 0)}` : ""}`, "3 checks", sizePop ? `${fmtInt(flaggedWh)} of ${fmtInt(sizePop)} warehouses` : null].filter(Boolean).join(" · ") : null}
          cause={saving != null ? `${partText(cE)} from sharing, ${partText(oE)} from one size down, ${partText(sE)} from Snowpark-optimized. Not added to waste.` : null}
          onOpen={() => scrollToAnchor("ac-resize")} openLabel="Where it comes from ↓" />
        <IssueTile label="Large warehouses, small queries" loading={loading(over)} status={statusOf(over.f)}
          headline={affectedOf(over.f) ? `${fmtInt(affectedOf(over.f)!.flagged)}` : null} unit={affectedOf(over.f)?.total ? `of ${fmtInt(affectedOf(over.f)!.total)} warehouses` : "warehouses"} missingReason={missingOf(over, p) || oM.why}
          base={oM.headline ? [savingWords(oM.headline), smallRange ? `${smallRange} of queries small` : null].filter(Boolean).join(" · ") : null}
          cause={resize[0] ? `Most: ${whLabel(resize[0].r, p)}, ${resize[0].r.warehouse_size} → ${resize[0].r.suggested_size || "one size down"}.` : null}
          onOpen={() => scrollToAnchor("ac-resize")} openLabel="One size down ↓" />
        <IssueTile label="Lightly loaded at the same hours" loading={loading(cons)} status={statusOf(cons.f)}
          headline={affectedOf(cons.f) ? `${fmtInt(affectedOf(cons.f)!.flagged)}` : null} unit={affectedOf(cons.f)?.total ? `of ${fmtInt(affectedOf(cons.f)!.total)} warehouses` : "warehouses"} missingReason={missingOf(cons, p) || cM.why}
          base={cM.headline ? `${savingWords(cM.headline)} · ${fmtInt(pairs.length)} pairs` : null}
          cause="Same size, busy at the same hours: one warehouse could carry both." onOpen={() => scrollToAnchor("ac-share")} openLabel="Pairs ↓" />
        <IssueTile label="Too small: queries spill" loading={loading(under)} status={statusOf(under.f)}
          headline={underAff && underAff.total ? fmtShare(pctOf(underAff.flagged, underAff.total)) : null} unit="of warehouses" missingReason={missingOf(under, p)}
          base={underAff ? `${fmtInt(underAff.flagged)} of ${fmtInt(underAff.total)} warehouses${spillSpend > 0 ? ` · ${fmtMoney(spillSpend, 0)} spend on them · context` : ""}` : null}
          cause={topSpill ? `Most: ${topSpill.name}, ${fmtShare(pctOf(topSpill.value, topSpill.total))} of its queries spill.` : null}
          onOpen={() => scrollToAnchor("ac-spill")} openLabel="By warehouse ↓" />
      </div>
      <Row2>
        <div id="ac-resize">
          <Panel p={p} src={over} title="Resize candidates" subtitle="ranked by possible saving · size now → one step down · share of small queries · median scan">
            <DrillTable aria="Resize candidates" n={8} empty={`No warehouse is too big for its queries in ${rangeOf(p) || "this window"}.`}
              cols={[{ label: "Warehouse" }, { label: "Size → next", width: "minmax(90px, auto)" }, { label: "Saving", width: "minmax(50px, 1fr)" }, { label: `$ · ${p.filters.window} d`, num: true, width: "auto" }, { label: "Small", num: true, width: "auto" }]}
              rows={resize.map(({ r, usd }) => ({
                key: `${whKey(r)}|${usd}`, status: r.status,
                onOpen: () => DrawerBus.open({ id: "sf_wh_oversized", col: r.warehouse_id != null ? "warehouse_id" : null, val: r.warehouse_id != null ? String(r.warehouse_id) : null, label: whLabel(r, p) }),
                cells: [whLabel(r, p), <span key="s" className="dt-chip">{`${r.warehouse_size || "?"} → ${r.suggested_size || "?"}`}</span>, <MiniBar key="b" value={usd} max={maxSave} />, fmtMoney(usd, 0),
                  r.small_query_pct != null ? fmtShare(numOrZero(r.small_query_pct)) : "–"],
              }))} />
          </Panel>
        </div>
        <div id="ac-share">
          <Panel p={p} src={cons} title="Warehouses that could share" subtitle="same size, each lightly loaded at the same hours · saving = the second warehouse's bill while both run">
            <RankedOrLine items={pairs} valueFmt={usdFmt} unitLabel="$" ariaLabel="Consolidation pairs by saving" emptyText="No same-size warehouses idle together in this window."
              onBarClick={(it) => DrawerBus.open({ id: "sf_wh_consolidation_candidates", label: it.name })} />
          </Panel>
        </div>
      </Row2>
      <div id="ac-spill">
        <Panel p={p} src={under} title="Too small: share of queries that spill to remote storage" subtitle={`spilling queries of all queries, by warehouse and size${underAff ? ` · ${fmtInt(underAff.flagged)} of ${fmtInt(underAff.total)} flagged` : ""} · dot = status`}>
          <ShareBarList items={spill} noun="queries" emptyText="No warehouse spilled in this window." />
        </Panel>
      </div>
      <Row2>
        <Panel p={p} src={sof} title="Snowpark-optimized: Snowpark work or plain SQL?" subtitle="run time in procedures and in spilling statements · plain SQL pays the premium for nothing · possible saving, not waste">
          <RankedOrLine items={soItems} valueFmt={usdFmt} unitLabel="$" ariaLabel="Snowpark-optimized warehouses by fit" emptyText="No Snowpark-optimized warehouse ran queries in this window."
            onBarClick={(it) => { const r = (rowsOf(sof) || []).find((x) => whKey(x) === it.key); if (r) DrawerBus.open({ id: "sf_wh_snowpark_optimized_fit", col: "warehouse_id", val: String(r.warehouse_id), label: it.name }); }} />
        </Panel>
        <Panel p={p} src={g2} title="Gen1 or Gen2" subtitle="Gen2 runs delete, update and merge faster but bills 1.35× per hour (1.25× on Azure): a test, not a saving">
          {conversions.map((r) => <Gen2Conversion key={whKey(r)} r={r} name={whLabel(r, p)} />)}
          <div className="ac-sub-title">Gen1 warehouses that mostly delete, update and merge</div>
          <RankedOrLine items={gen2} valueFmt={(v) => fmtShare(v)} unitLabel="% of run time" ariaLabel="Gen1 warehouses by delete, update and merge share"
            emptyText="No Gen1 warehouse spends most of its run time on delete, update and merge."
            onBarClick={(it) => { const r = g2Rows.find((x) => whKey(x) === it.key); if (r) DrawerBus.open({ id: "sf_wh_gen2_fit", col: "warehouse_id", val: String(r.warehouse_id), label: it.name }); }} />
        </Panel>
      </Row2>
    </div>
  );
}
(WhSizing as any).ownsLede = true;

const G2_VERDICT: Record<string, string> = {
  paid_off: "paid off", about_even: "about even", costs_more: "costs more", back_to_gen1: "moved back to Gen1", too_soon: "too soon to judge",
};
const signed = (v: any) => (v == null ? "–" : `${Number(v) > 0 ? "+" : ""}${fmtShare(Number(v))}`);

/** One generation change: before vs after, credits per query and the same statements' run time. */
function Gen2Conversion({ r, name }: { r: Row; name: string }) {
  const verdict = G2_VERDICT[String(r.verdict)] || String(r.verdict || "");
  const facts = r.verdict === "too_soon"
    ? `${fmtInt(r.days_before ?? 0)} days before, ${fmtInt(r.days_after ?? 0)} after`
    : [`credits per query ${signed(r.credits_per_query_change_pct)}`, r.same_shapes ? `same ${fmtInt(r.same_shapes)} statements ${signed(r.same_shape_exec_change_pct)} run time` : null,
      `${fmtInt(r.days_before)} d before, ${fmtInt(r.days_after)} d after`].filter(Boolean).join(" · ");
  return (
    <div className="chart-note-oneline ac-one-line">
      <span className="blk-dot" style={{ background: statusBarColor(r.status) }} aria-hidden="true" />
      <strong>{name}</strong>{` → ${r.converted_to === "GEN1" ? "Gen1" : "Gen2"} on ${fmtDayShort(String(r.converted_at).slice(0, 10))}: `}<strong>{verdict}</strong>{` · ${facts}`}
    </div>
  );
}

// ═══════════════════════ Warehouses > Load & scaling ═══════════════════════

function WhLoad(p: ApPageProps) {
  const mc = useRows(p, "sf_wh_multicluster_scaling");
  const lu = useRows(p, "sf_wh_load_utilization");
  const mix = useRows(p, "sf_wh_mixed_workload_contention");
  const mcPop = affectedOf(mc.f)?.total || null;
  // Warehouses where reads queue more while pipelines write: the bar is the queued share in pipeline hours.
  const mixItems: StatusBarItem[] = (rowsOf(mix) || []).filter((r) => r.verdict === "pipeline_crowds_out" || r.verdict === "queue_from_reads")
    .map((r) => ({
      key: whKey(r), name: whLabel(r, p), value: numOrZero(r.queued_pct_pipeline_hours), status: r.status,
      valueText: [`${fmtShare(numOrZero(r.queued_pct_pipeline_hours))} queue while pipelines run vs ${fmtShare(numOrZero(r.queued_pct_other_hours))} otherwise`,
        r.top_pipeline_user_name ? String(r.top_pipeline_user_name) : null,
        r.peak_pipeline_hour_utc != null ? `worst ${String(r.peak_pipeline_hour_utc).padStart(2, "0")}:00 UTC` : null].filter(Boolean).join(" · "),
    }));
  const mcRows = rowsOf(mc);
  const queued = (mcRows || []).filter((r) => isFlagged(r) && numOrZero(r.queued_pct) > 0);
  const qp = queued.map((r) => numOrZero(r.queued_pct));
  const oneCluster = queued.filter((r) => numOrZero(r.max_clusters) <= 1).length;
  const luRows = rowsOf(lu);
  const low = luRows ? luRows.reduce((s, r) => s + numOrZero(r.low_load_hours), 0) : 0;
  const billed = luRows ? luRows.reduce((s, r) => s + numOrZero(r.billed_hours), 0) : 0;
  const lowItems: ShareItem[] = (luRows || []).filter((r) => numOrZero(r.billed_hours) > 0)
    .map((r) => ({ key: whKey(r), name: whLabel(r, p), value: numOrZero(r.low_load_hours), total: numOrZero(r.billed_hours), status: r.status }));
  const range = qp.length ? (Math.min(...qp) === Math.max(...qp) ? fmtShare(qp[0]) : `${Math.round(Math.min(...qp))}–${fmtShare(Math.max(...qp))}`) : null;
  const load = useWarehouseLoad(p.filters);
  const luAff = affectedOf(lu.f);
  const sr = useRows(p, "sf_wh_starts_resumes");
  const press = useRows(p, "query_warehouse_pressure");
  // The same group keys as Queries > Efficiency, so the two pages read one set of sums.
  const cacheAgg = useAgg(p, "sf_query_result_cache_misses", ["warehouse_id", "warehouse_name", "status"], "sum", "repeats", { also: ["missed_runs"] });
  const pruneAgg = useAgg(p, "query_pruning_effectiveness", ["warehouse_id", "warehouse_name", "status"], "sum", "query_count");
  const hours = useAgg(p, "query_workload_mix_hours", ["hour_of_day"], "sum", "query_count");

  const lede = loading(mc) || loading(lu) ? "…" : [
    mcRows && queued.length ? `${fmtInt(queued.length)}${mcPop ? ` of ${fmtInt(mcPop)}` : ""} warehouses queue ${range} of their queries${oneCluster === queued.length ? ", all on one cluster" : ""}` : null,
    luRows && billed > 0 ? `${fmtShare(pctOf(low, billed))} of billed hours carried little load` : null,
  ].filter(Boolean).join("; ") || null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede ? (lede === "…" ? lede : `${lede}.`) : null); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="ac-page">
      <Tiles>
        <IssueTile label="Queries queued at capacity" loading={loading(mc)}
          headline={mcRows ? (range || "None") : null} unit={range ? "of their queries queue" : undefined} missingReason={missingOf(mc, p)}
          base={mcRows ? `${fmtInt(queued.length)} of ${fmtInt(mcPop ?? mcRows.length)} warehouses${queued.length ? ` · ${fmtInt(oneCluster)} run on 1 cluster with MAX_CLUSTER_COUNT = 1` : ""}` : null}
          cause={queued.length ? "A second cluster, or spreading the load, removes the queue." : null}
          status={statusOf(mc.f)} onOpen={() => scrollToAnchor("ac-clusters")} openLabel="Clusters allowed vs used ↓" />
        <IssueTile label="Billed hours with little load" loading={loading(lu)}
          headline={luRows ? fmtShare(pctOf(low, billed)) : null} unit="of billed hours" missingReason={missingOf(lu, p)}
          base={luRows ? `${fmtInt(luAff?.flagged ?? 0)} of ${fmtInt(luAff?.total || luRows.length)} warehouses flagged · ${fmtInt(Math.round(low))} of ${fmtInt(Math.round(billed))} h across all ${fmtInt(luRows.length)}` : null}
          cause="Overlaps idle time, so not priced here: it is counted once, on Idle & settings."
          status={statusOf(lu.f)} onOpen={() => scrollToAnchor("ac-lowload")} openLabel="By warehouse ↓" />
      </Tiles>
      <ChartCard title={`Warehouses · load over ${fmtInt(p.filters.window)} days`} subtitle="each day split busy, busy with queries queued, idle but billed, and not running · most queued first · click a warehouse for its days" onOpenCheck={openCheck(p, "sf_wh_state_daily")} takeaway={null}>
        <WarehouseLoadBands load={load} meta={p.meta} filters={p.filters} n={10}
          onRow={(w) => DrawerBus.open({ id: "sf_wh_load_utilization", col: "warehouse_id", val: w.id, label: `${w.name} (${w.id})` })} />
      </ChartCard>
      <Row2>
        <div id="ac-clusters">
          <Panel p={p} src={mc} title="Clusters allowed vs used, with % queued" subtitle="filled = clusters that ran · outlined = allowed, never used · most queued first">
            {mcRows && <ClusterRows rows={mcRows} p={p} />}
          </Panel>
        </div>
        <div id="ac-lowload">
          <Panel p={p} src={lu} title="Low-load hours, by warehouse" subtitle="low-load hours of billed hours">
            <ShareBarList items={lowItems} noun="hours" valueFmt={(v) => `${fmtInt(Math.round(v))} h`} emptyText="No billed hours in this window." />
          </Panel>
        </div>
      </Row2>
      <Panel p={p} src={mix} title="Pipelines that make people wait" subtitle="share of SELECTs that queue in hours a pipeline writes vs the other hours · split or reschedule the pipeline before upsizing">
        <RankedOrLine items={mixItems} valueFmt={(v) => fmtShare(v)} unitLabel="% queued" max={100} ariaLabel="Warehouses where pipelines make reads queue"
          emptyText={`No warehouse where reads queue behind pipelines in ${rangeOf(p) || "this window"}.`}
          onBarClick={(it) => { const r = (rowsOf(mix) || []).find((x) => whKey(x) === it.key); if (r) DrawerBus.open({ id: "sf_wh_mixed_workload_contention", col: "warehouse_id", val: String(r.warehouse_id), label: it.name }); }} />
      </Panel>
      <StartsResumes p={p} src={sr} />
      <HourVolume p={p} src={hours} />
      <EfficiencyByWarehouse p={p} press={press} cache={cacheAgg} prune={pruneAgg} />
      <ChartCard title="Warehouse spend by calendar month" subtitle="last 12 months and this month · compute and billed cloud services · the top 4 warehouses and the rest" onOpenCheck={openCheck(p, "sf_wh_spend_monthly")} takeaway={null}>
        <WarehouseSpendMonths filters={p.filters} meta={p.meta} />
      </ChartCard>
    </div>
  );
}
(WhLoad as any).ownsLede = true;

/** One row per warehouse: a box per cluster (filled = used, outlined = allowed, unused) and the % queued. */
function ClusterRows({ rows, p, n = 10 }: { rows: Row[]; p: ApPageProps; n?: number }) {
  const [ref, W] = useChartWidth(560);
  const labelW = rowLabelWidth(W);
  const list = rows.filter((r) => r.status !== "NOT_ASSESSED")
    .sort((a, b) => numOrZero(b.queued_pct) - numOrZero(a.queued_pct) || numOrZero(b.compute_credits) - numOrZero(a.compute_credits));
  if (!list.length) return <div className="chart-note-oneline" ref={ref}>No warehouse could be judged in this window.</div>;
  const shown = list.slice(0, n);
  const dot = (s: any) => (s === "CRITICAL" ? "crit" : s === "WARN" ? "warn" : "ok");
  return (
    <div className="de-cl-list" ref={ref} role="table" aria-label="Clusters allowed vs used, by warehouse">
      <div className="de-cl-row de-cl-head" role="row"><span role="columnheader">Warehouse</span><span role="columnheader">Clusters</span><span role="columnheader">Setting</span><span role="columnheader" className="de-cl-q">Queued</span></div>
      {shown.map((r) => {
        const allowed = Math.max(1, numOrZero(r.max_clusters));
        const used = Math.max(0, numOrZero(r.max_cluster_seen));
        const q = numOrZero(r.queued_pct);
        const name = whLabel(r, p);
        return (
          <div key={whKey(r)} className="de-cl-row" role="row">
            <span className="de-cl-name" role="cell" title={name}>
              <span className={`de-dot ${dot(r.status)}`} aria-hidden="true" />
              <button type="button" className="b2-linkbtn" onClick={() => DrawerBus.open({ id: "sf_wh_multicluster_scaling", col: r.warehouse_id != null ? "warehouse_id" : null, val: r.warehouse_id != null ? String(r.warehouse_id) : null, label: name })}>
                {truncateLeft(name, Math.max(80, labelW - 8))}
              </button>
            </span>
            <span role="cell"><ClusterDots used={Math.min(10, used)} allowed={Math.min(10, Math.max(allowed, used))} /></span>
            <span className="de-cl-set" role="cell">{[`MIN ${fmtInt(r.min_clusters ?? 1)} · MAX ${fmtInt(allowed)}`, r.scaling_policy ? String(r.scaling_policy) : null, r.warehouse_size ? String(r.warehouse_size) : null].filter(Boolean).join(" · ")}</span>
            <span className="de-cl-q" role="cell">{fmtShare(q)}</span>
          </div>
        );
      })}
      {list.length > shown.length && <div className="blk-more">{`+${fmtInt(list.length - shown.length)} more not shown`}</div>}
    </div>
  );
}

/** The window the check's rows are for: the page window, or the nearest one the export kept. */
function windowOfSrc(s: Src, p: ApPageProps): number {
  const w = s.state.data ? Number(s.state.data.window_days) : NaN;
  return Number.isFinite(w) && w > 0 ? w : p.filters.window;
}

/** Resumes, suspends and cluster starts per warehouse, and how long queries waited for it to start. */
function StartsResumes({ p, src }: { p: ApPageProps; src: Src }) {
  const days = windowOfSrc(src, p);
  // Rows are kept per exported window; only the page's window is read, never summed across windows.
  const rows = (rowsOf(src) || []).filter((r) => r.window_days == null || Number(r.window_days) === days)
    .sort((a, b) => numOrZero(b.resumes) - numOrZero(a.resumes) || numOrZero(b.provisioning_wait_s) - numOrZero(a.provisioning_wait_s));
  const split = (parts: [any, string][]) => parts.filter(([v]) => numOrZero(v) > 0).map(([v, w]) => `${fmtInt(v)} ${w}`).join(" · ");
  return (
    <Panel p={p} src={src} title="Starts and resumes"
      subtitle={`${fmtInt(days)} days · each resume bills at least 60 s · query wait p95 is how long queries waited for it to start, not the resume itself`}>
      <DrillTable aria="Starts and resumes by warehouse" n={10}
        empty={`No resume, suspend or start-up wait in ${rangeOf(p) || "this window"}.`}
        cols={[{ label: "Warehouse" }, { label: "Resumes", width: "minmax(110px, 1.3fr)" }, { label: "Per day", num: true, width: "minmax(60px, 0.6fr)" },
          { label: "Suspends", width: "minmax(110px, 1.3fr)" }, { label: "Clusters added", num: true, width: "minmax(100px, 0.8fr)" }, { label: "Queries waited", num: true, width: "minmax(100px, 0.8fr)" },
          { label: "Wait total", num: true, width: "minmax(70px, 0.7fr)" }, { label: "Query wait p95", num: true, width: "minmax(80px, 0.8fr)" }]}
        rows={rows.map((r) => ({
          key: whKey(r), status: r.status,
          onOpen: () => DrawerBus.open({ id: "sf_wh_starts_resumes", col: "warehouse_id", val: r.warehouse_id != null ? String(r.warehouse_id) : null, label: whLabel(r, p) }),
          cells: [whLabel(r, p),
            `${fmtInt(r.resumes ?? 0)}${numOrZero(r.resumes) > 0 ? ` (${split([[r.auto_resumes, "auto"], [r.manual_resumes, "manual"]]) || "other"})` : ""}`,
            r.resumes_per_day != null ? smallFmt(numOrZero(r.resumes_per_day), numOrZero(r.resumes) > 0) : "–",
            `${fmtInt(r.suspends ?? 0)}${numOrZero(r.suspends) > 0 ? ` (${split([[r.auto_suspends, "auto"], [r.manual_suspends, "manual"], [r.monitor_suspends, "monitor"]]) || "other"})` : ""}`,
            fmtInt(r.clusters_added ?? 0), fmtInt(r.queries_waiting_provisioning ?? 0),
            r.provisioning_wait_s != null ? secFmt(numOrZero(r.provisioning_wait_s)) : "–",
            r.provisioning_p95_s != null ? secFmt(numOrZero(r.provisioning_p95_s)) : "–"],
        }))} />
    </Panel>
  );
}

/** Queries per hour of day (UTC) over the window, with the peak hour named. */
function HourVolume({ p, src }: { p: ApPageProps; src: Src }) {
  const g = groupsOf(src);
  const byHour = Array.from({ length: 24 }, () => 0);
  (g || []).forEach((x) => { const h = Number(x.key[0]); if (h >= 0 && h <= 23) byHour[h] += numOrZero(x.value); });
  const all = byHour.reduce((s, v) => s + v, 0);
  const peak = byHour.reduce((best, v, h) => (v > byHour[best] ? h : best), 0);
  const hh = (h: number) => `${String(h).padStart(2, "0")}:00`;
  return (
    <Panel p={p} src={src} title="Query volume by hour"
      subtitle={g && all > 0 ? `all queries, incl. those with no warehouse · per hour of day, all days summed · UTC · peak ${hh(peak)}, ${fmtInt(byHour[peak])} of ${fmtInt(all)} queries (${fmtShare(pctOf(byHour[peak], all))})` : "all queries, incl. those with no warehouse · per hour of day, all days summed · UTC"}>
      {g && (all > 0
        ? <div className="ac-hour-line"><MultiLine series={[{ label: "Queries", color: "var(--c1)", data: byHour }]} xLabels={byHour.map((_, h) => `${hh(h)} UTC`)} /></div>
        : <div className="chart-note-oneline">{`No queries in ${rangeOf(p) || "this window"}.`}</div>)}
    </Panel>
  );
}

type EffSort = "queries" | "avg" | "spill" | "queued" | "cold" | "cache" | "prune";
const EFF_COLS: { k: EffSort; label: string; title: string }[] = [
  { k: "queries", label: "Queries", title: "Statements in the window" },
  { k: "avg", label: "Avg run", title: "Execution time per finished statement" },
  { k: "spill", label: "Spill", title: "Share of run time spent in queries that spilled (what the pressure status reads)" },
  { k: "queued", label: "Queued", title: "Share of statement time queued at capacity" },
  { k: "cold", label: "Start-up wait", title: "Share of statement time waiting for the warehouse to start" },
  { k: "cache", label: "Cache miss", title: "Repeat runs that re-ran instead of using the result cache" },
  { k: "prune", label: "Poor pruning", title: "Queries flagged for reading most of the table" },
];

/** One row per warehouse with each efficiency measure its checks give; click a header to sort. */
function EfficiencyByWarehouse({ p, press, cache, prune }: { p: ApPageProps; press: Src; cache: Src; prune: Src }) {
  const [sort, setSort] = React.useState<EffSort>("queries");
  const rows = rowsOf(press);
  // The pressure check has ids only; the daily query feed names warehouses the role's name list lacks.
  const daily = rowsOf(useRows(p, "sf_qry_daily_by_warehouse"));
  const nameById = new Map<string, string>();
  (daily || []).forEach((r) => { if (r.warehouse_id != null && r.warehouse_name) nameById.set(String(r.warehouse_id), String(r.warehouse_name)); });
  const labelOf = (r: Row) => (r.warehouse_id != null && nameById.has(String(r.warehouse_id)) ? `${nameById.get(String(r.warehouse_id))} (${r.warehouse_id})` : whLabel(r, p));
  // Part / whole per warehouse id from a (warehouse_id, warehouse_name, status) sum; unjudged rows left out.
  const ratio = (s: Src, flaggedOnly: boolean, partCol: string | null) => {
    const m = new Map<string, { part: number; whole: number }>();
    (s.state.phase === "ready" && s.state.data ? s.state.data.groups || [] : []).forEach((g: any) => {
      const [id, , st] = g.key;
      if (st === "NOT_ASSESSED") return;
      const k = String(id ?? "");
      const cur = m.get(k) || { part: 0, whole: 0 };
      cur.whole += numOrZero(g.value);
      cur.part += partCol ? numOrZero(g.also && g.also[partCol]) : flaggedOnly && (st === "CRITICAL" || st === "WARN") ? numOrZero(g.value) : 0;
      m.set(k, cur);
    });
    return m;
  };
  const cacheBy = ratio(cache, false, "missed_runs"), pruneBy = ratio(prune, true, null);
  const pct = (m: Map<string, { part: number; whole: number }>, id: any) => { const x = m.get(String(id ?? "")); return x && x.whole > 0 ? pctOf(x.part, x.whole) : null; };
  const list = (rows || []).filter((r) => numOrZero(r.query_count) > 0).map((r) => ({
    r, name: labelOf(r),
    v: {
      queries: numOrZero(r.query_count),
      avg: numOrZero(r.finished_count) > 0 && r.execution_s_sum != null ? numOrZero(r.execution_s_sum) / numOrZero(r.finished_count) : null,
      spill: r.spill_time_pct != null ? numOrZero(r.spill_time_pct) : null,
      queued: r.capacity_wait_pct != null ? numOrZero(r.capacity_wait_pct) : null,
      cold: r.cold_start_wait_pct != null ? numOrZero(r.cold_start_wait_pct) : null,
      cache: pct(cacheBy, r.warehouse_id),
      prune: pct(pruneBy, r.warehouse_id),
    } as Record<EffSort, number | null>,
  })).sort((a, b) => (b.v[sort] ?? -1) - (a.v[sort] ?? -1));
  const dot = (s: any) => (s === "CRITICAL" ? "crit" : s === "WARN" ? "warn" : "ok");
  const busy: Partial<Record<EffSort, boolean>> = { cache: loading(cache), prune: loading(prune) };
  const cell = (k: EffSort, v: number | null) => (busy[k] ? "…" : v == null ? "–" : k === "queries" ? fmtInt(v) : k === "avg" ? secFmt(v) : fmtShare(v));
  const sideNote = [noteOf(cache, p), noteOf(prune, p)].filter((n) => n && n.startsWith("–"));
  return (
    <Panel p={p} src={press} title="Efficiency by warehouse"
      subtitle="warehouse queries only · spill of run time · queued and start-up wait of statement time · cache miss of repeat runs · click a header to sort">
      {rows && (list.length ? (
        <>
          <div className="b2-scroll de-qp-box">
            <table className="de-qp">
              <thead>
                <tr>
                  <th scope="col">Warehouse</th>
                  {EFF_COLS.map((c) => (
                    <th key={c.k} scope="col" className="num" title={c.title} aria-sort={sort === c.k ? "descending" : undefined}>
                      <button type="button" className={`de-sort${sort === c.k ? " on" : ""}`} onClick={() => setSort(c.k)}>{c.label}{sort === c.k ? " ↓" : ""}</button>
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {list.slice(0, 15).map((x) => (
                  <tr key={whKey(x.r)} title={isFlagged(x.r) && x.r.pressure_reason ? String(x.r.pressure_reason) : undefined}>
                    <td className="de-qp-shape">
                      <span className={`de-dot ${dot(x.r.status)}`} aria-hidden="true" title={x.r.pressure_reason ? String(x.r.pressure_reason) : undefined} />
                      <button type="button" className="b2-linkbtn" onClick={() => DrawerBus.open({ id: "query_warehouse_pressure", col: "warehouse_id", val: x.r.warehouse_id != null ? String(x.r.warehouse_id) : null, label: x.name })}>{x.name}</button>
                    </td>
                    {EFF_COLS.map((c) => <td key={c.k} className="num">{cell(c.k, x.v[c.k])}</td>)}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {list.length > 15 && <div className="blk-more">{`+${fmtInt(list.length - 15)} more not shown`}</div>}
          {sideNote.length > 0 && <div className="chart-note-oneline">{`Cache miss or pruning: ${sideNote.map((n) => n!.replace(/^– /, "")).join("; ")}`}</div>}
        </>
      ) : <div className="chart-note-oneline">{`No warehouse ran queries in ${rangeOf(p) || "this window"}.`}</div>)}
    </Panel>
  );
}

// ═══════════════════════ Queries > Heavy ═══════════════════════

/** A statement group as a label: its shape ("SELECT #a1b2c3d4"), never its text. */
function shapeOf(r: Row): string {
  if (r.statement_shape) return String(r.statement_shape);
  const type = String(r.statement_type || r.query_type || "").replace(/_/g, " ");
  const h = r.group_id ?? r.query_parameterized_hash ?? r.query_hash;
  return `${type || "statement"}${h ? ` #${String(h).slice(0, 8)}` : ""}`;
}

function QHeavy(p: ApPageProps) {
  const pat = useQueryPatterns(p.filters, 10);
  const topF = findingOf(p, "query_top_by_cost");
  const byType = useRows(p, "sf_query_cost_by_statement_type");
  const repSrc = useFlaggedRows(p, "sf_query_repeated_expensive");
  const shapes = pat.rows || [];
  const typeRows = rowsOf(byType);
  const yDisc = discOf(byType);
  const typePriced = !!typeRows && typeRows.some((r) => r.price_basis !== "unpriced" && r.est_attributed_usd_list != null);
  const attributed = typeRows ? typeRows.reduce((s, r) => s + (typePriced ? numOrZero(r.est_attributed_usd_list) * (1 - yDisc) : 0), 0) : 0;
  const top10 = shapes.slice(0, 10).reduce((s, x) => s + x.usd, 0);
  const share = typePriced && pat.rows ? pctOf(top10, attributed) : null;
  const segs: ShareSegment[] = (typeRows || []).map((r) => ({
    key: r.statement_type, label: String(r.statement_type || "(unknown)").replace(/_/g, " "),
    value: typePriced ? numOrZero(r.est_attributed_usd_list) * (1 - yDisc) : numOrZero(r.attributed_credits), unknown: !r.statement_type,
  }));
  const patNote = !topF ? "– Not in this export: run the export again." : aggNote(pat.state, p.meta, p.filters.window);
  const rep = repSrc.f, longQ = findingOf(p, "sf_query_long_running");
  const repRows = rowsOf(repSrc);
  const repDisc = discOf(repSrc);
  const repUsd = (r: Row) => numOrZero(r.est_usd_list) * (1 - repDisc);
  const repSpend = repRows ? repRows.reduce((s, r) => s + repUsd(r), 0) : null;
  const repItems: StatusBarItem[] = (repRows || []).map((r) => ({
    key: `${whKey(r)}|${r.query_parameterized_hash}`, name: `${String(r.query_type || "statement").replace(/_/g, " ")} #${String(r.query_parameterized_hash || "").slice(0, 8)} · ${whLabel(r, p)}`,
    value: repUsd(r), status: r.status,
    valueText: `${fmtMoney(repUsd(r), 0)} · ${fmtInt(r.runs)} runs${r.runs_per_day != null ? ` · ${Number(r.runs_per_day).toFixed(0)} / day` : ""}`,
  }));

  // The lede: the top shapes' share, then the statement type most of them are.
  const byKind = new Map<string, number>();
  shapes.forEach((s) => { const k = s.shape.split(" ")[0]; byKind.set(k, (byKind.get(k) || 0) + s.usd); });
  const topKind = [...byKind.entries()].sort((a, b) => b[1] - a[1])[0];
  const lede = pat.state.phase === "loading" || loading(byType) ? "…" : share != null
    ? `The top ${fmtInt(Math.min(10, shapes.length))} statement shapes are ${fmtShare(share)} of attributed compute${topKind ? `; ${fmtShare(pctOf(topKind[1], top10))} of that is ${topKind[0]}` : ""}.`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="ac-page">
      <Tiles>
        <IssueTile label="Top 10 statement shapes" loading={pat.state.phase === "loading" || loading(byType)}
          headline={share != null ? fmtShare(share) : null} unit="of attributed compute"
          missingReason={(patNote || "").replace(/^– /, "") || missingOf(byType, p) || "no $/credit price in this export"}
          base={share != null ? `${fmtMoney(top10, 0)} of ${fmtMoney(attributed, 0)} · ${fmtInt(Math.min(10, shapes.length))} of ${fmtInt(pat.shapes ?? shapes.length)} shapes` : null}
          cause={shapes[0] ? `Most: ${shapes[0].shape}, ${fmtMoney(shapes[0].usd, 0)} in ${fmtInt(shapes[0].runs)} runs.` : null}
          status={statusOf(topF)} onOpen={() => scrollToAnchor("ac-patterns")} openLabel="Query patterns ↓" />
        <CountTile p={p} f={rep} label="Expensive statements run again and again"
          extra={repSpend != null && repSpend > 0 ? `${fmtMoney(repSpend, 0)} spend on the ${fmtInt((repRows || []).length)} flagged shapes · context` : null}
          cause="Precompute as a dynamic table or materialized view." />
        <CountTile p={p} f={longQ} label="Long-running statements"
          cause="Set STATEMENT_TIMEOUT_IN_SECONDS; the default is two days." />
      </Tiles>
      <Row2>
        <Panel p={p} src={byType} title="Attributed compute, by statement type" subtitle="idle time and queries under about 100 ms are not in it">
          <StackedShareBar segments={segs} pareto valueFmt={typePriced ? usdFmt : (v) => `${fmtInt(Math.round(v))} credits`} ariaLabel="Attributed compute by statement type" />
        </Panel>
        <Panel p={p} src={repSrc} title="Repeats: the same expensive shape, run again" subtitle="flagged shapes · $ · runs · runs a day · spend is context">
          <RankedOrLine items={repItems} n={6} valueFmt={usdFmt} unitLabel="$" ariaLabel="Repeated expensive shapes" emptyText="No expensive shape repeats in this window."
            onBarClick={() => DrawerBus.open({ id: "sf_query_repeated_expensive" })} />
        </Panel>
      </Row2>
      <div id="ac-patterns">
        <ChartCard title="Query patterns" subtitle={`grouped by shape; the SQL text is never shown · sort any column${pat.shapes != null ? ` · top ${fmtInt(Math.min(10, shapes.length))} of ${fmtInt(pat.shapes)} shapes` : ""}`} onOpenCheck={openCheck(p, "query_top_by_cost")} takeaway={null}>
          {patNote ? <div className="chart-note-oneline">{patNote}</div>
            : shapes.length ? <QueryPatternTable rows={shapes} n={10} onOpen={(r) => DrawerBus.open({ id: "query_top_by_cost", col: "group_id", val: r.groupId, label: r.shape })} />
              : <div className="chart-note-oneline">{`No statement cost in ${rangeOf(p) || "this window"}.`}</div>}
        </ChartCard>
      </div>
    </div>
  );
}
(QHeavy as any).ownsLede = true;

/** A tile for a count-only check: the flagged share of what it assessed. */
function CountTile({ p, f, label, extra, cause }: { p: ApPageProps; f: Finding | null; label: string; extra?: string | null; cause?: string | null }) {
  const a = affectedOf(f);
  const b = f ? bandOf(f) : "NOT_ASSESSED";
  const ran = !!f && b !== "NOT_ASSESSED" && b !== "ERROR";
  const empty = b === "EMPTY_WINDOW" || b === "EMPTY_FILTERS";
  return (
    <IssueTile label={label}
      headline={!ran ? null : empty ? "None" : a && a.total ? fmtShare(pctOf(a.flagged, a.total)) : a ? fmtInt(a.flagged) : null}
      unit={ran && !empty && a && a.total ? ` of ${a.noun || "rows"}` : undefined}
      missingReason={!f ? "not in this export" : (f.not_assessed && f.not_assessed.label) || "did not run"}
      base={ran && !empty && a ? [`${fmtInt(a.flagged)}${a.total ? ` of ${fmtInt(Math.max(a.total, a.flagged))}` : ""}${a.noun ? ` ${a.noun}` : ""}`, extra || null].filter(Boolean).join(" · ") : undefined}
      cause={ran ? cause : null}
      status={statusOf(f)} onOpen={f ? () => DrawerBus.open({ id: f.query_id }) : undefined} />
  );
}

// ═══════════════════════ Queries > Efficiency ═══════════════════════

type EffKey = "spill" | "prune" | "cache" | "compile";
interface EffWh { key: string; name: string; part: number; whole: number; status: string }
interface EffShape { wh: string; name: string; usd: number; text: string; status: string }

function QEfficiency(p: ApPageProps) {
  const press = useRows(p, "query_warehouse_pressure");
  const remote = useRows(p, "sf_query_remote_spill");
  const prune = useAgg(p, "query_pruning_effectiveness", ["warehouse_id", "warehouse_name", "status"], "sum", "query_count");
  // The shape lists read flagged rows only; the warehouse bars read sums, never every row.
  const scans = useFlaggedRows(p, "sf_query_full_scans");
  const cache = useAgg(p, "sf_query_result_cache_misses", ["warehouse_id", "warehouse_name", "status"], "sum", "repeats", { also: ["missed_runs"] });
  const cacheShapes = useFlaggedRows(p, "sf_query_result_cache_misses");
  const comp = useRows(p, "sf_query_compilation_heavy");
  const slow = useFlaggedRows(p, "sf_perf_query_shape_regression");

  const byWh = (rows: Row[] | null, part: (r: Row) => number, whole: (r: Row) => number): EffWh[] | null =>
    rows ? sumBy(rows.filter((r) => r.status !== "NOT_ASSESSED"), (r) => String(r.warehouse_id ?? r.warehouse_name ?? ""), (r) => whLabel(r, p), { part, whole })
      .map((w) => ({ key: String(w.rows[0].warehouse_id ?? w.rows[0].warehouse_name ?? ""), name: w.name, part: w.part, whole: w.whole, status: worstStatus(w.rows) }))
      .filter((w) => w.whole > 0) : null;
  const pruneGroups = groupsOf(prune);
  const pruneWh: EffWh[] | null = pruneGroups ? (() => {
    const m = new Map<string, EffWh>();
    pruneGroups.forEach((g) => {
      const [id, name, st] = g.key;
      if (st === "NOT_ASSESSED") return;
      const k = String(id ?? name ?? "");
      const cur = m.get(k) || { key: k, name: rowLabelOf({ warehouse_id: id, warehouse_name: name }, name ? "warehouse_name" : "warehouse_id", p.dims) || "(no warehouse)", part: 0, whole: 0, status: "OK" };
      cur.whole += numOrZero(g.value);
      if (st === "CRITICAL" || st === "WARN") { cur.part += numOrZero(g.value); if (cur.status !== "CRITICAL") cur.status = st; }
      m.set(k, cur);
    });
    return [...m.values()].filter((w) => w.whole > 0);
  })() : null;

  const shapesFrom = (src: Src, usdCol: string, text: (r: Row) => string): EffShape[] => {
    const d = discOf(src);
    return (rowsOf(src) || []).filter(isFlagged).map((r) => ({
      wh: String(r.warehouse_id ?? r.warehouse_name ?? ""), name: shapeOf(r), usd: numOrZero(r[usdCol]) * (1 - d), text: text(r), status: r.status,
    }));
  };
  const M: Record<EffKey, { label: string; noun: string; src: Src; whs: EffWh[] | null; shapes: () => EffShape[]; shapeSrc: Src; shapeTitle: string }> = {
    spill: {
      label: "Queries that spill", noun: "queries", src: press,
      whs: byWh(rowsOf(press), (r) => r.spilling_query_count, (r) => r.query_count),
      shapeSrc: remote, shapeTitle: "spilled to remote storage",
      shapes: () => shapesFrom(remote, "est_usd_list", (r) => `${fmtInt(Math.round(numOrZero(r.remote_spill_gb)))} GB remote · ${fmtInt(r.spilling_runs)} runs`),
    },
    prune: {
      label: "Queries with poor pruning", noun: "queries", src: prune, whs: pruneWh,
      shapeSrc: scans, shapeTitle: "read most of the table",
      shapes: () => shapesFrom(scans, "est_usd_list", (r) => `${fmtShare(numOrZero(r.avg_scan_pct))} scanned · ${fmtInt(r.runs)} runs`),
    },
    cache: {
      label: "Repeats that missed the result cache", noun: "repeat runs", src: cache,
      whs: byWh(rowsOf(cache), (r) => r.missed_runs, (r) => r.repeats),
      shapeSrc: cacheShapes, shapeTitle: "re-ran instead of using the result cache",
      shapes: () => shapesFrom(cacheShapes, "est_usd_list", (r) => `${fmtInt(r.missed_runs)} of ${fmtInt(r.repeats)} runs missed`),
    },
    compile: {
      label: "Runs where compile time dominates", noun: "runs", src: comp,
      whs: byWh(rowsOf(comp), (r) => (isFlagged(r) ? r.runs : 0), (r) => r.runs),
      shapeSrc: comp, shapeTitle: "spend most of their time compiling",
      shapes: () => shapesFrom(comp, "est_billed_cs_usd_list", (r) => `${fmtShare(numOrZero(r.compile_pct))} compiling · ${fmtInt(r.runs)} runs`),
    },
  };
  // One tile per measure: the flagged share of what it judged, from the same sums as the cards.
  // whsOnly: "(no warehouse)" statements count in the sums, but not as a warehouse (the checks list does the same)
  const tot = (k: EffKey, whsOnly = false) => {
    const w = M[k].whs || [];
    const ws = whsOnly ? w.filter((x) => x.key !== "" && !/^\(.*\)$/.test(x.key) && !/^\(.*\)$/.test(x.name)) : w;
    return { part: w.reduce((s, x) => s + x.part, 0), whole: w.reduce((s, x) => s + x.whole, 0), whs: ws.filter((x) => x.part > 0).length, all: ws.length };
  };
  const shapeUsd = (k: EffKey) => M[k].shapes().reduce((s, x) => s + x.usd, 0);
  const extra: Record<EffKey, () => string | null> = {
    spill: () => null,
    prune: () => { const t = tot("prune", true); return t.all ? `${fmtInt(t.whs)} of ${fmtInt(t.all)} warehouses` : null; },
    cache: () => { const u = shapeUsd("cache"); return u > 0 ? `${fmtMoney(u, 0)} spend · context` : null; },
    compile: () => { const t = tot("compile", true); return t.all ? `${fmtInt(t.whs)} of ${fmtInt(t.all)} warehouses` : null; },
  };
  const why: Record<EffKey, string> = {
    spill: "Spill means the warehouse ran out of memory for the query.",
    prune: "They read most of the table's partitions for a few rows.",
    cache: "Identical text ran again and scanned; some re-runs are right when the data changed.",
    compile: "Many small statements: batch them, or load with COPY.",
  };
  const tile = (k: EffKey) => {
    const m = M[k], t = tot(k), note = noteOf(m.src, p);
    const ok = !note && t.whole > 0;
    return (
      <IssueTile key={k} label={m.label} loading={note === "…"} headline={ok ? fmtShare(pctOf(t.part, t.whole)) : null} unit={`of ${m.noun}`}
        missingReason={note && note !== "…" ? note.replace(/^– /, "") : `none judged in ${rangeOf(p) || "this window"}`}
        base={ok ? [`${fmtInt(t.part)} of ${fmtInt(t.whole)} ${m.noun}`, extra[k]()].filter(Boolean).join(" · ") : null}
        cause={ok ? why[k] : null} status={statusOf(m.src.f)} onOpen={() => scrollToAnchor(`ac-eff-${k}`)} openLabel="By warehouse ↓" />
    );
  };
  const whItems = (k: EffKey): ShareItem[] => (M[k].whs || []).filter((w) => w.part > 0).map((w) => ({ key: w.key, name: w.name, value: w.part, total: w.whole, status: w.status }));
  const shapeItems = (k: EffKey): StatusBarItem[] => M[k].shapes().sort((a, b) => b.usd - a.usd)
    .map((s, i) => ({ key: `${s.wh}-${s.name}-${i}`, name: s.name, value: s.usd, status: s.status, valueText: `${fmtMoney(s.usd, 0)} · ${s.text}` }));

  const cacheT = tot("cache"), pruneT = tot("prune");
  const lede = loading(cache) || loading(prune) ? "…" : [
    cacheT.whole > 0 ? `Repeat queries missed the result cache ${fmtShare(pctOf(cacheT.part, cacheT.whole))} of the time` : null,
    pruneT.whole > 0 ? `${fmtShare(pctOf(pruneT.part, pruneT.whole))} of queries pruned poorly` : null,
  ].filter(Boolean).join("; ") || null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede ? (lede === "…" ? lede : `${lede}.`) : null); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="ac-page">
      <Tiles>{(Object.keys(M) as EffKey[]).map(tile)}</Tiles>
      <Row2>
        <div id="ac-eff-prune">
          <Panel p={p} src={scans} title="Poor pruning, by statement shape" subtitle="flagged shapes · share of partitions scanned · $ is spend, context">
            <RankedOrLine items={shapeItems("prune")} n={6} valueFmt={usdFmt} unitLabel="$" ariaLabel="Statement shapes that scan most of the table" emptyText="No shape scans most of its table in this window." onBarClick={() => DrawerBus.open({ id: scans.id })} />
          </Panel>
        </div>
        <div id="ac-eff-cache">
          <Panel p={p} src={cache} title="Cache misses, by warehouse" subtitle="repeat runs that re-ran instead of being served from the result cache">
            <ShareBarList items={whItems("cache")} noun="repeat runs" emptyText={`None in ${rangeOf(p) || "this window"}.`} />
          </Panel>
        </div>
      </Row2>
      <Row2>
        <div id="ac-eff-compile">
          <Panel p={p} src={comp} title="Compile time dominates, by warehouse" subtitle="runs where compiling took longer than running">
            <ShareBarList items={whItems("compile")} noun="runs" emptyText={`None in ${rangeOf(p) || "this window"}.`} />
          </Panel>
        </div>
        <div id="ac-eff-spill">
          <Panel p={p} src={remote} title="Statement shapes that spill" subtitle="spilled to remote storage · $ is spend, context">
            <RankedOrLine items={shapeItems("spill")} n={6} valueFmt={usdFmt} unitLabel="$" ariaLabel="Statement shapes that spill to remote storage" emptyText="No shape spilled to remote storage in this window." onBarClick={() => DrawerBus.open({ id: remote.id })} />
          </Panel>
        </div>
      </Row2>
      <Panel p={p} src={slow} title="Statement shapes that got slower" subtitle="median run time, last week vs the days before · compile + execution, no queueing · $ is a change, not waste">
        <RankedOrLine items={(rowsOf(slow) || []).map((r) => {
          const usd = numOrZero(r.est_change_usd_list) * (1 - discOf(slow));
          return {
            key: `${r.account_id}|${r.warehouse_id}|${r.query_parameterized_hash}`, name: `${shapeOf(r)} · ${whLabel(r, p)}`, value: numOrZero(r.growth_pct), status: r.status,
            valueText: [`${fmtDuration(numOrZero(r.base_p50_s))} → ${fmtDuration(numOrZero(r.recent_p50_s))}`, SLOW_CAUSE[String(r.likely_cause)] || null,
              usd > 0 ? `+${fmtMoney(usd, 0)}` : null].filter(Boolean).join(" · "),
          };
        })} n={8} valueFmt={(v) => `+${fmtShare(v)}`} unitLabel="% slower" ariaLabel="Statement shapes that got slower"
          emptyText={`No statement shape got slower in ${rangeOf(p) || "this window"}.`} onBarClick={() => DrawerBus.open({ id: slow.id })} />
      </Panel>
    </div>
  );
}
(QEfficiency as any).ownsLede = true;
// sf_perf_query_shape_regression.likely_cause, in words; worse pruning points at the table check
const SLOW_CAUSE: Record<string, string> = { worse_pruning: "pruning got worse", more_data: "reads more data", spilling: "now spills", compile: "compiles longer", plan: "plan changed?" };

// ═══════════════════════ Queries > Failures ═══════════════════════

function QFailures(p: ApPageProps) {
  const failDays = useAgg(p, "query_failed_queries_daily", ["day", "execution_status"], "sum", "query_count");
  const allDays = useAgg(p, "query_workload_mix_hours", ["day"], "sum", "query_count");
  const errs = useRows(p, "sf_query_failed_by_error");
  const whFail = useRows(p, "cost_failed_statement_waste");
  const waste = findingOf(p, "cost_failed_statement_waste"), retries = findingOf(p, "sf_perf_query_retries");
  const [day, setDay] = React.useState<string | null>(null);
  const [grain, setGrain] = React.useState<Grain>("day");
  // Each warehouse's top user and error, from the per-warehouse daily rows (the error check is per code, not warehouse).
  const whUser = useAgg(p, "query_failed_queries_daily", ["warehouse_id", "executed_by"], "sum", "query_count");
  const whErr = useAgg(p, "query_failed_queries_daily", ["warehouse_id", "error_message_sample"], "sum", "query_count");
  // A clicked day's causes: sums by day and one column each, fetched only once a day is open.
  const FD = "query_failed_queries_daily";
  const dayBy = {
    error: useAgg(p, FD, ["day", "error_message_sample"], "sum", "query_count", { off: !day }),
    user: useAgg(p, FD, ["day", "executed_by"], "sum", "query_count", { off: !day }),
    warehouse: useAgg(p, FD, ["day", "warehouse_id"], "sum", "query_count", { off: !day }),
    type: useAgg(p, FD, ["day", "statement_type"], "sum", "query_count", { off: !day }),
  };

  const fg = groupsOf(failDays), ag = groupsOf(allDays);
  const isCancel = (s: any) => /CANCEL/i.test(String(s || ""));
  const failed = new Map<string, number>();
  let nFailed = 0, nCancel = 0;
  (fg || []).forEach((g) => {
    const d = String(g.key[0]).slice(0, 10), v = numOrZero(g.value);
    failed.set(d, (failed.get(d) || 0) + v);
    if (isCancel(g.key[1])) nCancel += v; else nFailed += v;
  });
  const total = new Map<string, number>((ag || []).map((g) => [String(g.key[0]).slice(0, 10), numOrZero(g.value)]));
  // The month view: every day of the window summed into months, failed and cancelled kept apart.
  const failedOnly = new Map<string, number>(), cancelOnly = new Map<string, number>();
  (fg || []).forEach((g) => { const d = String(g.key[0]).slice(0, 10), m = isCancel(g.key[1]) ? cancelOnly : failedOnly; m.set(d, (m.get(d) || 0) + numOrZero(g.value)); });
  const days = [...new Set([...total.keys(), ...failed.keys()])].sort();
  const sumF = [...failed.values()].reduce((s, v) => s + v, 0), sumT = [...total.values()].reduce((s, v) => s + v, 0);
  const pctByDay = days.map((d) => ({ d, pct: pctOf(failed.get(d) || 0, total.get(d) || 0) ?? 0 }));
  const sortedPct = pctByDay.map((x) => x.pct).sort((a, b) => a - b);
  const median = sortedPct.length ? sortedPct[Math.floor(sortedPct.length / 2)] : 0;
  // A spike day fails at least twice the usual rate and two points above it.
  const spikes = new Set(pctByDay.filter((x) => x.pct >= Math.max(2 * median, median + 2) && x.pct > 0).map((x) => x.d));
  const worst = [...pctByDay].sort((a, b) => b.pct - a.pct)[0];
  const share = fg && ag ? pctOf(sumF, sumT) : null;

  const errRows = rowsOf(errs);
  const byCode = errRows ? sumBy(errRows, (r) => String(r.error_code ?? "?"), (r) => `Error ${r.error_code ?? "?"}`, { n: (r) => r.failures }) : [];
  const codeAll = byCode.reduce((s, x) => s + x.n, 0);
  const codeItems: StatusBarItem[] = byCode.map((c) => {
    const lead = [...c.rows].sort((a, b) => numOrZero(b.failures) - numOrZero(a.failures))[0];
    const pattern = lead && lead.error_pattern ? `: ${String(lead.error_pattern).slice(0, 40)}` : "";
    return { key: c.name, name: `${c.name}${pattern}`, value: c.n, status: worstStatus(c.rows), valueText: `${fmtInt(c.n)} · ${fmtShare(pctOf(c.n, codeAll))}` };
  });
  const topCode = [...byCode].sort((a, b) => b.n - a.n)[0];
  const topPattern = topCode ? [...topCode.rows].sort((a, b) => numOrZero(b.failures) - numOrZero(a.failures))[0] : null;

  // Where failures land: each warehouse's failed statements, with its top user and error message by warehouse id.
  const whRows = rowsOf(whFail);
  const wDisc = discOf(whFail);
  const topBy = (src: Src) => {
    const m = new Map<string, { k: string; n: number }>();
    (groupsOf(src) || []).forEach((g) => {
      const id = String(g.key[0] ?? ""), k = g.key[1] == null || g.key[1] === "" ? null : String(g.key[1]);
      if (!k) return;
      const cur = m.get(id);
      if (!cur || numOrZero(g.value) > cur.n) m.set(id, { k, n: numOrZero(g.value) });
    });
    return m;
  };
  const userByWh = topBy(whUser), errByWh = topBy(whErr);
  const whList = (whRows || []).map((r) => {
    const name = whLabel(r, p), id = String(r.warehouse_id ?? "");
    const n = numOrZero(r.failed_statements) + numOrZero(r.canceled_statements);
    return { r, name, n, of: pctOf(n, numOrZero(r.statements)), usd: r.est_wasted_usd_list != null ? numOrZero(r.est_wasted_usd_list) * (1 - wDisc) : null,
      user: userByWh.get(id)?.k ?? null, err: errByWh.get(id)?.k ?? null };
  }).filter((w) => w.n > 0).sort((a, b) => b.n - a.n);
  const whAll = whList.reduce((s, w) => s + w.n, 0);

  const wM = moneyHeadline(waste), rM = moneyHeadline(retries);
  const wA = affectedOf(waste), rA = affectedOf(retries);
  const partial = days.length ? partialBarKeys(days, false)[0] || null : null;
  const lede = loading(failDays) || loading(allDays) ? "…" : share != null
    ? `${fmtInt(sumF)} of ${fmtInt(sumT)} queries failed or were cancelled${spikes.size ? `; the worst rate was ${fmtShare(worst.pct)} on ${fmtDayShort(worst.d)}` : ""}.${topCode && codeAll > 0 ? ` One error code is ${fmtShare(pctOf(topCode.n, codeAll))} of them.` : ""}`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div className="ac-page">
      <Tiles>
        <IssueTile label="Failed or cancelled" loading={loading(failDays) || loading(allDays)}
          headline={share != null ? fmtShare(share) : null} unit="of queries"
          missingReason={missingOf(failDays, p) || missingOf(allDays, p)}
          base={fg && ag ? `${fmtInt(sumF)} of ${fmtInt(sumT)} queries · ${fmtInt(nFailed)} failed · ${fmtInt(nCancel)} cancelled` : undefined}
          cause={spikes.size ? `Worst rate ${fmtDayShort(worst.d)}: ${fmtShare(worst.pct)}, ${fmtInt(failed.get(worst.d) || 0)} queries.` : (fg && ag ? "No spike day." : null)}
          status={statusOf(findingOf(p, FD))} onOpen={() => scrollToAnchor("qf-day")} openLabel="Per day ↓" />
        <IssueTile label="Compute used by failed SQL" headline={wM.headline} unit={wM.headline && wM.headline !== "None" ? "possible waste" : undefined} missingReason={wM.why}
          base={wA ? `${fmtInt(wA.flagged)} of ${fmtInt(Math.max(wA.total, wA.flagged))} ${wA.noun || "warehouses"}` : undefined}
          cause="Some is unavoidable; most of it is one error code." status={statusOf(waste)} onOpen={() => scrollToAnchor("qf-where")} openLabel="By warehouse ↓" />
        <IssueTile label="Time lost to retries" headline={rM.headline} unit={rM.headline && rM.headline !== "None" ? "possible waste" : undefined} missingReason={rM.why}
          base={rA ? `${fmtInt(rA.flagged)} of ${fmtInt(Math.max(rA.total, rA.flagged))} ${rA.noun || "warehouses"} · kept apart` : undefined}
          cause="Runs Snowflake retried after a memory or other error." status={statusOf(retries)} onOpen={() => DrawerBus.open({ id: "sf_perf_query_retries" })} />
        <IssueTile label="Top error" loading={loading(errs)} headline={topCode && codeAll > 0 ? fmtShare(pctOf(topCode.n, codeAll)) : null} unit="of failures"
          missingReason={missingOf(errs, p) || "No failure with an error code."}
          base={topCode ? `${fmtInt(topCode.n)} of ${fmtInt(codeAll)} with an error code · ${fmtInt(byCode.filter((c) => isFlagged({ status: worstStatus(c.rows) })).length)} of ${fmtInt(byCode.length)} codes flagged` : undefined}
          cause={topPattern ? `${String(topCode!.name).replace(/^Error /, "")}: ${String(topPattern.error_pattern || "").slice(0, 60)}` : null}
          status={statusOf(errs.f)} onOpen={() => DrawerBus.open({ id: "sf_query_failed_by_error", col: "error_code", val: topCode ? String(topCode.rows[0].error_code) : null, label: topCode ? topCode.name : null })} />
      </Tiles>
      <Row2>
        <div id="qf-day">
          <Panel p={p} src={fg ? allDays : failDays} title={`Failed and cancelled, per ${grain}`}
            subtitle={grain === "day" ? "queries · today is partial · click a day for its cause" : "queries per month · the current month is partial"}>
            {fg && ag && <GrainSwitch value={grain} onChange={setGrain} />}
            {fg && ag && grain === "month" && <FailureMonths days={windowDayList(p.meta, p.filters.window, days)} failed={failedOnly} cancelled={cancelOnly} />}
            {fg && ag && grain === "day" && (
              <>
                <DayKindTimeline
                  rows={(fg || []).map((g) => ({ day: String(g.key[0]).slice(0, 10), kind: isCancel(g.key[1]) ? "Cancelled" : "Failed", value: numOrZero(g.value) }))}
                  days={days} kinds={["Failed", "Cancelled"]} kindColors={{ Failed: "var(--c1)", Cancelled: "var(--c-other)" }}
                  valueFmt={(v) => fmtInt(v)} unitLabel="queries" partialDay={partial} selectedDay={day}
                  onDayClick={(d) => setDay(day === d ? null : d)} ariaLabel="Failed and cancelled queries per day" />
                {spikes.size > 0 && !day && <div className="chart-note-oneline">{`Spike day${spikes.size === 1 ? "" : "s"}: ${[...spikes].sort().map((d) => `${fmtDayShort(d)} · ${fmtInt(failed.get(d) || 0)}`).join(", ")}`}</div>}
                {day && <FailureDay p={p} day={day} by={dayBy} failed={failed.get(day) || 0} total={total.get(day) || 0} />}
              </>
            )}
          </Panel>
        </div>
        <Panel p={p} src={errs} title="Failures by error code" subtitle={`${fmtInt(codeAll)} failed with a code (cancelled ones have none) · share of coded failures · dot = the code's status`}>
          <RankedOrLine items={codeItems} valueFmt={(v) => fmtInt(v)} unitLabel="failures" ariaLabel="Failures by error code" emptyText="No failures in this window."
            onBarClick={(it) => { const c = byCode.find((x) => x.name === it.key); DrawerBus.open({ id: "sf_query_failed_by_error", col: "error_code", val: c ? String(c.rows[0].error_code) : null, label: c ? c.name : null }); }} />
        </Panel>
      </Row2>
      <div id="qf-where">
        <Panel p={p} src={whFail} title="Where failures land · by warehouse" subtitle="failed and cancelled statements on warehouses, retried ones under retries · share of the warehouse's own · top error message and user · failed-SQL $ is possible waste">
          {whRows && (whList.length ? (
            <div className="pl-stack">
              <StackedShareBar pareto valueFmt={(v) => `${fmtInt(v)} statements`} ariaLabel="Failed statements by warehouse"
                segments={whList.map((w) => ({ key: w.name, label: w.name, value: w.n }))} totalLabel={`${fmtInt(whAll)} failed or cancelled on warehouses`} />
              <DrillTable aria="Failures by warehouse" n={8}
                cols={[{ label: "Warehouse" }, { label: "Failed", num: true, width: "auto" }, { label: "Of its", num: true, width: "auto" }, { label: "Top error", width: "auto" }, { label: "Top user", width: "minmax(80px, 1fr)" }, { label: "Failed $", num: true, width: "auto" }]}
                rows={whList.map((w) => ({
                  key: whKey(w.r), status: w.r.status,
                  onOpen: () => DrawerBus.open({ id: "cost_failed_statement_waste", col: "warehouse_id", val: w.r.warehouse_id != null ? String(w.r.warehouse_id) : null, label: w.name }),
                  cells: [w.name, fmtInt(w.n), fmtShare(w.of), w.err ? w.err.slice(0, 40) : "–", w.user || "–", w.usd != null ? fmtMoney(w.usd, 0) : "–"],
                }))} />
            </div>
          ) : <div className="chart-note-oneline">No failed statement in this window.</div>)}
        </Panel>
      </div>
    </div>
  );
}
(QFailures as any).ownsLede = true;

/** Failed and cancelled per month; a month the window does not fully cover is named as partial. */
function FailureMonths({ days, failed, cancelled }: { days: string[]; failed: Map<string, number>; cancelled: Map<string, number> }) {
  const pm = partialMonths(days, true);
  const notes = [pm.open ? `${fmtMonth(pm.open)} is partial: up to today` : null, pm.cut && pm.cut !== pm.open ? `${fmtMonth(pm.cut)} starts mid-month in this window` : null].filter(Boolean);
  return (
    <>
      <GrainLines grain="month" days={days} series={[
        { label: "Failed", color: "var(--c1)", data: days.map((d) => failed.get(d) || 0) },
        { label: "Cancelled", color: "var(--c-other)", data: days.map((d) => cancelled.get(d) || 0) },
      ]} />
      {notes.length > 0 && <div className="chart-note-oneline">{`${notes.join(" · ")}.`}</div>}
    </>
  );
}

/** One day's failures: the top error, user, warehouse and statement type. */
function FailureDay({ p, day, by, failed, total }: { p: ApPageProps; day: string; by: Record<"error" | "user" | "warehouse" | "type", Src>; failed: number; total: number }) {
  const note = noteOf(by.error, p) || noteOf(by.user, p) || noteOf(by.warehouse, p) || noteOf(by.type, p);
  const topOf = (src: Src, key: (r: Row) => string) => {
    const rows = (rowsOf(src) || []).filter((r) => String(r.day).slice(0, 10) === day);
    const m = sumBy(rows, key, key, { n: (r) => r.query_count }).sort((a, b) => b.n - a.n)[0];
    return m ? `${m.name} (${fmtShare(pctOf(m.n, failed))})` : "–";
  };
  return (
    <div className="ac-day">
      <div className="ac-day-head">{`${fmtDayShort(day)}: ${fmtShare(pctOf(failed, total))} failed · ${fmtInt(failed)} of ${fmtInt(total)} queries`}</div>
      {note ? <div className="chart-note-oneline">{note}</div> : (
        <dl className="ac-day-facts">
          <dt>Error</dt><dd>{topOf(by.error, (r) => String(r.error_message_sample || "(no message)").slice(0, 48))}</dd>
          <dt>User</dt><dd>{topOf(by.user, (r) => String(r.executed_by || "(no user)"))}</dd>
          <dt>Warehouse</dt><dd>{topOf(by.warehouse, (r) => (r.warehouse_id != null ? whLabel(r, p) : "(no warehouse)"))}</dd>
          <dt>Type</dt><dd>{topOf(by.type, (r) => String(r.statement_type || "(unknown)").replace(/_/g, " "))}</dd>
        </dl>
      )}
    </div>
  );
}

// ═══════════════════════ Queries > Waiting ═══════════════════════

function QWaiting(p: ApPageProps) {
  // One call per grain: all queries as the value, the queued ones summed alongside.
  const all = useAgg(p, "query_queuing_waits", ["warehouse_id", "day"], "sum", "query_count", { also: ["queued_at_capacity_count", "waiting_at_capacity_ms_sum"] });
  const queued = all;
  const prov = useAgg(p, "query_queuing_waits", ["warehouse_id"], "sum", "waited_for_compute_count", { also: ["waiting_for_compute_ms_sum"] });
  const locks = useRows(p, "sf_query_blocked_lock_waits");
  const aHour = useAgg(p, "query_queuing_waits", ["day_of_week", "hour_of_day"], "sum", "query_count", { also: ["queued_at_capacity_count"] });
  const qg = alsoGroups(all, "queued_at_capacity_count"), ag = groupsOf(all), pg = groupsOf(prov);
  const key = (wh: any, d: any) => `${wh}|${String(d).slice(0, 10)}`;
  const qMap = new Map<string, number>((qg || []).map((g) => [key(g.key[0], g.key[1]), numOrZero(g.value)]));
  const aMap = new Map<string, number>((ag || []).map((g) => [key(g.key[0], g.key[1]), numOrZero(g.value)]));
  // Every day of the window keeps its column; a day with no queries is hatched, not skipped.
  const days = windowDayList(p.meta, p.filters.window, (ag || []).map((g) => String(g.key[1]).slice(0, 10)));
  const whs = new Map<string, { q: number; a: number }>();
  (ag || []).forEach((g) => {
    const w = String(g.key[0]);
    const cur = whs.get(w) || { q: 0, a: 0 };
    cur.a += numOrZero(g.value); cur.q += qMap.get(key(g.key[0], g.key[1])) || 0;
    whs.set(w, cur);
  });
  const sumQ = [...whs.values()].reduce((s, w) => s + w.q, 0), sumA = [...whs.values()].reduce((s, w) => s + w.a, 0);
  const sumP = (pg || []).reduce((s, g) => s + numOrZero(g.value), 0);
  const rowsW = [...whs.entries()].filter(([, w]) => w.q > 0).sort((a, b) => b[1].q - a[1].q).slice(0, 12);
  const whName = (id: string) => rowLabelOf({ warehouse_id: id === "null" ? null : id }, "warehouse_id", p.dims) || "(no warehouse)";
  const lockRows = rowsOf(locks);
  const lockMin = lockRows ? lockRows.reduce((s, r) => s + numOrZero(r.blocked_minutes), 0) : 0;
  const lockTop = lockRows ? [...lockRows].sort((a, b) => numOrZero(b.blocked_minutes) - numOrZero(a.blocked_minutes))[0] : null;
  const lockItems: StatusBarItem[] = (lockRows || []).map((r) => ({
    key: `${r.account_id}|${r.object_id}`, name: chartLabel(r.object_name, r.object_id), value: numOrZero(r.blocked_minutes), status: r.status,
    valueText: `${minFmt(numOrZero(r.blocked_minutes))} · ${fmtInt(r.blocked_statements)} statements`,
  }));
  const topW = rowsW[0];
  // Queue and start-up time in seconds, and start-up waits per warehouse.
  const qSec = (ag ? (all.state.data!.groups || []).reduce((s: number, g: any) => s + numOrZero(g.also && g.also.waiting_at_capacity_ms_sum), 0) : 0) / 1000;
  const topQSec = topW ? (all.state.data!.groups || []).filter((g: any) => String(g.key[0]) === topW[0]).reduce((s: number, g: any) => s + numOrZero(g.also && g.also.waiting_at_capacity_ms_sum), 0) / 1000 : 0;
  const pSec = (pg ? (prov.state.data!.groups || []).reduce((s: number, g: any) => s + numOrZero(g.also && g.also.waiting_for_compute_ms_sum), 0) : 0) / 1000;
  const provItems: StatusBarItem[] = (pg ? prov.state.data!.groups || [] : []).filter((g: any) => g.key && g.key[0] != null)
    .map((g: any) => ({ key: String(g.key[0]), name: whName(String(g.key[0])), value: numOrZero(g.also && g.also.waiting_for_compute_ms_sum) / 1000, status: "OK",
      valueText: `${fmtDuration(numOrZero(g.also && g.also.waiting_for_compute_ms_sum) / 1000)} · ${fmtInt(g.value)} queries` }))
    .filter((it: StatusBarItem) => it.value > 0);
  const lockAff = affectedOf(locks.f);

  const lede = loading(all) ? "…" : qg && ag
    ? (sumQ > 0
      ? `${fmtShare(pctOf(sumQ, sumA))} of queries waited ${fmtDuration(qSec)} for a full warehouse${topW ? `; ${whName(topW[0])} has ${fmtShare(pctOf(topQSec, qSec))} of that time` : ""}.`
      : `No query queued for a full warehouse in ${rangeOf(p) || "this window"}.`)
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="ac-page">
      <Tiles>
        <IssueTile label="Queued: warehouse at capacity" loading={loading(queued) || loading(all)}
          headline={qg && ag ? fmtShare(pctOf(sumQ, sumA)) : null} unit="of queries" missingReason={missingOf(queued, p)}
          base={qg && ag ? `${fmtInt(sumQ)} of ${fmtInt(sumA)} queries · ${fmtDuration(qSec)} in total` : null}
          cause={topW ? `${whName(topW[0])}: ${fmtShare(pctOf(topW[1].q, topW[1].a))} of its queries queue, ${fmtShare(pctOf(topQSec, qSec))} of all queue time.` : null}
          status={statusOf(queued.f)} onOpen={() => scrollToAnchor("ac-wait-hour")} openLabel="By weekday and hour ↓" />
        <IssueTile label="Waited for compute to start" loading={loading(prov) || loading(all)} pill={<StatusPill kind="neutral" />}
          headline={pg && ag ? fmtShare(pctOf(sumP, sumA)) : null} unit="of queries" missingReason={missingOf(prov, p)}
          base={pg && ag ? `${fmtInt(sumP)} of ${fmtInt(sumA)} queries · ${fmtDuration(pSec)} in total` : null}
          cause="Resume after auto-suspend, or scale-out: a few seconds here pays for the idle saved." status="neutral" onOpen={() => scrollToAnchor("ac-wait-start")} openLabel="By warehouse ↓" />
        <IssueTile label="Blocked on locks" loading={loading(locks)}
          headline={lockRows ? fmtInt(Math.round(lockMin)) : null} unit="min waiting on a lock" missingReason={missingOf(locks, p)}
          base={lockRows ? [lockAff ? `${fmtInt(lockAff.flagged)} of ${fmtInt(lockAff.total)} ${lockAff.noun}` : null,
            lockTop && lockMin > 0 ? `${fmtShare(pctOf(numOrZero(lockTop.blocked_minutes), lockMin))} on ${chartLabel(lockTop.object_name, lockTop.object_id)}` : null].filter(Boolean).join(" · ") : null}
          status={statusOf(locks.f)} onOpen={() => scrollToAnchor("ac-wait-locks")} openLabel="By object ↓" />
      </Tiles>
      <div id="ac-wait-hour">
        <HourPanel p={p} src={aHour} title="Queued %, weekday by hour (UTC)" subtitle="share of queries that queued at capacity · darker is worse">
          {(() => {
            const qh = alsoGroups(aHour, "queued_at_capacity_count"), ah = groupsOf(aHour);
            if (!qh || !ah) return null;
            const grid = weekHourGrid(ah, qh, (q, a) => (a > 0 ? (pctOf(q, a) ?? 0) : null));
            return grid.some((r) => r.some((v) => v != null && v > 0))
              ? <WeekHourHeatmap grid={grid} ariaLabel="Queued share by weekday and hour" legendLow="few queued" legendHigh="most queued"
                  tip={(wd, h, v) => `${wd} ${String(h).padStart(2, "0")}:00 UTC: ${v == null ? "no queries" : `${fmtShare(v)} queued`}`} />
              : <div className="chart-note-oneline">{`No query queued at capacity in ${rangeOf(p) || "this window"}.`}</div>;
          })()}
        </HourPanel>
      </div>
      <Row2>
        <Panel p={p} src={qg ? all : queued} title="Queued %, warehouse by day" subtitle="share of each warehouse's queries that queued · darker is worse">
          {qg && ag && (rowsW.length
            ? <QueueHeat rows={rowsW.map(([id, w]) => ({ id, name: whName(id), total: pctOf(w.q, w.a) }))} days={days}
                cell={(id, d) => { const a = aMap.get(key(id, d)) || 0; return a ? pctOf(qMap.get(key(id, d)) || 0, a) : null; }} />
            : <div className="chart-note-oneline">{`No query queued at capacity in ${rangeOf(p) || "this window"}.`}</div>)}
        </Panel>
        <div id="ac-wait-locks">
          <Panel p={p} src={locks} title="Blocked on locks, by object" subtitle="minutes statements waited on a lock">
            <RankedOrLine items={lockItems} valueFmt={minFmt} unitLabel="minutes" ariaLabel="Lock waits by object" emptyText="No lock waits in this window." onBarClick={() => DrawerBus.open({ id: "sf_query_blocked_lock_waits" })} />
          </Panel>
        </div>
      </Row2>
      <div id="ac-wait-start">
        <Panel p={p} src={prov} title="Waited for compute to start" subtitle={`${pg ? `${fmtDuration(pSec)} · ` : ""}by warehouse · resume after auto-suspend, or scale-out`}>
          <RankedOrLine items={provItems} n={6} valueFmt={(v) => fmtDuration(v)} unitLabel="waiting to start" ariaLabel="Time waiting for compute to start, by warehouse"
            emptyText={`No query waited for compute to start in ${rangeOf(p) || "this window"}.`} onBarClick={openCheck(p, "query_queuing_waits")} />
        </Panel>
      </div>
    </div>
  );
}
(QWaiting as any).ownsLede = true;

/** Sums by (day_of_week, hour_of_day) into a 7 x 24 grid; `cell` turns (part, all) into the shaded value. */
function weekHourGrid(allGroups: { key: any[]; value: number }[], partGroups: { key: any[]; value: number }[] | null,
  cell: (part: number, all: number) => number | null): WeekHourGrid {
  const k = (g: { key: any[] }) => `${Number(g.key[0])}|${Number(g.key[1])}`;
  const part = new Map<string, number>();
  (partGroups || []).forEach((g) => part.set(k(g), (part.get(k(g)) || 0) + numOrZero(g.value)));
  const grid = emptyWeekHourGrid();
  allGroups.forEach((g) => {
    const d = Number(g.key[0]) - 1, h = Number(g.key[1]);
    if (d < 0 || d > 6 || !(h >= 0 && h <= 23)) return;
    grid[d][h] = cell(part.get(k(g)) || 0, numOrZero(g.value));
  });
  return grid;
}

/** A Panel whose hour columns may be missing from an older export: says so instead of the raw error. */
function HourPanel({ p, src, title, subtitle, children }: { p: ApPageProps; src: Src; title: string; subtitle?: string; children?: React.ReactNode }) {
  if (src.f && src.state.phase === "error") {
    return (
      <ChartCard title={title} subtitle={subtitle} onOpenCheck={openCheck(p, src.id)} takeaway={null}>
        <div className="chart-note-oneline">– This export has no hour of day for this check: run the export again.</div>
      </ChartCard>
    );
  }
  return <Panel p={p} src={src} title={title} subtitle={subtitle}>{children}</Panel>;
}

/** A warehouse × day grid of a % in one hue; the weekday × hour view sits below it. */
function QueueHeat({ rows, days, cell }: { rows: { id: string; name: string; total: number | null }[]; days: string[]; cell: (id: string, d: string) => number | null }) {
  const vals = rows.flatMap((r) => days.map((d) => cell(r.id, d))).filter((v): v is number => v != null && v > 0);
  const max = vals.length ? Math.max(...vals) : 1;
  const level = (v: number | null) => (v == null ? -1 : v <= 0 ? 0 : Math.min(5, Math.max(1, Math.ceil((v / max) * 5))));
  const stride = Math.max(1, Math.ceil(days.length / 8));
  return (
    <div className="ac-heat" style={{ gridTemplateColumns: `minmax(90px, 180px) repeat(${days.length}, minmax(6px, 1fr)) 52px` }} role="table" aria-label="Queued share by warehouse and day">
      {rows.map((r) => (
        <React.Fragment key={r.id}>
          <span className="ac-heat-label" title={r.name}>{truncateLeft(r.name, 170)}</span>
          {days.map((d) => {
            const v = cell(r.id, d), l = level(v);
            return <span key={d} className={`ac-heat-cell${l < 0 ? " blk-hatch" : ""}`} style={l >= 0 ? { background: `var(--seq-${l})` } : undefined}
              title={`${r.name} · ${fmtDayShort(d)}: ${v == null ? "no queries" : `${fmtShare(v)} queued`}`} />;
          })}
          <span className="ac-heat-total">{fmtShare(r.total)}</span>
        </React.Fragment>
      ))}
      <span />
      {days.map((d, i) => <span key={d} className="ac-heat-x">{i % stride === 0 ? fmtDayShort(d) : ""}</span>)}
      <span className="ac-heat-x">all</span>
    </div>
  );
}

// ═══════════════════════ Queries > By source & team ═══════════════════════

function QTeam(p: ApPageProps) {
  const client = useRows(p, "sf_query_by_client_application");
  // One group per source: query and duration sums, and the source-wide p95 the check repeats per row.
  const prov = useAgg(p, "query_provenance_by_source", ["source_kind"], "sum", "query_count", { also: ["total_duration_ms_sum"], pick: ["source_p95_total_duration_ms"] });
  const cRows = rowsOf(client);
  const cDisc = discOf(client);
  const priced = !!cRows && cRows.some((r) => r.price_basis !== "unpriced" && r.est_usd_list != null);
  // no session record (or an old export's "(unknown)"): a gap in the data, not a tool
  const NO_REC = "(no session record)";
  const unknown = (r: Row) => !r.client || /^\(?(unknown|no session record)\)?$/i.test(String(r.client).trim());
  const byClient = cRows ? sumBy(cRows, (r) => (unknown(r) ? NO_REC : String(r.client)), (r) => (unknown(r) ? NO_REC : String(r.client)), {
    v: (r) => (priced ? numOrZero(r.est_usd_list) * (1 - cDisc) : numOrZero(r.credits)), q: (r) => r.queries,
    untagged: (r) => numOrZero(r.queries) * numOrZero(r.untagged_pct) / 100,
  }) : [];
  const all = byClient.reduce((s, c) => s + c.v, 0);
  const unk = byClient.find((c) => c.name === NO_REC);
  const named = byClient.filter((c) => !/^\(.*\)$/.test(c.name));
  const qAll = byClient.reduce((s, c) => s + c.q, 0), qUntagged = byClient.reduce((s, c) => s + c.untagged, 0);
  const fmtV = priced ? usdFmt : (v: number) => `${fmtInt(Math.round(v))} credits`;
  const segs: ShareSegment[] = byClient.map((c) => ({ key: c.name, label: c.name, value: c.v, unknown: c.name === NO_REC }));
  const pRows = rowsOf(prov);
  const bySource = pRows ? sumBy(pRows, (r) => String(r.source_kind || "(unknown)"), (r) => String(r.source_kind || "(unknown)").replace(/_/g, " "), {
    q: (r) => r.query_count, ms: (r) => r.total_duration_ms_sum,
  }) : [];
  // p95 does not add up across rows: the check repeats the source-wide p95 on each row of that source.
  const p95Of = (rows: Row[]) => {
    const v = rows.map((r) => r.source_p95_total_duration_ms).find((x) => x != null && Number.isFinite(Number(x)));
    return v != null ? Number(v) : null;
  };
  const srcItems: StatusBarItem[] = bySource.map((s) => {
    const p95 = p95Of(s.rows);
    return {
      key: s.name, name: s.name, value: s.q, status: "OK",
      valueText: `${fmtInt(s.q)} queries · avg ${secFmt(s.q ? s.ms / s.q / 1000 : 0)} · p95 ${p95 != null ? secFmt(p95 / 1000) : "–"}`,
    };
  });
  const p95Items: StatusBarItem[] = bySource.map((s) => ({ key: s.name, name: s.name, value: p95Of(s.rows) ?? NaN, status: "OK" }))
    .filter((it) => Number.isFinite(it.value)).map((it) => ({ ...it, value: it.value / 1000, valueText: secFmt(it.value / 1000) }));
  const qSrcAll = bySource.reduce((s, x) => s + x.q, 0);
  const srcSorted = [...bySource].sort((a, b) => b.q - a.q);
  const mix = useRows(p, "sf_use_query_type_mix");
  const mixRows = rowsOf(mix);

  const lede = loading(client) ? "…" : cRows && all > 0
    ? `${fmtShare(pctOf(unk ? unk.v : 0, all))} of warehouse compute has no session record, so its client is unknown; ${fmtShare(pctOf(qUntagged, qAll))} of warehouse queries carry no query tag.`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  const clientRows = [...byClient].sort((a, b) => b.v - a.v);
  const clientMax = clientRows.length ? clientRows[0].v : 1;
  const MIX: [string, string, string][] = [["read_pct", "read", "var(--c1)"], ["dml_pct", "write", "var(--c2)"], ["ddl_pct", "DDL", "var(--c3)"], ["metadata_pct", "metadata", "var(--c4)"], ["procedural_pct", "procedures", "var(--c5)"], ["other_pct", "other", "var(--c-other)"]];
  return (
    <div className="ac-page">
      <Tiles>
        <IssueTile label="Compute with no client record" loading={loading(client)}
          headline={cRows ? fmtShare(pctOf(unk ? unk.v : 0, all)) : null} unit={priced ? "of client $" : "of client credits"}
          missingReason={missingOf(client, p)}
          base={cRows ? `${fmtV(unk ? unk.v : 0)} of ${fmtV(all)}` : undefined}
          cause={unk ? "Its session is not in SESSIONS: opened long before the window, or past retention." : "Every query's session is on record."}
          status={unk && unk.v > 0 ? "not_assessed" : statusOf(client.f)} onOpen={() => scrollToAnchor("qt-client")} openLabel="By client tool ↓" />
        <IssueTile label="Queries with no query tag" loading={loading(client)}
          headline={cRows ? fmtShare(pctOf(qUntagged, qAll)) : null} unit="of queries" missingReason={missingOf(client, p)}
          base={cRows ? `${fmtInt(Math.round(qUntagged))} of ${fmtInt(qAll)} queries on warehouses · ${fmtInt(p.filters.window)} d` : undefined}
          cause="A query tag lets chargeback name the team." status="neutral" pill={<KindChip>Context</KindChip>} onOpen={() => scrollToAnchor("qt-clients")} openLabel="By client ↓" />
        <IssueTile label="Queries by source" loading={loading(prov)} pill={<KindChip>Context</KindChip>} status="neutral"
          headline={srcSorted[0] && qSrcAll > 0 ? fmtShare(pctOf(srcSorted[0].q, qSrcAll)) : null} unit={srcSorted[0] ? `of statements from ${srcSorted[0].name}` : undefined}
          missingReason={missingOf(prov, p)}
          base={srcSorted.length ? `${fmtInt(srcSorted[0].q)} of ${fmtInt(qSrcAll)}${srcSorted.slice(1, 3).map((s) => ` · ${s.name} ${fmtShare(pctOf(s.q, qSrcAll))}`).join("")}` : undefined}
          onOpen={() => scrollToAnchor("qt-source")} openLabel="By source ↓" />
      </Tiles>
      <Row2>
        <div id="qt-client">
          <Panel p={p} src={client} title="Compute by client tool" subtitle={`${priced ? "$" : "credits"} · hatched: no client name`}>
            <StackedShareBar segments={segs} pareto valueFmt={fmtV} ariaLabel="Compute by client tool" />
          </Panel>
        </div>
        <div id="qt-source">
          <Panel p={p} src={prov} title="Queries by source" subtitle="queries · average and p95 run time, start to end, queue included">
            <RankedOrLine items={srcItems} valueFmt={(v) => fmtInt(v)} unitLabel="queries" ariaLabel="Queries by source" emptyText="No queries in this window." onBarClick={openCheck(p, "query_provenance_by_source")} />
            {pRows && !p95Items.length && <div className="chart-note-oneline">– This export has no p95 for this check: run the export again.</div>}
          </Panel>
        </div>
      </Row2>
      <div id="qt-clients">
        <Panel p={p} src={client} title="Clients" subtitle={`${fmtInt(named.length)} client tools${unk ? " + no session record" : ""} · ${priced ? "$" : "credits"} · share of queries with no tag · share that failed · click a row`}>
          <DrillTable aria="Client tools" n={10}
            cols={[{ label: "Client" }, { label: "Queries", num: true, width: "auto" }, { label: priced ? "Spend" : "Credits", num: true, width: "auto" }, { label: "Share", width: "minmax(50px, 0.8fr)" }, { label: "No tag", num: true, width: "auto" }, { label: "Failed", num: true, width: "auto" }]}
            rows={clientRows.map((c) => {
              const failedQ = c.rows.reduce((s, r) => s + numOrZero(r.queries) * numOrZero(r.failed_pct) / 100, 0);
              return {
                key: c.name, status: worstStatus(c.rows),
                onOpen: () => DrawerBus.open({ id: "sf_query_by_client_application", col: "client", val: c.rows[0].client != null ? String(c.rows[0].client) : null, label: c.name }),
                cells: [c.name, fmtInt(c.q), fmtV(c.v), <MiniBar key="b" value={c.v} max={clientMax} hatched={c.name === NO_REC} />, fmtShare(pctOf(c.untagged, c.q)), fmtShare(pctOf(failedQ, c.q))],
              };
            })} />
        </Panel>
      </div>
      <Panel p={p} src={mix} title="What each warehouse is used for" subtitle="share of each warehouse's statements, by kind · dot = status">
        {mixRows && (
          <DrillTable aria="Statement kinds by warehouse" n={10}
            cols={[{ label: "Warehouse" }, { label: "Statements", num: true, width: "auto" }, { label: "Read · write · DDL · metadata · procedures · other", width: "minmax(120px, 2fr)" }, { label: "Main", width: "auto" }]}
            rows={[...mixRows].sort((a, b) => numOrZero(b.queries) - numOrZero(a.queries)).map((r) => ({
              key: whKey(r), status: r.status,
              onOpen: () => DrawerBus.open({ id: "sf_use_query_type_mix", col: r.warehouse_id != null ? "warehouse_id" : "warehouse_name", val: r.warehouse_id != null ? String(r.warehouse_id) : r.warehouse_name != null ? String(r.warehouse_name) : null, label: whLabel(r, p) }),
              cells: [r.warehouse_name && r.warehouse_name !== "(no warehouse)" ? whLabel(r, p) : "(no warehouse)", fmtInt(r.queries),
                <SplitBar key="m" max={100} title={MIX.map(([col, w]) => `${w} ${fmtShare(numOrZero(r[col]))}`).join(" · ")} parts={MIX.map(([col, , color]) => ({ value: numOrZero(r[col]), color }))} />,
                String(r.main_kind || "–")],
            }))} />
        )}
        {mixRows && <div className="blk-legend">{MIX.map(([, w, color]) => <span key={w} className="blk-legend-item"><span className="blk-sw" style={{ background: color }} />{w}</span>)}</div>}
      </Panel>
    </div>
  );
}
(QTeam as any).ownsLede = true;

/** The Warehouses and Queries sub-tabs that draw the whole top of the page themselves. */
export const COMPUTE_PAGES: Record<string, Record<string, (p: ApPageProps) => React.JSX.Element>> = {
  warehouses: { idle: WhIdle, sizing: WhSizing, load: WhLoad },
  queries: { heavy: QHeavy, efficiency: QEfficiency, failures: QFailures, waiting: QWaiting, team: QTeam, trend: QTrend },
};
