// web/src/components/cx_c.tsx -- the redesign's building blocks for the AI & apps, Sharing & org and
// Storage pages: ranked bars on fixed columns, label-above-bar lists, one table style, a secondary
// KPI strip, the dashed empty strip and a card that turns into that strip when its check has no rows.
import React from "react";
import { fmtDayShort, fmtInt, fmtMoney } from "../format";
import { ChartCard } from "./primitives";
import type { Chk } from "./area_ai_storage";
import type { Row } from "../types";

// ═══════════════════════ money in its own currency ═══════════════════════

const CUR_SYM: Record<string, string> = { USD: "$", EUR: "€", GBP: "£", JPY: "¥" };

/** "$1,234" for USD, "€1,826" for EUR, "CHF 1,234" for a currency with no symbol; no code, "(invoice currency)". */
export function cxMoney(code: any, v: number): string {
  const s = fmtMoney(v, 0);
  if (code === null || code === undefined || code === "") return `${s.replace("$", "")} (invoice currency)`;
  const c = String(code).toUpperCase();
  if (c === "USD") return s;
  return s.replace("$", CUR_SYM[c] || `${c} `);
}

/** One currency for a set of invoice rows (never added across currencies). `tag` names a non-USD code once: " (EUR)". */
export function cxCurrency(rows: Row[]): { ok: boolean; code: string | null; fmt: (v: number) => string; tag: string } {
  const cur = [...new Set(rows.map((r) => r.currency).filter((c) => c !== null && c !== undefined && c !== "").map((c) => String(c).toUpperCase()))];
  if (cur.length > 1) return { ok: false, code: null, fmt: (v) => fmtInt(v), tag: "" };
  const code = cur[0] || null;
  return { ok: true, code, fmt: (v) => (code ? cxMoney(code, v) : fmtMoney(v, 0)), tag: code && code !== "USD" ? ` (${code})` : "" };
}

// ═══════════════════════ names and status ═══════════════════════

const STATUS_WORD: Record<string, string> = { CRITICAL: "Critical", WARN: "Warning", OK: "OK", NOT_ASSESSED: "Not assessed" };
const statusKey = (s: any) => {
  const k = String(s || "").toUpperCase();
  return k === "CRITICAL" || k === "WARN" || k === "NOT_ASSESSED" ? k : "OK";
};
export const statusWordOf = (s: any) => STATUS_WORD[statusKey(s)];

/** The 8px status dot (Critical red, Warning amber, OK grey, Not assessed dashed). */
export function CxDot({ status }: { status: any }) {
  return <span className={`cx-dot st-${statusKey(status).toLowerCase()}`} aria-hidden="true" />;
}

/** Dot + word, for a table's status column. */
export function CxStatus({ status }: { status: any }) {
  return <span className="cx-status" title={statusWordOf(status)}><CxDot status={status} /><span className="cx-status-word">{statusWordOf(status)}</span></span>;
}

/** A full object name: "DB.SCHEMA." muted, the object in ink, wrapping at the dots. Only dotted
 * identifier paths are split, so "llama3.1-70b" stays one word. */
export function CxName({ name }: { name: React.ReactNode }) {
  if (typeof name !== "string") return <span className="cx-name">{name}</span>;
  const m = /^(.*?)(\s\([^()]*\))?$/.exec(name);
  const body = m ? m[1] : name;
  const id = m && m[2] ? m[2] : "";
  const i = body.lastIndexOf(".");
  if (i <= 0 || !/^[A-Za-z_$"\[][\w$"\[\]]*(\.[A-Za-z_$"\[][\w$"\[\]]*)+$/.test(body)) return <span className="cx-name">{name}</span>;
  return (
    <span className="cx-name">
      <span className="cx-name-pre">{body.slice(0, i + 1).replace(/\./g, ".​")}</span>{body.slice(i + 1)}{id && <span className="cx-name-id">{id}</span>}
    </span>
  );
}

/** "Critical · Warning · OK" for the statuses present, under a list. */
export function CxLegend({ statuses, extra }: { statuses: any[]; extra?: React.ReactNode }) {
  const present = ["CRITICAL", "WARN", "OK", "NOT_ASSESSED"].filter((k) => statuses.some((s) => statusKey(s) === k));
  if (present.length < 2 && !extra) return null;
  return (
    <div className="cx-legend">
      {present.length >= 2 && present.map((k) => <span key={k} className="cx-legend-item"><CxDot status={k} />{STATUS_WORD[k]}</span>)}
      {extra}
    </div>
  );
}

