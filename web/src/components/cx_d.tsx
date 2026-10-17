// web/src/components/cx_d.tsx -- the look blocks the All findings, Coverage, Guide, DE Overview and
// Queries pages share: ranked label-above-bar rows with full names, one fixed-column table, the
// grouped checks table, status tabs, a dashed empty strip and one duration format.
import React from "react";
import { fmtInt, fmtMoneyOf } from "../format";
import { getCheckLabel } from "./labels";
import { moneyKindOf } from "./waste_total";
import { navHref } from "./nav_hash";
import { AREA_REGISTRY, homeForQuery } from "./tab_registry";
import { TAB_ORDER } from "./findings_table";
import type { Finding, GoToFn, Row } from "../types";
import { GuideHelp } from "./guide_links";

/** "25 h 9 m", "48 m 9 s", "1 h", "27 s": no zero parts, no padding; never broken across lines. */
export function fmtDur(seconds: unknown): string {
  const v = Number(seconds);
  if (seconds == null || seconds === "" || !Number.isFinite(v)) return "–";
  const t = Math.round(v);
  let out: string;
  if (v > 0 && t < 1) out = "<1 s";
  else if (t < 60) out = `${t} s`;
  else if (t < 3600) { const m = Math.floor(t / 60), s = t % 60; out = s ? `${m} m ${s} s` : `${m} m`; }
  else { const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60); out = m ? `${h} h ${m} m` : `${h} h`; }
  return out.replace(/ /g, " ");
}

/** A status word's dot class: crit, warn, ok, na (not assessed) or ref. */
export function dotOf(status: unknown): string {
  const s = String(status || "").toUpperCase();
  // An empty status keeps the dot's space, so names still line up.
  if (s === "") return "none";
  if (s === "CRITICAL" || s === "CRIT") return "crit";
  if (s === "WARN" || s === "WARNING") return "warn";
  if (s === "OK" || s === "RANKED") return "ok";
  if (s === "NOT_ASSESSED" || s === "ERROR" || s === "COULDNT") return "na";
  return "ref";
}
export function Dot({ status }: { status?: unknown }) {
  return <span className={`cxd-dot ${dotOf(status)}`} aria-hidden="true" />;
}

// ═══════════════════════ Ranked bars, label above the bar ═══════════════════════

export interface CxBarItem {
  key: string;
  name: React.ReactNode;
  value: number;
  /** The bold figure on the right, e.g. "$1,293". */
  valueText?: React.ReactNode;
  /** Muted words after the figure, e.g. "93% scanned · 240 runs". */
  extra?: React.ReactNode;
  /** A line under the bar. */
  sub?: React.ReactNode;
  status?: unknown;
  hatched?: boolean;
  /** A fill other than the one series colour, e.g. var(--c-other) for "Other". */
  color?: string;
}

/** Ranked bars with the full name above each bar; scaled to the largest shown (or `max`). The tail is counted, never dropped. */
export function CxBars({ items, n = 8, max, onClick, noun = "rows", emptyText, ariaLabel, dots = true }: {
  items: CxBarItem[]; n?: number; max?: number; onClick?: ((it: CxBarItem) => void) | null; noun?: string;
  emptyText?: string; ariaLabel?: string; dots?: boolean;
}) {
  const [all, setAll] = React.useState(false);
  if (!items.length) return <div className="chart-note-oneline">{emptyText || "Nothing to show."}</div>;
  const shown = all ? items : items.slice(0, n);
  const top = max != null ? max : Math.max(0, ...items.map((it) => it.value));
  return (
    <div className="cxd-bars" role="list" aria-label={ariaLabel}>
      {shown.map((it) => {
        const w = top > 0 ? Math.max(it.value > 0 ? 1 : 0, Math.min(100, (100 * it.value) / top)) : 0;
        const body = (
          <>
            <span className="cxd-bar-head">
              <span className="cxd-bar-name">{dots && it.status !== undefined && <Dot status={it.status} />}{it.name}</span>
              <span className="cxd-bar-val">{it.valueText != null && <b>{it.valueText}</b>}{it.extra != null && <>{it.valueText != null ? " · " : ""}{it.extra}</>}</span>
            </span>
            <span className="cxd-track"><span className={`cxd-fill${it.hatched ? " hatched" : ""}`} style={{ width: `${w}%`, background: it.color }} /></span>
            {it.sub != null && <span className="cxd-bar-sub">{it.sub}</span>}
          </>
        );
        return onClick
          ? <button type="button" role="listitem" key={it.key} className="cxd-bar-row click" onClick={() => onClick(it)}>{body}</button>
          : <div role="listitem" key={it.key} className="cxd-bar-row">{body}</div>;
      })}
      {items.length > n && (
        <div className="cxd-foot">
          {`${fmtInt(shown.length)} of ${fmtInt(items.length)} ${noun} shown · `}
          <button type="button" className="ck-link" onClick={() => setAll(!all)}>{all ? "Show fewer" : `${fmtInt(items.length - n)} more →`}</button>
        </div>
      )}
    </div>
  );
}

