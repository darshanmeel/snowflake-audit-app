// web/src/tabs/tab_coverage.tsx -- Coverage & Gaps: sub-tabs sources / couldnt / limits.
// "An empty panel means could not look or nothing yet, never a verified zero". A view the audit role
// cannot see, an edition too low, a failed check: each reads NOT ASSESSED with the reason and the way
// to get access, never "nothing found". The "checks that ran" count here is the same one the top bar
// and Overview show (meta.checks_ran, read through ranCountsOf in primitives.tsx).
import { FixCopyButton } from "../components/fixcopy_button";
import React from "react";
import { Api } from "../api";
import { fmtDuration, fmtInt, fmtMoney } from "../format";
import { numOrZero, sumBy, useFindingData } from "../components/hooks";
import { ChartCard, KindChip, bandOf, isUncertainBand, noDataText, ranCountsOf } from "../components/primitives";
import { AreaContent } from "../area_content";
import { getCheckLabel } from "../components/labels";
import { IssueTile, StatusBars, fmtShare, pctOf } from "../components/blocks";
import type { StatusBarItem } from "../components/blocks";
import { StatStrip } from "../components/blocks_2";
import { DrillTable, MiniBar } from "../components/drill_table";
import { SummaryTileRow } from "../components/overview_tile";
import "../styles/css/p_area_governance.css";
import { notAssessedText } from "../components/scope";
import { AREA_REGISTRY, homeForQuery } from "../components/tab_registry";
import { HomeChecksList } from "./tab_findings";
import type { Filters, Finding, GoToFn, Meta, Row } from "../types";

/** One source in the coverage `tables` map: how its read went and which checks depend on it. */
export interface CoverageSource {
  state?: string | null;
  rows?: number | null;
  reason?: string | null;
  message?: string | null;
  covers?: string | null;
  window_days?: number | null;
  checks_total?: number | null;
  checks_ok?: number | null;
  dependent_query_ids?: string[] | null;
  [key: string]: any;
}

/** One check the export could not run, with why and what opens it. */
export interface CoverageCheckNotOk {
  query_id: string;
  title?: string | null;
  reason_label?: string | null;
  fix?: string | null;
  cause?: string | null;
  requires?: string | null;
  grants?: string[] | null;
  unreadable_sources?: (string | { source: string })[] | null;
  [key: string]: any;
}

/** What the audit role can see: warehouses listed vs billed and the sources it cannot read. */
export interface CoverageVisibility {
  warehouses?: { missing: number; note?: string | null; visible: number; billed: number; unit?: string | null } | null;
  unreadable?: { source: string; grant?: string | null }[] | null;
  probed?: number | null;
  [key: string]: any;
}

export interface CoverageEdition { edition?: string | null; source?: string | null; [key: string]: any }

/** GET /api/coverage. */
export interface Coverage {
  tables?: Record<string, CoverageSource> | null;
  export_mode?: string | null;
  visibility?: CoverageVisibility | null;
  edition?: CoverageEdition | null;
  checks_not_ok?: CoverageCheckNotOk[] | null;
  truncated_query_ids?: string[] | null;
  [key: string]: any;
}

/** The props the area shell passes to each Coverage sub-tab. */
interface CoveragePanelProps {
  goTo: GoToFn;
  filters: Filters;
  allFindingsIndex?: Record<string, Finding> | null;
  meta: Meta | null;
  onExternalJump?: (queryId: string) => void;
  /** False on the CTO lens, which has no sub-tabs to link to. */
  canDrill?: boolean;
  /** Sets the page-head lede. */
  onVerdict?: (sentence: string | null) => void;
}


export function useCoverageWithError() {
  const [cov, setCov] = React.useState<Coverage | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  React.useEffect(() => {
    let cancelled = false;
    Api.coverage().then((d: Coverage) => { if (!cancelled) setCov(d); }).catch((e: any) => { if (!cancelled) setError(e.message || String(e)); });
    return () => { cancelled = true; };
  }, []);
  return { cov, error };
}

