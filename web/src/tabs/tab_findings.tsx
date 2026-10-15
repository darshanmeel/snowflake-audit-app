// web/src/tabs/tab_findings.tsx -- "All findings": every check the app runs, one list. Status tabs, a
// search and area chips, then what came out critical by area and the possible waste the critical
// checks name, then the compact list (pill · check · "n of m · $ kind" · home tab). Registers into
// the "findings" area (no sub-tabs, no ids of its own) and reads every check through allFindingsIndex.
import React from "react";
import { fmtInt, fmtMoney } from "../format";
import { AREA_ORDER, AREA_REGISTRY, homeForQuery } from "../components/tab_registry";
import { ChartCard, StatusPill, bandOf, bandPillKind, ranCountsOf } from "../components/primitives";
import { AreaContent } from "../area_content";
import { getCheckLabel } from "../components/labels";
import { CheckStatusTabs, TAB_META, TAB_ORDER, csvField, findingSearchText, sortByWasteThenMoney, statusText, tabOf } from "../components/findings_table";
import { checkFact } from "../components/checks_list";
import { navHref } from "../components/nav_hash";
import { buildWasteWorklist, moneyKindOf } from "../components/waste_total";
import { StatusBars, fmtShare, pctOf } from "../components/blocks";
import type { StatusBarItem } from "../components/blocks";
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

/** Compact rows of checks, each opening its home tab: pill · name · "n of m · $ kind" · home. */
export function HomeChecksList({ rows, goTo, n = AF_PAGE_SIZE, title, right, foot }: {
  rows: { row: Row; band: string; pill?: string }[]; goTo: GoToFn; n?: number;
  title: React.ReactNode; right?: React.ReactNode; foot?: React.ReactNode;
}) {
  const [all, setAll] = React.useState(false);
  React.useEffect(() => { setAll(false); }, [rows]);
  const shown = all ? rows : rows.slice(0, n);
  return (
    <div className="card ck-card">
      <div className="ck-head"><div className="card-title">{title}</div>{right}</div>
      <div className="ck-list" role="list">
        {shown.map(({ row, band, pill }) => {
          const home = afHome(row);
          const name = getCheckLabel(row.query_id, row.title).title;
          const go = home ? () => goTo({ tab: home.tab, subtab: home.subtab, focusQueryId: row.query_id }) : undefined;
          return (
            <a role="listitem" key={row.query_id} className="ck-row" href={home ? navHref({ tab: home.tab, subtab: home.subtab, focus: row.query_id }) : undefined}
              onClick={(e) => { if (go) { e.preventDefault(); go(); } }} aria-label={`${name}: open on ${home ? home.text : "its page"}`}>
              <span className="ck-pill"><StatusPill kind={pill || bandPillKind(band)} /></span>
              <span className="ck-name" title={name}>{name}</span>
              <span className="ck-fact">{checkFact(row as Finding, band)}</span>
              <span className="ck-rows">{home ? `${home.text} →` : "This page"}</span>
            </a>
          );
        })}
        {!rows.length && <div className="chart-note-oneline">Nothing to list.</div>}
      </div>
      {(rows.length > n || foot) && (
        <div className="ck-foot">
          {rows.length > n && (
            <button type="button" className="ck-link" onClick={() => setAll((x) => !x)}>
              {all ? "Show fewer" : `+${fmtInt(rows.length - n)} more · show all ${fmtInt(rows.length)}`}
            </button>
          )}
          {foot}
        </div>
      )}
    </div>
  );
}

// The whole-account verdict leads with the API's one checks-that-ran count (meta.checks_ran); a lens
// that shows only some areas words its own smaller list without claiming that count.
export function afVerdict(counts: Record<string, number>, total: number, windowDays: number, lensOnly: boolean, ranMeta: { assessed: number; total: number; unit: string } | null | undefined) {
  if (total === 0) return "No checks are in scope for the current filters.";
  const bits: string[] = [];
  if (counts.CRITICAL) bits.push(`${fmtInt(counts.CRITICAL)} critical`);
  if (counts.WARN) bits.push(`${fmtInt(counts.WARN)} warning${counts.WARN === 1 ? "" : "s"}`);
  const lead = bits.length ? `${bits.join(" and ")} to look at first` : "nothing critical or warning right now";
  const tail = `${fmtInt(counts.COULDNT)} could not run; ${fmtInt(counts.REFERENCE)} are reference, kept apart.`;
  if (lensOnly) return `${fmtInt(total)} checks in this lens, on the last ${windowDays} days: ${lead}. ${tail}`;
  if (!ranMeta) return "…";
  return `${fmtInt(ranMeta.assessed)} of ${fmtInt(ranMeta.total)} ${ranMeta.unit} ran on the last ${windowDays} days: ${lead}. ${tail}`;
}

type AfEntry = { row: Row; band: string; tab: string; homeArea: string; searchText: string };
const SC_PARTS: { key: "crit" | "warn" | "ok" | "nd" | "na"; cls: string; word: string }[] = [
  { key: "crit", cls: "crit", word: "critical" }, { key: "warn", cls: "warn", word: "warning" }, { key: "ok", cls: "ok", word: "ok" },
  { key: "nd", cls: "ref", word: "no data in window" }, { key: "na", cls: "na", word: "could not run" },
];

