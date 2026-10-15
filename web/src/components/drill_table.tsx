// web/src/components/drill_table.tsx -- the small drill-down table the shared tabs use under their
// cause cards: a status dot and name (id) first, mono figures after, a row opens the drawer. The
// caller passes formatted cells; nothing here fetches. On a phone only the first two cells show.
import React from "react";
import "../styles/css/p_shared_tabs.css";
import { fmtInt } from "../format";
import { statusBarColor } from "./blocks";

export interface DrillCol { label: React.ReactNode; num?: boolean; width?: string }
export interface DrillRow { key: string; cells: React.ReactNode[]; status?: string | null; onOpen?: (() => void) | null; selected?: boolean; title?: string }

/** Rows under a header; `n` caps what is shown and the rest is counted, never summed. */
export function DrillTable({ cols, rows, n = 10, aria, empty, more }: {
  cols: DrillCol[]; rows: DrillRow[]; n?: number; aria: string; empty?: React.ReactNode; more?: React.ReactNode;
}) {
  if (!rows.length) return <div className="chart-note-oneline">{empty || "Nothing to list."}</div>;
  const style = { ["--dt-cols" as any]: cols.map((c, i) => c.width || (i === 0 ? "minmax(140px, 2fr)" : "minmax(64px, 1fr)")).join(" ") } as React.CSSProperties;
  const shown = rows.slice(0, n);
  const cell = (c: React.ReactNode, i: number, r: DrillRow) => (
    <span key={i} role="cell" className={i === 0 ? "dt-name" : cols[i] && cols[i].num ? "dt-num" : "dt-txt"}>
      {i === 0 && r.status !== undefined && <span className="blk-dot" style={{ background: statusBarColor(r.status) }} aria-hidden="true" />}
      {c}
    </span>
  );
  return (
    <div className="dt-table" role="table" aria-label={aria} style={style}>
      <div className="dt-tr dt-th" role="row">
        {cols.map((c, i) => <span key={i} role="columnheader" className={c.num ? "dt-num" : undefined}>{c.label}</span>)}
      </div>
      {shown.map((r) => r.onOpen
        ? <button type="button" role="row" key={r.key} title={r.title} className={`dt-tr${r.selected ? " selected" : ""}`} aria-pressed={r.selected || undefined} onClick={r.onOpen}>{r.cells.map((c, i) => cell(c, i, r))}</button>
        : <div role="row" key={r.key} title={r.title} className="dt-tr">{r.cells.map((c, i) => cell(c, i, r))}</div>)}
      {(rows.length > shown.length || more) && (
        <div className="blk-more">{rows.length > shown.length ? `+${fmtInt(rows.length - shown.length)} more not shown` : null}{more}</div>
      )}
    </div>
  );
}

/** One bar split in parts against `max` (busy / idle, kept / unallocated); hatched = no owner or unknown. */
export function SplitBar({ parts, max, title }: { parts: { value: number; color?: string; hatched?: boolean }[]; max: number; title?: string }) {
  return (
    <span className="dt-bar" title={title} aria-hidden={title ? undefined : true}>
      {parts.map((pt, i) => (
        <span key={i} className={`dt-bar-fill dt-bar-part${pt.hatched ? " blk-hatch" : ""}`}
          style={{ width: `${max > 0 ? Math.max(0, Math.min(100, (pt.value / max) * 100)) : 0}%`, background: pt.hatched ? undefined : (pt.color || "var(--c1)") }} />
      ))}
    </span>
  );
}

/** A thin neutral bar: `value` of `max`; `hatched` reads as a part nobody can judge. */
export function MiniBar({ value, max, hatched, tone }: { value: number; max: number; hatched?: boolean; tone?: "warn" | "crit" | null }) {
  const w = max > 0 ? Math.max(value > 0 ? 2 : 0, Math.min(100, (value / max) * 100)) : 0;
  return (
    <span className="dt-bar" aria-hidden="true">
      <span className={`dt-bar-fill${hatched ? " blk-hatch" : ""}${tone ? ` tone-${tone}` : ""}`} style={{ width: `${w}%` }} />
    </span>
  );
}
