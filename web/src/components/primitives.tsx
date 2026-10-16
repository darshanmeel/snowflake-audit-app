// web/src/components/primitives.tsx -- small reusable bits (adapted from the reference
// dashboard's components/primitives.tsx Badge/Tip pattern, kept minimal for this vertical slice).

// P3 (DESIGN-DIRECTION.md section 6): a status never rides on colour alone -- Critical/Warning/
// OK/Not assessed/Reference (and Badge's own "error", drawn the same shape as Critical) each get
// StatusIcon's hand-drawn 12px mark ahead of the word. A `kind` outside this map (e.g. "info", or
// a free-text chip like a domain/tier label) draws no icon and renders exactly as before -- it was
// never a status colour to begin with.
import React from "react";
import { AreaContent } from "../area_content";
import { Api } from "../api";
import { estLabel, fmtDayShort, fmtInt, fmtMoney } from "../format";
import { IgnoredFilterTracker, useIgnoredFilterSummary } from "./hooks";
import { AREA_REGISTRY, EST_SPEND_CAVEAT, countsForIds, visibleSubtabs } from "./tab_registry";
import { getCheckLabel } from "./labels";
import { TabScopeNote } from "./scope";
import { ChecksList, CoverageStrip, NotJudgedStrip } from "./checks_list";
import { CheckDrawer, DrawerBus, useDrawer } from "./drawer";
import "./wh_idle_detail"; // registers the Idle drawer block
import { windowRangeLabel } from "./overview_tile";
import { navHref } from "./nav_hash";
import { LENS_LABEL, pageLabel } from "./lens_nav";
import type { Dims, Filters, Finding, GoTo, GoToFn, Meta, Row } from "../types";

export const STATUS_ICON_SHAPE: Record<string, string> = {
  critical: "critical", error: "critical",
  warn: "warn", ok: "ok", not_assessed: "not_assessed", reference: "reference", ranked: "reference",
};

// Checks that rank resources by size alone (no critical/warn threshold) must always read "Ranked",
// never Critical/Warn, whatever their own row status happens to be. None today; a check that ranks
// by size adds its id here.
export const RANKED_QUERY_IDS = new Set<string>([]);

// StatusIcon: one shape per status, every stroke/fill in currentColor so the caller's own CSS
// (ink on a tint, or a bare mark colour) decides the actual colour -- this component only ever
// picks WHICH shape to draw. Hand-drawn, not a library icon set (section 8: no framework added).
export function StatusIcon({ kind, size = 12 }: { kind?: string | null; size?: number }) {
  const shape = STATUS_ICON_SHAPE[kind as string];
  if (!shape) return null;
  const common: React.SVGProps<SVGSVGElement> = { width: size, height: size, viewBox: "0 0 16 16", className: "status-icon", "aria-hidden": "true", focusable: "false" };
  if (shape === "critical") {
    return (
      <svg {...common}>
        <path d="M5.5 1.5H10.5L14.5 5.5V10.5L10.5 14.5H5.5L1.5 10.5V5.5L5.5 1.5Z" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
        <line x1="8" y1="4.6" x2="8" y2="9" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        <circle cx="8" cy="11.4" r="0.9" fill="currentColor" />
      </svg>
    );
  }
  if (shape === "warn") {
    return (
      <svg {...common}>
        <path d="M8 2L15 14H1L8 2Z" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
        <line x1="8" y1="6.6" x2="8" y2="10" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        <circle cx="8" cy="12" r="0.9" fill="currentColor" />
      </svg>
    );
  }
  if (shape === "ok") {
    return (
      <svg {...common}>
        <circle cx="8" cy="8" r="6.3" fill="none" stroke="currentColor" strokeWidth="1.4" />
        <path d="M5 8.3L7.2 10.4L11.2 5.7" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  }
  if (shape === "not_assessed") {
    return (
      <svg {...common}>
        <circle cx="8" cy="8" r="6.3" fill="none" stroke="currentColor" strokeWidth="1.4" strokeDasharray="2 2.2" />
        <path d="M6.1 6.3C6.1 5 7 4.2 8.1 4.2C9.2 4.2 10 5 10 6C10 7.4 8.2 7.3 8.2 9.1" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
        <circle cx="8.2" cy="11.2" r="0.9" fill="currentColor" />
      </svg>
    );
  }
  // reference: a short ruled list -- "lines" per section 6.
  return (
    <svg {...common}>
      <rect x="1.6" y="2.6" width="12.8" height="10.8" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.3" />
      <line x1="4" y1="6" x2="12" y2="6" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" />
      <line x1="4" y1="8.6" x2="12" y2="8.6" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" />
      <line x1="4" y1="11.2" x2="9" y2="11.2" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" />
    </svg>
  );
}

// The word each status reads as (section 6). A caller may still pass its own `word` (StatusPill)
// for a context that needs different phrasing; this is only the default.
export const STATUS_WORD: Record<string, string> = {
  critical: "Critical", warn: "Warning", ok: "OK", not_assessed: "Not assessed", reference: "Reference",
  ranked: "Ranked", neutral: "Context",
};

// A money kind as a chip ("Possible waste", "Spend"): a label, never a status colour.
export function KindChip({ children }: { children?: React.ReactNode }) {
  return <span className="status-pill status-pill-kind">{children}</span>;
}

// StatusPill: [icon][word][count], the full form; `compact` drops the word for the sub-tab bar
// and the nav rail, where only the icon and the count fit (section 4). `count === 0` reads faint
// with no tint (section 4: "a zero is shown faint, with no tint") -- a quiet true zero, never a
// colourless void. Colour is carried by the CSS class alone; this component never inlines one.
export function StatusPill({ kind, word, count, compact = false }: { kind: string; word?: string | null; count?: number | null; compact?: boolean }) {
  const label = word || STATUS_WORD[kind] || kind;
  const isZero = count === 0;
  const cls = ["status-pill", `status-pill-${kind}`, compact ? "compact" : "", isZero ? "zero" : ""]
    .filter(Boolean).join(" ");
  return (
    <span className={cls}>
      <StatusIcon kind={kind} />
      {!compact && <span className="status-pill-word">{label}</span>}
      {count != null && <span className="status-pill-count">{count}</span>}
    </span>
  );
}

// Badge keeps its exact exported name and props (kind/solid/children) so every existing caller
// (Tip wrappers, finding_detail.tsx chips, tab_jobs.tsx verdicts, ...) keeps working unchanged;
// only its rendering changed -- a kind that names one of our five statuses (or Badge's own
// "error") now draws StatusIcon ahead of the word, so a status is never colour alone. A kind like
// "info" (a plain chip: domain, tier, query id, ...) draws no icon, exactly as before.
export function Badge({ kind = "info", solid = false, children }: { kind?: string; solid?: boolean; children?: React.ReactNode }) {
  const cls = ["badge", solid ? "solid" : "", kind].filter(Boolean).join(" ");
  return (
    <span className={cls}>
      <StatusIcon kind={kind} />
      {children}
    </span>
  );
}

export function Dot({ kind }: { kind?: string | null }) {
  return <span className={`dot ${kind}`}></span>;
}

// Hover tooltip -- read_this / confidence_note, off the row to keep the table scannable
// (mirrors app/ui/panel.tooltip_text's own reasoning for putting this on a help= hover).
// `placement` (F2/F4): the bubble opens upward by default, which a header pinned to the TOP of a
// scrolling box (finding_detail.tsx's table.data thead, position:sticky top:0) has no room for --
// .data-table-wrap's own overflow:auto then clips it to an unreadable sliver (found wiring up
// F2's column-header tips). "down" opens it below instead; "end" right-aligns it (for a tip near
// the right edge of a narrow box) instead of the default left-aligned bubble.
export function Tip({ text, children, placement }: { text?: React.ReactNode; children?: React.ReactNode; placement?: string | null }) {
  if (!text) return children || null;
  const cls = ["tip", placement].filter(Boolean).join(" ");
  return (
    <span className={cls}>
      {children || <span className="i">i</span>}
      <span className="bubble">{text}</span>
    </span>
  );
}

// A thin proportional bar for "magnitude" (row_count scaled against the largest visible row --
// see App.tsx's own note on why row_count, not a dollar figure, is this vertical slice's
// magnitude signal).
export function MagBar({ value, max }: { value: number; max: number }) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  return (
    <div className="mag-bar-track">
      <div className="mag-bar-fill" style={{ width: `${pct}%` }}></div>
    </div>
  );
}

