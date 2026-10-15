// web/src/components/overview_tile.tsx -- SummaryTile: the one reusable building block for a summary
// strip. A tile is a label, a number, one line and a link: it answers "is this a problem" (severity ->
// left-accent colour), "how big" (value/unit + reading) and "where do I go to look closer" (href).
// No row-level detail; that is the drill-down, and it stays in the tab the tile links to.
//
// A tile with no verified figure passes value="-" and a `reading` that says why (loading / not
// assessed / no estimate) rather than a fake zero: the honesty rule reaches into tile space the same
// way ChartNote does for charts (charts.tsx). While a figure is loading the value is "…".

// The first rung of a check's own `actions:` ladder, which the library writes in cost order (free,
// then config, then spend), so rung 1 is always the cheapest thing that might fix it. Taken verbatim
// from the header and only shortened, never rewritten; absent when the header has no ladder (an
// inventory check's "actions: n/a").
import React from "react";
import { getAuditRange } from "../range_store";
import { fmtInt } from "../format";
import { numOrZero } from "./hooks";
import { Facts, StatusPill, bandOf } from "./primitives";
import type { Finding } from "../types";

/** One Facts entry a tile can carry instead of its reading. */
export interface TileFact { label: string; value: React.ReactNode; title?: string; tone?: string; detail?: React.ReactNode }

/** The optional delta line under a tile's number. */
export interface TileDelta { text?: React.ReactNode; direction?: string }

/** What a caller computed for a tile: whatever it omits falls back to the flagged-row count. */
export interface TileFigure { value?: string | null; unit?: string | null; reading?: string | null }

/** A tile as tileFromFinding builds it, ready to spread into SummaryTile. */
export interface TileSpec {
  label: string;
  value: string;
  unit?: string | null;
  reading?: string | null;
  severity: string;
  facts?: TileFact[];
}

export interface SummaryTileProps {
  label: React.ReactNode;
  value?: React.ReactNode;
  unit?: React.ReactNode;
  /** The mono base line: "1,690 of 29,650 runs". */
  base?: React.ReactNode;
  reading?: React.ReactNode;
  severity?: string;
  /** Overrides the top-right status pill (a kind chip); null hides it. */
  pill?: React.ReactNode;
  href?: React.ReactNode;
  onClick?: () => void;
  scope?: React.ReactNode;
  delta?: TileDelta | null;
  sparkline?: (number | null)[] | null;
  footnote?: React.ReactNode;
  facts?: TileFact[] | null;
}

/** The money cut-off from GET /api/meta: last complete day and, when taken in, today (partial). */
export interface CostCutoff { data_through?: string | null; partial_day?: string | null; [key: string]: any }

export function actionTier(raw: string | null | undefined) {
  const t = String(raw || "").toLowerCase();
  if (t.includes("free")) return "free";
  if (t.includes("config")) return "config";
  if (t.includes("spend")) return "spend";
  return null;
}

export function firstAction(header: { actions?: string[] | null; [key: string]: any } | null | undefined) {
  const ladder = header && header.actions;
  if (!ladder || !ladder.length) return null;
  let full = String(ladder[0]).trim();
  if (!full || full.toLowerCase().startsWith("n/a")) return null;
  // Classify the cost tier from wherever the rung states it, but only STRIP it when it trails.
  let tier = null;
  const anywhere = full.match(/\(([^()]*(?:free|config|spend)[^()]*)\)/i);
  if (anywhere) tier = actionTier(anywhere[1]);
  const trailing = full.match(/\s*\(([^()]*)\)\s*[;.]?\s*$/);
  if (trailing && actionTier(trailing[1])) full = full.slice(0, trailing.index).trim();
  full = full.replace(/[;.]+$/, "").trim();
  if (!full) return null;
  // Truncate on a word boundary, never mid-word.
  let text = full;
  if (text.length > 90) {
    const cut = text.slice(0, 90);
    const lastSpace = cut.lastIndexOf(" ");
    text = `${(lastSpace > 40 ? cut.slice(0, lastSpace) : cut).replace(/[\s,;:.–-]+$/, "")}...`;
  }
  return { text, full, tier };
}

