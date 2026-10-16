// Cost > Before & after: pick a warehouse, task or pipe and a date, and set the days before it against the days after.
// Every figure is an average day (or a per-query ratio) over complete days, so two sides of unequal length compare;
// today is partial and left out of both. $ reads "–" without a credit price, never $0.
import React from "react";
import { fmtBytes, fmtCredits, fmtDayShort, fmtDuration, fmtInt, fmtMoney, fmtPct } from "../format";
import { fmtChangePct, numOrZero, useFindingAgg } from "./hooks";
import { Card, ChartCard, noDataText } from "./primitives";
import { notAssessedText } from "./scope";
import { IssueTile } from "./blocks";
import { CxPicker, NaStrip } from "./cx_a";
import { NameId } from "./blocks_2";
import { DrillTable } from "./drill_table";
import type { DrillRow } from "./drill_table";
import { CsvButton } from "./csv";
import type { CsvColumn } from "./csv";
import { DAY_MS, KpiRow, windowSpan } from "./overview_tile";
import type { ApPageProps } from "./area_pages";
import type { FetchState, Finding, Row } from "../types";

const COST_QID = "cost_daily_by_resource";
const QRY_QID = "sf_qry_daily_by_warehouse";
const LEVELS = [
  { key: "warehouse", label: "Warehouse", plural: "warehouses" },
  { key: "task", label: "Serverless task", plural: "serverless tasks" },
  { key: "pipe", label: "Pipe", plural: "pipes" },
];
// account_id joins the group so a pick reads one row, never the largest of several accounts.
const COST_GROUP = ["account_id", "resource_key", "usage_date"];
const COST_PICK = ["warehouse_name", "warehouse_id", "task_full_name", "task_id", "pipe_name", "pipe_id", "is_other"];
const QRY_GROUP = ["account_id", "warehouse_id", "usage_date"];
const QRY_ALSO = ["failed_queries", "total_elapsed_s", "queued_overload_s", "bytes_spilled_remote", "bytes_scanned"];
const QRY_PICK = ["warehouse_name", "cache_scan_pct"];
// Fewer days than this on a side and one odd day moves its average a lot.
const FEW_DAYS = 3;
// Under this share of the larger side a move is rounding, not a change.
const NOISE = 0.01;

interface Src { groups: Row[] | null; disc: number; why: string | null; loading: boolean; truncated: boolean }

function findingOf(p: ApPageProps, id: string): Finding | null {
  return (p.findings || []).find((f) => f.query_id === id) || (p.allFindingsIndex ? p.allFindingsIndex[id] || null : null);
}

// One check's aggregate groups, or the one line that says why there are none.
function useAggSrc(p: ApPageProps, id: string, group: string[], value: string, also: string[], pick: string[]): Src {
  const f = findingOf(p, id);
  const state = useFindingAgg(f ? id : null, p.filters.window, p.filters.accountIds, group, "sum", value, { also, pick }) as FetchState;
  const none: Src = { groups: null, disc: 0, why: null, loading: false, truncated: false };
  if (!f) return { ...none, why: "Not in this export yet: run the export again." };
  if (state.phase === "loading") return { ...none, loading: true };
  if (state.phase === "error") return { ...none, why: state.error || "Could not load" };
  const d: Row = state.data || {};
  if (state.outcome === "not_assessed") return { ...none, why: notAssessedText(d) };
  if (state.outcome === "error") return { ...none, why: d.error || "The check failed." };
  // An empty window is a real zero for every day, not a gap.
  if (state.outcome !== "ok_rows") return { ...none, groups: [] };
  return { ...none, groups: d.groups || [], disc: numOrZero(d.discount_pct), truncated: d.truncated === true };
}

// pooled: a warehouse seen only in the query feed, whose credits sit in the cost check's "Other" row.
interface Item { key: string; level: string; account: string; id: string | null; name: string; credits: number; pooled?: boolean }
// Per item, per day: summed figures and whether every priced figure had a price.
interface DayVals { credits: number; usd: number; unpriced: boolean; queries: number; failed: number; elapsed: number; queued: number; spill: number; scanned: number; cached: number }
const zeroDay = (): DayVals => ({ credits: 0, usd: 0, unpriced: false, queries: 0, failed: 0, elapsed: 0, queued: 0, spill: 0, scanned: 0, cached: 0 });

