// AI > Cortex: Cortex Analyst, Agents, Cortex Code and CoWork: one strip cell per product, then one
// panel of who uses them (top agents, Cortex Code clients, spend by user).
import React from "react";
import "../styles/css/p_ai_cortex_agents.css";
import { fmtDayShort, fmtInt, fmtMoney } from "../format";
import { fmtChangePct, numOrZero } from "./hooks";
import { ChartCard, noDataText } from "./primitives";
import { DrawerBus } from "./drawer";
import { StackedShareBar } from "./blocks";
import type { ShareSegment } from "./blocks";
import { dtChip, groupBy, isFlagged, isPriced, sumCol, useCheck } from "./area_ai_storage";
import type { Chk } from "./area_ai_storage";
import { CxBars, CxEmpty, CxRow2, CxTable } from "./cx_c";
import type { CxStripCell } from "./cx_c";
import type { ApPageProps } from "./area_pages";
import type { Row } from "../types";

const ANALYST = "sf_ai_cortex_analyst_spend";
const AGENT = "sf_ai_agent_spend";
const CODE = "sf_ai_cortex_code_spend";
const COWORK = "sf_ai_cowork_spend";

// Cortex Code rows are often a few thousandths of a credit: rounding them to 0 would read as no use.
function fmtCr(v: number, unit = true): string {
  if (!Number.isFinite(v)) return "–";
  const a = Math.abs(v);
  const n = a >= 100 ? fmtInt(Math.round(v)) : a >= 1 ? v.toFixed(1) : a === 0 ? "0" : v.toPrecision(2);
  return unit ? `${n} credits` : n;
}

/** "+40%", "new" or null, on credits of any size (fmtChange treats under 1 credit as nothing). */
function changeText(cur: number, prev: number): string | null {
  if (prev > 0) return fmtChangePct(((cur - prev) / prev) * 100);
  return cur > 0 ? "new" : null;
}

/** Spend of rows in $ (after the what-if discount) when priced, else credits; never mixed. */
function spend(rows: Row[], disc: number) {
  const priced = isPriced(rows);
  const cur = (r: Row) => (priced ? numOrZero(r.est_current_usd_list) * (1 - disc) : numOrZero(r.current_credits));
  const prev = (r: Row) => (priced ? numOrZero(r.est_previous_usd_list) * (1 - disc) : numOrZero(r.previous_credits));
  return { priced, cur, prev, fmt: (v: number) => (priced ? fmtMoney(v, 0) : fmtCr(v)) };
}

/** One product's strip cell: spend, users, change vs before and one line of detail. */
function productCell(key: string, label: string, c: Chk, line: (rows: Row[]) => React.ReactNode): CxStripCell {
  const base = { key, label, onOpen: c.open };
  if (c.loading) return { ...base, value: null, loading: true };
  if (c.why || !c.rows) return { ...base, value: null, missing: c.why, status: c.empty ? null : "not_assessed" };
  const rows = c.rows;
  const s = spend(rows, c.disc);
  const cur = rows.reduce((a, r) => a + s.cur(r), 0);
  const prev = rows.reduce((a, r) => a + s.prev(r), 0);
  const users = new Set(rows.filter((r) => numOrZero(r.current_credits) > 0).map((r) => String(r.user_name))).size;
  const flagged = rows.filter(isFlagged).length;
  const ch = changeText(cur, prev);
  return {
    ...base,
    value: s.priced ? fmtMoney(cur, 0) : fmtCr(cur), unit: `${fmtInt(users)} user${users === 1 ? "" : "s"}`,
    lines: [[ch ? `${ch} vs before` : null, flagged ? `${fmtInt(flagged)} row${flagged === 1 ? "" : "s"} flagged` : null].filter(Boolean).join(" · ") || null, line(rows)],
  };
}

/** "5,007 requests at 0.051 credits each."; null when the check counts no requests. */
function perRequest(rows: Row[], reqCol: string): string | null {
  const req = sumCol(rows, reqCol);
  return req > 0 ? `${fmtInt(req)} requests at ${fmtCr(sumCol(rows, "current_credits") / req)} each.` : null;
}

// Cortex Code's window ends :settle_days (SQL default 1) before the others, to tie to the bill.
const CODE_SETTLE_DAYS = 1;
function codeLastDay(asOf: any): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(asOf || ""));
  if (!m) return null;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3] - 1 - CODE_SETTLE_DAYS));
  return fmtDayShort(d.toISOString().slice(0, 10));
}

const PRODUCTS = "Cortex Analyst, Agents, Code and CoWork";