// Source keys are Snowflake views ("ACCOUNT_USAGE.QUERY_HISTORY"), SHOW commands ("SHOW WAREHOUSES")
// or functions ("SYSTEM$CLIENT_VERSION_INFO()"), grouped by where they live.
export const CV_GROUP_ORDER = ["ACCOUNT_USAGE", "ORGANIZATION_USAGE", "DATA_SHARING_USAGE", "TRUST_CENTER", "SHOW commands", "Functions"];
export function cvGroupForKey(key: string) {
  const k = String(key);
  if (/^SHOW /i.test(k)) return "SHOW commands";
  if (/\(\)$/.test(k)) return "Functions";
  const schema = k.split(".")[0];
  return CV_GROUP_ORDER.includes(schema) ? schema : "ACCOUNT_USAGE";
}
export const CV_GROUP_NOTE: Record<string, string> = {
  ACCOUNT_USAGE: "Needs IMPORTED PRIVILEGES on the SNOWFLAKE database. Views lag up to a few hours and keep 365 days.",
  ORGANIZATION_USAGE: "Needs an organization role (ORGADMIN or granted access) in the organization account. Billing views lag up to 72 hours.",
  DATA_SHARING_USAGE: "Needs the role to see shares and listings.",
  TRUST_CENTER: "Needs the Trust Center viewer application role.",
  "SHOW commands": "List only what the role can see: grant MONITOR on the warehouses, tasks and pipes to widen them.",
  Functions: "Read one value from Snowflake itself.",
};

// The last segment of the source, in plain words: never a fabricated description.
export function cvSourceLabel(key: string) {
  const k = String(key).replace(/\(\)$/, "").replace(/^SHOW /i, "");
  const last = k.split(".").pop()!.replace(/_/g, " ").toLowerCase();
  return last.charAt(0).toUpperCase() + last.slice(1);
}

// "ok" with 0 rows is not a verified pass: derive "empty" so a 0-row source never reads as clean.
export function cvEffectiveState(info: CoverageSource | null | undefined) {
  if (!info) return "not_assessed";
  if (info.state === "ok" && info.rows === 0) return "empty";
  return info.state || "not_assessed";
}

// A source's reason code -> the plain words, and how to fix it.
export const CV_REASON: Record<string, string[]> = {
  no_access: ["the role can't see it", "Grant the audit role IMPORTED PRIVILEGES on the SNOWFLAKE database (ORGANIZATION_USAGE also needs an organization role)."],
  view_missing: ["not available in this account", "The view or feature is not in this account: it may need Enterprise edition or an organization account."],
  timeout: ["timed out reading it", "Run the export again with a shorter window."],
  not_exported: ["not run in this export", "Run the export again: this check produced no result last time."],
  unknown: ["failed in the export", "Run the export again and read its own error output for this source."],
  "no export yet": ["no export yet", "Run python tools/first_run.py to export and load."],
};
export function cvReasonText(info: CoverageSource) {
  const r = info.reason && CV_REASON[info.reason] ? CV_REASON[info.reason] : null;
  if (r) return `${r[0]}. ${r[1]}`;
  return info.reason || info.message || "Not in this export.";
}

/** Sets the page-head lede from the page's own numbers ("…" while it loads). */
function useCvLede(onVerdict: ((s: string | null) => void) | undefined, text: string | null) {
  React.useEffect(() => { if (onVerdict) onVerdict(text); }, [text]); // eslint-disable-line react-hooks/exhaustive-deps
}

/** sf_cost_source_freshness rows, or why there are none. */
function useFreshness(filters: Filters) {
  const state = useFindingData("sf_cost_source_freshness", filters.window, filters.accountIds);
  const rows: Row[] | null = state.phase === "ready" && state.outcome === "ok_rows" ? state.data!.rows : null;
  const why = state.phase === "loading" ? null : state.phase === "error" ? (state.error || "could not load")
    : state.outcome === "not_assessed" ? notAssessedText(state.data) : state.outcome === "ok_empty_window" ? "no data in this window" : rows ? null : "not in this export";
  return { rows, why, loading: state.phase === "loading" };
}
const lagHours = (r: Row) => (r.lag_hours != null ? numOrZero(r.lag_hours) : r.days_behind != null ? numOrZero(r.days_behind) * 24 : null);

// What running this audit itself cost, from cost_audit_self_usage (coverage-only: that check emits
// no status column). Spend, kept apart from the account's own figures.
function AuditSelfCost({ filters }: { filters: Filters }) {
  const state = useFindingData("cost_audit_self_usage", filters.window, filters.accountIds);
  const rows: Row[] | null = state.phase === "ready" && state.outcome === "ok_rows" ? state.data!.rows : null;
  let value: string | null = null;
  let why: string | null = null;
  if (state.phase === "loading") value = "…";
  else if (state.phase === "error") why = state.error || "Could not load.";
  else if (state.outcome === "not_assessed") why = notAssessedText(state.data);
  else if (state.outcome === "ok_empty_window") why = "No audit queries matched this window.";
  const auditUsd = (r: Row) => (r.est_audit_usd_list_disc != null ? r.est_audit_usd_list_disc : r.est_audit_usd_list);
  const priced = (rows || []).filter((r) => auditUsd(r) != null);
  if (rows && rows.length) {
    if (!priced.length) why = "Not priced: no $ price for this export.";
    else value = fmtMoney(priced.reduce((s: number, r: Row) => s + numOrZero(auditUsd(r)), 0), 2);
  }
  return (
    <StatStrip ariaLabel="What this audit cost" cells={[
      { key: "cost", label: "Audit cost", pill: null, value: value, unit: <KindChip>Spend</KindChip>, missing: why || undefined },
      { key: "q", label: "Queries", value: rows ? fmtInt(sumBy(rows, "matched_statement_count")) : null, missing: why || undefined },
      { key: "wh", label: "Warehouses", value: rows ? fmtInt(rows.length) : null, missing: why || undefined },
    ]} />
  );
}