// Facts: a labelled fact list under a KPI's big number, in place of a hand-written sentence once a
// card has more than one number to carry. items: [{label, value, tone, detail, title}] -- tone
// colours the value (crit/warn/ok/muted/money; money reads as plain neutral text, same as no tone);
// detail is a muted trailing clause; title is hover text (e.g. a shortened id's full form). A fact
// with no value is dropped rather than rendered blank.
/** One fact in a Facts list. */
export interface FactItem {
  label?: React.ReactNode;
  value?: React.ReactNode;
  tone?: string | null;
  detail?: React.ReactNode;
  title?: string | null;
}
export type FactItems = (FactItem | null | undefined | false)[] | null;

export function Facts({ items }: { items?: FactItems }) {
  const rows = (items || []).filter((it): it is FactItem => !!(it && it.value != null && it.value !== ""));
  if (!rows.length) return null;
  return (
    <div className="facts">
      {rows.map((it, i) => (
        <React.Fragment key={it.label != null ? `${it.label}-${i}` : i}>
          <span className="facts-label">{it.label}</span>
          <span className={`facts-value${it.tone ? ` tone-${it.tone}` : ""}`} title={it.title || undefined}>
            {it.value}
            {/* Facts owns the " · " separator so no caller can forget it (and none can double it
                by hand-typing one) -- pass the bare detail text, no leading "· ". */}
            {it.detail ? <span className="facts-detail">{` · ${it.detail}`}</span> : null}
          </span>
        </React.Fragment>
      ))}
    </div>
  );
}

// PqgsNote: tab_query/tab_governance/tab_storage's KPI-card note slot had no shared component of
// its own -- same facts option as the card primitives below, in place of its plain-sentence children.
export function PqgsNote({ children, facts }: { children?: React.ReactNode; facts?: FactItems }) {
  if (facts && facts.length) return <div className="pqgs-card-note"><Facts items={facts} /></div>;
  if (children == null || children === "") return null;
  return <div className="pqgs-card-note">{children}</div>;
}

// The outcome -> band classification every table row and the triage strip share, so the two can
// never disagree about what a finding "is" this render (PLAN.md 6.2: the four outcomes stay
// visually distinct -- never collapsed into a single "ok"/"not ok" bit).
export const BAND_LABEL = {
  CRITICAL: "Critical",
  WARN: "Warn",
  OK: "OK",
  NOT_ASSESSED: "Not assessed",
  INVENTORY: "Inventory",
  RANKED: "Ranked",
  EMPTY_WINDOW: "Nothing in window",
  EMPTY_FILTERS: "Excluded by filters",
  ERROR: "Read error",
};

export function bandOf(row: Row) {
  if (row.outcome === "error") return "ERROR";
  if (row.outcome === "not_assessed") return "NOT_ASSESSED";
  if (row.outcome === "ok_empty_window") return "EMPTY_WINDOW";
  if (row.outcome === "ok_empty_filters") return "EMPTY_FILTERS";
  // ok_rows
  const sc = row.status_counts;
  if (!sc) return "INVENTORY";
  // DEC-74: a magnitude-only ranking never reads Critical/Warn, whatever its own rows say.
  if (RANKED_QUERY_IDS.has(row.query_id)) return "RANKED";
  // The server caps a report-type check's own CRITICAL rows to WARN before they ever reach here
  // (contract E, app/core/materiality.severity_cap) -- status_counts.CRITICAL is already the
  // capped count, so this band always matches what the row itself carries.
  if ((sc.CRITICAL || 0) > 0) return "CRITICAL";
  if ((sc.WARN || 0) > 0) return "WARN";
  // T-67: a finding can return real rows where every single one was judged NOT_ASSESSED (no
  // too few queries, ...) with zero rows ever reaching a CRITICAL/WARN/OK
  // verdict -- that is not a verified clean pass, so it must not fall through to OK just
  // because the row-level status is not one of the two flagged values. NOT_ASSESSED is never OK.
  if ((sc.NOT_ASSESSED || 0) > 0 && !(sc.OK || 0)) return "NOT_ASSESSED";
  return "OK";
}

