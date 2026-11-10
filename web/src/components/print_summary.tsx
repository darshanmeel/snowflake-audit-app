// web/src/components/print_summary.tsx -- the printable one-page summary. Always mounted inside
// Overview's own return, hidden on screen and shown only by @media print (styles.css's .print-only
// rule): "Print summary" just calls window.print(); the browser's print dialog saves it as a PDF.
//
// Every number is a prop straight off Overview's own already-computed state: the same verdict,
// spend and possible-waste figures the screen shows, so the two can never disagree. A figure that
// could not be computed prints "-" and why, never $0.
import { BRAND_NAME } from "../api";
import { fmtInt } from "../format";
import type { Filters, Meta } from "../types";
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
