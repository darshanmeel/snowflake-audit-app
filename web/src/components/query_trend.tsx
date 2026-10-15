// Queries > Trend: one measure per warehouse per day (or month), and its change against the earlier period.
import React from "react";
import "../styles/css/p_query_trend.css";
import { fmtBytes, fmtDayShort, fmtDuration, fmtInt } from "../format";
import { fmtChangePct, numOrZero, useFindingAgg } from "./hooks";
import { ChartCard } from "./primitives";
import { MultiLine, paletteColor } from "./charts";
import { Columns } from "./charts_more";
import { DrillTable } from "./drill_table";
import { NameId } from "./blocks_2";
import { fmtShare, pctOf } from "./blocks";
import { aggNote, whNameId } from "./de_blocks";
import { windowDayList } from "./run_blocks";
import { DrawerBus } from "./drawer";
import { DAY_ROWS_MAX, MONTH_ROWS_MAX, GrainSwitch, fmtMonth, latest, monthOf, monthRun, partialMonths } from "./grain";
import type { Grain } from "./grain";
import { CsvButton } from "./csv";
import type { CsvColumn } from "./csv";
import type { ApPageProps } from "./area_pages";
import type { FetchState, Finding, Row } from "../types";

const QID = "sf_qry_daily_by_warehouse";
// The server takes at most 8 extra columns per call, so p95 comes in a second call.
const ALSO = ["failed_queries", "total_elapsed_s", "queued_overload_s", "queued_provisioning_s",
  "bytes_spilled_remote", "bytes_spilled_local", "bytes_scanned", "cache_scan_pct"];
const GROUP = ["account_id", "warehouse_id", "usage_date"];
const TOP_N = 5;
const HEAT_ROWS = 10;
// Under this a change is noise.
const NOISE_PCT = 5;

/** One warehouse's sums for one day; p95 is the day's own (it cannot be added up). */
interface Sums { queries: number; failed: number; total: number; qOver: number; qProv: number; spillR: number; spillL: number; scanned: number; cacheB: number; p95: number | null }
const zero = (): Sums => ({ queries: 0, failed: 0, total: 0, qOver: 0, qProv: 0, spillR: 0, spillL: 0, scanned: 0, cacheB: 0, p95: null });

type Unit = "count" | "dur" | "sec" | "bytes" | "pct";
// dir: 1 = a rise is bad, -1 = a rise is good, 0 = neither.
interface Measure { key: string; label: string; unit: Unit; dir: 1 | -1 | 0; dayOnly?: boolean; what: string; val: (c: Sums[]) => number | null }

const sumOf = (f: keyof Sums) => (c: Sums[]) => c.reduce((s, x) => s + numOrZero(x[f]), 0);
const MEASURES: Measure[] = [
  { key: "queries", label: "Queries", unit: "count", dir: 0, what: "Statements run on the warehouse.", val: sumOf("queries") },
  { key: "failed", label: "Failed queries", unit: "count", dir: 1, what: "Statements that ended in FAIL or INCIDENT.", val: sumOf("failed") },
  { key: "avg", label: "Avg time", unit: "sec", dir: 1, what: "Total elapsed time over queries, waits included; a day with no queries reads –.",
    val: (c) => { const q = sumOf("queries")(c); return q > 0 ? sumOf("total")(c) / q : null; } },
  { key: "p95", label: "p95 time", unit: "sec", dir: 1, dayOnly: true, what: "The day's 95th percentile query time (approximate); over several days, the worst day.",
    val: (c) => { const v = c.map((x) => x.p95).filter((x): x is number => x != null); return v.length ? Math.max(...v) : null; } },
  { key: "total", label: "Total time", unit: "dur", dir: 1, what: "Elapsed time of all queries added up.", val: sumOf("total") },
  { key: "qover", label: "Queued overload", unit: "dur", dir: 1, what: "Time queries waited because the warehouse was full. More clusters or a split workload cut it.", val: sumOf("qOver") },
  { key: "qprov", label: "Queued provisioning", unit: "dur", dir: 1, what: "Time queries waited for the warehouse to resume or resize.", val: sumOf("qProv") },
  { key: "spillr", label: "Remote spill", unit: "bytes", dir: 1, what: "Data written to remote storage when memory and local disk ran out; the slowest kind of spill.", val: sumOf("spillR") },
  { key: "spilll", label: "Local spill", unit: "bytes", dir: 1, what: "Data written to the warehouse's local disk when memory ran out.", val: sumOf("spillL") },
  { key: "cache", label: "Cache %", unit: "pct", dir: -1, what: "Share of scanned bytes read from the warehouse cache; it drops after the warehouse suspends.",
    val: (c) => { const s = sumOf("scanned")(c); return s > 0 ? (100 * sumOf("cacheB")(c)) / s : null; } },
];
const UNIT_WORD: Record<Unit, string> = { count: "count", dur: "seconds", sec: "seconds per query", bytes: "bytes", pct: "%" };
const PLOT_WORD: Record<Unit, string> = { count: "count", dur: "minutes", sec: "seconds", bytes: "GB", pct: "%" };

