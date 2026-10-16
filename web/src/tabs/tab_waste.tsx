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
import { ErrorBoundary, PatternCard, StatusPill } from "../components/primitives";
import { AreaContent } from "../area_content";
import { firstAction, scrollToAnchor } from "../components/overview_tile";
import { DrawerBus } from "../components/drawer";
import { CellBar, CxTable, LabelBars, NameBars, NameIdText, SevWord } from "../components/cx_b";
import type { CxBarRow, CxGroup, CxRow } from "../components/cx_b";
import { IssueTile, fmtShare, pctOf } from "../components/blocks";
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

// An opened priced check: its largest objects and the first fix, then a link to its home.
function PricedBody({ entry, off, goTo }: { entry: WasteEntry; off: Offenders; goTo: GoToFn }) {
  const rows = off.rows || [];
  const top = rows.slice(0, 5);
  const action = off.header ? firstAction(off.header) : null;
  const { home, target } = openTarget(entry.id);
  return (
    <>
      {top.length === 0 ? <div className="faint">{off.state && off.state.phase !== "ready" ? "…" : entry.why}</div>
        : top.map((o) => <OffenderRow key={o.name} o={o} max={top[0].v} unit={entry.unit} />)}
      {rows.length > top.length && <div className="faint">{`+${fmtInt(rows.length - top.length)} more: ${rows.slice(5, 8).map((o) => `${o.name} ${fmtMoneyShort(o.v)}`).join(", ")}${rows.length > 8 ? "…" : ""}`}</div>}
      {action && <div className="ws-fix-line"><b>Fix</b><span>{action.text}</span></div>}
      <button type="button" className="ov-link-btn" onClick={() => goTo(target)}>{`Open in ${(AREA_REGISTRY[home.tab] || {}).label || "the check"} →`}</button>
    </>
  );
}

