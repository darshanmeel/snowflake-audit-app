// web/src/components/wh_idle_detail.tsx -- one warehouse's idle time in detail: the Top 5 offenders rows
// under Busy vs idle and the Idle drawer block. Running and idle hours are parts of the warehouse's own
// spend; each auto-suspend option's saving is an estimate shown on its own, never added to the idle $.
import React from "react";
import { fmtInt, fmtMoney } from "../format";
import { numOrZero, useFindingData } from "./hooks";
import { DrawerBus, useDrawer } from "./drawer";
import { registerDrawerBlock } from "./drawer_blocks";
import { WarehouseHoursPerDay } from "./run_blocks";
import type { DrawerBlockProps } from "./drawer";
import { fmtShare, statusBarColor } from "./blocks";
import type { FetchState, Meta, Row } from "../types";

// The options replayed by sf_wh_auto_suspend_tuning, in seconds.
export const SUSPEND_OPTIONS = [60, 120, 300, 600];
const IDLE_ID = "sf_wh_idle_minutes";
const TUNE_ID = "sf_wh_auto_suspend_tuning";
const MC_ID = "sf_wh_multicluster_scaling";
// Gen2 bills this much more per hour than Gen1 (Service Consumption Table; 1.25 on Azure).
const GEN2_RATE = 1.35;

export function suspendText(s: number | null | undefined): string {
  if (s == null || s <= 0) return "off";
  return s < 120 ? `${fmtInt(s)} s` : `${fmtInt(Math.round(s / 60))} min`;
}
/** Minutes as hours: one decimal under 10 h. */
export function hrs(min: number | null | undefined): string {
  const h = numOrZero(min) / 60;
  if (h > 0 && h < 0.1) return "<0.1 h";
  return `${h < 10 ? h.toFixed(1) : fmtInt(Math.round(h))} h`;
}

export interface SuspendOption {
  s: number; idleMin: number | null; resumes: number | null; extra: number | null;
  savedMin: number | null; savingUsd: number | null; longer: boolean; recommended: boolean;
}

/** The replayed options of one tuning row; a saving $ only where the export kept one (flagged rows). */
export function suspendOptions(t: Row, disc: number): SuspendOption[] {
  // A setting under 60 s is replayed as 60 s; off never suspends.
  const cur = t.auto_suspend_s == null || numOrZero(t.auto_suspend_s) <= 0 ? null : Math.max(60, numOrZero(t.auto_suspend_s));
  return SUSPEND_OPTIONS.map((s) => {
    const idle = t[`idle_min_${s}s`], res = t[`suspends_${s}s`], usd = t[`est_saving_${s}s_usd_list`];
    return {
      s, idleMin: idle == null ? null : Number(idle), resumes: res == null ? null : Number(res),
      extra: res == null || t.suspends_now == null ? null : Number(res) - Number(t.suspends_now),
      savedMin: idle == null || t.idle_min_now == null ? null : Math.max(0, Number(t.idle_min_now) - Number(idle)),
      savingUsd: usd == null ? null : Number(usd) * (1 - disc),
      longer: cur != null && s >= cur, recommended: t.recommended_auto_suspend_s != null && Number(t.recommended_auto_suspend_s) === s,
    };
  });
}

/** "Keep warm?" in one line, from the warehouse cache share, repeats and the median gap. */
export function cacheVerdict(t: Row | null | undefined): { verdict: string; line: string } | null {
  if (!t) return null;
  const cache = t.cache_pct_weighted, rep = t.repeat_share_pct, gap = t.median_gap_s;
  const facts = [
    cache != null ? `${fmtShare(Number(cache))} of scanned bytes from the warehouse cache` : null,
    rep != null ? `${fmtShare(Number(rep))} of queries repeat a shape` : null,
    gap != null ? `median gap ${suspendText(Math.round(Number(gap)))}` : null,
  ].filter(Boolean).join(" · ");
  if (t.keep_warm === "keep_warm") return { verdict: "Keep warm: 5 min", line: `${facts}. A suspend empties that cache, so the next queries read from storage again.` };
  if (t.keep_warm === "suspend_sooner") return { verdict: "Suspend sooner", line: `${facts}. Little is lost when the cache empties.` };
  return facts ? { verdict: "Cache: too few scans to judge", line: facts } : null;
}

function resultCacheLine(t: Row): string | null {
  return t.result_cache_pct != null ? `Result cache: ${fmtShare(Number(t.result_cache_pct))} of SELECTs; it survives a suspend.` : null;
}