// T-67: every band that is NOT a verified CRITICAL/WARN/OK verdict for a finding -- the model
// failed/was skipped (NOT_ASSESSED), a local read failed (ERROR), or the result was a real but
// unjudged zero (EMPTY_WINDOW/EMPTY_FILTERS). A caller tallying "how many of these checks can I
// trust" must count all four the same way, or a domain made entirely of read errors / empty
// windows / filtered-out rows quietly reads as a verified "0 flagged" clean pass.
export function isUncertainBand(band?: string | null) {
  return band === "NOT_ASSESSED" || band === "ERROR" || band === "EMPTY_WINDOW" || band === "EMPTY_FILTERS";
}

// ranCountsOf: the ONE "checks that ran" count, read from GET /api/meta (`checks_ran`), so the top
// bar, Overview, Coverage and the printed summary can never differ. null until meta has answered:
// callers show "…" then, never a count worked out here from the findings list.
export function ranCountsOf(meta?: Meta | null) {
  const c = meta && meta.checks_ran;
  if (!c || !Number.isFinite(Number(c.ran)) || !Number.isFinite(Number(c.total))) return null;
  return { assessed: Number(c.ran), total: Number(c.total), unit: c.unit || "checks", notRan: c.not_ran || {} };
}
// "12 of 48 checks ran", or "…" while meta is loading.
export function ranCountsText(meta?: Meta | null) {
  const c = ranCountsOf(meta);
  return c ? `${fmtInt(c.assessed)} of ${fmtInt(c.total)} ${c.unit} ran` : "…";
}

export function bandDotKind(band?: string | null) {
  switch (band) {
    case "CRITICAL": return "critical";
    case "WARN": return "warn";
    case "OK": return "ok";
    case "NOT_ASSESSED": return "not_assessed";
    case "RANKED": return "inventory";
    default: return "inventory";
  }
}

// bandOf() -> the StatusPill `kind` for that band (findings_table.tsx's own worst-band pill).
export function bandPillKind(band?: string | null) {
  switch (band) {
    case "CRITICAL": return "critical";
    case "WARN": return "warn";
    case "OK": return "ok";
    case "RANKED": return "ranked";
    case "NOT_ASSESSED": case "ERROR": return "not_assessed";
    default: return "reference";
  }
}

// P2-BOUNDARY: a React error boundary. getDerivedStateFromError/componentDidCatch only exist on
// a class component (no hooks equivalent), so this is the one class component in app/web. It
// catches a render error anywhere in its children and shows a small card in the app's own
// honest-card style (finding_detail.tsx's NotAssessedCard/EmptyWindowCard/ErrorCard family)
// instead of letting one bad row or one broken component blank the whole page. "Try again"
// clears the caught error and re-renders the same children fresh -- no page reload, no refetch --
// so a one-off render glitch gets a real second chance without losing whatever else is on screen.
//
// Wrapping pattern for any other top-level panel (App.tsx and every other tab wrap their own
// panels the same way, tracked as later work): <ErrorBoundary><ThePanel ... /></ErrorBoundary>
export class ErrorBoundary extends React.Component<{ children?: React.ReactNode }, { error: any }> {
  constructor(props: { children?: React.ReactNode }) {
    super(props);
    this.state = { error: null };
    this.retry = this.retry.bind(this);
  }
  static getDerivedStateFromError(error: any) {
    return { error };
  }
  componentDidCatch(error: any, info: React.ErrorInfo) {
    // eslint-disable-next-line no-console
    console.error("ErrorBoundary caught a render error:", error, info && info.componentStack);
  }
  retry() {
    this.setState({ error: null });
  }
  render() {
    if (this.state.error) {
      const err = this.state.error;
      const msg = (err && (err.message || String(err))) || "Unknown error";
      return (
        <div className="honest-card error">
          <div className="h-title">This panel could not be shown</div>
          <details className="h-detail">
            <summary>Error details</summary>
            <div className="h-note mono">{msg}</div>
          </details>
          <button type="button" className="eb-retry" onClick={this.retry}>Try again</button>
        </div>
      );
    }
    return this.props.children;
  }
}

// ChartCard (DESIGN-DIRECTION.md section 6): the title reads as a question (16/600), the subtitle
// gives unit/dates/basis once (13, --text-3), and "Table"/"Open check ->" are right-side slots a
// caller wires up or omits. `children` is the chart itself; `takeaway` is one optional line under
// it. Exported for later lanes (P5 rewires the tab_*.jsx chart cards onto it) -- this pass only
// builds and exports it, per the task split in section 7; no existing tab is rewired to use it,
// so it draws its own "chart-card-v2" class rather than the "chart-card" class those tabs already
// own, and nothing here touches charts.tsx/charts_more.tsx (edited in parallel this same round).
export function ChartCard({ title, subtitle, onToggleTable, showingTable, onOpenCheck, takeaway, children }: {
  title?: React.ReactNode; subtitle?: React.ReactNode; onToggleTable?: (() => void) | null; showingTable?: boolean;
  onOpenCheck?: (() => void) | null; takeaway?: React.ReactNode; children?: React.ReactNode;
}) {
  return (
    <div className="chart-card-v2">
      <div className="chart-card-v2-head">
        <div className="chart-card-v2-titles">
          {title && <div className="chart-card-v2-title">{title}</div>}
          {subtitle && <div className="chart-card-v2-subtitle">{subtitle}</div>}
        </div>
        {(onToggleTable || onOpenCheck) && (
          <div className="chart-card-v2-actions">
            {onToggleTable && (
              <button type="button" className="chart-card-v2-toggle" onClick={onToggleTable} aria-pressed={!!showingTable}>
                {showingTable ? "Chart" : "Table"}
              </button>
            )}
            {onOpenCheck && (
              <button type="button" className="chart-card-v2-open" onClick={onOpenCheck}>
                {"Open check →"}
              </button>
            )}
          </div>
        )}
      </div>
      <div className="chart-card-v2-body">{children}</div>
      {takeaway && <div className="chart-card-v2-takeaway">{takeaway}</div>}
    </div>
  );
}

