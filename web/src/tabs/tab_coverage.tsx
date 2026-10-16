// web/src/tabs/tab_coverage.tsx -- Coverage & Gaps: sub-tabs sources / couldnt / limits.
// "An empty panel means could not look or nothing yet, never a verified zero". A view the audit role
// cannot see, an edition too low, a failed check: each reads NOT ASSESSED with the reason and the way
// to get access, never "nothing found". The "checks that ran" count here is the same one the top bar
// and Overview show (meta.checks_ran, read through ranCountsOf in primitives.tsx).
import { FixCopyButton } from "../components/fixcopy_button";
import React from "react";
import { Api } from "../api";
import { fmtDayShort, fmtInt, fmtMoney } from "../format";
import { numOrZero, sumBy, useFindingData } from "../components/hooks";
import { ChartCard, bandOf, isUncertainBand, noDataText, ranCountsOf } from "../components/primitives";
import { AreaContent } from "../area_content";
import { getCheckLabel } from "../components/labels";
import { IssueTile, fmtShare, pctOf } from "../components/blocks";
import { SummaryTileRow } from "../components/overview_tile";
import "../styles/css/p_area_governance.css";
import { notAssessedText } from "../components/scope";
import { AREA_REGISTRY, homeForQuery } from "../components/tab_registry";
import { CxBars, CxCellBar, CxTable, afHomeOf, fmtDur } from "../components/cx_d";
import type { CxRow } from "../components/cx_d";
import { navHref } from "../components/nav_hash";
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
const isFlaggedRow = (r: Row) => r.status === "CRITICAL" || r.status === "WARN";
const plural = (n: number, one: string) => `${fmtInt(n)} ${n === 1 ? one : `${one}s`}`;

// The grant that lets SHOW WAREHOUSES list a warehouse the role cannot see yet.
const WH_GRANT = "GRANT MONITOR ON WAREHOUSE <warehouse> TO ROLE <audit_role>;";

/** A grant line in mono with its own Copy button. */
function GrantLine({ text }: { text: string }) {
  return (
    <div className="cv-grant-box" onClick={(e) => e.stopPropagation()}>
      <code>{text}</code>
      <FixCopyButton text={text} />
    </div>
  );
}

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
  const queries = rows ? sumBy(rows, "matched_statement_count") : null;
  return (
    <div className="cv-audit">
      <div className="cv-audit-value">{value || "–"}{value && value !== "…" && <span className="cv-audit-unit">for this export</span>}</div>
      {why && <div className="cv-audit-line">{why}</div>}
      {rows && rows.length > 0 && <div className="cv-audit-line">{`${fmtInt(numOrZero(queries))} quer${numOrZero(queries) === 1 ? "y" : "ies"} on ${plural(rows.length, "warehouse")}.`}</div>}
    </div>
  );
}

