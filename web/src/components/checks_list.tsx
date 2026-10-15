// web/src/components/checks_list.tsx -- what an area sub-tab ends with: the compact checks list (pill ·
// name · "n of m · $ kind" · Rows →, each row opening the drawer), the "what could not be judged"
// strip, and the coverage strip that leads the page when the role cannot see everything.
import React from "react";
import { fmtInt, fmtMoneyOf } from "../format";
import { StatusPill, bandOf, bandPillKind } from "./primitives";
import { getCheckLabel } from "./labels";
import { moneyKindOf } from "./waste_total";
import { downloadChecksCsv } from "./findings_table";
import { DrawerBus } from "./drawer";
import { MONEY_KIND_WORD, upToWord } from "../tabs/tab_area";
import type { Filters, Finding, GoToFn, Meta } from "../types";

const LIST_RANK: Record<string, number> = { CRITICAL: 0, WARN: 1, NOT_ASSESSED: 2, ERROR: 2, OK: 3, RANKED: 3, EMPTY_WINDOW: 4, EMPTY_FILTERS: 4, INVENTORY: 5 };
const SHOW = 8;

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
}

export function ChecksList({ findings, refIds, filters, meta, goTo, openId, title: listTitle = "Checks on this tab" }: ChecksListProps) {
  const [all, setAll] = React.useState(false);
  const refs = new Set(refIds || []);
  const rows = findings.map((f) => ({ row: f, band: bandOf(f) }));
  const usd = (f: Finding) => (f.money && Number.isFinite(Number(f.money.usd)) ? Number(f.money.usd) : -1);
  rows.sort((x, y) => (LIST_RANK[x.band] ?? 5) - (LIST_RANK[y.band] ?? 5) || usd(y.row) - usd(x.row));
  if (!rows.length) return null;
  const shown = all ? rows : rows.slice(0, SHOW);
  return (
    <div className="card ck-card">
      <div className="ck-head">
        <div className="card-title">{listTitle}</div>
        <button type="button" className="ck-link" onClick={() => downloadChecksCsv(rows, filters, meta)}
          title="Download these checks as a CSV file.">CSV</button>
      </div>
      <div className="ck-list" role="list">
        {shown.map(({ row: f, band }) => {
          const flagged = band === "CRITICAL" || band === "WARN";
          const pill = refs.has(f.query_id) && !flagged ? "reference" : bandPillKind(band);
          const word = band === "EMPTY_WINDOW" || band === "EMPTY_FILTERS" ? "No data" : undefined;
          const title = getCheckLabel(f.query_id, f.title).title;
          return (
            <button type="button" role="listitem" key={f.query_id} className={`ck-row${openId === f.query_id ? " selected" : ""}`}
              onClick={() => DrawerBus.open({ id: f.query_id })} aria-label={`${title}: open its rows`}>
              <span className="ck-pill"><StatusPill kind={pill} word={word} /></span>
              <span className="ck-name" title={title}>{title}</span>
              <span className="ck-fact">{checkFact(f, band)}</span>
              <span className="ck-rows">{"Rows →"}</span>
            </button>
          );
        })}
      </div>
      {(rows.length > SHOW || goTo) && (
        <div className="ck-foot">
          {rows.length > SHOW && (
            <button type="button" className="ck-link" onClick={() => setAll((x) => !x)}>
              {all ? "Show fewer" : `+${fmtInt(rows.length - SHOW)} more`}
            </button>
          )}
          {goTo && <button type="button" className="ck-link" onClick={() => goTo({ tab: "findings" })}>{"All findings →"}</button>}
        </div>
      )}
    </div>
  );
}

/** "N checks on this tab · x critical", what could not be judged and why, and All findings. */
export function NotJudgedStrip({ findings, goTo }: { findings: Finding[]; goTo?: GoToFn | null }) {
  if (!findings.length) return null;
  const crit = findings.filter((f) => bandOf(f) === "CRITICAL").length;
  const notRun = findings.filter((f) => { const b = bandOf(f); return b === "NOT_ASSESSED" || b === "ERROR"; });
  const shown = notRun.slice(0, 3);
  return (
    <div className="nj-strip">
      <span className="nj-count">{`${fmtInt(findings.length)} check${findings.length === 1 ? "" : "s"} on this tab · ${fmtInt(crit)} critical`}</span>
      {shown.map((f) => (
        <span key={f.query_id} className="nj-pill" title={f.not_assessed && f.not_assessed.fix ? String(f.not_assessed.fix) : undefined}>
          {`– ${getCheckLabel(f.query_id, f.title).title}: ${notRunReason(f)}`}
        </span>
      ))}
      {notRun.length > shown.length && <span className="nj-pill">{`– ${fmtInt(notRun.length - shown.length)} more not judged`}</span>}
      <span className="nj-spacer" />
      {goTo && <button type="button" className="ck-link" onClick={() => goTo({ tab: "findings" })}>{"All findings →"}</button>}
    </div>
  );
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
  return (
    <div className="cov-strips">
      {strips.map((s) => (
        <div key={s.key} className="cov-strip">
          <span className="nj-pill">{s.pill}</span>
          <span className="cov-text">{s.text}</span>
          {s.grant && <code className="cov-grant">{s.grant}</code>}
          <span className="nj-spacer" />
          {goTo && <button type="button" className="ck-link" onClick={() => goTo({ tab: "coverage" })}>{"Coverage →"}</button>}
        </div>
      ))}
    </div>
  );
}