function resumeLine(t: Row): string | null {
  const parts = [
    t.observed_resumes != null ? `${fmtInt(t.observed_resumes)} resumes` : null,
    t.resume_p50_s != null ? `each took ${secs(t.resume_p50_s)} (p95 ${secs(t.resume_p95_s)})` : null,
    t.resume_wait_p95_s != null && numOrZero(t.resume_waits) > 0 ? `${fmtInt(t.resume_waits)} queries waited, p95 ${secs(t.resume_wait_p95_s)}` : null,
  ].filter(Boolean);
  return parts.length ? parts.join(" · ") : null;
}
function secs(v: any): string {
  const n = numOrZero(v);
  return n >= 120 ? `${(n / 60).toFixed(1)} min` : `${n >= 10 ? Math.round(n) : n.toFixed(1)} s`;
}

/** "Medium · Gen1 · 4 credits/h · up to 3 clusters": the size it is billed at now. */
function sizingLine(t: Row): string | null {
  const gen = t.warehouse_generation === "GEN2" ? "Gen2" : t.warehouse_generation === "SNOWPARK_OPTIMIZED" ? "Snowpark-optimized" : t.warehouse_generation === "GEN1" ? "Gen1" : null;
  const parts = [
    String(t.warehouse_type || "").toUpperCase() === "ADAPTIVE" ? "Adaptive" : t.warehouse_size,
    gen, t.credits_per_hour != null ? `${fmtInt(t.credits_per_hour)} credits/h` : null,
    numOrZero(t.max_clusters) > 1 ? `up to ${fmtInt(t.max_clusters)} clusters` : null,
  ].filter(Boolean);
  return parts.length ? parts.join(" · ") : null;
}

const BIG = /^(5|6)X-?LARGE$|^X{5,6}LARGE$/i;
function isStandard(t: Row) { return String(t.warehouse_type || "STANDARD").toUpperCase() === "STANDARD"; }
function isBig(t: Row) { return BIG.test(String(t.warehouse_size || "").replace(/\s/g, "")); }

/** Gen2 runs delete, update and merge faster but bills more per hour: hinted where those dominate. */
export function gen2Hint(t: Row | null | undefined): string | null {
  if (!t || !isStandard(t) || isBig(t) || t.warehouse_generation !== "GEN1" || numOrZero(t.dml_exec_pct) < 50) return null;
  return `Gen2: ${fmtShare(numOrZero(t.dml_exec_pct))} of its run time is delete, update and merge, which Gen2 runs faster. It bills ${GEN2_RATE}× per hour (1.25× on Azure), so it pays only if those runs finish over a quarter sooner: test it first.`;
}

/** "Consider adaptive" only where at least two signals in the data point to it. */
export function adaptiveHint(t: Row | null | undefined, idle: Row | null | undefined, mc: Row | null | undefined, meta: Meta | null | undefined, windowDays: number): string | null {
  if (!t) return null;
  if (String(t.warehouse_type || "").toUpperCase() === "ADAPTIVE") return "Adaptive: Snowflake does not split its time into busy and idle; its per-query credits are in Adaptive spend by user.";
  if (!isStandard(t) || isBig(t)) return null;
  const e = meta && meta.edition;
  const ed = String((e && typeof e === "object" ? e.edition : e) || "").toUpperCase();
  if (ed === "STANDARD") return null;
  const signals = [
    idle && numOrZero(idle.idle_share_pct) >= 30 ? `${fmtShare(numOrZero(idle.idle_share_pct))} idle` : null,
    windowDays > 0 && numOrZero(t.observed_resumes) / windowDays >= 10 ? `${fmtInt(Math.round(numOrZero(t.observed_resumes) / windowDays))} resumes a day` : null,
    numOrZero(t.manual_resizes) >= 2 ? `${fmtInt(t.manual_resizes)} manual resizes` : null,
    mc && numOrZero(mc.queued_pct) >= 5 && numOrZero(mc.max_cluster_seen) >= Math.max(1, numOrZero(mc.max_clusters)) ? `${fmtShare(numOrZero(mc.queued_pct))} queued at max clusters` : null,
  ].filter(Boolean);
  if (signals.length < 2) return null;
  return `Consider adaptive: ${signals.join(", ")}. An adaptive warehouse sizes and suspends itself and bills per query${ed ? "" : " (needs Enterprise edition)"}.`;
}

// ═══════════════════════ shared pieces ═══════════════════════

