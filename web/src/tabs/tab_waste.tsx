// web/src/tabs/tab_waste.tsx -- Waste & savings: a roll-up with no checks table of its own.
// Every WASTE_ITEMS id is homed on another area's sub-tab (tab_registry.tsx), so the figures here
// are views of those checks, read through waste_total.tsx: the same $ as the area pages, Overview
// and Actions. Three sub-tabs: Priced (a Pareto of where the waste is, idle by warehouse, then one
// line per check), Flagged, not priced (by flagged share), and How it's counted (a diagram; the
// prose is in the Guide).
//
// Three money units are shown side by side and NEVER added together: possible waste over the
// window, possible saving over the window (a resize), and storage $ per month.
import React from "react";
import { fmtInt, fmtMoney, fmtMoneyShort } from "../format";
import { useNames } from "../components/names";
import { belowFloorNoteText, aggTotal, numOrZero, useFindingAgg } from "../components/hooks";
import { AREA_REGISTRY, COST_MONEY_COL, WASTE_ITEMS, homeForQuery } from "../components/tab_registry";
import { ErrorBoundary, KindChip, PatternCard, StatusPill, bandPillKind } from "../components/primitives";
import { AreaContent } from "../area_content";
import { firstAction, scrollToAnchor } from "../components/overview_tile";
import { DrawerBus } from "../components/drawer";
import { DrillTable, SplitBar } from "../components/drill_table";
import { StatStrip } from "../components/blocks_2";
import { IssueTile, ShareBarList, StackedShareBar, StatusBars, fmtShare, pctOf } from "../components/blocks";
import { buildWasteWorklist, useBelowFloorWaste, useWasteTopRows, overlapNote, wasteTotal, wasteUnitOf } from "../components/waste_total";
import { pickNum, priceBasisText } from "./tab_overview";
import { emptyLabelFor, pickLabelColumn, rowLabelOf } from "./tab_area";
import type { MultiFetchState } from "../components/hooks";
import type { WasteEntry } from "../components/waste_total";
import type { Dims, Filters, Finding, GoToFn, Meta, Row } from "../types";

/** The three money units, never added together. */
export type WasteUnit = "waste" | "saving" | "month";

export interface UnitMetaEntry { title: string; period: (w: number) => string; noun: string; tone: string }

type WasteTotal = ReturnType<typeof wasteTotal>;
type WasteFigure = WasteTotal[WasteUnit];

/** One named offender: a row label, its discounted $ and its worst status. */
export interface Offender { name: string; v: number; status?: string }

/** A priced check's largest flagged rows, with the fetch they came from and its header. */
export interface Offenders { rows: Offender[] | null; state: any; header?: any }

/** The props the area shell passes to each Waste sub-tab. */
interface WastePageProps {
  filters: Filters;
  dims: Dims;
  goTo: GoToFn;
  setVerdict?: ((sentence: string | null) => void) | null;
  allFindingsIndex?: Record<string, Finding> | null;
  meta: Meta | null;
  [key: string]: any;
}


export const UNIT_META: Record<WasteUnit, UnitMetaEntry> = {
  waste: { title: "Possible waste", period: (w: number) => `over ${w} days`, noun: "possible waste", tone: "crit" },
  saving: { title: "Possible saving from resizing", period: (w: number) => `over ${w} days`, noun: "possible saving", tone: "" },
  month: { title: "Storage that could be freed", period: () => "per month", noun: "storage", tone: "" },
};

export function lowerFirstWord(s: string | null | undefined) {
  const t = String(s || "");
  if (!t) return t;
  // An acronym's second letter is also upper case: lowering only the first would read as a typo.
  const second = t.charAt(1);
  if (second && second === second.toUpperCase() && second !== second.toLowerCase()) return t;
  return t.charAt(0).toLowerCase() + t.slice(1);
}

const STATUS_RANK: Record<string, number> = { CRITICAL: 0, WARN: 1 };

// Where a priced check's money sits: its largest flagged rows, named, ranked by the item's own
// column (discounted the same way the headline is, so offenders sum back to the check's figure).
export function offendersFor(entry: WasteEntry, topState: MultiFetchState | null | undefined, dims: Dims): Offenders {
  const st = topState && topState.byId && topState.byId[entry.id];
  if (!st || st.phase !== "ready" || st.outcome !== "ok_rows") return { rows: null, state: st };
  const cols = st.data!.columns;
  const disc = numOrZero(st.data!.discount_pct);
  const labelCol = pickLabelColumn(cols);
  const agg = new Map<string, Offender>();
  (st.data!.rows || []).forEach((r: Row) => {
    if (r.status !== "CRITICAL" && r.status !== "WARN") return;
    const v = pickNum(r, [entry.col!]);
    if (v === null) return;
    const name = rowLabelOf(r, labelCol, dims) || emptyLabelFor(labelCol);
    const cur = agg.get(name) || { name, v: 0, status: r.status };
    cur.v += v * (1 - disc);
    if ((STATUS_RANK[r.status] ?? 2) < (STATUS_RANK[cur.status || ""] ?? 2)) cur.status = r.status;
    agg.set(name, cur);
  });
  const rows = [...agg.values()].filter((o) => o.v > 0).sort((a, b) => b.v - a.v);
  return { rows, state: st, header: st.data!.header };
}

