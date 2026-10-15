// web/src/tabs/tab_money.tsx -- the CFO's Money page: six money tiles (spend, forecast, possible
// waste, no cost center, contract, billed vs metered), what moved spend, the calendar months, the
// cost-center split, four figures to forward and the contract runway drawer. Also the spend-change
// helpers the other overviews share.
//
// Dollars are credits times the effective $ per credit. Spend, change and possible waste are shown
// side by side and never added. A figure that could not be computed reads "–" and why.
import React from "react";
import { acctId } from "../api";
import { fmtDate, fmtDayShort, fmtInt, fmtMoney, fmtMoneyOf, fmtMoneyShort, fmtPct } from "../format";
import { resolveName, useNames } from "../components/names";
import { IgnoredFilterTracker, buildMonthBars, fmtChangePct, groupSum, aggTotal, numOrZero, useFindingAgg, useFindingData } from "../components/hooks";
import { COST_MONEY_COL } from "../components/tab_registry";
import { Card, FilterReachNote, FreshnessLine, KindChip, PageFooter, PageIntro, PatternCard, StatusPill, noDataText, pageEyebrow, printWholePage } from "../components/primitives";
import { ChartNote } from "../components/charts";
import { reconciliationLine, rollupNote, useCostCenterAllocation } from "../components/tag_rollup";
import { RankedBars } from "../components/charts_more";
import { IssueTile, ReconciliationStrip, ShareBar, fmtShare, pctOf } from "../components/blocks";
import { StatStrip } from "../components/blocks_2";
import { NO_PRICE_LEDE, NO_PRICE_READING, isUnpricedAgg, notAssessedText } from "../components/scope";
import { windowShortLabel } from "../components/overview_tile";
import { buildWasteWorklist, wasteTotal } from "../components/waste_total";
import { MoneyPrintHeader } from "../components/print_summary";
import { ChecksRanStrip, OV_TOTAL_CREDITS, pickNum, priceBasisText, sumPick } from "./tab_overview";
import { forecastFigures, serviceOf, serviceWords } from "./tab_cost";
import { withoutTotalRows } from "./tab_area";
import type { FetchState, Filters, Finding, GoToFn, Meta, Row } from "../types";

export function moneyAcctName(id: unknown): string {
  if (id === null || id === undefined || id === "") return "Account-level (no account id)";
  return resolveName("account", id, id) || `account ${id}`;
}

// Spend movers: the services that moved the most between the previous and the current period, as a
// waterfall. Grouped by service; "others" is the remainder, so it closes the exact gap.
export function buildSpendMovers(rows: Row[] | null | undefined, discountPct: unknown) {
  const judged = withoutTotalRows(rows).filter((r) => r.status !== "NOT_ASSESSED");
  if (!judged.length) return null;
  const disc = numOrZero(discountPct);
  const bySvc = new Map<string, { id: string; cur: number; prev: number }>();
  judged.forEach((r) => {
    const key = serviceOf(r) || "__none__";
    if (!bySvc.has(key)) bySvc.set(key, { id: key, cur: 0, prev: 0 });
    const g = bySvc.get(key)!;
    g.cur += numOrZero(r.est_current_usd_list) * (1 - disc);
    g.prev += numOrZero(r.est_previous_usd_list) * (1 - disc);
  });
  const groups = Array.from(bySvc.values()).map((g) => ({ ...g, delta: g.cur - g.prev }));
  const totalPrev = groups.reduce((s, g) => s + g.prev, 0);
  const totalCur = groups.reduce((s, g) => s + g.cur, 0);
  const totalDelta = totalCur - totalPrev;
  const ranked = [...groups].sort((a, b) => Math.abs(b.delta) - Math.abs(a.delta));
  const top = ranked.slice(0, 5);
  // The remainder, not a second sum: "N others" always closes the exact gap to `current`.
  const othersDelta = totalDelta - top.reduce((s, g) => s + g.delta, 0);
  return { totalPrev, totalCur, totalDelta, top, othersDelta, othersCount: ranked.length - top.length };
}

// Floating-bar rows: each delta bar starts where the running total left off; the two totals are
// full bars from zero. `svc` is the service a delta row can be opened on.
export type SpendMovers = NonNullable<ReturnType<typeof buildSpendMovers>>;
export interface WaterfallRow { kind: string; label: string; start: number; end: number; value: number; svc?: string | null }

export function spendMoverRows(movers: SpendMovers, windowDays: number | string, todayPartial = false): WaterfallRow[] {
  const rows: WaterfallRow[] = [{ kind: "total", label: `Previous ${windowDays} days`, start: 0, end: movers.totalPrev, value: movers.totalPrev }];
  let running = movers.totalPrev;
  movers.top.forEach((g) => {
    const start = running;
    running += g.delta;
    rows.push({
      kind: g.delta >= 0 ? "up" : "down",
      label: serviceWords(g.id === "__none__" ? null : g.id) + (g.prev < 1 && g.cur >= 1 ? " · new" : ""),
      start, end: running, value: g.delta, svc: g.id,
    });
  });
  if (movers.othersCount > 0) {
    const start = running;
    running += movers.othersDelta;
    rows.push({ kind: movers.othersDelta >= 0 ? "up" : "down", label: `${fmtInt(movers.othersCount)} others`, start, end: running, value: movers.othersDelta });
  }
  rows.push({ kind: "total", label: `Last ${windowDays} days${todayPartial ? " · today partial" : ""}`, start: 0, end: movers.totalCur, value: movers.totalCur });
  return rows;
}

type MonthBar = ReturnType<typeof buildMonthBars>[number];

const isWarehouseService = (svc: string | null | undefined) => /WAREHOUSE/i.test(String(svc || ""));

