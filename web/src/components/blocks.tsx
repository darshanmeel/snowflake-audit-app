// web/src/components/blocks.tsx -- the shared building blocks every area page draws an issue with:
// a headline figure, the driver behind it and a way into the rows. Presentation only: callers pass
// already-aggregated numbers. Each block keeps the app's own tokens and card look (c_blocks.css).
//
// Honesty rules carried by every block: a figure that is missing reads "–" with its reason, never 0;
// a count names its unit; a ratio is never folded into "Other"; an untagged/unknown part is hatched.
import React from "react";
import { fmtDayShort, fmtInt, fmtMoney, fmtPct } from "../format";
import { columnEnumLabel } from "./labels";
import { humanizeColumnName } from "./columns";
import { StatusIcon, StatusPill } from "./primitives";
import { Sparkline } from "./blocks_2";
import { ChartFrame, RoundRect, measureTextPx, niceTicks, truncateLeft, useChartWidth } from "./charts";
import { compactTick, rowLabelWidth } from "./charts_more";
import type { Row } from "../types";

// ═══════════════════════ shared helpers ═══════════════════════

/** A row status as the checks write it. */
export type BlockStatus = "CRITICAL" | "WARN" | "OK" | "NOT_ASSESSED" | string | null | undefined;

/** Part over whole as a percentage, or null when either is missing or the whole is not positive. */
export function pctOf(part: number | null | undefined, whole: number | null | undefined): number | null {
  if (part == null || whole == null || !Number.isFinite(part) || !Number.isFinite(whole) || whole <= 0) return null;
  return (part / whole) * 100;
}

/** "42%", "0.4%", "<0.1%": one decimal only under 10%, never a fake 0% for a real part. */
export function fmtShare(pct: number | null | undefined): string {
  if (pct == null || !Number.isFinite(pct)) return "–";
  if (pct > 0 && pct < 0.1) return "<0.1%";
  return fmtPct(pct, pct < 10 && pct % 1 !== 0 ? 1 : 0);
}

/** Bar colour by status: Critical red, Warning amber, OK grey, Not assessed lavender. */
export function statusBarColor(status: BlockStatus): string {
  switch (String(status || "").toUpperCase()) {
    case "CRITICAL": return "var(--st-crit)";
    case "WARN": return "var(--st-warn)";
    case "NOT_ASSESSED": return "var(--st-na)";
    default: return "var(--c-other)";
  }
}
const STATUS_LEGEND: [string, string][] = [["CRITICAL", "Critical"], ["WARN", "Warning"], ["OK", "OK"], ["NOT_ASSESSED", "Not assessed"]];
function statusKey(status: BlockStatus): string {
  const s = String(status || "").toUpperCase();
  return s === "CRITICAL" || s === "WARN" || s === "NOT_ASSESSED" ? s : "OK";
}
function pillKind(status: BlockStatus): string {
  return ({ CRITICAL: "critical", WARN: "warn", OK: "ok", NOT_ASSESSED: "not_assessed" } as Record<string, string>)[statusKey(status)];
}

// ═══════════════════════ 1. IssueTile ═══════════════════════

/** A small change chip on an IssueTile. `tone` colours it (bad = red, good = green), not the arrow. */
export interface IssueTrend { text: string; direction: "up" | "down" | "flat"; tone?: "bad" | "good" | "neutral" }

/** IssueTile props. The big number is the issue (a % or the flagged $), never the population total. */
export interface IssueTileProps {
  label: React.ReactNode;
  /** The headline figure, already formatted ("42%", "$1,764"). null (and not loading) reads "–". */
  headline: React.ReactNode | null | undefined;
  /** Small unit after the headline ("of spend", "/mo"). */
  unit?: React.ReactNode;
  /** Why the headline is missing: "not in this export", "needs Enterprise edition", "the role can't see it". */
  missingReason?: React.ReactNode;
  /** Flagged count and its base: "21 of 113 users". Base null reads "21 users flagged". */
  flagged?: number | null;
  population?: number | null;
  /** Plural noun of the population ("users", "warehouses"). */
  noun?: string;
  trend?: IssueTrend | null;
  /** The top cause, one line ("idle 82% · WH_ETL (1003) leads"). */
  cause?: React.ReactNode;
  status?: "critical" | "warn" | "ok" | "not_assessed" | "neutral";
  /** Open the rows behind the tile. A link (href) or a handler, or both. */
  href?: string;
  onOpen?: () => void;
  openLabel?: string;
  loading?: boolean;
  /** The mono base line; overrides the flagged/population text. */
  base?: React.ReactNode;
  /** Overrides the top-right status pill (a kind chip); null hides it. */
  pill?: React.ReactNode;
  /** A daily series drawn as a 40px sparkline; `sparkAnomalies` are point indexes marked in warn. */
  spark?: (number | null)[] | null;
  sparkAnomalies?: number[];
  /** A small visual under the base line: a share bar, a month-to-date bar. */
  chart?: React.ReactNode;
}