export function OffenderRow({ o, max, unit }: { o: Offender; max: number; unit: WasteUnit | null }) {
  const pct = max > 0 ? Math.max(1, Math.round((o.v / max) * 100)) : 1;
  return (
    <div className="ws-offender-row">
      <div className="ws-offender-text" title={o.name}><b>{o.name}</b></div>
      <div className="ws-offender-bar-track"><div className="ws-offender-bar-fill" style={{ width: `${pct}%` }} /></div>
      <div className="mono ws-offender-val">{fmtMoney(o.v, 0)}{unit === "month" ? "/mo" : ""}</div>
    </div>
  );
}

function openTarget(id: string) {
  const home = homeForQuery({ query_id: id });
  return { home, target: { tab: home.tab, subtab: home.subtab, focusQueryId: id } };
}

// One priced check on one line: rank, status, title, a $ bar against its unit's largest, the $ and
// "N of M"; open it for its largest objects and the first fix.
export function PricedLine({ rank, entry, off, goTo, max }: { rank: number; entry: WasteEntry; off: Offenders; goTo: GoToFn; max: number }) {
  const [open, setOpen] = React.useState(false);
  const rows = off.rows || [];
  const top = rows.slice(0, 5);
  const action = off.header ? firstAction(off.header) : null;
  const { home, target } = openTarget(entry.id);
  const per = entry.unit === "month" ? "/mo" : "";
  const w = max > 0 && entry.usd != null ? Math.max(1, (entry.usd / max) * 100) : 0;
  return (
    <div className={`ws-line${open ? " open" : ""}`}>
      <button type="button" className="ws-line-head" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="ws-line-rank mono">{rank}</span>
        <StatusPill kind={bandPillKind(entry.band)} compact />
        <span className="ws-line-title" title={entry.title}>{entry.title}</span>
        <span className="ws-line-track" aria-hidden="true"><span className="ws-line-fill" style={{ width: `${w}%` }} /></span>
        <span className="ws-line-usd mono">{`${fmtMoney(entry.usd, 0)}${per}`}</span>
        <span className="ws-line-aff faint">{entry.affected ? `${fmtInt(entry.affected.flagged)} of ${fmtInt(entry.affected.total)} ${entry.affected.noun}` : ""}</span>
        <span className="ws-line-caret" aria-hidden="true">{open ? "▾" : "▸"}</span>
      </button>
      {open && (
        <div className="ws-line-body">
          {top.length === 0 ? <div className="faint">{off.state && off.state.phase !== "ready" ? "…" : entry.why}</div>
            : top.map((o) => <OffenderRow key={o.name} o={o} max={top[0].v} unit={entry.unit} />)}
          {rows.length > top.length && <div className="faint">{`+${fmtInt(rows.length - top.length)} more: ${rows.slice(5, 8).map((o) => `${o.name} ${fmtMoneyShort(o.v)}`).join(", ")}${rows.length > 8 ? "…" : ""}`}</div>}
          {action && <div className="ws-fix-line"><b>Fix</b><span title={action.full}>{action.text}</span></div>}
          <button type="button" className="ov-link-btn" onClick={() => goTo(target)}>{`Open in ${(AREA_REGISTRY[home.tab] || {}).label || "the check"} →`}</button>
        </div>
      )}
    </div>
  );
}

export function UnitKpi({ unit, fig, windowDays, ready, spend }: { unit: WasteUnit; fig: WasteFigure; windowDays: number; ready: boolean; spend?: number | null }) {
  const um = UNIT_META[unit];
  const value = !ready ? "…" : fig.usd == null ? "-" : fmtMoney(fig.usd, 0);
  const share = unit !== "month" && fig.usd != null && spend ? fmtShare(pctOf(fig.usd, spend)) : null;
  const caption = !ready ? null : fig.usd == null
    ? (fig.ran > 0 ? "flagged, but no figure of this kind in this export" : "not assessed: none of these checks ran")
    : `${share ? `${share} of spend · ` : ""}${um.period(windowDays)} · ${fmtInt(fig.flagged)} of ${fmtInt(fig.ran)} checks flagged`;
  return (
    <div className="card ov-kpi-card">
      <div className="ov-kpi-label">{um.title}</div>
      <div className="ov-kpi-value-row">
        <span className={`ov-kpi-value mono${um.tone && (fig.usd ?? 0) > 0 ? ` tone-${um.tone}` : ""}`}>{value}</span>
        {unit === "month" && fig.usd != null && ready ? <span className="ov-kpi-unit">/mo</span> : null}
      </div>
      {caption && <div className="ov-kpi-caption">{caption}</div>}
    </div>
  );
}

