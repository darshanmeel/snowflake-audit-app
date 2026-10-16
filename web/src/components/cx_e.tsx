// web/src/components/cx_e.tsx -- presentational helpers for the Tasks, Loading and Governance pages:
// single-colour ranked bars on fixed columns, a run grid with its own numeric columns, a section
// eyebrow and a one-line stat. Callers pass aggregated values; nothing here fetches.
import React from "react";
import { fmtInt } from "../format";
import { HealthBadge, NameId } from "./blocks_2";
import type { Health, RunCell } from "./blocks_2";
import { fmtShare } from "./blocks";

/** The page wrapper that scopes this group's look (cx_e.css). */
export function CxPage({ children }: { children?: React.ReactNode }) {
  return <div className="cx-e">{children}</div>;
}

/** A small uppercase label above a block of rows. */
export function CxEyebrow({ children }: { children?: React.ReactNode }) {
  return <div className="cx-eyebrow">{children}</div>;
}

/** A one-line sentence in place of a chart that would carry no information. */
export function CxStat({ children }: { children?: React.ReactNode }) {
  return <div className="cx-stat">{children}</div>;
}

export interface CxRankItem {
  key: string;
  label: React.ReactNode;
  value: number;
  /** Bold figure on the right ("81%"); the muted rest follows it ("1,375 runs"). */
  strong?: React.ReactNode;
  rest?: React.ReactNode;
  /** An aggregate ("Other (6)"): drawn last, in the neutral colour. */
  other?: boolean;
  color?: string;
  onClick?: (() => void) | null;
}

/** Ranked single-colour bars: `label | bar | value` on fixed columns, or label above the bar. */
export function CxRanked({ items, max, layout = "grid", ariaLabel, labelWidth }: {
  items: CxRankItem[]; max?: number; layout?: "grid" | "above"; ariaLabel?: string; labelWidth?: number;
}) {
  if (!items.length) return null;
  const top = max ?? Math.max(1, ...items.map((i) => i.value));
  const pct = (v: number) => Math.max(0, Math.min(100, (100 * v) / (top || 1)));
  const style = labelWidth ? ({ "--cx-label-w": `${labelWidth}px` } as React.CSSProperties) : undefined;
  return (
    <div className={`cx-rank cx-rank-${layout}`} role="list" aria-label={ariaLabel} style={style}>
      {items.map((it) => {
        const label = it.onClick
          ? <button type="button" className="cx-rank-link" onClick={it.onClick}>{it.label}</button>
          : it.label;
        const value = <span className="cx-rank-val">{it.strong != null && <b>{it.strong}</b>}{it.rest != null && <span className="cx-muted">{it.strong != null ? " · " : ""}{it.rest}</span>}</span>;
        const bar = (
          <span className="cx-rank-track" aria-hidden="true">
            <span className="cx-rank-fill" style={{ width: `${pct(it.value)}%`, background: it.color || (it.other ? "var(--c-other)" : "var(--c1)") }} />
          </span>
        );
        return layout === "above"
          ? <div key={it.key} className="cx-rank-row" role="listitem"><div className="cx-rank-head"><span className="cx-rank-label">{label}</span>{value}</div>{bar}</div>
          : <div key={it.key} className="cx-rank-row" role="listitem"><span className="cx-rank-label">{label}</span>{bar}{value}</div>;
      })}
    </div>
  );
}

/** A tally of `rows` by key into ranked items, the largest first, with "Other (n)" past `n`. */
export function rankTally(entries: [string, number][], total: number, unit: (v: number) => string, n = 7, label?: (k: string) => React.ReactNode): CxRankItem[] {
  const sorted = [...entries].filter(([, v]) => v > 0).sort((a, b) => b[1] - a[1]);
  const head = sorted.length > n ? sorted.slice(0, n - 1) : sorted;
  const tail = sorted.length > n ? sorted.slice(n - 1) : [];
  const item = (k: string, v: number, other = false): CxRankItem => ({
    key: k, label: label && !other ? label(k) : k, value: v, other,
    strong: total > 0 ? fmtShare((100 * v) / total) : undefined, rest: unit(v),
  });
  const out = head.map(([k, v]) => item(k, v));
  if (tail.length) out.push(item(`Other (${fmtInt(tail.length)})`, tail.reduce((s, [, v]) => s + v, 0), true));
  return out;
}