/** Eyebrow + pill · the issue as one number + unit · mono base line · one line · footer link. */
export function IssueTile({
  label, headline, unit, missingReason, flagged, population, noun, trend, cause, status = "neutral",
  href, onOpen, openLabel = "Open →", loading = false, base, pill, spark, sparkAnomalies, chart,
}: IssueTileProps) {
  const missing = !loading && (headline === null || headline === undefined || headline === "");
  const clickable = !!onOpen;
  const go = (e: React.SyntheticEvent) => {
    if (!onOpen) return;
    e.preventDefault();
    onOpen();
  };
  let popText: string | null = null;
  if (!loading && flagged != null && Number.isFinite(flagged)) {
    popText = population != null && Number.isFinite(population)
      ? `${fmtInt(flagged)} of ${fmtInt(Math.max(population, flagged))}${noun ? ` ${noun}` : ""}`
      : `${fmtInt(flagged)}${noun ? ` ${noun}` : ""} flagged`;
  }
  const baseLine = base !== undefined ? base : popText;
  const tag = pill !== undefined ? pill : status !== "neutral" ? <StatusPill kind={status} /> : null;
  return (
    <div
      className={`summary-tile sev-${status} issue-tile${missing ? " is-missing" : ""}${clickable ? " clickable" : ""}`}
      onClick={clickable ? go : undefined}
      role={clickable ? "button" : undefined}
      tabIndex={clickable ? 0 : undefined}
      onKeyDown={clickable ? (e) => { if (e.key === "Enter" || e.key === " ") go(e); } : undefined}
    >
      <div className="summary-tile-head">
        <div className="summary-tile-label">{label}</div>
        {tag}
      </div>
      <div className="summary-tile-value">
        {loading ? "…" : missing ? "–" : headline}
        {!loading && !missing && unit && <span className="summary-tile-unit">{unit}</span>}
      </div>
      {missing && missingReason && <div className="issue-tile-why">{missingReason}</div>}
      {!missing && !loading && (baseLine || trend) && (
        <div className="issue-tile-facts">
          {baseLine && <span className="summary-tile-base">{baseLine}</span>}
          {trend && (
            <span className={`issue-tile-trend tone-${trend.tone || "neutral"}`}>
              {trend.direction === "up" ? "▲ " : trend.direction === "down" ? "▼ " : ""}{trend.text}
            </span>
          )}
        </div>
      )}
      {chart && !loading && !missing && <div className="issue-tile-chart">{chart}</div>}
      {spark && !loading && !missing && <Sparkline points={spark} anomalies={sparkAnomalies} ariaLabel={typeof label === "string" ? `${label}, by day` : undefined} />}
      {cause && !loading && <div className="issue-tile-cause" title={typeof cause === "string" ? cause : undefined}>{cause}</div>}
      {(href || onOpen) && (
        <div className="summary-tile-link">
          {href
            ? <a className="summary-tile-open" href={href} onClick={(e) => { e.stopPropagation(); if (onOpen) go(e); }}>{openLabel}</a>
            : <span className="summary-tile-open">{openLabel}</span>}
        </div>
      )}
    </div>
  );
}

// ═══════════════════════ 2. ShareBar ═══════════════════════

/** ShareBar props: one part of one whole. */
export interface ShareBarProps {
  value: number | null | undefined;
  total: number | null | undefined;
  /** Optional label shown before the bar. */
  label?: React.ReactNode;
  /** Formats the raw X and Y for the tooltip ("$1,764 of $4,315"). */
  valueFmt?: (v: number) => string;
  /** Plural noun for the tooltip's "X of Y noun". */
  noun?: string;
  status?: BlockStatus;
  color?: string;
  /** Shown instead of a bar when the share cannot be worked out. */
  missingText?: string;
}