const SURFACE_LABEL: Record<string, string> = { CLI: "CLI", DESKTOP: "Desktop", SNOWSIGHT: "Snowsight" };
const surfaceOf = (r: Row) => SURFACE_LABEL[String(r.surface || "").toUpperCase()] || String(r.surface || "unknown");

export interface CortexProducts { analyst: Chk; agent: Chk; code: Chk; cowork: Chk }

/** The four product checks, read once by the page for both the strip and the panel. */
export function useCortexProducts(p: ApPageProps): CortexProducts {
  return { analyst: useCheck(p, ANALYST), agent: useCheck(p, AGENT), code: useCheck(p, CODE), cowork: useCheck(p, COWORK) };
}

/** The products' cells for the page's KPI strip: spend per product, never added across products. */
export function cortexProductCells(p: ApPageProps, k: CortexProducts): CxStripCell[] {
  return [
    productCell("analyst", "Cortex Analyst", k.analyst, (r) => perRequest(r, "current_requests") || "No requests counted."),
    productCell("agents", "Cortex Agents", k.agent, (r) => {
      const agents = new Set(r.map((x) => String(x.agent_name))).size;
      const req = sumCol(r, "current_requests");
      return `${fmtInt(agents)} agent${agents === 1 ? "" : "s"}${req > 0 ? ` at ${fmtCr(sumCol(r, "current_credits") / req)} per request` : ""}.`;
    }),
    productCell("code", "Cortex Code", k.code, (rows) => {
      // The billed total is a tie-out on the data, never added to spend.
      const totals = (k.code.allRows || []).filter((r) => r.is_total_row && r.billed_credits != null);
      const tokens = sumCol(rows, "current_tokens");
      const last = codeLastDay(p.meta && p.meta.as_of_date);
      const to = last ? ` to ${last}, the last day left out to tie to the bill` : "";
      return totals.length ? `${fmtInt(tokens)} tokens${to}; bill ${fmtCr(sumCol(totals, "billed_credits"))}.` : `${fmtInt(tokens)} tokens${to}; no billed total.`;
    }),
    productCell("cowork", "Snowflake CoWork", k.cowork, (r) => perRequest(r, "requests") || "No requests counted."),
  ];
}

export function CortexAgentsPanel({ p, k }: { p: ApPageProps; k: CortexProducts }) {
  const { analyst, agent, code, cowork } = k;
  const all = [analyst, agent, code, cowork];
  const loading = all.some((c) => c.loading);
  // One line only when no product was used in the window; a filter-excluded check keeps its reason.
  const noUse = (c: Chk) => (c.empty && !!c.why && c.why.startsWith("No data for this")) || (c.rows !== null && c.rows.length === 0);
  if (!loading && all.every(noUse)) return <CxEmpty title={`Who uses ${PRODUCTS}`} reason={noDataText(p.meta, p.filters.window)} />;
  const anyPriced = all.some((c) => c.rows && c.rows.length && isPriced(c.rows));
  const unpricedNote = all.some((c) => c.rows && c.rows.length && !isPriced(c.rows)) ? " · $ –: no credit price in this export" : "";
  const sub = (c: Chk) => (c.loading ? <div className="chart-note-oneline">…</div>
    : c.why || !c.rows ? <div className="chart-note-oneline">{c.empty ? c.why : `– ${c.why}`}</div> : null);

  return (
    <ChartCard title={`Who uses ${PRODUCTS}`}
      subtitle={`${anyPriced ? "Spend" : "Token credits"} this period vs the one before · per product, never added across products${unpricedNote}`}
      takeaway={null}>
      <CxRow2>
        <div className="cxa-block">
          <div className="b2-eyebrow cxa-block-title">Top agents</div>
          {sub(agent) || <TopAgents rows={agent.rows!} c={agent} />}
        </div>
        <div className="cxa-block">
          <div className="b2-eyebrow cxa-block-title">Cortex Code by client</div>
          {sub(code) || <ClientSplit rows={code.rows!} c={code} />}
        </div>
      </CxRow2>
      <div className="cxa-block cxa-users">
        <div className="b2-eyebrow cxa-block-title">Spend by user</div>
        {loading ? <div className="chart-note-oneline">…</div> : <UserTable p={p} checks={k} />}
      </div>
    </ChartCard>
  );
}