/** "Aug 2026" from a YYYY-MM-DD month start. */
function monthWord(d: string): string {
  const m = /^(\d{4})-(\d{2})/.exec(d);
  return m ? `${["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][Number(m[2]) - 1]} ${m[1]}` : d;
}

export function WasteVerdict({ ready, wt, windowDays }: { ready: boolean; wt: WasteTotal; windowDays: number }) {
  if (!ready) return null;
  if (wt.waste.usd == null) return "Possible waste could not be assessed: none of the waste checks ran (see Coverage & Gaps).";
  const bits = [`${fmtMoney(wt.waste.usd, 0)} of possible waste over the last ${windowDays} days`];
  if (wt.saving.usd != null) bits.push(`${fmtMoney(wt.saving.usd, 0)} of possible saving from resizing`);
  if (wt.month.usd != null) bits.push(`${fmtMoney(wt.month.usd, 0)} per month of storage that could be freed`);
  return `${bits.join("; ")}. Never added together.`;
}

export function WastePricedContent({ filters, dims, goTo, setVerdict, allFindingsIndex, meta }: WastePageProps) {
  useNames();
  const byId: Record<string, Finding> = allFindingsIndex || {};
  const worklist = React.useMemo(() => buildWasteWorklist(byId), [allFindingsIndex]); // eslint-disable-line react-hooks/exhaustive-deps
  const belowFloorById = useBelowFloorWaste(filters);
  const wt = wasteTotal(worklist, belowFloorById);
  const topState = useWasteTopRows(worklist, filters, 50);
  const spendAgg = useFindingAgg("cost_dollarized_by_service_day", filters.window, filters.accountIds, ["usage_date"], "sum", COST_MONEY_COL);
  const spend = spendAgg.phase === "ready" && spendAgg.outcome === "ok_rows"
    ? aggTotal(spendAgg.data) : null;
  const ready = Object.keys(byId).length > 0 && topState.phase === "ready";
  // Storage to free is per month, so its base is a month of storage spend: the last full calendar month.
  const storeAgg = useFindingAgg("cost_monthly_actuals", filters.window, filters.accountIds, ["month_start", "billing_origin_product", "partial_reason"], "sum", "net_list_cost_usd");
  const storeMonth = React.useMemo(() => {
    if (!(storeAgg.phase === "ready" && storeAgg.outcome === "ok_rows" && storeAgg.data)) return null;
    const full = (storeAgg.data.groups || []).filter((g: Row) => g.key && g.key[1] === "STORAGE" && g.key[2] == null && g.value != null)
      .sort((a: Row, b: Row) => String(b.key[0]).localeCompare(String(a.key[0])))[0];
    return full ? { usd: numOrZero(full.value) * (1 - numOrZero(storeAgg.data.discount_pct)), month: String(full.key[0]).slice(0, 10) } : null;
  }, [storeAgg]);

  const sentence = ready ? WasteVerdict({ ready, wt, windowDays: filters.window }) : null;
  React.useEffect(() => { if (setVerdict) setVerdict(sentence); }, [sentence]); // eslint-disable-line react-hooks/exhaustive-deps

  const sections = (["waste", "saving", "month"] as WasteUnit[]).map((unit) => {
    const entries = worklist.filter((w) => w.unit === unit);
    const flagged = entries.filter((w) => w.ran && w.isFlagged && w.usd != null && w.usd > 0).sort((a, b) => b.usd! - a.usd!);
    const notRun = entries.filter((w) => !w.ran);
    return { unit, flagged, notRun };
  });
  const wasteFlagged = sections[0].flagged;
  // Idle has one home: the warehouse idle check, by warehouse.
  const idleEntry = worklist.find((w) => w.id === "sf_wh_idle_minutes" && w.usd != null && w.usd > 0) || null;
  const idleOff = idleEntry ? offendersFor(idleEntry, topState, dims) : null;
  const idleTarget = openTarget("sf_wh_idle_minutes").target;

  // One tile per unit: the share of spend (never for storage per month), its $ and base, the largest part.
  const checksFlagged = (fig: WasteFigure) => `${fmtInt(fig.flagged)} of ${fmtInt(fig.ran)} checks flagged`;
  const missing = (fig: WasteFigure) => (fig.ran > 0 ? "flagged, but no figure of this kind in this export" : "none of these checks ran");
  const topOf = (i: number) => sections[i].flagged[0] || null;
  const shareOfTop = (i: number, fig: WasteFigure) => {
    const t = topOf(i);
    return t && fig.usd ? `${fmtShare(pctOf(t.usd, fig.usd))} of it is ${lowerFirstWord(t.title)}.` : null;
  };
  const toList = (unit: WasteUnit) => () => scrollToAnchor(`ws-${unit}`);
  const tileStatus = (fig: WasteFigure) => (fig.usd == null ? "not_assessed" : fig.flagged > 0 ? "warn" : "ok") as "warn" | "ok" | "not_assessed";
  const wastePct = wt.waste.usd != null ? pctOf(wt.waste.usd, spend) : null;
  const savingPct = wt.saving.usd != null ? pctOf(wt.saving.usd, spend) : null;

  const list = (unit: WasteUnit, idx: number) => {
    const { flagged, notRun } = sections[idx];
    const max = flagged.length ? (flagged[0].usd as number) : 0;
    const um = UNIT_META[unit];
    if (!flagged.length && !notRun.length && !(ready && wt[unit].usd != null)) return null;
    return (
      <div id={`ws-${unit}`}>
        <PatternCard title={`${um.title} · ${um.period(filters.window)}`}
          sub={`${fmtInt(flagged.length)} check${flagged.length === 1 ? "" : "s"}${unit === "saving" ? " · a different unit from waste" : unit === "month" ? ` · per month, not per ${filters.window} days` : ""} · open a row for its rows and the fix`}>
          {flagged.length > 0 && (
            <div className="ws-lines">
              {flagged.map((entry, i) => (
                <ErrorBoundary key={entry.id}>
                  <PricedLine rank={i + 1} entry={entry} off={offendersFor(entry, topState, dims)} goTo={goTo} max={max} />
                </ErrorBoundary>
              ))}
            </div>
          )}
          {ready && flagged.length === 0 && wt[unit].usd != null && (
            <div className="chart-note-oneline">{`Nothing flagged in the ${fmtInt(wt[unit].ran)} of ${fmtInt(wt[unit].total)} checks that ran.`}</div>
          )}
          {ready && notRun.length > 0 && (
            <div className="nj-pill ws-notrun">{`– Not assessed: ${notRun.map((w) => `${w.title} (${w.notRunLabel || "did not run"})`).join("; ")}`}</div>
          )}
        </PatternCard>
      </div>
    );
  };

  return (
    <div>
      <div className="summary-tile-row compact ws-tiles">
        <IssueTile label={`Possible waste · ${filters.window} days`} loading={!ready} status={tileStatus(wt.waste)}
          headline={wastePct != null ? fmtShare(wastePct) : (wt.waste.usd != null ? fmtMoney(wt.waste.usd, 0) : null)} unit={wastePct != null ? "of spend" : undefined}
          missingReason={missing(wt.waste)}
          base={wt.waste.usd != null ? `${fmtMoney(wt.waste.usd, 0)}${spend ? ` of ${fmtMoney(spend, 0)}` : ""} · ${checksFlagged(wt.waste)}` : null}
          cause={shareOfTop(0, wt.waste)} onOpen={toList("waste")} openLabel={`${fmtInt(sections[0].flagged.length)} checks ↓`} />
        <IssueTile label={`Possible saving from resizing · ${filters.window} days`} loading={!ready} pill={<KindChip>kept apart</KindChip>}
          headline={savingPct != null ? fmtShare(savingPct) : (wt.saving.usd != null ? fmtMoney(wt.saving.usd, 0) : null)} unit={savingPct != null ? "of spend" : undefined}
          missingReason={missing(wt.saving)}
          base={wt.saving.usd != null ? `${fmtMoney(wt.saving.usd, 0)} · ${checksFlagged(wt.saving)}` : null}
          cause={topOf(1) ? `${topOf(1)!.affected ? `${fmtInt(topOf(1)!.affected.flagged)} of ${fmtInt(topOf(1)!.affected.total)} ${topOf(1)!.affected.noun}: ` : ""}${lowerFirstWord(topOf(1)!.title)}.` : null}
          onOpen={toList("saving")} openLabel={`${fmtInt(sections[1].flagged.length)} checks ↓`} />
        <IssueTile label="Storage that could be freed · per month" loading={!ready} status={tileStatus(wt.month)}
          headline={wt.month.usd != null ? fmtMoney(wt.month.usd, 0) : null} unit="/ month" missingReason={missing(wt.month)}
          base={wt.month.usd != null ? `${storeMonth ? `of ${fmtMoney(storeMonth.usd, 0)} storage spend in ${monthWord(storeMonth.month)} · ` : ""}${checksFlagged(wt.month)}` : null}
          cause={overlapNote(wt.month, (v) => fmtMoney(v, 0)) || shareOfTop(2, wt.month)} onOpen={toList("month")} openLabel={`${fmtInt(sections[2].flagged.length)} checks ↓`} />
      </div>
      {belowFloorNoteText(wt) && <div className="scope-note">{belowFloorNoteText(wt)}</div>}

      {ready && wasteFlagged.length > 0 && (
        <div className={idleOff && idleOff.rows && idleOff.rows.length ? "cj-charts-2" : ""}>
          <PatternCard title="Where the possible waste is" sub={`${fmtMoney(wt.waste.usd, 0)} across ${fmtInt(wasteFlagged.length)} check${wasteFlagged.length === 1 ? "" : "s"} · last ${filters.window} days`}>
            <StackedShareBar pareto height={26} valueFmt={(v) => fmtMoney(v, 0)} ariaLabel="Possible waste by check"
              segments={wasteFlagged.map((e) => ({ key: e.id, label: e.title, value: e.usd as number, onClick: () => goTo(openTarget(e.id).target) }))} />
          </PatternCard>
          {idleOff && idleOff.rows && idleOff.rows.length > 0 && (
            <PatternCard title="Idle, by warehouse" sub={`${fmtMoney(idleEntry!.usd, 0)} possible waste${idleEntry!.affected ? ` on ${fmtInt(idleEntry!.affected.flagged)} of ${fmtInt(idleEntry!.affected.total)} ${idleEntry!.affected.noun}` : ""} · dot = the warehouse's status`}
              link="Warehouses →" onLink={() => goTo(idleTarget)}>
              <StatusBars n={8} valueFmt={(v) => fmtMoney(v, 0)} unitLabel="idle $" ariaLabel="Idle cost by warehouse"
                items={idleOff.rows.map((o) => ({ key: o.name, name: o.name, value: o.v, status: o.status }))}
                onBarClick={() => goTo(idleTarget)} />
            </PatternCard>
          )}
        </div>
      )}

      <div className="cj-charts-2 ws-lists">
        <div>{list("waste", 0)}</div>
        <div>{list("saving", 1)}{list("month", 2)}</div>
      </div>
      <div className="scope-note">{`Three units, never added.${priceBasisText(meta) ? ` ${priceBasisText(meta)}.` : ""}`}</div>
    </div>
  );
}

