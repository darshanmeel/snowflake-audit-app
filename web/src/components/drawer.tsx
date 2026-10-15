// web/src/components/drawer.tsx -- the drill-down drawer: one check (or one object of it) beside the
// page at desktop width, a bottom sheet on a phone. Chips, a title, a mono base line, one figure box
// per money kind (never summed), the check's own fix text, the worst rows and links. The open check
// lives in the URL hash (open=<id>), so a view with its drawer open can be shared.
import React from "react";
import { fmtInt, fmtMoneyOf, isNumericValue } from "../format";
import { HashState } from "./hash_state";
import { useNames } from "./names";
import { useFindingData } from "./hooks";
import { KindChip, StatusPill, bandOf, bandPillKind } from "./primitives";
import { getCheckLabel } from "./labels";
import { planColumns } from "./columns";
import { firstAction } from "./overview_tile";
import { moneyKindOf } from "./waste_total";
import { NameId } from "./blocks_2";
import { DRAWER_BLOCKS } from "./drawer_blocks";
import { FixSection } from "./fixcopy_button";
import {
  EmptyFiltersCard, EmptyWindowCard, ErrorCard, FindingDetail, NotAssessedCard, RowsCsvButton,
  buildEntitySummary, findDayColumn, metricValueText, sortEntityGroups, statusColorVar, tallyStatusCounts,
} from "./finding_detail";
import type { FindingData } from "./finding_detail";
import type { FetchState, Filters, Finding, GoToFn, Meta, Row } from "../types";

/** What the drawer shows: a check, optionally narrowed to the rows where `col` equals `val`. */
export interface DrawerTarget { id: string; col?: string | null; val?: string | null; label?: string | null }

// One open drawer for the whole app, mirrored to the hash so a pasted link reopens it.
export const DrawerBus = (function () {
  function read(): DrawerTarget | null {
    try {
      const p = HashState.get();
      const id = p.get("open");
      return id ? { id, col: p.get("ocol"), val: p.get("oval"), label: p.get("olabel") } : null;
    } catch (e) { return null; }
  }
  let cur: DrawerTarget | null = read();
  const subs = new Set<() => void>();
  function emit() {
    try { HashState.set({ open: cur ? cur.id : null, ocol: cur && cur.col, oval: cur && cur.val, olabel: cur && cur.label }); } catch (e) { /* no hash here */ }
    subs.forEach((f) => f());
  }
  return {
    get: () => cur,
    open(t: DrawerTarget) { cur = { ...t }; emit(); },
    close() { if (!cur) return; cur = null; emit(); },
    subscribe(f: () => void) { subs.add(f); return () => { subs.delete(f); }; },
  };
})();

export function useDrawer(): DrawerTarget | null {
  return React.useSyncExternalStore(DrawerBus.subscribe, DrawerBus.get, DrawerBus.get);
}

/** A check's own detail block, drawn under the figures (one warehouse's idle options, say). */
export interface DrawerBlockProps { target: DrawerTarget; filters: Filters; meta?: Meta | null; finding: Finding | null }

const KIND_WORD: Record<string, string> = {
  waste: "Possible waste", saving: "Possible saving", saving_month: "Possible saving per month", spend: "Spend",
  spend_month: "Storage per month", change: "Change vs previous period", gap: "Gap", balance: "Balance", context: "Context, not counted",
};

function FigBox({ eyebrow, value, sub, missing }: { eyebrow: string; value?: React.ReactNode; sub?: React.ReactNode; missing?: boolean }) {
  return (
    <div className={`dr-fig${missing ? " is-missing" : ""}`}>
      <div className="dr-eyebrow">{eyebrow}</div>
      <div className="dr-fig-value">{missing ? "–" : value}</div>
      {sub && <div className="dr-fig-sub">{sub}</div>}
    </div>
  );
}

export interface CheckDrawerProps {
  target: DrawerTarget;
  finding: Finding | null;
  filters: Filters;
  goTo?: GoToFn | null;
  areaLabel?: string | null;
  onClose: () => void;
  findingsIndex?: Record<string, Row> | null;
  meta?: Meta | null;
  /** An optional block under the figures: a CompareToBaseline or a mini chart. */
  children?: React.ReactNode;
}

