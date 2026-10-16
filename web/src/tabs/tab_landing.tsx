// web/src/tabs/tab_landing.tsx -- the FinOps and Governance Overviews: headline tiles, cause cards,
// one drill-down list and the checks behind them. Both render inside AreaPage (Overview), so a row
// opens the shared check drawer. Spend, waste, saving and storage per month are separate kinds and
// are never added; a check that did not run reads "–" and why.
import React from "react";
import { fmtDayShort, fmtInt, fmtMoney } from "../format";
import { FLAGGED_STATUSES, fmtChangePct, aggTotal, monitorCoverage, numOrZero, totalSpikeDays, useFindingAgg, useFindingData } from "../components/hooks";
import { AREA_REGISTRY, COST_MONEY_COL } from "../components/tab_registry";
import { KindChip, PatternCard, bandOf, noDataText } from "../components/primitives";
import { useNames } from "../components/names";
import { reconciliationLine, useCostCenterAllocation } from "../components/tag_rollup";
import { DayKindTimeline, IssueTile, StackedShareBar, fmtShare, pctOf, statusBarColor } from "../components/blocks";
import { NameId } from "../components/blocks_2";
import { CxAreaCounts, CxChip, CxDot, CxRanked, CxStrip, CxTable } from "../components/cx_e";
import type { CxAreaRow, CxRankItem } from "../components/cx_e";
import { whNameId } from "../components/de_blocks";
import { ChartNote } from "../components/charts";
import { ChecksList } from "../components/checks_list";
import { DrawerBus } from "../components/drawer";
import { NO_PRICE_LEDE, NO_PRICE_READING, isUnpricedAgg, notAssessedText } from "../components/scope";
import { windowShortLabel } from "../components/overview_tile";
import { buildWasteWorklist, overlapNote, wasteTotal } from "../components/waste_total";
import { getCheckLabel } from "../components/labels";
import { SpendMoversCard, buildSpendMovers } from "./tab_money";
import { withoutTotalRows } from "./tab_area";
import { ChecksRanStrip, DAY_KINDS, OV_TOTAL_CREDITS, dayKindOf, fillGaps, sumPick } from "./tab_overview";
import type { ScoreRow, OverviewProps } from "./tab_overview";
import type { FetchState, Finding, Row } from "../types";

const okRows = (s: FetchState) => s.phase === "ready" && s.outcome === "ok_rows";
type Sev = "critical" | "warn" | "ok" | "not_assessed" | "neutral";
function sevOf(f: Finding | undefined): Sev {
  if (!f) return "neutral";
  const b = bandOf(f);
  if (b === "NOT_ASSESSED" || b === "ERROR") return "not_assessed";
  if (b === "CRITICAL") return "critical";
  if (b === "WARN") return "warn";
  return "ok";
}
const affOf = (f: Finding | undefined) => (f && f.affected && f.affected.total ? f.affected as { flagged: number; total: number; noun: string } : null);

// The checks the FinOps Overview lists under its cards, besides the waste items.
const FINOPS_EXTRA_IDS = ["sf_chg_tag_coverage", "sf_cost_resource_monitor_coverage", "sf_acct_budgets"];

// ─────────── FinOps Overview ───────────