const RUN_WORD: Record<RunCell, string> = { ok: "ran OK", failed: "failed", slow: "slow", skipped: "skipped", none: "no run" };

export interface CxRunRow {
  key: string; name: string; id?: string | number | null; health: Health; cells: RunCell[];
  failed: React.ReactNode; slow: React.ReactNode; lastError: React.ReactNode; onClick?: () => void;
}

/** Rows = tasks, columns = days, then FAILED / SLOW / LAST ERROR in their own columns. */
export function CxRunGrid({ days, rows, perDay, partialLast, ariaLabel }: {
  days: string[]; rows: CxRunRow[]; perDay: number[]; partialLast: boolean; ariaLabel?: string;
}) {
  const max = Math.max(1, ...perDay);
  const last = days.length - 1;
  const cols = { gridTemplateColumns: `220px 92px repeat(${days.length}, minmax(6px, 18px)) 60px 48px minmax(100px, auto)` };
  return (
    <div className="b2-scroll">
      <div className="cx-rungrid" style={cols} role="table" aria-label={ariaLabel}>
        <div className="cx-rg-row cx-rg-head" role="row">
          <span role="columnheader">Task</span><span role="columnheader">State</span>
          <span role="columnheader" className="cx-rg-perday" style={{ gridColumn: `span ${days.length}` }}>
            <span className="cx-rg-perday-label">Failed runs per day, all tasks (relative)</span>
            <span className="cx-rg-bars">{days.map((d, i) => (
              <span key={d} className={`b2-rg-bar${partialLast && i === last ? " partial" : ""}`} title={`${d}: ${fmtInt(perDay[i] || 0)}`}>
                <span style={{ height: `${(100 * (perDay[i] || 0)) / max}%` }} />
              </span>
            ))}</span>
          </span>
          <span role="columnheader" className="cx-num">Failed</span><span role="columnheader" className="cx-num">Slow</span><span role="columnheader" className="cx-rg-err">Last error</span>
        </div>
        {rows.map((r) => (
          <div key={r.key} className={`cx-rg-row${r.onClick ? " clickable" : ""}`} role="row" onClick={r.onClick}>
            <span className="cx-rg-name" role="cell">{r.onClick
              ? <button type="button" className="cx-rank-link" onClick={(e) => { e.stopPropagation(); r.onClick!(); }}><NameId name={r.name} id={r.id} /></button>
              : <NameId name={r.name} id={r.id} />}</span>
            <span role="cell"><HealthBadge health={r.health} /></span>
            {r.cells.map((c, i) => (
              <span key={i} role="cell" className="cx-rg-cellwrap"><span className={`b2-rg-cell c-${c}${partialLast && i === last ? " partial" : ""}`}
                title={`${days[i] || ""}: ${RUN_WORD[c]}${partialLast && i === last ? " (today, partial)" : ""}`} /></span>
            ))}
            <span role="cell" className="cx-num cx-strong">{r.failed}</span>
            <span role="cell" className="cx-num">{r.slow}</span>
            <span role="cell" className="cx-rg-err">{r.lastError}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/** A legend of run-cell states, each a 12px square and a word. */
export function CxRunLegend() {
  const states: [RunCell, string][] = [["failed", "Failed"], ["ok", "OK"], ["slow", "Slow"], ["skipped", "Skipped"], ["none", "No run"]];
  return (
    <div className="cx-legend" aria-hidden="true">
      {states.map(([c, w]) => <span key={c}><span className={`cx-legend-sq b2-rg-cell c-${c}`} />{w}</span>)}
    </div>
  );
}

/** A dotted object name: DB.SCHEMA. muted on its own line, the object in ink, then " (id)" muted. */
export function CxObjName({ full, id }: { full: string; id?: string | number | null }) {
  const s = String(full ?? "");
  const cut = s.lastIndexOf(".");
  const pre = cut > 0 ? s.slice(0, cut + 1) : "";
  const obj = cut > 0 ? s.slice(cut + 1) : s;
  const showId = id !== null && id !== undefined && id !== "" && !s.includes(`(${id})`);
  return (
    <span className="cx-obj" title={`${s}${showId ? ` (${id})` : ""}`}>
      {/* Break at the dots first, so a narrow column wraps between parts. */}
      {pre && <span className="cx-obj-pre">{pre.split(".").filter(Boolean).map((x, i) => <React.Fragment key={i}>{x}.<wbr /></React.Fragment>)}</span>}
      <span className="cx-obj-name">{obj}{showId && <span className="cx-muted">{` (${id})`}</span>}</span>
    </span>
  );
}

const DOT_WORD: Record<string, string> = { CRITICAL: "Critical", WARN: "Warning", OK: "OK", NOT_ASSESSED: "Not assessed" };
const DOT_CLASS: Record<string, string> = { CRITICAL: "crit", WARN: "warn", OK: "ok", NOT_ASSESSED: "na" };

/** A status dot; the word is the accessible name. */
export function CxDot({ status }: { status?: string | null }) {
  const k = String(status || "").toUpperCase();
  if (!DOT_CLASS[k]) return <span className="cx-dot" aria-hidden="true" />;
  return <span className={`cx-dot ${DOT_CLASS[k]}`} role="img" aria-label={DOT_WORD[k]} title={DOT_WORD[k]} />;
}

/** The status words present in `statuses`, in severity order, as a dot legend. */
export function CxDotLegend({ statuses, words }: { statuses: (string | null | undefined)[]; words?: Record<string, string> }) {
  const have = new Set(statuses.map((s) => String(s || "").toUpperCase()));
  const keys = ["CRITICAL", "WARN", "OK", "NOT_ASSESSED"].filter((k) => have.has(k));
  if (keys.length < 2) return null;
  return <div className="cx-legend" aria-hidden="true">{keys.map((k) => <span key={k}><span className={`cx-dot ${DOT_CLASS[k]}`} />{(words && words[k]) || DOT_WORD[k]}</span>)}</div>;
}

export interface CxBarRow {
  key: string;
  /** The full dotted name; DB.SCHEMA. is shown muted above the object. */
  name: string;
  id?: string | number | null;
  value: number;
  status?: string | null;
  strong?: React.ReactNode;
  rest?: React.ReactNode;
  onClick?: (() => void) | null;
}

/** Ranked rows on fixed columns: dot | name (DB.SCHEMA muted above) | bar | value; first `n`, then "Show all". */
export function CxBarRows({ rows, max, n = 8, ariaLabel, legend = true }: {
  rows: CxBarRow[]; max?: number; n?: number; ariaLabel?: string; legend?: boolean;
}) {
  const [all, setAll] = React.useState(false);
  if (!rows.length) return null;
  const top = max ?? Math.max(1, ...rows.map((r) => r.value));
  const shown = all ? rows : rows.slice(0, n);
  return (
    <div>
      {legend && <CxDotLegend statuses={rows.map((r) => r.status)} />}
      <div className="cx-bars" role="list" aria-label={ariaLabel}>
        {shown.map((r) => (
          <div key={r.key} className="cx-bars-row" role="listitem">
            <CxDot status={r.status} />
            {r.onClick ? <button type="button" className="cx-rank-link" onClick={r.onClick}><CxObjName full={r.name} id={r.id} /></button> : <CxObjName full={r.name} id={r.id} />}
            <span className="cx-bars-track" aria-hidden="true"><span className="cx-bars-fill" style={{ width: `${Math.max(0, Math.min(100, (100 * r.value) / (top || 1)))}%` }} /></span>
            <span className="cx-bars-val">{r.strong != null && <b>{r.strong}</b>}{r.rest != null && <span className="cx-muted">{r.rest}</span>}</span>
          </div>
        ))}
      </div>
      {rows.length > n && <div className="cx-foot"><button type="button" className="cx-linkbtn" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show ${fmtInt(rows.length - n)} more`}</button></div>}
    </div>
  );
}

export interface CxDumbRow { key: string; name: string; id?: string | number | null; before: number; after: number; strong?: React.ReactNode; rest?: React.ReactNode; onClick?: (() => void) | null }

/** Before → after per row on one shared axis: hollow dot then filled dot; the axis carries its unit. */
export function CxDumbbell({ rows, n = 8, tick, axisLabel, beforeLabel, afterLabel, ariaLabel }: {
  rows: CxDumbRow[]; n?: number; tick: (v: number) => string; axisLabel: string; beforeLabel: string; afterLabel: string; ariaLabel?: string;
}) {
  const [all, setAll] = React.useState(false);
  if (!rows.length) return null;
  const max = Math.max(1, ...rows.map((r) => Math.max(r.before, r.after)));
  const x = (v: number) => `${Math.max(0, Math.min(100, (100 * v) / max))}%`;
  const shown = all ? rows : rows.slice(0, n);
  return (
    <div>
      <div className="cx-legend" aria-hidden="true">
        <span><span className="cx-db-dot before" />{beforeLabel}</span><span><span className="cx-db-dot after" />{afterLabel}</span>
      </div>
      <div className="cx-dumb" role="list" aria-label={ariaLabel}>
        {shown.map((r) => {
          const lo = Math.min(r.before, r.after), hi = Math.max(r.before, r.after);
          return (
            <div key={r.key} className="cx-dumb-row" role="listitem">
              {r.onClick ? <button type="button" className="cx-rank-link" onClick={r.onClick}><CxObjName full={r.name} id={r.id} /></button> : <CxObjName full={r.name} id={r.id} />}
              <span className="cx-db-track" aria-hidden="true">
                <span className="cx-db-span" style={{ left: x(lo), width: `calc(${x(hi)} - ${x(lo)})` }} />
                <span className="cx-db-dot before" style={{ left: x(r.before) }} />
                <span className="cx-db-dot after" style={{ left: x(r.after) }} />
              </span>
              <span className="cx-bars-val">{r.strong != null && <b>{r.strong}</b>}{r.rest != null && <span className="cx-muted">{r.rest}</span>}</span>
            </div>
          );
        })}
        <div className="cx-dumb-row cx-dumb-axis" aria-hidden="true">
          <span className="cx-muted">{axisLabel}</span>
          <span className="cx-db-axis"><span style={{ left: "0%" }}>{tick(0)}</span><span style={{ left: "50%" }}>{tick(max / 2)}</span><span style={{ left: "100%" }}>{tick(max)}</span></span>
          <span />
        </div>
      </div>
      {rows.length > n && <div className="cx-foot"><button type="button" className="cx-linkbtn" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show ${fmtInt(rows.length - n)} more`}</button></div>}
    </div>
  );
}

/** A check with no chart to draw: a dashed one-line strip with the title and the reason. */
export function CxMissing({ title, reason, onOpen }: { title: React.ReactNode; reason: React.ReactNode; onOpen?: (() => void) | null }) {
  return (
    <div className="cx-missing">
      <span className="cx-missing-title">{title}</span>
      <span className="cx-missing-why">{reason}</span>
      {onOpen && <button type="button" className="cx-linkbtn" onClick={onOpen}>{"Open check →"}</button>}
    </div>
  );
}

export interface CxCol { label: string; num?: boolean; width?: string }
export interface CxTableRow { key: string; cells: React.ReactNode[]; status?: string | null; onClick?: (() => void) | null }

/** The standard table: 11px uppercase header, 12px row padding, full-row dividers, numbers right-aligned.
 *  A leading status dot when rows carry a status; scrolls inside its own box on a phone. */
export function CxTable({ cols, rows, n, ariaLabel, foot }: { cols: CxCol[]; rows: CxTableRow[]; n?: number; ariaLabel?: string; foot?: React.ReactNode }) {
  const [all, setAll] = React.useState(false);
  const dots = rows.some((r) => r.status);
  const shown = n && !all ? rows.slice(0, n) : rows;
  return (
    <div>
      <div className="cx-table-box">
        <table className="cx-table" aria-label={ariaLabel}>
          <thead><tr>{dots && <th aria-hidden="true" className="cx-td-dot" />}{cols.map((c) => <th key={c.label} className={c.num ? "cx-num" : undefined} style={c.width ? { width: c.width } : undefined}>{c.label}</th>)}</tr></thead>
          <tbody>
            {shown.map((r) => (
              <tr key={r.key} className={r.onClick ? "clickable" : undefined} onClick={r.onClick || undefined}>
                {dots && <td className="cx-td-dot"><CxDot status={r.status} /></td>}
                {r.cells.map((c, i) => <td key={i} className={cols[i] && cols[i].num ? "cx-num" : undefined}>{c}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {(foot || (n && rows.length > n)) && (
        <div className="cx-foot"><span>{foot}</span>
          {n && rows.length > n ? <button type="button" className="cx-linkbtn" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show ${fmtInt(rows.length - n)} more`}</button> : null}
        </div>
      )}
    </div>
  );
}

/** An inline bar for a table cell, scaled to `max`, with its value after it. */
export function CxCellBar({ value, max, text }: { value: number; max: number; text: React.ReactNode }) {
  return (
    <span className="cx-cellbar">
      <span className="cx-bars-track" aria-hidden="true"><span className="cx-bars-fill" style={{ width: `${Math.max(0, Math.min(100, (100 * value) / (max || 1)))}%` }} /></span>
      <b>{text}</b>
    </span>
  );
}

/** A bar for a table cell in two tones: the whole light, the `part` of it dark, scaled to `max`. */
export function CxTwoBar({ part, whole, max }: { part: number; whole: number; max: number }) {
  const w = (v: number) => `${Math.max(0, Math.min(100, (100 * v) / (max || 1)))}%`;
  return (
    <span className="cx-twobar" aria-hidden="true">
      <span className="cx-twobar-whole" style={{ width: w(whole) }}><span className="cx-twobar-part" style={{ width: whole ? `${(100 * part) / whole}%` : 0 }} /></span>
    </span>
  );
}

/** A status word chip: Critical / Warning tinted, anything else neutral. */
export function CxChip({ status, children }: { status?: string | null; children?: React.ReactNode }) {
  const k = String(status || "").toUpperCase();
  return <span className={`cx-chip ${DOT_CLASS[k] || ""}`}>{children}</span>;
}

/** A schedule in words: "30 MINUTE" → "Every 30 minutes"; cron text stays out of the UI. */
export function scheduleText(v: any): string {
  const s = String(v ?? "").trim();
  if (!s) return "No schedule";
  if (/^USING\s+CRON/i.test(s)) return "On a cron schedule";
  const m = s.match(/^(\d+)\s*(SECOND|MINUTE|HOUR|DAY)S?$/i) || s.match(/^(\d+)\s*([smhd])$/i);
  if (!m) return s;
  const n = Number(m[1]);
  const unit = ({ s: "second", m: "minute", h: "hour", d: "day" } as Record<string, string>)[m[2].toLowerCase()] || m[2].toLowerCase();
  if (unit === "minute" && n % 60 === 0) return n === 60 ? "Every hour" : `Every ${n / 60} hours`;
  return n === 1 ? `Every ${unit}` : `Every ${n} ${unit}s`;
}

export interface CxTrackRow {
  key: string; name: string; id?: string | number | null; status?: string | null;
  /** The bar from `from` to `to`, both 0–100 along the track. */
  from: number; to: number; color?: string;
  strong?: React.ReactNode; rest?: React.ReactNode; onClick?: (() => void) | null;
}

/** Rows on one shared track with a drawn reference line (1× target, Today) and labelled ticks. */
export function CxTrackRows({ rows, line, ticks, n = 10, ariaLabel, legend }: {
  rows: CxTrackRow[]; line: { at: number; label: string }; ticks: { at: number; label: string }[]; n?: number; ariaLabel?: string; legend?: React.ReactNode;
}) {
  const [all, setAll] = React.useState(false);
  if (!rows.length) return null;
  const shown = all ? rows : rows.slice(0, n);
  return (
    <div>
      {legend}
      <div className="cx-bars cx-track" role="list" aria-label={ariaLabel}>
        <div className="cx-bars-row cx-track-head" aria-hidden="true">
          <span /><span />
          <span className="cx-track-axis"><span className="cx-track-linelabel" style={{ left: `${line.at}%` }}>{line.label}</span></span>
          <span />
        </div>
        {shown.map((r) => (
          <div key={r.key} className="cx-bars-row" role="listitem">
            <CxDot status={r.status} />
            {r.onClick ? <button type="button" className="cx-rank-link" onClick={r.onClick}><CxObjName full={r.name} id={r.id} /></button> : <CxObjName full={r.name} id={r.id} />}
            <span className="cx-track-lane" aria-hidden="true">
              <span className="cx-track-line" style={{ left: `${line.at}%` }} />
              <span className="cx-track-bar" style={{ left: `${Math.min(r.from, r.to)}%`, width: `${Math.max(0.6, Math.abs(r.to - r.from))}%`, background: r.color || "var(--c1)" }} />
            </span>
            <span className="cx-bars-val">{r.strong != null && <b>{r.strong}</b>}{r.rest != null && <span className="cx-muted">{r.rest}</span>}</span>
          </div>
        ))}
        <div className="cx-bars-row cx-track-ticks" aria-hidden="true">
          <span /><span />
          <span className="cx-track-axis">{ticks.map((t) => <span key={t.label} style={{ left: `${t.at}%` }}>{t.label}</span>)}</span>
          <span />
        </div>
      </div>
      {rows.length > n && <div className="cx-foot"><button type="button" className="cx-linkbtn" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show ${fmtInt(rows.length - n)} more`}</button></div>}
    </div>
  );
}

export interface CxAreaRow { key: string; label: string; crit: number; warn: number; ok: number; ref: number; na: number; onClick?: (() => void) | null }
const AREA_PARTS: { key: "crit" | "warn" | "ok" | "ref"; head: string; color: string }[] = [
  { key: "crit", head: "Crit", color: "var(--st-crit)" }, { key: "warn", head: "Warn", color: "var(--st-warn)" },
  { key: "ok", head: "OK", color: "var(--st-ok)" }, { key: "ref", head: "Ref", color: "var(--c-other)" },
];

/** Checks by area: a bar split by outcome (length = checks in the area), then the counts in fixed columns. */
export function CxAreaCounts({ rows, ariaLabel }: { rows: CxAreaRow[]; ariaLabel?: string }) {
  if (!rows.length) return null;
  const parts = AREA_PARTS.filter((p) => rows.some((r) => r[p.key] > 0) || p.key === "crit" || p.key === "warn");
  const all = (r: CxAreaRow) => r.crit + r.warn + r.ok + r.ref;
  const max = Math.max(1, ...rows.map(all));
  const cols = { gridTemplateColumns: `minmax(110px, 160px) minmax(80px, 1fr) repeat(${parts.length + 1}, 52px)` };
  return (
    <div className="cx-table-box">
      <div className="cx-areas" role="table" aria-label={ariaLabel}>
        <div className="cx-areas-row cx-areas-head" style={cols} role="row">
          <span role="columnheader">Area</span><span role="columnheader" />
          {parts.map((p) => <span key={p.key} role="columnheader" className={`cx-num${p.key === "crit" ? " cx-crit" : ""}`}>{p.head}</span>)}
          <span role="columnheader" className="cx-num">All</span>
        </div>
        {rows.map((r) => (
          <button type="button" key={r.key} className="cx-areas-row" style={cols} role="row" onClick={r.onClick || undefined}>
            <span role="cell" className="cx-areas-label">{r.label}</span>
            <span role="cell" className="cx-areas-bar" aria-hidden="true">
              <span className="cx-areas-fill" style={{ width: `${(100 * all(r)) / max}%` }}>
                {parts.map((p) => (r[p.key] > 0 ? <span key={p.key} style={{ flexGrow: r[p.key], background: p.color }} /> : null))}
              </span>
            </span>
            {parts.map((p) => <span key={p.key} role="cell" className={`cx-num${p.key === "crit" && r.crit ? " cx-crit" : ""}`}>{r[p.key] ? fmtInt(r[p.key]) : "–"}</span>)}
            <span role="cell" className="cx-num" title={r.na ? `${fmtInt(r.na)} more did not run` : undefined}>{fmtInt(all(r))}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

/** One small-multiple panel: daily columns on their own scale, 3 y ticks, first / middle / last day. */
export function CxMiniCols({ title, sub, days, values, color, partialLast, selected, onDay, dayLabel }: {
  title: React.ReactNode; sub?: React.ReactNode; days: string[]; values: number[]; color: string; partialLast?: boolean;
  selected?: string | null; onDay?: (d: string) => void; dayLabel: (d: string) => string;
}) {
  const max = Math.max(1, ...values);
  const top = max <= 4 ? max : Math.ceil(max / 2) * 2;
  const W = 240, H = 96, L = 22, B = 16, T = 8;
  const bw = (W - L) / Math.max(1, days.length);
  const y = (v: number) => T + (H - B - T) * (1 - v / top);
  const ticks = [0, top / 2, top].map((t) => (Number.isInteger(t) ? t : Math.round(t * 10) / 10));
  const mid = Math.floor((days.length - 1) / 2);
  return (
    <div className="cx-mini">
      <div className="cx-mini-title"><span className="cx-legend-sq" style={{ background: color }} />{title}</div>
      {sub && <div className="cx-mini-sub">{sub}</div>}
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" height={H} role="img" aria-label={typeof title === "string" ? `${title} per day` : undefined}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={L} x2={W} y1={y(t)} y2={y(t)} stroke="var(--border)" strokeWidth="1" />
            <text x={L - 4} y={y(t) + 3} textAnchor="end" fontSize="9" fill="var(--text-3)">{t}</text>
          </g>
        ))}
        {days.map((d, i) => {
          const v = values[i] || 0;
          const last = partialLast && i === days.length - 1;
          return (
            <rect key={d} x={L + i * bw + bw * 0.2} y={y(v)} width={Math.max(1, bw * 0.6)} height={(H - B) - y(v)}
              fill={color} opacity={selected && selected !== d ? 0.35 : last ? 0.55 : 1} style={onDay ? { cursor: "pointer" } : undefined}
              onClick={onDay ? () => onDay(d) : undefined}><title>{`${dayLabel(d)}: ${v}${last ? " (today, partial)" : ""}`}</title></rect>
          );
        })}
        {[0, mid, days.length - 1].filter((i, k, a) => days[i] && a.indexOf(i) === k).map((i, k) => (
          <text key={i} x={L + i * bw + bw / 2} y={H - 3} textAnchor={k === 0 ? "start" : k === 2 ? "end" : "middle"} fontSize="9" fill="var(--text-3)">{dayLabel(days[i])}</text>
        ))}
      </svg>
    </div>
  );
}

/** A legend of coloured squares with words. */
export function CxSwatches({ items }: { items: [string, string][] }) {
  return <div className="cx-legend" aria-hidden="true">{items.map(([c, w]) => <span key={w}><span className="cx-legend-sq" style={{ background: c }} />{w}</span>)}</div>;
}

/** A secondary strip: one card split into cells, for the figures past the first three KPIs. */
export function CxStrip({ children }: { children?: React.ReactNode }) {
  return <div className="cx-strip summary-tile-row compact">{children}</div>;
}