/** A light track with the % printed; the raw "X of Y" is in the tooltip. Never folds anything. */
export function ShareBar({ value, total, label, valueFmt, noun, status, color, missingText }: ShareBarProps) {
  const pct = pctOf(value, total);
  const fmt = valueFmt || ((v: number) => fmtInt(v));
  if (pct === null) {
    return (
      <span className="blk-share">
        {label && <span className="blk-share-label">{label}</span>}
        <span className="blk-share-missing">{`– ${missingText || "no base to compare against"}`}</span>
      </span>
    );
  }
  const tip = `${fmt(value as number)} of ${fmt(total as number)}${noun ? ` ${noun}` : ""} (${fmtShare(pct)})`;
  const fill = color || (status ? statusBarColor(status) : "var(--c1)");
  return (
    <span className="blk-share" title={tip}>
      {label && <span className="blk-share-label">{label}</span>}
      <span className="blk-share-track" role="img" aria-label={tip}>
        <span className="blk-share-fill" style={{ width: `${Math.min(100, Math.max(0, pct))}%`, background: fill }} />
      </span>
      <span className="blk-share-pct">{fmtShare(pct)}</span>
    </span>
  );
}

/** One row of a ShareBarList. */
export interface ShareItem { key?: string; name: string; value: number | null; total: number | null; status?: BlockStatus; onClick?: (() => void) | null }

/** Several ShareBars, ranked by %. The tail is counted ("+4 more"), never summed into Other. */
export function ShareBarList({ items, n = 10, sort = "desc", valueFmt, noun, emptyText }: {
  items: ShareItem[] | null | undefined; n?: number; sort?: "desc" | "asc" | "none";
  valueFmt?: (v: number) => string; noun?: string; emptyText?: string;
}) {
  const [ref, W] = useChartWidth(560);
  const list = (items || []).filter((it) => it);
  if (!list.length) return <div ref={ref} className="chart-note-oneline">{emptyText || "Nothing to show."}</div>;
  const withPct = list.map((it) => ({ ...it, pct: pctOf(it.value, it.total) }));
  const sorted = sort === "none" ? withPct : [...withPct].sort((a, b) => {
    const av = a.pct ?? -1, bv = b.pct ?? -1;
    return sort === "asc" ? av - bv : bv - av;
  });
  const shown = sorted.slice(0, n);
  const labelW = rowLabelWidth(W, shown.map((it) => it.name), 110);
  return (
    <div ref={ref} className="blk-share-list">
      {shown.map((it, i) => {
        const body = (
          // Status rides on the 8px dot before the label; the bar stays neutral.
          <ShareBar value={it.value} total={it.total} valueFmt={valueFmt} noun={noun}
            label={<span className="blk-row-label" style={{ width: labelW }} title={it.name}>{it.status !== undefined && <span className="blk-dot" style={{ background: statusBarColor(it.status) }} aria-hidden="true" />}{truncateLeft(it.name, labelW - (it.status !== undefined ? 22 : 8))}</span>} />
        );
        return it.onClick
          ? <button type="button" key={it.key || i} className="blk-row-btn" onClick={it.onClick}>{body}</button>
          : <div key={it.key || i}>{body}</div>;
      })}
      {sorted.length > shown.length && <div className="blk-more">{`+${fmtInt(sorted.length - shown.length)} more not shown`}</div>}
    </div>
  );
}

// ═══════════════════════ 3. StackedShareBar / Pareto ═══════════════════════

/** One part of a StackedShareBar. `unknown` (untagged, no reason, unattributed) is hatched and last. */
export interface ShareSegment { key?: string; label: string; value: number; color?: string; unknown?: boolean; onClick?: (() => void) | null }

/** A 100% bar of additive parts ($, credits, rows) with a hatched unknown part and a legend of %.
 * `pareto` sorts largest first and says how few parts make up most of the whole. Additive parts past
 * `maxSegments` fold into Other; never pass ratios here (use ShareBarList). */