// StateNote (DESIGN-DIRECTION.md section 6, "the honesty rule, one component"): takes the chart's
// own slot and height and is never blank. Six states, each worded so the reader can tell "nothing
// happened here" apart from "nothing was found" apart from "we could not tell" -- the same
// distinction the rest of the app already draws (bandOf/isUncertainBand above), given its own
// reusable shape for chart space. Exported for later lanes; no existing chart is rewired to it
// this pass (section 7's own split -- P4/P5 wire it into charts.tsx's ChartFrame and the tabs).
//   loading        -- skeleton bars, no spinner
//   ok_empty       -- nothing flagged (a verified, judged zero)
//   empty_window   -- a real but unjudged zero: "Not a verified zero."
//   hidden_filters -- rows exist, the current filters hide every one
//   not_assessed   -- a gap, not a pass
//   error          -- a local read failed
export const STATE_NOTE_KINDS = ["loading", "ok_empty", "empty_window", "hidden_filters", "not_assessed", "error"];
export function StateNote({ state, height = 120, rowCount, rangeLabel, reason, onReset, onRetry, onOpenGaps, gapHref = "Coverage & Gaps" }: {
  state?: string | null; height?: number; rowCount?: number | null; rangeLabel?: string | null; reason?: React.ReactNode;
  onReset?: (() => void) | null; onRetry?: (() => void) | null; onOpenGaps?: (() => void) | null; gapHref?: string | null;
}) {
  const kind = STATE_NOTE_KINDS.includes(state as string) ? state : "loading";
  const style = { minHeight: height };
  if (kind === "loading") {
    return (
      <div className="state-note state-note-loading" style={style} aria-busy="true">
        <div className="state-note-text muted">Loading...</div>
        <div className="state-note-skeleton" style={{ width: "88%" }} />
        <div className="state-note-skeleton" style={{ width: "64%" }} />
        <div className="state-note-skeleton" style={{ width: "42%" }} />
      </div>
    );
  }
  if (kind === "ok_empty") {
    const n = rowCount != null ? fmtInt(rowCount) : null;
    return (
      <div className="state-note state-note-ok" style={style}>
        <StatusIcon kind="ok" />
        <div className="state-note-text">
          {n != null ? `Nothing flagged in ${n} row${rowCount === 1 ? "" : "s"}` : "Nothing flagged"}
          {rangeLabel ? `, ${rangeLabel}` : ""}.
        </div>
      </div>
    );
  }
  if (kind === "empty_window") {
    return (
      <div className="state-note state-note-neutral" style={style}>
        <div className="state-note-text">{"Not a verified zero."}{reason ? ` ${reason}` : ""}</div>
      </div>
    );
  }
  if (kind === "hidden_filters") {
    return (
      <div className="state-note state-note-neutral" style={style}>
        <div className="state-note-text">Hidden by your filters.</div>
        {onReset && <button type="button" className="state-note-action" onClick={onReset}>Reset filters</button>}
      </div>
    );
  }
  if (kind === "not_assessed") {
    return (
      <div className="state-note state-note-na" style={style}>
        <StatusIcon kind="not_assessed" />
        <div className="state-note-text">
          {reason || "This could not be read."} This is a gap, not a pass.
          {/* Review round 1: this rendered as a plain, non-clickable span even though it reads
              exactly like a link ("Coverage & Gaps →"). A caller that wires up `onOpenGaps` gets a
              real button; until one does, the words stay plain text rather than a fake link that
              goes nowhere on click. */}
          {gapHref && (onOpenGaps ? (
            <button type="button" className="state-note-link" onClick={onOpenGaps}>{` ${gapHref} →`}</button>
          ) : (
            <span className="state-note-link-text">{` ${gapHref} →`}</span>
          ))}
        </div>
      </div>
    );
  }
  // error
  return (
    <div className="state-note state-note-error" style={style}>
      <StatusIcon kind="critical" />
      <div className="state-note-text">{reason || "Could not read this table."}</div>
      {onRetry && <button type="button" className="state-note-action" onClick={onRetry}>Try again</button>}
    </div>
  );
}

// ═══════════════════════ Redesign shared-base primitives (section 1-5 of the brief) ═══════════════════════

// The whole page as the browser's print dialog sees it; "Save as PDF" is that dialog's own option.
// print-full lifts Overview's summary-only print for this one print.
export function printWholePage() {
  document.body.classList.add("print-full");
  window.addEventListener("afterprint", () => document.body.classList.remove("print-full"), { once: true });
  window.print();
}

export function PrintPageButton() {
  return <button type="button" className="copy-link-btn print-page-btn" onClick={printWholePage}>Save as PDF</button>;
}

// The page head's eyebrow: "CTO · Cost · last 30 days · <dates>", or the snapshot label instead.
export function pageEyebrow(role: string | null | undefined, section: string, meta: Meta | null | undefined, windowDays: number, snapshot?: string | null) {
  const lens = role ? LENS_LABEL[role] || null : null;
  const when = snapshot || [`last ${windowDays} days`, windowRangeLabel(meta && meta.as_of_date, windowDays, meta && meta.snapshot_days)].filter(Boolean).join(" · ");
  return [lens, section, when].filter(Boolean).join(" · ");
}

// PageIntro: overline (small caps scope/date label), title, one verdict sentence with real numbers,
// the method line under it, and an optional right-aligned action (e.g. Export).
export function PageIntro({ overline, title, scope, verdict, action }: {
  overline?: React.ReactNode; title?: React.ReactNode; scope?: React.ReactNode; verdict?: React.ReactNode; action?: React.ReactNode;
}) {
  return (
    <div className="page-intro">
      {overline && <div className="page-intro-overline">{overline}</div>}
      <div className="page-intro-head">
        <div>
          <h1 className="page-intro-title">{title}</h1>
          {verdict && <div className="page-intro-verdict">{verdict}</div>}
          {scope && <div className="page-intro-scope">{scope}</div>}
        </div>
        {action && <div className="page-intro-action">{action}</div>}
      </div>
    </div>
  );
}

