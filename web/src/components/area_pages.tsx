// web/src/components/area_pages.tsx -- the charts an area sub-tab leads with: 1-3 purpose-built
// charts from checks the sub-tab already owns, read off each check's own columns. tab_area.tsx renders
// AREA_CHART_PAGES[area][subtab] above the generic tiles and table. A chart with fewer than two
// categories is hidden; a check that did not run reads "-" and why; a figure still loading reads "…".

// One chart slot: loads one check's rows, then draws build(rows, ctx) or says why it can't.
// build returns a node, or null to hide the slot (fewer than two categories).
import React from "react";
import { fmtInt } from "../format";
import { numOrZero, useFindingData } from "./hooks";
import { ChartCard } from "./primitives";
import { RankedBars } from "./charts_more";
import { notAssessedText } from "./scope";
import { partialBarKeys, windowShortLabel } from "./overview_tile";
import { withoutTotalRows } from "../tabs/tab_area";
import type { Dims, FetchState, Filters, Finding, GoToFn, Meta, Row } from "../types";
import { ApCostBudgets, ApCostByService, ApCostChargeback, ApCostContract, ApCostWho } from "./ap_cost";
import { ApCostBeforeAfter } from "./cost_before_after";
import { AI_STORAGE_PAGES } from "./area_ai_storage";
import { GOV_CHART_PAGES } from "./area_governance";
import { ACTIVITY_CHART_PAGES } from "./area_activity";
import { PlLoadingCopy, PlLoadingPipes, PlServerlessClustering, PlServerlessFeature, PlServerlessMvso, PlTasksCost, PlTasksDynamic, PlTasksFailures, PlTasksHygiene } from "./area_pipelines";

/** What a chart slot's build gets besides the rows. */
export interface ApCtx {
  dims: Dims;
  disc: number;
  rows: Row[];
  partial: (days: string[]) => string[];
}
export type ApBuild = (rows: Row[], ctx: ApCtx) => React.ReactNode;
export interface ApSlot {
  title: string;
  subtitle?: string;
  build: ApBuild;
}
/** The shell props every area chart page gets. */
export interface ApPageProps {
  area: string;
  subtab: string;
  findings: Finding[];
  filters: Filters;
  dims: Dims;
  meta: Meta;
  goTo: GoToFn;
  /** Set when the page builds the page-head lede from its own numbers (the page is marked ownsLede). */
  setLede?: ((sentence: string | null) => void) | null;
  /** Every check in the export, for a tile on a check homed on another tab. */
  allFindingsIndex?: Record<string, Finding> | null;
}
export interface ApPanelProps extends ApPageProps {
  id: string;
  title: string;
  subtitle?: string;
  build: ApBuild;
  more?: ApSlot[];
}
/** Options of a bar or column chart: value format, unit, note and aria label. */
export interface ApChartOpts {
  fmt: (v: number) => string;
  unit: string;
  note?: string;
  /** A ratio (a %, a change): the tail is dropped, never summed into Other. */
  ratio?: boolean;
  aria: string;
}
type ApValueFn = (r: Row) => any;