function levelOfKey(rk: string): string { return rk.slice(0, Math.max(0, rk.indexOf(":"))); }

function itemName(level: string, pick: Row, rk: string): { name: string; id: string | null } {
  const plural = (LEVELS.find((l) => l.key === level) || LEVELS[0]).plural;
  if (pick.is_other === true || rk.endsWith(":other")) return { name: `Other ${plural}, pooled`, id: null };
  const rid = rk.slice(rk.indexOf(":") + 1);
  if (level === "warehouse") return { name: String(pick.warehouse_name || rid), id: pick.warehouse_id != null ? String(pick.warehouse_id) : rid };
  if (level === "task") return { name: String(pick.task_full_name || rid), id: pick.task_id != null ? String(pick.task_id) : rid };
  if (rid === "none") return { name: "(auto-refresh or Streaming)", id: null };
  return { name: String(pick.pipe_name || rid), id: pick.pipe_id != null ? String(pick.pipe_id) : rid };
}

function fmtCr(v: number | null): string {
  if (v == null || !Number.isFinite(v)) return "–";
  const a = Math.abs(v);
  return fmtCredits(v, a === 0 ? 0 : a < 0.1 ? 4 : a < 10 ? 2 : 1);
}
function fmtSecs(v: number | null): string {
  if (v == null || !Number.isFinite(v)) return "–";
  const a = Math.abs(v);
  return a < 10 ? `${v.toFixed(a < 1 ? 2 : 1)} s` : fmtDuration(v);
}
function fmtCount(v: number | null): string {
  if (v == null || !Number.isFinite(v)) return "–";
  return Math.abs(v) < 10 ? v.toFixed(1) : fmtInt(Math.round(v));
}

// "up" is bad for cost, waits and failures; good for cache hits; neutral for load.
type Tone = "cost" | "good_up" | "neutral";
interface Measure { key: string; label: string; before: number | null; after: number | null; fmt: (v: number | null) => string; tone: Tone; points?: boolean; missing?: string | null }

function changeOf(m: Measure): { text: string; tone: string } {
  if (m.missing) return { text: "–", tone: "neutral" };
  const { before: b, after: a } = m;
  if (b == null || a == null) return { text: b == null && a == null ? "–" : b == null ? "none before" : "none after", tone: "neutral" };
  const d = a - b;
  const big = Math.max(Math.abs(a), Math.abs(b));
  if (big === 0 || Math.abs(d) <= big * NOISE) return { text: "no change", tone: "neutral" };
  const up = d > 0;
  const tone = m.tone === "neutral" ? "neutral" : (m.tone === "cost" ? up : !up) ? "warn" : "good";
  if (m.points) return { text: `${up ? "+" : "−"}${Math.abs(d).toFixed(1)} pts`, tone };
  return { text: b > 0 ? fmtChangePct((d / b) * 100) : "new", tone };
}

function Chip({ m }: { m: Measure }) {
  const c = changeOf(m);
  return <span className={`cost-delta tone-${c.tone}`}>{c.text}</span>;
}

// A round axis top at or above v: 1, 2, 2.5 or 5 times a power of ten.
function niceTop(v: number): number {
  if (!(v > 0)) return 1;
  const e = 10 ** Math.floor(Math.log10(v));
  return ([1, 2, 2.5, 5, 10].find((m) => m * e >= v) || 10) * e;
}