function useShowAll(total: number, n: number) {
  const [all, setAll] = React.useState(false);
  const shown = all ? total : Math.min(total, n);
  const more = total > n
    ? <button type="button" className="cx-more" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show ${fmtInt(total - n)} more`}</button>
    : null;
  return { shown, more };
}

// ═══════════════════════ ranked bars on fixed columns ═══════════════════════

export interface CxBarRow {
  key: string;
  name: React.ReactNode;
  value: number;
  status?: any;
  /** The figures after the bar, one per value column, right-aligned. */
  cells: React.ReactNode[];
  /** Bar colour; default blue. Status never colours the bar. */
  color?: string;
  hatched?: boolean;
  onOpen?: (() => void) | null;
}

/** `name | bar | value…` on fixed columns, so every track starts and ends at the same x. Bars scale
 * to the largest shown unless `max` is given; the tail past `n` sits behind "Show N more". */
export function CxGridBars({ rows, cols, n = 8, max, aria, nameWidth = "minmax(170px, 1.4fr)", legend = true, foot }: {
  rows: CxBarRow[]; cols: { label: string; width?: string }[]; n?: number; max?: number; aria: string;
  nameWidth?: string; legend?: boolean; foot?: React.ReactNode;
}) {
  const { shown, more } = useShowAll(rows.length, n);
  if (!rows.length) return null;
  const list = rows.slice(0, shown);
  const scale = max && max > 0 ? max : Math.max(...rows.map((r) => r.value), 0) || 1;
  const hasStatus = rows.some((r) => r.status !== undefined);
  const style = {
    ["--cx-cols" as any]: [nameWidth, "minmax(60px, 1fr)", ...cols.map((c) => c.width || "auto")].join(" "),
    ["--cx-k" as any]: cols.length,
  } as React.CSSProperties;
  return (
    <div className="cx-gbars" role="table" aria-label={aria} style={style}>
      {cols.some((c) => c.label) && (
        <div className="cx-gb-row cx-gb-head" role="row">
          <span role="columnheader">{""}</span><span className="cx-gb-barhead" />
          {cols.map((c, i) => <span key={i} role="columnheader" className="cx-num">{c.label}</span>)}
        </div>
      )}
      {list.map((r) => {
        const inner = (
          <>
            <span role="cell" className="cx-gb-name">{hasStatus && <CxDot status={r.status} />}<CxName name={r.name} /></span>
            <span role="cell" className="cx-track">
              <span className={`cx-fill${r.hatched ? " cx-hatch" : ""}`} style={{ width: `${Math.max(r.value > 0 ? 1 : 0, Math.min(100, (r.value / scale) * 100))}%`, background: r.hatched ? undefined : (r.color || "var(--c1)") }} />
            </span>
            {r.cells.map((c, i) => <span key={i} role="cell" className={`cx-num${i === 0 ? " cx-strong" : ""}`}>{c}</span>)}
          </>
        );
        return r.onOpen
          ? <button type="button" role="row" key={r.key} className="cx-gb-row cx-click" onClick={r.onOpen}>{inner}</button>
          : <div role="row" key={r.key} className="cx-gb-row">{inner}</div>;
      })}
      {(more || foot || (legend && hasStatus)) && (
        <div className="cx-foot">{legend && hasStatus && <CxLegend statuses={rows.map((r) => r.status)} />}{foot}{more}</div>
      )}
    </div>
  );
}

/** Label-above-bar rows: a full name and its figure on one line, the bar under it. For long names in a half-width card. */
export function CxBars({ rows, n = 8, max, aria, legend = true, foot }: {
  rows: CxBarRow[]; n?: number; max?: number; aria: string; legend?: boolean; foot?: React.ReactNode;
}) {
  const { shown, more } = useShowAll(rows.length, n);
  if (!rows.length) return null;
  const scale = max && max > 0 ? max : Math.max(...rows.map((r) => r.value), 0) || 1;
  const hasStatus = rows.some((r) => r.status !== undefined);
  return (
    <div className="cx-bars" role="list" aria-label={aria}>
      {rows.slice(0, shown).map((r) => {
        const inner = (
          <>
            <span className="cx-bar-top">
              <span className="cx-bar-name">{hasStatus && <CxDot status={r.status} />}<CxName name={r.name} /></span>
              <span className="cx-bar-val">{r.cells.map((c, i) => <span key={i} className={i === 0 ? "cx-strong" : "cx-sub"}>{i > 0 ? " · " : ""}{c}</span>)}</span>
            </span>
            <span className="cx-track cx-track-thin">
              <span className={`cx-fill${r.hatched ? " cx-hatch" : ""}`} style={{ width: `${Math.max(r.value > 0 ? 1 : 0, Math.min(100, (r.value / scale) * 100))}%`, background: r.hatched ? undefined : (r.color || "var(--c1)") }} />
            </span>
          </>
        );
        return r.onOpen
          ? <button type="button" role="listitem" key={r.key} className="cx-bar cx-click" onClick={r.onOpen}>{inner}</button>
          : <div role="listitem" key={r.key} className="cx-bar">{inner}</div>;
      })}
      {(more || foot || (legend && hasStatus)) && (
        <div className="cx-foot">{legend && hasStatus && <CxLegend statuses={rows.map((r) => r.status)} />}{foot}{more}</div>
      )}
    </div>
  );
}

// ═══════════════════════ one table style ═══════════════════════

export interface CxCol { label: string; num?: boolean; width?: string }
export interface CxRow { key: string; cells: React.ReactNode[]; status?: any; onOpen?: (() => void) | null }

/** Header 11px uppercase · rows 12px padded with a full divider · text left, numbers right · status
 * as dot + word in its own first column · scrolls inside its own box on a phone. */
export function CxTable({ cols, rows, n = 10, aria, empty, minWidth = 560, foot }: {
  cols: CxCol[]; rows: CxRow[]; n?: number; aria: string; empty?: React.ReactNode; minWidth?: number; foot?: React.ReactNode;
}) {
  const { shown, more } = useShowAll(rows.length, n);
  if (!rows.length) return <div className="cx-empty-line">{empty || "Nothing to list."}</div>;
  const hasStatus = rows.some((r) => r.status !== undefined);
  const all = hasStatus ? [{ label: "Status", width: "auto" } as CxCol, ...cols] : cols;
  const style = {
    ["--cx-cols" as any]: all.map((c, i) => c.width || (i === (hasStatus ? 1 : 0) ? "minmax(160px, 2fr)" : "minmax(72px, 1fr)")).join(" "),
    ["--cx-minw" as any]: `${minWidth}px`,
  } as React.CSSProperties;
  const cellsOf = (r: CxRow) => (hasStatus ? [<CxStatus key="s" status={r.status} />, ...r.cells] : r.cells);
  return (
    <div className="cx-table-box">
      <div className="cx-table" role="table" aria-label={aria} style={style}>
        <div className="cx-tr cx-th" role="row">
          {all.map((c, i) => <span key={i} role="columnheader" className={c.num ? "cx-num" : hasStatus && i === 0 ? "cx-th-status" : undefined}>{c.label}</span>)}
        </div>
        {rows.slice(0, shown).map((r) => {
          const cells = cellsOf(r).map((c, i) => <span key={i} role="cell" className={all[i] && all[i].num ? "cx-num" : "cx-txt"}>{c}</span>);
          return r.onOpen
            ? <button type="button" role="row" key={r.key} className="cx-tr cx-click" onClick={r.onOpen}>{cells}</button>
            : <div role="row" key={r.key} className="cx-tr">{cells}</div>;
        })}
      </div>
      {(more || foot) && <div className="cx-foot">{foot}{more}</div>}
    </div>
  );
}

// ═══════════════════════ KPI strip and notes ═══════════════════════

export interface CxStripCell {
  key: string;
  label: string;
  /** Only Critical / Warning / Not assessed earn a chip. */
  status?: "critical" | "warn" | "not_assessed" | null;
  value: React.ReactNode | null;
  unit?: React.ReactNode;
  lines?: React.ReactNode[];
  /** Why the value is missing; the cell reads "–". */
  missing?: React.ReactNode;
  loading?: boolean;
  onOpen?: (() => void) | null;
}

const CHIP: Record<string, string> = { critical: "Critical", warn: "Warning", not_assessed: "Not assessed" };

/** The secondary strip under the primary KPI cards: one card split in cells, a 28px number each. */
export function CxStrip({ cells, aria }: { cells: CxStripCell[]; aria: string }) {
  return (
    <div className="cx-strip" role="list" aria-label={aria}>
      {cells.map((c) => {
        const missing = !c.loading && (c.value === null || c.value === undefined || c.value === "");
        return (
          <div key={c.key} role="listitem" className={`cx-cell${missing ? " is-missing" : ""}`}>
            <div className="cx-cell-head">
              <span className="cx-eyebrow">{c.label}</span>
              {c.status && <span className={`cx-chip chip-${c.status}`}>{CHIP[c.status]}</span>}
            </div>
            <div className="cx-cell-value">{c.loading ? "…" : missing ? "–" : c.value}{!c.loading && !missing && c.unit && <span className="cx-cell-unit">{c.unit}</span>}</div>
            {!c.loading && (missing ? (c.missing ? [c.missing] : []) : (c.lines || [])).filter(Boolean).map((l, i) => <div key={i} className="cx-cell-line">{l}</div>)}
            {c.onOpen && <button type="button" className="cx-cell-open" onClick={c.onOpen}>Open check →</button>}
          </div>
        );
      })}
    </div>
  );
}

/** The one line under a KPI row that says the figures are different kinds, never added. */
export function CxKindsNote({ children }: { children: React.ReactNode }) {
  return <p className="cx-kinds-note">{children}</p>;
}

// ═══════════════════════ columns per day, one outlier capped ═══════════════════════

/** A tick step of 1, 2 or 5 × 10^n that gives about three ticks up to `max`. */
function niceStep(max: number): number {
  const raw = max / 3;
  const p = 10 ** Math.floor(Math.log10(raw || 1));
  const m = raw / p;
  return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 5 ? 5 : 10) * p;
}

/** Stacked columns per day for up to three kinds (the rest is "Other"). A day more than three times the
 * next one is cut to fit, marked, and labelled with its real value, so the smaller days stay readable. */
export function CxDayStack({ rows, days, valueFmt, unit, word = "", aria, onOpen }: {
  rows: { day: string; kind: string; value: number }[]; days: string[];
  valueFmt: (v: number) => string; unit: string; aria: string; onOpen?: (() => void) | null;
  /** The unit after a figure in the outlier's label and note ("GB"). */
  word?: string;
}) {
  const withWord = (v: number) => `${valueFmt(v)}${word ? ` ${word}` : ""}`;
  const byKind = new Map<string, number>();
  rows.forEach((r) => byKind.set(r.kind, (byKind.get(r.kind) || 0) + r.value));
  const kinds = [...byKind.entries()].sort((a, b) => b[1] - a[1]).map(([k]) => k);
  const top = kinds.slice(0, 3);
  const COLORS = ["var(--c1)", "var(--c2)", "var(--c3)"];
  const kindOf = (k: string) => (top.includes(k) ? k : "Other");
  const legend = [...top, ...(kinds.length > 3 ? ["Other"] : [])];
  const colorOf = (k: string) => (k === "Other" ? "var(--c-other)" : COLORS[top.indexOf(k)]);
  const perDay = days.map((d) => {
    const m = new Map<string, number>();
    rows.filter((r) => r.day === d).forEach((r) => m.set(kindOf(r.kind), (m.get(kindOf(r.kind)) || 0) + r.value));
    return { day: d, parts: legend.map((k) => ({ k, v: m.get(k) || 0 })).filter((x) => x.v > 0), total: [...m.values()].reduce((a, v) => a + v, 0) };
  });
  const sorted = perDay.map((x) => x.total).sort((a, b) => b - a);
  const capped = sorted[1] > 0 && sorted[0] > 3 * sorted[1];
  const step = niceStep(capped ? sorted[1] * 1.3 : sorted[0] || 1);
  const scale = Math.max(step * Math.ceil((capped ? sorted[1] * 1.3 : sorted[0] || 1) / step), step);
  const ticks = [];
  for (let v = 0; v <= scale + 1e-9; v += step) ticks.push(v);
  const every = Math.max(1, Math.ceil(days.length / 8));
  const big = capped ? perDay.find((x) => x.total === sorted[0]) : null;
  return (
    <div className="cx-days" role="img" aria-label={aria}>
      {legend.length > 1 && (
        <div className="cx-legend cx-days-legend">
          {legend.map((k) => <span key={k} className="cx-legend-item"><span className="cx-sw" style={{ background: colorOf(k) }} />{k}</span>)}
        </div>
      )}
      <div className="cx-days-unit">{unit}</div>
      <div className="cx-days-plot">
        <div className="cx-days-axis" aria-hidden="true">
          {[...ticks].reverse().map((v) => <span key={v}>{valueFmt(v)}</span>)}
        </div>
        <div className="cx-days-cols">
          {ticks.map((v) => <span key={v} className="cx-days-grid" style={{ bottom: `${(v / scale) * 100}%` }} />)}
          {perDay.map((x, i) => {
            const over = x.total > scale;
            const col = (
              <span className="cx-days-col">
                <span className="cx-days-stack" style={{ height: `${Math.min(100, (x.total / scale) * 100)}%` }}>
                  {x.parts.map((pt) => <span key={pt.k} style={{ flexGrow: pt.v, background: colorOf(pt.k) }} />)}
                  {over && <span className="cx-days-break" aria-hidden="true" />}
                </span>
                {over && <span className="cx-days-flag">{`≈ ${withWord(x.total)}`}<br />cut to fit</span>}
                <span className={`cx-days-x${(i / every) % 2 === 1 && i !== perDay.length - 1 ? " cx-minor" : ""}`}>{i % every === 0 || i === perDay.length - 1 ? fmtDayShort(x.day) : ""}</span>
              </span>
            );
            return onOpen
              ? <button type="button" key={x.day} className="cx-days-btn" title={`${fmtDayShort(x.day)}: ${withWord(x.total)}`} onClick={onOpen}>{col}</button>
              : <span key={x.day} className="cx-days-btn" title={`${fmtDayShort(x.day)}: ${withWord(x.total)}`}>{col}</span>;
          })}
        </div>
      </div>
      {big && (
        <div className="metric-note">{`${fmtDayShort(big.day)} holds ${withWord(big.total)}${big.parts.length === 1 ? `, all of it ${big.parts[0].k}` : ""}; its bar is cut so the smaller days stay readable.`}</div>
      )}
    </div>
  );
}

// ═══════════════════════ empty strip and the card around a check ═══════════════════════

/** A dashed one-line strip: the title, one reason, and the fix line when there is one. No controls. */
export function CxEmpty({ title, reason, fix }: { title: React.ReactNode; reason: React.ReactNode; fix?: React.ReactNode }) {
  return (
    <div className="cx-empty" role="note">
      <span className="cx-empty-title">{title}</span>
      <span className="cx-empty-why">{reason}</span>
      {fix && <code className="cx-empty-fix">{fix}</code>}
    </div>
  );
}

/** A chart card on one check. "…" while loading; a check with no rows (or a body of null) becomes
 * the dashed strip with its reason, never a card with an empty chart. */
export function CxSlot({ c, title, subtitle, emptyReason, children }: {
  c: Chk; title: string; subtitle?: React.ReactNode; emptyReason?: string;
  children: (rows: Row[], c: Chk) => React.ReactNode;
}) {
  if (c.loading) return <ChartCard title={title} subtitle={subtitle} takeaway={null}><div className="chart-note-oneline">…</div></ChartCard>;
  if (c.why || !c.rows) return <CxEmpty title={title} reason={c.empty ? c.why : `– ${c.why}`} />;
  const body = children(c.rows, c);
  if (body === null || body === undefined || body === false) return emptyReason ? <CxEmpty title={title} reason={emptyReason} /> : null;
  return <ChartCard title={title} subtitle={subtitle} onOpenCheck={c.open} takeaway={null}>{body}</ChartCard>;
}

/** Two cards side by side that size to their own content (top-aligned, never stretched). */
export function CxRow2({ children }: { children?: React.ReactNode }) {
  return <div className="cx-row2">{children}</div>;
}