function TopAgents({ rows, c }: { rows: Row[]; c: Chk }) {
  const s = spend(rows, c.disc);
  const list = groupBy(rows, (r) => String(r.agent_name || "unknown"), s.cur, s.prev).filter((x) => x.value > 0).sort((a, b) => b.value - a.value);
  if (!list.length) return <div className="chart-note-oneline">No agent spent credits in this window.</div>;
  return (
    <CxBars aria="Top Cortex Agents" n={5}
      rows={list.map((x) => {
        // Same count as the strip: users with credits in this window.
        const users = new Set(rows.filter((r) => String(r.agent_name || "unknown") === x.name && numOrZero(r.current_credits) > 0).map((r) => String(r.user_name))).size;
        const ch = changeText(x.value, x.prev);
        return {
          key: x.name, name: x.name, value: x.value, status: x.status,
          cells: [s.fmt(x.value), ch, `${fmtInt(users)} user${users === 1 ? "" : "s"}`].filter((v): v is string => !!v),
          onOpen: () => DrawerBus.open({ id: AGENT, col: "agent_name", val: String(x.name), label: String(x.name) }),
        };
      })} />
  );
}

function ClientSplit({ rows, c }: { rows: Row[]; c: Chk }) {
  const s = spend(rows, c.disc);
  const by = groupBy(rows, surfaceOf, s.cur, s.prev).sort((a, b) => b.value - a.value);
  const colors: Record<string, string> = { CLI: "var(--c1)", Desktop: "var(--c2)", Snowsight: "var(--c3)" };
  const segs: ShareSegment[] = by.map((x) => ({ key: x.name, label: x.name, value: x.value, color: colors[x.name] }));
  // The change follows the value ("0.0021 credits · new"), not the client name.
  const chOf = new Map(by.map((x) => [x.value, changeText(x.value, x.prev)] as const));
  const fmt = (v: number) => { const ch = chOf.get(v); return ch ? `${s.fmt(v)} · ${ch}` : s.fmt(v); };
  return <StackedShareBar segments={segs} valueFmt={fmt} ariaLabel="Cortex Code spend by client" />;
}

/** One row per product and user: products are never summed into one figure. */
function UserTable({ p, checks }: { p: ApPageProps; checks: CortexProducts }) {
  type U = { key: string; id: string; product: string; user: string; cur: number; prev: number; credits: number; usd: number | null; req: number | null; status: string };
  const out: U[] = [];
  const add = (c: Chk, id: string, product: (r: Row) => string, reqCol: string | null) => {
    if (!c.rows) return;
    const priced = isPriced(c.rows);
    const g = new Map<string, U>();
    const rank: Record<string, number> = { CRITICAL: 3, WARN: 2, NOT_ASSESSED: 1 };
    c.rows.forEach((r) => {
      const prod = product(r);
      const k = `${prod}|${r.user_name}`;
      const u = g.get(k) || { key: `${id}|${k}`, id, product: prod, user: String(r.user_name || "unknown"), cur: 0, prev: 0, credits: 0, usd: priced ? 0 : null, req: reqCol ? 0 : null, status: "OK" };
      u.credits += numOrZero(r.current_credits);
      u.cur += numOrZero(r.current_credits);
      u.prev += numOrZero(r.previous_credits);
      if (u.usd !== null) u.usd += numOrZero(r.est_current_usd_list) * (1 - c.disc);
      if (u.req !== null && reqCol) u.req += numOrZero(r[reqCol]);
      if ((rank[r.status] || 0) > (rank[u.status] || 0)) u.status = r.status;
      g.set(k, u);
    });
    out.push(...g.values());
  };
  add(checks.analyst, ANALYST, () => "Analyst", "current_requests");
  add(checks.agent, AGENT, () => "Agents", "current_requests");
  add(checks.code, CODE, (r) => `Code · ${surfaceOf(r)}`, null);
  add(checks.cowork, COWORK, () => "CoWork", "requests");
  const list = out.filter((u) => u.credits > 0 || u.prev > 0).sort((a, b) => b.credits - a.credits);
  return (
    <CxTable aria={`${PRODUCTS} spend by user`} n={10} minWidth={640}
      empty={noDataText(p.meta, p.filters.window)}
      cols={[{ label: "User · product" }, { label: "$", num: true, width: "auto" }, { label: "Credits", num: true, width: "auto" },
        { label: "Change", num: true, width: "minmax(64px, auto)" }, { label: "Credits / request", num: true, width: "auto" }]}
      rows={list.map((u) => {
        const ch = changeText(u.cur, u.prev);
        return {
          key: u.key, status: u.status,
          onOpen: () => DrawerBus.open({ id: u.id, col: "user_name", val: u.user, label: u.user }),
          cells: [<span key="u">{u.user} <span className="cx-sub">· {u.product}</span></span>,
            u.usd === null ? <span title="No credit price in this export">–</span> : fmtMoney(u.usd, 0), fmtCr(u.credits, false),
            ch ? (u.status === "CRITICAL" || u.status === "WARN" ? dtChip(ch, u.status) : ch) : "–",
            u.req ? fmtCr(u.credits / u.req, false) : "–"],
        };
      })} />
  );
}
