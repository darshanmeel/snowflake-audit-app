// AI > Cortex: Cortex Analyst, Agents, Cortex Code and CoWork in one panel: spend against the period before, users, agents and clients.
import React from "react";
import "../styles/css/p_ai_cortex_agents.css";
import { fmtDayShort, fmtInt, fmtMoney } from "../format";
import { fmtChangePct, numOrZero } from "./hooks";
import { ChartCard, noDataText } from "./primitives";
import { DrillTable } from "./drill_table";
import { DrawerBus } from "./drawer";
import { SummaryTileRow } from "./overview_tile";
import { StackedShareBar, StatusBars } from "./blocks";
import type { IssueTileProps, ShareSegment, StatusBarItem } from "./blocks";
import { CheckTile, Row2, dtChip, groupBy, isFlagged, isPriced, sumCol, useCheck } from "./area_ai_storage";
import type { Chk } from "./area_ai_storage";
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

function trendOf(cur: number, prev: number, flagged: boolean): IssueTileProps["trend"] {
  const t = changeText(cur, prev);
  if (!t) return null;
  return { text: `${t} vs before`, direction: cur > prev ? "up" : cur < prev ? "down" : "flat", tone: flagged && cur > prev ? "bad" : "neutral" };
}

/** Spend of rows in $ (after the what-if discount) when priced, else credits; never mixed. */
function spend(rows: Row[], disc: number) {
  const priced = isPriced(rows);
  const cur = (r: Row) => (priced ? numOrZero(r.est_current_usd_list) * (1 - disc) : numOrZero(r.current_credits));
  const prev = (r: Row) => (priced ? numOrZero(r.est_previous_usd_list) * (1 - disc) : numOrZero(r.previous_credits));
  return { priced, cur, prev, fmt: (v: number) => (priced ? fmtMoney(v, 0) : fmtCr(v)) };
}

/** One product's tile: spend, change vs before, distinct users, and one line of detail. */
function productTile(rows: Row[], c: Chk, line: (rows: Row[]) => React.ReactNode): Partial<IssueTileProps> {
  const s = spend(rows, c.disc);
  const cur = rows.reduce((a, r) => a + s.cur(r), 0);
  const prev = rows.reduce((a, r) => a + s.prev(r), 0);
  const users = new Set(rows.filter((r) => numOrZero(r.current_credits) > 0).map((r) => String(r.user_name))).size;
  const flagged = rows.filter(isFlagged).length;
  return {
    // Unit inside the headline: a cut-off headline must not lose its unit.
    headline: s.priced ? fmtMoney(cur, 0) : fmtCr(cur),
    trend: trendOf(cur, prev, flagged > 0),
    base: `${fmtInt(users)} user${users === 1 ? "" : "s"}${flagged ? ` · ${fmtInt(flagged)} rows flagged` : ""}`,
    cause: line(rows),
  };
}