export function StackedShareBar({ segments, valueFmt, pareto = false, maxSegments = 6, totalLabel, height = 22, ariaLabel }: {
  segments: ShareSegment[] | null | undefined; valueFmt?: (v: number) => string; pareto?: boolean;
  maxSegments?: number; totalLabel?: React.ReactNode; height?: number; ariaLabel?: string;
}) {
  const fmt = valueFmt || ((v: number) => fmtInt(v));
  const list = (segments || []).filter((s) => s && Number.isFinite(s.value) && s.value > 0);
  if (!list.length) return <div className="chart-note-oneline">Nothing to show.</div>;
  const unknown = list.filter((s) => s.unknown);
  let known = list.filter((s) => !s.unknown);
  if (pareto) known = [...known].sort((a, b) => b.value - a.value);
  const head = known.slice(0, maxSegments);
  const tail = known.slice(maxSegments);
  const parts: (ShareSegment & { isOther?: boolean })[] = [...head];
  if (tail.length) parts.push({ key: "__other", label: `Other (${fmtInt(tail.length)})`, value: tail.reduce((s, x) => s + x.value, 0), color: "var(--c-other)", isOther: true });
  parts.push(...unknown);
  const total = parts.reduce((s, x) => s + x.value, 0);
  const palette = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)", "var(--c5)", "var(--seq-3)"];
  let paretoNote: string | null = null;
  if (pareto && head.length >= 2) {
    let acc = 0, k = 0;
    for (const s of head) { acc += s.value; k += 1; if (acc / total >= 0.8) break; }
    paretoNote = `Top ${fmtInt(k)} of ${fmtInt(known.length)} = ${fmtShare((acc / total) * 100)}`;
  }
  return (
    <div className="blk-stack">
      {(totalLabel || paretoNote) && (
        <div className="blk-stack-head">
          {totalLabel && <span>{totalLabel}</span>}
          {paretoNote && <span className="blk-stack-pareto">{paretoNote}</span>}
        </div>
      )}
      <div className="blk-stack-bar" style={{ height }} role="img" aria-label={ariaLabel || "Share of the whole"}>
        {parts.map((s, i) => {
          const pct = (s.value / total) * 100;
          const color = s.color || (s.isOther ? "var(--c-other)" : palette[i % palette.length]);
          const tip = `${s.label}: ${fmt(s.value)} (${fmtShare(pct)})`;
          const cls = `blk-stack-seg${s.unknown ? " blk-hatch" : ""}${s.onClick ? " clickable" : ""}`;
          return (
            <span key={s.key || `${s.label}-${i}`} className={cls} title={tip}
              style={{ width: `${pct}%`, background: s.unknown ? undefined : color }}
              onClick={s.onClick || undefined}>
              {pct >= 12 && <span className="blk-stack-seg-pct">{fmtShare(pct)}</span>}
            </span>
          );
        })}
      </div>
      <div className="blk-legend">
        {parts.map((s, i) => {
          const pct = (s.value / total) * 100;
          const color = s.color || (s.isOther ? "var(--c-other)" : palette[i % palette.length]);
          return (
            <span key={s.key || `${s.label}-${i}`} className="blk-legend-item">
              <span className={`blk-sw${s.unknown ? " blk-hatch" : ""}`} style={s.unknown ? undefined : { background: color }} />
              {`${s.label} · ${fmtShare(pct)} · ${fmt(s.value)}`}
            </span>
          );
        })}
      </div>
    </div>
  );
}

// ═══════════════════════ 4. StatusBars ═══════════════════════

/** One bar of StatusBars. `name` should already read "name (id)" where an id exists. */
export interface StatusBarItem { key?: string; name: string; value: number; status?: BlockStatus; valueText?: string; title?: string; [key: string]: any }

/** Ranked bars with the status on a dot before each label (Critical red, Warning amber, OK grey). Labels are cut from the
 * left so the identifying tail and "(id)" stay visible; each bar can open its rows. The tail past
 * `n` is counted, never folded. */
export function StatusBars({ items, n = 10, valueFmt, unitLabel, onBarClick, emptyText, ariaLabel, max }: {
  items: StatusBarItem[] | null | undefined; n?: number; valueFmt?: (v: number) => string; unitLabel?: string;
  onBarClick?: ((item: StatusBarItem) => void) | null; emptyText?: string; ariaLabel?: string;
  /** Scale bars against this instead of the largest value (e.g. 100 for a %). */
  max?: number;
}) {
  const [ref, W] = useChartWidth(560);
  const list = (items || []).filter((it) => it && Number.isFinite(it.value));
  if (!list.length) return <div ref={ref} className="chart-note-oneline">{emptyText || "Nothing to show."}</div>;
  const fmt = valueFmt || ((v: number) => fmtInt(v));
  const sorted = [...list].sort((a, b) => b.value - a.value);
  const shown = sorted.slice(0, n);
  const text = (it: StatusBarItem) => it.valueText || fmt(it.value);
  const valueW = Math.min(Math.round(W * 0.4), Math.ceil(Math.max(...shown.map((it) => measureTextPx(text(it))))) + 12);
  const labelW = rowLabelWidth(W, shown.map((it) => it.name), valueW);
  const scale = max && max > 0 ? max : Math.max(...shown.map((it) => it.value), 0) || 1;
  const present = new Set(shown.map((it) => statusKey(it.status)));
  const legend = STATUS_LEGEND.filter(([k]) => present.has(k));
  return (
    <div ref={ref} className="blk-sbars" role="list" aria-label={ariaLabel}>
      {legend.length >= 2 && (
        <div className="blk-legend">
          {legend.map(([k, word]) => (
            <span key={k} className="blk-legend-item"><span className="blk-dot" style={{ background: statusBarColor(k) }} />{word}</span>
          ))}
        </div>
      )}
      {shown.map((it, i) => {
        const pct = Math.max(0, Math.min(100, (it.value / scale) * 100));
        const tip = it.title || `${it.name}: ${text(it)}${unitLabel ? ` ${unitLabel}` : ""}`;
        // Status rides on the 8px dot before the label; the bar stays neutral.
        const inner = (
          <>
            <span className="blk-row-label" style={{ width: labelW }} title={it.name}><span className="blk-dot" style={{ background: statusBarColor(it.status) }} aria-hidden="true" />{truncateLeft(it.name, labelW - 22)}</span>
            <span className="blk-sbar-track"><span className="blk-sbar-fill" style={{ width: `${pct}%`, background: "var(--c1)" }} /></span>
            <span className="blk-sbar-value" style={{ width: valueW }} title={text(it)}>{text(it)}</span>
          </>
        );
        return onBarClick
          ? <button type="button" role="listitem" key={it.key || `${it.name}-${i}`} className="blk-sbar blk-row-btn" title={tip} onClick={() => onBarClick(it)}>{inner}</button>
          : <div role="listitem" key={it.key || `${it.name}-${i}`} className="blk-sbar" title={tip}>{inner}</div>;
      })}
      {sorted.length > shown.length && <div className="blk-more">{`+${fmtInt(sorted.length - shown.length)} more not shown`}</div>}
    </div>
  );
}