export const TILE_SEVERITIES = ["critical", "warn", "ok", "not_assessed", "neutral"];

// The optional 36px sparkline, last point marked with a dot. `points` is a plain array of numbers
// (already computed by the caller). Fewer than 2 finite points has nothing to draw a line between,
// so it renders nothing rather than a flat or fabricated line.
export function SummaryTileSpark({ points }: { points?: (number | null)[] | null }) {
  const finite = (points || []).filter((p): p is number => Number.isFinite(p));
  if (finite.length < 2) return null;
  const w = 120, h = 36, pad = 2;
  const min = Math.min(...finite), max = Math.max(...finite);
  const span = max - min || 1;
  const stepX = (w - pad * 2) / (finite.length - 1);
  const coords = finite.map((p, i) => [
    pad + i * stepX,
    pad + (h - pad * 2) * (1 - (p - min) / span),
  ]);
  const path = coords.map((c, i) => `${i === 0 ? "M" : "L"}${c[0].toFixed(1)},${c[1].toFixed(1)}`).join(" ");
  const last = coords[coords.length - 1];
  return (
    <svg className="summary-tile-spark" viewBox={`0 0 ${w} ${h}`} width="100%" height="36" preserveAspectRatio="none" aria-hidden="true">
      <path d={path} fill="none" stroke="var(--c1)" strokeWidth="1.6" />
      <circle cx={last[0]} cy={last[1]} r="2.4" fill="var(--c1)" />
    </svg>
  );
}

// The optional delta line ("+ $3,120 (7%) vs previous 30 days"): `direction` picks the arrow and the
// diverging colour, which is about MAGNITUDE of change, not good or bad (more spend is not always
// bad), so it never reads as success or failure. `text` is the caller's own worded sentence.
export function SummaryTileDelta({ delta }: { delta?: TileDelta | null }) {
  if (!delta || !delta.text) return null;
  const down = delta.direction === "down";
  return (
    <div className={`summary-tile-delta ${down ? "down" : "up"}`}>
      <span className="summary-tile-delta-arrow">{down ? "▼" : "▲"}</span>
      <span className="summary-tile-delta-text">{delta.text}</span>
    </div>
  );
}

// Anatomy: eyebrow + pill · number + unit · mono base line · one line · footer link.
// `scope` says what the figure covers when the Account filter does not reach it.
export function SummaryTile({ label, value, unit, base, reading, severity, pill, href, onClick, scope, delta, sparkline, footnote, facts }: SummaryTileProps) {
  const sev = TILE_SEVERITIES.includes(severity as string) ? severity! : "neutral";
  const clickable = typeof onClick === "function";
  // A figure that is not there reads an en dash, never a hyphen or a zero.
  const shown = value === "-" ? "–" : value;
  const missing = shown === "–";
  const tag = pill !== undefined ? pill : sev !== "neutral" ? <StatusPill kind={sev} /> : null;
  return (
    <div
      className={`summary-tile sev-${sev}${missing ? " is-missing" : ""}${clickable ? " clickable" : ""}`}
      onClick={clickable ? onClick : undefined}
      role={clickable ? "button" : undefined}
      tabIndex={clickable ? 0 : undefined}
      onKeyDown={clickable ? (e: React.KeyboardEvent<HTMLDivElement>) => { if (e.key === "Enter" || e.key === " ") onClick!(); } : undefined}
    >
      <div className="summary-tile-head">
        <div className="summary-tile-label">{label}</div>
        {tag}
      </div>
      <div className="summary-tile-value">
        {shown}
        {unit && !missing && <span className="summary-tile-unit">{unit}</span>}
      </div>
      {base && !missing && <div className="summary-tile-base">{base}</div>}
      {scope && <div className="summary-tile-scope">{scope}</div>}
      <SummaryTileDelta delta={delta} />
      <SummaryTileSpark points={sparkline} />
      {facts ? <div className="summary-tile-reading"><Facts items={facts} /></div>
        : (reading && <div className="summary-tile-reading" title={typeof reading === "string" ? reading : undefined}>{reading}</div>)}
      {footnote && <div className="summary-tile-footnote">{footnote}</div>}
      {href && <div className="summary-tile-link">{href} &rarr;</div>}
    </div>
  );
}