// SubTabs: pill sub-tab bar with a count badge per tab -- red = criticals, amber = warns only,
// grey "no data" text when every owned check on that sub-tab has nothing to report. `tabs` is
// [{key, label, critical, warn, noData}] -- countsForIds (tab_registry.tsx) builds this shape so
// this bar and a caller's own badges can never disagree (section 4.1).
/** One sub-tab in the SubTabs bar, with its badge counts. */
export interface SubTabRow {
  key: string;
  label: React.ReactNode;
  critical: number;
  warn: number;
  noData?: boolean;
  notRun?: boolean;
}

export function SubTabs({ tabs, active, onChange }: { tabs?: SubTabRow[] | null; active?: string | null; onChange: (key: string) => void }) {
  return (
    <div className="area-subtabs" role="tablist">
      {(tabs || []).map((t) => {
        // Just the critical count; its unit is in the title. A tab where no check ran reads "–".
        const badge = t.critical > 0
          ? { text: fmtInt(t.critical), cls: "critical", title: `${fmtInt(t.critical)} critical check${t.critical === 1 ? "" : "s"} on this tab` }
          : t.noData && t.notRun ? { text: "–", cls: "", title: "No check on this tab ran" } : null;
        return (
          <button
            key={t.key}
            type="button"
            role="tab"
            aria-selected={active === t.key}
            className={`area-subtab ${active === t.key ? "active" : ""}`}
            onClick={() => onChange(t.key)}
          >
            {t.label}
            {badge && <span className={`area-subtab-badge ${badge.cls}`} title={badge.title} aria-label={badge.title}>{badge.text}</span>}
          </button>
        );
      })}
    </div>
  );
}

// Card: the one generic hairline card (surface, hairline border, no heavy shadow) every panel is
// built from -- an optional title + one right-aligned link/action in its head row.
export function Card({ title, right, children, className }: { title?: React.ReactNode; right?: React.ReactNode; children?: React.ReactNode; className?: string | null }) {
  return (
    <div className={["card", className].filter(Boolean).join(" ")}>
      {(title || right) && (
        <div className="card-head">
          {title && <div className="card-title">{title}</div>}
          {right}
        </div>
      )}
      {children}
    </div>
  );
}

/** A cause card: serif title, one muted line under it, a link on the right, then the chart. */
export function PatternCard({ title, sub, link, onLink, children, className }: {
  title: React.ReactNode; sub?: React.ReactNode; link?: string | null; onLink?: (() => void) | null;
  children?: React.ReactNode; className?: string | null;
}) {
  return (
    <div className={["card pc-card", className].filter(Boolean).join(" ")}>
      <div className="pc-head">
        <div className="pc-titles">
          <div className="pc-title">{title}</div>
          {sub && <div className="pc-sub">{sub}</div>}
        </div>
        {link && onLink && <button type="button" className="pc-link" onClick={onLink}>{link}</button>}
      </div>
      {children}
    </div>
  );
}

// noDataText (contract H): "No data for this in 22 Aug - 20 Sep 2026" -- built on overview_tile.
// jsx's own windowRangeLabel, so this reads the exact dates rather than the vaguer "in the current
// window". Falls back to a plain day count while `meta` has not loaded yet.
export function noDataText(meta: Meta | null | undefined, windowDays: number) {
  const range = typeof windowRangeLabel === "function"
    ? windowRangeLabel(meta && meta.as_of_date, windowDays, meta && meta.snapshot_days)
    : null;
  return `No data for this in ${range || `the last ${fmtInt(windowDays)} days`}`;
}

export function EmptyState({ meta, windowDays }: { meta?: Meta | null; windowDays: number }) {
  return <div className="muted">{noDataText(meta, windowDays)}</div>;
}

// NoDataBlock: one card for a tab/sub-tab whose sources are empty (never a grid of "-" tiles).
// `sources` is [{name, unlocks}] or plain strings; `unlocks` is an optional flat list of check
// names this data would turn on; `howToFill` is the plain-text command/instruction to close the
// gap (Coverage & Gaps' own coverage payload is the source of truth for which sources are empty).
// `meta`/`windowDays` are optional -- a caller that has them gets the real window dates
// (noDataText); one that doesn't yet keeps the plain fallback line.
export function NoDataBlock({ sources, unlocks, howToFill, meta, windowDays }: {
  sources?: (string | { name: string; unlocks?: string | null })[] | null; unlocks?: string[] | null; howToFill?: React.ReactNode;
  meta?: Meta | null; windowDays?: number | null;
}) {
  return (
    <div className="card no-data-block">
      <div className="h-title">{windowDays ? noDataText(meta, windowDays) : "No data for this in the current window"}</div>
      {sources && sources.length > 0 && (
        <ul className="no-data-source-list">
          {sources.map((s) => {
            const name = typeof s === "string" ? s : s.name;
            const why = typeof s === "string" ? null : s.unlocks;
            return (
              <li key={name} className="no-data-source-row">
                <span className="no-data-source-name">{name}</span>
                {why && <span className="no-data-source-unlocks">{` -- unlocks ${why}`}</span>}
              </li>
            );
          })}
        </ul>
      )}
      {unlocks && unlocks.length > 0 && (
        <div className="no-data-source-unlocks" style={{ marginTop: 8 }}>
          {`Once filled, this would check: ${unlocks.join(", ")}.`}
        </div>
      )}
      {howToFill && <div className="no-data-how">{howToFill}</div>}
    </div>
  );
}

// The price basis words next to a $ ("Effective $2.85 per credit, from your invoice"): the API's own
// label, never rebuilt here. null until meta has answered.
export function priceLabelOf(meta?: Meta | null): string | null {
  const p = meta && meta.price_basis;
  return p && p.label ? p.label.charAt(0).toUpperCase() + p.label.slice(1) : null;
}

// The label next to a $: the price basis, plus the what-if discount only when the API applied one.
export function moneyBasisLabel(meta?: Meta | null, discountPct?: number | null) {
  const basis = priceLabelOf(meta);
  const eff = discountPct != null ? discountPct : (meta && meta.discount ? meta.discount.effective : 0);
  if (!basis) return estLabel(eff);
  return Number(eff) ? `${basis}; ${estLabel(eff)}` : basis;
}