/** The small "i" in a circle before a one-line note. */
export function InfoMark() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <circle cx="8" cy="8" r="6.5" stroke="currentColor" strokeWidth="1.3" />
      <path d="M8 7.2v4M8 4.8v.1" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
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
  if (wt.month.usd != null) bits.push(`${fmtMoney(wt.month.usd, 0)} a month of storage that could be freed`);
  const list = bits.length > 1 ? `${bits.slice(0, -1).join(", ")}, and ${bits[bits.length - 1]}` : bits[0];
  return `${list}. ${bits.length === 3 ? "The three are" : "They are"} never added together.`;
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
  const missing = (fig: WasteFigure) => (fig.ran > 0 ? "flagged, but no figure of this kind in this export" : "none of these checks ran");
  const topOf = (i: number) => sections[i].flagged[0] || null;
  const shareOfTop = (i: number, fig: WasteFigure) => {
    const t = topOf(i);
    return t && fig.usd ? `${fmtShare(pctOf(t.usd, fig.usd))} of it is ${lowerFirstWord(t.title)}.` : null;
  };
  const tileStatus = (fig: WasteFigure) => (fig.usd == null ? "not_assessed" : fig.flagged > 0 ? "warn" : "ok") as "warn" | "ok" | "not_assessed";
  const wastePct = wt.waste.usd != null ? pctOf(wt.waste.usd, spend) : null;
  const savingPct = wt.saving.usd != null ? pctOf(wt.saving.usd, spend) : null;

  // One table for every priced check, grouped by unit; a row opens its largest objects and the fix.
  const [openId, setOpenId] = React.useState<string | null>(null);
  const [allIdle, setAllIdle] = React.useState(false);
  const kindWord: Record<WasteUnit, string> = { waste: "waste", saving: "saving", month: "a month" };
  const kindColor: Record<WasteUnit, string> = { waste: "var(--c1)", saving: "var(--c3)", month: "var(--c4)" };
  const groups: CxGroup[] = sections.map(({ unit, flagged, notRun }) => {
    const max = flagged.length ? (flagged[0].usd as number) : 0;
    const um = UNIT_META[unit];
    const fig = wt[unit];
    const rows: CxRow[] = flagged.map((entry) => ({
      key: entry.id,
      open: openId === entry.id,
      onOpen: () => setOpenId(openId === entry.id ? null : entry.id),
      body: <ErrorBoundary><PricedBody entry={entry} off={offendersFor(entry, topState, dims)} goTo={goTo} /></ErrorBoundary>,
      cells: [
        <SevWord key="s" band={entry.band} />,
        <span key="t">{entry.title}</span>,
        <span key="f" className="cx-muted">{entry.affected ? `${fmtInt(entry.affected.flagged)} of ${fmtInt(entry.affected.total)} ${entry.affected.noun}` : "–"}</span>,
        <span key="i" className="cx-impact"><CellBar value={entry.usd as number} max={max} color={kindColor[unit]} /><span className="cx-impact-val">{fmtMoney(entry.usd, 0)}</span><span className="cx-impact-kind">{kindWord[unit]}</span></span>,
        <span key="r" className="cx-link">{openId === entry.id ? "Close ↑" : "Rows →"}</span>,
      ],
    }));
    if (ready && flagged.length === 0 && fig.usd != null) {
      rows.push({ key: `${unit}-none`, cells: [<span key="n" />, <span key="t" className="cx-muted">{`Nothing flagged in the ${fmtInt(fig.ran)} of ${fmtInt(fig.total)} checks that ran.`}</span>, null, null, null] });
    }
    if (ready && notRun.length > 0) {
      rows.push({ key: `${unit}-notrun`, cells: [<SevWord key="s" kind="not_assessed" />, <span key="t">{notRun.map((w) => `${w.title} (${w.notRunLabel || "did not run"})`).join("; ")}</span>, null, <span key="i" className="cx-impact"><span className="cx-impact-val">–</span></span>, null] });
    }
    const head = `${um.title} · ${fmtInt(flagged.length)} · ${unit === "month" ? "per month" : `last ${filters.window} days`}`;
    const total = fig.usd == null ? "–" : unit === "month" ? `${fmtMoney(fig.usd, 0)} a month` : fmtMoney(fig.usd, 0);
    return { key: unit, head, total: ready ? total : "…", rows };
  }).filter((g) => g.rows.length > 0);
  const pricedN = sections.reduce((n, s) => n + s.flagged.length, 0);
  const sevCount = (band: string) => sections.reduce((n, s) => n + s.flagged.filter((e) => e.band === band).length, 0);

  // Where the waste is: the six largest checks, then the rest as one grey row; bars scale to the largest.
  const whereRows: CxBarRow[] = wasteFlagged.slice(0, 6).map((e) => ({
    key: e.id, label: e.title, value: e.usd as number, valueText: fmtMoney(e.usd, 0), aside: ` · ${fmtShare(pctOf(e.usd, wt.waste.usd))}`,
    onClick: () => goTo(openTarget(e.id).target),
  }));
  const rest = wasteFlagged.slice(6);
  if (rest.length) {
    const v = rest.reduce((n, e) => n + (e.usd as number), 0);
    whereRows.push({ key: "__other", label: `Other checks (${fmtInt(rest.length)})`, value: v, valueText: fmtMoney(v, 0), aside: ` · ${fmtShare(pctOf(v, wt.waste.usd))}`, other: true });
  }
  let topK = 0;
  if (wasteFlagged.length >= 2 && wt.waste.usd) {
    let acc = 0;
    for (const e of wasteFlagged) { acc += e.usd as number; topK += 1; if (acc / wt.waste.usd >= 0.8) break; }
  }
  const topShare = topK ? fmtShare(pctOf(wasteFlagged.slice(0, topK).reduce((n, e) => n + (e.usd as number), 0), wt.waste.usd)) : null;

  const idleRows = idleOff && idleOff.rows ? idleOff.rows : [];
  const idleShown = allIdle ? idleRows : idleRows.slice(0, 8);
  const idleCrit = idleShown.filter((o) => o.status === "CRITICAL").length;
  const idleStatusText = idleShown.length && idleCrit === idleShown.length ? "all shown are critical"
    : `${fmtInt(idleCrit)} of ${fmtInt(idleShown.length)} shown are critical`;
  const floorNote = belowFloorNoteText(wt);
  const toList = () => scrollToAnchor("ws-checks");
  const checksOf = (fig: WasteFigure) => `${fmtInt(fig.flagged)} of ${fmtInt(fig.ran)} checks`;

  return (
    <div>
      <div className="summary-tile-row compact ws-tiles">
        <IssueTile label="Possible waste" loading={!ready} status={tileStatus(wt.waste)}
          headline={wt.waste.usd != null ? fmtMoney(wt.waste.usd, 0) : null}
          missingReason={missing(wt.waste)}
          base={wt.waste.usd != null ? `${wastePct != null ? `${fmtShare(wastePct)} of spend · ` : ""}${filters.window} days` : null}
          cause={wt.waste.usd != null ? <>{`${spend ? `Of ${fmtMoney(spend, 0)} spend, f` : "F"}lagged by ${checksOf(wt.waste)}.`}{shareOfTop(0, wt.waste) && <span className="cx-sub">{shareOfTop(0, wt.waste)}</span>}</> : null}
          onOpen={toList} openLabel={`${fmtInt(sections[0].flagged.length)} checks ↓`} />
        <IssueTile label="Possible saving from resizing" loading={!ready} status={wt.saving.usd == null ? "not_assessed" : "neutral"}
          headline={wt.saving.usd != null ? fmtMoney(wt.saving.usd, 0) : null}
          missingReason={missing(wt.saving)}
          base={wt.saving.usd != null ? `${savingPct != null ? `${fmtShare(savingPct)} of spend · ` : ""}${filters.window} days` : null}
          cause={wt.saving.usd != null ? <>{`Flagged by ${checksOf(wt.saving)}.`}{topOf(1) && <span className="cx-sub">{`${topOf(1)!.affected ? `${fmtInt(topOf(1)!.affected.flagged)} of ${fmtInt(topOf(1)!.affected.total)} ${topOf(1)!.affected.noun}: ` : ""}${lowerFirstWord(topOf(1)!.title)}.`}</span>}</> : null}
          onOpen={toList} openLabel={`${fmtInt(sections[1].flagged.length)} checks ↓`} />
        <IssueTile label="Storage that could be freed" loading={!ready} status={tileStatus(wt.month)}
          headline={wt.month.usd != null ? fmtMoney(wt.month.usd, 0) : null} unit="per month" missingReason={missing(wt.month)}
          base={wt.month.usd != null && storeMonth ? `Of ${fmtMoney(storeMonth.usd, 0)} storage spend in ${monthWord(storeMonth.month)}` : null}
          cause={wt.month.usd != null ? <>{`Flagged by ${checksOf(wt.month)}.`}{(overlapNote(wt.month, (v) => fmtMoney(v, 0)) || shareOfTop(2, wt.month)) && <span className="cx-sub">{overlapNote(wt.month, (v) => fmtMoney(v, 0)) || shareOfTop(2, wt.month)}</span>}</> : null}
          onOpen={toList} openLabel={`${fmtInt(sections[2].flagged.length)} checks ↓`} />
      </div>
      <div className="cx-note"><InfoMark /><span>{`Three units, never added.${floorNote ? ` ${floorNote}` : ""}`}</span></div>

      {ready && wasteFlagged.length > 0 && (
        <div className="cx-row">
          <PatternCard title="Where the possible waste is" sub={`${fmtMoney(wt.waste.usd, 0)} across ${fmtInt(wasteFlagged.length)} check${wasteFlagged.length === 1 ? "" : "s"} · last ${filters.window} days${topShare ? ` · top ${fmtInt(topK)} make ${topShare}` : ""}`}>
            <LabelBars rows={whereRows} max={wasteFlagged[0].usd as number} ariaLabel="Possible waste by check" />
          </PatternCard>
          {idleRows.length > 0 && (
            <PatternCard title="Idle, by warehouse" sub={`${fmtMoney(idleEntry!.usd, 0)} possible waste${idleEntry!.affected ? ` on ${fmtInt(idleEntry!.affected.flagged)} of ${fmtInt(idleEntry!.affected.total)} ${idleEntry!.affected.noun}` : ""} · ${idleStatusText}`}
              link="Warehouses →" onLink={() => goTo(idleTarget)}>
              <NameBars ariaLabel="Idle cost by warehouse" max={idleRows[0].v}
                rows={idleShown.map((o) => ({ key: o.name, label: <NameIdText text={o.name} />, value: o.v, valueText: fmtMoney(o.v, 0), onClick: () => goTo(idleTarget) }))} />
              {idleRows.length > 8 && (
                <button type="button" className="cx-show-all" onClick={() => setAllIdle(!allIdle)}>
                  {allIdle ? "Show the top 8" : `Show all ${fmtInt(idleRows.length)} warehouses`}
                </button>
              )}
            </PatternCard>
          )}
        </div>
      )}

      <div id="ws-checks">
        <PatternCard title="Checks on this tab" sub={`${fmtInt(pricedN)} priced checks, grouped by unit and ordered by dollars · bars compare within a group only · open a row for its rows and the fix`}
          link="All findings →" onLink={() => goTo({ tab: "findings" })}>
          {!ready ? <div className="chart-note-oneline">…</div> : (
            <CxTable aria="Priced checks, by unit" phone={{ cols: [1, 3], widths: "minmax(0, 1fr) 128px" }} minWidth={860} groups={groups}
              cols={[{ label: "Severity", width: "96px" }, { label: "Check", width: "minmax(260px, 1fr)" }, { label: "Found", width: "170px" }, { label: "Impact", width: "260px" }, { label: "", width: "64px", num: true }]}
              foot={<>
                <span>{`${fmtInt(pricedN)} priced check${pricedN === 1 ? "" : "s"} on this tab`}</span>
                {sevCount("CRITICAL") > 0 && <span className="cx-sev cx-sev-critical"><span className="cx-sev-dot" aria-hidden="true" />{`${fmtInt(sevCount("CRITICAL"))} critical`}</span>}
                {sevCount("WARN") > 0 && <span className="cx-sev cx-sev-warn"><span className="cx-sev-dot" aria-hidden="true" />{`${fmtInt(sevCount("WARN"))} warning`}</span>}
              </>} />
          )}
        </PatternCard>
      </div>
    </div>
  );
}