// ═══════════════════════ 5. CauseSplitBar ═══════════════════════

function splitReasons(v: any): string[] {
  if (v === null || v === undefined || v === "") return [];
  if (Array.isArray(v)) return v.map(String).filter(Boolean);
  return String(v).split(/[,;|]/).map((x) => x.trim()).filter(Boolean);
}

/** The causes behind a check, from one of its row columns (`finding`, `reasons`, `cause`). One cause
 * per row draws one 100% bar; rows with several causes draw a % of rows per cause instead (those
 * shares overlap, so they are never stacked). Rows with no cause are the hatched "(no cause given)". */
export function CauseSplitBar({ rows, column, weightColumn, valueFmt, noun = "rows", labelFor, onCauseClick }: {
  rows: Row[] | null | undefined; column: string;
  /** Weight each row by this column (e.g. its $) instead of counting it. */
  weightColumn?: string; valueFmt?: (v: number) => string; noun?: string;
  labelFor?: (code: string) => string; onCauseClick?: ((code: string | null) => void) | null;
}) {
  const list = rows || [];
  if (!list.length) return <div className="chart-note-oneline">Nothing to show.</div>;
  const word = (code: string) => (labelFor ? labelFor(code) : (columnEnumLabel(column, code) || humanizeColumnName(code.toLowerCase())));
  const by = new Map<string, number>();
  let none = 0, multi = false;
  list.forEach((r) => {
    const w = weightColumn ? Number(r[weightColumn]) || 0 : 1;
    const codes = splitReasons(r[column]);
    if (codes.length > 1) multi = true;
    if (!codes.length) { none += w; return; }
    codes.forEach((c) => by.set(c, (by.get(c) || 0) + w));
  });
  const fmt = valueFmt || ((v: number) => `${fmtInt(v)} ${noun}`);
  if (multi) {
    const base = weightColumn ? list.reduce((s, r) => s + (Number(r[weightColumn]) || 0), 0) : list.length;
    const items: ShareItem[] = [...by.entries()].map(([code, v]) => ({ key: code, name: word(code), value: v, total: base, onClick: onCauseClick ? () => onCauseClick(code) : null }));
    if (none > 0) items.push({ key: "__none", name: "(no cause given)", value: none, total: base, onClick: onCauseClick ? () => onCauseClick(null) : null });
    return <ShareBarList items={items} valueFmt={valueFmt || ((v) => fmtInt(v))} noun={weightColumn ? undefined : noun} />;
  }
  const segs: ShareSegment[] = [...by.entries()].map(([code, v]) => ({ key: code, label: word(code), value: v, onClick: onCauseClick ? () => onCauseClick(code) : null }));
  if (none > 0) segs.push({ key: "__none", label: "(no cause given)", value: none, unknown: true, onClick: onCauseClick ? () => onCauseClick(null) : null });
  return <StackedShareBar segments={segs} valueFmt={fmt} pareto ariaLabel="Causes" />;
}