// The what-if discount is applied by the API only when it is not stacked on an invoice rate; when it
// is ignored the API says why, and this shows that instead of a "what-if" label.
export function discountIgnoredReason(meta?: Meta | null) {
  const d = meta && meta.discount;
  return d && d.ignored ? d.reason : null;
}

// One line on Overview and Actions when a usage view is behind its normal latency: the newest days
// of spend are then too low. Reads the freshness check's own status; links to Coverage.
export function FreshnessLine({ findingsById, goTo }: { findingsById?: Record<string, Finding> | null; goTo?: GoToFn | null }) {
  const f = findingsById && findingsById.sf_cost_source_freshness;
  const band = f ? bandOf(f) : null;
  if (band !== "WARN" && band !== "CRITICAL") return null;
  return (
    <div className="scope-note freshness-line">
      {"A usage view is behind its normal delay, so spend for the newest days reads too low. "}
      <a href={navHref({ tab: "coverage", subtab: "sources" })} onClick={(e) => { e.preventDefault(); if (goTo) goTo({ tab: "coverage", subtab: "sources" }); }}>
        {"See source freshness →"}
      </a>
    </div>
  );
}

// PageFooter: the per-page footer line -- the data source and money basis on the left, the Guide
// on the right. Distinct from App.tsx's BrandFooter (copyright/brand, DEC-69),
// which stays at the very bottom of the shell once, not on every area page.
export function PageFooter({ meta }: { meta?: Meta | null }) {
  // The effective discount is 0 when the $/credit is the invoice rate (the API says so).
  const ignored = discountIgnoredReason(meta);
  const caveat = EST_SPEND_CAVEAT || "excludes your cloud provider's own VM bill";
  return (
    <div className="page-footer">
      <span>{`${moneyBasisLabel(meta)} · ${caveat}${ignored ? ` · discount not applied: ${ignored}` : ""}`}</span>
      <a href={navHref({ tab: "guide", subtab: null, focus: null, domain: null })}>
        How it&apos;s worked out →
      </a>
    </div>
  );
}

// A plain, honest one-line default verdict for an area/sub-tab with no registered content yet --
// real content components should pass their own richer verdict into PageIntro instead; this is
// only what AreaPage falls back to so "every area already works" (section 7).
export function genericVerdict(owned?: Row[] | null) {
  if (!owned || owned.length === 0) return "Nothing is placed on this screen yet.";
  let critical = 0, warn = 0;
  owned.forEach((f) => {
    const band = bandOf(f);
    if (band === "CRITICAL") critical += 1;
    else if (band === "WARN") warn += 1;
  });
  if (critical === 0 && warn === 0) return `${fmtInt(owned.length)} check${owned.length === 1 ? "" : "s"} in this view, nothing flagged.`;
  const parts = [];
  if (critical) parts.push(`${fmtInt(critical)} critical`);
  if (warn) parts.push(`${fmtInt(warn)} warning`);
  return `${fmtInt(owned.length)} checks in this view -- ${parts.join(", ")}.`;
}

// WindowCoverageNote: under the page title, only when the selected window is a
// PARTIAL export (GET /api/meta `windows`) -- e.g. a 10-day export read at "30d" -- so the money
// and row counts on screen are never mistaken for a full 30 days without saying so here first.
// Silent (returns null) for a fully-covered or not-yet-loaded window.
export function WindowCoverageNote({ meta, windowDays }: { meta?: Meta | null; windowDays: number }) {
  const w = meta && meta.windows && meta.windows.find((x: Row) => x.days === windowDays);
  if (!w || !w.partial) return null;
  return (
    <div className="window-coverage-note">
      {`${windowDays}d: partial, ${fmtInt(w.covered_days)} of ${fmtInt(windowDays)} days`}
    </div>
  );
}

// FallbackSourceNote: one line under the sub-tabs when any check on this screen was read from
// INFORMATION_SCHEMA (the role cannot read ACCOUNT_USAGE); each check's own limits are in the tooltip.
export function FallbackSourceNote({ findings }: { findings: Finding[] }) {
  const used = findings.filter((f) => f && f.source && f.source.source === "information_schema");
  if (!used.length) return null;
  const detail = used.map((f) => `${getCheckLabel(f.query_id).title || f.query_id}: ${(f.source && f.source.note) || "partial"}`).join("\n");
  return (
    <div className="window-coverage-note fallback-source-note" title={detail}>
      {"Some checks here read INFORMATION_SCHEMA, as this role cannot read ACCOUNT_USAGE: partial, only what the role can see and a shorter history. Hover for each check's limits."}
    </div>
  );
}

// One line naming the panels on this page that an active account or tag filter did not narrow.
export function ignoredFilterClause(prefix: string, queryIds?: string[] | null) {
  if (!queryIds || !queryIds.length) return null;
  const names: string[] = [];
  queryIds.forEach((id) => {
    const title = getCheckLabel(id).title;
    if (title && !names.includes(title)) names.push(title);
  });
  if (!names.length) return null;
  const shown = names.slice(0, 5).join(", ");
  const more = names.length > 5 ? `, +${names.length - 5} more` : "";
  return `${prefix}: ${shown}${more}.`;
}

export function FilterReachNote() {
  const { accountIds, tagIds, acctTagIds } = useIgnoredFilterSummary();
  const parts = [
    ignoredFilterClause("Not narrowed by your Account filter (covers every account)", accountIds),
    ignoredFilterClause("Not narrowed by your tag filter (covers every tag)", tagIds),
    ignoredFilterClause("Narrowed by the account's tag only (query, warehouse and object tags do not reach these rows)", acctTagIds),
    Api.ownerFilterKey() ? `Owner filter: applies only to checks whose rows carry an owner or role. Spend, warehouse idle time and other account-wide figures are not filtered by owner.` : null,
  ].filter(Boolean);
  if (!parts.length) return null;
  return <div className="scope-note">{parts.join(" ")}</div>;
}

// Where the dollars the tag filter keeps got their tag: the query, the object, the warehouse, the user or role, or the account.
/** GET /api/tag_origins: where the tag filter's dollars got their tag, per selected key. */
interface TagOrigins {
  keys: { tag_key: string; values: string[]; origins: { label: string; usd: number | null }[] }[];
  window_days: number;
  usd: number | null;
}