/** Credits per request over the product's rows; null when the check counts no requests. */
function perRequest(rows: Row[], reqCol: string): string | null {
  const req = sumCol(rows, reqCol);
  return req > 0 ? `${fmtCr(sumCol(rows, "current_credits") / req)} per request · ${fmtInt(req)} requests` : null;
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

export function CortexAgentsPanel(p: ApPageProps) {
  const analyst = useCheck(p, ANALYST);
  const agent = useCheck(p, AGENT);
  const code = useCheck(p, CODE);
  const cowork = useCheck(p, COWORK);
  const all = [analyst, agent, code, cowork];
  const loading = all.some((c) => c.loading);
  // One line only when no product was used in the window; a filter-excluded check keeps its tile and reason.
  const noUse = (c: Chk) => (c.empty && !!c.why && c.why.startsWith("No data for this")) || (c.rows !== null && c.rows.length === 0);
  if (!loading && all.every(noUse)) {
    return (
      <ChartCard title={PRODUCTS} subtitle="token credits per product">
        <div className="chart-note-oneline">{noDataText(p.meta, p.filters.window)}</div>
      </ChartCard>
    );
  }
  const anyPriced = all.some((c) => c.rows && c.rows.length && isPriced(c.rows));
  const unpricedNote = all.some((c) => c.rows && c.rows.length && !isPriced(c.rows)) ? " · $ –: no credit price in this export" : "";

  return (
    <div className="cxa-panel">
      <SummaryTileRow compact>
        {/* No status badge: these tiles show spend, not a verdict (unpriced rows are NOT_ASSESSED). */}
        <CheckTile c={analyst} label="Cortex Analyst" build={(rows, c) => productTile(rows, c, (r) => perRequest(r, "current_requests") || "No requests counted")} />
        <CheckTile c={agent} label="Cortex Agents" build={(rows, c) => productTile(rows, c, (r) => {
          const agents = new Set(r.map((x) => String(x.agent_name))).size;
          const per = perRequest(r, "current_requests");
          return `${fmtInt(agents)} agent${agents === 1 ? "" : "s"}${per ? ` · ${per.split(" · ")[0]}` : ""}`;
        })} />
        <CheckTile c={code} label="Cortex Code" build={(rows, c) => productTile(rows, c, () => {
          // The billed total is a tie-out on the data, shown per surface, never added to spend.
          const totals = (c.allRows || []).filter((r) => r.is_total_row && r.billed_credits != null);
          const tokens = sumCol(rows, "current_tokens");
          const last = codeLastDay(p.meta && p.meta.as_of_date);
          const to = last ? ` · to ${last}, last day left out to tie to the bill` : "";
          return totals.length
            ? `${fmtInt(tokens)} tokens · bill ${fmtCr(sumCol(totals, "billed_credits"))}${to}`
            : `${fmtInt(tokens)} tokens · no billed total${to}`;
        })} />
        <CheckTile c={cowork} label="Snowflake CoWork" build={(rows, c) => productTile(rows, c, (r) => perRequest(r, "requests") || "No requests counted")} />
      </SummaryTileRow>

      <ChartCard title={`Who uses ${PRODUCTS}`}
        subtitle={`${anyPriced ? "spend" : "token credits"} this period vs the one before · per product, never added across products${unpricedNote}`}
        takeaway={null}>
        <Row2>
          <div className="cxa-block">
            <div className="b2-eyebrow cxa-block-title">Top agents</div>
            {agent.loading ? <div className="chart-note-oneline">…</div>
              : agent.why || !agent.rows ? <div className="chart-note-oneline">{agent.empty ? agent.why : `– ${agent.why}`}</div>
              : <TopAgents rows={agent.rows} c={agent} />}
          </div>
          <div className="cxa-block">
            <div className="b2-eyebrow cxa-block-title">Cortex Code by client</div>
            {code.loading ? <div className="chart-note-oneline">…</div>
              : code.why || !code.rows ? <div className="chart-note-oneline">{code.empty ? code.why : `– ${code.why}`}</div>
              : <ClientSplit rows={code.rows} c={code} />}
          </div>
        </Row2>
        <div className="cxa-block cxa-users">
          <div className="b2-eyebrow cxa-block-title">Spend by user</div>
          {loading ? <div className="chart-note-oneline">…</div> : <UserTable p={p} checks={{ analyst, agent, code, cowork }} />}
        </div>
      </ChartCard>
    </div>
  );
}

function TopAgents({ rows, c }: { rows: Row[]; c: Chk }) {
  const s = spend(rows, c.disc);
  const items: StatusBarItem[] = groupBy(rows, (r) => String(r.agent_name || "unknown"), s.cur, s.prev)
    .filter((x) => x.value > 0)
    .map((x) => {
      // Same count as the tile: users with credits in this window.
      const users = new Set(rows.filter((r) => String(r.agent_name || "unknown") === x.name && numOrZero(r.current_credits) > 0).map((r) => String(r.user_name))).size;
      const ch = changeText(x.value, x.prev);
      return { key: x.name, name: x.name, value: x.value, status: x.status,
        valueText: [s.fmt(x.value), ch, `${fmtInt(users)} user${users === 1 ? "" : "s"}`].filter(Boolean).join(" · ") };
    });
  return <StatusBars items={items} n={5} unitLabel={s.priced ? "$" : "credits"} ariaLabel="Top Cortex Agents"
    emptyText="No agent spent credits in this window." onBarClick={(it) => DrawerBus.open({ id: AGENT, col: "agent_name", val: String(it.name), label: String(it.name) })} />;
}

function ClientSplit({ rows, c }: { rows: Row[]; c: Chk }) {
  const s = spend(rows, c.disc);
  const by = groupBy(rows, surfaceOf, s.cur, s.prev).sort((a, b) => b.value - a.value);
  const colors: Record<string, string> = { CLI: "var(--c1)", Desktop: "var(--c2)", Snowsight: "var(--c3)" };
  const segs: ShareSegment[] = by.map((x) => {
    return { key: x.name, label: x.name, value: x.value, color: colors[x.name] };
  });
  // The change follows the value ("0.0021 credits · new"), not the client name.
  const chOf = new Map(by.map((x) => [x.value, changeText(x.value, x.prev)] as const));
  const fmt = (v: number) => { const ch = chOf.get(v); return ch ? `${s.fmt(v)} · ${ch}` : s.fmt(v); };
  return <StackedShareBar segments={segs} valueFmt={fmt} ariaLabel="Cortex Code spend by client" />;
}

/** One row per product and user: products are never summed into one figure. */
function UserTable({ p, checks }: { p: ApPageProps; checks: Record<"analyst" | "agent" | "code" | "cowork", Chk> }) {
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
    <DrillTable aria={`${PRODUCTS} spend by user`} n={10}
      empty={noDataText(p.meta, p.filters.window)}
      // Credits 2nd and the product in the user cell: a phone shows only the first two columns.
      cols={[{ label: "User · product" }, { label: "Credits", num: true, width: "auto" },
        { label: "$", num: true, width: "auto" }, { label: "Change", width: "minmax(64px, auto)" }, { label: "Credits / request", num: true, width: "auto" }]}
      rows={list.map((u) => {
        const ch = changeText(u.cur, u.prev);
        return {
          key: u.key, status: u.status,
          onOpen: () => DrawerBus.open({ id: u.id, col: "user_name", val: u.user, label: u.user }),
          cells: [`${u.user} · ${u.product}`, fmtCr(u.credits, false),
            u.usd === null ? <span title="No credit price in this export">–</span> : fmtMoney(u.usd, 0),
            ch ? (u.status === "CRITICAL" || u.status === "WARN" ? dtChip(ch, u.status) : ch) : "–",
            u.req ? fmtCr(u.credits / u.req, false) : "–"],
        };
      })} />
  );
}
