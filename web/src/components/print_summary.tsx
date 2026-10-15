// web/src/components/print_summary.tsx -- the printable one-page summary. Always mounted inside
// Overview's own return, hidden on screen and shown only by @media print (styles.css's .print-only
// rule): "Print summary" just calls window.print(); the browser's print dialog saves it as a PDF.
//
// Every number is a prop straight off Overview's own already-computed state: the same verdict,
// spend and possible-waste figures the screen shows, so the two can never disagree. A figure that
// could not be computed prints "-" and why, never $0.
import { BRAND_NAME } from "../api";
import { fmtInt, fmtMoney } from "../format";
import { getCheckLabel } from "./labels";
import type { Filters, Meta, TagFilter } from "../types";
import { fixFirstAffected, fixFirstUsd, fixFirstVisible, useFixFirst } from "../tabs/tab_actions";
import { ranCountsOf } from "./primitives";


/** One Overview tile, as far as the printout reads it. */
export interface PrintTile {
  label?: string;
  value?: string | number | null;
  unit?: string | null;
  reading?: string | null;
  [key: string]: any;
}

/** One of the never-added waste figures (waste, saving, storage per month). */
interface PrintFigure { usd?: number | null; [key: string]: any }

/** Overview's already-computed state the printout shows. */
export interface PrintSummaryData {
  sentence?: string | null;
  tiles?: PrintTile[] | null;
  wt: { waste: PrintFigure; saving: PrintFigure; month: PrintFigure; [key: string]: any };
  windowText?: string | null;
  meta: Meta | null;
  filters: Filters;
  ranCounts: { assessed: number; total: number; [key: string]: any };
  priceText?: string | null;
}

type TagGroup = TagFilter["groups"][number];

export function tileLineText(t: PrintTile) {
  const value = [t.value, t.unit].filter(Boolean).join("");
  return `${t.label}: ${value}${t.reading ? ` (${t.reading})` : ""}`;
}

export function tagValueText(tag: TagGroup | null | undefined) {
  if (!tag) return "any value";
  return (tag.values && tag.values.length ? tag.values : ["any value"]).map((v: string) => (v === "__untagged__" ? "untagged" : v)).join(" or ");
}