// `compact` clamps each reading to 2 lines, for Overview's at-a-glance row.
export function SummaryTileRow({ children, compact, six }: { children?: React.ReactNode; compact?: boolean; six?: boolean }) {
  return <div className={`summary-tile-row${compact ? " compact" : ""}${six ? " six" : ""}`}>{children}</div>;
}

// A header field cut to its first sentence, with the library's own "- field heuristic" hedge
// stripped (it qualifies the threshold, not the cause, and eats the tile).
export function clause(text: string | null | undefined, maxLen?: number) {
  if (!text) return null;
  let s = String(text).trim();
  if (!s || s.toLowerCase().startsWith("n/a")) return null;
  const lower = s.toLowerCase();
  let cutAt = -1;
  [" - field heuristic", " (field heuristic"].forEach((marker) => {
    const idx = lower.indexOf(marker);
    if (idx > 0 && (cutAt === -1 || idx < cutAt)) cutAt = idx;
  });
  if (cutAt > 0) s = s.slice(0, cutAt);
  const m = s.match(/^(.*?[.!?])(\s|$)/);
  if (m) s = m[1];
  s = s.trim();
  const cap = maxLen || 160;
  if (s.length > cap) s = `${s.slice(0, cap - 1).trim()}...`;
  return s || null;
}

// The WHY from the header: investigate_if, else read_this; null rather than an invented cause.
export function headerReason(header: { investigate_if?: string | null; read_this?: string | null; [key: string]: any } | null | undefined) {
  return clause(header && header.investigate_if) || clause(header && header.read_this) || null;
}

