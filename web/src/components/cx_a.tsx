// web/src/components/cx_a.tsx -- small look helpers for the FinOps, CTO and CFO money screens: ranked
// rows (one colour, scaled to the largest shown), the "ties to the bill" line, the account-wide ran
// line inside a checks card, calendar months as rows, and the dashed one-line empty strip.
import React from "react";
import { fmtInt, fmtMoney, fmtMoneyShort } from "../format";
import { fmtChangePct } from "./hooks";
import { bandOf, ranCountsOf } from "./primitives";
import { _dayMonth, _utcDay } from "./overview_tile";
import type { Finding, GoToFn, Meta } from "../types";

/** "1 run", "3 runs": a count with its noun, never "(s)". */
export function plural(n: number, one: string, many?: string) {
  return `${fmtInt(n)} ${n === 1 ? one : (many || `${one}s`)}`;
}

/** One ranked row. `tone` picks the bar: series blue, orange (a rise), teal (a fall), grey (a rest), hatched (untagged). */
export interface CxBarItem {
  key: string;
  label: React.ReactNode;
  value: number;
  valueText: React.ReactNode;
  share?: string | null;
  tone?: "c1" | "c2" | "c3" | "other" | "hatch";
  strong?: boolean;
  onClick?: (() => void) | null;
  title?: string;
}

// Ranked bars, either the label above each bar ("above") or a fixed grid label | bar | value, so every
// track starts and ends at the same x. Bars scale to the largest shown, not to 100%.
export function CxBars({ items, layout = "grid", ariaLabel, labelWidth }: { items: CxBarItem[]; layout?: "grid" | "above"; ariaLabel: string; labelWidth?: number }) {
  const max = Math.max(0, ...items.map((it) => Math.abs(it.value)));
  const pct = (v: number) => (max > 0 ? Math.max(1.5, (100 * Math.abs(v)) / max) : 0);
  return (
    <div className={`cx-bars cx-bars-${layout}`} role="list" aria-label={ariaLabel}
      style={labelWidth ? ({ "--cx-label-w": `${labelWidth}px` } as React.CSSProperties) : undefined}>
      {items.map((it) => {
        const val = <span className="cx-bar-val">{it.valueText}{it.share && <span className="cx-bar-share">{` · ${it.share}`}</span>}</span>;
        const bar = <span className="cx-bar-track" aria-hidden="true"><span className={`cx-bar-fill t-${it.tone || "c1"}`} style={{ width: `${pct(it.value)}%` }} /></span>;
        const body = layout === "above"
          ? <><span className="cx-bar-top"><span className="cx-bar-label">{it.label}</span>{val}</span>{bar}</>
          : <><span className={`cx-bar-label${it.strong ? " strong" : ""}`}>{it.label}</span>{bar}{val}</>;
        return it.onClick
          ? <button type="button" role="listitem" key={it.key} className="cx-bar-row clickable" onClick={it.onClick} title={it.title}>{body}</button>
          : <div role="listitem" key={it.key} className="cx-bar-row" title={it.title}>{body}</div>;
      })}
    </div>
  );
}

/** "Ties to the bill: …" as one line with a tick, or a warning mark when it is off. */
export function TieLine({ tie }: { tie: { tone: string; text: string } | null }) {
  if (!tie) return null;
  const ok = tie.tone === "ok";
  return (
    <div className={`cx-tie${ok ? "" : " off"}`}>
      {ok
        ? <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 7.4l2.6 2.6L11 4.4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" /></svg>
        : <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M7 1.8l5.5 10H1.5z" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round" /></svg>}
      <span>{tie.text}</span>
    </div>
  );
}

/** "273 of 279 checks ran · ● 159 critical · ● 87 warning · …": the one ran count, for the foot of a checks card. */
export function RanLine({ meta, byId, goTo }: { meta: Meta | null; byId: Record<string, Finding>; goTo: GoToFn }) {
  const ran = ranCountsOf(meta);
  const all = Object.values(byId);
  // Same rule as ChecksRanStrip: a check whose every row is not assessed did not run.
  const didNotRun = (f: Finding) => ["NOT_ASSESSED", "ERROR"].includes(bandOf(f)) || (!!f.not_assessed && f.not_assessed.code === "all_rows_not_assessed");
  const n = (bands: string[]) => all.filter((f) => !didNotRun(f) && bands.includes(bandOf(f))).length;
  const notRun = all.filter(didNotRun).length;
  const dot = (cls: string, text: string) => <span><span className={`cx-sev-dot ${cls}`} aria-hidden="true" />{text}</span>;
  return (
    <span className="cx-ran">
      <span>{ran ? `${fmtInt(ran.assessed)} of ${fmtInt(ran.total)} ${ran.unit} ran` : "…"}</span>
      {all.length > 0 && <>
        {dot("d-crit", `${fmtInt(n(["CRITICAL"]))} critical`)}
        {dot("d-warn", `${fmtInt(n(["WARN"]))} warning`)}
        {dot("d-ok", `${fmtInt(n(["OK"]))} ok`)}
        {dot("d-ref", `${fmtInt(n(["RANKED", "INVENTORY"]))} reference`)}
      </>}
      <button type="button" className="ck-link" onClick={() => goTo({ tab: "coverage" })}>{notRun > 0 ? `${fmtInt(notRun)} not assessed →` : "Coverage & gaps →"}</button>
    </span>
  );
}

