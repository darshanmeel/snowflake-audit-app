// web/src/components/checks_list.tsx -- what an area sub-tab ends with: the checks list (severity ·
// check · found · impact · spend in scope · Rows →, grouped Priced / Not priced / Reference, each row
// opening the drawer, its summary line inside the card), and the coverage strip that leads the page
// when the role cannot see everything.
import React from "react";
import { fmtInt, fmtMoney, fmtMoneyOf } from "../format";
import { StatusPill, bandOf, bandPillKind } from "./primitives";
import { getCheckLabel } from "./labels";
import { moneyKindOf } from "./waste_total";
import { downloadChecksCsv } from "./findings_table";
import { DrawerBus } from "./drawer";
import { MONEY_KIND_WORD, upToWord } from "../tabs/tab_area";
import type { Filters, Finding, GoToFn, Meta } from "../types";
import { GuideHelp } from "./guide_links";

const LIST_RANK: Record<string, number> = { CRITICAL: 0, WARN: 1, NOT_ASSESSED: 2, ERROR: 2, OK: 3, RANKED: 3, EMPTY_WINDOW: 4, EMPTY_FILTERS: 4, INVENTORY: 5 };

function notRunReason(f: Finding) {
  return (f.not_assessed && f.not_assessed.label) || "did not run";
}

/** The mono fact of one check: "3 of 56 warehouses · $1,204 possible waste", or "–" and why. */
export function checkFact(f: Finding, band: string): string {
  if (band === "NOT_ASSESSED" || band === "ERROR") return `– ${notRunReason(f)}`;
  if (band === "EMPTY_WINDOW") return "no data in this window";
  if (band === "EMPTY_FILTERS") return "excluded by the filters";
  const parts: string[] = [];
  const a = f.affected;
  if (a) {
    parts.push(`${fmtInt(a.flagged)} of ${fmtInt(a.total)} ${a.noun}`);
    // a flagged remainder row ("(no warehouse)") is not one of the noun: say it, so Critical never reads 0 of N alone
    if (a.flagged_other > 0) parts.push(`+ ${fmtInt(a.flagged_other)} other flagged row${a.flagged_other === 1 ? "" : "s"}`);
  } else if (f.row_count != null) parts.push(`${fmtInt(f.row_count)} rows`);
  const m = f.money;
  const kind = moneyKindOf(f);
  if (m && f.money_reason === "unpriced") parts.push("not priced");
  else if (m && m.mixed_currency) parts.push("more than one currency");
  // A figure over every row, next to a flagged count, says so: it is not the flagged rows' $.
  else if (m && m.usd != null && Number.isFinite(Number(m.usd))) parts.push(`${upToWord(f)}${fmtMoneyOf(m, m.usd, 0)} ${MONEY_KIND_WORD[kind as string] || ""}${m.basis === "all" && a && a.flagged < a.total ? ` across all ${fmtInt(a.total)}` : ""}`.trim());
  return parts.join(" · ");
}

export interface ChecksListProps {
  findings: Finding[];
  refIds?: string[];
  filters: Filters;
  meta?: Meta | null;
  goTo?: GoToFn | null;
  openId?: string | null;
  title?: string;
  /** Show this many rows, then "Show N more" (the Overview); omitted, every check is listed. */
  limit?: number;
  /** Replaces the summary line at the foot of the card (the Overview's account-wide ran count). */
  summary?: React.ReactNode;
}

// Impact kinds: a figure counted on its own. Spend and context figures sit in SPEND IN SCOPE.
const IMPACT_WORD: Record<string, string> = {
  waste: "waste", saving: "saving", saving_month: "saving / month", spend_month: "storage / month", change: "change",
};
// A balance or a gap is a fact about the rows, not a $ impact: it reads after the count in FOUND.
const FOUND_KINDS: Record<string, string> = { balance: "balance", gap: "gap" };
// One currency style: USD reads "$"; another currency keeps its code (fmtMoneyOf).
const moneyText = (m: Finding["money"], v: number) => (m && m.unit === "currency" && String(m.currency || "").toUpperCase() === "USD" ? fmtMoney(v, 0) : fmtMoneyOf(m, v, 0));
const SCOPE_KINDS = new Set(["spend", "context"]);
const SEV_WORD: Record<string, string> = { critical: "Critical", warn: "Warning", ok: "OK", not_assessed: "Not assessed", reference: "Reference", nodata: "No data" };