// The top 3 behind one service's change: warehouses for warehouse metering, else accounts.
export function MoverDetail({ svc, periodRows, discountPct, filters }: { svc: string; periodRows: Row[]; discountPct: unknown; filters: Filters }) {
  useNames();
  const wh = isWarehouseService(svc);
  const whState = useFindingData(wh ? "cost_chargeback_by_warehouse" : null, filters.window, filters.accountIds, 5000);
  let items: { name: string; value: number }[] | null = null;
  let note: React.ReactNode = null;
  if (wh) {
    if (whState.phase !== "ready") return <div className="money-mover-detail muted">…</div>;
    if (whState.outcome !== "ok_rows") return <div className="money-mover-detail"><ChartNote state={whState} label="cost_chargeback_by_warehouse" /></div>;
    const net = 1 - numOrZero(whState.data!.discount_pct);
    const priced = whState.data!.rows.filter((r: Row) => r.status !== "NOT_ASSESSED" && r.change_usd_list != null);
    // Warehouse ids are unique only within an account, and each account has its own pooled row.
    const whAccts = new Set(priced.map((r: Row) => String(acctId(r)))).size > 1;
    items = groupSum(priced.map((r: Row) => {
      const base = r.is_other ? "Other warehouses" : `${resolveName("warehouse", acctId(r), r.warehouse_id) || r.warehouse_id} (${r.warehouse_id})`;
      return { name: whAccts ? `${base} · ${moneyAcctName(acctId(r))}` : base, v: numOrZero(r.change_usd_list) * net };
    }), (r) => r.name, "v");
  } else {
    const net = 1 - numOrZero(discountPct);
    // An unpriced change is unknown, not $0: leave it out.
    const rows = withoutTotalRows(periodRows).filter((r) => r.status !== "NOT_ASSESSED" && r.est_change_usd_list != null && (serviceOf(r) || "__none__") === svc);
    items = groupSum(rows.map((r) => ({ name: moneyAcctName(acctId(r)), v: numOrZero(r.est_change_usd_list) * net })), (r) => r.name, "v");
    if (items.length <= 1) note = "One account: this export has no finer split for this service.";
  }
  const top = [...(items || [])].sort((a, b) => Math.abs(b.value) - Math.abs(a.value)).slice(0, 3);
  if (!note && !top.length) note = `– No priced ${wh ? "warehouse" : "account"} change behind this service in this window.`;
  return (
    <div className="money-mover-detail">
      {note && <div className="faint">{note}</div>}
      {!note && top.map((it) => (
        <div key={it.name} className="money-mover-detail-row">
          <span className="money-mover-detail-name" title={it.name}>{it.name}</span>
          <span className={`mono tone-${it.value >= 0 ? "up" : "down"}`}>{`${it.value >= 0 ? "+" : "-"}${fmtMoney(Math.abs(it.value), 0)}`}</span>
        </div>
      ))}
    </div>
  );
}

export function MoneyWaterfall({ rows, renderDetail, canOpen: canOpenSvc }: { rows: WaterfallRow[]; renderDetail?: ((svc: string) => React.ReactNode) | null; canOpen?: (svc: string) => boolean }) {
  const [open, setOpen] = React.useState<string | null>(null);
  const domainMin = Math.min(0, ...rows.map((r) => Math.min(r.start, r.end)));
  const domainMax = Math.max(0, ...rows.map((r) => Math.max(r.start, r.end)));
  const span = domainMax - domainMin || 1;
  const pct = (v: number) => ((v - domainMin) / span) * 100;
  return (
    <div className="money-waterfall">
      {rows.map((r, i) => {
        const left = pct(Math.min(r.start, r.end));
        const w = Math.max(pct(Math.max(r.start, r.end)) - left, 0);
        const sign = r.kind !== "total" && r.value >= 0 ? "+" : "";
        const canOpen = !!(renderDetail && r.svc && (!canOpenSvc || canOpenSvc(r.svc)));
        const isOpen = canOpen && open === r.svc;
        const body = (
          <>
            <div className="money-waterfall-label" title={r.label}>{canOpen ? `${isOpen ? "▾" : "▸"} ` : ""}{r.label}</div>
            <div className="money-waterfall-track">
              <div className={`money-waterfall-bar tone-${r.kind}`} style={{ left: `${left}%`, width: `${w}%` }} />
            </div>
            <div className="money-waterfall-value mono">{`${sign}${fmtMoney(r.value, 0)}`}</div>
          </>
        );
        return (
          <React.Fragment key={i}>
            {canOpen
              ? <button type="button" className="money-waterfall-row money-waterfall-btn" aria-expanded={isOpen} onClick={() => setOpen(isOpen ? null : r.svc!)}>{body}</button>
              : <div className={`money-waterfall-row${r.kind === "total" ? " is-total" : ""}`}>{body}</div>}
            {isOpen && renderDetail!(r.svc!)}
          </React.Fragment>
        );
      })}
    </div>
  );
}

export interface SpendMoversCardProps {
  periodState: FetchState;
  filters?: Filters;
  title?: React.ReactNode;
  sub?: React.ReactNode;
  link?: string | null;
  onLink?: (() => void) | null;
  meta?: Meta | null;
}

