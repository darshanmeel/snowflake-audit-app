// Shared shapes of what the API returns and what the shell passes down. The API is the source of
// truth (app/api/app.py); these types describe it loosely where a response carries per-check columns.

/** One row of a check's table: column name -> value, as the API sends it. */
export type Row = Record<string, any>;

/** How a check's fetch came out. Only ok_rows draws a chart; every other outcome shows its note. */
export type Outcome = "ok_rows" | "ok_empty_window" | "ok_empty_filters" | "not_assessed" | "error";

/** A check's headline money figure on GET /api/findings. */
export interface Money {
  usd?: number | null;
  credits?: number | null;
  column?: string | null;
  kind?: string | null;
  /** "flagged" (a waste or saving: the flagged rows' own) or "all" (every row listed). */
  basis?: string | null;
  /** For basis "all": the flagged rows' part of usd. */
  usd_flagged?: number | null;
  [key: string]: any;
}

/** One entry of GET /api/findings: a check's summary, with more fields the pages read by name. */
export interface Finding {
  query_id: string;
  /** The export's price basis (GET /api/findings `price_basis`), copied onto each finding. */
  export_price?: { credit_price_usd?: number | null; storage_price_usd_tb_month?: number | null } | null;
  title?: string;
  domain?: string;
  outcome?: Outcome | string | null;
  row_count?: number;
  money?: Money | null;
  /** Set when the export read this check from INFORMATION_SCHEMA because the role cannot read ACCOUNT_USAGE. */
  source?: { source: string; reads?: string | null; note?: string | null } | null;
  [key: string]: any;
}

/** GET /api/meta: the export's own facts (as-of date, windows, edition, pricing). */
export type Meta = Record<string, any>;

/** The dims (warehouse, task, user ... names by id) the pages label rows with. */
export type Dims = Record<string, any>;

/** The filters the shell passes to every page. */
export interface Filters {
  window: number;
  accountIds: string[] | null;
  accountIdSet?: Set<string> | null;
  tag?: TagFilter | null;
  [key: string]: any;
}

export interface TagFilter {
  // all: every value ticked, untagged too, so the name is picked but narrows nothing yet.
  groups: { key: string; display_key?: string; values: string[]; all?: boolean }[];
}

/** A finding fetch as the hooks return it: loading, ready (with an outcome) or error. */
export interface FetchState<D = any> {
  phase: "loading" | "ready" | "error";
  outcome: Outcome | string | null;
  data: D | null;
  error: string | null;
}

/** Where the shell can send the user: area, sub-tab and an optional check to focus. */
export interface GoTo {
  tab?: string;
  subtab?: string | null;
  focusQueryId?: string | null;
  [key: string]: any;
}
export type GoToFn = (to: GoTo) => void;