/** Running queries vs idle, as one bar with hours and $ per part (both parts of the warehouse's spend). */
function HoursSplit({ busyMin, idleMin, spendUsd, busyUsd, idleUsd, gaps }: { busyMin: number; idleMin: number; spendUsd: number | null; busyUsd: number | null; idleUsd: number | null; gaps?: string | null }) {
  const total = busyMin + idleMin;
  if (total <= 0) return <div className="chart-note-oneline">No running time in this window.</div>;
  const ip = (idleMin / total) * 100;
  return (
    <div className="ac-hours">
      <div className="ac-hours-top">
        <span><b className="mono">{hrs(total)}</b>{spendUsd != null ? ` (${fmtMoney(spendUsd, 0)})` : ""} running</span>
        <span><b className="mono">{fmtShare(ip)}</b> idle</span>
      </div>
      <div className="ac-hours-bar" role="img" aria-label={`${fmtShare(100 - ip)} running queries, ${fmtShare(ip)} idle`}>
        <span style={{ width: `${100 - ip}%`, background: "var(--c1)" }} />
        <span style={{ width: `${ip}%`, background: "var(--c-other)" }} />
      </div>
      <div className="ac-hours-legend">
        <span><i style={{ background: "var(--c1)" }} /><b className="mono">{hrs(busyMin)}</b>{busyUsd != null ? ` (${fmtMoney(busyUsd, 0)})` : ""} running queries</span>
        <span><i style={{ background: "var(--c-other)" }} /><b className="mono">{hrs(idleMin)}</b>{idleUsd != null ? ` (${fmtMoney(idleUsd, 0)})` : ""} idle</span>
      </div>
      {gaps && <div className="ac-hours-gaps">{gaps}</div>}
    </div>
  );
}

// Why the replay skipped a warehouse, from the check's not_assessed_reason codes.
const TUNE_SKIP: Record<string, string> = { too_few_gaps: "too few idle gaps to replay", unknown_size: "size unknown, so no credits per hour" };
function tuneSkipped(t: Row): string | null {
  if (t.status !== "NOT_ASSESSED") return null;
  const code = String(t.not_assessed_reason || "");
  return `Not assessed: ${TUNE_SKIP[code] || code.replace(/_/g, " ") || "the replay skipped it"}`;
}

function gapsText(t: Row | null | undefined): string | null {
  if (!t || t.gaps == null || t.status === "NOT_ASSESSED") return null;
  return `${fmtInt(t.gaps)} idle gaps between queries · median ${suspendText(Math.round(numOrZero(t.median_gap_s)))} · longest ${hrs(t.longest_gap_min)}`;
}

/** The options grid: setting · idle left · saves · resumes. Options at or above the current setting read "longer". */
function OptionsGrid({ t, disc, windowDays, compact }: { t: Row; disc: number; windowDays: number; compact?: boolean }) {
  const skipped = tuneSkipped(t);
  if (skipped) return <div className="ac-change-none">{skipped}</div>;
  const all = suspendOptions(t, disc);
  const opts = compact ? all.filter((o) => !o.longer) : all;
  const cur = t.auto_suspend_s == null || numOrZero(t.auto_suspend_s) <= 0 ? null : numOrZero(t.auto_suspend_s);
  if (!opts.length) return <div className="ac-change-none">{`Auto-suspend already ${suspendText(cur)}`}</div>;
  return (
    <div className="ac-change-box">
      <div className="ac-change-title">{`Auto-suspend ${suspendText(cur)} now · options`}</div>
      <div className={`ac-change-grid${compact ? "" : " full"}`} role="table" aria-label="Auto-suspend options">
        <span className="ac-change-head" role="columnheader">set to</span>
        {!compact && <span className="ac-change-head" role="columnheader">idle left</span>}
        <span className="ac-change-head" role="columnheader">saves</span>
        <span className="ac-change-head" role="columnheader">resumes</span>
        {opts.map((o) => (
          <React.Fragment key={o.s}>
            <span className={`ac-change-to${o.recommended ? " rec" : ""}`} role="cell">{`${suspendText(o.s)}${o.recommended ? " ✓" : ""}`}</span>
            {!compact && <span className="ac-change-starts mono" role="cell">{o.idleMin != null ? hrs(o.idleMin) : "–"}</span>}
            <span className="ac-change-usd mono" role="cell" title={o.savingUsd == null && o.savedMin != null ? "no $: under the flag line or not priced" : undefined}>
              {o.longer ? "longer" : o.savingUsd != null ? `−${fmtMoney(o.savingUsd, 0)}` : o.savedMin != null ? `−${hrs(o.savedMin)}` : "–"}
            </span>
            <span className="ac-change-starts mono" role="cell">{o.extra == null ? "–" : `${o.extra > 0 ? "+" : ""}${fmtInt(o.extra)}`}</span>
          </React.Fragment>
        ))}
      </div>
      <div className="ac-change-per">{`estimate · over ${fmtInt(windowDays)} days · ✓ recommended · each resume bills at least 60 s`}</div>
    </div>
  );
}

