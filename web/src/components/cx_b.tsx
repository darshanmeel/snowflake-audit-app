// web/src/components/cx_b.tsx -- small look helpers for the Waste, Warehouses and Serverless pages:
// a status dot + word, ranked bars (label above, or name | bar | value on fixed columns), one
// standard table with optional groups, and a dashed one-line empty strip. Nothing here fetches.
import React from "react";
import { STATUS_WORD } from "./primitives";
import { niceTicks, useChartWidth } from "./charts";

const BAND_KIND: Record<string, string> = { CRITICAL: "critical", WARN: "warn", OK: "ok", NOT_ASSESSED: "not_assessed", ERROR: "not_assessed", RANKED: "reference" };

/** A band or pill kind as a dot and its word: "● Critical". */
export function SevWord({ band, kind }: { band?: string | null; kind?: string | null }) {
  const k = kind || BAND_KIND[String(band || "").toUpperCase()] || "reference";
  return <span className={`cx-sev cx-sev-${k}`}><span className="cx-sev-dot" aria-hidden="true" />{STATUS_WORD[k] || k}</span>;
}

/** "WH_ETL (1001)" as the name in ink and the id muted; any other label as it is. */
export function NameIdText({ text }: { text: string }) {
  const m = /^(.*\S)\s+(\([^()]+\))$/.exec(text);
  if (!m) return <>{text}</>;
  return <>{m[1]}<span className="cx-id"> {m[2]}</span></>;
}

/** "DB.SCHEMA.TABLE (id)": the path muted, the object in ink, the id muted; wraps at the dots. */
export function FqnText({ text }: { text: string }) {
  const m = /^(.*?)(\s+\([^()]+\))?$/.exec(text);
  const body = m ? m[1] : text, id = m && m[2] ? m[2] : "";
  const cut = body.lastIndexOf(".");
  const path = cut > 0 ? body.slice(0, cut + 1) : "";
  const obj = cut > 0 ? body.slice(cut + 1) : body;
  return (
    <span className="cx-fqn">
      {path && <span className="cx-id">{path.split(".").filter(Boolean).map((s, i) => <React.Fragment key={i}>{s}.<wbr /></React.Fragment>)}</span>}
      {obj}{id && <span className="cx-id">{id}</span>}
    </span>
  );
}

export interface CxBarRow {
  key: string;
  label: React.ReactNode;
  value: number;
  valueText: React.ReactNode;
  /** Muted text after the value ("· 50%"). */
  aside?: React.ReactNode;
  /** An aggregate row ("Other checks (5)"): grey, and drawn last by the caller. */
  other?: boolean;
  color?: string;
  onClick?: (() => void) | null;
}

const pctW = (v: number, max: number) => (max > 0 ? Math.max(v > 0 ? 1 : 0, Math.min(100, (v / max) * 100)) : 0);

/** Ranked rows with the label above an 8px bar; bars scale to the largest shown. */
export function LabelBars({ rows, max, ariaLabel }: { rows: CxBarRow[]; max?: number; ariaLabel?: string }) {
  const top = max ?? Math.max(0, ...rows.map((r) => r.value));
  return (
    <div className="cx-lbars" role="list" aria-label={ariaLabel}>
      {rows.map((r) => {
        const body = (
          <>
            <span className="cx-lbar-head">
              <span className="cx-lbar-label">{r.label}</span>
              <span className="cx-lbar-val"><b>{r.valueText}</b>{r.aside ? <span className="cx-muted">{r.aside}</span> : null}</span>
            </span>
            <span className="cx-track" aria-hidden="true"><span className="cx-fill" style={{ width: `${pctW(r.value, top)}%`, background: r.color || (r.other ? "var(--c-other)" : undefined) }} /></span>
          </>
        );
        return r.onClick
          ? <button type="button" role="listitem" key={r.key} className="cx-lbar cx-click" onClick={r.onClick}>{body}</button>
          : <div role="listitem" key={r.key} className="cx-lbar">{body}</div>;
      })}
    </div>
  );
}