// One card for Money and the Overview: same check, same cut-off, so the change agrees on both.
export function SpendMoversCard({ periodState, filters, title, sub, link, onLink, meta }: SpendMoversCardProps) {
  const shell = (body: React.ReactNode) => (
    <PatternCard title={title || "What moved spend"} sub={sub} link={link} onLink={onLink}>{body}</PatternCard>
  );
  const ready = periodState.phase === "ready" && periodState.outcome === "ok_rows";
  if (!ready) return shell(<ChartNote state={periodState} label="cost_period_over_period" />);
  const all: Row[] = periodState.data!.rows || [];
  const movers = buildSpendMovers(all, periodState.data!.discount_pct);
  const judged = withoutTotalRows(all).filter((r) => r.status !== "NOT_ASSESSED");
  // No price on either side means no $ to compare: say so, never draw $0 bars.
  const unpriced = judged.length > 0 && judged.every((r) => r.est_current_usd_list == null && r.est_previous_usd_list == null);
  if (!movers || unpriced || movers.totalPrev <= 0) {
    const noPrev = all.some((r: Row) => r.not_assessed_reason === "previous_window_not_covered");
    // The check marks a row with no credit price NOT_ASSESSED 'unpriced'; all of them means no price at all.
    const noPrice = all.length > 0 && withoutTotalRows(all).every((r: Row) => r.not_assessed_reason === "unpriced" || r.price_basis === "unpriced");
    const note = !movers ? (noPrev ? "– No previous period to compare in this window." : noPrice ? `– ${NO_PRICE_READING}` : "– Spend in one of the two periods has no price, so the change can't be worked out.")
      : unpriced ? `– ${NO_PRICE_READING}`
      : "– No priced spend in the previous period to compare against.";
    return shell(<div className="chart-note-oneline">{note}</div>);
  }
  const rows = spendMoverRows(movers, periodState.data!.window_days, !!(meta && meta.cost_cutoff && meta.cost_cutoff.partial_day));
  // Services with no price are left out of both totals: say how many, so the totals don't read as whole.
  const svcAll = new Set(withoutTotalRows(all).map((r: Row) => serviceOf(r) || "__none__"));
  const svcUnpriced = new Set(withoutTotalRows(all).filter((r: Row) => r.not_assessed_reason === "unpriced").map((r: Row) => serviceOf(r) || "__none__"));
  const unpricedNote = svcUnpriced.size
    ? `${fmtInt(svcUnpriced.size)} of ${fmtInt(svcAll.size)} services have no price and are left out.` : null;
  const topDelta = movers.top.reduce((s, g) => s + g.delta, 0);
  // Only a real share: some services left out, the top ones moving the same way as the total, and
  // at least $1 of net change.
  const share = movers.othersCount > 0 && Math.abs(movers.totalDelta) >= 1 ? topDelta / movers.totalDelta : null;
  const sentence = share != null && share > 0 && share <= 1
    ? `${fmtInt(movers.top.length)} service${movers.top.length === 1 ? "" : "s"} explain${movers.top.length === 1 ? "s" : ""} `
      + `${fmtPct(share * 100, 0)} of the ${fmtMoneyShort(Math.abs(movers.totalDelta))} ${movers.totalDelta >= 0 ? "increase" : "decrease"}.`
    : null;
  const renderDetail = filters
    ? (svc: string) => <MoverDetail svc={svc} periodRows={all} discountPct={periodState.data!.discount_pct} filters={filters} />
    : null;
  // A service opens on its warehouses (warehouse metering) or, with several accounts, its accounts.
  const multiAcct = new Set(all.map((r: Row) => String(acctId(r)))).size > 1;
  const canOpen = (svc: string) => multiAcct || isWarehouseService(svc);
  const anyOpen = !!renderDetail && rows.some((r) => r.svc && canOpen(r.svc));
  const note = [sentence, unpricedNote, anyOpen ? "Open a row for the top 3 behind it." : null].filter(Boolean).join(" ");
  return shell(
    <div className="money-movers-body">
      {note && <div className="money-mover-note">{note}</div>}
      <MoneyWaterfall rows={rows} renderDetail={renderDetail} canOpen={canOpen} />
      <div className="pc-foot">{`${fmtMoney(movers.totalPrev, 0)} → ${fmtMoney(movers.totalCur, 0)} · change is shown on its own, never added to waste or saving`}</div>
    </div>,
  );
}

// Calendar months with their $ on top and the change vs the month before under the name; the month
// in progress is its spend so far, with a hollow bar up to the month-end forecast.
export function MoneyMonthBars({ months, projected }: { months: MonthBar[]; projected?: number | null }) {
  const max = Math.max(1, ...months.map((m) => m.total), projected || 0);
  return (
    <div className="money-mbars" role="img" aria-label="Spend by calendar month">
      {months.map((m, i) => {
        const prev = i > 0 ? months[i - 1] : null;
        // A month whose history starts mid-month is not a base for a change.
        const chg = !m.partial && !m.startsMid && prev && !prev.partial && !prev.startsMid && prev.total > 0 ? ((m.total - prev.total) / prev.total) * 100 : null;
        const fc = m.partial && projected != null && projected > m.total ? projected : null;
        return (
          <div className="money-mbar-col" key={m.month} title={`${m.label}: ${fmtMoney(m.total, 0)}${m.partial ? ` so far${fc != null ? `, forecast ${fmtMoney(fc, 0)}` : ""}` : ""}`}>
            <div className="money-mbar-val mono">{m.partial ? `${fmtMoneyShort(m.total)} MTD` : fmtMoneyShort(m.total)}</div>
            <div className="money-mbar-track">
              {fc != null && <div className="money-mbar-forecast" style={{ height: `${(fc / max) * 100}%` }} />}
              <div className={`money-mbar-fill${m.partial ? " partial" : ""}`} style={{ height: `${Math.max(1, (m.total / max) * 100)}%` }} />
            </div>
            <div className="money-mbar-label">{m.shortLabel}</div>
            <div className={`money-mbar-chg mono${chg != null && chg >= 15 ? " tone-warn" : ""}`}>{chg != null ? fmtChangePct(chg) : m.partial ? "partial" : m.startsMid ? "from mid-month" : ""}</div>
          </div>
        );
      })}
    </div>
  );
}

