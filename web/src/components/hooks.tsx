// web/src/components/hooks.tsx -- data-fetching hooks and aggregation helpers shared by every
// tab. Nothing here renders markup; it only fetches rows
// through Api.finding (the same endpoint the findings table itself uses) and reduces them into
// the small {name, value} shapes charts.tsx draws. Keeping this in one place means every tab's
// chart is backed by the SAME honesty-rule outcome the finding's own detail panel would show --
// a chart is only ever computed from an "ok_rows" fetch; every other outcome is threaded through
// unchanged for ChartNote to render.

// ---------------------------------------------------------------------------------------------
// IgnoredFilterTracker: the checks on the current page that an active account or tag filter
// did not narrow, so the page can say so once.
// ---------------------------------------------------------------------------------------------
import React from "react";
import { Api, excludedNoAccount, scopeHasAccount } from "../api";
import { fmtInt, fmtMoney, fmtPct } from "../format";
import type { Dims, FetchState, Row } from "../types";

type AccountIds = string[] | null | undefined;
type IgnoredEntry = { account: boolean; tag: boolean; acctTag: boolean };
/** One {name, value} bar/slice the chart primitives draw; `color` only on a folded "Other". */
export interface ChartEntry { name: any; value: number; color?: string }
export interface AggOpts { statuses?: string[] | null; top?: number | null; belowFloor?: any; also?: string[] | null; pick?: string[] | null }
export interface DimMaps { tasks: Map<string, Row>; warehouses: Map<string, Row> }
export interface MultiFetchState { phase: string; byId: Record<string, FetchState> }

export const IgnoredFilterTracker = (function () {
  let state: Record<string, IgnoredEntry> = {}; // {queryId: {account: bool, tag: bool, acctTag: bool}}
  const listeners = new Set<() => void>();
  function notify() { listeners.forEach((fn) => fn()); }
  function reset() {
    if (Object.keys(state).length === 0) return;
    state = {};
    notify();
  }
  function report(queryId: string, accountIgnored: boolean, tagIgnored: boolean, tagAccountOnly: boolean) {
    if (!queryId) return;
    const prev = state[queryId];
    if (!accountIgnored && !tagIgnored && !tagAccountOnly) {
      if (!prev) return;
      const next = { ...state };
      delete next[queryId];
      state = next;
      notify();
      return;
    }
    if (prev && prev.account === !!accountIgnored && prev.tag === !!tagIgnored && prev.acctTag === !!tagAccountOnly) return;
    state = { ...state, [queryId]: { account: !!accountIgnored, tag: !!tagIgnored, acctTag: !!tagAccountOnly } };
    notify();
  }
  function subscribe(fn: () => void) { listeners.add(fn); return () => listeners.delete(fn); }
  function getSnapshot() { return state; }
  return { reset, report, subscribe, getSnapshot };
})();

// Only a filter that was actually set can be ignored.
export function reportIgnoredFilters(queryId: string, accountActive: boolean, tagActive: boolean, scope: Row | null | undefined) {
  if (!scope) return;
  const accountIgnored = !!accountActive && !scopeHasAccount(scope);
  const tagIgnored = !!tagActive && !!scope.tag && scope.tag.applied === false;
  const chain = (scope.tag && scope.tag.chain) || [];
  const tagAccountOnly = !!tagActive && !tagIgnored && chain.length === 1 && chain[0] === "account";
  IgnoredFilterTracker.report(queryId, accountIgnored, tagIgnored, tagAccountOnly);
}

// The ignored checks, split by filter, for FilterReachNote.
export function useIgnoredFilterSummary() {
  const state = React.useSyncExternalStore(IgnoredFilterTracker.subscribe, IgnoredFilterTracker.getSnapshot, IgnoredFilterTracker.getSnapshot);
  return React.useMemo(() => {
    const accountIds: string[] = [], tagIds: string[] = [], acctTagIds: string[] = [];
    Object.keys(state).forEach((id) => {
      if (state[id].account) accountIds.push(id);
      if (state[id].tag) tagIds.push(id);
      if (state[id].acctTag) acctTagIds.push(id);
    });
    return { accountIds, tagIds, acctTagIds };
  }, [state]);
}

