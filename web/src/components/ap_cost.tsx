// web/src/components/ap_cost.tsx -- the Cost sub-tabs By service, Who spent it, Chargeback & tags,
// Contract & rate and Budgets & guardrails: four headline tiles, then the cause cards and the rows a
// drawer opens. area_pages.tsx lists these in AREA_CHART_PAGES.cost; each draws its own tiles and lede.
//
// Money is credits times the effective $ per credit, net of the discount; a check that did not run
// reads "–" and why, never $0. Spend, change and shares of different bases are never added together.
import React from "react";
import "../styles/css/p_shared_tabs.css";
import { fmtDayShort, fmtInt, fmtMoney } from "../format";
import { fmtChangePct, monitorCoverage, numOrZero, useFindingAgg, useFindingData } from "./hooks";
import { KindChip, PatternCard, bandOf, noDataText } from "./primitives";
import { notAssessedText } from "./scope";
import { DayKindTimeline, IssueTile, ReconciliationStrip, ShareBarList, StackedShareBar, StatusBars, fmtShare, pctOf } from "./blocks";
import type { IssueTileProps, ReconStep, ShareItem, ShareSegment, StatusBarItem } from "./blocks";
import { NameId, StatStrip } from "./blocks_2";
import { DrawerBus } from "./drawer";
import { DrillTable, MiniBar, SplitBar } from "./drill_table";
import { whNameId } from "./de_blocks";
import { reconciliationLine, rollupNote, useCostCenterAllocation } from "./tag_rollup";
import { scrollToAnchor, windowShortLabel } from "./overview_tile";
import { ChargebackByDimension } from "./cost_chargeback_picker";
import { withoutTotalRows } from "../tabs/tab_area";
import { dayKindOf, DAY_KINDS } from "../tabs/tab_overview";
import type { ApPageProps } from "./area_pages";
import type { FetchState, Finding, Row } from "../types";

// ── shared: one check's rows, or the one line that says why there are none ──────────────────────
interface CheckRows { rows: Row[] | null; disc: number; note: string | null; state: FetchState }

function useCheckRows(p: ApPageProps, id: string): CheckRows {
  const f = (p.findings || []).find((x) => x.query_id === id) || null;
  const state = useFindingData(f ? id : null, p.filters.window, p.filters.accountIds, 5000) as FetchState;
  if (!f) return { rows: null, disc: 0, note: "– Not in this export yet: run the export again.", state };
  if (state.phase === "loading") return { rows: null, disc: 0, note: "…", state };
  if (state.phase === "error") return { rows: null, disc: 0, note: `– ${state.error || "Could not load"}`, state };
  const o = state.outcome;
  if (o === "not_assessed") return { rows: null, disc: 0, note: `– ${notAssessedText(state.data)}`, state };
  if (o === "error") return { rows: null, disc: 0, note: `– ${(state.data && state.data.error) || "The check failed."}`, state };
  if (o === "ok_empty_window") return { rows: [], disc: 0, note: noDataText(p.meta, p.filters.window), state };
  if (o === "ok_empty_filters") {
    const none = state.data && state.data.scope && state.data.scope.none_flagged;
    return { rows: [], disc: 0, note: none ? "Nothing flagged in this window." : "Rows exist, but the current filters exclude all of them.", state };
  }
  return { rows: withoutTotalRows(state.data!.rows), disc: numOrZero(state.data!.discount_pct), note: null, state };
}

function Note({ text }: { text: string }) {
  return <div className="chart-note-oneline">{text}</div>;
}

type Sev = NonNullable<IssueTileProps["status"]>;
const usd0 = (v: number) => fmtMoney(v, 0);
const isTrue = (v: any) => v === true || v === "true" || v === 1;
const priced = (rows: Row[]) => rows.some((r) => r.price_basis !== "unpriced");

const isFlagged = (r: Row) => r.status === "CRITICAL" || r.status === "WARN";
const findingOf = (p: ApPageProps, id: string): Finding | null => (p.findings || []).find((f) => f.query_id === id) || null;
function sevOf(f: Finding | null | undefined): Sev {
  if (!f) return "not_assessed";
  const b = bandOf(f);
  return b === "CRITICAL" ? "critical" : b === "WARN" ? "warn" : b === "NOT_ASSESSED" || b === "ERROR" ? "not_assessed" : "ok";
}
const SEV_RANK: Record<string, number> = { critical: 0, warn: 1, ok: 2, neutral: 3, not_assessed: 4 };
const worse = (...s: Sev[]) => [...s].sort((a, b) => SEV_RANK[a] - SEV_RANK[b])[0];
function affOf(f: Finding | null | undefined) {
  const a = f && f.affected;
  return a && Number.isFinite(Number(a.flagged)) ? { flagged: Number(a.flagged), total: a.total != null ? Number(a.total) : null, noun: String(a.noun || "") } : null;
}
/** "3 of 12 tables" from a check's own summary, so counts agree with every page. */
const affText = (f: Finding | null | undefined, suffix = "flagged") => {
  const a = affOf(f);
  return a ? `${fmtInt(a.flagged)}${a.total != null ? ` of ${fmtInt(a.total)}` : ""} ${a.noun}${suffix ? ` ${suffix}` : ""}` : null;
};
const why = (c: CheckRows) => (c.note && c.note !== "…" ? c.note.replace(/^– /, "") : undefined);
const busy = (c: CheckRows) => c.note === "…";
const openDrawer = (id: string, col?: string | null, val?: any, label?: string | null) => () =>
  DrawerBus.open({ id, col: col && val != null ? col : null, val: col && val != null ? String(val) : null, label: label || null });
function useLede(p: ApPageProps, text: string | null) {
  React.useEffect(() => { if (p.setLede) p.setLede(text); }, [text]); // eslint-disable-line react-hooks/exhaustive-deps
}
function rangeOf(p: ApPageProps) {
  return (windowShortLabel(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days) || "").split(",")[0] || `the last ${p.filters.window} days`;
}
function Tiles({ children }: { children?: React.ReactNode }) { return <div className="summary-tile-row compact sx-tiles-4">{children}</div>; }

// A service code in plain words, the same on every Cost page: WAREHOUSE_METERING -> Warehouse metering.
export function costServiceWords(code: any) {
  if (code === null || code === undefined || code === "") return "unknown service";
  const WORDS: Record<string, string> = { ai: "AI", cli: "CLI", sql: "SQL", mv: "MV" };
  return String(code).replace(/_/g, " ").toLowerCase().split(" ")
    .map((w, i) => WORDS[w] || (i === 0 ? w.charAt(0).toUpperCase() + w.slice(1) : w)).join(" ");
}

// The change chip: 25% up is over the warning line, 50% is critical, a 15% drop reads good.
export function DeltaChip({ cur, prev }: { cur: number; prev: number }) {
  if (!(prev > 0)) return <span className="cost-delta tone-neutral">{cur > 0 ? "new" : "–"}</span>;
  const pct = ((cur - prev) / prev) * 100;
  const tone = pct >= 50 ? "crit" : pct >= 25 ? "warn" : pct <= -15 ? "good" : "neutral";
  const sign = pct > 0 ? "+" : pct < 0 ? "−" : "";
  return <span className={`cost-delta tone-${tone}`} title={`${usd0(cur)} vs ${usd0(prev)} the period before`}>{`${sign}${fmtShare(Math.abs(pct))}`}</span>;
}

// This period's bar over the previous one's track, with the change chip. The tail is counted, not folded.
export function ThisVsPrevBars({ items, n = 8, valueFmt = usd0, onOpen }: { items: { key?: string; name: string; cur: number; prev: number }[]; n?: number; valueFmt?: (v: number) => string; onOpen?: ((key: string) => void) | null }) {
  const sorted = [...items].sort((a, b) => b.cur - a.cur);
  const shown = sorted.slice(0, n);
  const max = Math.max(1, ...shown.map((it) => Math.max(it.cur, it.prev)));
  return (
    <div className="cost-tvp" role="list" aria-label="This period vs the previous period">
      <div className="blk-legend">
        <span className="blk-legend-item"><span className="blk-sw" style={{ background: "var(--c1)" }} />This period</span>
        <span className="blk-legend-item"><span className="blk-sw cost-tvp-sw-prev" />Previous period</span>
      </div>
      {shown.map((it) => {
        const body = (
          <>
            <span className="cost-tvp-name">{it.name}</span>
            <span className="cost-tvp-bars">
              <span className="cost-tvp-prev" style={{ width: `${(it.prev / max) * 100}%` }} />
              <span className="cost-tvp-cur" style={{ width: `${(it.cur / max) * 100}%` }} />
            </span>
            <span className="cost-tvp-value mono">{valueFmt(it.cur)}</span>
            <DeltaChip cur={it.cur} prev={it.prev} />
          </>
        );
        return onOpen && it.key
          ? <button type="button" key={it.name} className="cost-tvp-row blk-row-btn" title={`${it.name}: ${valueFmt(it.cur)} (previous ${valueFmt(it.prev)})`} onClick={() => onOpen(it.key!)}>{body}</button>
          : <div key={it.name} className="cost-tvp-row" role="listitem" title={`${it.name}: ${valueFmt(it.cur)} (previous ${valueFmt(it.prev)})`}>{body}</div>;
      })}
      {sorted.length > shown.length && <div className="blk-more">{`+${fmtInt(sorted.length - shown.length)} more not shown`}</div>}
    </div>
  );
}

