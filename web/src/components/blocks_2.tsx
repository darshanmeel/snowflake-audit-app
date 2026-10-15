// web/src/components/blocks_2.tsx -- the newer presentational blocks: plain HTML/CSS grids with typed
// props (c_redesign.css). Callers pass already-aggregated values; nothing here fetches. A missing
// value reads "–" with its reason, never 0; a cell with no run is hatched, never a colour.
import React from "react";
import { fmtInt } from "../format";
import { StatusPill } from "./primitives";

/** "name (id)": name in ink, id muted; a bare name when the id is missing or the same. */
export function NameId({ name, id }: { name: React.ReactNode; id?: string | number | null }) {
  const showId = id !== null && id !== undefined && id !== "" && String(id) !== String(name);
  return <span className="b2-nameid" title={typeof name === "string" ? `${name}${showId ? ` (${id})` : ""}` : undefined}>
    <span className="b2-name">{name}</span>{showId && <span className="b2-id">{` (${id})`}</span>}
  </span>;
}

// ═══════════════════════ HealthBadge ═══════════════════════

export type Health = "healthy" | "degraded" | "failing" | "unknown";
const HEALTH_WORD: Record<Health, string> = { healthy: "Healthy", degraded: "Degraded", failing: "Failing", unknown: "Unknown" };

/** An 8px square and a word: Healthy (ok) / Degraded (warn) / Failing (crit) / Unknown (hatched). */
export function HealthBadge({ health, label }: { health: Health; label?: string }) {
  return <span className={`b2-health h-${health}`}><span className="b2-health-sq" aria-hidden="true" />{label || HEALTH_WORD[health]}</span>;
}

// ═══════════════════════ Sparkline ═══════════════════════

/** A 40px blue polyline; `anomalies` (point indexes) get a warn dot. Fewer than 2 points draws nothing. */
export function Sparkline({ points, anomalies, height = 40, ariaLabel }: { points: (number | null)[]; anomalies?: number[]; height?: number; ariaLabel?: string }) {
  const pts = points.map((p, i) => ({ p, i })).filter((x): x is { p: number; i: number } => x.p != null && Number.isFinite(x.p));
  if (pts.length < 2) return null;
  const w = 200, pad = 3;
  const min = Math.min(...pts.map((x) => x.p)), max = Math.max(...pts.map((x) => x.p));
  const span = max - min || 1;
  const step = (w - pad * 2) / Math.max(1, points.length - 1);
  const xy = (x: { p: number; i: number }) => [pad + x.i * step, pad + (height - pad * 2) * (1 - (x.p - min) / span)];
  const marks = new Set(anomalies || []);
  return (
    <svg className="b2-spark" viewBox={`0 0 ${w} ${height}`} width="100%" height={height} preserveAspectRatio="none" role={ariaLabel ? "img" : undefined} aria-label={ariaLabel} aria-hidden={ariaLabel ? undefined : "true"}>
      <polyline points={pts.map((x) => xy(x).map((v) => v.toFixed(1)).join(",")).join(" ")} fill="none" stroke="var(--c1)" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
      {pts.filter((x) => marks.has(x.i)).map((x) => { const [cx, cy] = xy(x); return <circle key={x.i} cx={cx} cy={cy} r="2.6" fill="var(--st-warn)" />; })}
    </svg>
  );
}

// ═══════════════════════ StatStrip ═══════════════════════

export interface StatCell {
  key?: string;
  label: string;
  /** Status pill kind ("critical", "warn", "ok", "not_assessed") or none. */
  pill?: string | null;
  value: React.ReactNode | null | undefined;
  unit?: React.ReactNode;
  base?: React.ReactNode;
  /** Why the value is missing; the cell then reads "–". */
  missing?: React.ReactNode;
}

