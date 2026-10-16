// web/src/tabs/tab_findings.tsx -- "All findings": every check the app runs, one list. Status tabs, a
// search and area chips, then what came out critical by area and the possible waste the critical
// checks name, then the grouped checks table (severity · check · found · impact · spend · where).
// Registers into the "findings" area (no sub-tabs, no ids of its own) and reads every check through allFindingsIndex.
import React from "react";
import { fmtInt, fmtMoney } from "../format";
import { AREA_ORDER, AREA_REGISTRY, homeForQuery } from "../components/tab_registry";
import { ChartCard, bandOf, ranCountsOf } from "../components/primitives";
import { AreaContent } from "../area_content";
import { getCheckLabel } from "../components/labels";
import { TAB_ORDER, csvField, findingSearchText, sortByWasteThenMoney, statusText, tabOf } from "../components/findings_table";
import { buildWasteWorklist, moneyKindOf } from "../components/waste_total";
import { fmtShare, pctOf } from "../components/blocks";
import { CxBars, CxChecksTable, CxStatusTabs, Dot } from "../components/cx_d";
import { LENS_LABEL } from "../components/lens_nav";
import { MONEY_KIND_WORD } from "./tab_area";
import "../styles/css/p_area_governance.css";
import { CONTENT_AREAS } from "../App";
import type { Filters, Finding, GoToFn, Meta, Row } from "../types";

export const AF_HOME_AREAS = AREA_ORDER.filter((k) => !["overview", "waste", "findings", "coverage"].includes(k));
export const AF_REFERENCE_IDS = (function () {
  const set = new Set<string>();
  ["overview", "coverage", ...AF_HOME_AREAS].forEach((key) => {
    const area = AREA_REGISTRY[key];
    if (!area) return;
    (area.refIds || []).forEach((id: string) => set.add(id));
    (area.subtabs || []).forEach((s) => (s.refIds || []).forEach((id: string) => set.add(id)));
  });
  return set;
})();

const AF_PAGE_SIZE = 12;

export function afHome(row: Row) {
  const home = homeForQuery(row);
  const area = AREA_REGISTRY[home.tab];
  if (!area || home.tab === "findings") return null;
  const sub = (area.subtabs || []).find((s) => s.key === home.subtab);
  return { tab: home.tab, subtab: home.subtab, text: sub ? `${area.label} › ${sub.label}` : area.label };
}

// The lede: a lens that shows only some areas counts its own checks and says so; the whole account
// leads with the API's one checks-that-ran count (meta.checks_ran).
export function afVerdict(counts: Record<string, number>, total: number, windowDays: number, lensOnly: boolean, ranMeta: { assessed: number; total: number; unit: string } | null | undefined, lens?: string | null): React.ReactNode {
  if (total === 0) return "No checks are in scope for the current filters.";
  if (!lensOnly && !ranMeta) return "…";
  const head = lensOnly
    ? <>{`The ${lens || "current"} lens has `}<b>{`${fmtInt(total)} checks`}</b>{` on the last ${windowDays} days.`}</>
    : <><b>{`${fmtInt(ranMeta!.assessed)} of ${fmtInt(ranMeta!.total)} ${ranMeta!.unit}`}</b>{` ran on the last ${windowDays} days.`}</>;
  const crit = counts.CRITICAL || 0, warn = counts.WARN || 0;
  const mid = crit || warn
    ? <>{" "}{crit ? <b>{`${fmtInt(crit)} ${crit === 1 ? "is" : "are"} critical`}</b> : null}{crit && warn ? " and " : ""}{warn ? `${fmtInt(warn)} ${warn === 1 ? "is a warning" : "are warnings"}` : ""}{" — look at those first."}</>
    : " Nothing is critical or a warning right now.";
  const ref = counts.REFERENCE || 0;
  const tail = ` ${fmtInt(counts.COULDNT || 0)} could not run, and ${fmtInt(ref)} reference check${ref === 1 ? " is" : "s are"} kept apart.`;
  return <>{head}{mid}{tail}</>;
}

type AfEntry = { row: Row; band: string; tab: string; homeArea: string; searchText: string };
const SC_PARTS: { key: "crit" | "warn" | "ok" | "nd" | "na"; cls: string; word: string }[] = [
  { key: "crit", cls: "crit", word: "critical" }, { key: "warn", cls: "warn", word: "warning" }, { key: "ok", cls: "ok", word: "OK" },
  { key: "nd", cls: "ref", word: "no data" }, { key: "na", cls: "na", word: "not assessed" },
];