const KIND_WORD: Record<string, string> = { saving: "Possible saving", saving_month: "Storage a month", context: "For scale", spend: "Spend", spend_month: "Spend a month", change: "Change", gap: "Gap" };
// What the $ means, in the order the list groups it.
const KIND_ORDER = ["saving", "saving_month", "spend", "spend_month", "context", "change", "gap"];
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
  const pricedHere = worklist.filter((w) => w.unit !== null && w.ran && w.isFlagged && w.usd != null && w.usd > 0).length;

  const sentence = !ready ? "…"
    : unpriced.length > 0
      ? `${fmtInt(unpriced.length)} of ${fmtInt(items.length)} unpriced checks flag objects but carry no $ figure${worst && worst.affected ? `; the worst is ${fmtInt(worst.affected.flagged)} of ${fmtInt(worst.affected.total)} ${worst.affected.noun}` : ""}. ${elsewhere.length ? `${fmtInt(elsewhere.length)} more are priced on their own pages and not added here.` : "They count as checks, never as dollars."}`
      : `Nothing flagged without a $ figure in the ${fmtInt(items.length - items.filter((w) => !w.ran).length)} of ${fmtInt(items.length)} unpriced checks that ran.`;
  React.useEffect(() => { if (setVerdict) setVerdict(sentence); }, [sentence]); // eslint-disable-line react-hooks/exhaustive-deps

  const open = (id: string) => () => goTo(openTarget(id).target);
  const drawer = (id: string) => () => DrawerBus.open({ id });
  const byShare = [...unpriced].sort((a, b) => numOrZero(affPct(b)) - numOrZero(affPct(a)));
  const kindRank = (k: string) => { const i = KIND_ORDER.indexOf(k); return i < 0 ? KIND_ORDER.length : i; };
  const byKind = [...elsewhere].sort((a, b) => kindRank(a.ownMoney!.kind) - kindRank(b.ownMoney!.kind) || b.ownMoney!.usd - a.ownMoney!.usd);
  const homeList = homes.length > 4 ? `${homes.slice(0, 4).join(", ")} and ${fmtInt(homes.length - 4)} more pages` : homes.join(", ");
  return (
    <div className="sx-page">
      <div className="summary-tile-row compact ws-tiles">
        <IssueTile label="Flagged, no $ figure" loading={!ready}
          headline={fmtInt(unpriced.length)} unit={`of ${fmtInt(worklist.length)} waste checks`}
          base="Objects are counted per check, never summed."
          cause={'Shown as "–", never $0, and not added to any total.'} onOpen={() => scrollToAnchor("wu-list")} openLabel={`The ${fmtInt(unpriced.length)} ↓`} />
        <IssueTile label="Worst share flagged" loading={!ready} status={worst ? sevOfBand(worst.band) : "neutral"}
          headline={worst ? fmtShare(affPct(worst)) : "None"} unit={worst && worst.affected ? `of ${worst.affected.noun}` : undefined}
          base={worst && worst.affected ? `${fmtInt(worst.affected.flagged)} of ${fmtInt(worst.affected.total)} ${worst.affected.noun}: ${lowerFirstWord(worst.title)}.` : null}
          onOpen={worst ? drawer(worst.id) : undefined} openLabel="Open →" />
        <IssueTile label="Priced on its own page" loading={!ready}
          headline={fmtInt(elsewhere.length)} unit={`of ${fmtInt(worklist.length)} waste checks`}
          base="Their $ is saving, spend or a figure for scale, so it is not added here."
          cause={homes.length ? `Shown on ${homeList}.` : null} onOpen={() => scrollToAnchor("wu-elsewhere")} openLabel={`The ${fmtInt(elsewhere.length)} ↓`} />
      </div>
      {ready && (
        <div className={`cx-note${notRun.length ? "" : " cx-note-ok"}`}>
          {notRun.length ? <InfoMark /> : <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M3 8.5l3.2 3L13 4.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" /></svg>}
          <span>
            {notRun.length
              ? `${fmtInt(notRun.length)} of ${fmtInt(worklist.length)} waste checks did not run: ${notRun.slice(0, 3).map((w) => `${lowerFirstWord(w.title)} (${w.notRunLabel || "did not run"})`).join("; ")}${notRun.length > 3 ? `; and ${fmtInt(notRun.length - 3)} more` : ""}. `
              : `All ${fmtInt(worklist.length)} waste checks ran: ${fmtInt(pricedHere)} priced on the Priced tab, ${fmtInt(unpriced.length)} flagged with no $, ${fmtInt(elsewhere.length)} priced on their own page. `}
            <button type="button" className="cx-link" onClick={() => goTo({ tab: "coverage" })}>Coverage →</button>
          </span>
        </div>
      )}

      <div id="wu-list">
        <PatternCard title="Flagged, no $ figure" sub={`${fmtInt(unpriced.length)} checks · share of each check's own objects flagged, worst first · no source prices them`}>
          {!ready ? <div className="chart-note-oneline">…</div> : unpriced.length === 0
            ? <div className="chart-note-oneline">Nothing flagged without a $ figure in the checks that ran.</div>
            : (
              <CxTable aria="Flagged checks with no $ figure" phone={{ cols: [1, 3], widths: "minmax(0, 1fr) 110px" }} minWidth={760}
                cols={[{ label: "Severity", width: "96px" }, { label: "Check", width: "minmax(240px, 1fr)" }, { label: "Flagged", width: "150px" }, { label: "Share flagged", width: "200px" }, { label: "", width: "64px", num: true }]}
                rows={byShare.map((w) => ({
                  key: w.id, onOpen: drawer(w.id), title: w.why || undefined,
                  cells: [<SevWord key="s" band={w.band} />, <span key="t">{w.title}</span>,
                    <span key="f" className="cx-muted">{w.affected ? `${fmtInt(w.affected.flagged)} of ${fmtInt(w.affected.total)} ${w.affected.noun}` : "–"}</span>,
                    affPct(w) != null
                      ? <span key="b" className="cx-impact"><CellBar value={numOrZero(affPct(w))} max={100} /><span className="cx-impact-val" style={{ width: 44 }}>{fmtShare(affPct(w))}</span></span>
                      : <span key="b" className="cx-muted">–</span>,
                    <span key="r" className="cx-link">Rows →</span>],
                }))}
                foot={notFlagged.length > 0 ? <span>{`${fmtInt(notFlagged.length)} more ran and flagged nothing.`}</span> : undefined} />
            )}
        </PatternCard>
      </div>

      {ready && elsewhere.length > 0 && (
        <div id="wu-elsewhere">
          <PatternCard title="Flagged, priced on its own page" sub={`${fmtInt(elsewhere.length)} checks · grouped by what the $ means, largest first · not added here, or to each other`}>
            <CxTable aria="Flagged checks priced on their own page" phone={{ cols: [1, 2], widths: "minmax(0, 1fr) auto" }} minWidth={760}
              cols={[{ label: "Severity", width: "96px" }, { label: "Check", width: "minmax(240px, 1fr)" }, { label: "Amount", width: "96px", num: true }, { label: "What the $ is", width: "130px" }, { label: "Priced on", width: "170px", num: true }]}
              rows={byKind.map((w) => {
                const { home } = openTarget(w.id);
                const m = w.ownMoney!;
                return {
                  key: w.id,
                  cells: [<SevWord key="s" band={w.band} />, <span key="t">{w.title}</span>,
                    <span key="a" className="cx-strong">{fmtMoney(m.usd, 0)}</span>,
                    <span key="k" className="cx-muted">{KIND_WORD[m.kind] || m.kind}</span>,
                    <button key="o" type="button" className="cx-link cx-btn-link" onClick={open(w.id)}>{`${(AREA_REGISTRY[home.tab] || {}).label || "The check"} →`}</button>],
                };
              })}
              foot={<span className="cx-muted">Spend is what the objects billed; saving is what the same work would cost at another setting; a figure for scale is never a finding on its own.</span>} />
          </PatternCard>
        </div>
      )}
    </div>
  );
}