// ═══════════════════════ By service ═══════════════════════
export function ApCostByService(p: ApPageProps) {
  const svc = useCheckRows(p, "cost_chargeback_by_service");
  const cs = useCheckRows(p, "sf_cost_cloud_services_billed");
  const eg = useCheckRows(p, "sf_cost_data_transfer_egress");
  const svcF = findingOf(p, "cost_chargeback_by_service"), csF = findingOf(p, "sf_cost_cloud_services_billed"), egF = findingOf(p, "sf_cost_data_transfer_egress");

  // One line per service; an unpriced row is left out, never $0.
  const keep = 1 - svc.disc;
  const byCode = new Map<string, { key: string; name: string; cur: number; prev: number }>();
  (svc.rows || []).forEach((r) => {
    if (r.usd_list == null) return;
    const code = String(r.billing_origin_product || r.service_type || "");
    const g = byCode.get(code) || { key: code, name: r.service_label && !r.billing_origin_product ? String(r.service_label) : costServiceWords(code || null), cur: 0, prev: 0 };
    g.cur += numOrZero(r.usd_list) * keep;
    g.prev += numOrZero(r.prev_usd_list) * keep;
    byCode.set(code, g);
  });
  const services = [...byCode.values()].filter((s) => s.cur > 0 || s.prev > 0);
  const total = services.reduce((s, x) => s + x.cur, 0), prevTotal = services.reduce((s, x) => s + x.prev, 0);
  const live = services.filter((s) => s.cur > 0);
  const acctPct = prevTotal > 0 ? ((total - prevTotal) / prevTotal) * 100 : null;
  const growth = (s: { cur: number; prev: number }) => (s.prev > 0 ? ((s.cur - s.prev) / s.prev) * 100 : null);
  const growers = acctPct == null ? [] : live.filter((s) => { const g = growth(s); return g == null || g > acctPct; })
    .sort((a, b) => (growth(b) ?? Infinity) - (growth(a) ?? Infinity));
  const wh = services.find((s) => s.key === "WAREHOUSE_METERING");
  const kinds = DAY_KINDS.map((k) => ({ k, v: services.filter((s) => dayKindOf(s.key) === k).reduce((a, s) => a + s.cur, 0) }));
  const ready = !!svc.rows && total > 0;

  // Cloud services: days billed above the daily 10% allowance, and the ratio per day.
  const csRows = cs.rows || [];
  const csDays = new Map<string, { cs: number; compute: number; billed: number }>();
  csRows.forEach((r) => {
    const d = String(r.usage_date).slice(0, 10);
    const g = csDays.get(d) || { cs: 0, compute: 0, billed: 0 };
    g.cs += numOrZero(r.cloud_services_credits); g.compute += numOrZero(r.compute_credits); g.billed += numOrZero(r.billed_cloud_services_credits);
    csDays.set(d, g);
  });
  const billedDays = [...csDays.values()].filter((g) => g.billed > 0).length;
  const csUsed = csRows.reduce((s, r) => s + numOrZero(r.cloud_services_credits), 0);
  const csBilled = csRows.reduce((s, r) => s + numOrZero(r.billed_cloud_services_credits), 0);
  const csUsd = cs.rows && priced(cs.rows) ? csRows.reduce((s, r) => s + numOrZero(r.est_billed_cloud_services_usd_list), 0) * (1 - cs.disc) : null;
  const csTimeline = [...csDays.entries()].sort().map(([day, g]) => ({ day, kind: g.billed > 0 ? "Over the allowance" : "Within 10%", value: g.compute > 0 ? (g.cs / g.compute) * 100 : 0 }));

  // Egress: the flagged routes' $ against all transfer $; the price is your per-TB rate card.
  const egRows = eg.rows || [];
  const egUsd = (r: Row) => numOrZero(r.est_egress_usd_list) * (1 - eg.disc);
  const egAll = egRows.reduce((s, r) => s + egUsd(r), 0);
  const egFlag = egRows.filter(isFlagged);
  const egFlagUsd = egFlag.reduce((s, r) => s + egUsd(r), 0);

  const lede = busy(svc) ? "…" : ready
    ? `Warehouse compute is ${fmtShare(pctOf(wh ? wh.cur : 0, total))} of ${usd0(total)}; serverless, AI and features are ${fmtShare(pctOf(kinds[1].v, total))}.${acctPct != null ? ` ${fmtInt(growers.length)} of ${fmtInt(live.length)} services grew faster than the account.` : ""}`
    : null;
  useLede(p, lede);
  const openSvc = (code: string) => DrawerBus.open({ id: "cost_chargeback_by_service", col: "billing_origin_product", val: code, label: costServiceWords(code) });
  const maxPct = Math.max(1, ...growers.slice(0, 8).map((s) => growth(s) ?? 0), acctPct ?? 0);

  return (
    <div className="sx-page">
      <Tiles>
        <IssueTile label="Warehouse compute" loading={busy(svc)} pill={<KindChip>Context</KindChip>}
          headline={ready ? fmtShare(pctOf(wh ? wh.cur : 0, total)) : null} unit="of spend" missingReason={why(svc) || "no priced service rows"}
          base={ready ? `${usd0(wh ? wh.cur : 0)} of ${usd0(total)} · 1 of ${fmtInt(live.length)} services` : null}
          cause={ready ? `Serverless, AI & features ${fmtShare(pctOf(kinds[1].v, total))} (${usd0(kinds[1].v)}); storage & transfer ${fmtShare(pctOf(kinds[2].v, total))} (${usd0(kinds[2].v)}).` : null}
          onOpen={() => scrollToAnchor("cs-where")} openLabel="Where it goes ↓" />
        <IssueTile label="Cloud services billed" loading={busy(cs)} status={sevOf(csF)}
          headline={cs.rows && csDays.size ? `${fmtInt(billedDays)} of ${fmtInt(csDays.size)}` : null} unit="days over the 10% allowance" missingReason={why(cs) || "no cloud services usage"}
          base={cs.rows && csDays.size ? [csUsd != null ? `${usd0(csUsd)} billed` : `${fmtInt(Math.round(csBilled))} credits billed`, csUsed > 0 ? `${fmtShare(pctOf(csBilled, csUsed))} of cloud services credits` : null].filter(Boolean).join(" · ") : null}
          cause="The free 10% is counted per day against warehouse compute." onOpen={() => scrollToAnchor("cs-days")} openLabel="By day ↓" />
        <IssueTile label="Growing faster than the account" loading={busy(svc)} status={!(ready && acctPct != null) ? "not_assessed" : growers.length ? sevOf(svcF) : "ok"}
          headline={ready && acctPct != null ? `${fmtInt(growers.length)} of ${fmtInt(live.length)}` : null} unit="services"
          missingReason={why(svc) || "no previous period to compare"}
          base={ready && acctPct != null ? `${usd0(growers.reduce((s, x) => s + x.cur, 0))} of ${usd0(total)} spend · account ${fmtChangePct(acctPct)}` : null}
          cause={growers.length ? growers.slice(0, 2).map((s) => `${s.name} ${growth(s) == null ? "new" : fmtChangePct(growth(s))}`).join(", ") + "." : null}
          onOpen={() => scrollToAnchor("cs-change")} openLabel="Change vs the account ↓" />
        <IssueTile label="Data transfer egress" loading={busy(eg)} status={sevOf(egF)}
          headline={eg.rows && egRows.length ? (egFlag.length ? usd0(egFlagUsd) : "None") : null} unit={egFlag.length ? `on ${fmtInt(egFlag.length)} route${egFlag.length === 1 ? "" : "s"}` : undefined}
          missingReason={why(eg) || "no transfer in this window"}
          base={eg.rows && egRows.length ? `of ${usd0(egAll)} transfer spend · ${fmtInt(egFlag.length)} of ${fmtInt(egRows.length)} routes flagged${egFlag.length ? ` · ${fmtShare(pctOf(egFlagUsd, egAll))}` : ""}` : null}
          cause="Priced at your per-TB rate card: the usage views carry no transfer price." onOpen={openDrawer("sf_cost_data_transfer_egress")} openLabel="Open check →" />
      </Tiles>

      <div className="cj-charts-2">
        <div id="cs-where">
          <PatternCard title="Where spend goes, by service" sub={ready ? `${usd0(total)} across ${fmtInt(live.length)} services · this period` : "This period"}>
            {!ready ? <Note text={svc.note || "– No priced service rows in this window."} /> : (
              <div>
                <StackedShareBar height={26} pareto maxSegments={6} valueFmt={usd0} ariaLabel="Spend by service"
                  segments={live.map((s) => ({ key: s.key, label: s.name, value: s.cur, onClick: () => openSvc(s.key) }))} />
                <div className="sx-sub">Warehouses vs serverless vs storage</div>
                <StackedShareBar height={22} valueFmt={usd0} ariaLabel="Spend by kind"
                  segments={kinds.map((k, i) => ({ key: k.k, label: k.k, value: k.v, color: ["var(--c1)", "var(--c2)", "var(--c-other)"][i] }))} />
                {csUsd != null && billedDays > 0 && <div className="sx-foot">{`Cloud services above the free allowance: ${usd0(csUsd)} on ${fmtInt(billedDays)} of ${fmtInt(csDays.size)} days, billed on top of warehouse compute.`}</div>}
              </div>
            )}
          </PatternCard>
        </div>
        <PatternCard title="Ranked by spend, with change" sub="This period vs the one before · click a service for its rows">
          {!ready ? <Note text={svc.note || "–"} /> : <ThisVsPrevBars items={services} n={9} onOpen={openSvc} />}
        </PatternCard>
      </div>

      <div className="cj-charts-2">
        <div id="cs-change">
          <PatternCard title={acctPct != null ? `Change vs the account's ${fmtChangePct(acctPct)}` : "Change vs the account"}
            sub={acctPct != null ? `Each service's growth against the whole account's · ${fmtInt(growers.length)} of ${fmtInt(live.length)} grew faster` : "Needs the previous period"}>
            {!ready || acctPct == null ? <Note text={svc.note || "– No previous period to compare in this export."} /> : (
              <DrillTable aria="Services growing faster than the account" n={8}
                empty={`No service grew faster than the account in ${rangeOf(p)}.`}
                cols={[{ label: "Service" }, { label: "This service", width: "minmax(60px, 1fr)" }, { label: "Whole account", width: "minmax(60px, 1fr)" }, { label: "Change", num: true, width: "auto" }]}
                rows={growers.map((s) => ({
                  key: s.key, onOpen: () => openSvc(s.key),
                  cells: [s.name, <MiniBar key="a" value={growth(s) ?? maxPct} max={maxPct} />, <MiniBar key="b" value={Math.max(0, acctPct)} max={maxPct} />,
                    `${growth(s) == null ? "new" : fmtChangePct(growth(s))} vs ${fmtChangePct(acctPct)}`],
                }))} />
            )}
          </PatternCard>
        </div>
        <div id="cs-days">
          <PatternCard title="Cloud services vs the 10% allowance, by day" sub="Cloud services credits as a share of that day's warehouse compute · amber: over 10% and billed">
            {cs.rows && csTimeline.length ? (
              <DayKindTimeline rows={csTimeline} days={csTimeline.map((d) => d.day)} kinds={["Within 10%", "Over the allowance"]} height={170}
                kindColors={{ "Within 10%": "var(--c1)", "Over the allowance": "var(--st-warn)" }}
                partialDay={(p.meta && p.meta.cost_cutoff && p.meta.cost_cutoff.partial_day) || null}
                valueFmt={(v) => fmtShare(v)} unitLabel="of compute" ariaLabel="Cloud services ratio by day" />
            ) : <Note text={cs.note || "– No cloud services usage in this window."} />}
          </PatternCard>
        </div>
      </div>
    </div>
  );
}
(ApCostByService as any).ownsTiles = true;
(ApCostByService as any).ownsLede = true;