function fmtUnit(unit: Unit, v: number | null): string {
  if (v == null || !Number.isFinite(v)) return "–";
  if (unit === "count") return fmtInt(Math.round(v));
  if (unit === "dur") return v > 0 && v < 1 ? "<1 s" : fmtDuration(v);
  if (unit === "sec") return v < 10 ? `${v.toFixed(v < 1 ? 2 : 1)} s` : fmtDuration(v);
  if (unit === "bytes") return fmtBytes(v);
  return `${v.toFixed(0)}%`;
}
// Lines plot waits in minutes and bytes in GB, so the axis reads in a sane unit.
function plotOf(unit: Unit, v: number | null): number {
  if (v == null) return 0;
  return unit === "dur" ? v / 60 : unit === "bytes" ? v / 1e9 : v;
}

interface Wh { key: string; id: string | null; name: string; days: Map<string, Sums>; queries: number }
interface WhRow { wh: Wh; values: (number | null)[]; value: number | null; change: { text: string; tone: string } }

function findingOf(p: ApPageProps, id: string): Finding | null {
  return (p.findings || []).find((f) => f.query_id === id) || (p.allFindingsIndex ? p.allFindingsIndex[id] || null : null);
}

export function QTrend(p: ApPageProps) {
  const [mKey, setMKey] = React.useState("queries");
  const [grain, setGrain] = React.useState<Grain>("day");
  const [picked, setPicked] = React.useState<string | null>(null);
  const f = findingOf(p, QID);
  // Server-side sums per warehouse and day: no row cap, so a long window keeps every warehouse.
  const s = useFindingAgg(f ? QID : null, p.filters.window, p.filters.accountIds, GROUP, "sum", "queries",
    { also: ALSO, pick: ["warehouse_name"] }) as FetchState;
  // One row per group, so the sum is the day's own p95.
  const sP95 = useFindingAgg(f ? QID : null, p.filters.window, p.filters.accountIds, GROUP, "sum", "p95_elapsed_s") as FetchState;
  const note = aggNote(s, p.meta, p.filters.window, !!f) || aggNote(sP95, p.meta, p.filters.window, !!f);
  const m = MEASURES.find((x) => x.key === mKey && !(x.dayOnly && grain === "month")) || MEASURES[0];

  const whs = React.useMemo((): Wh[] | null => {
    if (note || !s.data || !sP95.data) return null;
    const p95 = new Map<string, number>();
    (sP95.data.groups || []).forEach((g: Row) => {
      if (g.key && g.key[1] != null && g.key[2] != null && g.value != null) p95.set(`${g.key[0] ?? ""}|${g.key[1]}|${String(g.key[2]).slice(0, 10)}`, Number(g.value));
    });
    const out = new Map<string, Wh>();
    (s.data.groups || []).forEach((g: Row) => {
      if (!g.key || g.key[1] == null || g.key[2] == null) return;
      const key = `${g.key[0] ?? ""}|${g.key[1]}`, day = String(g.key[2]).slice(0, 10);
      const a = g.also || {};
      let w = out.get(key);
      if (!w) {
        const ni = whNameId(g.key[1]);
        const nm = g.pick && g.pick.warehouse_name ? String(g.pick.warehouse_name) : ni.name;
        w = { key, id: ni.id, name: nm, days: new Map(), queries: 0 };
        out.set(key, w);
      }
      const c = w.days.get(day) || zero();
      const q = numOrZero(g.value), scanned = numOrZero(a.bytes_scanned);
      c.queries += q; c.failed += numOrZero(a.failed_queries); c.total += numOrZero(a.total_elapsed_s);
      c.qOver += numOrZero(a.queued_overload_s); c.qProv += numOrZero(a.queued_provisioning_s);
      c.spillR += numOrZero(a.bytes_spilled_remote); c.spillL += numOrZero(a.bytes_spilled_local);
      c.scanned += scanned; c.cacheB += (scanned * numOrZero(a.cache_scan_pct)) / 100;
      // a day with no queries has no p95, not a p95 of 0
      const dp = p95.get(`${key}|${day}`);
      if (q > 0 && dp != null) c.p95 = Math.max(c.p95 ?? 0, dp);
      w.days.set(day, c);
      w.queries += q;
    });
    return [...out.values()].filter((w) => w.queries > 0);
  }, [s, sP95, note]);

  const days = React.useMemo(() => windowDayList(p.meta, p.filters.window, whs ? whs.flatMap((w) => [...w.days.keys()]) : []),
    [p.meta, p.filters.window, whs]);
  const pd = p.meta && p.meta.cost_cutoff && p.meta.cost_cutoff.partial_day ? String(p.meta.cost_cutoff.partial_day).slice(0, 10) : null;
  const partialDay = pd && days[days.length - 1] === pd ? pd : null;
  const { open: openMonth, cut: cutMonth } = partialMonths(days, true);
  const months = latest(monthRun(days.map(monthOf)), MONTH_ROWS_MAX);
  const keys = grain === "day" ? latest(days, DAY_ROWS_MAX) : months;
  const isPartial = (k: string) => (grain === "day" ? k === partialDay : k === openMonth || k === cutMonth);
  const cellsOf = (w: Wh, k: string): Sums[] => (grain === "day"
    ? [w.days.get(k) || zero()]
    : days.filter((d) => monthOf(d) === k).map((d) => w.days.get(d) || zero()));
  // The change sets the later half of the window's complete days against the earlier half, at either grain.
  const full = partialDay ? days.slice(0, -1) : days;
  const half = Math.floor(full.length / 2);
  const earlyDays = half >= 2 ? full.slice(0, half) : [], lateDays = half >= 2 ? full.slice(full.length - half) : [];
  const fmt = (v: number | null) => fmtUnit(m.unit, v);
  // A period with no queries has no value, so the grid leaves it blank rather than reading 0.
  const periodVal = (c: Sums[]) => (sumOf("queries")(c) > 0 ? m.val(c) : null);
  const range = days.length ? `${fmtDayShort(days[0])} – ${fmtDayShort(days[days.length - 1])}${partialDay ? " (last day partial)" : ""}` : "";

  const change = (w: Wh): { text: string; tone: string } => {
    if (!earlyDays.length) return { text: "–", tone: "" };
    const a = m.val(earlyDays.map((d) => w.days.get(d) || zero())), b = m.val(lateDays.map((d) => w.days.get(d) || zero()));
    if (a == null || b == null) return { text: "–", tone: "" };
    const toneOf = (up: boolean, small: boolean) => (small || !m.dir ? "" : (up === (m.dir === 1)) ? "qt-bad" : "qt-good");
    if (m.unit === "pct") {
      const pts = b - a;
      return { text: `${pts >= 0 ? "+" : "−"}${Math.abs(pts).toFixed(0)} pts`, tone: toneOf(pts > 0, Math.abs(pts) < 2) };
    }
    if (a <= 0) return b > 0 ? { text: fmtChangePct(null), tone: toneOf(true, false) } : { text: "–", tone: "" };
    const pct = ((b - a) / a) * 100;
    return { text: fmtChangePct(pct), tone: toneOf(pct > 0, Math.abs(pct) < NOISE_PCT) };
  };

  const rows = React.useMemo((): WhRow[] | null => {
    if (!whs) return null;
    const out = whs.map((wh) => ({
      wh, values: keys.map((k) => periodVal(cellsOf(wh, k))), value: m.val(days.map((d) => wh.days.get(d) || zero())), change: change(wh),
    }));
    // A share or an average means little on a few queries, so those list the busiest warehouses first.
    const byValue = (x: WhRow, y: WhRow) => numOrZero(y.value) - numOrZero(x.value);
    const byQueries = (x: WhRow, y: WhRow) => y.wh.queries - x.wh.queries;
    const [first, second] = m.unit === "pct" || m.unit === "sec" ? [byQueries, byValue] : [byValue, byQueries];
    return out.sort((x, y) => first(x, y) || second(x, y) || x.wh.name.localeCompare(y.wh.name));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [whs, m, grain, days.join(","), keys.join(",")]);

  // The lede reads queries whatever the picker shows, so the page head stays put.
  const totalQ = whs ? whs.reduce((t, w) => t + w.queries, 0) : 0;
  const busiest = whs && whs.length ? [...whs].sort((a, b) => b.queries - a.queries)[0] : null;
  const busiestName = busiest ? `${busiest.name}${busiest.id && busiest.id !== busiest.name ? ` (${busiest.id})` : ""}` : "";
  // Scope named: this check counts only statements that ran on a warehouse.
  const ledeHead = whs && whs.length && busiest
    ? `${fmtInt(totalQ)} statements ran on ${fmtInt(whs.length)} warehouses in ${range}; `
    : null;
  const ledeTail = busiest ? ` ran ${fmtShare(pctOf(busiest.queries, totalQ))} of them.` : "";
  const loading = (s.phase === "loading" || sP95.phase === "loading") && !!f;
  const ledeKey = loading ? "…" : ledeHead ? `${ledeHead}${busiestName}${ledeTail}` : "";
  React.useEffect(() => {
    if (!p.setLede) return;
    // A node, so a long warehouse name can wrap on a phone.
    const node = loading ? "…" : ledeHead ? <>{ledeHead}<span className="qt-lede-name">{busiestName}</span>{ledeTail}</> : null;
    (p.setLede as unknown as (v: React.ReactNode) => void)(node);
  }, [ledeKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const sel = rows && rows.length ? rows.find((r) => r.wh.key === picked) || null : null;
  const pick = (k: string) => setPicked((cur) => (cur === k ? null : k));
  const top = rows ? rows.slice(0, TOP_N) : [];
  const heat = rows ? rows.slice(0, HEAT_ROWS) : [];
  const keyLabel = (k: string) => (grain === "day" ? fmtDayShort(k) : fmtMonth(k));
  const partNote = grain === "day"
    ? (partialDay ? `${fmtDayShort(partialDay)} is partial (to ${(p.meta && p.meta.cost_cutoff && p.meta.cost_cutoff.partial_until) || "the export"} UTC).` : null)
    : [openMonth, cutMonth].filter(Boolean).length ? `${[cutMonth, openMonth].filter(Boolean).map((k) => fmtMonth(k)).join(" and ")} ${cutMonth && openMonth ? "are part months" : "is a part month"} in this window.` : null;
  const shownNote = grain === "day" && days.length > keys.length ? `Latest ${fmtInt(keys.length)} of ${fmtInt(days.length)} days.` : null;

  const csvCols: CsvColumn<WhRow>[] = [
    { label: "Warehouse", value: (r) => r.wh.name },
    { label: "Warehouse id", value: (r) => r.wh.id ?? "" },
    ...keys.map((k, i): CsvColumn<WhRow> => ({ label: grain === "day" ? k : k.slice(0, 7), value: (r) => (r.values[i] == null ? "" : Math.round(r.values[i]! * 10000) / 10000) })),
    { label: `Window ${days[0] || ""} to ${days[days.length - 1] || ""}`, value: (r) => (r.value == null ? "" : Math.round(r.value * 10000) / 10000) },
    ...(m.key === "queries" ? [] : [{ label: "Queries", value: (r: WhRow) => r.wh.queries }]),
    { label: "Later half vs earlier half", value: (r) => r.change.text },
  ];

  // Big values plot in thousands, so the y labels fit the chart's left gutter.
  const plotted = top.map((r) => r.values.map((v) => plotOf(m.unit, v)));
  const kScale = Math.max(0, ...plotted.flat()) >= 1000;
  const plotWord = `${kScale ? "thousand " : ""}${PLOT_WORD[m.unit]}`;

  const picker = (
    <div className="ws-actions qt-picker" role="group" aria-label="Measure">
      {MEASURES.filter((x) => !(x.dayOnly && grain === "month")).map((x) => (
        <button key={x.key} type="button" className={x.key === m.key ? "on" : ""} onClick={() => setMKey(x.key)}>{x.label}</button>
      ))}
    </div>
  );

  return (
    <div className="ac-page qt-page">
      <ChartCard title={`${m.label} by warehouse`} subtitle={`${m.what} · ${plotWord} · top ${TOP_N} warehouses${rows ? ` of ${fmtInt(rows.length)}` : ""}`}
        onOpenCheck={f ? () => DrawerBus.open({ id: QID }) : null} takeaway={null}>
        <div className="qt-bar">
          {picker}
          <div className="qt-bar-right">
            <GrainSwitch value={grain} onChange={setGrain} />
            <CsvButton fileName={`warehouse-${m.key}-${grain}`} columns={csvCols} rows={rows || []} />
          </div>
        </div>
        {note ? <div className="chart-note-oneline">{note}</div>
          : !rows ? <div className="chart-note-oneline">…</div>
            : !rows.length ? <div className="chart-note-oneline">{`No data for this in ${range || `the last ${fmtInt(p.filters.window)} days`}`}</div>
              : grain === "month" && keys.length < 2
                ? <div className="chart-note-oneline">{`Only ${fmtMonth(keys[keys.length - 1])} in this window: pick a longer window for a monthly trend.`}</div>
                : (
                  <>
                    <MultiLine series={top.map((r, i) => ({ label: <span className="qt-leg-name">{r.wh.name}</span>, color: paletteColor(i), data: plotted[i].map((v) => (kScale ? v / 1000 : v)) }))}
                      xLabels={keys.map((k) => `${keyLabel(k)}${isPartial(k) ? " (partial)" : ""}`)} />
                    <div className="metric-note">{[shownNote, partNote, "A period with no queries plots at 0; the grid leaves it blank."].filter(Boolean).join(" ")}</div>
                  </>
                )}
      </ChartCard>

      {rows && rows.length > 0 && !note && (
        <ChartCard title={`By warehouse and ${grain}`} subtitle={`darker = more · blank = no queries · faded = partial · top ${fmtInt(heat.length)} of ${fmtInt(rows.length)} warehouses · click one for its own chart`} takeaway={null}>
          <HeatRows rows={heat} keys={keys} keyLabel={keyLabel} isPartial={isPartial} fmt={fmt} selected={sel ? sel.wh.key : null} onPick={pick} label={m.label} />
        </ChartCard>
      )}

      {rows && rows.length > 0 && !note && (
        <ChartCard title="Change by warehouse" subtitle={earlyDays.length
          ? `${m.label}: ${fmtDayShort(lateDays[0])} – ${fmtDayShort(lateDays[lateDays.length - 1])} vs ${fmtDayShort(earlyDays[0])} – ${fmtDayShort(earlyDays[earlyDays.length - 1])}, complete days only`
          : "Too few complete days in this window to compare halves."} takeaway={null}>
          <DrillTable aria={`${m.label} change by warehouse`} n={10}
            cols={[{ label: "Warehouse" }, { label: m.label, num: true }, ...(m.key === "queries" ? [] : [{ label: "Queries", num: true }]), { label: "Later vs earlier half", num: true }]}
            rows={rows.map((r) => ({
              key: r.wh.key, selected: !!sel && sel.wh.key === r.wh.key, onOpen: () => pick(r.wh.key),
              cells: [<NameId key="n" name={r.wh.name} id={r.wh.id} />, fmt(r.value), ...(m.key === "queries" ? [] : [fmtInt(r.wh.queries)]),
                <span key="c" className={r.change.tone}>{r.change.text}</span>],
            }))} />
        </ChartCard>
      )}

      {sel && <WarehouseCard r={sel} m={m} days={latest(days, DAY_ROWS_MAX)} months={months} partialDay={partialDay}
        partMonths={[openMonth, cutMonth].filter((x): x is string => !!x)} />}
    </div>
  );
}
(QTrend as any).ownsLede = true;

/** Warehouse x period cells in the single-hue scale, darker = more; a period with no value is blank. */
function HeatRows({ rows, keys, keyLabel, isPartial, fmt, selected, onPick, label }: {
  rows: WhRow[]; keys: string[]; keyLabel: (k: string) => string; isPartial: (k: string) => boolean; fmt: (v: number | null) => string;
  selected: string | null; onPick: (k: string) => void; label: string;
}) {
  const vals = rows.flatMap((r) => r.values).filter((v): v is number => v != null && Number.isFinite(v));
  const max = Math.max(0, ...vals);
  const color = (v: number | null) => (v == null ? "transparent" : !(v > 0) || !(max > 0) ? "var(--seq-0)" : `var(--seq-${Math.min(5, Math.max(1, Math.ceil((v / max) * 5)))})`);
  const every = keys.length > 20 ? 7 : 1;
  const style = { ["--qt-cols" as any]: keys.length } as React.CSSProperties;
  return (
    <div className="qt-heat" role="table" aria-label={`${label} by warehouse and period`} style={style}>
      <div className="qt-heat-row qt-heat-head" role="row">
        <span className="qt-heat-name" role="columnheader">Warehouse</span>
        {keys.map((k, i) => (
          <span key={k} role="columnheader" className={`qt-heat-col${isPartial(k) ? " qt-partial" : ""}`} title={`${keyLabel(k)}${isPartial(k) ? " (partial)" : ""}`}>
            {(keys.length - 1 - i) % every === 0 ? keyLabel(k) : ""}
          </span>
        ))}
        <span className="qt-heat-total" role="columnheader">Window</span>
      </div>
      {rows.map((r) => (
        <button type="button" role="row" key={r.wh.key} className={`qt-heat-row${selected === r.wh.key ? " selected" : ""}`} aria-pressed={selected === r.wh.key || undefined} onClick={() => onPick(r.wh.key)}>
          <span className="qt-heat-name" role="cell" title={`${r.wh.name}${r.wh.id ? ` (${r.wh.id})` : ""}`}><NameId name={r.wh.name} id={r.wh.id} /></span>
          {keys.map((k, i) => {
            const v = r.values[i];
            return <span key={k} role="cell" className={`qt-cell${isPartial(k) ? " qt-partial" : ""}${v == null ? " qt-empty" : ""}`}
              style={{ background: color(v) }} title={`${r.wh.name} · ${keyLabel(k)}${isPartial(k) ? " (partial)" : ""}: ${fmt(v)}`} />;
          })}
          <span className="qt-heat-total mono" role="cell">{fmt(r.value)}</span>
        </button>
      ))}
    </div>
  );
}

/** One warehouse's measure by day, and its months in a short list. */
function WarehouseCard({ r, m, days, months, partialDay, partMonths }: {
  r: WhRow; m: Measure; days: string[]; months: string[]; partialDay: string | null; partMonths: string[];
}) {
  // A period with no queries has no value.
  const at = (ds: string[]) => { const c = ds.map((d) => r.wh.days.get(d) || zero()); return sumOf("queries")(c) > 0 ? m.val(c) : null; };
  const dVals = days.map((d) => at([d]));
  const peak = dVals.reduce((best: number, v, i) => (numOrZero(v) > numOrZero(dVals[best]) ? i : best), 0);
  const monthRows = months.map((k) => {
    const ds = [...r.wh.days.keys()].filter((d) => monthOf(d) === k);
    return { k, v: at(ds), q: ds.reduce((t, d) => t + (r.wh.days.get(d) || zero()).queries, 0) };
  });
  return (
    <ChartCard title={<span className="qt-card-title"><NameId name={r.wh.name} id={r.wh.id} /></span>} subtitle={`${m.label} by day · faded = partial · ${fmtInt(r.wh.queries)} queries in the window · click the warehouse again to close`}
      onOpenCheck={() => DrawerBus.open({ id: QID, col: "warehouse_id", val: r.wh.id, label: `${r.wh.name}${r.wh.id ? ` (${r.wh.id})` : ""}` })} takeaway={null}>
      <Columns days={days} series={[{ name: m.label, values: dVals.map((v) => v ?? 0) }]} valueFmt={(v) => fmtUnit(m.unit, v)} unitLabel={UNIT_WORD[m.unit]}
        partialDays={partialDay ? [partialDay] : null} ariaLabel={`${r.wh.name} ${m.label} by day`}
        note={days.length && dVals[peak] != null ? `Highest ${fmtUnit(m.unit, dVals[peak])} on ${fmtDayShort(days[peak])}.` : null} />
      {!m.dayOnly && monthRows.length > 0 && (
        <DrillTable aria={`${r.wh.name} ${m.label} by month`} n={MONTH_ROWS_MAX}
          cols={[{ label: "Month" }, { label: m.label, num: true }, ...(m.key === "queries" ? [] : [{ label: "Queries", num: true }])]}
          rows={monthRows.map((x) => ({ key: x.k, cells: [`${fmtMonth(x.k)}${partMonths.includes(x.k) ? " (part month)" : ""}`, fmtUnit(m.unit, x.v), ...(m.key === "queries" ? [] : [fmtInt(x.q)])] }))} />
      )}
    </ChartCard>
  );
}