// The tile for ONE finding row's own band, with an honest branch for every band bandOf() can
// return: a check that did not run (or errored) reads "-" and why, never a number; a verified empty
// window or an empty filter set reads a real 0 only where 0 is the truth; only a check that ran,
// judged rows and flagged some gets a severity. `figure` is {value, unit, reading} the caller
// computed from data it verified; whatever it omits falls back to the flagged-row count.
// While `loading` the value is "…", never an interim number.
// `population` (one denominator per page): the inventory count of the check's own noun, used as
// the base when it is at least the check's own; the reading's tooltip names what the check assessed.
export function tileFromFinding(label: string, f: Finding | null | undefined, loading: boolean, figure?: TileFigure | null,
  population?: { total: number; noun: string } | null): TileSpec {
  if (loading || !f) return { label, value: "…", reading: null, severity: "neutral" };
  const band = bandOf(f);
  if (band === "NOT_ASSESSED" || band === "ERROR") {
    // The tile says why: the API's reason and the check's own access line, or (when the check ran but
    // every row was unjudged) how many rows and the first row-level reason.
    const na = f.not_assessed || {};
    const unjudged = f.status_counts ? numOrZero(f.status_counts.NOT_ASSESSED) : 0;
    const why = na.label
      || (unjudged > 0 ? `ran, but none of its ${fmtInt(unjudged)} row${unjudged === 1 ? "" : "s"} could be judged` : "not in this export");
    const facts = [{ label: "Why", value: why, title: na.requires ? `Needs: ${na.requires}` : undefined }];
    return { label, value: "-", reading: `Not assessed: ${why}`, facts, severity: "not_assessed" };
  }
  if (band === "EMPTY_WINDOW") return { label, value: "-", reading: `No data for this in ${getAuditRange() || "the window"}`, severity: "neutral" };
  if (band === "EMPTY_FILTERS") return { label, value: "-", reading: "The current filters exclude every row", severity: "neutral" };
  const flagged = f.affected ? f.affected.flagged : 0;
  const severity = band === "CRITICAL" ? "critical" : band === "WARN" ? "warn" : band === "OK" || band === "RANKED" ? "ok" : "neutral";
  const fig = figure || {};
  const a = f.affected;
  // Rows the check could not judge are said, never folded into "not flagged".
  const notJudged = a && numOrZero(a.not_assessed) > 0 ? ` · ${fmtInt(a.not_assessed)} not judged` : "";
  const pop = a && population && population.noun === a.noun && population.total >= numOrZero(a.total) ? population.total : null;
  const flaggedRows = f.status_counts ? numOrZero(f.status_counts.CRITICAL) + numOrZero(f.status_counts.WARN) : 0;
  // Flagged rows that name no object (a total, an account-wide line) are counted as rows, never "0 of N".
  const fallback = a && flagged === 0 && flaggedRows > 0
    ? { value: fmtInt(flaggedRows), unit: null, reading: `row${flaggedRows === 1 ? "" : "s"} flagged · no single ${a.noun.replace(/s$/, "")}${notJudged}` }
    : a
    ? { value: fmtInt(flagged), unit: null, reading: `of ${fmtInt(pop ?? a.total)} ${a.noun} flagged${notJudged}` }
    : { value: fmtInt((f.status_counts && ((f.status_counts.CRITICAL || 0) + (f.status_counts.WARN || 0))) || 0), unit: null, reading: "rows flagged" };
  return {
    label,
    value: fig.value != null ? fig.value : fallback.value,
    unit: fig.unit != null ? fig.unit : fallback.unit,
    reading: fig.reading != null ? fig.reading : fallback.reading,
    severity,
  };
}

// A tile's onClick: scroll to that tab's own detail below the strip. There is no router, so this
// is a scroll, not a navigation.
export function scrollToAnchor(anchorId: string) {
  const el = document.getElementById(anchorId);
  if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
}

// ─────────── The one money cut-off. GET /api/meta's `cost_cutoff` says the last complete day
// (data_through) and, when the export took in today, that today is partial (partial_day). Every
// range label reads it, so a page never shows two different "todays". ───────────
export let _costCutoff: CostCutoff | null = null;
export function setCostCutoff(c: CostCutoff | null | undefined) { _costCutoff = c || null; }

// The bars of a daily or monthly chart that are still filling: today (partial_day) and the month
// that contains it. `keys` are YYYY-MM-DD strings; `monthly` says each key is a month start.
export function partialBarKeys(keys: string[], monthly: boolean) {
  const cut: CostCutoff = _costCutoff || {};
  const day = (v: string | null | undefined) => String(v || "").slice(0, 10);
  if (monthly) {
    const ref = day(cut.partial_day) || day(cut.data_through);
    if (!ref) return [];
    const end = new Date(Date.UTC(Number(ref.slice(0, 4)), Number(ref.slice(5, 7)), 0)).getUTCDate();
    if (!cut.partial_day && Number(ref.slice(8, 10)) >= end) return [];
    return keys.filter((k) => day(k).slice(0, 7) === ref.slice(0, 7));
  }
  return cut.partial_day ? keys.filter((k) => day(k) === day(cut.partial_day)) : [];
}

export const MONTH_ABBR = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const DAY_MS = 86400000;

export function _utcDay(iso: string | null | undefined) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ""));
  return m ? Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null;
}
export function _dayMonth(ms: number) {
  const d = new Date(ms);
  return `${d.getUTCDate()} ${MONTH_ABBR[d.getUTCMonth()]}`;
}