// Credits a day, before (orange) and after (blue) the change day, each side's average as a dashed line.
// One day far above the rest is capped with a break mark and its value written above it, so it does not
// flatten every other day.
function BeforeAfterBars({ days, values, fix, fmt, label }: { days: string[]; values: number[]; fix: string; fmt: (v: number) => string; label: string }) {
  const sorted = [...values].sort((a, b) => a - b);
  const max = sorted[sorted.length - 1] || 0;
  const second = sorted.length > 1 ? sorted[sorted.length - 2] : max;
  // Only a single day far above every other one is capped.
  const cap = max > 2.5 * second && second > 0 ? niceTop(second * 1.15) : niceTop(max);
  const bIdx = days.map((d, i) => (d < fix ? i : -1)).filter((i) => i >= 0);
  const aIdx = days.map((d, i) => (d >= fix ? i : -1)).filter((i) => i >= 0);
  const avg = (ix: number[]) => (ix.length ? ix.reduce((s, i) => s + values[i], 0) / ix.length : 0);
  const avgB = avg(bIdx), avgA = avg(aIdx);
  const W = 900, H = 220, L = 44, T = 22, B = 24;
  const ph = H - T - B, pw = W - L - 6;
  const bw = pw / days.length;
  const y = (v: number) => T + ph - (ph * Math.min(v, cap)) / cap;
  const xFix = L + bIdx.length * bw;
  const ticks = [0, cap / 2, cap];
  const capped = values.map((v, i) => (v > cap ? i : -1)).filter((i) => i >= 0);
  const dl = fmtDayShort;
  return (
    <div className="cx-ba">
      <div className="cx-ba-legend"><span><span className="cx-sm-sw" style={{ background: "var(--c2)" }} />Before</span><span aria-hidden="true">→</span><span><span className="cx-sm-sw" style={{ background: "var(--c1)" }} />After</span></div>
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label={label}>
        <text x={0} y={10} className="cx-ba-unit">credits / day</text>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={L} x2={W} y1={y(t)} y2={y(t)} className="cx-sm-grid-line" />
            <text x={L - 6} y={y(t) + 4} textAnchor="end" className="cx-ba-tick">{fmt(t)}</text>
          </g>
        ))}
        {values.map((v, i) => {
          const after = days[i] >= fix;
          const top = y(v);
          return <rect key={days[i]} x={L + i * bw + bw * 0.15} y={top} width={bw * 0.7} height={T + ph - top} fill={after ? "var(--c1)" : "var(--c2)"} />;
        })}
        {capped.map((i) => (
          <g key={`cap${i}`}>
            <path d={`M${L + i * bw + bw * 0.1} ${T + 8} l${bw * 0.8} -5 M${L + i * bw + bw * 0.1} ${T + 13} l${bw * 0.8} -5`} stroke="var(--surface)" strokeWidth="2.5" />
            <text x={L + i * bw + bw / 2} y={T - 6} textAnchor="middle" className="cx-ba-tick strong">{fmt(values[i])}</text>
          </g>
        ))}
        {bIdx.length > 0 && <line x1={L} x2={xFix} y1={y(avgB)} y2={y(avgB)} className="cx-ba-avg before" />}
        {aIdx.length > 0 && <line x1={xFix} x2={W} y1={y(avgA)} y2={y(avgA)} className="cx-ba-avg after" />}
        {bIdx.length > 0 && <text x={L + 4} y={y(avgB) - 5} className="cx-ba-tick">{`avg ${fmt(avgB)}`}</text>}
        {aIdx.length > 0 && <text x={xFix + 4} y={y(avgA) - 5} className="cx-ba-tick">{`avg ${fmt(avgA)}`}</text>}
        <line x1={xFix} x2={xFix} y1={T - 4} y2={T + ph} className="cx-ba-fix" />
        <line x1={L} x2={W} y1={T + ph} y2={T + ph} className="cx-sm-base" />
        <text x={L} y={H - 6} className="cx-ba-tick">{dl(days[0])}</text>
        <text x={xFix} y={H - 6} textAnchor="middle" className="cx-ba-tick">{`${dl(fix)} · change`}</text>
        <text x={W} y={H - 6} textAnchor="end" className="cx-ba-tick">{dl(days[days.length - 1])}</text>
      </svg>
      {capped.length > 0 && <div className="cx-moved-note">{`${capped.map((i) => fmtDayShort(days[i])).join(", ")} reached ${capped.map((i) => fmt(values[i])).join(", ")} and ${capped.length === 1 ? "is" : "are"} cut off so the other days stay readable.`}</div>}
    </div>
  );
}