// ═══════════════════════ 6. PostureScorecard ═══════════════════════

/** One control of a PostureScorecard. `pass` null = not assessed (never counted as a pass). */
export interface PostureControl { key: string; label: string; pass: boolean | null; value?: React.ReactNode; reason?: string; onClick?: (() => void) | null }

/** A grid of pass/fail chips, headed "N of M controls pass" (M counts assessed controls only). */
export function PostureScorecard({ controls, title }: { controls: PostureControl[] | null | undefined; title?: React.ReactNode }) {
  const list = controls || [];
  const assessed = list.filter((c) => c.pass !== null);
  const passed = assessed.filter((c) => c.pass).length;
  const na = list.length - assessed.length;
  return (
    <div className="blk-posture">
      <div className="blk-posture-head">
        {title && <span className="blk-posture-title">{title}</span>}
        <span className="blk-posture-count">
          {assessed.length ? `${fmtInt(passed)} of ${fmtInt(assessed.length)} controls pass` : "– no control could be assessed"}
          {na > 0 && <span className="blk-posture-na">{` · ${fmtInt(na)} not assessed`}</span>}
        </span>
      </div>
      <div className="blk-posture-grid">
        {list.map((c) => {
          const kind = c.pass === null ? "not_assessed" : c.pass ? "ok" : "critical";
          const body = (
            <>
              <span className="blk-chip-head"><StatusIcon kind={kind} /><span className="blk-chip-label">{c.label}</span></span>
              <span className="blk-chip-value">{c.pass === null ? `– ${c.reason || "not assessed"}` : (c.value ?? (c.pass ? "Pass" : "Fail"))}</span>
            </>
          );
          return c.onClick
            ? <button type="button" key={c.key} className={`blk-chip blk-chip-${kind} clickable`} onClick={c.onClick}>{body}</button>
            : <div key={c.key} className={`blk-chip blk-chip-${kind}`}>{body}</div>;
        })}
      </div>
    </div>
  );
}

// ═══════════════════════ 7. DayKindTimeline ═══════════════════════

/** One event count for DayKindTimeline: a day (YYYY-MM-DD), a kind and how many (default 1). */
export interface DayKindRow { day: string; kind: string; value?: number | null }

function dayRange(first: string, last: string): string[] {
  const out: string[] = [];
  const a = Date.parse(`${first.slice(0, 10)}T00:00:00Z`), b = Date.parse(`${last.slice(0, 10)}T00:00:00Z`);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return out;
  for (let t = a; t <= b && out.length < 400; t += 86400000) out.push(new Date(t).toISOString().slice(0, 10));
  return out;
}

/** Day × kind columns for changes, failures or spikes. Days with nothing still get a column (never
 * skipped); `days` pins the full window. `dangerKinds` draw red (DROP). Click a day for its rows. */