// A ranked-bars card over one check's rows: `valueCol` summed by `nameOf(row)`. A check that did
// not run says so in the card's own slot.
export interface TopDriversCardProps {
  title: string;
  qid: string;
  valueCol: string;
  nameOf: (r: Row) => string;
  filters: Filters;
  n?: number;
  right?: React.ReactNode;
  meta: Meta | null;
}
export function TopDriversCard({ title, qid, valueCol, nameOf, filters, n, right, meta }: TopDriversCardProps) {
  const state = useFindingData(qid, filters.window, filters.accountIds, 5000);
  const rows = state.phase === "ready" && state.outcome === "ok_rows" ? state.data!.rows.filter((r: Row) => !r.is_other && r.status !== "NOT_ASSESSED") : null;
  const disc = state.data ? numOrZero(state.data.discount_pct) : 0;
  const items = rows ? groupSum(rows.map((r: Row) => ({ name: nameOf(r), v: numOrZero(r[valueCol]) * (1 - disc) })), (r) => r.name, "v").filter((it) => it.value > 0) : null;
  return (
    <Card title={title} right={right}>
      {items ? <RankedBars items={items} n={n} valueFmt={(v: number) => fmtMoney(v, 0)} unitLabel="$" ariaLabel={title} emptyText={noDataText(meta, filters.window)} />
        : <ChartNote state={state} label={qid} />}
    </Card>
  );
}

const STATUS_RANK: Record<string, number> = { CRITICAL: 0, WARN: 1, OK: 2 };

// The contract that needs a look first: worst status, then the nearest end date.
export function worstContract(rows: Row[] | null): Row | null {
  const judged = (rows || []).filter((r) => r.status !== "NOT_ASSESSED");
  if (!judged.length) return null;
  return [...judged].sort((a, b) => (STATUS_RANK[a.status] ?? 3) - (STATUS_RANK[b.status] ?? 3)
    || numOrZero(a.days_to_contract_end ?? 1e9) - numOrZero(b.days_to_contract_end ?? 1e9))[0];
}

// Day N of M of the month the money cut-off sits in, for the forecast tile's MTD bar.
export function monthProgress(meta: Meta | null): { day: number; days: number } | null {
  const ref = String((meta && meta.cost_cutoff && (meta.cost_cutoff.partial_day || meta.cost_cutoff.data_through)) || "").slice(0, 10);
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ref);
  if (!m) return null;
  const days = new Date(Date.UTC(Number(m[1]), Number(m[2]), 0)).getUTCDate();
  return { day: Number(m[3]), days };
}

export interface MoneyTabProps {
  filters: Filters;
  meta: Meta | null;
  findingsById: Record<string, Finding> | null;
  goTo: GoToFn;
  role: string | null;
}

// The month the money cut-off sits in, as a word ("September").
function cutoffMonthName(meta: Meta | null): string | null {
  const ref = String((meta && meta.cost_cutoff && (meta.cost_cutoff.partial_day || meta.cost_cutoff.data_through)) || "").slice(0, 10);
  const t = Date.parse(`${ref}T00:00:00Z`);
  return Number.isFinite(t) ? new Date(t).toLocaleDateString("en-US", { month: "long", timeZone: "UTC" }) : null;
}

function MoneyFig({ eyebrow, value, sub }: { eyebrow: string; value: React.ReactNode | null; sub?: React.ReactNode }) {
  const missing = value === null || value === undefined || value === "";
  return (
    <div className={`dr-fig${missing ? " is-missing" : ""}`}>
      <div className="dr-eyebrow">{eyebrow}</div>
      <div className="dr-fig-value">{missing ? "–" : value}</div>
      {sub && <div className="dr-fig-sub">{sub}</div>}
    </div>
  );
}