/** Checks per home area: bar length is the number of checks, split crit / warn / OK / no data / not assessed; highest share critical first. */
function CriticalByArea({ entries, onArea }: { entries: AfEntry[]; onArea: (area: string) => void }) {
  const by = new Map<string, { crit: number; warn: number; ok: number; nd: number; na: number }>();
  entries.filter((e) => e.tab !== "REFERENCE").forEach((e) => {
    const c = by.get(e.homeArea) || { crit: 0, warn: 0, ok: 0, nd: 0, na: 0 };
    if (e.band === "CRITICAL") c.crit += 1;
    else if (e.band === "WARN") c.warn += 1;
    else if (e.band === "NOT_ASSESSED" || e.band === "ERROR") c.na += 1;
    else if (e.band === "EMPTY_WINDOW" || e.band === "EMPTY_FILTERS") c.nd += 1;
    else c.ok += 1;
    by.set(e.homeArea, c);
  });
  const rows = [...by.entries()].map(([area, c]) => ({ area, c, n: c.crit + c.warn + c.ok + c.nd + c.na }))
    .sort((a, b) => b.c.crit / b.n - a.c.crit / a.n || b.n - a.n);
  if (!rows.length) return <div className="chart-note-oneline">No check in scope.</div>;
  const maxN = Math.max(...rows.map((r) => r.n));
  const used = SC_PARTS.filter((p) => rows.some((r) => r.c[p.key] > 0));
  return (
    <div className="cxd-bars">
      {rows.map(({ area, c, n }) => {
        const label = AREA_REGISTRY[area] ? AREA_REGISTRY[area].label : area;
        const parts = SC_PARTS.filter((p) => c[p.key] > 0).map((p) => `${fmtInt(c[p.key])} ${p.word}`);
        return (
          <button type="button" key={area} className="cxd-bar-row click" onClick={() => onArea(area)} aria-label={`${label}: ${fmtInt(n)} checks, ${parts.join(", ")}`}>
            <span className="cxd-bar-head">
              <span className="cxd-bar-name">{label}</span>
              <span className="cxd-bar-val"><b>{`${fmtInt(n)} check${n === 1 ? "" : "s"}`}</b>{` · ${parts.join(" · ")}`}</span>
            </span>
            <span className="af-area-track" style={{ width: `${(100 * n) / maxN}%` }}>
              {SC_PARTS.map((p) => (c[p.key] > 0 ? <span key={p.key} className={`sc-seg s-${p.cls}`} style={{ flexBasis: `${(100 * c[p.key]) / n}%` }} /> : null))}
            </span>
          </button>
        );
      })}
      <div className="b2-legend af-area-legend">
        {used.map((p) => <span key={p.key} className="b2-legend-item"><span className={`sc-sw s-${p.cls}`} />{p.word.charAt(0).toUpperCase() + p.word.slice(1)}</span>)}
      </div>
    </div>
  );
}

/** The possible waste the critical checks put a figure on: one bar per check with its full name, the same $ the Waste page shows. */
function CriticalWaste({ index, allowed, goTo }: { index: Record<string, Finding> | null | undefined; allowed: Set<string>; goTo: GoToFn }) {
  const crit = buildWasteWorklist(index).filter((w) => w.band === "CRITICAL" && w.unit === "waste" && allowed.has(homeForQuery({ query_id: w.id }).tab));
  const priced = crit.filter((w) => w.usd != null && (w.usd as number) > 0).sort((a, b) => (b.usd as number) - (a.usd as number));
  if (!crit.length) return <div className="chart-note-oneline">No critical check carries a possible-waste figure.</div>;
  const total = priced.reduce((s, w) => s + (w.usd as number), 0);
  const top = priced[0];
  return (
    <div>
      <div className="af-waste-total">
        <span className="af-waste-num">{fmtMoney(total, 0)}</span>
        <span className="af-waste-unit">{`possible waste${top && total > 0 ? ` · the top check is ${fmtShare(pctOf(top.usd as number, total))} of it` : ""}`}</span>
      </div>
      <CxBars ariaLabel="Possible waste by critical check" n={8} noun="checks" dots={false}
        items={priced.map((w) => ({ key: w.id, name: w.title, value: w.usd as number, valueText: fmtMoney(w.usd, 0),
          sub: w.affected ? `${fmtInt(w.affected.flagged)} of ${fmtInt(w.affected.total)} ${w.affected.noun}` : undefined }))}
        onClick={(it) => { const h = afHome({ query_id: it.key }); if (h) goTo({ tab: h.tab, subtab: h.subtab, focusQueryId: it.key }); }} />
      <div className="af-waste-note">Possible saving, storage per month and spend are other kinds. They are on Waste &amp; savings and are never added here.</div>
    </div>
  );
}

const TAB_LIST_WORD: Record<string, string> = { CRITICAL: "Critical checks", WARN: "Warnings", OK: "OK checks", COULDNT: "Checks not assessed", NODATA: "Checks with no data", REFERENCE: "Reference checks" };