// ---------------------------------------------------------------------------------------------
// useFindingData -- one query_id's full row set (up to `limit`) for aggregation, independent of
// the paginated 100-row view FindingDetail.tsx renders inside an expanded table row.
//
// `statuses` (T-68, optional, e.g. ["CRITICAL", "WARN"]) scopes the fetch to those status values
// SERVER-side, on a finding that carries a status column -- a caller that only needs flagged rows
// (a tile summing a column across CRITICAL/WARN rows) gets only those, up to the SAME `limit`, so
// the cap applies to the flagged subset rather than to the whole unfiltered table. A caller that
// wants every row regardless of status still passes nothing (the existing default).
// ---------------------------------------------------------------------------------------------
export function useFindingData(queryId: string | null | undefined, windowDays: number, accountIds: AccountIds, limit?: number, statuses?: string[] | null, allPages?: boolean) {
  const lim = limit || 5000;
  const [state, setState] = React.useState<FetchState>({ phase: "loading", outcome: null, data: null, error: null });
  // The tag and owner filters are not arguments (Api.finding reads them itself), so they join the
  // memo key or the fetch would not re-run when only they changed.
  const key = queryId + "|" + !!allPages + "|" + windowDays + "|" + JSON.stringify(accountIds) + "|" + lim + "|" + JSON.stringify(statuses || null) + "|" + Api.tagFilterKey() + "|" + Api.ownerFilterKey() + "|" + Api.dimFilterKey();
  React.useEffect(() => {
    let cancelled = false;
    setState({ phase: "loading", outcome: null, data: null, error: null });
    if (!queryId) return undefined;
    const accountActive = !!(accountIds && accountIds.length > 0);
    const tagActive = Api.tagFilterKey() !== "";
    Api.finding(queryId, windowDays, accountIds, lim, 0, undefined, statuses)
      .then(async (d) => {
        // Past one page only when asked: most panels read a capped list and say so.
        while (allPages && !cancelled && d.rows && d.rows_total > d.rows.length) {
          const next = await Api.finding(queryId, windowDays, accountIds, lim, d.rows.length, undefined, statuses);
          if (!next.rows || !next.rows.length) break;
          d = { ...d, rows: d.rows.concat(next.rows) };
        }
        if (cancelled) return;
        setState({ phase: "ready", outcome: d.outcome, data: d, error: null });
        reportIgnoredFilters(queryId, accountActive, tagActive, d.scope);
      })
      .catch((e) => { if (!cancelled) setState({ phase: "error", outcome: null, data: null, error: e.message || String(e) }); });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return state;
}

// ---------------------------------------------------------------------------------------------
// useFindingAgg -- T-68: the server-side aggregate twin of useFindingData. `group` is an array of
// 0-2 real column names; `agg` is "sum" | "count" | "count_distinct"; `value` is the column to
// sum/count-distinct (ignored for "count"). `opts` is {statuses, top} (both optional; `top` folds
// the tail past that many groups into one "other" bucket, keeping the true total exact). Returns
// the same {phase, outcome, data, error} shape as useFindingData -- `data` carries
// {groups, other, total_value, rows_total, matched_rows, discount_pct, window_coverage, ...}
// instead of `rows` on an ok_rows outcome. See overview_tile.tsx's aggregateGroupTileProps for the
// shared four-outcome handling every caller should route through, same discipline as
// aggregateTileProps for a row-shaped useFindingData state.
// ---------------------------------------------------------------------------------------------
export function useFindingAgg(queryId: string | null | undefined, windowDays: number, accountIds: AccountIds, group?: string[] | null, agg?: string | null, value?: string | null, opts?: AggOpts | null) {
  const o: AggOpts = opts || {};
  const grp = group || [];
  const [state, setState] = React.useState<FetchState>({ phase: "loading", outcome: null, data: null, error: null });
  const key = [
    queryId, windowDays, JSON.stringify(accountIds),
    grp.join(","), agg, value || "", JSON.stringify(o.statuses || null), o.top || "",
    (o.also || []).join(","), (o.pick || []).join(","),
    Api.tagFilterKey(), Api.ownerFilterKey(), Api.dimFilterKey(),
  ].join("|");
  React.useEffect(() => {
    let cancelled = false;
    setState({ phase: "loading", outcome: null, data: null, error: null });
    if (!queryId) return undefined;
    const accountActive = !!(accountIds && accountIds.length > 0);
    const tagActive = Api.tagFilterKey() !== "";
    Api.aggregate(queryId, windowDays, accountIds, grp, agg, value, o)
      .then((d) => {
        if (cancelled) return;
        setState({ phase: "ready", outcome: d.outcome, data: d, error: null });
        reportIgnoredFilters(queryId, accountActive, tagActive, d.scope);
      })
      .catch((e) => { if (!cancelled) setState({ phase: "error", outcome: null, data: null, error: e.message || String(e) }); });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return state;
}

// One row-like object per aggregate group: its key columns, its `also` sums, its `pick` values and
// the aggregate under `valueCol`, so code written for rows reads a grouped response unchanged.
export function groupsToRows(data: Row | null | undefined, group: string[], valueCol: string | null): Row[] {
  return ((data && data.groups) || []).map((g: Row) => {
    const r: Row = { ...(g.also || {}), ...(g.pick || {}) };
    group.forEach((c, i) => { r[c] = g.key ? g.key[i] : null; });
    if (valueCol) r[valueCol] = g.value;
    return r;
  });
}

// A spike day is judged on the day's total (the bar on the chart): at least SPIKE_PCT above the
// median of the 7 days before it. The median keeps low weekends from turning every Monday into a
// spike. `days` is [{day, value}] in date order; days with fewer than 5 earlier days are not judged.
export const SPIKE_PCT = 15;
export function totalSpikeDays(days: { day: string; value: number }[] | null | undefined) {
  return (days || []).map((d, i) => {
    const prev = days!.slice(Math.max(0, i - 7), i).map((x) => x.value).sort((a, b) => a - b);
    if (prev.length < 5) return null;
    const n = prev.length;
    const median = n % 2 ? prev[(n - 1) / 2] : (prev[n / 2 - 1] + prev[n / 2]) / 2;
    if (!(median > 0) || d.value < median * (1 + SPIKE_PCT / 100)) return null;
    return { day: d.day, value: d.value, median, pct: (d.value / median - 1) * 100 };
  }).filter(Boolean) as { day: string; value: number; median: number; pct: number }[];
}

// ---------------------------------------------------------------------------------------------
// useMultiFindingData -- several query_ids at once (a tab's whole chart set), one state object
// keyed by query_id so each chart can independently render its own ChartNote.
// ---------------------------------------------------------------------------------------------
// Waste totals and lists read only flagged rows; fetching every row cost megabytes per check.
export const FLAGGED_STATUSES = ["CRITICAL", "WARN"];

export function useMultiFindingData(queryIds: string[] | null | undefined, windowDays: number, accountIds: AccountIds, limit?: number, statuses?: string[] | null) {
  const lim = limit || 5000;
  const ids = queryIds || [];
  const key = ids.join(",") + "|" + windowDays + "|" + JSON.stringify(accountIds) + "|" + lim + "|" + JSON.stringify(statuses || null) + "|" + Api.tagFilterKey() + "|" + Api.ownerFilterKey() + "|" + Api.dimFilterKey();
  const [state, setState] = React.useState<MultiFetchState>({ phase: "loading", byId: {} });
  React.useEffect(() => {
    let cancelled = false;
    setState({ phase: "loading", byId: {} });
    if (!ids.length) { setState({ phase: "ready", byId: {} }); return undefined; }
    const accountActive = !!(accountIds && accountIds.length > 0);
    const tagActive = Api.tagFilterKey() !== "";
    Promise.all(ids.map((id) =>
      Api.finding(id, windowDays, accountIds, lim, 0, undefined, statuses)
        .then((d) => {
          // Same as useFindingData: a check a filter can't narrow is named under the page.
          if (!cancelled) reportIgnoredFilters(id, accountActive, tagActive, d.scope);
          return [id, { phase: "ready", outcome: d.outcome, data: d, error: null }] as [string, FetchState];
        })
        .catch((e) => [id, { phase: "error", outcome: null, data: null, error: e.message || String(e) }] as [string, FetchState])
    )).then((pairs) => {
      if (cancelled) return;
      const byId: Record<string, FetchState> = {};
      pairs.forEach(([id, v]) => { byId[id] = v; });
      setState({ phase: "ready", byId });
    });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return state;
}

// ---------------------------------------------------------------------------------------------
// useDims -- dims.dim_task and dim_warehouse, fetched once and turned into lookup maps ("names, not
// ids"). Falls back to the raw id when a dim row is missing (a dropped warehouse, a dim not yet
// built), never a blank label. A task is keyed by its full name (DB.SCHEMA.TASK).
// ---------------------------------------------------------------------------------------------
export function useDims() {
  const [maps, setMaps] = React.useState<DimMaps | null>(null);
  React.useEffect(() => {
    let cancelled = false;
    Api.dims().then((d) => {
      if (cancelled) return;
      const tasks = new Map<string, Row>();
      (d.tasks || []).forEach((x: Row) => tasks.set(String(x.task_full_name), x));
      const warehouses = new Map<string, Row>();
      (d.warehouses || []).forEach((w: Row) => warehouses.set(String(w.warehouse_id), w));
      setMaps({ tasks, warehouses });
    }).catch(() => { if (!cancelled) setMaps({ tasks: new Map(), warehouses: new Map() }); });
    return () => { cancelled = true; };
  }, []);
  return maps;
}

export function taskName(maps: DimMaps | Dims | null | undefined, fullName: any) {
  if (!maps) return String(fullName);
  const x = maps.tasks.get(String(fullName));
  return (x && (x.task_full_name || x.task_name)) || String(fullName);
}
export function warehouseName(maps: DimMaps | Dims | null | undefined, warehouseId: any) {
  if (!maps) return String(warehouseId);
  const w = maps.warehouses.get(String(warehouseId));
  return (w && w.warehouse_name) || `warehouse ${String(warehouseId).slice(0, 8)}`;
}

// ---------------------------------------------------------------------------------------------
// Aggregation helpers -- plain reductions over the JSON rows an ok_rows finding returns.
// ---------------------------------------------------------------------------------------------

export function numOrZero(v: any) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

// Resource monitor coverage over the warehouses the role sees: no monitor that suspends, of judged; the rest hidden.
export function monitorCoverage(rows: any[] | null | undefined) {
  const key = (r: any) => `${r.account_id}|${r.warehouse_id ?? r.warehouse_name}`;
  const judged = new Map<string, boolean>();
  const hidden = new Set<string>();
  (rows || []).forEach((r) => {
    if (r.status === "NOT_ASSESSED") { hidden.add(key(r)); return; }
    judged.set(key(r), (judged.get(key(r)) || false) || r.has_suspend === true || r.has_suspend === "true" || r.has_suspend === 1);
  });
  hidden.forEach((k) => { if (judged.has(k)) hidden.delete(k); });
  return { total: judged.size, noCap: [...judged.values()].filter((c) => !c).length, hidden: hidden.size };
}

// An aggregate's total after the discount; null (never $0) when no row had a value, e.g. unpriced.
export function aggTotal(data: any) {
  return data && data.total_value != null ? numOrZero(data.total_value) * (1 - numOrZero(data.discount_pct)) : null;
}

export function sumBy(rows: Row[] | null | undefined, valKey: string) {
  return (rows || []).reduce((s: number, r: Row) => s + numOrZero(r[valKey]), 0);
}

// Group rows by keyFn(row) and sum valKey within each group -> [{name, value}], insertion order.
export function groupSum(rows: Row[] | null | undefined, keyFn: (r: Row) => any, valKey: string): ChartEntry[] {
  const order: any[] = [];
  const totals = new Map<any, number>();
  (rows || []).forEach((r) => {
    const k = keyFn(r);
    if (!totals.has(k)) { totals.set(k, 0); order.push(k); }
    totals.set(k, totals.get(k)! + numOrZero(r[valKey]));
  });
  return order.map((k) => ({ name: k, value: totals.get(k)! }));
}

// fillDays -- one {day, value} per calendar day (UTC) from as_of minus min(windowDays,
// snapshotDays) through as_of minus 1, 0 where `days` had no row for that day. A daily average or
// a spike scan built straight off a sparse aggregate silently skips zero-spend days, which both
// inflates the average and misaligns "the 7 days before" a spike compares against.
export function fillDays(days: { day: string; value: any }[] | null | undefined, asOfDate: any, windowDays: number, snapshotDays?: number | null) {
  const byDay = new Map<string, number>((days || []).map((d) => [d.day, numOrZero(d.value)]));
  if (!asOfDate) {
    return [...byDay.keys()].sort().map((day) => ({ day, value: byDay.get(day)! }));
  }
  const span = Math.max(0, Math.min(windowDays, snapshotDays != null ? snapshotDays : windowDays));
  const asOf = new Date(`${String(asOfDate).slice(0, 10)}T00:00:00Z`);
  const out = [];
  for (let i = span; i >= 1; i -= 1) {
    const d = new Date(asOf.getTime());
    d.setUTCDate(d.getUTCDate() - i);
    const day = d.toISOString().slice(0, 10);
    out.push({ day, value: byDay.get(day) || 0 });
  }
  return out;
}

// excludedNoAccountNote -- one line when an account or attribute filter is silently leaving out
// spend that carries no account id, as an aggregate response reports it; null when no such filter
// applies or the excluded amount rounds to nothing.
export function excludedNoAccountNote(data: Row | null | undefined) {
  const exc = excludedNoAccount(data);
  if (!exc) return null;
  const usd = numOrZero(exc.value) * (1 - numOrZero(data!.discount_pct));
  if (usd < 1) return null;
  return `${fmtMoney(usd, 0)} of spend with no account id is not in this filter.`;
}

// belowFloorNoteText -- "Not counted" for the $ a per-check materiality floor left OUT of
// wasteTotal's own priced total (never folded into it), shared by Waste and Overview's waste tile
// so the two never word the same figure differently.
export function belowFloorNoteText(total: Row | null | undefined) {
  if (!total || !(total.belowFloorUsd >= 1)) return null;
  const floorText = total.floor
    ? `each check's floor (${fmtMoney(total.floor.min, 0)} per ${fmtInt(total.floor.per_days)} days)`
    : "each check's floor";
  return `Not counted: ${fmtMoney(total.belowFloorUsd, 0)} in ${fmtInt(total.belowFloorRows)} row${total.belowFloorRows === 1 ? "" : "s"} under ${floorText}.`;
}

// fmtChangePct -- the one wording for a current-vs-previous percent this app uses everywhere:
// "new" when there is no previous total to compare against (pct is null), a multiple once it has
// doubled ("6.2×", never "+518%"), else a signed, rounded percent.
export function fmtChangePct(pct: any) {
  if (pct == null) return "new";
  const p = Number(pct);
  if (p >= 100) return `${(1 + p / 100).toFixed(1)}×`;
  return `${p >= 0 ? "+" : "−"}${fmtPct(Math.abs(p), 0)}`;
}

export const MONTH_BAR_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// One calendar month after an ISO month_start key (always day 01), for filling gaps.
export function addMonthKey(key: string) {
  const [y, m] = key.split("-").map(Number);
  const total = y * 12 + (m - 1) + 1;
  return `${Math.floor(total / 12)}-${String((total % 12) + 1).padStart(2, "0")}-01`;
}

// buildMonthBars -- the ONE month-bar colouring rule Money and Cost both use (they used to each
// slice to a different length BEFORE colouring, so the same month came out red on one page and
// "steady" on the other). Colours every month against its own trailing 3 FULL months from the
// WHOLE history handed in, then slices to `displayCount` only at the end -- so a caller may show
// 12 months or 13 without changing what colour any shared month gets. `tone` is "crit"/"warn"/
// "calm"/"steady" once 3 full priors exist, else null (not enough history -- a caller must render
// this as its own neutral colour, never reuse "steady"'s).
export function buildMonthBars(groups: Row[] | null | undefined, discountPct: any, displayCount?: number) {
  const disc = numOrZero(discountPct);
  // Rows repeat per product and per partial reason: merge them into one bar per month. Only the
  // month still in progress reads partial; a month whose history starts mid-month is a full bar.
  const byMonth = new Map<string, { key: string; partial: boolean; total: number; startsMid?: boolean }>();
  (groups || []).forEach((g) => {
    const key = g.key && g.key[0] ? String(g.key[0]).slice(0, 10) : null;
    if (!key) return;
    const cur = byMonth.get(key) || { key, partial: false, total: 0 };
    if (g.key[1] === "month_in_progress" || g.key[1] === true) cur.partial = true;
    if (g.key[1] === "history_starts_mid_month") cur.startsMid = true;
    cur.total += numOrZero(g.value) * (1 - disc);
    byMonth.set(key, cur);
  });
  const sparse = [...byMonth.values()].sort((a, b) => a.key.localeCompare(b.key));
  // A month with no billing row at all is a real $0, not a gap to skip -- otherwise the trailing-3-
  // month average and the bar count both silently drop straight past it.
  const all: { key: string; partial: boolean; total: number; startsMid?: boolean }[] = [];
  sparse.forEach((m, i) => {
    all.push(m);
    if (i < sparse.length - 1) {
      let next = addMonthKey(m.key);
      while (next < sparse[i + 1].key) {
        all.push({ key: next, partial: false, total: 0 });
        next = addMonthKey(next);
      }
    }
  });
  const withTone = all.map((m, i, arr) => {
    let tone: string | null = null, changePct: number | null = null;

    if (!m.partial) {
      const prior3 = arr.slice(Math.max(0, i - 3), i).filter((p) => !p.partial && !p.startsMid);
      if (prior3.length === 3) {
        const avg3 = prior3.reduce((s, p) => s + p.total, 0) / 3;
        if (avg3 > 0) {
          changePct = ((m.total - avg3) / avg3) * 100;
          if (changePct >= 30) tone = "crit";
          else if (changePct >= 15) tone = "warn";
          else if (changePct <= -15) tone = "calm";
          else tone = "steady";
        } else if (m.total > 0) {
          tone = "crit"; // real spend where the trailing 3 months were flat $0
        } else {
          tone = "steady";
        }
      }
    }
    const d = new Date(`${m.key}T00:00:00Z`);
    const validDate = !Number.isNaN(d.getTime());
    const shortLabel = validDate ? MONTH_BAR_NAMES[d.getUTCMonth()] : m.key;
    const label = validDate ? `${MONTH_BAR_NAMES[d.getUTCMonth()]} ${d.getUTCFullYear()}` : m.key;
    return { month: m.key, label, shortLabel, total: m.total, partial: m.partial, startsMid: !!m.startsMid, changePct, tone };
  });
  return displayCount ? withTone.slice(-displayCount) : withTone;
}