const KIND_WORD: Record<string, string> = { saving: "possible saving", saving_month: "storage per month", context: "context", spend: "spend", gap: "gap" };
const sevOfBand = (band: string) => (band === "CRITICAL" ? "critical" : band === "WARN" ? "warn" : band === "OK" ? "ok" : "not_assessed") as "critical" | "warn" | "ok" | "not_assessed";
const affPct = (w: WasteEntry) => (w.affected && numOrZero(w.affected.total) > 0 ? pctOf(numOrZero(w.affected.flagged), numOrZero(w.affected.total)) : null);

export function WasteUnpricedContent({ goTo, setVerdict, allFindingsIndex }: WastePageProps) {
  const byId: Record<string, Finding> = allFindingsIndex || {};
  const ready = Object.keys(byId).length > 0;
  const worklist = React.useMemo(() => buildWasteWorklist(byId), [allFindingsIndex]); // eslint-disable-line react-hooks/exhaustive-deps
  const wt = wasteTotal(worklist);
  const items = worklist.filter((w) => w.unit === null);
  const notFlagged = items.filter((w) => w.ran && !w.isFlagged);
  const notRun = worklist.filter((w) => !w.ran);
  // A flagged check that carries its own $ is priced on its own page: listed apart, never here.
  const elsewhere = wt.flaggedOnly.filter((w) => w.ownMoney);
  const unpriced = wt.flaggedOnly.filter((w) => !w.ownMoney);
  const worst = [...unpriced].filter((w) => affPct(w) != null).sort((a, b) => numOrZero(affPct(b)) - numOrZero(affPct(a)))[0] || null;
  const homes = [...new Set(elsewhere.map((w) => (AREA_REGISTRY[openTarget(w.id).home.tab] || {}).label).filter(Boolean))];

  const sentence = !ready ? "…"
    : unpriced.length > 0
      ? `${fmtInt(unpriced.length)} of ${fmtInt(items.length)} unpriced checks flag objects but have no $ figure. They count as checks, never as dollars.`
      : `Nothing flagged without a $ figure in the ${fmtInt(items.length - items.filter((w) => !w.ran).length)} of ${fmtInt(items.length)} unpriced checks that ran.`;
  React.useEffect(() => { if (setVerdict) setVerdict(sentence); }, [sentence]); // eslint-disable-line react-hooks/exhaustive-deps

  const open = (id: string) => () => goTo(openTarget(id).target);
  const drawer = (id: string) => () => DrawerBus.open({ id });
  return (
    <div className="sx-page">
      <div className="summary-tile-row compact sx-tiles-4">
        <IssueTile label="Flagged, no $ figure" loading={!ready} pill={<KindChip>counted as checks</KindChip>}
          headline={fmtInt(unpriced.length)} unit="checks"
          base={`${fmtInt(unpriced.length)} of ${fmtInt(worklist.length)} waste checks · objects counted per check, never summed`}
          cause={'Shown as "–", never $0. Not added to any $ total.'} onOpen={() => scrollToAnchor("wu-list")} openLabel={`The ${fmtInt(unpriced.length)} ↓`} />
        <IssueTile label="Worst share flagged" loading={!ready} status={worst ? sevOfBand(worst.band) : "ok"}
          headline={worst ? fmtShare(affPct(worst)) : "None"} unit={worst && worst.affected ? `of ${worst.affected.noun}` : undefined}
          base={worst && worst.affected ? `${fmtInt(worst.affected.flagged)} of ${fmtInt(worst.affected.total)} ${worst.affected.noun} · ${lowerFirstWord(worst.title)}` : null}
          onOpen={worst ? drawer(worst.id) : undefined} openLabel="Open →" />
        <IssueTile label="Priced on its own page" loading={!ready} pill={<KindChip>not added here</KindChip>}
          headline={fmtInt(elsewhere.length)} unit="checks"
          base={`${fmtInt(elsewhere.length)} of ${fmtInt(worklist.length)}${homes.length ? ` · $ shown on ${homes.join(", ")}` : ""}`}
          cause="Other kinds of $ (saving, spend, context), kept apart." onOpen={() => scrollToAnchor("wu-elsewhere")} openLabel={`The ${fmtInt(elsewhere.length)} ↓`} />
        <IssueTile label="Did not run" loading={!ready} status={notRun.length ? "not_assessed" : "ok"}
          headline={notRun.length ? null : "None"} missingReason={`${fmtInt(notRun.length)} of ${fmtInt(worklist.length)} waste checks: ${notRun.slice(0, 3).map((w) => `${lowerFirstWord(w.title)} (${w.notRunLabel || "did not run"})`).join("; ")}${notRun.length > 3 ? "…" : ""}`}
          base={notRun.length ? null : `all ${fmtInt(worklist.length)} waste checks ran`}
          onOpen={() => goTo({ tab: "coverage" })} openLabel="Coverage →" />
      </div>

      <PatternCard title="Share of each check's objects flagged" sub={`${fmtInt(unpriced.length)} checks · flagged of base · dot = the check's status`}>
        {!ready ? <div className="chart-note-oneline">…</div>
          : unpriced.length === 0 ? <div className="chart-note-oneline">Nothing flagged without a $ figure in the checks that ran.</div>
          : <ShareBarList n={30} items={unpriced.map((w) => ({
            key: w.id, name: w.title, value: w.affected ? numOrZero(w.affected.flagged) : null, total: w.affected ? numOrZero(w.affected.total) : null,
            status: w.band, onClick: drawer(w.id),
          }))} />}
      </PatternCard>

      <div id="wu-list">
        <PatternCard title="Flagged, no $ figure" sub="Status · check and why there is no $ · flagged of base · click a row for its rows">
          {!ready ? <div className="chart-note-oneline">…</div> : (
            <DrillTable aria="Flagged checks with no $ figure" n={30} empty="Nothing flagged without a $ figure."
              cols={[{ label: "Check", width: "minmax(0, 3fr)" }, { label: "Flagged", num: true, width: "minmax(90px, auto)" }]}
              rows={unpriced.map((w) => ({
                key: w.id, onOpen: drawer(w.id), title: w.why || undefined,
                cells: [<span key="c" className="wu-check"><StatusPill kind={bandPillKind(w.band)} /><span className="wu-check-text"><b>{w.title}</b><span>{w.why}</span></span></span>,
                  w.affected ? `${fmtInt(w.affected.flagged)} of ${fmtInt(w.affected.total)} ${w.affected.noun}` : "–"],
              }))} />
          )}
          {ready && notFlagged.length > 0 && <div className="sx-foot">{`${fmtInt(notFlagged.length)} more ran and flagged nothing.`}</div>}
        </PatternCard>
      </div>

      {ready && elsewhere.length > 0 && (
        <div id="wu-elsewhere">
          <PatternCard title="Flagged, priced on its own page" sub={`${fmtInt(elsewhere.length)} checks · each $ is labelled by kind and lives where its rows are · not added here, or to each other`}>
            {elsewhere.map((w) => {
              const { home } = openTarget(w.id);
              return (
                <div className="ws-flagged-row" key={w.id}>
                  <StatusPill kind={bandPillKind(w.band)} />
                  <span className="ws-flagged-title">{w.title}</span>
                  <span className="ws-flagged-who mono">{`${fmtMoney(w.ownMoney!.usd, 0)}${w.ownMoney!.perMonth ? "/mo" : ""} ${KIND_WORD[w.ownMoney!.kind] || w.ownMoney!.kind}`}</span>
                  <button type="button" className="ov-link-btn" onClick={open(w.id)}>{`Open in ${(AREA_REGISTRY[home.tab] || {}).label || "the check"} →`}</button>
                </div>
              );
            })}
          </PatternCard>
        </div>
      )}
    </div>
  );
}