// ═══════════════════════ One table ═══════════════════════

export interface CxCol { label: React.ReactNode; num?: boolean; cls?: string; width?: string }
export interface CxRow { key: string; cells?: React.ReactNode[]; status?: unknown; onOpen?: (() => void) | null; group?: React.ReactNode; title?: string }

/** A bar inside a table cell: fixed track, scaled to `max`. */
export function CxCellBar({ value, max, hatched, color }: { value: number; max: number; hatched?: boolean; color?: string }) {
  const w = max > 0 ? Math.max(value > 0 ? 1 : 0, Math.min(100, (100 * value) / max)) : 0;
  return <span className="cxd-track in-cell"><span className={`cxd-fill${hatched ? " hatched" : ""}`} style={{ width: `${w}%`, background: hatched ? undefined : color }} /></span>;
}

/** Header 11px uppercase; rows 12px padding; numbers right-aligned; a status dot before the first cell; scrolls inside its own box. */
export function CxTable({ cols, rows, n, aria, noun = "rows", foot }: {
  cols: CxCol[]; rows: CxRow[]; n?: number; aria: string; noun?: string; foot?: React.ReactNode;
}) {
  const [all, setAll] = React.useState(false);
  const data = rows.filter((r) => !r.group);
  const limit = n && !all ? n : Infinity;
  let seen = 0;
  const shown = rows.filter((r) => (r.group ? true : (seen += 1) <= limit));
  return (
    <div>
      <div className="cxd-scroll">
        <table className="cxd-tbl" aria-label={aria}>
          <thead>
            <tr>{cols.map((c, i) => <th key={i} scope="col" className={[c.num ? "num" : "", c.cls || ""].join(" ").trim() || undefined} style={c.width ? { width: c.width } : undefined}>{c.label}</th>)}</tr>
          </thead>
          <tbody>
            {shown.map((r) => r.group ? (
              <tr key={r.key} className="group"><td colSpan={cols.length}>{r.group}</td></tr>
            ) : (
              <tr key={r.key} className={r.onOpen ? "click" : undefined} title={r.title}
                onClick={r.onOpen || undefined} tabIndex={r.onOpen ? 0 : undefined}
                onKeyDown={r.onOpen ? (e) => { if (e.key === "Enter") r.onOpen!(); } : undefined}>
                {(r.cells || []).map((c, i) => (
                  <td key={i} className={[cols[i] && cols[i].num ? "num" : "", cols[i] && cols[i].cls ? cols[i].cls : ""].join(" ").trim() || undefined}>
                    {i === 0 && r.status !== undefined ? <span className="cxd-first"><Dot status={r.status} /><span>{c}</span></span> : c}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {((n && data.length > n) || foot) && (
        <div className="cxd-foot">
          {n && data.length > n ? (
            <>
              {`${fmtInt(Math.min(n, data.length) === data.length || all ? data.length : n)} of ${fmtInt(data.length)} ${noun} shown · `}
              <button type="button" className="ck-link" onClick={() => setAll(!all)}>{all ? "Show fewer" : `${fmtInt(data.length - n)} more →`}</button>
            </>
          ) : null}
          {foot}
        </div>
      )}
    </div>
  );
}

/** A dashed one-line strip for a chart that has no data: title, reason, and an optional fix line. No controls. */
export function CxEmpty({ title, reason, fix }: { title?: React.ReactNode; reason: React.ReactNode; fix?: React.ReactNode }) {
  return (
    <div className="cxd-empty">
      {title && <span className="cxd-empty-title">{title}</span>}
      <span className="cxd-empty-reason">{reason}</span>
      {fix && <div className="cxd-empty-fix">{fix}</div>}
    </div>
  );
}

// ═══════════════════════ Status tabs ═══════════════════════

const TAB_WORD: Record<string, string> = { CRITICAL: "Critical", WARN: "Warning", OK: "OK", COULDNT: "Not assessed", NODATA: "No data", REFERENCE: "Reference" };

/** Pills with a dot, the status word and its count; an empty "No data" pill is left out. */
export function CxStatusTabs({ counts, active, onChange }: { counts: Record<string, number>; active: string; onChange: (key: string) => void }) {
  return (
    <div className="cxd-tabs" role="tablist">
      {TAB_ORDER.filter((k) => counts[k] || k === active || k !== "NODATA").map((k) => (
        <button key={k} type="button" role="tab" aria-selected={active === k}
          className={`cxd-tab${active === k ? " active" : ""}${k === "COULDNT" ? " dashed" : ""}${!counts[k] ? " zero" : ""}`} onClick={() => onChange(k)}
          aria-label={`${TAB_WORD[k]}, ${fmtInt(counts[k] || 0)}`}>
          {k !== "COULDNT" && <Dot status={k === "REFERENCE" || k === "NODATA" ? "REF" : k} />}
          {TAB_WORD[k]} <span className="cxd-tab-n">{fmtInt(counts[k] || 0)}</span>
        </button>
      ))}
    </div>
  );
}

// ═══════════════════════ Checks table ═══════════════════════

/** A check's status word, the same everywhere. */
export function bandWord(band: string, pill?: string): string {
  if (pill === "reference") return "Reference";
  if (band === "CRITICAL") return "Critical";
  if (band === "WARN") return "Warning";
  if (band === "NOT_ASSESSED" || band === "ERROR") return "Not assessed";
  if (band === "EMPTY_WINDOW" || band === "EMPTY_FILTERS") return "No data";
  if (band === "INVENTORY") return "Reference";
  return "OK";
}

// Kinds that are an impact (waste, saving, storage), against kinds that are spend in scope.
const IMPACT_KIND_WORD: Record<string, string> = { waste: "waste", saving: "saving", saving_month: "saving / month", spend_month: "storage / month" };

export function afHomeOf(row: Row) {
  const home = homeForQuery(row);
  const area = AREA_REGISTRY[home.tab];
  if (!area || home.tab === "findings") return null;
  const sub = (area.subtabs || []).find((s) => s.key === home.subtab);
  return { tab: home.tab, subtab: home.subtab, text: sub ? `${area.label} › ${sub.label}` : area.label };
}

interface CkEntry { row: Row; band: string; pill?: string }

function usdOf(row: Row): number | null {
  const m = row.money;
  if (!m || row.money_reason === "unpriced" || m.mixed_currency) return null;
  const v = Number(m.usd);
  return m.usd != null && Number.isFinite(v) ? v : null;
}

/** SEVERITY · CHECK · FOUND · IMPACT · SPEND IN SCOPE · WHERE, grouped Priced, Not priced, Reference. */
export function CxChecksTable({ rows, goTo, n = 12, title, sub, right, summary, impactWord = "Impact · 30 d" }: {
  rows: CkEntry[]; goTo: GoToFn; n?: number; title: React.ReactNode; sub?: React.ReactNode; right?: React.ReactNode;
  summary?: React.ReactNode; impactWord?: string;
}) {
  const [all, setAll] = React.useState(false);
  React.useEffect(() => { setAll(false); }, [rows]);
  const isRef = (e: CkEntry) => e.pill === "reference" || e.band === "INVENTORY";
  const kind = (e: CkEntry) => moneyKindOf(e.row as Finding) as string | null;
  const priced = rows.filter((e) => !isRef(e) && kind(e) && IMPACT_KIND_WORD[kind(e)!] && (usdOf(e.row) || 0) > 0)
    .sort((a, b) => (usdOf(b.row) || 0) - (usdOf(a.row) || 0));
  const pricedSet = new Set(priced);
  const spendOf = (e: CkEntry) => (pricedSet.has(e) ? null : usdOf(e.row));
  const notPriced = rows.filter((e) => !isRef(e) && !pricedSet.has(e)).sort((a, b) => (spendOf(b) ?? -1) - (spendOf(a) ?? -1));
  const refs = rows.filter(isRef);
  const maxImpact = Math.max(0, ...priced.map((e) => usdOf(e.row) || 0));
  const order = [...priced, ...notPriced, ...refs];
  const shownSet = new Set(all ? order : order.slice(0, n));

  const found = (e: CkEntry) => {
    const r = e.row, a = r.affected;
    if (e.band === "NOT_ASSESSED" || e.band === "ERROR") return <span className="muted">{(r.not_assessed && r.not_assessed.label) || "did not run"}</span>;
    if (e.band === "EMPTY_WINDOW") return <span className="muted">no data in this window</span>;
    if (e.band === "EMPTY_FILTERS") return <span className="muted">excluded by the filters</span>;
    if (a) {
      const total = Math.max(Number(a.total) || 0, Number(a.flagged) || 0);
      return (
        <span>{a.flagged ? `${fmtInt(a.flagged)} of ${fmtInt(total)} ${a.noun}` : `${fmtInt(total)} ${a.noun}`}
          {a.flagged_other > 0 && <span className="cxd-sub">{`+ ${fmtInt(a.flagged_other)} more flagged row${a.flagged_other === 1 ? "" : "s"}`}</span>}
        </span>
      );
    }
    return r.row_count != null ? `${fmtInt(r.row_count)} row${Number(r.row_count) === 1 ? "" : "s"}` : "–";
  };
  const impact = (e: CkEntry) => {
    const k = kind(e);
    if (pricedSet.has(e)) {
      const v = usdOf(e.row) || 0;
      return (
        <span className="cxd-impact">
          <CxCellBar value={v} max={maxImpact} />
          <b className="num">{fmtMoneyOf(e.row.money, v, 0)}</b>
          <span className="cxd-kind">{IMPACT_KIND_WORD[k!]}</span>
        </span>
      );
    }
    if (isRef(e)) return <span className="muted">Reference — not scored</span>;
    if (e.band === "NOT_ASSESSED" || e.band === "ERROR") return <span className="muted">–</span>;
    if (e.row.money_reason === "unpriced") return <span className="muted">Not priced — no price in this export</span>;
    if (k === "change") return <span className="muted">Not priced — a change vs the previous period</span>;
    if (k && ["spend", "context", "gap", "balance"].includes(k)) return <span className="muted">Not priced — context only</span>;
    return <span className="muted">Not priced — risk, not dollars</span>;
  };
  const spend = (e: CkEntry) => {
    const v = spendOf(e);
    if (v == null) return <span className="muted">—</span>;
    const m = e.row.money, a = e.row.affected;
    const k = kind(e);
    const across = m && m.basis === "all" && a && a.flagged < a.total ? `across all ${fmtInt(a.total)}` : k === "change" ? "change" : null;
    return <span>{fmtMoneyOf(m, v, 0)}{across && <span className="cxd-sub">{across}</span>}</span>;
  };
  const where = (e: CkEntry) => {
    const home = afHomeOf(e.row);
    if (!home) return <span className="muted">This page</span>;
    return (
      <a className="cxd-where" href={navHref({ tab: home.tab, subtab: home.subtab, focus: e.row.query_id })}
        onClick={(ev) => { ev.preventDefault(); ev.stopPropagation(); goTo({ tab: home.tab, subtab: home.subtab, focusQueryId: e.row.query_id }); }}>
        {`${home.text} →`}
      </a>
    );
  };
  const tableRows: CxRow[] = [];
  const add = (label: string, list: CkEntry[]) => {
    const vis = list.filter((e) => shownSet.has(e));
    if (!vis.length) return;
    tableRows.push({ key: `g-${label}`, group: `${label} · ${vis.length < list.length ? `${fmtInt(vis.length)} of ${fmtInt(list.length)} shown` : fmtInt(list.length)}` });
    vis.forEach((e) => {
      const name = getCheckLabel(e.row.query_id, e.row.title).title;
      tableRows.push({
        key: e.row.query_id,
        cells: [<span key="s" className={`cxd-sev ${dotOf(isRef(e) ? "REF" : e.band)}`}><Dot status={isRef(e) ? "REF" : e.band} />{bandWord(e.band, e.pill)}</span>,
          <span key="n">{name} <GuideHelp id={e.row.query_id} label={name} /></span>, found(e), impact(e), spend(e), where(e)],
      });
    });
  };
  add("Priced", priced);
  add("Not priced", notPriced);
  add("Reference", refs);
  return (
    <div className="card ck-card cxd-checks">
      <div className="cxd-card-head">
        <div>
          <div className="card-title">{title}</div>
          {sub && <div className="cxd-card-sub">{sub}</div>}
        </div>
        {right && <div className="cxd-card-right">{right}</div>}
      </div>
      {rows.length ? (
        <CxTable aria="Checks" rows={tableRows}
          cols={[{ label: "Severity", cls: "c-sev" }, { label: "Check", cls: "c-check" }, { label: "Found", cls: "c-found" }, { label: impactWord, cls: "c-impact" }, { label: "Spend in scope", num: true, cls: "c-spend" }, { label: "Where", cls: "c-where" }]} />
      ) : null}
      {(order.length > n || summary) && (
        <div className="cxd-foot cxd-checks-foot">
          {order.length > n ? <button type="button" className="ck-link" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show all ${fmtInt(order.length)}`}</button> : <span />}
          {summary}
        </div>
      )}
    </div>
  );
}