/** One card split into 4-6 cells: label + pill, a 26px value and unit, a mono base. */
export function StatStrip({ cells, ariaLabel }: { cells: StatCell[]; ariaLabel?: string }) {
  return (
    <div className="b2-statstrip" role="list" aria-label={ariaLabel}>
      {cells.map((c, i) => {
        const missing = c.value === null || c.value === undefined || c.value === "";
        return (
          <div key={c.key || i} className={`b2-stat${missing ? " is-missing" : ""}`} role="listitem">
            <div className="b2-stat-head"><span className="b2-eyebrow">{c.label}</span>{c.pill && <StatusPill kind={c.pill} />}</div>
            <div className="b2-stat-value">{missing ? "–" : c.value}{!missing && c.unit && <span className="b2-stat-unit">{c.unit}</span>}</div>
            {(missing ? c.missing : c.base) && <div className="b2-stat-base">{missing ? c.missing : c.base}</div>}
          </div>
        );
      })}
    </div>
  );
}

// ═══════════════════════ RunGrid ═══════════════════════

export type RunCell = "ok" | "failed" | "slow" | "skipped" | "none";
export interface RunGridRow {
  key: string;
  name: string;
  id?: string | number | null;
  health: Health;
  /** One state per day, oldest first, the same length as `days`. */
  cells: RunCell[];
  /** Mono metric after the cells ("85% failed · err 000630"). */
  metric?: React.ReactNode;
  onClick?: () => void;
}
const RUN_WORD: Record<RunCell, string> = { ok: "ran OK", failed: "failed", slow: "slow", skipped: "skipped", none: "no run" };