/** A dashed one-line strip for a chart or figure that is not there: the title, why, and the fix line if any. */
export function NaStrip({ title, reason, fix }: { title?: React.ReactNode; reason: React.ReactNode; fix?: string | null }) {
  return (
    <div className="cx-na-strip">
      {title && <span className="cx-na-title">{title}</span>}
      <span className="cx-na-reason">{reason}</span>
      {fix && <code className="cov-grant">{fix}</code>}
    </div>
  );
}

/** One row of a RankedTable. */
export interface RankedRow { key: string; label: React.ReactNode; value: number; valueText: React.ReactNode; extra?: React.ReactNode; extraTone?: string; tone?: CxBarItem["tone"]; marker?: number | null; onClick?: (() => void) | null }

// A ranked table with fixed columns: name | bar | value | extra (a change, a multiple). Bars scale to the
// largest shown; `marker` draws a reference tick (the account's own figure) at the same x on every row.
export function RankedTable({ rows, head, ariaLabel, max: maxIn }: { rows: RankedRow[]; head: [string, string, string, string?]; ariaLabel: string; max?: number }) {
  const max = maxIn || Math.max(0, ...rows.map((r) => Math.abs(r.value), ...rows.map((r) => r.marker || 0)));
  const pct = (v: number) => (max > 0 ? Math.min(100, (100 * Math.abs(v)) / max) : 0);
  const hasExtra = head[3] != null;
  return (
    <div className={`cx-rt${hasExtra ? "" : " no-extra"}`} role="table" aria-label={ariaLabel}>
      <div className="cx-rt-tr cx-rt-th" role="row">
        <span role="columnheader">{head[0]}</span><span role="columnheader">{head[1]}</span>
        <span role="columnheader" className="num">{head[2]}</span>{hasExtra && <span role="columnheader" className="num">{head[3]}</span>}
      </div>
      {rows.map((r) => {
        const cells = (
          <>
            <span role="cell" className="cx-rt-name">{r.label}</span>
            <span role="cell" className="cx-rt-track" aria-hidden="true">
              <span className={`cx-bar-fill t-${r.tone || "c1"}`} style={{ width: `${Math.max(1, pct(r.value))}%` }} />
              {r.marker != null && <span className="cx-rt-marker" style={{ left: `${pct(r.marker)}%` }} />}
            </span>
            <span role="cell" className="num cx-rt-val">{r.valueText}</span>
            {hasExtra && <span role="cell" className={`num cx-rt-extra${r.extraTone ? ` ${r.extraTone}` : ""}`}>{r.extra}</span>}
          </>
        );
        return r.onClick
          ? <button type="button" role="row" key={r.key} className="cx-rt-tr clickable" onClick={r.onClick}>{cells}</button>
          : <div role="row" key={r.key} className="cx-rt-tr">{cells}</div>;
      })}
    </div>
  );
}

/** One panel of SmallMultiples. */
export interface MultiSeries { key: string; label: React.ReactNode; color: string; values: number[]; meta?: React.ReactNode; onClick?: (() => void) | null }