// ═══════════════════════ Top 5 offenders ═══════════════════════

export interface Offender {
  key: string; id: any; name: string; size: string | null; autoSuspendS: number | null;
  busyMin: number; idleMin: number; spendUsd: number | null; busyUsd: number | null; idleUsd: number | null; status: string; tune: Row | null;
}

/** The five warehouses with the most idle $, in the Databricks row layout: who | hours split | idle $ | change. */
export function TopOffenders({ items, disc, windowDays, n = 5 }: { items: Offender[]; disc: number; windowDays: number; n?: number }) {
  const open = useDrawer();
  const list = items.filter((o) => o.idleMin > 0).slice(0, n);
  if (!list.length) return <div className="chart-note-oneline">No warehouse sat idle in this window.</div>;
  const priced = list.some((o) => o.idleUsd != null);
  const max = Math.max(...list.map((o) => (priced ? numOrZero(o.idleUsd) : o.idleMin)), 1);
  return (
    <div className="ac-off-table" role="table" aria-label="Top idle warehouses">
      <div className="ac-off-row ac-off-headrow" role="row">
        <div className="ac-off-name" role="columnheader">Warehouse</div>
        <div className="ac-off-detail" role="columnheader">How its running hours were spent</div>
        <div className="ac-off-cost" role="columnheader">{priced ? "Idle cost" : "Idle"}</div>
        <div className="ac-off-change" role="columnheader">Recommended change</div>
      </div>
      {list.map((o) => {
        const v = priced ? numOrZero(o.idleUsd) : o.idleMin;
        const isOpen = !!open && open.id === IDLE_ID && open.val === String(o.id);
        const cv = cacheVerdict(o.tune);
        return (
          <div key={o.key} className={`ac-off-row${isOpen ? " selected" : ""}`} role="row">
            <div className="ac-off-name" role="cell">
              <button type="button" className="ac-off-open" aria-pressed={isOpen}
                onClick={() => DrawerBus.open({ id: IDLE_ID, col: o.id != null ? "warehouse_id" : null, val: o.id != null ? String(o.id) : null, label: o.name })}>
                <span className="blk-dot" style={{ background: statusBarColor(o.status) }} aria-hidden="true" />
                <b>{o.name}</b>
              </button>
              <div className="ac-off-sub">
                {o.size && <span className="ac-kind-chip">{o.size}</span>}
                <span>{`Auto-suspend ${suspendText(o.autoSuspendS)}`}</span>
              </div>
            </div>
            <div className="ac-off-detail" role="cell">
              <HoursSplit busyMin={o.busyMin} idleMin={o.idleMin} spendUsd={o.spendUsd} busyUsd={o.busyUsd} idleUsd={o.idleUsd} gaps={gapsText(o.tune)} />
            </div>
            <div className="ac-off-cost" role="cell">
              <div className="ac-off-usd mono">{priced ? (o.idleUsd != null ? fmtMoney(o.idleUsd, 0) : "–") : hrs(o.idleMin)}</div>
              <div className="ac-off-cost-track"><div style={{ width: `${Math.max(2, Math.round((v / max) * 100))}%` }} /></div>
              <div className="ac-off-cost-word">{priced ? "possible waste" : "idle time"}</div>
            </div>
            <div className="ac-off-change" role="cell">
              {o.tune ? <OptionsGrid t={o.tune} disc={disc} windowDays={windowDays} compact /> : <div className="ac-change-none">No replay for this warehouse</div>}
              {cv && <div className="ac-change-cache"><b>{cv.verdict}.</b>{` ${cv.line}`}</div>}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ═══════════════════════ Auto-suspend bands ═══════════════════════

export const SUSPEND_BANDS: { key: string; label: string; color: string; test: (s: number | null) => boolean }[] = [
  { key: "off", label: "Off", color: "var(--st-crit)", test: (s) => s == null || s <= 0 },
  { key: "60", label: "60 s or less", color: "var(--c1)", test: (s) => s != null && s > 0 && s <= 60 },
  { key: "300", label: "1–5 min", color: "var(--c2)", test: (s) => s != null && s > 60 && s <= 300 },
  { key: "600", label: "5–10 min", color: "var(--c3)", test: (s) => s != null && s > 300 && s <= 600 },
  { key: "long", label: "Over 10 min", color: "var(--st-warn)", test: (s) => s != null && s > 600 },
];

// ═══════════════════════ the Idle drawer block ═══════════════════════

function rowsOfState(s: FetchState): Row[] | null {
  return s.phase === "ready" && s.outcome === "ok_rows" && s.data ? (s.data.rows || []).filter((r: Row) => !r.is_total_row) : null;
}

function IdleDrawerBlock({ target, filters, meta }: DrawerBlockProps) {
  const tune = useFindingData(TUNE_ID, filters.window, filters.accountIds, 5000) as FetchState;
  const idle = useFindingData(IDLE_ID, filters.window, filters.accountIds, 5000) as FetchState;
  const mc = useFindingData(MC_ID, filters.window, filters.accountIds, 5000) as FetchState;
  if (target.col !== "warehouse_id" || target.val == null) return null;
  const same = (r: Row) => String(r.warehouse_id) === target.val;
  const iRows = rowsOfState(idle), tRows = rowsOfState(tune);
  const ir = iRows ? iRows.find(same) || null : null;
  const t = tRows ? tRows.find(same) || null : null;
  const m = (rowsOfState(mc) || []).find(same) || null;
  const iDisc = idle.data ? numOrZero(idle.data.discount_pct) : 0;
  const tDisc = tune.data ? numOrZero(tune.data.discount_pct) : 0;
  const loadingAny = idle.phase === "loading" || tune.phase === "loading";
  const priced = !!ir && ir.price_basis !== "unpriced" && ir.est_usd_list != null;
  const idleUsd = priced && ir!.est_wasted_usd_list != null ? numOrZero(ir!.est_wasted_usd_list) * (1 - iDisc) : null;
  const spendUsd = priced ? numOrZero(ir!.est_usd_list) * (1 - iDisc) : null;
  // The running-queries part of the same spend: the warehouse's $ less its idle part.
  const busyUsd = spendUsd != null && idleUsd != null ? Math.max(spendUsd - idleUsd, 0) : null;
  const tuneWhy = tune.phase === "ready" && tune.outcome !== "ok_rows" ? "the auto-suspend replay did not run in this export" : !t && tRows ? "no replay row for this warehouse" : null;
  const cv = cacheVerdict(t);
  const hints = [t ? gen2Hint(t) : null, adaptiveHint(t, ir, m, meta, filters.window)].filter(Boolean) as string[];
  return (
    <div className="ac-dr">
      {loadingAny && <div className="dr-loading">…</div>}
      {t && sizingLine(t) && <div className="dr-base ac-dr-size">{sizingLine(t)}</div>}
      {ir && (
        <div className="dr-section">
          <div className="dr-eyebrow">Running vs idle</div>
          <HoursSplit busyMin={numOrZero(ir.busy_minutes)} idleMin={numOrZero(ir.idle_minutes)} spendUsd={spendUsd} busyUsd={busyUsd} idleUsd={idleUsd} gaps={gapsText(t)} />
        </div>
      )}
      <WarehouseHoursPerDay warehouseId={target.val} filters={filters} meta={meta} />
      <div className="dr-section">
        <div className="dr-eyebrow">Auto-suspend options · possible saving, not added to idle $</div>
        {t ? <OptionsGrid t={t} disc={tDisc} windowDays={filters.window} />
          : !loadingAny && <div className="dr-note">{`– ${tuneWhy || "no replay for this warehouse"}`}</div>}
      </div>
      {t && (resumeLine(t) || cv) && (
        <div className="dr-section">
          <div className="dr-eyebrow">Resume and cache</div>
          {resumeLine(t) && <div className="ac-dr-line">{resumeLine(t)}</div>}
          {cv && <div className="ac-dr-line"><b>{`${cv.verdict}.`}</b>{` ${cv.line}`}</div>}
          {resultCacheLine(t) && <div className="ac-dr-line muted">{resultCacheLine(t)}</div>}
        </div>
      )}
      {hints.length > 0 && (
        <div className="dr-section">
          <div className="dr-eyebrow">Worth a look</div>
          {hints.map((h) => <div key={h} className="ac-dr-line">{h}</div>)}
        </div>
      )}
    </div>
  );
}

registerDrawerBlock(IDLE_ID, IdleDrawerBlock);