export function FinopsOverviewContent({ filters, meta, goTo, setVerdict, allFindingsIndex }: OverviewProps) {
  useNames();
  const byId: Record<string, Finding> = allFindingsIndex || {};
  const findingsReady = Object.keys(byId).length > 0;
  const acct = filters.accountIds;
  const dayKindAgg = useFindingAgg("cost_dollarized_by_service_day", filters.window, acct, ["usage_date", "sku_name"], "sum", COST_MONEY_COL);
  const periodState = useFindingData("cost_period_over_period", filters.window, acct);
  const spendState = useFindingData("overview_spend_estimate", filters.window, acct, 500);
  const idleState = useFindingData("sf_wh_idle_minutes", filters.window, acct, 500, FLAGGED_STATUSES);
  const monState = useFindingData("sf_cost_resource_monitor_coverage", filters.window, acct, 500);
  const ccAlloc = useCostCenterAllocation(filters);
  const worklist = React.useMemo(() => buildWasteWorklist(byId), [allFindingsIndex]); // eslint-disable-line react-hooks/exhaustive-deps
  const wt = React.useMemo(() => wasteTotal(worklist), [worklist]);

  // Spend by day and kind; the discount applies once, to every figure.
  const dk = okRows(dayKindAgg) ? dayKindAgg.data! : null;
  const disc = dk ? numOrZero(dk.discount_pct) : 0;
  const dayRows: { day: string; kind: string; value: number }[] | null = dk
    ? (dk.groups || []).map((g: { key: any[]; value: number }) => ({ day: String(g.key[0]).slice(0, 10), kind: dayKindOf(g.key[1]), value: numOrZero(g.value) * (1 - disc) })) : null;
  const spend = dk ? aggTotal(dk) : null;
  const dayTotals = new Map<string, number>();
  (dayRows || []).forEach((r) => dayTotals.set(r.day, (dayTotals.get(r.day) || 0) + r.value));
  const daily = fillGaps(dayTotals);
  const spikes = totalSpikeDays(daily);
  const worstSpike = spikes.length ? [...spikes].sort((a, b) => b.pct - a.pct)[0] : null;
  const partialDay = (meta && meta.cost_cutoff && meta.cost_cutoff.partial_day) || null;
  const credits = okRows(spendState) ? sumPick(spendState.data!.rows, OV_TOTAL_CREDITS) : null;
  const movers = okRows(periodState) ? buildSpendMovers(periodState.data!.rows, periodState.data!.discount_pct) : null;
  const deltaPct = movers && movers.totalPrev > 0 ? (movers.totalDelta / movers.totalPrev) * 100 : null;
  const windowText = windowShortLabel(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days) || `last ${filters.window} days`;

  // Waste, saving, storage: three kinds, each its own tile.
  const wastePct = wt.waste.usd != null ? pctOf(wt.waste.usd, spend) : null;
  const savingPct = wt.saving.usd != null ? pctOf(wt.saving.usd, spend) : null;
  const wasteParts = worklist.filter((w) => w.unit === "waste" && w.ran && w.usd != null && w.usd > 0).sort((a, b) => b.usd! - a.usd!);
  const topWaste = wasteParts[0];
  const checksWord = (n: number) => `${fmtInt(n)} check${n === 1 ? "" : "s"}`;
  const notRun = (fig: { ran: number; noPrice?: boolean }, priceWord = "credit") => (fig.noPrice ? `no ${priceWord} price in this export` : fig.ran > 0 ? "flagged, not priced in this export" : "none of these checks ran");

  // Cost-center split: tagged by value, untagged hatched.
  const ccRows: Row[] | null = ccAlloc.phase === "ready" && ccAlloc.outcome === "ok_rows" ? (ccAlloc.data!.by_value || []) : null;
  const ccTotal = ccRows ? ccRows.reduce((s, e) => s + numOrZero(e.metrics && e.metrics.usd), 0) : null;
  const ccUntagged = ccRows ? ccRows.filter((e) => e.value === "__untagged__").reduce((s, e) => s + numOrZero(e.metrics && e.metrics.usd), 0) : null;
  const untaggedPct = pctOf(ccUntagged, ccTotal);
  const tie = reconciliationLine(ccAlloc.data && ccAlloc.data.reconciliation);
  const tagF = byId.sf_chg_tag_coverage;
  const monF = byId.sf_cost_resource_monitor_coverage;
  // The same count as Budgets and Warehouses: warehouses the role sees with no monitor that suspends them.
  const monCov = okRows(monState) ? monitorCoverage(monState.data!.rows) : null;
  const naReason = (f: Finding | undefined) => (f ? ((f.not_assessed && f.not_assessed.label) || "did not run") : (findingsReady ? "not in this export" : undefined));

  const settled = findingsReady && dayKindAgg.phase !== "loading" && periodState.phase !== "loading" && ccAlloc.phase !== "loading" && monState.phase !== "loading";
  const unpricedSpend = isUnpricedAgg(dk);
  const lede = !settled ? "…" : spend == null ? (unpricedSpend ? NO_PRICE_LEDE : "Spend could not be assessed for this export.")
    : [`${fmtMoney(spend, 0)}${deltaPct != null ? ` · ${fmtChangePct(deltaPct)} vs previous ${filters.window} d` : ""}`,
      wastePct != null ? `${fmtShare(wastePct)} possible waste` : null,
      untaggedPct != null ? `${fmtShare(untaggedPct)} of the split untagged` : null,
      monCov && monCov.total ? `${fmtInt(monCov.noCap)} of ${fmtInt(monCov.total)} warehouses with no monitor that suspends` : null].filter(Boolean).join(" · ");
  React.useEffect(() => { if (setVerdict) setVerdict(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  // Idle warehouses, largest possible waste first.
  const idleRows = okRows(idleState) ? withoutTotalRows(idleState.data!.rows) : null;
  const idleDisc = idleState.data ? numOrZero(idleState.data.discount_pct) : 0;
  const idleList = (idleRows || []).filter((r) => r.status === "CRITICAL" || r.status === "WARN")
    .map((r) => ({ r, waste: numOrZero(r.est_wasted_usd_list) * (1 - idleDisc), spend: r.est_usd_list != null ? numOrZero(r.est_usd_list) * (1 - idleDisc) : null }))
    .sort((a, b) => b.waste - a.waste);
  const idleShown = idleList.slice(0, 8);
  const idleAff = affOf(byId.sf_wh_idle_minutes);
  // Every warehouse not assessed (no price, no grant): say why, not "filters exclude all". Some rows
  // not assessed (partial) still lists or reads empty like any other result.
  const idleNa = byId.sf_wh_idle_minutes && byId.sf_wh_idle_minutes.not_assessed && !byId.sf_wh_idle_minutes.not_assessed.partial
    && !(idleAff && idleAff.flagged)
    ? (wt.waste.noPrice ? "no credit price in this export" : naReason(byId.sf_wh_idle_minutes)) : null;

  const listIds = [...worklist.map((w) => w.id), ...FINOPS_EXTRA_IDS];
  const listFindings = listIds.map((id) => byId[id]).filter(Boolean);

  return (
    <div>
      <div className="summary-tile-row cto-tiles ln-tiles-3">
        <IssueTile label="Spend" loading={dayKindAgg.phase === "loading"} pill={<KindChip>Context</KindChip>}
          headline={spend != null ? fmtMoney(spend, 0) : null} unit={`last ${filters.window} days`} missingReason={notAssessedText(dayKindAgg.data)}
          base={[credits != null ? `${fmtInt(Math.round(credits))} credits` : null, deltaPct != null ? `${fmtChangePct(deltaPct)} vs previous ${filters.window} d` : null].filter(Boolean).join(" · ") || null}
          spark={daily.length > 1 ? daily.map((d) => d.value) : null}
          sparkAnomalies={spikes.map((s) => daily.findIndex((d) => d.day === s.day)).filter((i) => i >= 0)}
          cause={worstSpike ? `▲ ${fmtDayShort(worstSpike.day)} · ${fmtChangePct(worstSpike.pct)} above the week's median` : null}
          onOpen={() => goTo({ tab: "cost" })} openLabel="Cost →" />
        <IssueTile label="Possible waste" loading={!findingsReady || dayKindAgg.phase === "loading"}
          status={wt.waste.usd == null ? "not_assessed" : wt.waste.flagged > 0 ? "warn" : "ok"}
          headline={wastePct != null ? fmtShare(wastePct) : (wt.waste.usd != null ? fmtMoney(wt.waste.usd, 0) : null)}
          unit={wastePct != null ? "of spend is possible waste" : undefined} missingReason={notRun(wt.waste)}
          base={wt.waste.usd != null ? `${fmtMoney(wt.waste.usd, 0)}${spend != null ? ` of ${fmtMoney(spend, 0)}` : ""} · ${fmtInt(wt.waste.flagged)} of ${checksWord(wt.waste.ran)}` : null}
          cause={topWaste ? `${topWaste.title}: ${fmtMoney(topWaste.usd, 0)}${topWaste.affected ? `, ${fmtInt(topWaste.affected.flagged)} of ${fmtInt(topWaste.affected.total)} ${topWaste.affected.noun}` : ""}.` : null}
          onOpen={() => goTo({ tab: "waste" })} openLabel="Waste & savings →" />
        <IssueTile label="Possible saving" loading={!findingsReady || dayKindAgg.phase === "loading"} pill={<KindChip>kind, kept apart</KindChip>}
          headline={savingPct != null ? fmtShare(savingPct) : (wt.saving.usd != null ? fmtMoney(wt.saving.usd, 0) : null)}
          unit={savingPct != null ? "of spend from resizing" : undefined} missingReason={notRun(wt.saving)}
          base={wt.saving.usd != null ? `${fmtMoney(wt.saving.usd, 0)} · ${checksWord(wt.saving.flagged)}` : null}
          cause="Kept apart from possible waste: the same minutes, never added."
          onOpen={() => goTo({ tab: "warehouses" })} openLabel="Warehouses →" />
        <IssueTile label="Storage to free" loading={!findingsReady} pill={<KindChip>kind, kept apart</KindChip>}
          headline={wt.month.usd != null ? fmtMoney(wt.month.usd, 0) : null} unit="/ month" missingReason={notRun(wt.month, "storage")}
          base={wt.month.usd != null ? `${checksWord(wt.month.flagged)} · per month` : null}
          cause={overlapNote(wt.month, (v) => fmtMoney(v, 0))}
          onOpen={() => goTo({ tab: "storage" })} openLabel="Storage →" />
        <IssueTile label="Untagged" loading={ccAlloc.phase === "loading"} status={untaggedPct != null && untaggedPct > 20 ? "warn" : "neutral"}
          headline={untaggedPct != null ? fmtShare(untaggedPct) : null} unit="of the split has no cost center"
          missingReason={ccAlloc.data ? "no cost-center split for this window" : "cost-center split not in this export"}
          base={untaggedPct != null ? [`${fmtMoney(ccUntagged, 0)} of ${fmtMoney(ccTotal, 0)}`,
            affOf(tagF) ? `${fmtInt(affOf(tagF)!.flagged)} of ${fmtInt(affOf(tagF)!.total)} ${affOf(tagF)!.noun}` : null].filter(Boolean).join(" · ") : null}
          onOpen={() => goTo({ tab: "tags" })} openLabel="Tags →" />
        <IssueTile label="Budgets" loading={!findingsReady || monState.phase === "loading"} status={sevOf(monF)}
          headline={monCov && monCov.total ? fmtShare(pctOf(monCov.noCap, monCov.total)) : null} unit="of warehouses, no monitor that suspends"
          missingReason={naReason(monF)}
          base={monCov && monCov.total ? `${fmtInt(monCov.noCap)} of ${fmtInt(monCov.total)} warehouses${monCov.hidden ? ` · ${fmtInt(monCov.hidden)} not visible` : ""}` : null}
          onOpen={() => goTo({ tab: "cost", subtab: "budgets" })} openLabel="Budgets & guardrails →" />
      </div>

      <div className="cj-charts-2">
        <PatternCard title="Where the waste is" sub={wt.waste.usd != null ? `${fmtMoney(wt.waste.usd, 0)} possible waste, by check · last ${filters.window} d` : "Possible waste, by check"}
          link="Waste & savings →" onLink={() => goTo({ tab: "waste" })}>
          {!findingsReady ? <div className="chart-note-oneline">…</div>
            : wasteParts.length ? (
              <div>
                <StackedShareBar height={26} pareto maxSegments={5} valueFmt={(v) => fmtMoney(v, 0)} ariaLabel="Possible waste by check"
                  segments={wasteParts.map((w) => ({ key: w.id, label: w.title, value: w.usd!, onClick: () => DrawerBus.open({ id: w.id }) }))} />
                <div className="pc-foot">Each check prices its own minutes; saving and storage are other kinds and are not added.</div>
              </div>
            ) : <div className="chart-note-oneline">{wt.waste.usd == null ? `– ${notRun(wt.waste)}` : noDataText(meta, filters.window)}</div>}
        </PatternCard>
        <PatternCard title="Chargeback by cost center" sub={ccTotal != null ? `The ${fmtMoney(ccTotal, 0)} split in one bar · untagged hatched` : "The billed split by cost center"}
          link="Tags →" onLink={() => goTo({ tab: "tags" })}>
          {ccRows && ccTotal ? (
            <div>
              <StackedShareBar height={26} pareto maxSegments={6} valueFmt={(v) => fmtMoney(v, 0)} ariaLabel="Billed split by cost center"
                segments={ccRows.map((e) => ({ key: String(e.value), label: e.value === "__untagged__" ? "No cost center" : String(e.label), value: numOrZero(e.metrics && e.metrics.usd), unknown: e.value === "__untagged__" }))} />
              {tie && <div className="pc-foot">{tie.text}</div>}
            </div>
          ) : <div className="chart-note-oneline">{ccAlloc.phase === "loading" ? "…" : "– the cost-center split is not in this export"}</div>}
        </PatternCard>
      </div>

      <SpendMoversCard periodState={periodState} filters={filters} meta={meta}
        title={movers && movers.totalPrev > 0 ? `What moved spend ${movers.totalDelta >= 0 ? "+" : "−"}${fmtMoney(Math.abs(movers.totalDelta), 0)}` : "What moved spend"}
        sub={`Change vs the previous ${filters.window} days, by service`} link="Cost › Trend →" onLink={() => goTo({ tab: "cost", subtab: "trend" })} />

      <PatternCard title="Spend per day, by kind" sub={`${windowText}${partialDay ? " · the last day is partial" : ""}`}>
        {unpricedSpend ? <div className="chart-note-oneline">– {NO_PRICE_READING}</div> : dayRows ? (
          <DayKindTimeline rows={dayRows} days={daily.map((d) => d.day)} kinds={DAY_KINDS} partialDay={partialDay} height={180}
            kindColors={{ [DAY_KINDS[0]]: "var(--c1)", [DAY_KINDS[1]]: "var(--c2)", [DAY_KINDS[2]]: "var(--c-other)" }}
            valueFmt={(v) => fmtMoney(v, 0)} ariaLabel="Spend per day, by kind" />
        ) : <ChartNote state={dayKindAgg} label="cost_dollarized_by_service_day" />}
      </PatternCard>

      <PatternCard title="Warehouses with idle spend" sub={idleAff && !idleNa ? `${idleAff.flagged ? `Worst ${fmtInt(idleShown.length)} of ${fmtInt(idleAff.flagged)} by possible waste · ` : ""}${fmtInt(idleAff.flagged)} of ${fmtInt(idleAff.total)} ${idleAff.noun} flagged` : "By possible waste"}
        link={idleList.length ? `All ${fmtInt(idleList.length)} →` : null} onLink={() => DrawerBus.open({ id: "sf_wh_idle_minutes" })}>
        {idleNa ? <div className="chart-note-oneline">– {idleNa}</div> : idleRows ? (idleShown.length ? (
          <div className="ln-table" role="table" aria-label="Warehouses with idle spend">
            <div className="ln-tr ln-th" role="row">
              <span role="columnheader">Warehouse</span><span role="columnheader">Idle</span>
              <span role="columnheader">{`Waste · ${filters.window} d`}</span><span role="columnheader">{`Spend · ${filters.window} d`}</span>
            </div>
            {idleShown.map(({ r, waste, spend: whSpend }) => {
              const w = whNameId(r.warehouse_id);
              return (
                <button type="button" role="row" key={String(r.warehouse_id)} className="ln-tr"
                  onClick={() => DrawerBus.open({ id: "sf_wh_idle_minutes", col: "warehouse_id", val: String(r.warehouse_id), label: w.name })}>
                  <span className="ln-name" role="cell"><span className="blk-dot" style={{ background: statusBarColor(r.status) }} aria-hidden="true" /><NameId name={w.name} id={w.id} /></span>
                  <span className="ln-num" role="cell">{r.idle_share_pct != null ? fmtShare(numOrZero(r.idle_share_pct)) : "–"}</span>
                  <span className="ln-num" role="cell">{fmtMoney(waste, 0)}</span>
                  <span className="ln-num muted" role="cell">{whSpend != null ? fmtMoney(whSpend, 0) : "–"}</span>
                </button>
              );
            })}
          </div>
        ) : <div className="chart-note-oneline">{noDataText(meta, filters.window)}</div>)
          // it ran and flagged none: the flagged-only read is empty, not filtered out
          : idleAff && idleAff.total > 0 && idleAff.flagged === 0 ? <div className="chart-note-oneline">Nothing flagged in this window.</div>
          : <ChartNote state={idleState} label="sf_wh_idle_minutes" />}
      </PatternCard>

      <ChecksList findings={listFindings} filters={filters} meta={meta} goTo={goTo} title="Checks in this view" />
      <ChecksRanStrip meta={meta} byId={byId} goTo={goTo} />
    </div>
  );
}

// ─────────── Governance Overview ───────────

export const GOV_CARDS = [
  { id: "access_broad_grants", tab: "access", subtab: "roles", label: "Broad grants", phrase: "of grants are broad", why: "Admin or write on widely held roles.", link: "Roles & grants →" },
  { id: "sf_gov_sensitive_columns_unprotected", tab: "pii", subtab: "sensitive", label: "Unmasked PII", phrase: "of sensitive tables have an unmasked column", why: "Sensitive, no masking policy.", link: "PII & policies →" },
  { id: "sf_sec_privileged_grant_changes", tab: "audit", subtab: "changes", label: "Admin changes", phrase: "of grantees had admin changes", why: "Privilege changes to confirm.", link: "Audit › Changes →" },
  { id: "sf_gov_shares_and_listings", tab: "sharing", subtab: "shares", label: "Shared out", phrase: "of databases are shared out", why: "To accounts outside this one.", link: "Sharing & org →" },
  { id: "sf_sec_users_without_mfa", tab: "access", subtab: "users", label: "No MFA", phrase: "of people sign in without MFA", why: "Password sign-ins with no second factor.", link: "Users & sign-ins →" },
];

export const GOV_AREAS: ScoreRow[] = [
  { tab: "access", label: "Access" }, { tab: "pii", label: "PII & policies" }, { tab: "audit", label: "Audit" },
  { tab: "sharing", label: "Sharing & org" }, { tab: "lineage", label: "Lineage & usage" },
];

/** Every check id the governance areas own or reference. */
export function govCheckIds(): string[] {
  const out: string[] = [];
  GOV_AREAS.forEach((a) => ((AREA_REGISTRY[a.tab] || { subtabs: [] }).subtabs || []).forEach((s: { ids?: string[]; refIds?: string[] }) => {
    [...(s.ids || []), ...(s.refIds || [])].forEach((id) => { if (!out.includes(id)) out.push(id); });
  }));
  return out;
}

function daysBetween(from: unknown, to: unknown): number | null {
  const a = Date.parse(String(from || "").slice(0, 10)), b = Date.parse(String(to || "").slice(0, 10));
  return Number.isFinite(a) && Number.isFinite(b) ? Math.max(0, Math.round((b - a) / 86400000)) : null;
}

// The Governance lede reads these two counts as sentences, in this order.
const GOV_LEDE = [
  { id: "sf_sec_users_without_mfa", says: "sign in with a password and no MFA" },
  { id: "sf_gov_sensitive_columns_unprotected", says: "with sensitive columns have no masking policy" },
];
// Three primary KPIs; the rest go in the strip under them.
const GOV_PRIMARY = ["sf_sec_users_without_mfa", "sf_gov_sensitive_columns_unprotected", "sf_sec_privileged_grant_changes"];

/** Databases by unmasked share, the first 8, then a link to the rest on PII › Sensitive data. */
function GovDbList({ items, goPii }: { items: CxRankItem[]; goPii: () => void }) {
  const shown = items.slice(0, 8);
  return (
    <div>
      <CxRanked items={shown} max={100} labelWidth={200} ariaLabel="Unmasked sensitive columns by database" />
      <div className="cx-foot cx-foot-left"><span>{"Same measure and order as PII › Sensitive data."}</span>
        {items.length > shown.length && <button type="button" className="cx-linkbtn" onClick={goPii}>{`${fmtInt(items.length - shown.length)} more ${items.length - shown.length === 1 ? "database" : "databases"} →`}</button>}</div>
    </div>
  );
}

export function GovOverviewContent({ filters, meta, goTo, setVerdict, allFindingsIndex }: OverviewProps) {
  const byId: Record<string, Finding> = allFindingsIndex || {};
  const findingsReady = Object.keys(byId).length > 0;
  const acct = filters.accountIds;
  const grantState = useFindingData("access_broad_grants", filters.window, acct, 5000, FLAGGED_STATUSES);
  const piiState = useFindingData("sf_gov_sensitive_columns_unprotected", filters.window, acct, 5000);
  const mfaState = useFindingData("sf_sec_users_without_mfa", filters.window, acct, 1000, FLAGGED_STATUSES);

  const govIds = govCheckIds();
  const govFindings = govIds.map((id) => byId[id]).filter(Boolean);
  const nBand = (bands: string[]) => govFindings.filter((f) => bands.includes(bandOf(f))).length;
  const crit = nBand(["CRITICAL"]), warn = nBand(["WARN"]);
  const notRunList = govFindings.filter((f) => ["NOT_ASSESSED", "ERROR"].includes(bandOf(f)));
  const ran = govFindings.length - notRunList.length;

  // The lede: the first two headline counts as plain sentences, then the critical count.
  const said = GOV_LEDE.map((x) => ({ x, a: affOf(byId[x.id]) })).filter((y) => y.a && y.a.flagged > 0)
    .map((y) => `${fmtInt(y.a!.flagged)} of ${fmtInt(y.a!.total)} ${y.a!.noun} ${y.x.says}`).slice(0, 2);
  const lede = !findingsReady ? "…" : [
    said.length ? `${said.join(", and ")}.`.replace(/^./, (x) => x.toUpperCase()) : null,
    `${fmtInt(crit)} of ${fmtInt(ran)} governance checks that ran are critical.`,
  ].filter(Boolean).join(" ");
  // Deferred one tick: the page frame clears its sentence after the first render's effects.
  React.useEffect(() => { const t = window.setTimeout(() => { if (setVerdict) setVerdict(lede); }, 0); return () => window.clearTimeout(t); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  // Who holds the risk: broad grants by the role that holds them.
  const grantRows: Row[] | null = okRows(grantState) ? grantState.data!.rows : null;
  const byGrantee = new Map<string, { n: number; crit: boolean }>();
  (grantRows || []).forEach((r) => {
    const k = String(r.grantee || "(unknown)");
    const cur = byGrantee.get(k) || { n: 0, crit: false };
    cur.n += 1; cur.crit = cur.crit || r.status === "CRITICAL";
    byGrantee.set(k, cur);
  });

  // Sensitive columns by database: classified vs unmasked.
  const piiRows = okRows(piiState) ? withoutTotalRows(piiState.data!.rows).filter((r) => r.status !== "NOT_ASSESSED") : null;
  const byDb = new Map<string, { total: number; open: number; crit: boolean }>();
  (piiRows || []).forEach((r) => {
    const k = String(r.database_name || "(unknown)");
    const cur = byDb.get(k) || { total: 0, open: 0, crit: false };
    cur.total += 1;
    if (!r.is_masked) cur.open += 1;
    cur.crit = cur.crit || r.status === "CRITICAL";
    byDb.set(k, cur);
  });
  const piiOpen = [...byDb.values()].reduce((s, d) => s + d.open, 0);
  const piiTotal = [...byDb.values()].reduce((s, d) => s + d.total, 0);

  // People without MFA: critical (admins) first, then the most password-only sign-ins.
  const asOf = meta && meta.as_of_date;
  const mfaRows = okRows(mfaState) ? withoutTotalRows(mfaState.data!.rows) : null;
  const mfaSorted = [...(mfaRows || [])].sort((a, b) => Number(b.status === "CRITICAL") - Number(a.status === "CRITICAL")
    || numOrZero(b.password_only_logins) - numOrZero(a.password_only_logins));
  const mfaShown = mfaSorted.slice(0, 8);
  const mfaAff = affOf(byId.sf_sec_users_without_mfa);

  const tile = (c: typeof GOV_CARDS[number]) => {
    const f = byId[c.id];
    const a = affOf(f);
    const sev = sevOf(f);
    const open = () => goTo({ tab: c.tab, subtab: c.subtab, focusQueryId: c.id });
    if (!f || sev === "not_assessed") {
      return <IssueTile key={c.id} label={c.label} loading={!findingsReady} headline={null} status={findingsReady ? "not_assessed" : "neutral"}
        missingReason={f && f.not_assessed && f.not_assessed.label ? f.not_assessed.label : "not in this export"} onOpen={open} openLabel={c.link} />;
    }
    const counts = f.status_counts || {};
    const flaggedRows = numOrZero(counts.CRITICAL) + numOrZero(counts.WARN);
    const when = f.windowed === false ? "Snapshot at export." : `Last ${filters.window} days.`;
    const extra = c.id === "sf_gov_sensitive_columns_unprotected" && a && !/column/i.test(a.noun) ? `, ${fmtInt(flaggedRows)} columns in all` : "";
    // Broad grants: say who holds them, in place of a one-bar chart.
    const holder = c.id === "access_broad_grants" && grantRows && grantRows.length ? (() => {
      const top = [...byGrantee.entries()].sort((x, y) => y[1].n - x[1].n)[0];
      return byGrantee.size === 1 ? `All ${fmtInt(top[1].n)} sit on one role, ${top[0]}.` : `Most sit on ${top[0]}: ${fmtInt(top[1].n)} of ${fmtInt(grantRows.length)}.`;
    })() : null;
    return (
      <IssueTile key={c.id} label={c.label} status={a && a.flagged === 0 ? "ok" : sev}
        headline={a ? fmtShare(pctOf(a.flagged, a.total)) : fmtInt(flaggedRows)} unit={a ? `of ${a.noun}` : "flagged rows"}
        base={a ? `${fmtInt(a.flagged)} of ${fmtInt(a.total)} ${a.noun}${extra}. ${holder || c.why}` : c.why}
        cause={when} onOpen={open} openLabel={c.link} />
    );
  };
  const primary = GOV_CARDS.filter((c) => GOV_PRIMARY.includes(c.id)).sort((x, y) => GOV_PRIMARY.indexOf(x.id) - GOV_PRIMARY.indexOf(y.id));
  const secondary = GOV_CARDS.filter((c) => !GOV_PRIMARY.includes(c.id));

  // Checks by area: the same bands the scorecard counts, in fixed columns.
  const areaRows: CxAreaRow[] = GOV_AREAS.map((r) => {
    const subs = ((AREA_REGISTRY[r.tab] || { subtabs: [] }).subtabs || []) as { ids?: string[]; refIds?: string[] }[];
    const ids = subs.flatMap((x) => x.ids || []), refIds = subs.flatMap((x) => x.refIds || []);
    const c = { crit: 0, warn: 0, ok: 0, ref: 0, na: 0 };
    [...ids, ...refIds].forEach((id) => {
      const f = byId[id];
      if (!f) return;
      const b = bandOf(f);
      if (b === "CRITICAL") c.crit += 1;
      else if (b === "WARN") c.warn += 1;
      else if (b === "NOT_ASSESSED" || b === "ERROR") c.na += 1;
      else if (refIds.includes(id) || b === "RANKED" || b === "INVENTORY") c.ref += 1;
      else c.ok += 1;
    });
    return { key: r.tab, label: r.label, ...c, onClick: () => goTo({ tab: r.tab, subtab: r.subtab || null }) };
  }).filter((r) => r.crit + r.warn + r.ok + r.ref > 0);
  const tot = areaRows.reduce((x, r) => ({ ok: x.ok + r.ok, ref: x.ref + r.ref }), { ok: 0, ref: 0 });

  // Unmasked share by database, the highest share first, the same measure as PII › Sensitive data.
  const dbItems: CxRankItem[] = [...byDb.entries()].map(([k, v]) => ({
    key: k, label: k, value: pctOf(v.open, v.total) ?? 0, strong: `${fmtInt(v.open)} of ${fmtInt(v.total)}`, rest: fmtShare(pctOf(v.open, v.total)),
    onClick: () => DrawerBus.open({ id: "sf_gov_sensitive_columns_unprotected", col: "database_name", val: k, label: k }),
  })).sort((x, y) => y.value - x.value || Number(String(y.strong).split(" ")[0].replace(/,/g, "")) - Number(String(x.strong).split(" ")[0].replace(/,/g, "")));

  return (
    <div className="cx-e">
      <div className="summary-tile-row cto-tiles ln-tiles-3">{primary.map(tile)}</div>
      <CxStrip>{secondary.map(tile)}</CxStrip>

      <PatternCard title="Governance checks by area" sub={findingsReady ? `${fmtInt(ran)} checks that ran · bar length = checks in the area, split by outcome` : "By outcome"}
        link="All findings →" onLink={() => goTo({ tab: "findings" })}>
        {findingsReady ? (
          <div>
            <CxAreaCounts rows={areaRows} ariaLabel="Governance checks by area" />
            <div className="cx-foot cx-foot-left">
              <span>{`${fmtInt(ran)} governance checks ran · ${notRunList.length ? `${fmtInt(notRunList.length)} not run` : "none not run"}`}</span>
              <span><CxDot status="CRITICAL" />{` ${fmtInt(crit)} critical`}</span><span><CxDot status="WARN" />{` ${fmtInt(warn)} warning`}</span>
              <span><span className="cx-dot" />{` ${fmtInt(tot.ref)} reference`}</span><span><CxDot status="OK" />{` ${fmtInt(tot.ok)} ok`}</span>
            </div>
            {notRunList.length > 0 && <div className="cx-foot cx-foot-left">{notRunList.slice(0, 3).map((f) => (
              <span key={f.query_id} className="nj-pill">{`– ${getCheckLabel(f.query_id, f.title).title}: ${(f.not_assessed && f.not_assessed.label) || "did not run"}`}</span>
            ))}{notRunList.length > 3 && <span className="nj-pill">{`– ${fmtInt(notRunList.length - 3)} more not run`}</span>}</div>}
          </div>
        ) : <div className="chart-note-oneline">…</div>}
      </PatternCard>

      <div className="cj-charts-2 cx-top">
        <PatternCard title="Unmasked sensitive columns, by database"
          sub={piiRows ? `${fmtInt(piiOpen)} of ${fmtInt(piiTotal)} sensitive columns unmasked (${fmtShare(pctOf(piiOpen, piiTotal))}) · bar = unmasked share of the database's sensitive columns` : "Classified columns, by database"}
          link="PII & policies →" onLink={() => goTo({ tab: "pii", subtab: "sensitive" })}>
          {piiRows ? (dbItems.length ? <GovDbList items={dbItems} goPii={() => goTo({ tab: "pii", subtab: "sensitive" })} />
            : <div className="chart-note-oneline">No classified column in this export.</div>) : <ChartNote state={piiState} label="sf_gov_sensitive_columns_unprotected" />}
        </PatternCard>
        <PatternCard title="People signing in without MFA"
          sub={mfaAff ? `Worst ${fmtInt(mfaShown.length)} of ${fmtInt(mfaAff.flagged)} · admins first, then password-only sign-ins` : "Admins first, then password-only sign-ins"}
          link={mfaRows && mfaRows.length ? `All ${fmtInt(mfaAff ? mfaAff.flagged : mfaRows.length)} →` : null} onLink={() => DrawerBus.open({ id: "sf_sec_users_without_mfa" })}>
          {mfaRows ? (mfaShown.length ? (
            <CxTable ariaLabel="People signing in without MFA"
              cols={[{ label: "User" }, { label: "Role" }, { label: "Sign-ins", num: true }, { label: "Password age", num: true }]}
              foot={<span className="cx-foot-left"><span><CxDot status="CRITICAL" />{" holds an admin role"}</span><span><CxDot status="WARN" />{" no admin role"}</span></span>}
              rows={mfaShown.map((r) => {
                const role = r.admin_roles ? String(r.admin_roles).split(",")[0].trim() : (r.default_role || null);
                const pwAge = r.password_last_set_time ? daysBetween(r.password_last_set_time, asOf) : null;
                return {
                  key: String(r.user_id || r.user_name), status: r.status,
                  onClick: () => DrawerBus.open({ id: "sf_sec_users_without_mfa", col: "user_name", val: String(r.user_name), label: String(r.user_name) }),
                  cells: [<NameId name={String(r.user_name)} id={r.user_id} />, role ? <CxChip status={r.admin_roles ? "CRITICAL" : null}>{role}</CxChip> : "–",
                    fmtInt(r.successful_logins), pwAge != null ? `${fmtInt(pwAge)} d` : "–"],
                };
              })} />
          ) : <div className="chart-note-oneline">{noDataText(meta, filters.window)}</div>)
            : <ChartNote state={mfaState} label="sf_sec_users_without_mfa" />}
        </PatternCard>
      </div>
    </div>
  );
}