export function PrintSummary({ data }: { data: PrintSummaryData }) {
  const { sentence, tiles, wt, windowText, meta, filters, ranCounts, priceText } = data;
  const brand = (meta && meta.brand && meta.brand.name) || BRAND_NAME;
  const asOf = meta && meta.direct_export ? String(meta.direct_export.as_of || "").slice(0, 10) : null;
  const builtText = asOf ? `Computed on Snowflake, ${asOf}` : "No export loaded yet";
  const nAccounts = filters.accountIdSet ? filters.accountIdSet.size : 0;
  const acctLine = nAccounts > 0 ? `${fmtInt(nAccounts)} account${nAccounts === 1 ? "" : "s"} selected` : "no account selected";
  const groups = (filters.tag && filters.tag.groups) || [];
  const tagLine = groups.length ? `Tag: ${groups.map((g: TagGroup) => `${g.display_key || g.key} = ${tagValueText(g)}`).join("; ")}` : "No tag filter";
  const partial = meta && meta.cost_cutoff && meta.cost_cutoff.partial_day;
  // The security findings with no dollar figure print as their own block, never inside a $ total.
  const ff = useFixFirst(filters, 10);
  const critNoUsd = ff.phase === "ready" ? fixFirstVisible(ff.data!.items).filter((it: any) => it.group === "critical_no_usd") : [];
  const fixRows = ff.phase === "ready" ? fixFirstVisible(ff.data!.items).filter((it: any) => it.group !== "critical_no_usd") : [];
  const critCount = ff.phase === "ready" && ff.data!.counts ? ff.data!.counts.critical_no_usd : null;

  return (
    <div className="print-only print-summary">
      <div className="ps-title">{brand} -- one-page summary</div>
      <div className="ps-scope">
        {builtText} -- window {windowText || `last ${filters.window} days`}{partial ? " (today partial)" : ""} -- {acctLine} -- {tagLine}
        {priceText ? ` -- ${priceText}` : ""}
      </div>

      <div className="ps-verdict">{sentence || "…"}</div>

      <div className="ps-section">
        <div className="ps-h">Top 3 to fix first</div>
        {ff.phase === "loading" ? <div className="ps-line">…</div> : fixRows.length === 0 ? (
          <div className="ps-line">Nothing flagged in the checks that ran{ranCounts.assessed < ranCounts.total ? ` (${fmtInt(ranCounts.total - ranCounts.assessed)} checks did not run)` : ""}.</div>
        ) : (
          <ol className="ps-list">
            {fixRows.slice(0, 3).map((r: any) => (
              <li key={r.query_id}>{`${getCheckLabel(r.query_id, r.title).title} -- ${fixFirstUsd(r)}${fixFirstAffected(r) ? ` -- ${fixFirstAffected(r)}` : ""}`}</li>
            ))}
          </ol>
        )}
      </div>

      <div className="ps-section">
        <div className="ps-h">{`Critical, not priced${critCount != null ? ` (${fmtInt(critCount)} checks)` : ""}`}</div>
        {ff.phase === "loading" ? <div className="ps-line">…</div>
          : ff.phase === "error" ? <div className="ps-line">-, could not be loaded.</div>
          : critNoUsd.length === 0 ? <div className="ps-line">No critical check without a dollar figure.</div>
          : (
            <ul className="ps-list">
              {critNoUsd.map((it: any) => (
                <li key={it.query_id}>{`${getCheckLabel(it.query_id, it.title).title}${it.affected && it.affected.flagged != null ? ` -- ${fmtInt(it.affected.flagged)} of ${fmtInt(it.affected.total)} ${it.affected.noun}` : ""}`}</li>
              ))}
            </ul>
          )}
      </div>

      <div className="ps-section">
        <div className="ps-h">Possible waste, saving and storage (never added together)</div>
        <ul className="ps-list">
          <li>{wt.waste.usd != null ? `Possible waste over the window: ${fmtMoney(wt.waste.usd, 0)} from ${fmtInt(wt.waste.ran)} of ${fmtInt(wt.waste.total)} checks that ran.` : "Possible waste: not assessed."}</li>
          <li>{wt.saving.usd != null ? `Possible saving from resizing over the window: ${fmtMoney(wt.saving.usd, 0)}.` : "Possible saving from resizing: not assessed."}</li>
          <li>{wt.month.usd != null ? `Storage that could be freed: ${fmtMoney(wt.month.usd, 0)} per month.` : "Storage per month: not assessed."}</li>
        </ul>
      </div>

      <div className="ps-section">
        <div className="ps-h">By area</div>
        <ul className="ps-list">
          {(tiles || []).map((t: PrintTile) => <li key={t.label}>{tileLineText(t)}</li>)}
        </ul>
      </div>

      <div className="ps-note">
        {`${fmtInt(ranCounts.assessed)} of ${fmtInt(ranCounts.total)} checks ran in this export.`}
      </div>
    </div>
  );
}

/** The Money page's printed header: account, as-of, rate and checks ran, then a four-line summary.
 * Every figure is the screen's own, passed in already formatted. */
export function MoneyPrintHeader({ meta, filters, lines, priceText }: { meta: Meta | null; filters: Filters; lines: (string | null)[]; priceText?: string | null }) {
  const brand = (meta && meta.brand && meta.brand.name) || BRAND_NAME;
  const asOf = meta && meta.direct_export ? String(meta.direct_export.as_of || "").slice(0, 10) : (meta && meta.as_of_date) || null;
  const nAccounts = filters.accountIdSet ? filters.accountIdSet.size : 0;
  const ran = ranCountsOf(meta);
  const partial = meta && meta.cost_cutoff && meta.cost_cutoff.partial_day;
  const scope = [asOf ? `As of ${asOf}` : null, `last ${filters.window} days${partial ? " (today partial)" : ""}`,
    nAccounts > 0 ? `${fmtInt(nAccounts)} account${nAccounts === 1 ? "" : "s"}` : null, priceText || null,
    ran ? `${fmtInt(ran.assessed)} of ${fmtInt(ran.total)} checks ran` : null].filter(Boolean).join(" -- ");
  return (
    <div className="print-only print-summary money-print-head">
      <div className="ps-title">{`${brand} -- money summary`}</div>
      <div className="ps-scope">{scope}</div>
      <ul className="ps-list">
        {(lines.filter(Boolean) as string[]).slice(0, 4).map((l) => <li key={l}>{l}</li>)}
      </ul>
    </div>
  );
}