/** Ranked rows on fixed columns, name | bar | value, so every track starts at the same x. */
export function NameBars({ rows, max, ariaLabel, nameCol = "minmax(150px, 1.1fr)", valueCol = "72px" }: {
  rows: CxBarRow[]; max?: number; ariaLabel?: string; nameCol?: string; valueCol?: string;
}) {
  const top = max ?? Math.max(0, ...rows.map((r) => r.value));
  const style = { gridTemplateColumns: `${nameCol} minmax(0, 1fr) ${valueCol}` } as React.CSSProperties;
  return (
    <div className="cx-nbars" role="list" aria-label={ariaLabel}>
      {rows.map((r) => {
        const body = (
          <>
            <span className="cx-nbar-name">{r.label}</span>
            <span className="cx-nbar-cell" aria-hidden="true"><span className="cx-nbar-fill" style={{ width: `${pctW(r.value, top)}%`, background: r.color || (r.other ? "var(--c-other)" : undefined) }} /></span>
            <span className="cx-nbar-val">{r.valueText}{r.aside ? <span className="cx-muted">{r.aside}</span> : null}</span>
          </>
        );
        return r.onClick
          ? <button type="button" role="listitem" key={r.key} className="cx-nbar cx-click" style={style} onClick={r.onClick}>{body}</button>
          : <div role="listitem" key={r.key} className="cx-nbar" style={style}>{body}</div>;
      })}
    </div>
  );
}

export interface CxCol { label: React.ReactNode; num?: boolean; width: string }
export interface CxRow { key: string; cells: React.ReactNode[]; title?: string; onOpen?: (() => void) | null; open?: boolean; body?: React.ReactNode }
export interface CxGroup { key: string; head: React.ReactNode; total?: React.ReactNode; rows: CxRow[] }

/** The standard table: 11px uppercase header, 12px row padding, full-width dividers, numbers right.
 * Wide tables scroll inside their own box. `groups` adds a small uppercase head over each set.
 * `phone` keeps only those columns on a phone, at the widths given, so the key figures stay in view. */
export function CxTable({ cols, rows, groups, aria, minWidth = 720, foot, phone }: {
  cols: CxCol[]; rows?: CxRow[]; groups?: CxGroup[]; aria: string; minWidth?: number; foot?: React.ReactNode;
  phone?: { cols: number[]; widths: string };
}) {
  const style = { ["--cx-cols" as any]: cols.map((c) => c.width).join(" "), ["--cx-ph-cols" as any]: phone ? phone.widths : undefined } as React.CSSProperties;
  const hide = (i: number) => (phone && !phone.cols.includes(i) ? " cx-ph-hide" : "");
  const cell = (c: React.ReactNode, i: number) => (
    <span key={i} role="cell" className={`${cols[i] && cols[i].num ? "cx-td cx-num" : "cx-td"}${hide(i)}`}>{c}</span>
  );
  const row = (r: CxRow) => (
    <React.Fragment key={r.key}>
      {r.onOpen
        ? <button type="button" role="row" className={`cx-tr cx-click${r.open ? " open" : ""}`} style={style} title={r.title} aria-expanded={r.body !== undefined ? !!r.open : undefined} onClick={r.onOpen}>{r.cells.map(cell)}</button>
        : <div role="row" className="cx-tr" style={style} title={r.title}>{r.cells.map(cell)}</div>}
      {r.open && r.body ? <div className="cx-tr-body">{r.body}</div> : null}
    </React.Fragment>
  );
  return (
    <div className="cx-table-wrap">
      <div className={`cx-table${phone ? " cx-has-ph" : ""}`} role="table" aria-label={aria} style={{ minWidth }}>
        <div className="cx-tr cx-th" role="row" style={style}>
          {cols.map((c, i) => <span key={i} role="columnheader" className={`${c.num ? "cx-num" : ""}${hide(i)}`}>{c.label}</span>)}
        </div>
        {groups
          ? groups.map((g) => (
            <div role="rowgroup" key={g.key}>
              <div className="cx-group-head"><span>{g.head}</span>{g.total != null && <span className="cx-group-total">{g.total}</span>}</div>
              {g.rows.map(row)}
            </div>
          ))
          : (rows || []).map(row)}
      </div>
      {foot && <div className="cx-table-foot">{foot}</div>}
    </div>
  );
}