/** The worst contract's runway: balance, burn, days left, what is left unused; one box per figure. */
export function ContractDrawer({ contract, count, filters, goTo, onClose }: { contract: Row; count: number; filters: Filters; goTo: GoToFn; onClose: () => void }) {
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  const svcState = useFindingData("cost_chargeback_by_service", filters.window, filters.accountIds, 5000);
  const cur = { unit: "currency", currency: contract.currency };
  const money = (v: unknown) => (v == null || !Number.isFinite(Number(v)) ? null : fmtMoneyOf(cur, Number(v), 0));
  const endDays = pickNum(contract, ["days_to_contract_end"]);
  const runway = pickNum(contract, ["runway_days"]);
  const unused = pickNum(contract, ["projected_unused"]);
  const unusedPct = pickNum(contract, ["projected_unused_pct"]);
  const short = runway != null && endDays != null && runway < endDays;
  const status = contract.status === "CRITICAL" ? "critical" : contract.status === "WARN" ? "warn" : "ok";
  const svcRows = svcState.phase === "ready" && svcState.outcome === "ok_rows" ? svcState.data!.rows.filter((r: Row) => !r.is_other && r.status !== "NOT_ASSESSED") : null;
  const svcDisc = svcState.data ? numOrZero(svcState.data.discount_pct) : 0;
  const svcItems = svcRows ? groupSum(svcRows.map((r: Row) => ({ name: serviceOf(r) ? serviceWords(serviceOf(r)) : String(r.service_label || "Other"), v: numOrZero(r.usd_list) * (1 - svcDisc) })), (r) => r.name, "v")
    .filter((it) => it.value > 0).sort((a, b) => b.value - a.value) : null;
  const svcTotal = svcItems ? svcItems.reduce((s, it) => s + it.value, 0) : 0;
  return (
    <aside className="dr" aria-label="Contract balance runway">
      <div className="dr-head">
        <div className="dr-chips"><KindChip>Cost</KindChip><KindChip>Contract & rate</KindChip><StatusPill kind={status} /></div>
        <button type="button" className="dr-close" aria-label="Close" onClick={onClose}>×</button>
      </div>
      <h3 className="dr-title">{`Contract balance runway${count > 1 ? ` (1 of ${fmtInt(count)})` : ""}`}{contract.contract_number ? <span className="b2-id">{` (${contract.contract_number})`}</span> : null}</h3>
      <div className="dr-base">{[money(contract.prepaid_balance) ? `${money(contract.prepaid_balance)} balance` : null,
        contract.contract_end_date ? `ends ${fmtDate(String(contract.contract_end_date).slice(0, 10)) || contract.contract_end_date}` : null, "snapshot at export"].filter(Boolean).join(" · ")}</div>
      <div className="dr-figs">
        <MoneyFig eyebrow="Balance left" value={money(contract.prepaid_balance)} sub={contract.latest_date ? `as of ${fmtDayShort(contract.latest_date)}` : null} />
        <MoneyFig eyebrow="Burn per day" value={money(contract.daily_burn)} sub="average drawdown" />
        <MoneyFig eyebrow="Days left" value={endDays != null ? `${fmtInt(Math.round(endDays))} d` : null}
          sub={runway != null ? `balance lasts ${fmtInt(Math.round(runway))} d at this burn` : null} />
        {short
          ? <MoneyFig eyebrow="Runs out" value={contract.projected_depletion_date ? fmtDayShort(contract.projected_depletion_date) : null} sub={`${fmtInt(Math.round(endDays! - runway!))} d before the end date`} />
          : <MoneyFig eyebrow="Unused at the end" value={unused != null && unused > 0 ? money(unused) : null} sub={unusedPct != null && unusedPct > 0 ? `${fmtShare(unusedPct)} of the balance` : "nothing left unused"} />}
      </div>
      <div className="dr-section">
        <div className="dr-eyebrow">The fix</div>
        <pre className="dr-fix">{short
          ? "Renew before the balance runs out: size the next commitment on the current run-rate, and ask for overage at the contract rate until renewal."
          : unused != null && unused > 0 ? "Size the next commitment lower, or move planned usage in before the end date: the balance outlasts the term."
          : "Nothing to change now: the balance and the term end together."}</pre>
      </div>
      <div className="dr-section">
        <div className="dr-eyebrow">{`Where · the run-rate, top ${fmtInt(Math.min(5, svcItems ? svcItems.length : 0))} of ${fmtInt(svcItems ? svcItems.length : 0)} services`}</div>
        {svcItems ? (
          <div className="dr-where">
            {svcItems.slice(0, 5).map((it) => (
              <div key={it.name} className="dr-where-row">
                <span className="dr-where-name" title={it.name}>{it.name}</span>
                <span className="dr-where-val">{`${fmtShare(pctOf(it.value, svcTotal))} · ${fmtMoney(it.value, 0)}`}</span>
              </div>
            ))}
          </div>
        ) : <ChartNote state={svcState} label="cost_chargeback_by_service" />}
      </div>
      <div className="dr-links">
        <button type="button" className="dr-link" onClick={() => goTo({ tab: "cost", subtab: "contract" })}>{"Contract & rate →"}</button>
        <button type="button" className="dr-link" onClick={() => goTo({ tab: "guide", focusQueryId: "sf_cost_contract_balance_burn" })}>{"How the runway is worked out →"}</button>
      </div>
    </aside>
  );
}