// ═══════════════════════ Who spent it ═══════════════════════
// Warehouse compute = attributed to queries | idle | not attributed (queries under ~100 ms, lag). One
// total; users and roles are ranked as shares of the attributed part only.
export function ApCostWho(p: ApPageProps) {
  const att = useCheckRows(p, "sf_cost_query_attribution_by_user");
  const roles = useCheckRows(p, "sf_chg_by_role");
  const bi = useCheckRows(p, "sf_chg_bi_dashboards");
  const dbt = useCheckRows(p, "sf_chg_dbt_models");
  const WD = "sf_chg_by_warehouse_and_user_daily";
  const whF = findingOf(p, WD);
  const whAgg = useFindingAgg(whF ? WD : null, p.filters.window, p.filters.accountIds, ["warehouse_id", "row_kind"], "sum", "est_attributed_usd_list") as FetchState;
  const attF = findingOf(p, "sf_cost_query_attribution_by_user"), rolesF = findingOf(p, "sf_chg_by_role"), biF = findingOf(p, "sf_chg_bi_dashboards"), dbtF = findingOf(p, "sf_chg_dbt_models");

  // Attributed vs idle vs not attributed, at one $ per credit taken from the check's own priced rows.
  const rows = att.rows || [];
  const asUsd = rows.length > 0 && priced(rows);
  const credits = (r: Row) => numOrZero(r.attributed_credits);
  const cr = rows.reduce((s, r) => s + credits(r), 0);
  const rate = asUsd && cr > 0 ? (rows.reduce((s, r) => s + numOrZero(r.est_attributed_usd_list), 0) / cr) * (1 - att.disc) : 1;
  const fmt = asUsd ? usd0 : (v: number) => `${fmtInt(Math.round(v))} credits`;
  const isIdle = (r: Row) => r.row_kind === "idle";
  const attributed = rows.filter((r) => !isIdle(r)).reduce((s, r) => s + credits(r), 0) * rate;
  const idle = rows.filter(isIdle).reduce((s, r) => s + credits(r), 0) * rate;
  // warehouse_compute_credits repeats on every row of an account: counted once per account.
  const whByAcct = new Map<string, number>();
  rows.forEach((r) => whByAcct.set(String(r.account_id), Math.max(whByAcct.get(String(r.account_id)) || 0, numOrZero(r.warehouse_compute_credits))));
  const whTotal = Math.max([...whByAcct.values()].reduce((s, v) => s + v, 0) * rate, attributed + idle);
  const byUser = new Map<string, number>();
  rows.filter((r) => !isIdle(r)).forEach((r) => { const k = String(r.user_name || "(no user)"); byUser.set(k, (byUser.get(k) || 0) + credits(r) * rate); });
  const users = [...byUser.entries()].sort((a, b) => b[1] - a[1]);
  const topUser = users[0];

  // Roles: their attributed $, and the ones no cost tag names.
  const rRows = roles.rows || [];
  const rUsd = rRows.length > 0 && priced(rRows);
  const rVal = (r: Row) => (rUsd ? numOrZero(r.est_attributed_usd_list) * (1 - roles.disc) : numOrZero(r.attributed_credits));
  const byRole = new Map<string, { v: number; owned: boolean; users: number; status: string }>();
  rRows.forEach((r) => {
    const k = String(r.role_name || "(no role)");
    const g = byRole.get(k) || { v: 0, owned: false, users: 0, status: "OK" };
    g.v += rVal(r); g.owned = g.owned || !!r.cost_tag_value; g.users = Math.max(g.users, numOrZero(r.distinct_users));
    if (r.status === "CRITICAL" || (r.status === "WARN" && g.status !== "CRITICAL")) g.status = r.status;
    byRole.set(k, g);
  });
  const roleList = [...byRole.entries()].map(([name, g]) => ({ name, ...g })).sort((a, b) => b.v - a.v);
  const roleTotal = roleList.reduce((s, r) => s + r.v, 0);
  const unowned = roleList.filter((r) => !r.owned && r.v > 0);
  const unownedV = unowned.reduce((s, r) => s + r.v, 0);
  const rFmt = rUsd ? usd0 : (v: number) => `${fmtInt(Math.round(v))} credits`;

  // Source tools: dbt models and BI tools, each from its own check.
  const dbtRows = (dbt.rows || []).filter((r) => r.row_kind === "model");
  const dbtUsd = dbtRows.reduce((s, r) => s + numOrZero(r.est_usd_list), 0) * (1 - dbt.disc);
  const biTools = new Map<string, { v: number; n: number }>();
  (bi.rows || []).filter((r) => r.row_kind === "dashboard").forEach((r) => {
    const k = String(r.bi_tool || "(unknown tool)");
    const g = biTools.get(k) || { v: 0, n: 0 };
    g.v += numOrZero(r.est_attributed_usd_list) * (1 - bi.disc); g.n += 1;
    biTools.set(k, g);
  });
  const biUsd = [...biTools.values()].reduce((s, g) => s + g.v, 0);
  const tools = [
    ...(dbt.rows && dbtRows.length ? [{ key: "dbt", name: "dbt", v: dbtUsd, note: affText(dbtF) || `${fmtInt(dbtRows.length)} models`, open: openDrawer("sf_chg_dbt_models") }] : []),
    ...[...biTools.entries()].map(([k, g]) => ({ key: k, name: k, v: g.v, note: `${fmtInt(g.n)} dashboard${g.n === 1 ? "" : "s"}`, open: openDrawer("sf_chg_bi_dashboards", "bi_tool", k, k) })),
  ].sort((a, b) => b.v - a.v);
  const toolMax = Math.max(1, ...tools.map((t) => t.v));

  // Attributed vs idle per warehouse, from the daily chargeback check's sums.
  const whGroups = whAgg.phase === "ready" && whAgg.outcome === "ok_rows" && whAgg.data ? (whAgg.data.groups || []) : null;
  const whDisc = whAgg.data ? numOrZero(whAgg.data.discount_pct) : 0;
  const perWh = new Map<string, { att: number; idle: number }>();
  (whGroups || []).forEach((g: { key: any[]; value: number }) => {
    const k = String(g.key[0]);
    const cur = perWh.get(k) || { att: 0, idle: 0 };
    if (g.key[1] === "idle") cur.idle += numOrZero(g.value) * (1 - whDisc); else cur.att += numOrZero(g.value) * (1 - whDisc);
    perWh.set(k, cur);
  });
  const whList = [...perWh.entries()].map(([id, v]) => ({ id, ...v, all: v.att + v.idle })).filter((w) => w.all > 0).sort((a, b) => b.all - a.all);
  const whMax = whList.length ? whList[0].all : 1;
  const whNote = !whF ? "– Not in this export yet: run the export again." : whAgg.phase === "loading" ? "…" : whAgg.phase === "error" ? `– ${whAgg.error || "Could not load"}` : !whGroups ? `– ${notAssessedText(whAgg.data)}` : null;

  const ready = rows.length > 0 && whTotal > 0;
  const lede = busy(att) ? "…" : ready
    ? `${fmtShare(pctOf(attributed, whTotal))} of warehouse compute (${fmt(attributed)} of ${fmt(whTotal)}) lands on a query${topUser && attributed > 0 ? `; ${topUser[0]} is ${fmtShare(pctOf(topUser[1], attributed))} of it` : ""}.${roleList.length ? ` ${fmtInt(unowned.length)} of ${fmtInt(roleList.length)} roles spend with no owner.` : ""}`
    : null;
  useLede(p, lede);

  return (
    <div className="sx-page">
      <Tiles>
        <IssueTile label="Attributed to queries" loading={busy(att)} pill={<KindChip>Context</KindChip>}
          headline={ready ? fmtShare(pctOf(attributed, whTotal)) : null} unit="of warehouse compute" missingReason={why(att) || "no attribution rows"}
          base={ready ? `${fmt(attributed)} of ${fmt(whTotal)} · idle ${fmtShare(pctOf(idle, whTotal))}, ${fmt(idle)}` : null}
          cause="Not attributed: queries under about 100 ms and the last 8 h." onOpen={() => scrollToAnchor("cw-who")} openLabel="Users and roles ↓" />
        <IssueTile label="One user's share" loading={busy(att)} status={sevOf(attF)}
          headline={ready && topUser ? fmtShare(pctOf(topUser[1], attributed)) : null} unit={topUser ? `is ${topUser[0]}` : undefined} missingReason={why(att) || "no user attribution"}
          base={ready && topUser ? [`${fmt(topUser[1])} of ${fmt(attributed)}`, affText(attF)].filter(Boolean).join(" · ") : null}
          cause="A service user often runs tasks and pipelines: charge it by the task's warehouse or query tag." onOpen={openDrawer("sf_cost_query_attribution_by_user")} openLabel="By user →" />
        <IssueTile label="Roles with no cost owner" loading={busy(roles)} status={sevOf(rolesF)}
          headline={roles.rows && roleList.length ? `${fmtInt(unowned.length)} of ${fmtInt(roleList.length)}` : null} unit="roles" missingReason={why(roles) || "no role attribution"}
          base={roles.rows && roleList.length ? `${rFmt(unownedV)} of ${rFmt(roleTotal)} role-attributed spend · ${fmtShare(pctOf(unownedV, roleTotal))}` : null}
          cause="No cost tag names who pays for them." onOpen={() => scrollToAnchor("cw-roles")} openLabel="By role ↓" />
        <IssueTile label="By source tool" loading={busy(dbt) || busy(bi)} status={worse(sevOf(dbtF), sevOf(biF))}
          headline={tools.length ? usd0(tools[0].v) : null} unit={tools.length ? `is ${tools[0].name}` : undefined}
          missingReason={why(dbt) || why(bi) || "no dbt or BI tool spend recorded"}
          base={tools.length ? [tools[0].note, biTools.size ? `BI tools ${usd0(biUsd)}, ${affText(biF, "") || `${fmtInt(biTools.size)} tools`}` : null].filter(Boolean).join(" · ") : null}
          cause={tools.length && attributed > 0 && asUsd ? `${fmtShare(pctOf(tools[0].v, attributed))} of attributed compute.` : null}
          onOpen={() => scrollToAnchor("cw-tools")} openLabel="By source tool ↓" />
      </Tiles>

      <div className="cj-charts-2">
        <div id="cw-who">
          <PatternCard title="Who used the compute" sub={ready ? `Share of the attributed ${fmt(attributed)} · by user, then by role` : "Share of the attributed part"}>
            {!ready ? <Note text={att.note || "– No query attributed to a user in this window."} /> : (
              <div>
                <StackedShareBar height={26} pareto maxSegments={6} valueFmt={fmt} ariaLabel="Attributed compute by user"
                  segments={users.map(([name, v]) => ({ key: name, label: name, value: v }))} />
                <div className="sx-sub">{`By role${roleTotal > 0 ? ` · ${rFmt(roleTotal)} role-attributed` : ""}`}</div>
                {roles.rows && roleList.length
                  ? <StackedShareBar height={22} pareto maxSegments={6} valueFmt={rFmt} ariaLabel="Attributed compute by role"
                      segments={roleList.map((r) => ({ key: r.name, label: r.name, value: r.v }))} />
                  : <Note text={roles.note || "– No role attribution in this window."} />}
              </div>
            )}
          </PatternCard>
        </div>
        <PatternCard title="Attributed vs idle, by warehouse" sub={whList.length ? `${usd0(whList.reduce((s, w) => s + w.all, 0))} warehouse compute · ${fmtInt(whList.length)} warehouses · blue attributed, sand idle` : "Attributed and idle, by warehouse"}>
          {whNote ? <Note text={whNote} /> : (
            <DrillTable aria="Attributed vs idle by warehouse" n={8} empty={`No warehouse compute in ${rangeOf(p)}.`}
              cols={[{ label: "Warehouse" }, { label: "Attributed · idle", width: "minmax(80px, 1.4fr)" }, { label: "Spend", num: true, width: "auto" }, { label: "Idle", num: true, width: "auto" }]}
              rows={whList.map((w) => {
                const n = whNameId(w.id);
                return {
                  key: w.id, onOpen: openDrawer(WD, "warehouse_id", w.id, n.name),
                  cells: [<NameId key="n" name={n.name} id={n.id} />, <SplitBar key="b" max={whMax} parts={[{ value: w.att }, { value: w.idle, color: "var(--c-other)" }]} />, usd0(w.all), fmtShare(pctOf(w.idle, w.all))],
                };
              })} />
          )}
        </PatternCard>
      </div>

      <div className="cj-charts-2">
        <div id="cw-tools">
          <PatternCard title="By source tool" sub="dbt per model and BI tools per dashboard, each from its own check">
            {busy(dbt) || busy(bi) ? <Note text="…" /> : tools.length ? (
              <DrillTable aria="Spend by source tool" n={8}
                cols={[{ label: "Tool" }, { label: "", width: "minmax(60px, 1fr)" }, { label: "Spend", num: true, width: "auto" }, { label: "", width: "minmax(90px, auto)" }]}
                rows={tools.map((t) => ({ key: t.key, onOpen: t.open, cells: [t.name, <MiniBar key="b" value={t.v} max={toolMax} />, usd0(t.v), t.note] }))} />
            ) : <Note text={why(dbt) ? `– ${why(dbt)}` : "– No dbt or BI tool spend recorded in this window."} />}
          </PatternCard>
        </div>
        <div id="cw-roles">
          <PatternCard title="Roles with no cost owner" sub={roleList.length ? `${rFmt(unownedV)} of ${rFmt(roleTotal)} · ${fmtInt(unowned.length)} of ${fmtInt(roleList.length)} roles · no cost tag names a team` : "Roles no cost tag names"}>
            {!roles.rows ? <Note text={roles.note || "–"} /> : (
              <DrillTable aria="Roles with no cost owner" n={8} empty="Every role that spent carries a cost tag."
                cols={[{ label: "Role" }, { label: "", width: "minmax(60px, 1fr)" }, { label: "Spend", num: true, width: "auto" }, { label: "Users", num: true, width: "auto" }]}
                rows={unowned.map((r) => ({ key: r.name, status: r.status, onOpen: openDrawer("sf_chg_by_role", "role_name", r.name, r.name),
                  cells: [r.name, <MiniBar key="b" value={r.v} max={unowned[0] ? unowned[0].v : 1} />, rFmt(r.v), `${fmtInt(r.users)} user${r.users === 1 ? "" : "s"}`] }))} />
            )}
          </PatternCard>
        </div>
      </div>
    </div>
  );
}
(ApCostWho as any).ownsTiles = true;
(ApCostWho as any).ownsLede = true;