// ═══════════════════════ Data sources ═══════════════════════

export function CoverageSourcesPanel({ goTo, filters, meta, allFindingsIndex, onVerdict }: CoveragePanelProps) {
  const { cov, error } = useCoverageWithError();
  const fresh = useFreshness(filters);
  const [showSources, setShowSources] = React.useState(false);
  const ran = ranCountsOf(meta);
  const entries = Object.entries((cov && cov.tables) || {});
  const state = (i: CoverageSource) => cvEffectiveState(i);
  const readOk = entries.filter(([, i]) => state(i) === "ok" || state(i) === "empty").length;
  const vis = cov && cov.visibility;
  const wh = vis && vis.warehouses;
  const unreadable = (vis && vis.unreadable) || [];
  const truncated = (cov && cov.truncated_query_ids) || [];
  const late = (fresh.rows || []).filter((r) => r.status === "CRITICAL" || r.status === "WARN").length;
  const bands = Object.values(allFindingsIndex || {}).map((f) => bandOf(f));
  const nBand = (b: string) => bands.filter((x) => x === b).length;
  useCvLede(onVerdict, !cov || !ran ? "…" : [
    `${fmtInt(ran.assessed)} of ${fmtInt(ran.total)} ${ran.unit} ran.`,
    entries.length ? `${fmtInt(readOk)} of ${fmtInt(entries.length)} Snowflake views and commands were readable.` : null,
    wh ? `The role sees ${fmtInt(wh.visible)} of ${fmtInt(wh.billed)} billed ${wh.unit || "warehouses"}${wh.missing > 0 ? `; the other ${fmtInt(wh.missing)} are missing from warehouse checks, not clean` : ""}.` : null,
  ].filter(Boolean).join(" "));
  if (error) return <div className="honest-card error"><div className="h-title">Could not read coverage</div><div className="h-note mono">{error}</div></div>;
  if (!cov) return <div className="loading-note">…</div>;

  const grouped: Record<string, [string, CoverageSource][]> = {};
  entries.forEach(([key, info]) => { (grouped[cvGroupForKey(key)] = grouped[cvGroupForKey(key)] || []).push([key, info]); });
  const noExport = cov.export_mode === "none";
  return (
    <div>
      {noExport && <div className="page-intro-verdict">Nothing has been exported yet: no source has been read.</div>}
      <div className="cv-tiles">
        <SummaryTileRow compact>
          <IssueTile label="Checks that ran" headline={ran ? fmtShare(pctOf(ran.assessed, ran.total)) : null} loading={!ran} unit=" of checks" pill={<KindChip>Context</KindChip>}
            base={ran ? `${fmtInt(ran.assessed)} of ${fmtInt(ran.total)} ${ran.unit} · ${fmtInt(nBand("CRITICAL"))} critical · ${fmtInt(nBand("WARN"))} warning` : null}
            cause={ran && ran.total > ran.assessed ? `${fmtInt(ran.total - ran.assessed)} did not run: see Not assessed.` : "Every check ran."}
            onOpen={() => goTo({ tab: "coverage", subtab: "couldnt" })} openLabel="Which ones →" />
          <IssueTile label="Sources read" headline={entries.length ? fmtShare(pctOf(readOk, entries.length)) : null} unit=" of sources" pill={<KindChip>Context</KindChip>}
            missingReason="no source in this export"
            base={`${fmtInt(readOk)} of ${fmtInt(entries.length)} views and commands · ${fmtInt(truncated.length)} hit the export row cap`}
            cause={unreadable.length ? `${fmtInt(unreadable.length)} the role cannot read: the grant is in the sources list.` : "Every usage view and SHOW command answered."}
            onOpen={() => setShowSources(true)} openLabel="By family ↓" />
          <IssueTile label="Warehouses the role sees" headline={wh ? fmtShare(pctOf(wh.visible, wh.billed)) : null} unit=" of billed warehouses"
            missingReason={vis ? "billed vs listed could not be compared" : "not probed in this export"}
            base={wh ? `${fmtInt(wh.visible)} of ${fmtInt(wh.billed)} ${wh.unit || "warehouses"}${wh.missing > 0 ? ` · ${fmtInt(wh.missing)} bill but are missing from SHOW WAREHOUSES` : ""}` : null}
            cause={wh && wh.missing > 0 ? "Missing, not clean. GRANT MONITOR on each warehouse widens the view." : null}
            status={!wh ? "not_assessed" : wh.missing > 0 ? "not_assessed" : "ok"}
            pill={wh && wh.missing > 0 ? <span className="nj-pill">{`– ${fmtInt(wh.missing)} not visible`}</span> : undefined}
            onOpen={() => goTo({ tab: "coverage", subtab: "limits" })} openLabel="Known limitations →" />
          <IssueTile label="Views behind their normal delay" loading={fresh.loading} headline={fresh.rows ? fmtInt(late) : null} unit={fresh.rows ? ` of ${fmtInt(fresh.rows.length)} views` : undefined}
            missingReason={fresh.why} status={fresh.rows ? (late ? "warn" : "ok") : "not_assessed"}
            base={fresh.rows ? (late ? `${fmtInt(late)} views are further behind than Snowflake documents` : "newest row within the normal delay for each") : null}
            cause={fresh.rows ? "A view far behind makes the newest days read too low." : null} />
        </SummaryTileRow>
      </div>

      <div className="cj-charts-2">
        <ChartCard title="Source freshness" subtitle="how far each view is behind, against its normal delay · dot = status" takeaway={null}>
          {fresh.rows ? (
            <StatusBars n={12} unitLabel="behind" ariaLabel="Hours each view is behind"
              items={fresh.rows.filter((r) => lagHours(r) != null).map((r): StatusBarItem => ({
                key: String(r.source_view), name: String(r.source_view || "(unknown view)"), value: lagHours(r)!, status: r.status,
                valueText: `${fmtDuration(lagHours(r)! * 3600)} · normal ${r.expected_latency_hours != null ? fmtDuration(numOrZero(r.expected_latency_hours) * 3600) : "–"}`,
              }))} />
          ) : <div className="chart-note-oneline">{fresh.loading ? "…" : fresh.why === "no data in this window" ? noDataText(meta, filters.window) : `– ${fresh.why}`}</div>}
        </ChartCard>
        <ChartCard title="Sources by state" subtitle={`${fmtInt(entries.length)} views and commands, by family · read, or not readable`} takeaway={null}>
          <DrillTable aria="Sources by family" n={CV_GROUP_ORDER.length}
            cols={[{ label: "Family" }, { label: "Read", width: "minmax(60px, 1fr)" }, { label: "Sources", num: true, width: "auto" }]}
            rows={CV_GROUP_ORDER.filter((g) => grouped[g]).map((g) => {
              const list = grouped[g];
              const ok = list.filter(([, i]) => state(i) === "ok" || state(i) === "empty").length;
              return {
                key: g, status: ok < list.length ? "NOT_ASSESSED" : "OK", title: CV_GROUP_NOTE[g],
                cells: [g, <MiniBar key="b" value={ok} max={list.length} />, `${fmtInt(ok)} read · ${fmtInt(list.length - ok)} not readable of ${fmtInt(list.length)}`],
              };
            })} />
          {truncated.length > 0 && <div className="chart-note-oneline">{`${fmtInt(truncated.length)} check${truncated.length === 1 ? "" : "s"} hit the export row cap: only the first rows per window were kept.`}</div>}
          <button type="button" className="cv-toggle-btn" onClick={() => setShowSources(!showSources)} aria-expanded={showSources}>
            {showSources ? "Hide the sources list" : `Show all ${fmtInt(entries.length)} sources`}
          </button>
          <div className="gov-sub">
            <div className="gov-sub-title">What this audit cost · kept apart from the account's spend</div>
            <AuditSelfCost filters={filters} />
          </div>
        </ChartCard>
      </div>

      {showSources && (
        <div className="card">
          <DrillTable aria="Every source" n={entries.length}
            cols={[{ label: "Source" }, { label: "Checks OK", num: true, width: "auto" }, { label: "Covers", width: "auto" }, { label: "If not read: why, and the grant", width: "minmax(120px, 2fr)" }]}
            rows={CV_GROUP_ORDER.filter((g) => grouped[g]).flatMap((g) => grouped[g].map(([key, info]) => {
              const st = state(info);
              const grant = unreadable.find((u) => u.source === key);
              const range = st === "not_assessed" ? "–" : info.covers === "window" ? (info.window_days ? `last ${fmtInt(info.window_days)} d` : "trailing window") : "current state";
              return {
                key, status: st === "ok" || st === "empty" ? "OK" : "NOT_ASSESSED",
                cells: [key, info.checks_total ? `${fmtInt(info.checks_ok || 0)} of ${fmtInt(info.checks_total)}` : "–", range,
                  st === "empty" ? "Read, 0 rows: a true zero, or a feature this account does not use."
                    : st !== "ok" ? <span>{cvReasonText(info)}{grant && grant.grant && <span className="cv-grant">{` ${grant.grant}`}</span>}</span> : ""],
              };
            }))} />
        </div>
      )}
    </div>
  );
}