// The days a window covers: {first, last, days, partialDay}. `last` is the last complete day
// (cost_cutoff.data_through, else the day before the export date); `partialDay` is today when the
// export took it in. `snapshotDays` caps the window at what the export holds.
export function windowSpan(asOfDate: string | null | undefined, windowDays: number | null | undefined, snapshotDays?: number | null) {
  const cut: CostCutoff = _costCutoff || {};
  const lastMs = _utcDay(cut.data_through) != null ? _utcDay(cut.data_through)
    : (_utcDay(asOfDate) != null ? _utcDay(asOfDate)! - DAY_MS : null);
  if (lastMs == null || !windowDays) return null;
  const days = snapshotDays && snapshotDays < windowDays ? snapshotDays : windowDays;
  return { first: lastMs - (days - 1) * DAY_MS, last: lastMs, days, partialDay: _utcDay(cut.partial_day), requested: windowDays };
}

// "16–22 Sep, 7 days of data": the days the money covers, capped at what the export holds.
export function windowShortLabel(asOfDate: string | null | undefined, windowDays: number | null | undefined, snapshotDays?: number | null) {
  const s = windowSpan(asOfDate, windowDays, snapshotDays);
  if (!s) return null;
  const range = new Date(s.first).getUTCMonth() === new Date(s.last).getUTCMonth()
    ? `${new Date(s.first).getUTCDate()}–${new Date(s.last).getUTCDate()} ${MONTH_ABBR[new Date(s.last).getUTCMonth()]}`
    : `${_dayMonth(s.first)} – ${_dayMonth(s.last)}`;
  return `${range}, ${s.days} days of data`;
}

// "16 Sep - 22 Sep 2026" (+ "and today, partial" when today is in). When the export holds fewer days
// than the window, the label states the days actually captured instead of inventing the rest.
export function windowRangeLabel(asOfDate: string | null | undefined, windowDays: number | null | undefined, snapshotDays?: number | null) {
  const s = windowSpan(asOfDate, windowDays, snapshotDays);
  if (!s) return null;
  const year = new Date(s.last).getUTCFullYear();
  let text = `${_dayMonth(s.first)} - ${_dayMonth(s.last)} ${year}`;
  if (s.partialDay != null) text += ` and today (${_dayMonth(s.partialDay)}, partial)`;
  if (snapshotDays && windowDays != null && snapshotDays < windowDays) text += ` -- partial, export covers ${snapshotDays}d of ${windowDays}d`;
  return text;
}

// sf_task_duration_regression's two periods: the window's days up to the day before the export
// date, against the same number of days before them. "6 Sep - 5 Oct against 7 Aug - 5 Sep 2026".
export function slowdownPeriods(asOfDate: string | null | undefined, windowDays: number | null | undefined) {
  const end = _utcDay(asOfDate);
  if (end == null || !windowDays) return null;
  const nowLast = end - DAY_MS, nowFirst = end - windowDays * DAY_MS;
  const prevLast = nowFirst - DAY_MS, prevFirst = nowFirst - windowDays * DAY_MS;
  return `${_dayMonth(nowFirst)} - ${_dayMonth(nowLast)} against ${_dayMonth(prevFirst)} - ${_dayMonth(prevLast)} ${new Date(nowLast).getUTCFullYear()}`;
}

// windowRangeLabel as a Window fact + (when partial) a separate amber Coverage fact.
export function windowFacts(asOfDate: string | null | undefined, windowDays: number | null | undefined, snapshotDays?: number | null): TileFact[] {
  const full = windowRangeLabel(asOfDate, windowDays, snapshotDays);
  if (!full) return [];
  const marker = " -- partial, export covers ";
  const cut = full.indexOf(marker);
  if (cut === -1) return [{ label: "Window", value: full }];
  return [
    { label: "Window", value: full.slice(0, cut) },
    { label: "Coverage", value: full.slice(cut + marker.length), tone: "warn" },
  ];
}