export function DayKindTimeline({ rows, days, kinds, kindColors, dangerKinds, onDayClick, selectedDay, valueFmt, unitLabel, height = 200, partialDay, ariaLabel }: {
  rows: DayKindRow[] | null | undefined; days?: string[] | null; kinds?: string[] | null;
  kindColors?: Record<string, string> | null; dangerKinds?: string[] | null;
  onDayClick?: ((day: string) => void) | null; selectedDay?: string | null;
  valueFmt?: (v: number) => string; unitLabel?: string; height?: number;
  /** Today (or the as-of day) when it is still filling: drawn faded. */
  partialDay?: string | null; ariaLabel?: string;
}) {
  const [ref, W] = useChartWidth(760);
  const list = (rows || []).filter((r) => r && r.day && r.kind);
  if (!list.length && !(days && days.length)) return <div ref={ref} className="chart-note-oneline">Nothing to show.</div>;
  const sortedDays = list.map((r) => String(r.day).slice(0, 10)).sort();
  const allDays = days && days.length ? days.map((d) => String(d).slice(0, 10)) : dayRange(sortedDays[0], sortedDays[sortedDays.length - 1]);
  const totalsByKind = new Map<string, number>();
  const cell = new Map<string, number>();
  list.forEach((r) => {
    const v = r.value == null ? 1 : Number(r.value) || 0;
    const d = String(r.day).slice(0, 10);
    cell.set(`${d}|${r.kind}`, (cell.get(`${d}|${r.kind}`) || 0) + v);
    totalsByKind.set(r.kind, (totalsByKind.get(r.kind) || 0) + v);
  });
  const kindList = kinds && kinds.length ? kinds.filter((k) => totalsByKind.has(k)) : [...totalsByKind.entries()].sort((a, b) => b[1] - a[1]).map(([k]) => k);
  const danger = new Set(dangerKinds || []);
  const palette = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)", "var(--c5)"];
  let pi = 0;
  const colorOf: Record<string, string> = {};
  kindList.forEach((k) => {
    colorOf[k] = (kindColors && kindColors[k]) || (danger.has(k) ? "var(--st-crit)" : (pi < palette.length ? palette[pi++] : "var(--c-other)"));
  });
  const fmt = valueFmt || ((v: number) => fmtInt(v));
  const dayTotals = allDays.map((d) => kindList.reduce((s, k) => s + (cell.get(`${d}|${k}`) || 0), 0));
  const maxT = Math.max(1, ...dayTotals);
  const ticks = niceTicks(0, maxT, 4);
  const step = ticks.length > 1 ? ticks[1] - ticks[0] : undefined;
  const P = { l: 40, r: 8, t: 10, b: 26 };
  const innerW = W - P.l - P.r, innerH = height - P.t - P.b;
  const top = ticks[ticks.length - 1] || 1;
  const yOf = (v: number) => P.t + innerH - (v / top) * innerH;
  const colW = innerW / Math.max(1, allDays.length);
  const barW = Math.max(2, Math.min(18, colW - 2));
  const legend = kindList.map((k) => ({ label: k, color: colorOf[k] }));
  const table = {
    columns: [{ key: "day", label: "Day" }, ...kindList.map((k, i) => ({ key: `k${i}`, label: k, align: "right" }))],
    rows: allDays.map((d) => {
      const r: Record<string, any> = { day: d };
      kindList.forEach((k, i) => { r[`k${i}`] = fmt(cell.get(`${d}|${k}`) || 0); });
      return r;
    }),
  };
  return (
    <div ref={ref}>
      <ChartFrame
        width={W} height={height} pad={P} forceLegend
        yTicks={ticks.map((t) => ({ y: yOf(t), value: t, label: compactTick(t, step) }))}
        zeroY={yOf(0)}
        xLabels={[allDays[0], allDays[Math.floor((allDays.length - 1) / 2)], allDays[allDays.length - 1]].map(fmtDayShort)}
        legend={legend} table={table} ariaLabel={ariaLabel || "Events by day and kind"} className="cols blk-timeline"
        renderPlot={() => (
          <>
            {allDays.map((d, di) => {
              const x = P.l + di * colW + (colW - barW) / 2;
              let acc = 0;
              const partial = partialDay && d === String(partialDay).slice(0, 10);
              const total = dayTotals[di];
              return (
                <g key={d} opacity={partial ? 0.5 : undefined}
                  className={onDayClick ? "blk-day clickable" : "blk-day"}
                  onClick={onDayClick && total > 0 ? () => onDayClick(d) : undefined}>
                  {/* A full-height hit area so a short column is still easy to click. */}
                  <rect x={P.l + di * colW} y={P.t} width={colW} height={innerH}
                    fill={selectedDay === d ? "var(--surface-2)" : "transparent"} />
                  {kindList.map((k, ki) => {
                    const v = cell.get(`${d}|${k}`) || 0;
                    if (v <= 0) return null;
                    const y0 = yOf(acc), y1 = yOf(acc + v);
                    acc += v;
                    const isTop = kindList.slice(ki + 1).every((later) => !((cell.get(`${d}|${later}`) || 0) > 0));
                    return <RoundRect key={k} x={x} y={y1} w={barW} h={Math.max(0, y0 - y1)} r={isTop ? 3 : 0} fill={colorOf[k]} squareEdge="bottom" />;
                  })}
                  <title>{`${d}${partial ? " (partial)" : ""}: ${total > 0 ? kindList.filter((k) => cell.get(`${d}|${k}`)).map((k) => `${k} ${fmt(cell.get(`${d}|${k}`) || 0)}`).join(", ") : "none"}${unitLabel ? ` ${unitLabel}` : ""}`}</title>
                </g>
              );
            })}
          </>
        )}
      />
    </div>
  );
}

// ═══════════════════════ 9. ReconciliationStrip ═══════════════════════

/** One total on a ReconciliationStrip. */
export interface ReconStep { key?: string; label: string; value: number | null | undefined; note?: React.ReactNode; missingReason?: string }