/** Checks per home area as crit / warn / ok / not run, one thin bar each, most critical first. */
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
  return (
    <div className="sc-list">
      {rows.map(({ area, c, n }) => {
        const label = AREA_REGISTRY[area] ? AREA_REGISTRY[area].label : area;
        const text = [c.crit ? `${fmtInt(c.crit)} crit` : null, c.warn ? `${fmtInt(c.warn)} warn` : null, c.ok ? `${fmtInt(c.ok)} ok` : null, c.nd ? `${fmtInt(c.nd)} no data` : null, c.na ? `${fmtInt(c.na)} not run` : null].filter(Boolean).join(" · ");
        return (
          <button type="button" key={area} className="sc-row" onClick={() => onArea(area)}>
            <span className="sc-label">{label}</span>
            <span className="sc-bar" role="img" aria-label={`${label}: ${text} of ${n}`}>
              {SC_PARTS.map((p) => (c[p.key] > 0 ? <span key={p.key} className={`sc-seg s-${p.cls}`} style={{ flexBasis: `${(100 * c[p.key]) / n}%` }} title={`${fmtInt(c[p.key])} ${p.word}`} /> : null))}
            </span>
            <span className="sc-val">{`${text} of ${fmtInt(n)}`}</span>
          </button>
        );
      })}
      <div className="b2-legend">
        {SC_PARTS.map((p) => <span key={p.key} className="b2-legend-item"><span className={`sc-sw s-${p.cls}`} />{p.word}</span>)}
      </div>
    </div>
  );
}

/** The possible waste the critical checks put a figure on: one bar per check, the same $ the Waste page shows. */
function CriticalWaste({ index, allowed, goTo }: { index: Record<string, Finding> | null | undefined; allowed: Set<string>; goTo: GoToFn }) {
  const crit = buildWasteWorklist(index).filter((w) => w.band === "CRITICAL" && w.unit === "waste" && allowed.has(homeForQuery({ query_id: w.id }).tab));
  const priced = crit.filter((w) => w.usd != null && (w.usd as number) > 0);
  if (!crit.length) return <div className="chart-note-oneline">No critical check carries a possible-waste figure.</div>;
  const total = priced.reduce((s, w) => s + (w.usd as number), 0);
  const items: StatusBarItem[] = priced.map((w) => ({
    key: w.id, name: w.title, value: w.usd as number, status: "CRITICAL",
    valueText: `${fmtMoney(w.usd, 0)}${w.affected ? ` · ${fmtInt(w.affected.flagged)} of ${fmtInt(w.affected.total)} ${w.affected.noun}` : ""}`,
  }));
  const top = [...priced].sort((a, b) => (b.usd as number) - (a.usd as number))[0];
  return (
    <div>
      <div className="gov-headline">
        <b>{`${fmtMoney(total, 0)} possible waste`}</b>
        {` · ${fmtInt(priced.length)} of ${fmtInt(crit.length)} critical waste checks put a figure on it`}
        {top && total > 0 ? ` · top 1 = ${fmtShare(pctOf(top.usd as number, total))}` : ""}
      </div>
      <StatusBars items={items} n={8} ariaLabel="Possible waste by critical check"
        onBarClick={(it) => { const h = afHome({ query_id: String(it.key) }); if (h) goTo({ tab: h.tab, subtab: h.subtab, focusQueryId: String(it.key) }); }} />
      <div className="chart-note-oneline">Possible saving, storage per month and context figures are other kinds: they are on Waste &amp; savings, never added here.</div>
    </div>
  );
}

export function AllFindingsPanel({ filters, allFindingsIndex, goTo, meta, roleAreas }: { filters: Filters; allFindingsIndex: Record<string, Finding> | null | undefined; goTo: GoToFn; meta?: Meta | null; roleAreas?: string[] | null }) {
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

  const tabWord = TAB_META[tab] ? TAB_META[tab].label : tab;
  return (
    <div>
      <div className="page-intro-verdict">{afVerdict(tabCounts, checkedRows.length, filters.window, CONTENT_AREAS.some((k) => !allowedAreas.has(k)), ranCountsOf(meta))}</div>

      <CheckStatusTabs counts={tabCounts} active={tab} onChange={setTab} />

      <div className="card">
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

      <div className="cj-charts-2">
        <ChartCard title="What came out critical, by area" subtitle={`${fmtInt(checkedRows.length)} checks · reference kept apart · most critical first`} takeaway={null}>
          <CriticalByArea entries={withMeta} onArea={(a) => setAreaFilter(areaFilter === a ? null : a)} />
        </ChartCard>
        <ChartCard title="Possible waste the critical checks name" subtitle={`$ in the last ${filters.window} days · one kind, never added to saving or spend`} takeaway={null}>
          <CriticalWaste index={allFindingsIndex} allowed={allowedAreas} goTo={goTo} />
        </ChartCard>
      </div>

      <HomeChecksList goTo={goTo} title={`${tabWord} · ${fmtInt(visible.length)} check${visible.length === 1 ? "" : "s"}`}
        rows={visible.map((f) => ({ row: f.row, band: f.band, pill: f.tab === "REFERENCE" ? "reference" : undefined }))}
        right={<button type="button" className="ck-link" onClick={downloadCsv} title="Download every check matching the current area and search, across all tabs.">CSV</button>}
        foot={!visible.length ? <span className="muted">{q || areaFilter ? "No checks match the current search and area." : `Nothing in "${tabWord}" right now.`}</span> : null} />
    </div>
  );
}

AreaContent.register("findings", null, AllFindingsPanel);