type Group = "priced" | "change" | "unpriced" | "reference";
const GROUP_LABEL: Record<Group, string> = { priced: "Priced", change: "Change", unpriced: "Not priced", reference: "Reference" };
const GROUP_ORDER: Group[] = ["priced", "change", "unpriced", "reference"];

interface CkRow { f: Finding; band: string; sev: string; group: Group; impact: number | null; scope: number | null }

const usdOf = (f: Finding) => {
  const m = f.money;
  return m && m.usd != null && Number.isFinite(Number(m.usd)) ? Number(m.usd) : null;
};

function rowOf(f: Finding, refs: Set<string>): CkRow {
  const band = bandOf(f);
  const flagged = band === "CRITICAL" || band === "WARN";
  const ran = !(band === "NOT_ASSESSED" || band === "ERROR");
  const m = f.money;
  const kind = String(moneyKindOf(f) || "");
  const usd = ran && m && f.money_reason !== "unpriced" && !m.mixed_currency ? usdOf(f) : null;
  const impact = usd != null && IMPACT_WORD[kind] ? usd : null;
  const scope = usd != null && SCOPE_KINDS.has(kind) ? usd : null;
  const isRef = !flagged && (refs.has(f.query_id) || band === "RANKED" || band === "INVENTORY");
  const sev = band === "EMPTY_WINDOW" || band === "EMPTY_FILTERS" ? "nodata"
    : isRef ? "reference" : bandPillKind(band) === "ranked" ? "reference" : bandPillKind(band);
  const group: Group = impact != null ? (kind === "change" ? "change" : "priced") : isRef ? "reference" : "unpriced";
  return { f, band, sev, group, impact, scope };
}

/** "23 of 57 warehouses", plus a flagged remainder that names no object. */
function foundText(f: Finding, band: string): string {
  if (band === "NOT_ASSESSED" || band === "ERROR" || band === "EMPTY_FILTERS") return "–";
  const a = f.affected;
  if (a) {
    const other = a.flagged_other > 0 ? ` + ${fmtInt(a.flagged_other)} other flagged row${a.flagged_other === 1 ? "" : "s"}` : "";
    return `${fmtInt(a.flagged)} of ${fmtInt(a.total)} ${a.noun}${other}`;
  }
  return f.row_count != null ? `${fmtInt(f.row_count)} row${f.row_count === 1 ? "" : "s"}` : "–";
}

/** FOUND plus a balance or gap figure the check carries ("1 of 1 contracts · $198,991 balance"). */
function foundWithFact(f: Finding, band: string): string {
  const base = foundText(f, band);
  const kind = String(moneyKindOf(f) || "");
  const v = usdOf(f);
  if (!FOUND_KINDS[kind] || v == null || base === "–" || f.money_reason === "unpriced" || (f.money && f.money.mixed_currency)) return base;
  return `${base} · ${moneyText(f.money, v)} ${FOUND_KINDS[kind]}`;
}

/** The IMPACT cell of a check with no impact figure: why there is no $. */
function noImpactText(r: CkRow): string {
  const { f, band } = r;
  if (band === "NOT_ASSESSED" || band === "ERROR") return `– ${notRunReason(f)}`;
  if (band === "EMPTY_WINDOW") return "No data in this window";
  if (band === "EMPTY_FILTERS") return "Excluded by the filters";
  if (f.money && f.money.mixed_currency) return "More than one currency, not added";
  if (f.money && f.money_reason === "unpriced") return "Not priced in this export";
  return r.group === "reference" ? "Reference, not judged" : "Not priced";
}

/** The status in the list: a dot and a word; Not assessed keeps its dashed chip. */
function SevCell({ sev }: { sev: string }) {
  if (sev === "not_assessed") return <StatusPill kind="not_assessed" />;
  return <span className={`cx-sev sev-${sev}`}><span className="cx-sev-dot" aria-hidden="true" />{SEV_WORD[sev] || sev}</span>;
}