export function ApCostBeforeAfter(p: ApPageProps) {
  const [level, setLevel] = React.useState("warehouse");
  const [picked, setPicked] = React.useState<string | null>(null);
  const [fixDay, setFixDay] = React.useState<string | null>(null);
  const cost = useAggSrc(p, COST_QID, COST_GROUP, "credits", ["usd_list"], COST_PICK);
  const qry = useAggSrc(p, QRY_QID, QRY_GROUP, "queries", QRY_ALSO, QRY_PICK);
  const meta: Row = p.meta || {};
  const lv = LEVELS.find((l) => l.key === level) || LEVELS[0];
  const partialDay: string | null = (meta.cost_cutoff && meta.cost_cutoff.partial_day) || null;
  const priceNote: string = (meta.price_basis && meta.price_basis.credit_price_usd == null && meta.price_basis.label) || "no credit price in this export";

  // Every complete day of the window, so a day with no usage counts as zero in an average.
  const days = React.useMemo(() => {
    const span = windowSpan(meta.as_of_date, p.filters.window, meta.snapshot_days);
    const out: string[] = [];
    if (span) {
      // Both feeds start at the as-of date minus the window, which can be a day after the cost cut-off's
      // window start; a day before that is not in the export and must not count as a zero day.
      const asOfMs = meta.as_of_date ? Date.parse(`${String(meta.as_of_date).slice(0, 10)}T00:00:00Z`) : NaN;
      const covered = Math.min(p.filters.window, numOrZero(meta.export_days) || p.filters.window);
      const first = Number.isFinite(asOfMs) ? Math.max(span.first, asOfMs - covered * DAY_MS) : span.first;
      for (let t = first; t <= span.last && out.length < 400; t += DAY_MS) out.push(new Date(t).toISOString().slice(0, 10));
      return out;
    }
    const seen = new Set<string>();
    (cost.groups || []).forEach((g) => seen.add(String(g.key[2]).slice(0, 10)));
    return [...seen].filter((d) => d !== partialDay).sort();
  }, [meta.as_of_date, meta.snapshot_days, meta.export_days, p.filters.window, cost.groups, partialDay]);
  const daySet = React.useMemo(() => new Set(days), [days]);

  // Items and their days: cost rows first, then warehouses that ran queries but billed nothing here.
  const { items, byItem } = React.useMemo(() => {
    const items = new Map<string, Item>();
    const byItem = new Map<string, Map<string, DayVals>>();
    const slot = (key: string, day: string) => {
      if (!byItem.has(key)) byItem.set(key, new Map());
      const m = byItem.get(key)!;
      if (!m.has(day)) m.set(day, zeroDay());
      return m.get(day)!;
    };
    (cost.groups || []).forEach((g) => {
      const [acct, rk, dRaw] = g.key || [];
      const rkS = String(rk == null ? "" : rk);
      const lvl = levelOfKey(rkS);
      const key = `${acct}|${rkS}`;
      const day = String(dRaw).slice(0, 10);
      const pick: Row = g.pick || {};
      if (!items.has(key)) items.set(key, { key, level: lvl, account: String(acct), ...itemName(lvl, pick, rkS), credits: 0 });
      if (!daySet.has(day)) return;
      const cr = numOrZero(g.value);
      items.get(key)!.credits += cr;
      const v = slot(key, day);
      v.credits += cr;
      const usd = g.also ? g.also.usd_list : null;
      if (usd == null) { if (cr > 0) v.unpriced = true; } else v.usd += Number(usd) * (1 - cost.disc);
    });
    // Accounts whose cost rows pool the warehouses past the top 100 into one "Other" row.
    const pooledAccts = new Set([...items.values()].filter((it) => it.level === "warehouse" && it.key.endsWith(":other")).map((it) => it.account));
    (qry.groups || []).forEach((g) => {
      const [acct, wid, dRaw] = g.key || [];
      const key = `${acct}|warehouse:${wid}`;
      const day = String(dRaw).slice(0, 10);
      const pick: Row = g.pick || {};
      if (!items.has(key)) items.set(key, { key, level: "warehouse", account: String(acct), name: String(pick.warehouse_name || wid), id: wid != null ? String(wid) : null, credits: 0, pooled: pooledAccts.has(String(acct)) });
      if (!daySet.has(day)) return;
      const also: Row = g.also || {};
      const v = slot(key, day);
      v.queries += numOrZero(g.value);
      v.failed += numOrZero(also.failed_queries);
      v.elapsed += numOrZero(also.total_elapsed_s);
      v.queued += numOrZero(also.queued_overload_s);
      v.spill += numOrZero(also.bytes_spilled_remote);
      const scanned = numOrZero(also.bytes_scanned);
      // cache_scan_pct is bytes-weighted per day, so weight it back by bytes before summing.
      if (pick.cache_scan_pct != null && scanned > 0) { v.scanned += scanned; v.cached += scanned * numOrZero(pick.cache_scan_pct) / 100; }
    });
    return { items, byItem };
  }, [cost.groups, cost.disc, qry.groups, daySet]);

  const accounts = new Set([...items.values()].map((it) => it.account));
  const levelItems = [...items.values()].filter((it) => it.level === level)
    .sort((a, b) => b.credits - a.credits || a.name.localeCompare(b.name));
  const sel = levelItems.find((it) => it.key === picked) || levelItems[0] || null;
  const labelOf = (it: Item) => `${it.name}${it.id && it.id !== it.name ? ` (${it.id})` : ""}${accounts.size > 1 ? ` · ${it.account}` : ""}${it.pooled ? " · credits in Other" : ""}`;

  // Default split: the middle of the window.
  const defaultFix = days.length > 1 ? days[Math.floor(days.length / 2)] : null;
  const fix = fixDay && days.length > 1 && fixDay > days[0] && fixDay <= days[days.length - 1] ? fixDay : defaultFix;
  const nB = fix ? days.filter((d) => d < fix).length : 0;
  const nA = days.length - nB;
  const beforeSpan = nB ? `${fmtDayShort(days[0])} – ${fmtDayShort(days[nB - 1])}` : "";
  const afterSpan = nA && fix ? `${fmtDayShort(fix)} – ${fmtDayShort(days[days.length - 1])}` : "";

  const measures = React.useMemo((): Measure[] => {
    if (!sel || !fix || !nB || !nA) return [];
    const m = byItem.get(sel.key) || new Map<string, DayVals>();
    const side = (after: boolean) => {
      const s = zeroDay();
      m.forEach((v, d) => {
        if ((d >= fix) !== after) return;
        (Object.keys(s) as (keyof DayVals)[]).forEach((k) => { if (k === "unpriced") s.unpriced = s.unpriced || v.unpriced; else (s as any)[k] += v[k]; });
      });
      return s;
    };
    const b = side(false), a = side(true);
    const priced = !b.unpriced && !a.unpriced && !(meta.price_basis && meta.price_basis.credit_price_usd == null);
    const crWhy = cost.why || (sel.pooled ? "Credits sit in the pooled Other warehouses row" : null);
    const out: Measure[] = [
      { key: "credits", label: "Credits a day", before: b.credits / nB, after: a.credits / nA, fmt: fmtCr, tone: "cost", missing: crWhy },
      { key: "usd", label: "$ a day", before: priced ? b.usd / nB : null, after: priced ? a.usd / nA : null, fmt: (v) => (v == null ? "–" : fmtMoney(v, Math.abs(v) < 100 ? 2 : 0)), tone: "cost", missing: crWhy || (priced ? null : priceNote) },
    ];
    if (sel.level === "warehouse") {
      // "…" while the query feed loads, never interim zeros.
      const qWhy = qry.loading ? "…" : qry.why;
      out.push(
        { key: "queries", label: "Queries a day", before: b.queries / nB, after: a.queries / nA, fmt: fmtCount, tone: "neutral", missing: qWhy },
        { key: "elapsed", label: "Avg query time", before: b.queries > 0 ? b.elapsed / b.queries : null, after: a.queries > 0 ? a.elapsed / a.queries : null, fmt: fmtSecs, tone: "cost", missing: qWhy },
        { key: "queued", label: "Queued, warehouse full, per query", before: b.queries > 0 ? b.queued / b.queries : null, after: a.queries > 0 ? a.queued / a.queries : null, fmt: fmtSecs, tone: "cost", missing: qWhy },
        { key: "spill", label: "Spilled to remote a day", before: b.spill / nB, after: a.spill / nA, fmt: (v) => (v == null ? "–" : fmtBytes(v)), tone: "cost", missing: qWhy },
        { key: "cache", label: "Scanned from cache", before: b.scanned > 0 ? (b.cached / b.scanned) * 100 : null, after: a.scanned > 0 ? (a.cached / a.scanned) * 100 : null, fmt: (v) => (v == null ? "–" : fmtPct(v, 0)), tone: "good_up", points: true, missing: qWhy },
        { key: "failed", label: "Failed queries a day", before: b.failed / nB, after: a.failed / nA, fmt: fmtCount, tone: "cost", missing: qWhy },
      );
    }
    return out;
  }, [sel, fix, nB, nA, byItem, cost.why, qry.why, qry.loading, meta.price_basis, priceNote]);

  // The lede from the same figures: "From 6 Sep, WH (3010) used 2.2× the credits a day: 184.8 against 83.6 before."
  const crM = measures.find((m) => m.key === "credits"), usdM = measures.find((m) => m.key === "usd");
  const ledeText = cost.loading ? "…" : sel && fix && crM && !crM.missing && crM.before != null && crM.after != null
    ? `From ${fmtDayShort(fix)}, ${labelOf(sel)} used ${changeOf(crM).text === "no change" ? "about the same" : changeOf(crM).text} credits a day: ${fmtCr(crM.after)} against ${fmtCr(crM.before)} before${usdM && !usdM.missing && usdM.after != null && usdM.before != null ? `, or ${usdM.fmt(usdM.after)} a day against ${usdM.fmt(usdM.before)}` : ""}.`
    : null;
  React.useEffect(() => { if (p.setLede) p.setLede(ledeText); }, [ledeText]); // eslint-disable-line react-hooks/exhaustive-deps

  const controls = (
    <div className="cx-ba-controls">
      <div className="cx-ba-field">
        <span className="cx-eyebrow">Kind</span>
        <div className="cx-seg" role="group" aria-label="Kind">
          {LEVELS.map((l) => (
            <button key={l.key} type="button" className={l.key === level ? "on" : ""} aria-pressed={l.key === level} onClick={() => { setLevel(l.key); setPicked(null); }}>{l.label}</button>
          ))}
        </div>
      </div>
      <div className="cx-ba-field">
        <span className="cx-eyebrow">{lv.label}</span>
        <CxPicker label={lv.label} mono value={sel ? sel.key : null} onChange={setPicked}
          options={levelItems.map((it) => ({ value: it.key, label: labelOf(it) }))} />
      </div>
      {days.length > 1 && fix && (
        <div className="cx-ba-field">
          <span className="cx-eyebrow">After starts on</span>
          <CxPicker label="After starts on" value={fix} onChange={(v) => setFixDay(v)}
            options={days.slice(1).map((d) => ({ value: d, label: fmtDayShort(d) }))} />
        </div>
      )}
    </div>
  );
  const lead = "An average day before the date against an average day from it on. It shows what moved, not why: other changes in the same days can explain it.";

  const head = (body: React.ReactNode) => (
    <Card title="Before and after a change">
      <div className="metric-note">{lead}</div>
      {controls}
      {body}
    </Card>
  );

  // The spend feed decides whether there is anything to compare; the query feed only adds measures.
  if (cost.loading || (level === "warehouse" && qry.loading && !levelItems.length)) return head(<div className="chart-note-oneline">…</div>);
  if (cost.why && !(level === "warehouse" && levelItems.length)) return head(<div className="chart-note-oneline">{`– ${cost.why}`}</div>);
  if (!levelItems.length) return head(<div className="chart-note-oneline">{`${noDataText(p.meta, p.filters.window)}: no ${lv.plural} with credits${level === "warehouse" ? " or queries" : ""}.`}</div>);
  if (!sel || !fix || !nB || !nA) return head(<div className="chart-note-oneline">The window has under two complete days: pick a longer one.</div>);

  const by = (k: string) => measures.find((m) => m.key === k) || null;
  const cr = by("credits"), usd = by("usd");
  const crChange = cr ? changeOf(cr) : null;
  const crMissing = cr && cr.missing ? cr.missing : null;
  const kpis = (
    <KpiRow strip={usd ? [
      <IssueTile key="u" label="$ a day, after" loading={usd.missing === "…"} headline={!usd.missing && usd.after != null ? usd.fmt(usd.after) : null} unit="a day"
        missingReason={usd.missing || undefined} base={usd.before != null && !usd.missing ? `${usd.fmt(usd.before)} a day before.` : null} />,
    ] : null}>
      <IssueTile label="Credits a day, before" loading={crMissing === "…"} headline={cr && !crMissing ? fmtCr(cr.before).replace(/ credits?$/, "") : null} unit="credits"
        missingReason={crMissing || undefined} base={`${beforeSpan} · ${fmtInt(nB)} days.`} />
      <IssueTile label="Credits a day, after" loading={crMissing === "…"} headline={cr && !crMissing ? fmtCr(cr.after).replace(/ credits?$/, "") : null} unit="credits"
        missingReason={crMissing || undefined} base={`${afterSpan} · ${fmtInt(nA)} days.`} />
      <IssueTile label="Change" loading={crMissing === "…"} headline={crChange && crChange.text !== "–" ? crChange.text : null} unit="credits a day"
        missingReason={crMissing || undefined} base="After against before." />
    </KpiRow>
  );

  const vals = (() => {
    const m = byItem.get(sel.key) || new Map<string, DayVals>();
    return days.map((d) => (m.get(d) || zeroDay()).credits);
  })();

  // Measures this export cannot fill are said once, not as rows of "–".
  const shownMeasures = measures.filter((m) => !m.missing || m.missing === "…" || m.key === "credits" || m.key === "usd");
  const missingMeasures = measures.filter((m) => !shownMeasures.includes(m));
  const missWhy = [...new Set(missingMeasures.map((m) => String(m.missing)))];
  const rows: DrillRow[] = shownMeasures.map((m) => ({
    key: m.key,
    title: m.missing || undefined,
    cells: m.missing === "…" ? [m.label, "…", "…", "…"]
      : [m.label, m.missing ? "–" : m.fmt(m.before), m.missing ? "–" : m.fmt(m.after), m.missing ? <span className="muted">{m.missing}</span> : <Chip m={m} />],
  }));
  const r4 = (v: number | null) => (v == null || !Number.isFinite(v) ? "" : Math.round(v * 10000) / 10000);
  const csvCols: CsvColumn<Measure>[] = [
    { label: lv.label, value: () => labelOf(sel) },
    { label: "Measure", value: (m) => m.label },
    { label: `Before ${days[0]} to ${days[nB - 1]} (${nB} days)`, value: (m) => (m.missing ? "" : r4(m.before)) },
    { label: `After ${fix} to ${days[days.length - 1]} (${nA} days)`, value: (m) => (m.missing ? "" : r4(m.after)) },
    { label: "Change", value: (m) => changeOf(m).text },
    { label: "Why missing", value: (m) => m.missing || "" },
  ];
  const fewest = Math.min(nB, nA);
  const notes = [
    partialDay ? `Today (${fmtDayShort(partialDay)}) is partial and left out of both sides.` : null,
    fewest < FEW_DAYS ? `Only ${fmtInt(fewest)} day${fewest === 1 ? "" : "s"} on one side: one unusual day moves its average a lot.` : null,
    sel.pooled ? "Its credits sit in the pooled Other warehouses row, so only its query measures compare." : null,
    level === "warehouse" && qry.truncated ? "The query feed hit its row cap and left out quiet warehouses: the list is a lower bound." : null,
    sel.key.endsWith(":other") ? `This row pools the ${lv.plural} past the top 100 by credits; which ones it holds can change day to day.` : null,
  ].filter(Boolean).join(" ");

  return (
    <div className="cx-stack">
      {head(null)}
      {kpis}
      <ChartCard
        title={<span>Credits a day, <NameId name={sel.name} id={sel.id} /></span>}
        subtitle={`Before ${beforeSpan}, after ${afterSpan} · dashed lines are each period's average`}
        onOpenCheck={() => p.goTo({ tab: p.area, subtab: p.subtab, focusQueryId: COST_QID })}
        takeaway={notes || null}
      >
        {cost.why ? <div className="chart-note-oneline">{`– ${cost.why}`}</div> : (
          <BeforeAfterBars days={days} values={vals} fix={fix} fmt={(v) => fmtCr(v).replace(/ credits?$/, "")} label={`${sel.name}: credits by day`} />
        )}
      </ChartCard>
      <Card title="What changed" right={<CsvButton fileName={`before-after-${level}-${fix}`} columns={csvCols} rows={measures} />}>
        <div className="metric-note">{`A day with no use counts as zero.${sel.level === "warehouse" && !missingMeasures.length ? " Avg query time and queue wait are per query; cache is weighted by bytes scanned." : ""}`}</div>
        <DrillTable
          aria={`What changed for ${sel.name}`}
          cols={[{ label: "Measure" }, { label: `Before · ${fmtInt(nB)} days`, num: true }, { label: `After · ${fmtInt(nA)} days`, num: true }, { label: "Change", num: true }]}
          rows={rows}
          n={20}
        />
        {missingMeasures.length > 0 && (
          <NaStrip title={`${missingMeasures.length === 1 ? missingMeasures[0].label : "Query measures"} not in this export`}
            reason={`${missingMeasures.map((m) => m.label).join(", ")}: ${missWhy.join("; ")}`} />
        )}
      </Card>
    </div>
  );
}
(ApCostBeforeAfter as any).ownsLede = true;