// One small line chart per series, each on its own scale (or one shared scale), so a series that dwarfs
// the rest no longer flattens them. Each panel names its top, mid and zero on the axis with `per`.
export function SmallMultiples({ series, days, fmt, per, partialLast }: {
  series: MultiSeries[]; days: string[]; fmt: (v: number) => string; per: string; partialLast?: boolean;
}) {
  const [shared, setShared] = React.useState(false);
  const sharedMax = Math.max(0, ...series.flatMap((s) => s.values));
  const w = 220, h = 70;
  const dayLabel = (d: string) => { const t = _utcDay(d); return t != null ? _dayMonth(t) : d; };
  return (
    <div className="cx-sm">
      {series.length > 1 && (
        <div className="cx-seg" role="group" aria-label="Scale">
          <button type="button" className={shared ? "" : "on"} aria-pressed={!shared} onClick={() => setShared(false)}>Own scale</button>
          <button type="button" className={shared ? "on" : ""} aria-pressed={shared} onClick={() => setShared(true)}>Shared scale</button>
        </div>
      )}
      <div className="cx-sm-grid">
        {series.map((s) => {
          const max = (shared ? sharedMax : Math.max(0, ...s.values)) || 1;
          const step = s.values.length > 1 ? w / (s.values.length - 1) : w;
          const pts = s.values.map((v, i) => `${(i * step).toFixed(1)},${(h - (h * v) / max).toFixed(1)}`).join(" ");
          const Panel = s.onClick ? "button" : "div";
          return (
            <Panel key={s.key} className={`cx-sm-panel${s.onClick ? " clickable" : ""}`} {...(s.onClick ? { type: "button" as const, onClick: s.onClick } : {})}>
              <span className="cx-sm-name"><span className="cx-sm-sw" style={{ background: s.color }} aria-hidden="true" />{s.label}</span>
              {s.meta && <span className="cx-sm-meta">{s.meta}</span>}
              <span className="cx-sm-plot">
                <span className="cx-sm-axis" aria-hidden="true"><span>{fmt(max)}</span><span>{fmt(max / 2)}</span><span>0</span></span>
                <svg viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" role="img" aria-label={`${typeof s.label === "string" ? s.label : "Series"}, ${per}`}>
                  <line x1="0" y1={h / 2} x2={w} y2={h / 2} className="cx-sm-grid-line" />
                  <line x1="0" y1={h - 0.5} x2={w} y2={h - 0.5} className="cx-sm-base" />
                  <polyline points={pts} fill="none" stroke={s.color} strokeWidth="1.6" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
                  {partialLast && s.values.length > 1 && <circle cx={w} cy={h - (h * s.values[s.values.length - 1]) / max} r="2.5" fill="var(--surface)" stroke={s.color} vectorEffect="non-scaling-stroke" />}
                </svg>
              </span>
              <span className="cx-sm-x"><span>{days.length ? dayLabel(days[0]) : ""}</span><span>{per}</span><span>{days.length ? dayLabel(days[days.length - 1]) : ""}</span></span>
            </Panel>
          );
        })}
      </div>
    </div>
  );
}

/** A styled single-choice picker (a button and a list), in place of a native <select>. */
export function CxPicker({ label, options, value, onChange, mono }: {
  label: string; options: { value: string; label: string }[]; value: string | null; onChange: (v: string) => void; mono?: boolean;
}) {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef<HTMLDivElement | null>(null);
  React.useEffect(() => {
    if (!open) return undefined;
    const onDoc = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onEsc);
    return () => { document.removeEventListener("mousedown", onDoc); document.removeEventListener("keydown", onEsc); };
  }, [open]);
  const cur = options.find((o) => o.value === value);
  return (
    <div className="cx-pick" ref={ref}>
      <button type="button" className="cx-pick-btn" aria-haspopup="listbox" aria-expanded={open} aria-label={label} disabled={!options.length} onClick={() => setOpen(!open)}>
        <span className={mono ? "cx-pick-mono" : undefined}>{cur ? cur.label : "…"}</span><span aria-hidden="true">▾</span>
      </button>
      {open && (
        <div className="cx-pick-list" role="listbox" aria-label={label}>
          {options.map((o) => (
            <button type="button" role="option" aria-selected={o.value === value} key={o.value} className={`${o.value === value ? "on" : ""}${mono ? "" : " sans"}`}
              onClick={() => { onChange(o.value); setOpen(false); }}>{o.label}</button>
          ))}
        </div>
      )}
    </div>
  );
}

/** One part of a SplitBar. */
export interface SplitPart { key: string; label: string; value: number; sub?: string; color?: string; hatch?: boolean }

// A 100% share bar for at most 4-5 parts, each labelled under its own segment (no legend to match).
export function SplitBar({ parts, ariaLabel }: { parts: SplitPart[]; ariaLabel: string }) {
  const shown = parts.filter((p) => p.value > 0);
  const total = shown.reduce((s, p) => s + p.value, 0);
  if (!total) return null;
  const pct = (v: number) => (100 * v) / total;
  return (
    <div className="cx-split" role="list" aria-label={ariaLabel}>
      {shown.map((p) => (
        <div role="listitem" key={p.key} className="cx-split-col" style={{ flexGrow: p.value, flexBasis: 0 }}>
          <span className={`cx-split-seg${p.hatch ? " hatch" : ""}`} style={p.hatch ? undefined : { background: p.color || "var(--c1)" }}>
            {pct(p.value) >= 8 ? `${Math.round(pct(p.value))}%` : ""}
          </span>
          <span className="cx-split-label">{p.label}</span>
          {p.sub && <span className="cx-split-sub">{p.sub}</span>}
        </div>
      ))}
    </div>
  );
}

/** One total in a ReconChain. */
export interface ChainStep { key: string; label: string; value: number | null | undefined }