// ═══════════════════════ Chargeback & tags ═══════════════════════
const TYPE_NOUN: Record<string, string> = { WAREHOUSE: "Warehouses", USER: "Users", ROLE: "Roles", DATABASE: "Databases" };

export function ApCostChargeback(p: ApPageProps) {
  const cc = useCostCenterAllocation(p.filters);
  const cov = useCheckRows(p, "sf_chg_tag_coverage");
  const rec = useCheckRows(p, "sf_chg_allocation_reconciliation");
  const db = useCheckRows(p, "sf_chg_by_database_schema");
  const covF = findingOf(p, "sf_chg_tag_coverage"), recF = findingOf(p, "sf_chg_allocation_reconciliation"), dbF = findingOf(p, "sf_chg_by_database_schema");
  const allocF = findingOf(p, "sf_chg_tag_based_allocation");

  // 1. Billed spend by cost center, the untagged part hatched.
  const d: Row | null = cc.phase === "ready" ? cc.data : null;
  const ccOk = !!d && d.outcome === "ok_rows";
  const byValue: Row[] = ccOk ? (d!.by_value || []) : [];
  const ccTotal = ccOk ? numOrZero(d!.total && d!.total.usd) : null;
  const untagged = byValue.filter((e) => e.value === "__untagged__").reduce((s, e) => s + numOrZero(e.metrics && e.metrics.usd), 0);
  const ccValues = byValue.filter((e) => e.value !== "__untagged__" && numOrZero(e.metrics && e.metrics.usd) > 0).length;
  const recon: Row | null = ccOk ? d!.reconciliation || null : null;
  const tie = reconciliationLine(recon);
  const ccNote = cc.phase === "loading" ? "…" : cc.phase === "error" ? `– ${cc.error || "Could not load the cost-center split"}` : d && !ccOk ? (rollupNote(d, "cost") || "– No cost-center split for this window.") : null;
  const ccPct = ccTotal ? pctOf(untagged, ccTotal) : null;

  // 2. Spending objects with no cost tag; each type is its own split of the same spend, never added.
  const cRows = cov.rows || [];
  const asUsd = cRows.length > 0 && priced(cRows);
  const val = (r: Row) => (asUsd ? numOrZero(r.est_usd_list) * (1 - cov.disc) : numOrZero(r.credits));
  const spending = cRows.filter((r) => val(r) > 0);
  const noTag = spending.filter((r) => !isTrue(r.is_tagged));
  const whSpend = spending.filter((r) => String(r.object_type).toUpperCase() === "WAREHOUSE");
  const whUntagged = whSpend.filter((r) => !isTrue(r.is_tagged)).reduce((s, r) => s + val(r), 0);
  const whAll = whSpend.reduce((s, r) => s + val(r), 0);
  const byType = new Map<string, { untagged: number; total: number; n: number; nu: number }>();
  cRows.forEach((r) => {
    const k = String(r.basis || r.object_type || "").toUpperCase();
    const g = byType.get(k) || { untagged: 0, total: 0, n: 0, nu: 0 };
    g.total += val(r); g.n += 1;
    if (!isTrue(r.is_tagged)) { g.untagged += val(r); g.nu += 1; }
    byType.set(k, g);
  });
  const typeItems: ShareItem[] = [...byType.entries()].map(([k, v]) => ({
    key: k, name: `${TYPE_NOUN[k] || k.toLowerCase()} · ${fmtInt(v.nu)} of ${fmtInt(v.n)}`, value: v.untagged, total: v.total,
    onClick: openDrawer("sf_chg_tag_coverage", "object_type", k, TYPE_NOUN[k] || k),
  }));
  const fmtV = asUsd ? usd0 : (v: number) => `${fmtInt(Math.round(v))} credits`;

  // 3. What each service's billed $ can be charged back.
  const rRows = (rec.rows || []).filter((r) => numOrZero(r.est_billed_usd_list) > 0);
  const recKeep = 1 - rec.disc;
  const svcRec = rRows.map((r) => {
    const billed = numOrZero(r.est_billed_usd_list) * recKeep;
    const un = numOrZero(r.est_unallocated_usd_list) * recKeep;
    return { key: `${r.account_id}|${r.service_type}`, code: String(r.service_type || ""), billed, un, ok: billed - un, status: r.status, to: String(r.allocated_to || "") };
  }).sort((a, b) => b.billed - a.billed);
  const recBilled = svcRec.reduce((s, x) => s + x.billed, 0), recOk = svcRec.reduce((s, x) => s + x.ok, 0);
  const underHalf = svcRec.filter((x) => pctOf(x.un, x.billed)! > 50);
  const recMax = svcRec.length ? svcRec[0].billed : 1;

  // 4. Full cost per database.
  const dbRows = (db.rows || []).filter((r) => r.row_kind === "database" && r.est_total_usd_list != null);
  const dbUsd = (r: Row) => numOrZero(r.est_total_usd_list) * (1 - db.disc);
  const dbSorted = [...dbRows].sort((a, b) => dbUsd(b) - dbUsd(a));
  const dbTotal = dbRows.reduce((s, r) => s + dbUsd(r), 0);
  const dbTop = dbSorted[0];

  const reconSteps: ReconStep[] = [
    { key: "metered", label: "Metered (usage views)", value: recon && recon.spend_usd != null ? numOrZero(recon.spend_usd) : null, note: "credits × your effective $ per credit", missingReason: ccNote ? ccNote.replace(/^– /, "") : "not in this split" },
    { key: "billed", label: "Billed to split", value: recon && recon.billing_usd != null ? numOrZero(recon.billing_usd) : null, note: recon && numOrZero(recon.outside_split_usd) > 0 ? `storage & transfer ${usd0(numOrZero(recon.outside_split_usd))} outside the split` : "spend the split covers", missingReason: "no bill to split" },
    { key: "allocated", label: "Allocated by cost center", value: recon && recon.rollup_usd != null ? numOrZero(recon.rollup_usd) : ccTotal, note: ccPct != null ? `${fmtShare(ccPct)} has no cost center` : undefined, missingReason: "no cost-center split" },
  ];

  const lede = cc.phase === "loading" ? "…" : ccPct != null
    ? `${fmtShare(ccPct)} of billed spend (${usd0(untagged)} of ${usd0(ccTotal!)}) reaches no cost center.${cov.rows && spending.length ? ` ${fmtInt(noTag.length)} of ${fmtInt(spending.length)} spending objects carry no cost tag.` : ""}${tie ? ` ${tie.text}` : ""}`
    : null;
  useLede(p, lede);

  return (
    <div className="sx-page">
      <Tiles>
        <IssueTile label="No cost center" loading={cc.phase === "loading"} status={ccPct != null ? (allocF ? sevOf(allocF) : ccPct > 20 ? "warn" : "ok") : "not_assessed"}
          headline={ccPct != null ? fmtShare(ccPct) : null} unit="of billed spend" missingReason={ccNote ? ccNote.replace(/^– /, "") : "no cost-center split"}
          base={ccPct != null ? `${usd0(untagged)} of ${usd0(ccTotal!)} · ${fmtInt(ccValues)} values in use` : null}
          cause={ccValues && ccPct != null ? `The ${fmtInt(ccValues)} cost centers share the other ${fmtShare(100 - ccPct)}.` : null}
          onOpen={() => scrollToAnchor("cc-split")} openLabel="By cost center ↓" />
        <IssueTile label="Spending objects with no cost tag" loading={busy(cov)} status={sevOf(covF)}
          headline={cov.rows && spending.length ? `${fmtInt(noTag.length)} of ${fmtInt(spending.length)}` : null} unit="objects" missingReason={why(cov) || "no spending objects"}
          base={cov.rows && whAll > 0 ? `${fmtV(whUntagged)} of ${fmtV(whAll)} warehouse spend · ${fmtShare(pctOf(whUntagged, whAll))}` : null}
          cause="Warehouses, databases, users and roles that spend but carry no cost tag." onOpen={() => scrollToAnchor("cc-types")} openLabel="By object type ↓" />
        <IssueTile label="Chargeable per service" loading={busy(rec)} status={sevOf(recF)}
          headline={rec.rows && svcRec.length ? `${fmtInt(underHalf.length)} of ${fmtInt(svcRec.length)}` : null} unit="services under half chargeable" missingReason={why(rec) || "no billed services"}
          base={rec.rows && svcRec.length ? `${usd0(recBilled)} billed to split · ${fmtShare(pctOf(recOk, recBilled))} can be allocated` : null}
          cause="Serverless follows the object's tag; warehouses follow the warehouse or query tag." onOpen={() => scrollToAnchor("cc-svc")} openLabel="Per service ↓" />
        <IssueTile label="Full cost per database" loading={busy(db)} status={sevOf(dbF)}
          headline={dbTop ? usd0(dbUsd(dbTop)) : null} unit="on one database" missingReason={why(db) || "no database-attributable spend"}
          base={dbTop ? `of ${usd0(dbTotal)} database-attributable spend · 1 of ${fmtInt(dbRows.length)} databases · ${fmtShare(pctOf(dbUsd(dbTop), dbTotal))}` : null}
          cause={dbTop ? `${dbTop.database_name || "(no name)"}${dbTop.database_id != null ? ` (${dbTop.database_id})` : ""}: compute, storage and serverless together.` : null}
          onOpen={dbTop ? openDrawer("sf_chg_by_database_schema", dbTop.database_id != null ? "database_id" : "database_name", dbTop.database_id ?? dbTop.database_name, dbTop.database_name) : undefined} openLabel="Open check →" />
      </Tiles>

      <div className="cj-charts-2">
        <div id="cc-split">
          <PatternCard title="Billed spend by cost center" sub={ccTotal != null ? `${usd0(ccTotal)} split · ${fmtInt(ccValues)} cost centers and the untagged remainder` : "One 100% bar · untagged hatched"}>
            {ccNote ? <Note text={ccNote} /> : (
              <div>
                <StackedShareBar height={26} segments={byValue.map((e): ShareSegment => ({ key: String(e.value), label: e.value === "__untagged__" ? "No cost center" : String(e.label || e.value), value: numOrZero(e.metrics && e.metrics.usd), unknown: e.value === "__untagged__" }))}
                  valueFmt={usd0} pareto maxSegments={7} ariaLabel="Billed spend by cost center" />
                {tie && <div className={`sx-foot${tie.tone === "crit" ? " tone-crit" : ""}`}>{tie.text}</div>}
              </div>
            )}
          </PatternCard>
        </div>
        <div id="cc-types">
          <PatternCard title="No cost tag, by object type" sub="Untagged share of each type's own spend · compare them, never add them" link="Tags →" onLink={() => p.goTo({ tab: "tags" })}>
            {cov.note && !cov.rows?.length ? <Note text={cov.note} /> : <ShareBarList items={typeItems} n={5} valueFmt={fmtV} noun="untagged" />}
          </PatternCard>
        </div>
      </div>

      <div className="cj-charts-2">
        <div id="cc-svc">
          <PatternCard title="What can be charged back, per service" sub={svcRec.length ? `Of each service's billed $, how much can be allocated · ${fmtInt(underHalf.length)} of ${fmtInt(svcRec.length)} under half` : "Per service"}>
            {!rec.rows ? <Note text={rec.note || "–"} /> : (
              <DrillTable aria="Chargeable share per service" n={8} empty={`No billed service in ${rangeOf(p)}.`}
                cols={[{ label: "Service" }, { label: "Allocated · not", width: "minmax(70px, 1.3fr)" }, { label: "Billed", num: true, width: "auto" }, { label: "Chargeable", num: true, width: "auto" }]}
                rows={svcRec.map((x) => ({
                  key: x.key, status: x.status, title: x.to ? `allocated to: ${x.to}` : undefined,
                  onOpen: openDrawer("sf_chg_allocation_reconciliation", "service_type", x.code, costServiceWords(x.code)),
                  cells: [costServiceWords(x.code), <SplitBar key="b" max={recMax} parts={[{ value: x.ok }, { value: x.un, hatched: true }]} />, usd0(x.billed), fmtShare(pctOf(x.ok, x.billed))],
                }))} />
            )}
          </PatternCard>
        </div>
        <PatternCard title="Ties to the bill" sub="Metered → billed to split → allocated" link="Contract & rate →" onLink={() => p.goTo({ tab: "cost", subtab: "contract" })}>
          {cc.phase === "loading" ? <Note text="…" /> : <ReconciliationStrip steps={reconSteps} />}
        </PatternCard>
      </div>

      <div id="cc-dims">
        <ChargebackByDimension p={p} />
      </div>
    </div>
  );
}
(ApCostChargeback as any).ownsTiles = true;
(ApCostChargeback as any).ownsLede = true;