// What each unit means, and how a status reads: the short form; the Guide has the long one.
const DEFINITIONS: { name: string; unit: (w: number) => string; text: string }[] = [
  { name: "Possible waste", unit: (w) => `$ · ${w} days`, text: "Credits a warehouse or feature used with no work to show: idle minutes, runs that changed nothing, retries, failed SQL." },
  { name: "Possible saving", unit: (w) => `$ · ${w} days`, text: "What the same work would have cost at another setting: one size down, one shared warehouse." },
  { name: "Storage that could be freed", unit: () => "$ · per month", text: "Bytes billed monthly that nothing reads: unused tables, stale stage files, Time Travel above policy." },
  { name: "Spend", unit: (w) => `$ · ${w} days · for scale`, text: "What the account was billed. Shown for scale; never a finding itself." },
  { name: "Change", unit: (w) => `% · vs previous ${w} days`, text: "Spend against the previous window of the same length. A rise is not waste until a check says why." },
];
const STATUS_MEANS: { kind: string; text: string }[] = [
  { kind: "critical", text: "Over the check's critical line. Worth a change this week." },
  { kind: "warn", text: "Over the warning line. Worth a look." },
  { kind: "reference", text: "A figure for scale: spend, counts, run times. Not a finding, never coloured." },
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
  const [showAll, setShowAll] = React.useState(false);

  const figs: string[] = [];
  if (wt.waste.usd != null) figs.push(`${fmtMoney(wt.waste.usd, 0)} of possible waste`);
  if (wt.saving.usd != null) figs.push(`${fmtMoney(wt.saving.usd, 0)} of possible saving`);
  if (wt.month.usd != null) figs.push(`${fmtMoney(wt.month.usd, 0)} a month of storage`);
  const figText = figs.length > 1 ? `${figs.slice(0, -1).join(", ")} and ${figs[figs.length - 1]}` : figs[0];
  const sentence = !ready ? "…" : figs.length
    ? `${fmtInt(worklist.length)} waste checks feed three separate figures: ${figText}. They are never added together.`
    : `${fmtInt(worklist.length)} waste checks feed three separate figures, never one total.`;
  React.useEffect(() => { if (setVerdict) setVerdict(sentence); }, [sentence]); // eslint-disable-line react-hooks/exhaustive-deps

  const byUnit = (unit: WasteUnit | null) => worklist.filter((x) => x.unit === unit);
  const box = (unit: WasteUnit, fig: WasteFigure) => (
    <div className="ws-dia-box">
      <div className="ws-dia-title">{`${UNIT_META[unit].title}${unit === "month" ? "" : ` · ${w} days`}`}</div>
      <div className="ws-dia-value">{!ready ? "…" : fig.usd == null ? "–" : fmtMoney(fig.usd, 0)}{ready && unit === "month" && fig.usd != null ? <span className="ws-dia-unit">per month</span> : null}</div>
      <div className="ws-dia-sub">{`${fmtInt(byUnit(unit).length)} checks${unit !== "month" && fig.usd != null && spend ? ` · ${fmtShare(pctOf(fig.usd, spend))} of ${fmtMoney(spend, 0)} spend` : ""}`}</div>
    </div>
  );
  const line = (it: (typeof WASTE_ITEMS)[number]) => {
    const home = AREA_REGISTRY[it.area];
    return <div className="ws-method-line" key={it.id}><span className="mono">{it.id}</span>{` · ${home ? home.label : it.area}: ${it.why}`}</div>;
  };
  const unitRows: { key: string; label: string; entries: WasteEntry[] }[] = [
    { key: "waste", label: `Possible waste · ${w} days`, entries: byUnit("waste") },
    { key: "saving", label: `Possible saving · ${w} days`, entries: byUnit("saving") },
    { key: "month", label: "Storage to free · per month", entries: byUnit("month") },
    { key: "none", label: "Flagged, no $ figure", entries: byUnit(null) },
  ];
  const counts = unitRows.map((u) => ({
    ...u,
    priced: u.entries.filter((x) => x.ran && x.usd != null).length,
    noUsd: u.entries.filter((x) => x.ran && x.isFlagged && x.usd == null).length,
    notRun: u.entries.filter((x) => !x.ran).length,
  }));
  const sum = (k: "priced" | "noUsd" | "notRun") => counts.reduce((n, c) => n + c[k], 0);
  const ranNoUsd = wt.flaggedOnly.length;
  const elsewhereN = wt.flaggedOnly.filter((x) => x.ownMoney).length;
  const noUsdN = byUnit(null).length;
  const floorDays = floor && floor.per_days != null ? Number(floor.per_days) : null;
  const cell = (label: string, value: React.ReactNode, unit: React.ReactNode, text: React.ReactNode, missing?: string) => (
    <div className="cx-fgrid-cell" key={label}>
      <div className="cx-fgrid-label">{label}</div>
      <div className="cx-fgrid-value">{value == null ? <span className="cx-muted">–</span> : value}{value != null && unit ? <span className="cx-fgrid-unit">{unit}</span> : null}</div>
      <div className="cx-fgrid-text">{value == null ? missing : text}</div>
    </div>
  );
  return (
    <div className="sx-page">
      <PatternCard title="Three units, never added" sub={`${fmtInt(worklist.length)} checks · the ≠ is the rule`}
        link="How it works →" onLink={goTo ? () => goTo({ tab: "guide", focusQueryId: "how-money" }) : null}>
        <div className="ws-dia cx-dia" role="img" aria-label="Three money units, never added together">
          {box("waste", wt.waste)}
          <div className="ws-dia-sep" aria-hidden="true">≠</div>
          {box("saving", wt.saving)}
          <div className="ws-dia-sep" aria-hidden="true">≠</div>
          {box("month", wt.month)}
        </div>
        <div className="ws-dia-foot">Waste is credits already burned with nothing to show. Saving is what the same work would cost at another setting, so part of it is also waste: adding them would count the idle hour twice. Storage is per month, not per window.</div>
      </PatternCard>

      <div className="cx-row">
        <PatternCard title="Definitions" sub="What each unit means, and what it is measured in">
          <div className="cx-defs">
            {DEFINITIONS.map((d) => (
              <div className="cx-def" key={d.name}>
                <div className="cx-def-head"><b>{d.name}</b><span className="cx-muted">{d.unit(w)}</span></div>
                <div className="cx-def-text">{d.text}</div>
              </div>
            ))}
          </div>
        </PatternCard>
        <PatternCard title="What a status means" sub="Colour is severity, never size. Bars stay neutral; the status lives on the dot or the pill.">
          <div className="cx-defs">
            {STATUS_MEANS.map((s) => (
              <div className="cx-stat" key={s.kind}>
                <span>{s.kind === "reference" || s.kind === "ok" ? <SevWord kind={s.kind} /> : <StatusPill kind={s.kind} />}</span>
                <span>{s.text}</span>
              </div>
            ))}
          </div>
        </PatternCard>
      </div>

      <PatternCard title="The floor, and what is not counted" sub={floor && floor.min != null ? `A flagged row is priced only when it is worth at least ${fmtMoney(floor.min, 0)}; under that it stays flagged, not priced` : "A flagged row under the materiality floor stays flagged, not priced"}>
        <div className="cx-fgrid" role="list" aria-label="The floor and what is not counted">
          {cell("Floor", floor && floor.min != null ? fmtMoney(floor.min, 0) : null, floorDays ? `per ${fmtInt(floorDays)} days` : null, floor && floor.label ? String(floor.label) : null, ready ? "No floor reported." : "…")}
          {cell("Rows under the floor", wt.belowFloorUsd != null ? fmtInt(wt.belowFloorRows) : null, "rows", wt.belowFloorUsd != null ? `${fmtMoney(wt.belowFloorUsd, 0)} flagged, not priced.` : null, "…")}
          {cell("Checks with no $", ready ? `${fmtInt(noUsdN)} of ${fmtInt(worklist.length)}` : null, "checks", `Counted as checks; ${fmtInt(ranNoUsd)} flagged.`, "…")}
          {cell("Did not run", ready ? `${fmtInt(wt.notRun.length)} of ${fmtInt(worklist.length)}` : null, "checks", 'Would read "–" and stay out of every total.', "…")}
          {cell("Effective $ per credit", price != null ? fmtMoney(price, 2) : null, "per credit", priceBasisText(meta || null) ? `${priceBasisText(meta || null)}.` : null, "No credit price in this export.")}
          {cell("Storage rate", storagePrice != null ? fmtMoney(storagePrice, 0) : null, "per TB a month", "Used to price storage that could be freed.", "No storage price in this export.")}
        </div>
      </PatternCard>

      <PatternCard title={`The ${fmtInt(worklist.length)} checks behind the figures`} sub="By unit: how many are priced, flagged with no $, or did not run">
        <CxTable aria="Checks behind the figures, by unit" phone={{ cols: [0, 1, 2, 3, 4], widths: "minmax(0, 1fr) 46px 56px 48px 46px" }} minWidth={560}
          cols={[{ label: "Unit", width: "minmax(180px, 1fr)" }, { label: "Priced", width: "90px", num: true }, { label: "Flagged, no $", width: "110px", num: true }, { label: "Did not run", width: "100px", num: true }, { label: "Checks", width: "80px", num: true }]}
          rows={[
            ...counts.map((c) => ({ key: c.key, cells: [c.label, fmtInt(c.priced), fmtInt(c.noUsd), fmtInt(c.notRun), <b key="n">{fmtInt(c.entries.length)}</b>] })),
            { key: "all", cells: [<b key="l">All waste checks</b>, <b key="p">{fmtInt(sum("priced"))}</b>, <b key="u">{fmtInt(sum("noUsd"))}</b>, <b key="r">{fmtInt(sum("notRun"))}</b>, <b key="n">{fmtInt(worklist.length)}</b>] },
          ]}
          foot={ready ? <span className="cx-muted">{`${wt.notRun.length ? `${fmtInt(wt.notRun.length)} of ${fmtInt(worklist.length)} checks did not run.` : "Every check ran."} Of the ${fmtInt(noUsdN)} with no $ here, ${fmtInt(elsewhereN)} are priced on their own page; see Flagged, not priced.`}</span> : undefined} />
      </PatternCard>

      <PatternCard title="Every check, by unit" sub={`All ${fmtInt(WASTE_ITEMS.length)} checks with their unit and home page`}
        link={showAll ? "Hide ▴" : "Show ▾"} onLink={() => setShowAll(!showAll)}>
        {showAll && (
          <div className="ws-method-list">
            <div className="section-title">Possible waste</div>{WASTE_ITEMS.filter((it) => wasteUnitOf(it) === "waste").map(line)}
            <div className="section-title">Possible saving from resizing</div>{WASTE_ITEMS.filter((it) => wasteUnitOf(it) === "saving").map(line)}
            <div className="section-title">Storage, per month</div>{WASTE_ITEMS.filter((it) => wasteUnitOf(it) === "month").map(line)}
            <div className="section-title">Flagged, no $ figure</div>{WASTE_ITEMS.filter((it) => wasteUnitOf(it) === null).map(line)}
          </div>
        )}
      </PatternCard>
    </div>
  );
}

AreaContent.register("waste", "priced", WastePricedContent);
AreaContent.register("waste", "unpriced", WasteUnpricedContent);
AreaContent.register("waste", "method", WasteMethodContent);