// Metered → billed → split as one compact line, with the % gap between each pair.
export function ReconChain({ steps }: { steps: ChainStep[] }) {
  const ok = (v: number | null | undefined): v is number => v != null && Number.isFinite(v);
  return (
    <div className="cx-chain" role="list" aria-label="Metered, billed and split totals">
      {steps.map((st, i) => {
        const prev = i > 0 ? steps[i - 1] : null;
        const g = prev && ok(prev.value) && ok(st.value) && prev.value !== 0 ? ((st.value - prev.value) / Math.abs(prev.value)) * 100 : null;
        return (
          <React.Fragment key={st.key}>
            {prev && <span className="cx-chain-gap" aria-hidden="true">{`→ ${g == null ? "–" : `${g >= 0 ? "+" : "−"}${Math.abs(g) < 0.05 ? "0" : Math.abs(g).toFixed(1).replace(/\.0$/, "")}%`} →`}</span>}
            <span role="listitem" className="cx-chain-step">{st.label} <b>{ok(st.value) ? fmtMoney(st.value, 0) : "–"}</b></span>
          </React.Fragment>
        );
      })}
    </div>
  );
}

// The cost-center split as ranked rows: untagged first and hatched, then the top values, the rest as "Other (n)".
export function costCenterBars(parts: { name: string; value: number; untagged: boolean }[], total: number, top = 7): CxBarItem[] {
  const share = (v: number) => (total > 0 ? `${((100 * v) / total).toFixed((100 * v) / total < 10 ? 1 : 0)}%` : null);
  const untagged = parts.filter((p) => p.untagged);
  const tagged = parts.filter((p) => !p.untagged && p.value > 0).sort((a, b) => b.value - a.value);
  // "Other (1)" hides a name for nothing: one left over is shown as itself.
  const cut = tagged.length === top + 1 ? top + 1 : top;
  const shown = tagged.slice(0, cut);
  const rest = tagged.slice(cut);
  const items: CxBarItem[] = untagged.filter((p) => p.value > 0).map((p) => ({ key: "__untagged__", label: p.name, value: p.value, valueText: fmtMoney(p.value, 0), share: share(p.value), tone: "hatch" as const, strong: true }));
  shown.forEach((p) => items.push({ key: p.name, label: p.name, value: p.value, valueText: fmtMoney(p.value, 0), share: share(p.value) }));
  if (rest.length) {
    const v = rest.reduce((s, p) => s + p.value, 0);
    items.push({ key: "__other__", label: `Other (${fmtInt(rest.length)})`, value: v, valueText: fmtMoney(v, 0), share: share(v), tone: "other" });
  }
  return items;
}

export interface CalMonth { month: string; label: string; shortLabel: string; total: number; partial: boolean; startsMid: boolean }

// Calendar months as rows (month | bar | $ | change): 12+ month labels in a half-width card never
// collide. The month in progress is its spend so far, with a dashed segment out to the forecast.
export function CalMonthRows({ months, projected }: { months: CalMonth[]; projected?: number | null }) {
  const max = Math.max(1, ...months.map((m) => m.total), projected || 0);
  return (
    <div className="cx-cal" role="table" aria-label="Spend by calendar month">
      {months.map((m, i) => {
        const prev = i > 0 ? months[i - 1] : null;
        // A month whose history starts mid-month is not a base for a change.
        const chg = !m.partial && !m.startsMid && prev && !prev.partial && !prev.startsMid && prev.total > 0 ? ((m.total - prev.total) / prev.total) * 100 : null;
        const fc = m.partial && projected != null && projected > m.total ? projected : null;
        return (
          <div role="row" className={`cx-cal-row${m.partial ? " partial" : ""}`} key={m.month}
            title={`${m.label}: ${fmtMoney(m.total, 0)}${m.partial ? ` so far${fc != null ? `, forecast ${fmtMoney(fc, 0)}` : ""}` : ""}`}>
            <span role="cell" className="cx-cal-m">{m.label}</span>
            <span role="cell" className="cx-cal-track" aria-hidden="true">
              {fc != null && <span className="cx-cal-fc" style={{ width: `${(100 * fc) / max}%` }} />}
              <span className="cx-cal-fill" style={{ width: `${Math.max(0.5, (100 * m.total) / max)}%` }} />
            </span>
            <span role="cell" className="cx-cal-v">{m.partial ? `${fmtMoneyShort(m.total)} so far` : fmtMoneyShort(m.total)}</span>
            <span role="cell" className={`cx-cal-c${chg != null && chg >= 15 ? " up" : ""}`}>
              {chg != null ? fmtChangePct(chg) : m.partial ? (fc != null ? `→ ${fmtMoneyShort(fc)}` : "partial") : m.startsMid ? "from mid-month" : ""}
            </span>
          </div>
        );
      })}
    </div>
  );
}