// ═══════════════════════ Contract & rate ═══════════════════════
export function ApCostContract(p: ApPageProps) {
  const con = useCheckRows(p, "sf_cost_contract_balance_burn");
  const inv = useCheckRows(p, "sf_cost_invoice_vs_metered");
  const rate = useCheckRows(p, "sf_cost_rate_sheet");
  const conF = findingOf(p, "sf_cost_contract_balance_burn"), invF = findingOf(p, "sf_cost_invoice_vs_metered"), rateF = findingOf(p, "sf_cost_rate_sheet");

  // The contract that runs out first.
  const contracts = (con.rows || []).filter((r) => r.runway_days != null || r.days_to_contract_end != null);
  const c0 = [...contracts].sort((a, b) => numOrZero(a.runway_days) - numOrZero(b.runway_days))[0] || null;
  const runway = c0 && c0.runway_days != null ? Number(c0.runway_days) : null;
  const toEnd = c0 && c0.days_to_contract_end != null ? Number(c0.days_to_contract_end) : null;
  const early = runway != null && toEnd != null ? toEnd - runway : null;
  const cur = (v: any) => (c0 && c0.currency && String(c0.currency).toUpperCase() !== "USD" ? `${fmtInt(Math.round(numOrZero(v)))} ${c0.currency}` : usd0(numOrZero(v)));

  // Effective $ per credit from the invoice's all-credits lines, against the app's list price.
  const invRows = (inv.state.phase === "ready" && inv.state.outcome === "ok_rows" ? inv.state.data!.rows || [] : []) as Row[];
  const usdRows = invRows.filter((r) => !r.currency || String(r.currency).toUpperCase() === "USD");
  const totals = usdRows.filter((r) => isTrue(r.is_total_row));
  const amount = totals.reduce((s, r) => s + numOrZero(r.invoice_amount), 0);
  const usage = totals.reduce((s, r) => s + numOrZero(r.invoice_usage), 0);
  const eff = usage > 0 ? amount / usage : null;
  const list = totals.map((r) => r.app_credit_price_usd).find((v) => v != null);
  const listN = list != null ? Number(list) : null;
  const effGap = eff != null && listN ? ((eff - listN) / listN) * 100 : null;
  const lines = usdRows.filter((r) => !isTrue(r.is_total_row));
  const byType = new Map<string, { amount: number; gap: number | null; status: string }>();
  lines.forEach((r) => {
    const k = String(r.usage_type || "(no usage type)");
    const g = byType.get(k) || { amount: 0, gap: null, status: "OK" };
    g.amount += numOrZero(r.invoice_amount);
    if (r.rate_gap_pct != null && (g.gap == null || Math.abs(Number(r.rate_gap_pct)) > Math.abs(g.gap))) g.gap = Number(r.rate_gap_pct);
    if (r.status === "CRITICAL" || (r.status === "WARN" && g.status !== "CRITICAL")) g.status = r.status;
    byType.set(k, g);
  });
  const typeList = [...byType.entries()].map(([k, g]) => ({ k, ...g })).sort((a, b) => b.amount - a.amount);
  const typeMax = typeList.length ? typeList[0].amount : 1;

  // Rates, one per usage type (the check repeats a rate per account).
  const rateMap = new Map<string, Row>();
  (rate.rows || []).forEach((r) => { const k = `${r.usage_type}|${r.rating_type}|${r.billing_type}|${r.currency}`; if (!rateMap.has(k)) rateMap.set(k, r); });
  const rates = [...rateMap.values()];
  const changed = rates.filter((r) => numOrZero(r.distinct_rates) > 1);
  const ch0 = changed[0];

  const lede = busy(con) ? "…" : c0
    ? `The contract ends in ${fmtInt(toEnd)} d with ${cur(c0.prepaid_balance)} left.${early != null && early > 0 ? ` At the current burn the balance is gone ${fmtInt(Math.round(early))} d early.` : ""}${eff != null ? ` The invoice says ${fmtMoney(eff, 2)} per credit${listN ? ` against ${fmtMoney(listN, 2)} in the app` : ""}.` : ""}`
    : null;
  useLede(p, lede);

  return (
    <div className="sx-page">
      <Tiles>
        <IssueTile label="Balance runs out" loading={busy(con)} status={sevOf(conF)}
          headline={runway != null ? (early != null && early > 0 ? `${fmtInt(Math.round(early))} d` : `${fmtInt(Math.round(runway))} d`) : null}
          unit={early != null && early > 0 ? "before the contract ends" : "of runway"} missingReason={why(con) || "no capacity contract in this export"}
          base={c0 ? `${cur(c0.prepaid_balance)} left · ends ${fmtDayShort(c0.contract_end_date)}${toEnd != null ? `, in ${fmtInt(toEnd)} d` : ""}${contracts.length > 1 ? ` · 1 of ${fmtInt(contracts.length)} contracts` : ""}` : null}
          cause={c0 && c0.projected_depletion_date ? `At ${cur(c0.daily_burn)} a day the balance is gone ${fmtDayShort(c0.projected_depletion_date)}.` : null}
          onOpen={openDrawer("sf_cost_contract_balance_burn")} openLabel="Open check →" />
        <IssueTile label="Effective $ per credit" loading={busy(inv)} status={sevOf(invF)}
          headline={eff != null ? fmtMoney(eff, 2) : null} unit="per credit" missingReason={why(inv) || "no USD invoice lines"}
          base={eff != null ? [listN ? `list ${fmtMoney(listN, 2)}` : null, effGap != null ? `${fmtChangePct(effGap)} vs list` : null, `${fmtInt(Math.round(usage))} credits invoiced`, affText(invF)].filter(Boolean).join(" · ") : null}
          cause={listN && effGap != null && Math.abs(effGap) >= 1 ? "The app prices at its own $ per credit; set it to the invoice rate to match the bill." : null}
          onOpen={() => scrollToAnchor("cr-inv")} openLabel="Invoiced vs metered ↓" />
        <IssueTile label="Rate changes mid-term" loading={busy(rate)} status={!(rate.rows && rates.length) ? "not_assessed" : changed.length ? sevOf(rateF) : "ok"}
          headline={rate.rows && rates.length ? `${fmtInt(changed.length)} of ${fmtInt(rates.length)}` : null} unit="rates" missingReason={why(rate) || "no rate sheet"}
          base={ch0 ? `${ch0.usage_type} ${fmtMoney(numOrZero(ch0.first_rate), 2)} → ${fmtMoney(numOrZero(ch0.latest_rate), 2)}${ch0.change_pct != null ? ` · ${fmtChangePct(Number(ch0.change_pct))}` : ""}` : (rates.length ? "No rate changed in the window." : null)}
          onOpen={() => scrollToAnchor("cr-rates")} openLabel="Rates ↓" />
      </Tiles>

      <StatStrip ariaLabel="Contract figures" cells={[
        { key: "rate", label: "$ per credit", value: eff != null ? fmtMoney(eff, 2) : null, unit: listN ? ` list ${fmtMoney(listN, 2)}` : undefined, base: "invoice view", missing: why(inv) || "no USD invoice lines" },
        { key: "credits", label: "Credits invoiced", value: usage > 0 ? fmtInt(Math.round(usage)) : null, base: `${rangeOf(p)}`, missing: why(inv) || "–" },
        { key: "burn", label: "Run-rate", value: c0 && c0.daily_burn != null ? cur(c0.daily_burn) : null, unit: " / day", base: "contract balance burn", missing: why(con) || "no contract" },
        { key: "term", label: "Term left", pill: c0 ? sevOf(conF) : null, value: toEnd != null ? fmtInt(toEnd) : null, unit: " days", base: runway != null ? `balance lasts ${fmtInt(Math.round(runway))} d at the trend` : undefined, missing: why(con) || "no contract" },
      ]} />

      <div className="cj-charts-2">
        <div id="cr-inv">
          <PatternCard title="Invoiced vs metered at the app price" sub={eff != null ? `${usd0(amount)} invoiced · by usage type · the gap is the invoice rate vs the app's $ per credit` : "By usage type"}>
            {inv.note && !typeList.length ? <Note text={inv.note} /> : (
              <DrillTable aria="Invoiced by usage type" n={9} empty="No invoice lines in this window."
                cols={[{ label: "Usage type" }, { label: "", width: "minmax(60px, 1fr)" }, { label: "Invoiced", num: true, width: "auto" }, { label: "Rate gap", num: true, width: "auto" }]}
                rows={typeList.map((t) => ({ key: t.k, status: t.status, onOpen: openDrawer("sf_cost_invoice_vs_metered", "usage_type", t.k, t.k),
                  cells: [t.k, <MiniBar key="b" value={t.amount} max={typeMax} />, usd0(t.amount), t.gap != null ? fmtChangePct(t.gap) : "–"] }))} />
            )}
          </PatternCard>
        </div>
        <div id="cr-rates">
          <PatternCard title="Rates by usage type" sub={rates.length ? `Contract rate vs the app's list price · ${fmtInt(rates.length)} rates · snapshot` : "Snapshot"}>
            {rate.note && !rates.length ? <Note text={rate.note} /> : (
              <DrillTable aria="Rates by usage type" n={9} empty="No rate sheet lines."
                cols={[{ label: "Usage type" }, { label: "Contract", num: true, width: "auto" }, { label: "App price", num: true, width: "auto" }, { label: "Change", num: true, width: "auto" }]}
                rows={rates.map((r) => ({ key: `${r.usage_type}|${r.rating_type}|${r.billing_type}|${r.currency}`, status: r.status,
                  onOpen: openDrawer("sf_cost_rate_sheet", "usage_type", r.usage_type, String(r.usage_type)),
                  cells: [`${r.usage_type}${r.rating_type ? ` · ${r.rating_type}` : ""}`, r.latest_rate != null ? fmtMoney(numOrZero(r.latest_rate), 2) : "–",
                    r.app_credit_price_usd != null && String(r.rating_type) === "compute" ? fmtMoney(numOrZero(r.app_credit_price_usd), 2) : "–",
                    numOrZero(r.distinct_rates) > 1 && r.change_pct != null ? fmtChangePct(Number(r.change_pct)) : "–"] }))} />
            )}
          </PatternCard>
        </div>
      </div>
    </div>
  );
}
(ApCostContract as any).ownsTiles = true;
(ApCostContract as any).ownsLede = true;