/** The views' freshness: one sentence and chips when none is late; ranked lag bars when some are. */
function SourceFreshness({ fresh, meta, filters }: { fresh: ReturnType<typeof useFreshness>; meta: Meta | null; filters: Filters }) {
  if (!fresh.rows) return <div className="chart-note-oneline">{fresh.loading ? "…" : fresh.why === "no data in this window" ? noDataText(meta, filters.window) : `– ${fresh.why}`}</div>;
  const rows = fresh.rows.filter((r) => lagHours(r) != null);
  const late = rows.filter(isFlaggedRow);
  const normal = rows.map((r) => numOrZero(r.expected_latency_hours)).filter((h) => h > 0);
  const byDelay = [...rows].sort((a, b) => numOrZero(a.expected_latency_hours) - numOrZero(b.expected_latency_hours) || String(a.source_view).localeCompare(String(b.source_view)));
  if (!late.length) {
    return (
      <div>
        <div className="cv-fresh-ok"><span aria-hidden="true">✓</span>
          {`All ${plural(rows.length, "usage view")} are on time: none is behind its normal delay${normal.length ? `, which runs from ${fmtDur(Math.min(...normal) * 3600)} to ${fmtDur(Math.max(...normal) * 3600)}` : ""}.`}
        </div>
        <div className="cv-chips">
          {byDelay.map((r) => (
            <span key={String(r.source_view)} className="cxd-chip">{String(r.source_view || "(unknown view)")}
              {r.expected_latency_hours != null && <span className="cv-chip-h">{` ${fmtDur(numOrZero(r.expected_latency_hours) * 3600)}`}</span>}
            </span>
          ))}
        </div>
        <div className="cxd-foot">Normal delay shown after each view.</div>
      </div>
    );
  }
  return (
    <CxBars n={12} noun="views" ariaLabel="Hours each view is behind"
      items={[...rows].sort((a, b) => lagHours(b)! - lagHours(a)!).map((r) => ({
        key: String(r.source_view), name: String(r.source_view || "(unknown view)"), value: lagHours(r)!, status: r.status,
        valueText: `${fmtDur(lagHours(r)! * 3600)} behind`,
        extra: `normal ${r.expected_latency_hours != null ? fmtDur(numOrZero(r.expected_latency_hours) * 3600) : "–"}`,
      }))} />
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
  const late = (fresh.rows || []).filter(isFlaggedRow).length;
  const bands = Object.values(allFindingsIndex || {}).map((f) => bandOf(f));
  const nBand = (b: string) => bands.filter((x) => x === b).length;
  useCvLede(onVerdict, !cov || !ran ? "…" : [
    `${fmtInt(ran.assessed)} of ${fmtInt(ran.total)} ${ran.unit} ran${entries.length ? (readOk === entries.length ? `, and all ${fmtInt(entries.length)} Snowflake views and commands were readable.` : `; ${fmtInt(readOk)} of ${fmtInt(entries.length)} Snowflake views and commands were readable.`) : "."}`,
    wh ? `The role sees ${fmtInt(wh.visible)} of ${fmtInt(wh.billed)} billed ${wh.unit || "warehouses"}${wh.missing > 0 ? `; the other ${fmtInt(wh.missing)} are missing from warehouse checks, not clean` : ""}.` : null,
  ].filter(Boolean).join(" "));
  if (error) return <div className="honest-card error"><div className="h-title">Could not read coverage</div><div className="h-note">Couldn't read the coverage summary from this export.</div></div>;
  if (!cov) return <div className="loading-note">…</div>;

  const grouped: Record<string, [string, CoverageSource][]> = {};
  entries.forEach(([key, info]) => { (grouped[cvGroupForKey(key)] = grouped[cvGroupForKey(key)] || []).push([key, info]); });
  const noExport = cov.export_mode === "none";
  const families = CV_GROUP_ORDER.filter((g) => grouped[g]).map((g) => {
    const list = grouped[g];
    const ok = list.filter(([, i]) => state(i) === "ok" || state(i) === "empty").length;
    return { g, ok, bad: list.length - ok };
  });
  const familyRows: CxRow[] = [
    ...families.map((f) => ({
      key: f.g, title: CV_GROUP_NOTE[f.g],
      cells: [/^[A-Z_]+$/.test(f.g) ? <span key="c" className="cxd-chip">{f.g}</span> : f.g, <b key="r">{fmtInt(f.ok)}</b>, fmtInt(f.bad),
        <span key="s" className="cv-state"><span className={`cxd-dot ${f.bad ? "na" : "ok"}`} aria-hidden="true" />{f.bad ? `${fmtInt(f.bad)} not readable` : "All read"}</span>],
    })),
    { key: "__total", cells: [<b key="t">Total</b>, <b key="r">{fmtInt(readOk)}</b>, <b key="n">{fmtInt(entries.length - readOk)}</b>, ""] },
  ];
  return (
    <div className="cxd cv-page">
      {noExport && <div className="page-intro-verdict">Nothing has been exported yet: no source has been read.</div>}
      <div className="cv-tiles">
        <SummaryTileRow compact>
          <IssueTile label="Checks that ran" headline={ran ? fmtShare(pctOf(ran.assessed, ran.total)) : null} loading={!ran} unit={ran ? `${fmtInt(ran.assessed)} of ${fmtInt(ran.total)}` : undefined} pill={null}
            base={ran ? `${fmtInt(nBand("CRITICAL"))} critical · ${fmtInt(nBand("WARN"))} warning.` : null}
            cause={ran && ran.total > ran.assessed ? `${fmtInt(ran.total - ran.assessed)} did not run; Not assessed lists them.` : "Every check ran."}
            onOpen={() => goTo({ tab: "coverage", subtab: "couldnt" })} openLabel="Which ones →" />
          <IssueTile label="Sources read" headline={entries.length ? fmtShare(pctOf(readOk, entries.length)) : null} unit={`${fmtInt(readOk)} of ${fmtInt(entries.length)}`} pill={null}
            missingReason="no source in this export"
            base={unreadable.length ? `${fmtInt(unreadable.length)} the role cannot read: the grant is in the sources list.` : "Every usage view and SHOW command was readable."}
            cause={truncated.length ? `${plural(truncated.length, "check")} hit the export row cap.` : "None hit the export row cap."}
            onOpen={() => setShowSources(true)} openLabel="By family ↓" />
          <IssueTile label="Warehouses seen" headline={wh ? fmtShare(pctOf(wh.visible, wh.billed)) : null} unit={wh ? `${fmtInt(wh.visible)} of ${fmtInt(wh.billed)} billed` : undefined}
            missingReason={vis ? "billed vs listed could not be compared" : "not probed in this export"}
            base={wh ? (wh.missing > 0 ? `${fmtInt(wh.missing)} bill but are missing from SHOW WAREHOUSES — not assessed, not clean.` : "SHOW WAREHOUSES lists every warehouse that billed.") : null}
            cause={wh && wh.missing > 0 ? <GrantLine text={WH_GRANT} /> : null}
            status={!wh || wh.missing > 0 ? "not_assessed" : "neutral"}
            onOpen={() => goTo({ tab: "coverage", subtab: "limits" })} openLabel="Known limitations →" />
        </SummaryTileRow>
      </div>
      <div className="cv-tiles cv-wide-tile">
        <IssueTile label="Views running late" loading={fresh.loading} headline={fresh.rows ? fmtInt(late) : null} unit={fresh.rows ? `of ${plural(fresh.rows.length, "view")}` : undefined}
          missingReason={fresh.why} status={fresh.rows ? (late ? "warn" : "neutral") : "not_assessed"}
          base={fresh.rows ? (late ? `${plural(late, "view")} ${late === 1 ? "is" : "are"} further behind than Snowflake documents.` : "Each view's newest row is within its normal delay.") : null}
          cause={fresh.rows ? "A late view would make the newest days look low." : null}
          onOpen={() => { const el = document.getElementById("cv-fresh"); if (el) el.scrollIntoView({ behavior: "smooth", block: "start" }); }} openLabel="Source freshness ↓" />
      </div>

      <div className="card cv-card">
        <div className="cxd-card-head">
          <div>
            <div className="card-title">Sources by state</div>
            <div className="cxd-card-sub">{`${fmtInt(entries.length)} views and commands, by family · read, or not readable`}</div>
          </div>
          <div className="cxd-card-right">
            <button type="button" className="ck-link" onClick={() => setShowSources(!showSources)} aria-expanded={showSources}>
              {showSources ? "Hide the sources list" : `Show all ${fmtInt(entries.length)} sources →`}
            </button>
          </div>
        </div>
        <CxTable aria="Sources by family" rows={familyRows}
          cols={[{ label: "Family" }, { label: "Read", num: true, width: "110px" }, { label: "Not readable", num: true, width: "130px" }, { label: "State", width: "180px" }]} />
        {truncated.length > 0 && <div className="cxd-foot">{`${plural(truncated.length, "check")} hit the export row cap: only the first rows per window were kept.`}</div>}
      </div>

      {showSources && (
        <div className="card cv-card">
          <CxTable aria="Every source" rows={CV_GROUP_ORDER.filter((g) => grouped[g]).flatMap((g) => grouped[g].map(([key, info]): CxRow => {
            const st = state(info);
            const grant = unreadable.find((u) => u.source === key);
            const range = st === "not_assessed" ? "–" : info.covers === "window" ? (info.window_days ? `last ${fmtInt(info.window_days)} d` : "trailing window") : "current state";
            return {
              key, status: st === "ok" || st === "empty" ? "OK" : "NOT_ASSESSED",
              cells: [<span key="k" className="cxd-mono">{key}</span>, info.checks_total ? `${fmtInt(info.checks_ok || 0)} of ${fmtInt(info.checks_total)}` : "–", range,
                st === "empty" ? "Read, 0 rows: a true zero, or a feature this account does not use."
                  : st !== "ok" ? <span>{cvReasonText(info)}{grant && grant.grant && <span className="cv-grant">{` ${grant.grant}`}</span>}</span> : ""],
            };
          }))}
            cols={[{ label: "Source" }, { label: "Checks OK", num: true }, { label: "Covers" }, { label: "If not read: why, and the grant" }]} />
        </div>
      )}

      <div className="cj-charts-2 cv-row">
        <div id="cv-fresh">
          <ChartCard title="Source freshness" subtitle="How far each usage view is behind, against its normal delay" takeaway={null}>
            <SourceFreshness fresh={fresh} meta={meta} filters={filters} />
          </ChartCard>
        </div>
        <ChartCard title="What this audit cost" subtitle="Kept apart from the account's spend" takeaway={null}>
          <AuditSelfCost filters={filters} />
        </ChartCard>
      </div>
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

/** A home-tab link: "Warehouses › Idle & settings →". */
function HomeLink({ qid, goTo }: { qid: string; goTo: GoToFn }) {
  const home = afHomeOf({ query_id: qid });
  if (!home) return <span className="muted">–</span>;
  return (
    <a className="cxd-where" href={navHref({ tab: home.tab, subtab: home.subtab, focus: qid })}
      onClick={(e) => { e.preventDefault(); goTo({ tab: home.tab, subtab: home.subtab, focusQueryId: qid }); }}>{`${home.text} →`}</a>
  );
}

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
    ? `${fmtInt(notOk.length)} of ${fmtInt(total)} checks are not in this export${groups.length === 1 && groups[0].label ? `: ${groups[0].label}` : ""}. Their panels show "–": the check could not look, which is never a verified zero.`
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
  const hit = [...byHome.entries()].filter(([, v]) => v.na > 0).sort((a, b) => b[1].n - a[1].n);
  const rest = [...byHome.entries()].filter(([, v]) => v.na === 0).reduce((s, [, v]) => s + v.n, 0);
  const maxHome = Math.max(rest, ...hit.map(([, v]) => v.n));

  // One list: every check that judged nothing, plus a check the export lists as not OK although it ran.
  const reasonOf = (f: Finding) => (f.not_assessed && f.not_assessed.label) || "did not run";
  const gapIds = new Set(gaps.map((f) => f.query_id));
  const merged: { qid: string; title: string; band: string; window: string }[] = [
    ...gaps.map((f) => {
      const b = bandOf(f);
      const c = notOk.find((x) => x.query_id === f.query_id);
      const why = (c && (c.reason_label || (c.cause && CV_CAUSE[c.cause]))) || reasonOf(f);
      return {
        qid: f.query_id, title: getCheckLabel(f.query_id, f.title).title, band: b,
        window: b === "EMPTY_WINDOW" ? "Ran; nothing in the window to judge" : b === "EMPTY_FILTERS" ? "Ran; the filters exclude every row"
          : b === "ERROR" ? `Could not read it: ${why}` : `Could judge nothing: ${why}`,
      };
    }),
    ...notOk.filter((c) => !gapIds.has(c.query_id)).map((c) => ({
      qid: c.query_id, title: getCheckLabel(c.query_id, (allFindingsIndex && allFindingsIndex[c.query_id] && allFindingsIndex[c.query_id].title) || c.title).title,
      band: "NOT_ASSESSED", window: `Ran; ${c.reason_label || (c.cause && CV_CAUSE[c.cause]) || "no row could be assessed"}`,
    })),
  ];
  const nNa = merged.filter((m) => m.band === "NOT_ASSESSED" || m.band === "ERROR").length;
  const nRanNa = merged.length - gaps.length;
  const listTitle = nNa === merged.length ? `The ${plural(merged.length, "check")} not assessed` : `The ${plural(merged.length, "check")} that judged nothing`;
  const listSub = [gaps.length ? `${fmtInt(gaps.length)} could judge nothing this window` : null, nRanNa ? `${fmtInt(nRanNa)} ran but could not assess any row` : null].filter(Boolean).join("; ");

  return (
    <div className="cxd cv-page">
      <div className="cv-tiles">
        <SummaryTileRow compact>
          <IssueTile label="Not in this export" loading={!cov} headline={cov ? fmtInt(notOk.length) : null} unit={` of ${fmtInt(total)} checks · ${fmtShare(pctOf(notOk.length, total))}`}
            status={notOk.length ? "not_assessed" : "neutral"} pill={notOk.length ? undefined : null}
            base={notOk.length ? `${groups.length === 1 ? "One reason" : `${fmtInt(groups.length)} reasons`}${grants.length ? `, fixed by ${grants.length === 1 ? "one grant" : `${fmtInt(grants.length)} grants`}` : ""}.` : "Every check ran."}
            onOpen={grants.length ? () => { const el = document.getElementById("cv-grants"); if (el) el.scrollIntoView({ behavior: "smooth", block: "start" }); } : undefined} openLabel="What to grant ↓" />
          <IssueTile label="Could judge nothing this window" headline={fmtInt(gaps.length)} unit={` of ${fmtInt(all.length)} checks`} pill={null}
            base={`${fmtInt(counts.NOT_ASSESSED)} not assessed · ${fmtInt(counts.ERROR)} read errors · ${fmtInt(counts.EMPTY_WINDOW)} nothing in window · ${fmtInt(counts.EMPTY_FILTERS)} excluded by filters.`}
            cause={`Not assessed reads "–"; nothing in the window reads No data. Neither is a pass.`} />
        </SummaryTileRow>
      </div>
      {error && <div className="honest-card error"><div className="h-title">Could not read coverage</div><div className="h-note">Couldn't read the list of checks that did not run from this export.</div></div>}
      {merged.length > 0 && (
        <div className="card cv-card">
          <div className="cxd-card-head">
            <div>
              <div className="card-title">{listTitle}</div>
              {listSub && <div className="cxd-card-sub">{listSub}</div>}
            </div>
          </div>
          <CxTable aria="Checks that judged nothing"
            cols={[{ label: "Status", width: "150px" }, { label: "Check" }, { label: "This window", width: "260px" }, { label: "Where", width: "250px" }]}
            rows={merged.map((m) => ({
              key: m.qid,
              cells: [<span key="s" className={m.band === "NOT_ASSESSED" || m.band === "ERROR" ? "cv-na-chip" : "cv-nd-chip"}>{m.band === "NOT_ASSESSED" || m.band === "ERROR" ? "Not assessed" : "No data"}</span>,
                m.title, <span key="w" className="cv-why">{m.window}</span>, <HomeLink key="h" qid={m.qid} goTo={goTo} />],
            }))} />
          {grants.length > 0 && (
            <div className="cv-grants" id="cv-grants">
              <div className="cv-grants-head">
                <b>What to grant — run as ACCOUNTADMIN, then export again</b>
                <FixCopyButton text={grants.join("\n")} label={grants.length === 1 ? "Copy" : grants.length === 2 ? "Copy both" : "Copy all"} />
              </div>
              {grants.map((g) => <pre key={g} className="dr-fix">{g}</pre>)}
              {groups[0] && groups[0].fix && <div className="cxd-foot">{groups[0].fix}</div>}
            </div>
          )}
        </div>
      )}
      <div className="cj-charts-2 cv-row cv-row-even">
        <ChartCard title="Where the gaps sit" subtitle="Checks per area · the hatched part did not run" takeaway={null}>
          {hit.length ? (
            <CxTable aria="Not-run checks by area"
              cols={[{ label: "Area" }, { label: "Ran", cls: "c-bar" }, { label: "", num: true }, { label: "Not run", num: true }, { label: "Checks", num: true }]}
              rows={[...hit.map(([k, v]) => ({
                key: k, onOpen: () => goTo({ tab: k }),
                cells: [AREA_REGISTRY[k] ? AREA_REGISTRY[k].label : k, <span key="b" className="cv-ranbar" style={{ width: `${(100 * v.n) / maxHome}%` }}><CxCellBar value={v.n - v.na} max={v.n} /></span>,
                  fmtInt(v.n - v.na), <b key="na">{fmtInt(v.na)}</b>, fmtInt(v.n)],
              })), { key: "__rest", cells: ["Everywhere else", <span key="b" className="cv-ranbar" style={{ width: `${(100 * rest) / maxHome}%` }}><CxCellBar value={rest} max={rest} /></span>, fmtInt(rest), "0", fmtInt(rest)] }]} />
          ) : <div className="chart-note-oneline">Every area's checks ran.</div>}
        </ChartCard>
        <ChartCard title="What an empty panel means" subtitle="Could not look, or nothing yet — never a verified zero" takeaway={null}>
          <CxTable aria="Kinds of empty"
            cols={[{ label: "On screen", width: "90px" }, { label: "Means" }, { label: "Checks", num: true }]}
            rows={[
              { key: "na", cells: [<b key="d">–</b>, "Not assessed. The check could not look: a grant is missing or its source is not in this export.", fmtInt(counts.NOT_ASSESSED + counts.ERROR)] },
              { key: "nd", cells: [<b key="d">No data</b>, "The check ran, but the window held nothing to judge, or your filters exclude every row.", fmtInt(counts.EMPTY_WINDOW + counts.EMPTY_FILTERS)] },
              { key: "zero", cells: [<b key="d">0 of N</b>, "The check ran, looked at every row and found none. This is a verified zero.", "–"] },
            ]} />
          <div className="cxd-foot">Money follows the same rule: a check that did not run shows "–", not $0, and is never added to spend, waste or saving.</div>
        </ChartCard>
      </div>
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
    note: "ACCOUNT_USAGE views lag up to a few hours, query attribution up to 8 hours, and the organization billing views up to 72 hours. When an export includes today, today is shown partial: its figures are not final.",
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
  if (!where.length) return <span>Every page</span>;
  return (
    <span>
      {where.map((w, i) => (
        <React.Fragment key={`${w.tab}|${w.subtab}|${w.focus || ""}`}>
          {i > 0 && " · "}
          <button type="button" className="ck-link" onClick={() => goTo({ tab: w.tab, subtab: w.subtab || null, focusQueryId: w.focus || null })}>{w.label}</button>
        </React.Fragment>
      ))}
      {" →"}
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
    : `${fmtInt(n)} things still limit these numbers, ${truncated.length ? `${fmtInt(CV_LIMITATIONS.length)} in how Snowflake records usage and 1 an export row cap` : "all of them in how Snowflake records usage"}. Each page says where one applies.`);
  const homeOf = (qid: string) => {
    const h = homeForQuery({ query_id: qid });
    const area = AREA_REGISTRY[h.tab];
    const sub = area && (area.subtabs || []).find((s) => s.key === h.subtab);
    return { tab: h.tab, subtab: h.subtab || undefined, focus: qid, label: area ? `${area.label}${sub ? ` › ${sub.label}` : ""}` : h.tab };
  };
  const rows: CxRow[] = [
    ...(truncated.length ? [{
      key: "cap", status: "WARN",
      cells: [<b key="t">Export row cap hit</b>, `Only the first rows per window were kept for ${truncated.map((q) => getCheckLabel(q, allFindingsIndex && allFindingsIndex[q] ? allFindingsIndex[q].title : q).title).join(", ")}: shares hold, totals are low.`,
        <WhereLinks key="w" goTo={goTo} where={truncated.map(homeOf)} />],
    }] : []),
    ...CV_LIMITATIONS.map((l) => ({
      key: l.title,
      cells: [<b key="t">{l.title}</b>,
        <span key="n">{l.note}{l.title.startsWith("Views show") && wh && wh.missing > 0 && <b>{` Here: ${fmtInt(wh.missing)} of ${fmtInt(wh.billed)} ${wh.unit || "warehouses"} are not visible.`}</b>}
          {l.title === "Data lags" && direct && <b>{partialToday ? " Here: today is in this export and shown partial." : " Here: this export stops before today."}</b>}</span>,
        <WhereLinks key="w" goTo={goTo} where={l.where} />],
    })),
  ];
  const delays = (fresh.rows || []).filter((r) => r.expected_latency_hours != null)
    .sort((a, b) => numOrZero(b.expected_latency_hours) - numOrZero(a.expected_latency_hours) || String(a.source_view).localeCompare(String(b.source_view)));
  const maxDelay = Math.max(0, ...delays.map((r) => numOrZero(r.expected_latency_hours)));
  const edition = cov && cov.edition && cov.edition.edition ? (CV_EDITION_WORDS[cov.edition.edition] || cov.edition.edition) : null;
  const scrollTo = (id: string) => () => { const el = document.getElementById(id); if (el) el.scrollIntoView({ behavior: "smooth", block: "start" }); };
  return (
    <div className="cxd cv-page">
      {error && <div className="honest-card error"><div className="h-title">Could not read coverage</div><div className="h-note">Couldn't read the coverage summary from this export.</div></div>}
      <div className="cv-tiles">
        <SummaryTileRow compact>
          <IssueTile label="Known limitations" headline={fmtInt(CV_LIMITATIONS.length)} unit="general notes" pill={null}
            base={truncated.length ? "How Snowflake records usage, plus the export row cap." : `All ${CV_LIMITATIONS.length === 6 ? "six" : fmtInt(CV_LIMITATIONS.length)} come from how Snowflake records usage.`}
            onOpen={scrollTo("cv-limits")} openLabel="Read them ↓" />
          <IssueTile label="Row cap hit" loading={!cov} headline={cov ? fmtInt(truncated.length) : null} unit={ran ? `of ${fmtInt(ran.total)} checks` : undefined}
            status={truncated.length ? "warn" : "neutral"} pill={truncated.length ? undefined : null}
            base={truncated.length ? "Only the first rows per window were kept: shares hold, totals are low." : "No check was cut short by the export row cap."} />
          <IssueTile label="Warehouses visible" loading={!cov} headline={wh ? fmtInt(wh.visible) : null} unit={wh ? `of ${fmtInt(wh.billed)}` : undefined}
            missingReason="not probed in this export" status={wh && wh.missing > 0 ? "not_assessed" : "neutral"} pill={wh && wh.missing > 0 ? undefined : null}
            base={wh ? (wh.missing > 0 ? `SHOW lists only what the role can see; the other ${fmtInt(wh.missing)} are not assessed.` : "SHOW lists every warehouse that billed.") : null}
            onOpen={wh && wh.missing > 0 ? () => goTo({ tab: "coverage", subtab: "couldnt" }) : undefined} openLabel="Not assessed →" />
        </SummaryTileRow>
      </div>
      <div className="cv-strip" role="list" aria-label="Today and edition">
        <div className="cv-strip-cell" role="listitem">
          <div className="cv-strip-label">Today</div>
          <div className="cv-strip-value">{direct ? (partialToday ? "Partial" : "Not included") : "–"}</div>
          <div className="cv-strip-base">{direct
            ? (partialToday ? "Today is in this export: its figures are shown partial everywhere." : `The export stops at ${direct.last_complete_day ? fmtDayShort(direct.last_complete_day) : "the last complete day"}, so every day shown is complete.`)
            : "Not recorded in this export."}</div>
        </div>
        <div className="cv-strip-cell" role="listitem">
          <div className="cv-strip-label">Edition</div>
          <div className="cv-strip-value">{edition || "–"}</div>
          <div className="cv-strip-base">{!edition ? "Not detected: none assumed." : cov && cov.edition && cov.edition.source === "feature_evidence" ? "Or higher, from the features used." : "From the organization accounts view."}</div>
        </div>
      </div>
      <div className="card cv-card" id="cv-limits">
        <div className="cxd-card-head">
          <div>
            <div className="card-title">What the audit cannot see, and why</div>
            <div className="cxd-card-sub">{`${plural(rows.length, "limitation")} · what each does to the numbers · where it bites`}</div>
          </div>
        </div>
        <CxTable aria="Known limitations" rows={rows}
          cols={[{ label: "Limitation", width: "22%" }, { label: "What it does to the numbers" }, { label: "Where it bites", width: "20%" }]} />
      </div>
      <div className="card cv-card">
        <div className="cxd-card-head">
          <div>
            <div className="card-title">Normal delay, by source</div>
            <div className="cxd-card-sub">Snowflake's documented delay per view, as the export recorded it · the reason a day in progress is shown partial</div>
          </div>
          <div className="cxd-card-right"><button type="button" className="ck-link" onClick={() => goTo({ tab: "coverage", subtab: "sources" })}>Data sources →</button></div>
        </div>
        {fresh.rows ? (
          delays.length ? (
            <div className="cv-delay" role="list" aria-label="Normal delay per view">
              {delays.map((r) => (
                <div key={String(r.source_view)} className="cv-delay-row" role="listitem">
                  <span className="cxd-mono cv-delay-name">{String(r.source_view || "(unknown view)")}</span>
                  <CxCellBar value={numOrZero(r.expected_latency_hours)} max={maxDelay} />
                  <b className="cv-delay-val">{fmtDur(numOrZero(r.expected_latency_hours) * 3600)}</b>
                </div>
              ))}
            </div>
          ) : <div className="chart-note-oneline">The export recorded no normal delay per view.</div>
        ) : <div className="chart-note-oneline">{fresh.loading ? "…" : `– ${fresh.why}`}</div>}
      </div>
    </div>
  );
}

const CV_EDITION_WORDS: Record<string, string> = { STANDARD: "Standard", ENTERPRISE: "Enterprise", BUSINESS_CRITICAL: "Business Critical" };

AreaContent.register("coverage", "sources", CoverageSourcesPanel);
AreaContent.register("coverage", "couldnt", CoverageCouldntPanel);
AreaContent.register("coverage", "limits", CoverageLimitsPanel);