/** The first `n` rows, then "Show N more" under them. */
export function ShowRows({ n, total, children }: { n: number; total: number; noun?: string; children: (k: number) => React.ReactNode }) {
  const [all, setAll] = React.useState(false);
  return (
    <>
      {children(all ? total : n)}
      {total > n && <button type="button" className="cx-show-all" onClick={() => setAll(!all)}>{all ? `Show the first ${n}` : `Show ${(total - n).toLocaleString("en-US")} more`}</button>}
    </>
  );
}

/** An inline bar inside a table cell, scaled to `max`. */
export function CellBar({ value, max, color }: { value: number; max: number; color?: string }) {
  return <span className="cx-track cx-cellbar" aria-hidden="true"><span className="cx-fill" style={{ width: `${pctW(value, max)}%`, background: color }} /></span>;
}

/** A 24-hour line: y ticks on round steps, x ticks every 3 h, the peak marked, units on the axis. */
export function HourLine({ values, yLabel, xLabel = "hour of day, UTC", valueFmt, ariaLabel }: {
  values: number[]; yLabel: string; xLabel?: string; valueFmt: (v: number) => string; ariaLabel: string;
}) {
  const [ref, W] = useChartWidth(760);
  const H = 240, pad = { l: 56, r: 16, t: 28, b: 40 };
  const max = Math.max(1, ...values);
  const ticks = niceTicks(0, max, 5);
  const top = Math.max(max, ticks[ticks.length - 1]);
  const iw = Math.max(10, W - pad.l - pad.r), ih = H - pad.t - pad.b;
  const x = (h: number) => pad.l + (h / 23) * iw;
  const y = (v: number) => pad.t + ih - (v / top) * ih;
  const peak = values.reduce((b, v, h) => (v > values[b] ? h : b), 0);
  const hh = (h: number) => `${String(h).padStart(2, "0")}:00`;
  const d = values.map((v, h) => `${h ? "L" : "M"}${x(h).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  return (
    <div ref={ref} className="cx-hourline">
      <div className="cx-axis-label">{yLabel}</div>
      <svg width={W} height={H} role="img" aria-label={ariaLabel}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={pad.l} x2={W - pad.r} y1={y(t)} y2={y(t)} stroke="var(--grid)" />
            <text x={pad.l - 8} y={y(t) + 4} textAnchor="end" className="cx-tick">{valueFmt(t)}</text>
          </g>
        ))}
        {[0, 3, 6, 9, 12, 15, 18, 21].map((h) => (
          <text key={h} x={x(h)} y={H - pad.b + 18} textAnchor="middle" className="cx-tick">{hh(h)}</text>
        ))}
        <path d={d} fill="none" stroke="var(--c1)" strokeWidth={2} />
        {values.map((v, h) => <circle key={h} cx={x(h)} cy={y(v)} r={6} fill="transparent"><title>{`${hh(h)} UTC: ${valueFmt(v)}`}</title></circle>)}
        <circle cx={x(peak)} cy={y(values[peak])} r={4} fill="var(--c1)" />
        <text x={x(peak)} y={y(values[peak]) - 9} textAnchor={peak > 20 ? "end" : peak < 2 ? "start" : "middle"} className="cx-tick cx-tick-strong">{`${hh(peak)} · ${valueFmt(values[peak])}`}</text>
      </svg>
      <div className="cx-axis-label cx-axis-x">{xLabel}</div>
    </div>
  );
}

/** A dashed one-line strip for a chart with no data: the title, then the reason. */
export function EmptyStrip({ title, children }: { title?: React.ReactNode; children?: React.ReactNode }) {
  return <div className="cx-empty">{title && <b>{title}</b>}{title && children ? " · " : null}{children}</div>;
}