export function TagOriginNote({ filters }: { filters: Filters }) {
  const tagKey = Api.tagFilterKey();
  const wsKey = JSON.stringify(filters.accountIds || []);
  const [data, setData] = React.useState<TagOrigins | null>(null);
  React.useEffect(() => {
    setData(null);
    if (!tagKey) return undefined;
    let live = true;
    Api.tagOrigins(filters.window, filters.accountIds)
      .then((d: TagOrigins) => { if (live) setData(d); })
      .catch(() => {});
    return () => { live = false; };
  }, [tagKey, wsKey, filters.window]);
  if (!tagKey || !data || !data.keys || !data.keys.length) return null;
  const groups = (filters.tag && filters.tag.groups) || [];
  const lines = data.keys.map((k, i) => {
    const g = groups[i] || {};
    const vals = (g.values && g.values.length ? g.values : k.values).map((v: string) => (v === "__untagged__" ? "untagged" : v));
    const who = `${g.display_key || g.key || k.tag_key}${vals.length ? ` = ${vals.join(" or ")}` : ""}`;
    if (!k.origins.length) return `${who}: no spend in the last ${data.window_days} days.`;
    const parts = k.origins.map((o) => `${o.label} ${fmtMoney(o.usd, 0)}`).join(" · ");
    return `${who}: ${fmtMoney(data.usd, 0)} list price in the last ${data.window_days} days, by where the tag was set: ${parts}.`;
  });
  return <div className="scope-note">{lines.join(" ")}</div>;
}

// AreaPage: the generic frame every area uses (section 7) -- PageIntro + SubTabs (the active
// sub-tab lives in the hash via onSubtabChange) + the sub-tab's registered content component, if
// any + the checks table for that sub-tab's owned ids. `areaKey` is one of AREA_REGISTRY's keys
// (tab_registry.tsx). Works with zero registered content (a bare header + checks table), which is
// what makes every area "already work" before a single page agent has touched it.
/** AreaPage's props: the shell's filters and data, plus where it is and how it navigates. */
export interface AreaPageProps {
  areaKey: string;
  findings?: Finding[] | null;
  filters: Filters;
  dims?: Dims | null;
  maxCat?: any;
  meta?: Meta | null;
  allFindingsIndex?: Record<string, Finding> | null;
  onExternalJump?: any;
  initialFocusId?: string | null;
  initialSubtab?: string | null;
  onSubtabChange?: ((key: string) => void) | null;
  setManyAccounts?: any;
  goTo?: GoToFn | null;
  summaryOnly?: boolean;
  role?: string | null;
  roleAreas?: string[] | null;
}