// What each unit means, and how a status reads: the short form; the Guide has the long one.
const DEFINITIONS: { name: string; unit: (w: number) => string; text: string; context?: boolean }[] = [
  { name: "Possible waste", unit: (w) => `$ · ${w} d`, text: "Credits a warehouse or feature used with no work to show: idle minutes, runs that changed nothing, retries, failed SQL." },
  { name: "Possible saving", unit: (w) => `$ · ${w} d`, text: "What the same work would have cost at another setting: one size down, one shared warehouse." },
  { name: "Storage that could be freed", unit: () => "$ · per month", text: "Bytes billed monthly that nothing reads: unused tables, stale stage files, Time Travel above policy." },
  { name: "Spend", unit: (w) => `$ · ${w} d`, text: "What the account was billed. Shown for scale; never a finding itself.", context: true },
  { name: "Change", unit: (w) => `% · vs previous ${w} d`, text: "Spend against the previous window of the same length. A rise is not waste until a check says why." },
];
const STATUS_MEANS: { kind: string; text: string }[] = [
  { kind: "critical", text: "Over the check's critical line. Worth a change this week." },
  { kind: "warn", text: "Over the warning line. Worth a look." },
  { kind: "neutral", text: "A figure for scale: spend, counts, run times. Not a finding, never coloured." },
  { kind: "not_assessed", text: 'The check did not run: not in this export, needs Enterprise edition, or the role can\'t see it. Shown as "–" with the reason. Never $0, never green.' },
  { kind: "ok", text: "The check ran, saw its full base, and flagged nothing." },
];