/** A → B → C with the % gap between each pair, for any page that shows more than one total. */
export function ReconciliationStrip({ steps, valueFmt }: { steps: ReconStep[] | null | undefined; valueFmt?: (v: number) => string }) {
  const list = steps || [];
  const fmt = valueFmt || ((v: number) => fmtMoney(v, 0));
  const ok = (v: number | null | undefined): v is number => v != null && Number.isFinite(v);
  return (
    <div className="blk-recon" role="list">
      {list.map((st, i) => {
        const prev = i > 0 ? list[i - 1] : null;
        let gap: React.ReactNode = null;
        if (prev) {
          const g = ok(prev.value) && ok(st.value) && prev.value !== 0 ? ((st.value - prev.value) / Math.abs(prev.value)) * 100 : null;
          const diff = ok(prev.value) && ok(st.value) ? st.value - prev.value : null;
          const big = g !== null && Math.abs(g) >= 5;
          gap = (
            <span className={`blk-recon-gap${big ? " big" : ""}`} title={diff !== null ? `${diff >= 0 ? "+" : "−"}${fmt(Math.abs(diff))} from ${prev.label} to ${st.label}` : "Cannot compare: a total is missing"}>
              <span className="blk-recon-arrow">→</span>
              <span className="blk-recon-gap-pct">{g === null ? "–" : `${g >= 0 ? "+" : "−"}${fmtShare(Math.abs(g))}`}</span>
            </span>
          );
        }
        return (
          <React.Fragment key={st.key || st.label}>
            {gap}
            <div className="blk-recon-step" role="listitem">
              <span className="blk-recon-label">{st.label}</span>
              <span className="blk-recon-value">{ok(st.value) ? fmt(st.value) : "–"}</span>
              {!ok(st.value) && st.missingReason && <span className="blk-recon-note">{st.missingReason}</span>}
              {ok(st.value) && st.note && <span className="blk-recon-note">{st.note}</span>}
            </div>
          </React.Fragment>
        );
      })}
    </div>
  );
}

// ═══════════════════════ 10. WeekHourHeatmap ═══════════════════════

/** ISO weekday labels, Monday first (the checks' day_of_week is 1 = Monday). */
export const WEEKDAYS_ISO = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/** One cell of a weekday x hour grid: the shaded value, or null when the slot had nothing to judge. */
export type WeekHourGrid = (number | null)[][];

/** An empty 7 x 24 grid of nulls. */
export function emptyWeekHourGrid(): WeekHourGrid {
  return Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => null as number | null));
}

/** A weekday x hour grid in single-hue blue, darker = more; a null slot is left blank ("no data"). */
export function WeekHourHeatmap({ grid, tip, max, ariaLabel, legendLow, legendHigh }: {
  grid: WeekHourGrid; tip: (weekday: string, hour: number, v: number | null) => string;
  /** Scale against this instead of the largest cell (e.g. 100 for a %). */
  max?: number; ariaLabel?: string; legendLow?: string; legendHigh?: string;
}) {
  const vals = grid.flat().filter((v): v is number => v != null && Number.isFinite(v));
  const top = max != null ? max : Math.max(0, ...vals);
  const color = (v: number | null) => {
    if (v == null) return "transparent";
    if (!(v > 0) || !(top > 0)) return "var(--seq-0)";
    return `var(--seq-${Math.min(5, Math.max(1, Math.ceil((v / top) * 5)))})`;
  };
  return (
    <div className="hour-heatmap" role="img" aria-label={ariaLabel}>
      <div className="hh-row hh-header">
        <div className="hh-row-label" />
        {Array.from({ length: 24 }, (_, h) => <div key={h} className="hh-hour-label">{h % 3 === 0 ? h : ""}</div>)}
      </div>
      {WEEKDAYS_ISO.map((wd, wi) => (
        <div className="hh-row" key={wd}>
          <div className="hh-row-label">{wd}</div>
          {Array.from({ length: 24 }, (_, h) => {
            const v = grid[wi] ? grid[wi][h] : null;
            return <div key={h} className="hh-cell" title={tip(wd, h, v)}
              style={{ background: color(v), boxShadow: v == null ? "inset 0 0 0 1px var(--border-subtle)" : undefined }} />;
          })}
        </div>
      ))}
      {(legendLow || legendHigh) && (
        <div className="blk-legend">
          <span className="blk-legend-item"><span className="blk-sw" style={{ background: "var(--seq-1)" }} />{legendLow || ""}</span>
          <span className="blk-legend-item"><span className="blk-sw" style={{ background: "var(--seq-5)" }} />{legendHigh || ""}</span>
          <span className="blk-legend-item"><span className="blk-sw" style={{ boxShadow: "inset 0 0 0 1px var(--border-strong)" }} />No data</span>
        </div>
      )}
    </div>
  );
}

// The status pill kind for a block status, for callers that put a pill beside a block.
export { pillKind as blockPillKind };