export function AreaPage({
  areaKey, findings, filters, dims, maxCat, meta, allFindingsIndex, onExternalJump,
  initialFocusId, initialSubtab, onSubtabChange, setManyAccounts, goTo,
  // CTO role (roles/App.tsx): an area opens its summary only -- no sub-tab bar, no checks table.
  // `role`/`roleAreas` (contract H) ride into every registered Content's own props unchanged;
  // `canDrill` is false exactly when summaryOnly is (CTO's own view, the only one that sets it).
  summaryOnly, role, roleAreas,
}: AreaPageProps) {
  const area = AREA_REGISTRY[areaKey];
  if (!area) {
    return (
      <div className="honest-card error">
        <div className="h-title">Unknown area</div>
        <div className="h-note mono">{areaKey}</div>
      </div>
    );
  }
  const subtabs = visibleSubtabs(areaKey, findings);
  const validInitial = initialSubtab && subtabs.some((s) => s.key === initialSubtab) ? initialSubtab : null;
  const [subtab, setSubtabState] = React.useState(validInitial || (subtabs[0] ? subtabs[0].key : null));
  React.useEffect(() => { if (validInitial && validInitial !== subtab) setSubtabState(validInitial); }, [validInitial]);

  const onSelect = (key: string) => {
    setSubtabState(key);
    if (onSubtabChange) onSubtabChange(key);
  };

  // summaryOnly always reads the area's first sub-tab, whatever `subtab` state or a stale hash
  // says -- there is no SubTabs bar to change it away from that in this mode anyway.
  const active = summaryOnly ? (subtabs[0] || null) : (subtabs.find((s) => s.key === subtab) || subtabs[0] || null);

  // A registered Content computes its OWN real verdict sentence from data this frame never sees
  // (a roll-up page like Overview/Waste has ids:[] everywhere, so genericVerdict(ownedFindings)
  // below always has zero rows to summarise) -- it reports it up through setVerdict/onVerdict
  // (tabProps, same callback under both names); a Content that never calls either leaves
  // genericVerdict deciding as before. Resets on area/sub-tab change so a stale sentence never
  // survives a navigation.
  const [contentVerdict, setContentVerdict] = React.useState<React.ReactNode>(null);
  // A layout effect, so the reset runs before the new sub-tab's own effect sets its sentence.
  React.useLayoutEffect(() => {
    setContentVerdict(null);
    // Start each sub-tab with an empty note.
    IgnoredFilterTracker.reset();
  }, [areaKey, active ? active.key : null]);

  const ownedIds = active ? (active.ids || []) : [];
  const refIds = active ? (active.refIds || []) : (area.refIds || []);
  const allIds = React.useMemo(() => [...ownedIds, ...refIds], [ownedIds.join(","), refIds.join(",")]);
  const scopedFindings = React.useMemo(
    () => (findings || []).filter((f) => allIds.includes(f.query_id)),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [findings, allIds.join(",")]
  );
  const ownedFindings = React.useMemo(
    () => scopedFindings.filter((f) => ownedIds.includes(f.query_id)),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [scopedFindings, ownedIds.join(",")]
  );

  // The drawer: a check's "Open" (focusQueryId) opens it; leaving the sub-tab closes it.
  const drawer = useDrawer();
  const activeKey = active ? active.key : null;
  const mounted = React.useRef(false);
  React.useEffect(() => {
    if (!mounted.current) { mounted.current = true; return; }
    if (!initialFocusId) DrawerBus.close();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [areaKey, activeKey]);
  React.useEffect(() => { if (initialFocusId && !summaryOnly) DrawerBus.open({ id: initialFocusId }); }, [initialFocusId, summaryOnly]);
  const closeDrawer = React.useCallback(() => {
    DrawerBus.close();
    // Clear the focus too, so the same tile opens the drawer again.
    if (initialFocusId && goTo) goTo({ tab: areaKey, subtab: activeKey, focusQueryId: null });
  }, [initialFocusId, goTo, areaKey, activeKey]);
  const drawerFinding = !summaryOnly && drawer && allFindingsIndex ? allFindingsIndex[drawer.id] || null : null;

  // A sub-tab that owns no checks of its own (ids: []) -- Coverage & Gaps' three, or a page's own
  // "method" tab -- reads its content directly, never a checks table, so countsForIds' "no data"
  // (built for a checks-table sub-tab with real ids that simply flagged nothing) does not apply;
  // it would otherwise show "no data" on a sub-tab that is not a checks table at all.
  const subtabRows = subtabs.map((s) => {
    const counts = countsForIds(findings, s.ids, s.refIds);
    // A reference list with rows is content too: the page is not empty.
    const refHasRows = (s.refIds || []).some((id) => (findings || []).some((f) => f.query_id === id && (f.row_count ?? 0) > 0));
    // Coverage pages read the export's own record, not their checks, so they are never empty.
    const badgeable = s.ids && s.ids.length > 0 && areaKey !== "coverage";
    return { key: s.key, label: s.label, ...counts, noData: badgeable ? counts.noData && !refHasRows : false };
  });

  const Content = AreaContent.get(areaKey, active ? active.key : null);

  // Every link a summary's own Content might offer (a chart's "Open check", a next:-chip) lands on
  // the TARGET area's own summary, never a sub-tab or a finding page the CTO view cannot open --
  // this used to ignore whatever target it was given and always re-land on the current area, so a
  // Fix-first row pointing at another area's summary silently went nowhere.
  const summaryGoTo = React.useCallback((target: string | GoTo | null | undefined) => {
    if (!goTo) return;
    // A link to one check opens that check's Guide page, which the summary view can show.
    if (typeof target === "string") { goTo({ tab: "guide", focusQueryId: target }); return; }
    if (target && target.focusQueryId) { goTo({ tab: "guide", focusQueryId: target.focusQueryId }); return; }
    goTo({ tab: (target && target.tab) || areaKey, subtab: null, focusQueryId: null });
  }, [goTo, areaKey]);

  const canDrill = !summaryOnly;
  const tabProps = {
    findings: scopedFindings, filters, dims, maxCat, meta, allFindingsIndex,
    onExternalJump: summaryOnly ? summaryGoTo : onExternalJump,
    setManyAccounts,
    goTo: summaryOnly ? summaryGoTo : goTo,
    // Same callback under both names: overview_waste's Content components call setVerdict,
    // compute_jobs's call onVerdict -- both just report their own real-number sentence up.
    setVerdict: setContentVerdict, onVerdict: setContentVerdict,
    role, roleAreas, canDrill,
  };

  const scopeText = area.scope;
  const title = pageLabel(areaKey, role);
  // A sub-tab whose checks all read the account as it is says so, not "last N days".
  const snapshot = scopedFindings.length > 0 && scopedFindings.every((f: any) => f && f.windowed === false)
    ? `snapshot at export${meta && meta.as_of_date ? `, ${fmtDayShort(meta.as_of_date)}` : ""} — the ${filters.window}-day window does not apply` : null;

  return (
    <div>
      <PageIntro
        overline={pageEyebrow(role, title, meta, filters.window, snapshot)}
        title={title}
        scope={scopeText}
        // A Content reports its own richer verdict via setVerdict/onVerdict (contentVerdict), or
        // renders it inline itself (page-intro-verdict) and leaves this null -- either way this
        // fallback is only for an area/sub-tab nothing has registered yet, so a real page never
        // shows "Nothing is placed on this screen yet." above content that is very much there.
        verdict={contentVerdict != null ? contentVerdict : (Content ? null : genericVerdict(ownedFindings))}
      />
      {!summaryOnly && subtabs.length > 1 && <SubTabs tabs={subtabRows} active={active ? active.key : null} onChange={onSelect} />}
      <WindowCoverageNote meta={meta} windowDays={filters.window} />
      <FallbackSourceNote findings={areaKey === "overview" || areaKey === "actions" ? (findings || []) : scopedFindings} />
      {(areaKey === "overview" || areaKey === "actions") && <FreshnessLine findingsById={allFindingsIndex} goTo={goTo} />}
      <FilterReachNote />
      {areaKey === "cost" && <TagOriginNote filters={filters} />}
      {!summaryOnly && <TabScopeNote findings={scopedFindings} meta={meta} filters={filters} />}
      <div className={`dr-layout${drawerFinding ? " open" : ""}`}>
        <div className="dr-main">
          {!summaryOnly && ownedFindings.length > 0 && <CoverageStrip findings={ownedFindings} goTo={goTo} />}
          {Content && <ErrorBoundary><Content {...tabProps} /></ErrorBoundary>}
          {!summaryOnly && areaKey !== "overview" && (allIds.length > 0 ? (
            <React.Fragment>
              <ChecksList key={`${areaKey}:${active ? active.key : ""}`} findings={scopedFindings} refIds={refIds}
                filters={filters} meta={meta} goTo={goTo} openId={drawer ? drawer.id : null} />
              <NotJudgedStrip findings={ownedFindings} goTo={goTo} />
            </React.Fragment>
          ) : (!Content && (
            <div className="card"><span className="muted">Nothing is placed on this screen yet.</span></div>
          )))}
        </div>
        {drawerFinding && drawer && (
          <ErrorBoundary>
            <CheckDrawer target={drawer} finding={drawerFinding} filters={filters} goTo={goTo} onClose={closeDrawer}
              areaLabel={area.label} findingsIndex={allFindingsIndex} meta={meta} />
          </ErrorBoundary>
        )}
      </div>
      <PageFooter meta={meta} />
    </div>
  );
}