// ═══════════════════════ Budgets & guardrails ═══════════════════════
export function ApCostBudgets(p: ApPageProps) {
  const mon = useCheckRows(p, "sf_cost_resource_monitor_coverage");
  const bud = useCheckRows(p, "sf_acct_budgets");
  const proj = useCheckRows(p, "sf_cost_resource_monitor_projection");
  const par = useCheckRows(p, "sf_acct_parameters_posture");
  const monF = findingOf(p, "sf_cost_resource_monitor_coverage"), projF = findingOf(p, "sf_cost_resource_monitor_projection"), parF = findingOf(p, "sf_acct_parameters_posture"), budF = findingOf(p, "sf_acct_budgets");

  // Per warehouse: its spend (repeated on each monitor row, so read once) and whether any monitor suspends it.
  // A warehouse the role cannot see is neither capped nor uncapped: counted apart, as on Warehouses and Overview.
  const mCov = monitorCoverage(mon.rows);
  const mRows = (mon.rows || []).filter((r) => r.status !== "NOT_ASSESSED");
  const asUsd = mRows.length > 0 && priced(mRows);
  const val = (r: Row) => (asUsd ? numOrZero(r.est_window_usd_list) * (1 - mon.disc) : numOrZero(r.window_credits));
  const fmt = asUsd ? usd0 : (v: number) => `${fmtInt(Math.round(v))} credits`;
  const whs = new Map<string, { id: any; name: string; v: number; capped: boolean; watched: boolean; own: boolean; status: string }>();
  mRows.forEach((r) => {
    const k = `${r.account_id}|${r.warehouse_id ?? r.warehouse_name}`;
    const g = whs.get(k) || { id: r.warehouse_id, name: String(r.warehouse_name || "(no name)"), v: 0, capped: false, watched: false, own: false, status: "OK" };
    g.v = Math.max(g.v, val(r)); g.capped = g.capped || isTrue(r.has_suspend); g.watched = g.watched || !!r.monitor_name;
    g.own = g.own || String(r.monitor_level || "").toUpperCase() === "WAREHOUSE";
    if (r.status === "CRITICAL" || (r.status === "WARN" && g.status !== "CRITICAL")) g.status = r.status;
    whs.set(k, g);
  });
  const whList = [...whs.values()];
  const whTotal = whList.reduce((s, w) => s + w.v, 0);
  const noCap = whList.filter((w) => !w.capped).sort((a, b) => b.v - a.v);
  const noCapV = noCap.reduce((s, w) => s + w.v, 0);
  const share = (f: (w: (typeof whList)[number]) => boolean) => whList.filter(f).reduce((s, w) => s + w.v, 0);

  // Monitors and their quota this cycle.
  const pRows = (proj.rows || []).filter((r) => numOrZero(r.credit_quota) > 0);
  const early = pRows.filter(isFlagged);
  const nextReset = pRows.map((r) => r.next_reset).filter(Boolean).sort()[0];
  const lead = [...pRows].sort((a, b) => numOrZero(b.used_pct) - numOrZero(a.used_pct))[0];
  const quotaItems: StatusBarItem[] = pRows.map((r) => ({
    key: `${r.account_id}|${r.monitor_name}`, name: String(r.monitor_name), value: numOrZero(r.used_pct), status: r.status,
    valueText: `${fmtShare(numOrZero(r.used_pct))}${r.projected_pct != null ? ` → ${fmtShare(numOrZero(r.projected_pct))}` : ""} of ${fmtInt(numOrZero(r.credit_quota))}`,
    title: `${r.monitor_name}: ${fmtInt(numOrZero(r.used_credits))} of ${fmtInt(numOrZero(r.credit_quota))} credits${r.projected_pct != null ? `, on pace for ${fmtShare(numOrZero(r.projected_pct))} by the reset` : ""}`,
  }));

  // Account parameters: judged ones only; NOT_ASSESSED is not "set".
  const params = (par.rows || []).filter((r) => r.status !== "NOT_ASSESSED");
  const costly = params.filter(isFlagged);

  // Budgets: custom budgets exist but what they cover is readable only with CALL.
  const acctB = (bud.rows || []).filter((r) => r.row_type === "ACCOUNT");
  const custom = acctB.reduce((s, r) => s + numOrZero(r.custom_budgets), 0);
  // Unpriced serverless spend is "–", never $0.
  const serverless = acctB.some((r) => r.est_serverless_usd_list != null)
    ? acctB.reduce((s, r) => s + numOrZero(r.est_serverless_usd_list), 0) * (1 - bud.disc) : null;
  const serverlessText = serverless != null ? usd0(serverless) : "– (not priced)";

  const lede = busy(mon) ? "…" : whList.length
    ? `${fmtInt(noCap.length)} of ${fmtInt(whList.length)} warehouses have no monitor that suspends them; they spent ${fmt(noCapV)}, ${fmtShare(pctOf(noCapV, whTotal))} of warehouse compute.${pRows.length ? ` ${fmtInt(early.length)} of ${fmtInt(pRows.length)} monitors will hit their quota before the reset.` : ""}`
    : null;
  useLede(p, lede);

  return (
    <div className="sx-page">
      <Tiles>
        <IssueTile label="No resource monitor cap" loading={busy(mon)} status={sevOf(monF)}
          headline={whList.length ? `${fmtInt(noCap.length)} of ${fmtInt(whList.length)}` : null} unit="warehouses" missingReason={why(mon) || "no warehouses"}
          base={whList.length ? `${fmt(noCapV)} of ${fmt(whTotal)} warehouse spend · ${fmtShare(pctOf(noCapV, whTotal))}${mCov.hidden ? ` · ${fmtInt(mCov.hidden)} not visible` : ""}` : null}
          cause="No monitor can suspend them; a notify-only monitor stops nothing." onOpen={() => scrollToAnchor("cb-nocap")} openLabel="By warehouse ↓" />
        <IssueTile label="Monitors hitting quota early" loading={busy(proj)} status={sevOf(projF)}
          headline={proj.rows && pRows.length ? `${fmtInt(early.length)} of ${fmtInt(pRows.length)}` : null} unit="resource monitors" missingReason={why(proj) || "no monitor with a quota"}
          base={pRows.length ? [`${fmtShare(pctOf(early.length, pRows.length))}`, "snapshot", nextReset ? `next reset ${fmtDayShort(nextReset)}` : null].filter(Boolean).join(" · ") : null}
          cause={lead ? `${lead.monitor_name} is at ${fmtShare(numOrZero(lead.used_pct))} of ${fmtInt(numOrZero(lead.credit_quota))} credits.` : null}
          onOpen={() => scrollToAnchor("cb-quota")} openLabel="Used of quota ↓" />
        <IssueTile label="Account parameters" loading={busy(par)} status={sevOf(parF)}
          headline={par.rows && params.length ? `${fmtInt(costly.length)} of ${fmtInt(params.length)}` : null} unit="left at a costly default" missingReason={why(par) || "no parameters read"}
          base={params.length ? `${fmtShare(pctOf(costly.length, params.length))} · snapshot · ${fmtInt((par.rows || []).length - params.length)} not readable` : null}
          cause={costly[0] ? `${costly[0].parameter}: ${costly[0].verdict || "default"}.` : null}
          onOpen={() => scrollToAnchor("cb-params")} openLabel="Which ones ↓" />
        <IssueTile label="Serverless $ under a budget" loading={busy(bud)} status={custom > 0 ? "not_assessed" : sevOf(budF)}
          headline={!bud.rows || custom > 0 || !acctB.length ? null : "None"} unit={custom > 0 ? undefined : `of ${serverlessText} serverless spend`}
          missingReason={custom > 0 ? `${fmtInt(custom)} custom budget${custom === 1 ? "" : "s"} exist; what they cover is readable only with CALL, not in this export` : (why(bud) || "no budgets read")}
          base={!bud.rows || custom > 0 || !acctB.length ? null : "no custom budget in the account"}
          onOpen={openDrawer("sf_acct_budgets")} openLabel="Open check →" />
      </Tiles>

      <div className="cj-charts-2">
        <div id="cb-quota">
          <PatternCard title="Monitors: used of quota, and where they land by the reset" sub={pRows.length ? `${fmtInt(pRows.length)} resource monitors · credits this cycle → projected at the current pace` : "This cycle"}>
            {!proj.rows ? <Note text={proj.note || "–"} /> : (
              <div>
                <StatusBars items={quotaItems} n={8} max={100} unitLabel="of quota" ariaLabel="Resource monitors: credits used of quota" emptyText="No monitor has a credit quota."
                  onBarClick={(it) => DrawerBus.open({ id: "sf_cost_resource_monitor_projection", col: "monitor_name", val: String(it.name), label: String(it.name) })} />
                {(proj.rows || []).length > pRows.length && <div className="sx-foot">{`${fmtInt((proj.rows || []).length - pRows.length)} monitor(s) with no quota not shown.`}</div>}
              </div>
            )}
          </PatternCard>
        </div>
        <PatternCard title="Guardrail coverage of warehouse spend" sub={whTotal > 0 ? `Share of ${fmt(whTotal)} each guard reaches · each bar against the same base` : "Each guard against warehouse spend"}>
          {!mon.rows ? <Note text={mon.note || "–"} /> : (
            <ShareBarList sort="none" valueFmt={fmt} n={3} items={[
              { key: "watched", name: "Under any monitor", value: share((w) => w.watched), total: whTotal },
              { key: "capped", name: "A monitor can suspend it", value: share((w) => w.capped), total: whTotal },
              { key: "own", name: "Warehouse's own monitor", value: share((w) => w.own), total: whTotal },
            ]} />
          )}
          <div className="sx-foot">{custom > 0 ? `Serverless $ under a budget: – ${fmtInt(custom)} custom budgets exist; their scope is readable only with CALL.` : acctB.length ? `Serverless $ under a budget: none of ${serverlessText}.` : `Budgets: ${bud.note || "–"}`}</div>
        </PatternCard>
      </div>

      <div className="cj-charts-2">
        <div id="cb-nocap">
          <PatternCard title="Warehouses with no resource monitor cap, by spend" sub={whList.length ? `${fmtInt(noCap.length)} of ${fmtInt(whList.length)} warehouses · ${fmt(noCapV)} in ${rangeOf(p)}` : "By spend"}>
            {!mon.rows ? <Note text={mon.note || "–"} /> : (
              <DrillTable aria="Warehouses with no resource monitor cap" n={9} empty="Every warehouse has a monitor that can suspend it."
                cols={[{ label: "Warehouse" }, { label: "", width: "minmax(60px, 1fr)" }, { label: "Spend", num: true, width: "auto" }, { label: "Monitor", width: "minmax(70px, auto)" }]}
                rows={noCap.map((w) => ({ key: `${w.id ?? w.name}`, status: w.status,
                  onOpen: openDrawer("sf_cost_resource_monitor_coverage", w.id != null ? "warehouse_id" : "warehouse_name", w.id ?? w.name, w.name),
                  cells: [<NameId key="n" name={w.name} id={w.id} />, <MiniBar key="b" value={w.v} max={noCap[0] ? noCap[0].v : 1} />, fmt(w.v), w.watched ? "notify only" : "none"] }))} />
            )}
          </PatternCard>
        </div>
        <div id="cb-params">
          <PatternCard title="Account parameters that guard cost" sub={params.length ? `${fmtInt(costly.length)} of ${fmtInt(params.length)} at a default that lets spend run · snapshot` : "Snapshot"}>
            {!par.rows ? <Note text={par.note || "–"} /> : !costly.length ? <Note text={`All ${fmtInt(params.length)} readable parameters are at expected values.`} /> : (
              <div className="sx-defs">
                {costly.map((r) => (
                  <button type="button" key={String(r.parameter)} className="sx-kv blk-row-btn" onClick={openDrawer("sf_acct_parameters_posture", "parameter", r.parameter, String(r.parameter))}>
                    <span className="sx-kv-name"><b>{String(r.parameter)}</b>{` ${String(r.level || "").toLowerCase()} · ${r.value == null || r.value === "" ? "unset" : r.value}`}</span>
                    <span className={`dt-chip tone-${r.status === "CRITICAL" ? "crit" : "warn"}`}>{r.status === "CRITICAL" ? "Critical" : "Warning"}</span>
                    <span className="sx-kv-val" title={r.verdict || undefined}>{r.recommended ? `set ${r.recommended}` : ""}</span>
                  </button>
                ))}
              </div>
            )}
          </PatternCard>
        </div>
      </div>
    </div>
  );
}
(ApCostBudgets as any).ownsTiles = true;
(ApCostBudgets as any).ownsLede = true;