export function CheckDrawer({ target, finding, filters, goTo, areaLabel, onClose, findingsIndex, meta, children }: CheckDrawerProps) {
  useNames();
  const state = useFindingData(target.id, filters.window, filters.accountIds, 5000) as FetchState<FindingData>;
  const [allRows, setAllRows] = React.useState(false);
  const closeRef = React.useRef<HTMLButtonElement | null>(null);
  const key = `${target.id}|${target.col || ""}|${target.val || ""}`;
  React.useEffect(() => { setAllRows(false); if (closeRef.current) closeRef.current.focus(); }, [key]);
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const data = state.phase === "ready" ? state.data : null;
  const okRows = !!data && data.outcome === "ok_rows";
  const cols = okRows ? (data!.columns || []) : [];
  const allLoaded: Row[] = okRows ? (data!.rows || []) : [];
  const narrowed = !!(target.col && target.val != null);
  const rows = narrowed ? allLoaded.filter((r) => r[target.col!] != null && String(r[target.col!]) === target.val) : allLoaded;
  const plan = React.useMemo(() => planColumns(cols, rows, data && data.discount_pct, data && data.order_by, data && data.query_id),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [data, key]);
  const hasStatus = cols.some((c) => c.name === "status");
  const dayCol = findDayColumn(cols);
  const summary = React.useMemo(() => (okRows ? buildEntitySummary(rows, plan, hasStatus, dayCol) : null),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [plan, okRows]);

  const label = getCheckLabel(target.id, (finding && finding.title) || (data && data.header && data.header.title));
  const band = narrowed && okRows
    ? bandOf({ outcome: "ok_rows", status_counts: hasStatus ? tallyStatusCounts(rows) : null, query_id: target.id })
    : finding ? bandOf(finding) : data ? bandOf({ outcome: data.outcome, status_counts: null, query_id: target.id }) : null;
  const m = finding ? finding.money : null;
  const kind = moneyKindOf(finding);
  const a = finding ? finding.affected : null;
  const windowWord = finding && finding.windowed === false ? "snapshot" : `last ${fmtInt(filters.window)} days`;

  // The figure boxes: one per money kind, a count beside them, never a sum of the two.
  const figs: React.ReactNode[] = [];
  const notRun = band === "NOT_ASSESSED" || band === "ERROR";
  if (notRun) {
    // Rows came back but none could be judged (e.g. no price): the check ran, so never "did not run".
    const rowReasons = okRows ? Array.from(new Set(rows.map((r) => r.not_assessed_reason).filter(Boolean).map(String))) : [];
    const ranSub = rowReasons.length === 1 && rowReasons[0] === "unpriced" ? "ran · not priced: no credit price in this export"
      : `ran · its rows could not be judged${rowReasons.length === 1 ? `: ${rowReasons[0].replace(/_/g, " ")}` : ""}`;
    figs.push(<FigBox key="na" eyebrow="Not assessed" missing sub={(finding && finding.not_assessed && finding.not_assessed.label) || (okRows ? ranSub : "this check did not run")} />);
  } else if (m && kind) {
    const word = KIND_WORD[kind] || kind;
    if (finding!.money_reason === "unpriced") figs.push(<FigBox key="m" eyebrow={word} missing sub="not priced" />);
    else if (m.mixed_currency) figs.push(<FigBox key="m" eyebrow={word} missing sub="more than one currency: not added" />);
    else if (narrowed) {
      // The same column and rows the chart bar was drawn from.
      const valueCol = m.column && cols.some((c) => c.name === m.column) ? m.column : null;
      const disc = data && m.unit !== "currency" ? Number(data.discount_pct) || 0 : 0;
      const counted = rows.filter((r) => !r.is_total_row && (m.basis !== "flagged" || r.status === "CRITICAL" || r.status === "WARN"));
      const sum = valueCol ? counted.reduce((s, r) => s + (isNumericValue(r[valueCol]) ? Number(r[valueCol]) : 0), 0) * (1 - disc) : null;
      if (okRows && sum != null) figs.push(<FigBox key="m" eyebrow={word} value={fmtMoneyOf(m, sum, 0)} sub={`${windowWord} · this object`} />);
    } else if (isNumericValue(m.usd)) {
      const part = m.basis === "all" && m.usd_flagged != null && a && a.flagged > 0 && a.flagged < a.total;
      figs.push(<FigBox key="m" eyebrow={word} value={fmtMoneyOf(m, m.usd, 0)}
        sub={part ? `${fmtMoneyOf(m, m.usd_flagged, 0)} on the flagged ${a.noun} · ${windowWord}` : windowWord} />);
    }
  }
  if (!notRun && a && !narrowed) {
    figs.push(<FigBox key="n" eyebrow="Flagged" value={`${fmtInt(a.flagged)} of ${fmtInt(a.total)}`} sub={a.noun} />);
  }

  const baseLine = notRun ? null : narrowed
    ? (okRows ? `${fmtInt(rows.length)} row${rows.length === 1 ? "" : "s"} · ${label.title} · ${windowWord}` : null)
    : [a ? `${fmtInt(a.flagged)} of ${fmtInt(a.total)} ${a.noun} flagged` : finding && finding.row_count != null ? `${fmtInt(finding.row_count)} rows` : null, windowWord].filter(Boolean).join(" · ");
  const fix = data && data.header ? firstAction(data.header) : null;
  const worst = summary && summary.list.length > 1 ? sortEntityGroups(summary.list, plan.keyMetric, hasStatus).slice(0, 5) : [];
  const noun = (plan.entityNoun && plan.entityNoun.p) || "objects";

  return (
    <aside className="dr" aria-label={`${label.title}: detail`}>
      <div className="dr-head">
        <div className="dr-chips">
          {areaLabel && <KindChip>{areaLabel}</KindChip>}
          {kind && <KindChip>{(KIND_WORD[kind] || kind).replace(/ per month| vs previous period|, not counted/, "")}</KindChip>}
          {band && <StatusPill kind={bandPillKind(band)} word={band === "EMPTY_WINDOW" || band === "EMPTY_FILTERS" ? "No data" : undefined} />}
        </div>
        <button type="button" ref={closeRef} className="dr-close" aria-label="Close" onClick={onClose}>×</button>
      </div>
      <h2 className="dr-title">{narrowed && target.label ? target.label : label.title}</h2>
      {baseLine && <div className="dr-base">{baseLine}</div>}
      {state.phase === "loading" && <div className="dr-loading">…</div>}
      {state.phase === "error" && <div className="dr-note">{`Could not load this check: ${state.error || "unknown error"}`}</div>}
      {figs.length > 0 && <div className="dr-figs">{figs}</div>}
      {DRAWER_BLOCKS[target.id] && React.createElement(DRAWER_BLOCKS[target.id] as React.ComponentType<DrawerBlockProps>, { target, filters, meta, finding })}
      {children}
      {data && data.outcome === "not_assessed" && <NotAssessedCard data={data} row={finding} />}
      {data && data.outcome === "error" && <ErrorCard data={data} />}
      {data && data.outcome === "ok_empty_window" && <EmptyWindowCard data={data} />}
      {data && data.outcome === "ok_empty_filters" && <EmptyFiltersCard data={data} />}
      {okRows && fix && <FixSection text={fix.full} />}
      {okRows && worst.length > 0 && (
        <div className="dr-section">
          <div className="dr-eyebrow">{`Where · worst ${fmtInt(worst.length)} of ${fmtInt(summary!.list.length)} ${noun}`}</div>
          <div className="dr-where" role="list">
            {worst.map((g) => {
              const v = metricValueText(plan.keyMetric, g.agg);
              return (
                <div key={g.mapKey} className="dr-where-row" role="listitem">
                  {hasStatus && <span className="dr-dot" style={{ background: statusColorVar(g.worstStatus) }} aria-hidden="true" />}
                  <span className="dr-where-name">{summary!.refKind && !g.noEntity
                    ? <NameId name={g.name || String(g.id)} id={g.id} />
                    : <span>{g.name || String(g.id)}</span>}</span>
                  <span className="dr-where-val">{v || `${fmtInt(g.count)} rows`}</span>
                </div>
              );
            })}
          </div>
        </div>
      )}
      <div className="dr-links">
        {okRows && <button type="button" className="dr-link" onClick={() => setAllRows((x) => !x)}>{allRows ? "Hide rows" : `All ${fmtInt(data!.rows_total)} rows →`}</button>}
        {okRows && <RowsCsvButton queryId={target.id} windowDays={filters.window} accountIds={filters.accountIds} className="dr-link" label="CSV" />}
        {goTo && <button type="button" className="dr-link" onClick={() => goTo({ tab: "guide", focusQueryId: target.id })}>{"How it's worked out →"}</button>}
      </div>
      {allRows && (
        <div className="dr-rows">
          <FindingDetail queryId={target.id} windowDays={filters.window} accountIds={filters.accountIds}
            onJumpTo={(id) => DrawerBus.open({ id })} findingsIndex={findingsIndex} />
        </div>
      )}
    </aside>
  );
}