// checks_not_ok entries grouped by their shared (reason_label, fix) pair, so a reader sees one bucket
// to act on, not several reason codes that mean the same thing.
export function groupChecksNotOk(checks: CoverageCheckNotOk[] | null | undefined) {
  const byKey: Record<string, { label: string | null | undefined; fix: string | null | undefined; checks: CoverageCheckNotOk[] }> = {};
  const order: string[] = [];
  (checks || []).forEach((c) => {
    const key = `${c.reason_label}|${c.fix}`;
    if (!byKey[key]) { byKey[key] = { label: c.reason_label, fix: c.fix, checks: [] }; order.push(key); }
    byKey[key].checks.push(c);
  });
  return order.map((k) => byKey[k]).sort((a, b) => b.checks.length - a.checks.length);
}

// Why a check could not run, in words: the cause the export recorded for a failed read.
export const CV_CAUSE: Record<string, string> = {
  no_access: "the role can't see it",
  view_missing: "not available in this account",
  timeout: "timed out",
  edition_too_low: "needs a higher Snowflake edition",
  unknown: "failed",
};

// ═══════════════════════ Not assessed ═══════════════════════

export function CoverageCouldntPanel({ allFindingsIndex, goTo, meta, onVerdict }: CoveragePanelProps) {
  const { cov, error } = useCoverageWithError();
  const all = React.useMemo(() => Object.values(allFindingsIndex || {}), [allFindingsIndex]);
  const gaps = React.useMemo(() => all.filter((f) => isUncertainBand(bandOf(f))), [all]);
  const counts: Record<string, number> = { NOT_ASSESSED: 0, ERROR: 0, EMPTY_WINDOW: 0, EMPTY_FILTERS: 0 };
  gaps.forEach((f) => { const b = bandOf(f); counts[b] = (counts[b] || 0) + 1; });
  const ran = ranCountsOf(meta);
  const total = ran ? ran.total : all.length;
  const notOk = (cov && cov.checks_not_ok) || [];
  const groups = groupChecksNotOk(notOk);
  const grants = [...new Set(notOk.flatMap((c) => (c.grants || []).map((g) => String(g).split("--")[0].trim())))].filter(Boolean);
  useCvLede(onVerdict, !cov ? "…" : notOk.length
    ? `${fmtInt(notOk.length)} of ${fmtInt(total)} checks are not in this export${groups.length === 1 && groups[0].label ? `: ${groups[0].label}` : ""}. Their panels show "–": could not look, never a verified zero.`
    : "Every check in this export ran.");
  const byHome = new Map<string, { n: number; na: number }>();
  all.forEach((f) => {
    const k = homeForQuery(f).tab;
    const cur = byHome.get(k) || { n: 0, na: 0 };
    cur.n += 1;
    const b = bandOf(f);
    if (b === "NOT_ASSESSED" || b === "ERROR") cur.na += 1;
    byHome.set(k, cur);
  });
  const hit = [...byHome.entries()].filter(([, v]) => v.na > 0);
  const rest = [...byHome.entries()].filter(([, v]) => v.na === 0).reduce((s, [, v]) => s + v.n, 0);
  const asRows = (fs: Finding[]) => fs.map((f) => ({ row: f as Row, band: bandOf(f) }));
  const notOkFindings = notOk.map((c) => (allFindingsIndex && allFindingsIndex[c.query_id]) || ({ query_id: c.query_id, title: c.title, not_assessed: { label: c.reason_label || CV_CAUSE[c.cause!] || "did not run" } } as unknown as Finding));

  return (
    <div>
      <div className="cv-tiles">
        <SummaryTileRow compact>
          <IssueTile label="Not in this export" loading={!cov} headline={cov ? fmtInt(notOk.length) : null} unit={` of ${fmtInt(total)} checks`}
            status={notOk.length ? "not_assessed" : "ok"} pill={notOk.length ? undefined : null}
            base={`${fmtShare(pctOf(notOk.length, total))} · ${groups.length === 1 ? "one reason" : `${fmtInt(groups.length)} reasons`}${grants.length ? ` · ${grants.length === 1 ? "one grant opens them" : `${fmtInt(grants.length)} grants`}` : ""}`}
            cause={notOk.slice(0, 2).map((c) => getCheckLabel(c.query_id, c.title).title).join(", ") || "Every check ran."} />
          <IssueTile label="Could judge nothing this window" headline={fmtInt(gaps.length)} unit={` of ${fmtInt(all.length)} checks`} pill={<KindChip>Context</KindChip>}
            base={`${fmtInt(counts.NOT_ASSESSED)} not assessed · ${fmtInt(counts.ERROR)} read errors · ${fmtInt(counts.EMPTY_WINDOW)} nothing in window · ${fmtInt(counts.EMPTY_FILTERS)} excluded by filters`}
            cause="Not assessed reads –; nothing in the window reads No data. Neither is a pass." />
        </SummaryTileRow>
      </div>
      {error && <div className="honest-card error"><div className="h-title">Could not read coverage</div><div className="h-note mono">{error}</div></div>}
      {notOk.length > 0 && (
        <HomeChecksList goTo={goTo} title={`${fmtInt(notOk.length)} check${notOk.length === 1 ? " is" : "s are"} not in this export, by reason`}
          rows={groups.flatMap((g) => g.checks.map((c) => notOkFindings.find((f) => f.query_id === c.query_id)!)).map((f) => ({ row: f as Row, band: "NOT_ASSESSED" }))}
          foot={grants.length ? (
            <div className="gov-sub" style={{ marginTop: 0, width: "100%" }}>
              <div className="fx-head">
                <div className="gov-sub-title">What to grant · run as ACCOUNTADMIN, then export again</div>
                <FixCopyButton text={grants.join("\n")} />
              </div>
              {grants.map((g) => <pre key={g} className="dr-fix">{g}</pre>)}
              {groups[0] && groups[0].fix && <div className="chart-note-oneline">{groups[0].fix}</div>}
            </div>
          ) : null} />
      )}
      <div className="cj-charts-2">
        <ChartCard title="Where the gaps sit" subtitle="checks per area · the hatched part did not run" takeaway={null}>
          {hit.length ? (
            <DrillTable aria="Not-run checks by area" n={12}
              cols={[{ label: "Area" }, { label: "Ran", width: "minmax(60px, 1fr)" }, { label: "Checks", num: true, width: "auto" }]}
              rows={[...hit.map(([k, v]) => ({
                key: k, status: "NOT_ASSESSED", onOpen: () => goTo({ tab: k }),
                cells: [AREA_REGISTRY[k] ? AREA_REGISTRY[k].label : k, <MiniBar key="b" value={v.n - v.na} max={v.n} />, `${fmtInt(v.n - v.na)} ran · ${fmtInt(v.na)} not run of ${fmtInt(v.n)}`],
              })), { key: "__rest", status: "OK", onOpen: null, cells: ["Everywhere else", <MiniBar key="b" value={rest} max={rest} />, `${fmtInt(rest)} ran of ${fmtInt(rest)}`] }]} />
          ) : <div className="chart-note-oneline">Every area's checks ran.</div>}
        </ChartCard>
        <ChartCard title="An empty panel means could not look, or nothing yet" subtitle="never a verified zero · how to read the kinds of empty" takeaway={null}>
          <DrillTable aria="Kinds of empty" n={3}
            cols={[{ label: "On screen" }, { label: "Means", width: "minmax(100px, 2fr)" }, { label: "Checks", num: true, width: "auto" }]}
            rows={[
              { key: "na", status: "NOT_ASSESSED", cells: ["–", "the check could not look: a grant, an edition or the export", fmtInt(counts.NOT_ASSESSED + counts.ERROR)] },
              { key: "nd", status: "OK", cells: ["No data", "it ran and the window held nothing to judge", fmtInt(counts.EMPTY_WINDOW + counts.EMPTY_FILTERS)] },
              { key: "zero", status: "OK", cells: ["0 of N", "it ran, looked and found none: the only true zero", "–"] },
            ]} />
          <div className="chart-note-oneline">Money follows the same rule: a check that did not run shows "–", not $0, and is never added to spend, waste or saving.</div>
        </ChartCard>
      </div>
      {gaps.length > 0 && (
        <HomeChecksList goTo={goTo} title={`Could judge nothing this window · ${fmtInt(gaps.length)} checks`} rows={asRows(gaps)} n={8} />
      )}
    </div>
  );
}

// ═══════════════════════ Known limitations ═══════════════════════

// Plain notes only, where a limitation changes how to read a number elsewhere in the app, and the
// pages it applies to.
export const CV_LIMITATIONS: { title: string; note: string; where: { tab: string; subtab?: string; label: string }[] }[] = [
  {
    title: "Cloud services: the 10% adjustment",
    note: "Snowflake gives back up to 10% of daily compute credits as cloud services. Only the part above that allowance is billed, so cloud services are priced after the adjustment, never at face value.",
    where: [{ tab: "cost", subtab: "service", label: "Cost › By service" }, { tab: "sharing", subtab: "spend", label: "Org spend" }],
  },
  {
    title: "Query attribution is not a total",
    note: "Credits attributed to queries leave out idle warehouse time and statements under about 100 ms, are empty on adaptive warehouses, and lag up to 8 hours. Spend by user, role, tag or dashboard adds up to less than the warehouse bill; the idle remainder is shown apart.",
    where: [{ tab: "cost", subtab: "who", label: "Cost › Who spent it" }, { tab: "cost", subtab: "chargeback", label: "Chargeback" }],
  },
  {
    title: "Views show only what the role can see",
    note: "SHOW commands and several views list only the objects the audit role has a privilege on. A warehouse, task or pipe the role cannot see is missing from its check, not clean. Grant MONITOR to widen them.",
    where: [{ tab: "warehouses", subtab: "idle", label: "Warehouses" }, { tab: "tasks", subtab: "failures", label: "Tasks" }, { tab: "loading", subtab: "pipes", label: "Loading" }],
  },
  {
    title: "Data lags",
    note: "ACCOUNT_USAGE views lag up to a few hours, query attribution up to 8 hours, and the organization billing views up to 72 hours. Today is shown partial: its figures are not final.",
    where: [],
  },
  {
    title: "Fail-safe tables have no name",
    note: "A table that has been dropped but is still in Fail-safe can appear with a NULL name and pass as live. The storage checks read both TABLE_ID and BASE_TABLE_ID while Snowflake rolls that rename out.",
    where: [{ tab: "storage", subtab: "unused", label: "Storage › Unused" }, { tab: "storage", subtab: "retention", label: "Time Travel" }],
  },
  {
    title: "Some policies are not listed",
    note: "POLICY_REFERENCES does not list session, password or authentication policies, so their coverage is read from the account and user settings instead.",
    where: [{ tab: "access", subtab: "perimeter", label: "Access › Perimeter" }, { tab: "pii", subtab: "policies", label: "PII › Masking" }],
  },
];

function WhereLinks({ where, goTo }: { where: { tab: string; subtab?: string; label: string; focus?: string }[]; goTo: GoToFn }) {
  if (!where.length) return <span className="muted">Every page</span>;
  return (
    <span>
      {where.map((w, i) => (
        <React.Fragment key={`${w.tab}|${w.subtab}|${w.focus || ""}`}>
          {i > 0 && " · "}
          <button type="button" className="ck-link" onClick={() => goTo({ tab: w.tab, subtab: w.subtab || null, focusQueryId: w.focus || null })}>{w.label}</button>
        </React.Fragment>
      ))}
    </span>
  );
}

export function CoverageLimitsPanel({ goTo, allFindingsIndex, filters, meta, onVerdict }: CoveragePanelProps) {
  const { cov, error } = useCoverageWithError();
  const fresh = useFreshness(filters);
  const truncated = cov ? (cov.truncated_query_ids || []) : [];
  const wh = cov && cov.visibility && cov.visibility.warehouses;
  const ran = ranCountsOf(meta);
  const direct = meta && meta.direct_export;
  const partialToday = !!(direct && direct.includes_today);
  const n = CV_LIMITATIONS.length + (truncated.length ? 1 : 0);
  useCvLede(onVerdict, !cov ? "…"
    : `${fmtInt(n)} things still limit these numbers: ${fmtInt(CV_LIMITATIONS.length)} are how Snowflake records usage${truncated.length ? ", 1 is an export row cap" : ""}. Each page says where one applies.`);
  const homeOf = (qid: string) => {
    const h = homeForQuery({ query_id: qid });
    const area = AREA_REGISTRY[h.tab];
    const sub = area && (area.subtabs || []).find((s) => s.key === h.subtab);
    return { tab: h.tab, subtab: h.subtab || undefined, focus: qid, label: area ? `${area.label}${sub ? ` › ${sub.label}` : ""}` : h.tab };
  };
  const rows = [
    ...(truncated.length ? [{
      key: "cap", status: "WARN",
      cells: ["Export row cap hit", `Only the first rows per window were kept for ${truncated.map((q) => getCheckLabel(q, allFindingsIndex && allFindingsIndex[q] ? allFindingsIndex[q].title : q).title).join(", ")}: shares hold, totals are low.`,
        <WhereLinks key="w" goTo={goTo} where={truncated.map(homeOf)} />, `${fmtInt(truncated.length)} check${truncated.length === 1 ? "" : "s"}`],
    }] : []),
    ...CV_LIMITATIONS.map((l) => ({
      key: l.title, status: "OK",
      cells: [l.title, l.note, <WhereLinks key="w" goTo={goTo} where={l.where} />,
        l.title.startsWith("Views show") && wh && wh.missing > 0 ? `– ${fmtInt(wh.missing)} of ${fmtInt(wh.billed)} ${wh.unit || "warehouses"}`
          : l.title === "Data lags" && partialToday ? "today partial" : ""],
    })),
  ];
  return (
    <div>
      {error && <div className="honest-card error"><div className="h-title">Could not read coverage</div><div className="h-note mono">{error}</div></div>}
      <div className="cv-tiles">
        <StatStrip ariaLabel="What limits these numbers" cells={[
          { key: "notes", label: "General notes", value: fmtInt(CV_LIMITATIONS.length), base: "how Snowflake records usage" },
          { key: "cap", label: "Row cap hit", value: cov ? fmtInt(truncated.length) : null, unit: ran ? ` of ${fmtInt(ran.total)} checks` : undefined, base: truncated.length ? "first rows per window kept" : "no check cut short", missing: cov ? undefined : "…", pill: truncated.length ? "warn" : null },
          { key: "wh", label: "Warehouses visible", value: wh ? fmtInt(wh.visible) : null, unit: wh ? ` of ${fmtInt(wh.billed)}` : undefined, base: wh ? "SHOW lists what the role can see" : undefined, missing: cov ? "not probed in this export" : "…", pill: wh && wh.missing > 0 ? "not_assessed" : null },
          { key: "today", label: "Today", value: direct ? (partialToday ? "½" : "complete") : null, base: partialToday ? "shown partial everywhere" : undefined, missing: "not recorded in this export" },
          { key: "ed", label: "Edition", value: cov && cov.edition && cov.edition.edition ? (CV_EDITION_WORDS[cov.edition.edition] || cov.edition.edition) : null, base: cov && cov.edition && cov.edition.source === "feature_evidence" ? "or higher, from features used" : "from the organization accounts view", missing: "not detected: none assumed" },
        ]} />
      </div>
      <ChartCard title="What the audit cannot see, and why" subtitle={`${plural(rows.length, "limitation")} · what each does to the numbers · where it bites`} takeaway={null}>
        <div className="cv-limits">
          <DrillTable aria="Known limitations" n={rows.length}
            cols={[{ label: "Limitation" }, { label: "What it does to the numbers", width: "minmax(140px, 3fr)" }, { label: "Where it bites", width: "minmax(90px, 1.4fr)" }, { label: "Here", num: true, width: "auto" }]}
            rows={rows} />
        </div>
      </ChartCard>
      <div className="cj-charts-2">
        <ChartCard title="Normal delay, by source" subtitle="Snowflake's documented delay per view, as the export recorded it · today is shown partial for this reason" takeaway={null}>
          {fresh.rows ? (
            <StatusBars n={12} ariaLabel="Normal delay per view"
              items={fresh.rows.filter((r) => r.expected_latency_hours != null).map((r): StatusBarItem => ({
                key: String(r.source_view), name: String(r.source_view || "(unknown view)"), value: numOrZero(r.expected_latency_hours), status: "OK",
                valueText: fmtDuration(numOrZero(r.expected_latency_hours) * 3600),
              }))} />
          ) : <div className="chart-note-oneline">{fresh.loading ? "…" : `– ${fresh.why}`}</div>}
        </ChartCard>
      </div>
    </div>
  );
}

const CV_EDITION_WORDS: Record<string, string> = { STANDARD: "Standard", ENTERPRISE: "Enterprise", BUSINESS_CRITICAL: "Business Critical" };
const plural = (n: number, one: string) => `${fmtInt(n)} ${n === 1 ? one : `${one}s`}`;

AreaContent.register("coverage", "sources", CoverageSourcesPanel);
AreaContent.register("coverage", "couldnt", CoverageCouldntPanel);
AreaContent.register("coverage", "limits", CoverageLimitsPanel);