export function MoneyTab({ filters, meta, findingsById, goTo, role }: MoneyTabProps) {
  useNames();
  // Money is not inside AreaPage, so it resets the ignored-filter note itself.
  React.useEffect(() => { IgnoredFilterTracker.reset(); }, []);
  const acct = filters.accountIds;
  const byId: Record<string, Finding> = findingsById || {};
  const findingsReady = Object.keys(byId).length > 0;
  const [contractOpen, setContractOpen] = React.useState(false);
  const closeContract = React.useCallback(() => setContractOpen(false), []);

  const dailyAgg = useFindingAgg("cost_dollarized_by_service_day", filters.window, acct, ["usage_date"], "sum", COST_MONEY_COL);
  const spendState = useFindingData("overview_spend_estimate", filters.window, acct, 500);
  const periodState = useFindingData("cost_period_over_period", filters.window, acct);
  const monthAgg = useFindingAgg("cost_monthly_actuals", filters.window, acct, ["month_start", "partial_reason"], "sum", "net_list_cost_usd");
  const forecastState = useFindingData("sf_cost_month_end_forecast", filters.window, acct);
  const contractState = useFindingData("sf_cost_contract_balance_burn", filters.window, acct);
  const invoiceState = useFindingData("sf_cost_invoice_vs_metered", filters.window, acct);
  const ccAlloc = useCostCenterAllocation(filters);

  const worklist = React.useMemo(() => buildWasteWorklist(byId), [findingsById]); // eslint-disable-line react-hooks/exhaustive-deps
  const wt = React.useMemo(() => wasteTotal(worklist), [worklist]);

  // Spend: one source and one cut-off for every figure on the page.
  const dailyReady = dailyAgg.phase === "ready" && dailyAgg.outcome === "ok_rows";
  const spend = dailyReady ? aggTotal(dailyAgg.data) : null;
  const credits = spendState.phase === "ready" && spendState.outcome === "ok_rows" ? sumPick(spendState.data!.rows, OV_TOTAL_CREDITS) : null;
  const movers = periodState.phase === "ready" && periodState.outcome === "ok_rows" ? buildSpendMovers(periodState.data!.rows, periodState.data!.discount_pct) : null;
  const delta = movers && movers.totalPrev > 0 ? movers.totalDelta : null;
  const deltaPct = movers && movers.totalPrev > 0 ? (movers.totalDelta / movers.totalPrev) * 100 : null;
  const signedMoney = (v: number) => `${v >= 0 ? "+" : "−"}${fmtMoney(Math.abs(v), 0)}`;
  const range = windowShortLabel(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days);

  const monthReady = monthAgg.phase === "ready" && monthAgg.outcome === "ok_rows";
  const months = monthReady ? buildMonthBars(monthAgg.data!.groups, monthAgg.data!.discount_pct, 13) : null;
  const fRows = forecastState.phase === "ready" && forecastState.outcome === "ok_rows" ? forecastState.data!.rows : null;
  const fc = fRows ? forecastFigures(fRows, forecastState.data && forecastState.data.discount_pct) : null;
  const projected = fc ? fc.projected : null;
  const mtd = fc ? fc.monthToDate : null;
  const prog = monthProgress(meta);
  const monthName = cutoffMonthName(meta);

  // Contract: the worst contract's end date and runway.
  const cRows = contractState.phase === "ready" && contractState.outcome === "ok_rows" ? contractState.data!.rows : null;
  const contract = worstContract(cRows);
  const cCount = cRows ? cRows.filter((r: Row) => r.status !== "NOT_ASSESSED").length : 0;
  const endDays = contract ? pickNum(contract, ["days_to_contract_end"]) : null;
  const runway = contract ? pickNum(contract, ["runway_days"]) : null;
  const unusedPct = contract ? pickNum(contract, ["projected_unused_pct"]) : null;
  const balance = contract ? pickNum(contract, ["prepaid_balance"]) : null;
  const curMoney = { unit: "currency", currency: contract ? contract.currency : null };
  const contractSev = contract ? (contract.status === "CRITICAL" ? "critical" : contract.status === "WARN" ? "warn" : "ok") : "neutral";

  // Invoice: billed vs metered credits (the ALL CREDITS row) and the usage type furthest off the rate.
  const iRows = invoiceState.phase === "ready" && invoiceState.outcome === "ok_rows" ? invoiceState.data!.rows.filter((r: Row) => r.status !== "NOT_ASSESSED") : null;
  const allRow = iRows ? iRows.find((r: Row) => r.is_total_row || r.usage_type === "ALL CREDITS") : null;
  const creditGap = allRow ? pickNum(allRow, ["credit_gap_pct"]) : null;
  const rateRows = iRows ? iRows.filter((r: Row) => !(r.is_total_row || r.usage_type === "ALL CREDITS") && pickNum(r, ["rate_gap_pct"]) != null) : [];
  const premium = rateRows.length ? [...rateRows].sort((a, b) => Math.abs(numOrZero(b.rate_gap_pct)) - Math.abs(numOrZero(a.rate_gap_pct)))[0] : null;
  const premiumGap = premium ? numOrZero(premium.rate_gap_pct) : null;
  const signed = (v: number) => `${v >= 0 ? "+" : "−"}${fmtPct(Math.abs(v), 1)}`;

  // Cost-center split (the rollup's by_value): tagged spend by value, untagged as its own hatched part.
  const ccRows = ccAlloc.phase === "ready" && ccAlloc.outcome === "ok_rows" ? (ccAlloc.data!.by_value || []) : null;
  const ccItems = ccRows ? ccRows.map((e: Row) => {
    const untagged = e.value === "__untagged__";
    return { name: untagged ? "No cost center" : e.label, value: numOrZero(e.metrics.usd), untagged };
  }).filter((it: { value: number }) => it.value > 0) : null;
  const ccTagged = ccItems ? ccItems.filter((it: { untagged: boolean }) => !it.untagged).reduce((s: number, it: { value: number }) => s + it.value, 0) : 0;
  const ccTotal = ccItems ? ccItems.reduce((s: number, it: { value: number }) => s + it.value, 0) : 0;
  const ccUntagged = ccTotal - ccTagged;
  const ccValues = ccItems ? ccItems.filter((it: { untagged: boolean }) => !it.untagged).length : 0;
  const untaggedPct = ccItems && ccTotal > 0 ? pctOf(ccUntagged, ccTotal) : null;
  const recon = ccAlloc.data && ccAlloc.data.reconciliation ? ccAlloc.data.reconciliation : null;
  const reconTie = reconciliationLine(recon);
  const tagAff = byId.sf_chg_tag_coverage && byId.sf_chg_tag_coverage.affected;

  const wasteUsd = wt.waste.usd;
  const wastePct = wasteUsd != null ? pctOf(wasteUsd, spend) : null;
  const priceText = priceBasisText(meta);

  const settled = dailyAgg.phase !== "loading" && periodState.phase !== "loading" && forecastState.phase !== "loading" && contractState.phase !== "loading";
  const lede = !settled ? "…" : spend == null ? (isUnpricedAgg(dailyAgg.data) ? NO_PRICE_LEDE : "Spend could not be assessed for this export.")
    : [fmtMoney(spend, 0), deltaPct != null ? `${fmtChangePct(deltaPct)} vs previous ${filters.window} d` : null,
      projected != null ? `forecast ${fmtMoney(projected, 0)}` : null,
      endDays != null && endDays >= 0 ? `contract ends in ${fmtInt(Math.round(endDays))} d` : null].filter(Boolean).join(" · ");

  const printLines = [
    spend != null ? `Spend ${fmtMoney(spend, 0)} over ${filters.window} days${deltaPct != null ? `, ${fmtChangePct(deltaPct)} vs the previous period` : ""}.` : null,
    wasteUsd != null ? `Possible waste ${fmtMoney(wasteUsd, 0)}${wastePct != null ? ` (${fmtShare(wastePct)} of spend)` : ""}; never added to spend.` : null,
    projected != null ? `Month-end forecast ${fmtMoney(projected, 0)}.` : null,
    untaggedPct != null ? `${fmtShare(untaggedPct)} of spend has no cost center (${fmtMoney(ccUntagged, 0)}).` : null,
  ];
  const showContract = contractOpen && !!contract;

  return (
    <div>
      <MoneyPrintHeader meta={meta} filters={filters} lines={printLines} priceText={priceText && priceText !== "…" ? priceText : null} />
      <PageIntro overline={pageEyebrow(role, "Money", meta, filters.window)} title="Money" verdict={lede} />
      <FreshnessLine findingsById={byId} goTo={goTo} />

      <div className="summary-tile-row cto-tiles ln-tiles-3">
        <IssueTile label="Spend" loading={dailyAgg.phase === "loading"} pill={<KindChip>Context</KindChip>}
          headline={spend != null ? fmtMoney(spend, 0) : null} unit={`last ${filters.window} days`} missingReason={notAssessedText(dailyAgg.data)}
          base={[credits != null ? `${fmtInt(Math.round(credits))} credits` : null,
            delta != null && deltaPct != null ? `${signedMoney(delta)} (${fmtChangePct(deltaPct)}) vs previous ${filters.window} d` : null].filter(Boolean).join(" · ") || null}
          cause={priceText && priceText !== "…" ? priceText : null} onOpen={() => goTo({ tab: "cost" })} openLabel="Cost →" />
        <IssueTile label="Month-end forecast" loading={forecastState.phase === "loading"} pill={<KindChip>Context · partial</KindChip>}
          headline={projected != null ? fmtMoney(projected, 0) : null} unit={monthName ? `if ${monthName} keeps its run-rate` : "at this run-rate"}
          missingReason={notAssessedText(forecastState.data)}
          chart={projected != null && mtd != null ? <ShareBar value={mtd} total={projected} valueFmt={(v) => fmtMoney(v, 0)} /> : null}
          base={[mtd != null ? `${fmtMoney(mtd, 0)} so far` : null, prog ? `day ${prog.day} of ${prog.days} · ${fmtShare((100 * prog.day) / prog.days)} through` : null].filter(Boolean).join(" · ") || null}
          cause="Partial month: run-rate × days left, not a bill." onOpen={() => goTo({ tab: "cost", subtab: "trend" })} openLabel="Cost › Trend →" />
        <IssueTile label="Possible waste" loading={!findingsReady || dailyAgg.phase === "loading"}
          status={wasteUsd == null ? "not_assessed" : wt.waste.flagged > 0 ? "warn" : "ok"}
          headline={wastePct != null ? fmtShare(wastePct) : (wasteUsd != null ? fmtMoney(wasteUsd, 0) : null)} unit={wastePct != null ? "of spend is possible waste" : undefined}
          missingReason="none of the waste checks ran"
          base={wasteUsd != null ? `${fmtMoney(wasteUsd, 0)}${spend != null ? ` of ${fmtMoney(spend, 0)}` : ""} · ${fmtInt(wt.waste.flagged)} of ${fmtInt(wt.waste.ran)} checks flagged` : null}
          cause="Not added to spend: it is part of it." onOpen={() => goTo({ tab: "waste" })} openLabel="Waste & savings →" />
        <IssueTile label="No cost center" loading={ccAlloc.phase === "loading"} status={untaggedPct != null && untaggedPct > 20 ? "warn" : "neutral"}
          headline={untaggedPct != null ? fmtShare(untaggedPct) : null} unit="of the split has no cost center"
          missingReason={ccAlloc.data ? (rollupNote(ccAlloc.data, "cost") || "no cost-center split for this window") : "cost-center rollup not in this export"}
          base={untaggedPct != null ? [`${fmtMoney(ccUntagged, 0)} of ${fmtMoney(ccTotal, 0)}`, tagAff ? `${fmtInt(tagAff.flagged)} of ${fmtInt(tagAff.total)} ${tagAff.noun} untagged` : null].filter(Boolean).join(" · ") : null}
          cause={untaggedPct != null && ccValues > 0 ? `${fmtInt(ccValues)} cost center${ccValues === 1 ? "" : "s"} carry ${fmtShare(pctOf(ccTagged, ccTotal))} (${fmtMoney(ccTagged, 0)}).` : null}
          onOpen={() => goTo({ tab: "cost", subtab: "chargeback" })} openLabel="Chargeback & tags →" />
        <IssueTile label="Contract" loading={contractState.phase === "loading"} status={contract ? contractSev : "neutral"}
          headline={contract ? (endDays != null ? (endDays < 0 ? "Ended" : `${fmtInt(Math.round(endDays))} d`) : runway != null ? `${fmtInt(Math.round(runway))} d` : null) : null}
          unit={endDays != null ? (endDays < 0 ? undefined : "until the contract ends") : "of balance at this burn"}
          missingReason={notAssessedText(contractState.data)}
          base={contract ? [balance != null ? `${fmtMoneyOf(curMoney, balance, 0)} balance left` : null, cCount > 1 ? `worst of ${fmtInt(cCount)} contracts` : `${fmtInt(cCount)} of ${fmtInt(cCount)} contracts`].filter(Boolean).join(" · ") : null}
          cause={contract ? (runway != null && endDays != null && runway < endDays
            ? `At ${fmtMoneyOf(curMoney, numOrZero(contract.daily_burn), 0)} a day the balance runs out${contract.projected_depletion_date ? ` ${fmtDayShort(contract.projected_depletion_date)}` : ""}, ${fmtInt(Math.round(endDays - runway))} d before the end date.`
            : unusedPct != null && unusedPct > 0 ? `${fmtShare(unusedPct)} of the balance unused at the end date.` : null) : null}
          onOpen={contract ? () => setContractOpen(true) : () => goTo({ tab: "cost", subtab: "contract" })} openLabel={contract ? "Open →" : "Contract & rate →"} />
        <IssueTile label="Billed vs metered" loading={invoiceState.phase === "loading"} pill={<KindChip>Context</KindChip>}
          headline={creditGap != null ? signed(creditGap) : null} unit="invoice vs usage views" missingReason={notAssessedText(invoiceState.data)}
          base={premium && premiumGap != null && Math.abs(premiumGap) >= 5 ? `${premium.usage_type} rate ${signed(premiumGap)} vs the audit's $/credit` : null}
          cause="The last days are left out: org billing lags." onOpen={() => goTo({ tab: "cost", subtab: "contract" })} openLabel="Contract & rate →" />
      </div>

      <div className="cj-charts-2">
        <SpendMoversCard periodState={periodState} filters={filters} meta={meta} title={delta != null ? `What moved spend ${signedMoney(delta)}` : "What moved spend"}
          sub={`Change vs the previous ${filters.window} days, by service`} link="Cost › Trend →" onLink={() => goTo({ tab: "cost", subtab: "trend" })} />
        <PatternCard title="By calendar month" sub="Last 12 billed months and this month · this month to date, then the forecast to month end">
          {months && months.length ? <MoneyMonthBars months={months} projected={projected} /> : <ChartNote state={monthAgg} label="cost_monthly_actuals" />}
        </PatternCard>
      </div>

      <div className={`dr-layout${showContract ? " open" : ""}`}>
        <div className="dr-main">
          <PatternCard title="By cost center" sub={ccItems ? `The ${fmtMoney(ccTotal, 0)} split, by cost_center tag · the untagged rest is hatched` : "The billed split, by cost center"}
            link="Chargeback & tags →" onLink={() => goTo({ tab: "cost", subtab: "chargeback" })}>
            {ccItems ? (ccTagged > 0
              ? <React.Fragment>
                <RankedBars items={ccItems} n={8} valueFmt={(v: number) => fmtMoney(v, 0)} unitLabel="$" ariaLabel="Spend by cost center" />
                {recon && recon.spend_usd != null && (
                  <div className="money-recon">
                    <ReconciliationStrip steps={[
                      { key: "spend", label: "Metered (usage views)", value: recon.spend_usd },
                      { key: "billed", label: "Billed to split", value: recon.billing_usd,
                        note: numOrZero(recon.outside_split_usd) > 0 ? `storage & transfer ${fmtMoney(recon.outside_split_usd, 0)} outside the split` : null },
                      { key: "split", label: "Split by cost center", value: recon.rollup_usd },
                    ]} />
                  </div>
                )}
                {reconTie && reconTie.tone !== "ok" && <div className="chart-note-oneline">{reconTie.text}</div>}
                {ccAlloc.data && ccAlloc.data.cut_sources && ccAlloc.data.cut_sources.length > 0 && (
                  <div className="chart-note-oneline">{`The export cut ${ccAlloc.data.cut_sources.join(", ")} at its row limit, so tagged spend can read low.`}</div>
                )}
              </React.Fragment>
              : <div className="chart-note-oneline">{ccTotal > 0 ? `None of the ${fmtMoney(ccTotal, 0)} carries a cost-center tag.` : noDataText(meta, filters.window)}</div>)
              : ccAlloc.phase === "loading" ? <div className="chart-note-oneline">…</div>
              : <div className="chart-note-oneline">{ccAlloc.data ? (rollupNote(ccAlloc.data, "cost") || "–") : "– the cost-center rollup is not in this export"}</div>}
          </PatternCard>

          {filters.accountIdSet && filters.accountIdSet.size > 1 && (
            <TopDriversCard title="By account" qid="cost_chargeback_by_account" valueCol="usd_list" n={8}
              nameOf={(r: Row) => moneyAcctName(acctId(r))} filters={filters} meta={meta} />
          )}

          <div className="card pc-card ln-forward">
            <div className="pc-head ln-forward-head">
              <div className="pc-titles">
                <div className="pc-title">Something to forward</div>
                <div className="pc-sub">Four figures, kinds apart · the PDF carries this page</div>
              </div>
              <button type="button" className="ln-btn" onClick={printWholePage}>Save as PDF</button>
            </div>
            <StatStrip ariaLabel="Four figures to forward" cells={[
              { key: "spend", label: "Spend · context", value: spend != null ? fmtMoney(spend, 0) : null, unit: ` ${filters.window} d`,
                base: [credits != null ? `${fmtInt(Math.round(credits))} credits` : null, range].filter(Boolean).join(" · ") || null, missing: notAssessedText(dailyAgg.data) },
              { key: "change", label: `Change · vs previous ${filters.window} d`, value: deltaPct != null ? fmtChangePct(deltaPct) : null,
                base: delta != null ? signedMoney(delta) : null, missing: "no previous period to compare" },
              { key: "forecast", label: "Forecast · partial", value: projected != null ? fmtMoney(projected, 0) : null, unit: " month end",
                base: [mtd != null ? `${fmtMoney(mtd, 0)} so far` : null, prog ? `day ${prog.day} of ${prog.days}` : null].filter(Boolean).join(" · ") || null, missing: notAssessedText(forecastState.data) },
              { key: "waste", label: "Possible waste", pill: wasteUsd != null && wt.waste.flagged > 0 ? "warn" : null,
                value: wastePct != null ? fmtShare(wastePct) : (wasteUsd != null ? fmtMoney(wasteUsd, 0) : null),
                base: wasteUsd != null ? `${fmtMoney(wasteUsd, 0)} · not added to spend · ${fmtInt(wt.waste.flagged)} of ${fmtInt(wt.waste.ran)} checks` : null, missing: "none of the waste checks ran" },
            ]} />
          </div>
        </div>
        {showContract && <ContractDrawer contract={contract!} count={cCount} filters={filters} goTo={goTo} onClose={closeContract} />}
      </div>

      <FilterReachNote />
      <ChecksRanStrip meta={meta} byId={byId} goTo={goTo} />
      <PageFooter meta={meta} />
    </div>
  );
}

export function whLabel(id: unknown): string {
  return `${resolveName("warehouse", null, id) || id} (${id})`;
}