export function AllFindingsPanel({ filters, allFindingsIndex, goTo, meta, roleAreas, role, setVerdict }: {
  filters: Filters; allFindingsIndex: Record<string, Finding> | null | undefined; goTo: GoToFn; meta?: Meta | null; roleAreas?: string[] | null;
  role?: string | null; setVerdict?: (v: React.ReactNode) => void;
}) {
  // roleAreas: every area for data_engineer/cto, a real subset for the other roles -- All findings
  // only ever lists a check whose home area the current role's own sidebar shows.
  const allowedAreas = React.useMemo(() => new Set(roleAreas && roleAreas.length ? roleAreas : AF_HOME_AREAS), [roleAreas]);
  const all = React.useMemo(
    () => Object.values(allFindingsIndex || {}).filter((row) => allowedAreas.has(homeForQuery(row).tab)),
    [allFindingsIndex, allowedAreas]
  );
  const [search, setSearch] = React.useState("");
  const [areaFilter, setAreaFilter] = React.useState<string | null>(null);
  // The first tab (Critical first) that has a row, so the page never opens on an empty tab.
  const [tab, setTab] = React.useState(() => {
    const present = new Set(all.map((row) => tabOf(row, bandOf(row), AF_REFERENCE_IDS)));
    return TAB_ORDER.find((k) => present.has(k)) || "CRITICAL";
  });

  const withMeta: AfEntry[] = React.useMemo(() => all.map((row) => {
    const band = bandOf(row);
    const label = getCheckLabel(row.query_id, row.title);
    return { row, band, tab: tabOf(row, band, AF_REFERENCE_IDS), homeArea: homeForQuery(row).tab, searchText: findingSearchText(row, band, label) };
  }), [all]);
  // "Checks ran" excludes Reference (raw lists, never a pass/fail check), like every other count here.
  const checkedRows = React.useMemo(() => withMeta.filter((f) => f.tab !== "REFERENCE"), [withMeta]);
  // Chip and tab counts are global, so a chip's number never shifts as another filter changes.
  const areaCounts = React.useMemo(() => {
    const counts: Record<string, number> = {};
    checkedRows.forEach((f) => { counts[f.homeArea] = (counts[f.homeArea] || 0) + 1; });
    return counts;
  }, [checkedRows]);
  const tabCounts = React.useMemo(() => {
    const counts: Record<string, number> = {};
    TAB_ORDER.forEach((k) => { counts[k] = 0; });
    withMeta.forEach((f) => { counts[f.tab] += 1; });
    return counts;
  }, [withMeta]);

  const q = search.trim().toLowerCase();
  const filtered = React.useMemo(() => withMeta.filter((f) => (!areaFilter || f.homeArea === areaFilter) && (!q || f.searchText.includes(q))), [withMeta, areaFilter, q]);
  const visible = React.useMemo(() => sortByWasteThenMoney(filtered.filter((f) => f.tab === tab)), [filtered, tab]);

  // The window or filters emptied the open tab: move to the next tab that has something.
  React.useEffect(() => {
    if (tabCounts[tab] === 0) {
      const firstNonEmpty = TAB_ORDER.find((k) => tabCounts[k] > 0);
      if (firstNonEmpty && firstNonEmpty !== tab) setTab(firstNonEmpty);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [all]);

  const lensOnly = CONTENT_AREAS.some((k) => !allowedAreas.has(k));
  const lens = role ? LENS_LABEL[role] || null : null;
  const ran = ranCountsOf(meta);
  const verdict = afVerdict(tabCounts, checkedRows.length, filters.window, lensOnly, ran, lens);
  const verdictKey = `${checkedRows.length}|${tabCounts.CRITICAL}|${tabCounts.WARN}|${tabCounts.COULDNT}|${tabCounts.REFERENCE}|${ran ? ran.assessed : "-"}|${lens}|${filters.window}`;
  React.useEffect(() => { if (setVerdict) setVerdict(verdict); }, [verdictKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const downloadCsv = () => {
    // One row per check; an unpriced or missing figure is blank, never 0.
    const lines = [[
      "Status", "Check", "Query ID", "Home tab", "Rows", "Possible waste $", "Other $", "Other $ kind", "Money currency",
      "Affected", "Affected of", "Affected noun", "Window days", "As of",
    ].map(csvField).join(",")];
    const asOf = (meta && meta.as_of_date) || "";
    filtered.forEach(({ row, band }) => {
      const home = afHome(row);
      const m = row.money;
      const kind = m ? moneyKindOf(row as Finding) : null;
      const usd = m && row.money_reason !== "unpriced" && m.usd != null && !m.mixed_currency ? m.usd : "";
      const a = row.affected;
      lines.push([
        csvField(statusText(row, band)), csvField(getCheckLabel(row.query_id, row.title).title), csvField(row.query_id), csvField(home ? home.text : ""),
        csvField(row.row_count ?? ""), csvField(kind === "waste" ? usd : ""), csvField(kind && kind !== "waste" ? usd : ""),
        csvField(kind && kind !== "waste" ? (MONEY_KIND_WORD[kind] || kind) : ""),
        csvField(m && m.unit === "currency" ? (m.currency || "invoice currency") : (m ? "USD (list price)" : "")),
        csvField(a ? a.flagged : ""), csvField(a ? a.total : ""), csvField(a ? a.noun : ""),
        csvField(row.windowed === false ? "snapshot" : (row.window_days ?? filters.window)), csvField(asOf),
      ].join(","));
    });
    const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = "all_findings.csv";
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const scopeWord = lensOnly ? "in this lens" : "across every area";
  const listTitle = TAB_LIST_WORD[tab] || tab;
  return (
    <div className="cxd af-page">
      {lensOnly && ran && (
        <div className="cxd-scope-note">{`Counts on this page are for the ${lens || "current"} lens only; the sidebar and top bar count every lens (${fmtInt(ran.assessed)} of ${fmtInt(ran.total)} ${ran.unit} ran).`}</div>
      )}

      <CxStatusTabs counts={tabCounts} active={tab} onChange={setTab} />

      <div className="card af-filter-card">
        <div className="findings-toolbar">
          <input className="findings-search-input" value={search} onChange={(e: React.ChangeEvent<HTMLInputElement>) => setSearch(e.target.value)}
            placeholder="Search checks, e.g. idle, timeout, grants" aria-label="Search checks" />
        </div>
        <div className="af-chip-row">
          <span className="af-chip-label">Area</span>
          <button type="button" className={`af-chip${!areaFilter ? " active" : ""}`} onClick={() => setAreaFilter(null)}>
            All <span className="af-chip-count">{fmtInt(checkedRows.length)}</span>
          </button>
          {AF_HOME_AREAS.filter((key) => allowedAreas.has(key)).map((key) => (
            <button key={key} type="button" className={`af-chip${areaFilter === key ? " active" : ""}`} onClick={() => setAreaFilter(areaFilter === key ? null : key)}>
              {AREA_REGISTRY[key].label} <span className="af-chip-count">{fmtInt(areaCounts[key] || 0)}</span>
            </button>
          ))}
        </div>
      </div>

      <div className="cj-charts-2 af-charts">
        <ChartCard title="What came out critical, by area" subtitle={`${fmtInt(checkedRows.length)} checks ${scopeWord}, reference kept apart · bar length = checks in the area · highest share critical first`} takeaway={null}>
          <CriticalByArea entries={withMeta} onArea={(a) => setAreaFilter(areaFilter === a ? null : a)} />
        </ChartCard>
        <ChartCard title="Possible waste in critical checks" subtitle={`Last ${filters.window} days · the critical waste checks that put a figure on it`} takeaway={null}>
          <button type="button" className="ck-link af-waste-link" onClick={() => goTo({ tab: "waste" })}>Waste &amp; savings →</button>
          <CriticalWaste index={allFindingsIndex} allowed={allowedAreas} goTo={goTo} />
        </ChartCard>
      </div>

      <CxChecksTable goTo={goTo} n={AF_PAGE_SIZE} title={listTitle}
        sub={`${fmtInt(visible.length)} check${visible.length === 1 ? "" : "s"}${lensOnly ? " in this lens" : ""} · priced ones first, by dollars; the rest by spend in scope`}
        rows={visible.map((f) => ({ row: f.row, band: f.band, pill: f.tab === "REFERENCE" ? "reference" : undefined }))}
        right={<button type="button" className="ck-link" onClick={downloadCsv} title="Download every check matching the current area and search, across all tabs.">CSV</button>}
        summary={
          <span className="cxd-summary">
            <span>{`${fmtInt(checkedRows.length)} checks ${scopeWord}`}</span>
            <span><Dot status="CRITICAL" />{`${fmtInt(tabCounts.CRITICAL)} critical`}</span>
            <span><Dot status="WARN" />{`${fmtInt(tabCounts.WARN)} warning`}</span>
            <span><Dot status="OK" />{`${fmtInt(tabCounts.OK)} OK`}</span>
            <span><Dot status="REF" />{`${fmtInt(tabCounts.REFERENCE)} reference`}</span>
            {tabCounts.COULDNT > 0 && <button type="button" className="ck-link" onClick={() => setTab("COULDNT")}>{`${fmtInt(tabCounts.COULDNT)} not assessed →`}</button>}
          </span>
        } />
      {!visible.length && <div className="chart-note-oneline">{q || areaFilter ? "No checks match the current search and area." : `Nothing in "${listTitle}" right now.`}</div>}
    </div>
  );
}

AreaContent.register("findings", null, AllFindingsPanel);