/** "5 checks + 2 reference · 3 critical · 1 warning · 1 ok · 1 not assessed": this list's own scope. */
export function checksSummary(rows: { sev: string; group: string }[]): string {
  const n = (s: string) => rows.filter((r) => r.sev === s).length;
  const refs = rows.filter((r) => r.group === "reference").length;
  const main = rows.length - refs;
  return [
    `${fmtInt(main)} check${main === 1 ? "" : "s"}${refs ? ` + ${fmtInt(refs)} reference` : ""}`,
    n("critical") ? `${fmtInt(n("critical"))} critical` : null,
    n("warn") ? `${fmtInt(n("warn"))} warning` : null,
    n("ok") ? `${fmtInt(n("ok"))} ok` : null,
    n("nodata") ? `${fmtInt(n("nodata"))} no data` : null,
    n("not_assessed") ? `${fmtInt(n("not_assessed"))} not assessed` : null,
  ].filter(Boolean).join(" · ");
}

export function ChecksList({ findings, refIds, filters, meta, goTo, openId, title: listTitle = "Checks on this tab", limit, summary }: ChecksListProps) {
  const [all, setAll] = React.useState(false);
  if (!findings.length) return null;
  const refs = new Set(refIds || []);
  const rows = findings.map((f) => rowOf(f, refs));
  const bySev = (x: CkRow, y: CkRow) => (LIST_RANK[x.band] ?? 5) - (LIST_RANK[y.band] ?? 5);
  // Priced by $, the rest by severity, then by spend in scope.
  const sortIn = (g: Group) => rows.filter((r) => r.group === g).sort((x, y) => (g === "priced" || g === "change"
    ? Math.abs(y.impact!) - Math.abs(x.impact!) : bySev(x, y) || (y.scope ?? -1) - (x.scope ?? -1)));
  const groups = GROUP_ORDER.map((g) => sortIn(g));
  const ordered = groups.flat();
  // A limit is shared across the groups, so a short list still shows priced and not-priced checks.
  const present = groups.filter((x) => x.length).length || 1;
  const perGroup = limit && !all ? Math.max(3, Math.ceil(limit / present)) : Infinity;
  const shown = groups.flatMap((x) => x.slice(0, perGroup));
  // One bar scale per group, so a change is never drawn against waste.
  const maxOf = (g: Group) => Math.max(0, ...rows.filter((r) => r.group === g).map((r) => Math.abs(r.impact || 0)));
  const max: Record<string, number> = { priced: maxOf("priced"), change: maxOf("change") };
  const win = `${filters.window} d`;
  return (
    <div className="card ck-card cx-ck">
      <div className="ck-head">
        <div className="card-title">{listTitle}</div>
        <div className="cx-ck-links">
          <button type="button" className="ck-link" onClick={() => downloadChecksCsv(rows.map((r) => ({ row: r.f, band: r.band })), filters, meta)}
            title="Download these checks as a CSV file.">CSV</button>
          {goTo && <button type="button" className="ck-link" onClick={() => goTo({ tab: "findings" })}>{"All findings →"}</button>}
        </div>
      </div>
      <div className="cx-ck-table" role="table" aria-label={listTitle}>
        <div className="cx-ck-tr cx-ck-th" role="row">
          <span role="columnheader">Severity</span><span role="columnheader">Check</span><span role="columnheader">Found</span>
          <span role="columnheader">{`Impact · ${win}`}</span><span role="columnheader" className="num">Spend in scope</span><span aria-hidden="true" />
        </div>
        {GROUP_ORDER.map((g) => {
          const inGroup = shown.filter((r) => r.group === g);
          if (!inGroup.length) return null;
          const total = rows.filter((r) => r.group === g).length;
          return (
            <React.Fragment key={g}>
              <div className="cx-ck-group" role="row"><span role="cell">{`${GROUP_LABEL[g]} · ${fmtInt(total)}`}</span></div>
              {inGroup.map((r) => {
                const { f } = r;
                const title = getCheckLabel(f.query_id, f.title).title;
                const kind = String(moneyKindOf(f) || "");
                const m = f.money;
                const a = f.affected;
                const pct = r.impact != null && max[g] > 0 ? Math.max(2, (100 * Math.abs(r.impact)) / max[g]) : 0;
                return (
                  // A div, not a button, so the row can hold the Guide link beside the name.
                  <div role="row" tabIndex={0} key={f.query_id} className={`cx-ck-tr${openId === f.query_id ? " selected" : ""}`}
                    onClick={() => DrawerBus.open({ id: f.query_id })} aria-label={`${title}: open its rows`}
                    onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); DrawerBus.open({ id: f.query_id }); } }}>
                    <span role="cell" className="cx-ck-sev"><SevCell sev={r.sev} /></span>
                    <span role="cell" className="cx-ck-name">{title} <GuideHelp id={f.query_id} label={title} /></span>
                    <span role="cell" className="cx-ck-found">{foundWithFact(f, r.band)}</span>
                    {r.impact != null ? (
                      <span role="cell" className="cx-ck-impact">
                        {g === "priced" && <span className="cx-ck-track" aria-hidden="true"><span className={`cx-ck-fill k-${kind}`} style={{ width: `${pct}%` }} /></span>}
                        <span className="cx-ck-usd">{`${upToWord(f)}${r.impact > 0 && g === "change" ? "+" : ""}${moneyText(m, r.impact)}`}</span>
                        <span className="cx-ck-kind">{IMPACT_WORD[kind]}</span>
                      </span>
                    ) : <span role="cell" className="cx-ck-impact none">{noImpactText(r)}</span>}
                    <span role="cell" className={`cx-ck-scope num${r.scope == null ? " empty" : ""}`}>
                      {r.scope != null ? (
                        <React.Fragment>
                          {moneyText(m, r.scope)}
                          {m && m.basis === "all" && a && a.flagged < a.total && <span className="cx-ck-sub">{`across all ${fmtInt(a.total)}`}</span>}
                        </React.Fragment>
                      ) : "–"}
                    </span>
                    <span role="cell" className="ck-rows">{"Rows →"}</span>
                  </div>
                );
              })}
            </React.Fragment>
          );
        })}
      </div>
      <div className="cx-ck-foot">
        {limit && (all || ordered.length > shown.length) ? (
          <button type="button" className="ck-link" onClick={() => setAll((x) => !x)}>
            {all ? "Show fewer" : `Show ${fmtInt(ordered.length - shown.length)} more`}
          </button>
        ) : <span />}
        {summary || <span className="cx-ck-summary">{checksSummary(rows)}</span>}
      </div>
    </div>
  );
}