export function WasteMethodContent({ setVerdict, goTo, filters, allFindingsIndex, meta }: Partial<WastePageProps>) {
  const byId: Record<string, Finding> = allFindingsIndex || {};
  const ready = Object.keys(byId).length > 0;
  const w = filters ? filters.window : 30;
  const worklist = React.useMemo(() => buildWasteWorklist(byId), [allFindingsIndex]); // eslint-disable-line react-hooks/exhaustive-deps
  const belowFloorById = useBelowFloorWaste(filters as Filters);
  const wt = wasteTotal(worklist, belowFloorById);
  const spendAgg = useFindingAgg(filters ? "cost_dollarized_by_service_day" : null, w, filters ? filters.accountIds : [], ["usage_date"], "sum", COST_MONEY_COL);
  const spend = spendAgg.phase === "ready" && spendAgg.outcome === "ok_rows" ? aggTotal(spendAgg.data) : null;
  const price = meta && meta.price_basis ? meta.price_basis.credit_price_usd : null;
  const storagePrice = meta && meta.price_basis ? meta.price_basis.storage_price_usd_tb_month : null;
  const floor = wt.floor as Row | null;

  const sentence = !ready ? "…" : `Three units, three figures, never one total. Each box sums its own checks' flagged rows${price != null ? ` at ${fmtMoney(price, 2)} per credit` : ""}.`;
  React.useEffect(() => { if (setVerdict) setVerdict(sentence); }, [sentence]); // eslint-disable-line react-hooks/exhaustive-deps

  const byUnit = (unit: WasteUnit | null) => worklist.filter((x) => x.unit === unit);
  const box = (unit: WasteUnit, fig: WasteFigure) => (
    <div className="ws-dia-box">
      <div className="ws-dia-title">{`${UNIT_META[unit].title} · ${unit === "month" ? "per month" : `${w} days`}`}</div>
      <div className="ws-dia-value mono">{!ready ? "…" : fig.usd == null ? "–" : `${fmtMoney(fig.usd, 0)}${unit === "month" ? "/mo" : ""}`}</div>
      <div className="ws-dia-sub">{`${fmtInt(byUnit(unit).length)} checks${unit !== "month" && fig.usd != null && spend ? ` · ${fmtShare(pctOf(fig.usd, spend))} of ${fmtMoney(spend, 0)} spend` : ""}`}</div>
    </div>
  );
  const line = (it: (typeof WASTE_ITEMS)[number]) => {
    const home = AREA_REGISTRY[it.area];
    return <div className="ws-method-line" key={it.id}><span className="mono">{it.id}</span>{` · ${home ? home.label : it.area}: ${it.why}`}</div>;
  };
  const unitRows: { key: string; label: string; entries: WasteEntry[] }[] = [
    { key: "waste", label: `Possible waste · ${w} d`, entries: byUnit("waste") },
    { key: "saving", label: `Possible saving · ${w} d`, entries: byUnit("saving") },
    { key: "month", label: "Storage to free · per month", entries: byUnit("month") },
    { key: "none", label: "Flagged, no $ figure", entries: byUnit(null) },
  ];
  const ranNoUsd = wt.flaggedOnly.length;
  return (
    <div className="sx-page">
      <PatternCard title="Three units, kept apart" sub={`${fmtInt(worklist.length)} checks · the ≠ is the rule: these are never added`}
        link="In full, in How it works →" onLink={goTo ? () => goTo({ tab: "guide", focusQueryId: "how-money" }) : null}>
        <div className="ws-dia" role="img" aria-label="Three money units, never added together">
          {box("waste", wt.waste)}
          <div className="ws-dia-sep" aria-hidden="true">≠</div>
          {box("saving", wt.saving)}
          <div className="ws-dia-sep" aria-hidden="true">≠</div>
          {box("month", wt.month)}
        </div>
        <div className="ws-dia-foot">Waste is credits already burned with nothing to show. Saving is what the same work would cost at another setting, so part of it is also waste: adding them would count the idle hour twice. Storage is per month, not per window.</div>
      </PatternCard>

      <div className="cj-charts-2">
        <PatternCard title="Definitions" sub="What each unit means · what it is measured in">
          <div className="sx-defs">
            {DEFINITIONS.map((d) => (
              <div className="sx-def" key={d.name}>
                <span className="sx-def-name">{d.name}{d.context ? <> <KindChip>context</KindChip></> : null}</span>
                <span className="sx-def-unit">{d.unit(w)}</span>
                <span className="sx-def-text">{d.text}</span>
              </div>
            ))}
          </div>
        </PatternCard>
        <PatternCard title="What a status means" sub="Colour is severity, never size · bars stay neutral; the status lives on the dot or the pill">
          <div className="sx-defs">
            {STATUS_MEANS.map((s) => (
              <div className="sx-stat" key={s.kind}><span><StatusPill kind={s.kind} /></span><span>{s.text}</span></div>
            ))}
          </div>
        </PatternCard>
      </div>

      <PatternCard title="The floor, and what is not counted" sub={floor && floor.min != null ? `A flagged row is priced only when it is worth at least ${fmtMoney(floor.min, 0)}; under that it stays flagged, not priced` : "A flagged row under the materiality floor stays flagged, not priced"}>
        <StatStrip ariaLabel="The floor and what is not counted" cells={[
          { key: "floor", label: "Floor", value: floor && floor.min != null ? fmtMoney(floor.min, 0) : null, base: floor && floor.label ? String(floor.label) : undefined, missing: ready ? "no floor reported" : "…" },
          { key: "under", label: "Rows under the floor", value: wt.belowFloorUsd != null ? fmtInt(wt.belowFloorRows) : null, unit: " rows", base: wt.belowFloorUsd != null ? `${fmtMoney(wt.belowFloorUsd, 0)} flagged, not priced` : undefined, missing: "…" },
          { key: "nousd", label: "Checks with no $", value: ready ? fmtInt(byUnit(null).length) : null, unit: ` of ${fmtInt(worklist.length)}`, base: `counted as checks · ${fmtInt(ranNoUsd)} flagged`, missing: "…" },
          { key: "notrun", label: "Did not run", pill: wt.notRun.length ? "not_assessed" : null, value: ready ? fmtInt(wt.notRun.length) : null, unit: ` of ${fmtInt(worklist.length)}`, base: 'reads "–", not in a total', missing: "…" },
          { key: "rate", label: "Effective $ per credit", value: price != null ? fmtMoney(price, 2) : null, base: priceBasisText(meta || null) || undefined, missing: "no credit price in this export" },
          { key: "storage", label: "Storage rate", value: storagePrice != null ? fmtMoney(storagePrice, 0) : null, unit: " per TB · mo", missing: "no storage price in this export" },
        ]} />
      </PatternCard>

      <PatternCard title={`The ${fmtInt(worklist.length)} checks behind the figures`} sub="By unit · how many priced, flagged with no $, did not run">
        <DrillTable aria="Checks behind the figures, by unit" n={4}
          cols={[{ label: "Unit", width: "minmax(150px, 1.2fr)" }, { label: "Priced · flagged, no $ · not run", width: "minmax(80px, 2fr)" }, { label: "Checks", num: true, width: "auto" }]}
          rows={unitRows.map((u) => {
            const pricedN = u.entries.filter((x) => x.ran && x.usd != null).length;
            const noUsd = u.entries.filter((x) => x.ran && x.isFlagged && x.usd == null).length;
            const nr = u.entries.filter((x) => !x.ran).length;
            return {
              key: u.key,
              cells: [u.label, <SplitBar key="b" max={u.entries.length || 1} parts={[{ value: pricedN }, { value: noUsd, color: "var(--c2)" }, { value: nr, hatched: true }]} />,
                `${fmtInt(pricedN)} priced · ${fmtInt(noUsd)} no $ · ${fmtInt(nr)} not run of ${fmtInt(u.entries.length)}`],
            };
          })} />
        <details className="ws-method-list">
          <summary>{`Every check, by unit`}</summary>
          <div className="section-title">Possible waste</div>{WASTE_ITEMS.filter((it) => wasteUnitOf(it) === "waste").map(line)}
          <div className="section-title">Possible saving from resizing</div>{WASTE_ITEMS.filter((it) => wasteUnitOf(it) === "saving").map(line)}
          <div className="section-title">Storage, per month</div>{WASTE_ITEMS.filter((it) => wasteUnitOf(it) === "month").map(line)}
          <div className="section-title">Flagged, no $ figure</div>{WASTE_ITEMS.filter((it) => wasteUnitOf(it) === null).map(line)}
        </details>
      </PatternCard>
    </div>
  );
}

AreaContent.register("waste", "priced", WastePricedContent);
AreaContent.register("waste", "unpriced", WasteUnpricedContent);
AreaContent.register("waste", "method", WasteMethodContent);