/** Rows = tasks, columns = days; the last column is today (partial). Optional failed-per-day bars on top. */
export function RunGrid({ days, rows, perDay, perDayLabel = "failed runs per day", partialLast = true, ariaLabel }: {
  days: string[]; rows: RunGridRow[]; perDay?: (number | null)[]; perDayLabel?: string; partialLast?: boolean; ariaLabel?: string;
}) {
  const cols = `minmax(110px, 220px) auto repeat(${days.length}, minmax(6px, 18px)) minmax(0, auto)`;
  const max = Math.max(1, ...(perDay || []).map((v) => Number(v) || 0));
  const last = days.length - 1;
  return (
    <div className="b2-scroll">
      <div className="b2-rungrid" style={{ gridTemplateColumns: cols }} role="table" aria-label={ariaLabel}>
        {perDay && (
          <div className="b2-rg-row b2-rg-perday" role="row">
            <span className="b2-rg-name b2-muted" role="cell">{perDayLabel}</span><span role="cell" />
            {days.map((d, i) => {
              const v = perDay[i];
              return <span key={d} role="cell" className={`b2-rg-bar${partialLast && i === last ? " partial" : ""}`} title={`${d}: ${v == null ? "–" : fmtInt(v)}`}>
                <span style={{ height: v == null ? 0 : `${(100 * Number(v)) / max}%` }} /></span>;
            })}
            <span role="cell" />
          </div>
        )}
        {rows.map((r) => (
          <div key={r.key} className={`b2-rg-row${r.onClick ? " clickable" : ""}`} role="row" onClick={r.onClick}>
            <span className="b2-rg-name" role="cell">{r.onClick
              ? <button type="button" className="b2-linkbtn" onClick={(e) => { e.stopPropagation(); r.onClick!(); }}><NameId name={r.name} id={r.id} /></button>
              : <NameId name={r.name} id={r.id} />}</span>
            <span role="cell"><HealthBadge health={r.health} /></span>
            {r.cells.map((c, i) => (
              <span key={i} role="cell" className={`b2-rg-cell c-${c}${partialLast && i === last ? " partial" : ""}`}
                title={`${days[i] || ""}: ${RUN_WORD[c]}${partialLast && i === last ? " (today, partial)" : ""}`} />
            ))}
            <span className="b2-mono b2-rg-metric" role="cell">{r.metric}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ═══════════════════════ StateBandList ═══════════════════════

export type BandState = "ok" | "failing" | "slow" | "queued" | "busy" | "idle" | "off" | "none";
export interface StateBandRow {
  key: string;
  name: string;
  id?: string | number | null;
  /** Segments in time order; widths are each segment's share of the row's total. */
  segments: { state: BandState; value: number; title?: string }[];
  metrics?: React.ReactNode;
  owner?: React.ReactNode;
  /** The last segment is still running (today): drawn partial. */
  partialLast?: boolean;
  onClick?: () => void;
}
const BAND_WORD: Record<BandState, string> = { ok: "OK", failing: "Failing", slow: "Slow", queued: "Queued", busy: "Busy", idle: "Idle, paying", off: "Not running", none: "No data" };

/** One 16px band per object across the window, segments sized by duration. */
export function StateBandList({ rows, legend, ariaLabel }: { rows: StateBandRow[]; legend?: BandState[]; ariaLabel?: string }) {
  return (
    <div className="b2-bands" role="list" aria-label={ariaLabel}>
      {legend && legend.length > 0 && (
        <div className="b2-legend">{legend.map((s) => <span key={s} className="b2-legend-item"><span className={`b2-sw s-${s}`} />{BAND_WORD[s]}</span>)}</div>
      )}
      {rows.map((r) => {
        const total = r.segments.reduce((a, s) => a + Math.max(0, s.value), 0) || 1;
        const last = r.segments.length - 1;
        return (
          <div key={r.key} className="b2-band-row" role="listitem">
            <span className="b2-band-name">{r.onClick
              ? <button type="button" className="b2-linkbtn" onClick={r.onClick}><NameId name={r.name} id={r.id} /></button>
              : <NameId name={r.name} id={r.id} />}</span>
            <span className="b2-band">
              {r.segments.map((s, i) => (
                <span key={i} className={`b2-seg s-${s.state}${r.partialLast && i === last ? " partial" : ""}`}
                  style={{ flexBasis: `${(100 * Math.max(0, s.value)) / total}%` }} title={s.title || BAND_WORD[s.state]} />
              ))}
            </span>
            <span className="b2-mono b2-band-metrics">{r.metrics}</span>
            {r.owner !== undefined && <span className="b2-band-owner">{r.owner}</span>}
          </div>
        );
      })}
    </div>
  );
}

// ═══════════════════════ CompareToBaseline ═══════════════════════

export interface BaselineRow { key?: string; attr: string; value: string; /** % of the selection with it */ sel: number | null; /** % of all with it */ all: number | null }

/** Why a set differs: per attribute value, the selection's % (plum) against all (blue-soft), largest gap first. */
export function CompareToBaseline({ title, selLabel = "selection", allLabel = "all", rows, n = 6 }: {
  title: React.ReactNode; selLabel?: string; allLabel?: string; rows: BaselineRow[]; n?: number;
}) {
  const gap = (r: BaselineRow) => Math.abs((r.sel ?? 0) - (r.all ?? 0));
  const sorted = [...rows].sort((a, b) => gap(b) - gap(a)).slice(0, n);
  const pct = (v: number | null) => (v == null ? "–" : `${Math.round(v)} %`);
  return (
    <div className="b2-cmp">
      <div className="b2-cmp-head"><span className="b2-eyebrow">{title}</span>
        <span className="b2-legend"><span className="b2-legend-item"><span className="b2-sw s-sel" />{selLabel}</span><span className="b2-legend-item"><span className="b2-sw s-all" />{allLabel}</span></span></div>
      {sorted.map((r, i) => (
        <div key={r.key || `${r.attr}-${r.value}-${i}`} className="b2-cmp-row">
          <span className="b2-cmp-label" title={`${r.attr}: ${r.value}`}><span className="b2-muted">{r.attr} </span><b>{r.value}</b></span>
          <span className="b2-cmp-bars">
            <span className="b2-track"><span className="b2-fill s-sel" style={{ width: `${Math.max(0, Math.min(100, r.sel ?? 0))}%` }} /></span>
            <span className="b2-track"><span className="b2-fill s-all" style={{ width: `${Math.max(0, Math.min(100, r.all ?? 0))}%` }} /></span>
          </span>
          <span className="b2-mono b2-cmp-val">{`${pct(r.sel)} vs ${pct(r.all)}`}</span>
        </div>
      ))}
    </div>
  );
}

// ═══════════════════════ Dumbbell (earlier -> now) ═══════════════════════

export interface DumbbellRow { key?: string; name: string; id?: string | number | null; before: number; after: number; valueText: React.ReactNode }

/** Earlier -> now on one track: blue ring earlier, warn ring now, a soft span between. */
export function DumbbellRows({ rows, max }: { rows: DumbbellRow[]; max?: number }) {
  const top = max && max > 0 ? max : Math.max(1, ...rows.flatMap((r) => [r.before, r.after]));
  const at = (v: number) => `${Math.max(0, Math.min(100, (100 * v) / top))}%`;
  return (
    <div className="b2-dumbbells" role="list">
      {rows.map((r, i) => {
        const lo = Math.min(r.before, r.after), hi = Math.max(r.before, r.after);
        return (
          <div key={r.key || i} className="b2-db-row" role="listitem">
            <span className="b2-db-name"><NameId name={r.name} id={r.id} /></span>
            <span className="b2-db-track">
              <span className="b2-db-span" style={{ left: at(lo), width: `calc(${at(hi)} - ${at(lo)})` }} />
              <span className="b2-db-dot before" style={{ left: at(r.before) }} title="earlier" />
              <span className="b2-db-dot after" style={{ left: at(r.after) }} title="now" />
            </span>
            <span className="b2-mono b2-db-val">{r.valueText}</span>
          </div>
        );
      })}
    </div>
  );
}

// ═══════════════════════ ScheduleStrip ═══════════════════════

/** 24 columns, one per hour: bar height = starts in that hour; hours at or over `collisionAt` in warn. */
export function ScheduleStrip({ hours, collisionAt, unit = "starts", ariaLabel }: { hours: (number | null)[]; collisionAt?: number; unit?: string; ariaLabel?: string }) {
  const max = Math.max(1, ...hours.map((v) => Number(v) || 0));
  return (
    <div className="b2-sched" role="img" aria-label={ariaLabel}>
      <div className="b2-sched-bars">
        {Array.from({ length: 24 }, (_, h) => {
          const v = hours[h];
          const hot = collisionAt != null && v != null && v >= collisionAt;
          return <span key={h} className={`b2-sched-col${v == null ? " none" : ""}${hot ? " hot" : ""}`} title={`${String(h).padStart(2, "0")}:00 · ${v == null ? "–" : `${fmtInt(v)} ${unit}`}`}>
            <span style={{ height: v == null ? "100%" : `${(100 * Number(v)) / max}%` }} /></span>;
        })}
      </div>
      <div className="b2-sched-axis b2-mono"><span>00</span><span>06</span><span>12</span><span>18</span><span>23</span></div>
    </div>
  );
}

// ═══════════════════════ ClusterDots ═══════════════════════

/** 12px squares: filled = clusters used, outlined = allowed but unused. */
export function ClusterDots({ used, allowed }: { used: number; allowed: number }) {
  const n = Math.max(0, Math.round(allowed));
  const u = Math.max(0, Math.min(n, Math.round(used)));
  return (
    <span className="b2-clusters" role="img" aria-label={`${fmtInt(u)} of ${fmtInt(n)} clusters used`} title={`${fmtInt(u)} of ${fmtInt(n)} clusters used`}>
      {Array.from({ length: n }, (_, i) => <span key={i} className={`b2-cl${i < u ? " used" : ""}`} />)}
    </span>
  );
}