/** Kept for callers: its counts and not-judged reasons now sit inside the checks list card. */
export function NotJudgedStrip(_props: { findings: Finding[]; goTo?: GoToFn | null }) {
  return null;
}

/** Shown only when the role cannot see part of what this tab reads: what is missing, the GRANT, Coverage. */
export function CoverageStrip({ findings, goTo }: { findings: Finding[]; goTo?: GoToFn | null }) {
  const strips: { key: string; pill: string; text: string; grant: string | null }[] = [];
  const vis = findings.find((f) => f.visibility && f.visibility.limited);
  if (vis) {
    const v = vis.visibility;
    const billed = Number(v.billed), visible = Number(v.visible);
    const note = String(v.note || "");
    // The note names the grant in prose ("... run GRANT ... for each warehouse."): shown in mono on its own.
    const g = /run (.+?) for each/.exec(note);
    strips.push({
      key: "vis",
      pill: `– ${fmtInt(billed - visible)} of ${fmtInt(billed)} ${v.unit || "warehouses"} not visible`,
      text: g ? `${note.slice(0, note.indexOf(". To see") + 1) || note} Run this for each one:` : note,
      grant: g ? g[1] : null,
    });
  }
  const blind = findings.filter((f) => { const b = bandOf(f); return (b === "NOT_ASSESSED" || b === "ERROR") && f.not_assessed && f.not_assessed.cause === "no_access"; });
  if (blind.length) {
    const grants = blind.flatMap((f) => (f.not_assessed.grants || []) as string[]);
    strips.push({
      key: "role",
      pill: `– ${fmtInt(blind.length)} of ${fmtInt(findings.length)} checks not visible`,
      text: "The audit role can't read what these checks need, so they read Not assessed.",
      grant: grants[0] ? String(grants[0]).split("--")[0].trim() : null,
    });
  }
  if (!strips.length) return null;
  // A dashed strip: what is missing as a title, one reason line, the GRANT to copy, Coverage.
  return (
    <div className="cov-strips">
      {strips.map((s) => (
        <div key={s.key} className="cov-strip cx-cov">
          <div className="cx-cov-main">
            <span className="cx-cov-title">{s.pill.replace(/^– /, "")}</span>
            <span className="cov-text">{s.text}</span>
            {s.grant && <code className="cov-grant">{s.grant}</code>}
          </div>
          {goTo && <button type="button" className="ck-link" onClick={() => goTo({ tab: "coverage" })}>{"Coverage →"}</button>}
        </div>
      ))}
    </div>
  );
}