export function ApPanel({ id, title, subtitle, area, subtab, findings, filters, dims, meta, goTo, build, more }: ApPanelProps) {
  const f = (findings || []).find((x) => x.query_id === id) || null;
  const state = useFindingData(f ? id : null, filters.window, filters.accountIds, 5000) as FetchState;
  const open = () => goTo({ tab: area, subtab, focusQueryId: id });
  // `more` adds cards on the same check's rows, so one fetch feeds them all.
  const slots: ApSlot[] = [{ title, subtitle, build } as ApSlot].concat(more || []);
  const cards = (bodyOf: (sl: ApSlot) => React.ReactNode) => slots.map((sl, i) => {
    const body = bodyOf(sl);
    return body ? (
      <ChartCard key={i} title={sl.title} subtitle={sl.subtitle} onOpenCheck={open} takeaway={null}>{body}</ChartCard>
    ) : null;
  });
  const note = (text: string) => cards(() => <div className="chart-note-oneline">{text}</div>);
  if (!f) return note("– Not in this export yet: run the export again.");
  if (state.phase === "loading") return note("…");
  if (state.phase === "error") return note(`– ${state.error || "Could not load"}`);
  const outcome = state.outcome;
  if (outcome === "not_assessed") return note(`– ${notAssessedText(state.data)}`);
  if (outcome === "error") return note(`– ${(state.data && state.data.error) || "The check failed."}`);
  if (outcome === "ok_empty_window") {
    const w = windowShortLabel(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days);
    return note(`No data for this in ${w || `the last ${filters.window} days`}`);
  }
  if (outcome === "ok_empty_filters") return note("Rows exist, but the current filters exclude all of them.");
  if (outcome !== "ok_rows") return null;
  const rows = withoutTotalRows(state.data!.rows);
  const disc = numOrZero(state.data!.discount_pct);
  const capped = state.data!.rows_total != null && rows.length < state.data!.rows_total;
  const ctx: ApCtx = { dims, disc, rows, partial: (days: string[]) => partialBarKeys(days, false) };
  return <React.Fragment>{cards((sl) => {
    const body = sl.build(rows, ctx);
    return body && capped ? <div>{body}<div className="chart-note-oneline">{`Top ${fmtInt(rows.length)} of ${fmtInt(state.data!.rows_total)} rows`}</div></div> : body;
  })}</React.Fragment>;
}

// The chart slots of a sub-tab, two to a row.
export function ApRow({ children }: { children?: React.ReactNode }) {
  return <div className="cj-charts-2">{children}</div>;
}

export function apDay(v: any): string { return String(v).slice(0, 10); }

// Sum of value(r) and of whole(r) per label(r), as RankedBars items; zero parts are dropped.
export function apItems(rows: Row[], label: (r: Row) => string, value: ApValueFn, whole?: ApValueFn | null): { name: string; value: number; whole?: number }[] {
  const m = new Map<string, { value: number; whole: number }>();
  rows.forEach((r) => {
    const k = label(r);
    const cur = m.get(k) || { value: 0, whole: 0 };
    cur.value += numOrZero(value(r));
    if (whole) cur.whole += numOrZero(whole(r));
    m.set(k, cur);
  });
  return [...m.entries()]
    .map(([name, v]) => (whole ? { name, value: v.value, whole: Math.max(v.whole, v.value) } : { name, value: v.value }))
    .filter((it) => it.value > 0);
}

export function apBars(items: { name: string; value: number; whole?: number }[], o: ApChartOpts) {
  if (items.length < 2) return null;
  return <RankedBars items={items} n={8} valueFmt={o.fmt} unitLabel={o.unit} note={o.note} ariaLabel={o.aria} ratio={o.fmt === apPct || !!o.ratio} />;
}

export const apPct = (v: number) => `${Number(v).toFixed(v >= 10 ? 0 : 1)}%`;

export const AREA_CHART_PAGES: Record<string, Record<string, (p: ApPageProps) => React.JSX.Element>> = {
  // Warehouses and Queries draw their whole page in area_compute.tsx.
  cost: { service: ApCostByService, who: ApCostWho, chargeback: ApCostChargeback, before: ApCostBeforeAfter, contract: ApCostContract, budgets: ApCostBudgets },
  tasks: { failures: PlTasksFailures, cost: PlTasksCost, hygiene: PlTasksHygiene, dynamic: PlTasksDynamic },
  loading: { pipes: PlLoadingPipes, copy: PlLoadingCopy },
  serverless: { feature: PlServerlessFeature, clustering: PlServerlessClustering, mvso: PlServerlessMvso },
  ...AI_STORAGE_PAGES,
  ...GOV_CHART_PAGES,
  ...ACTIVITY_CHART_PAGES,
};
