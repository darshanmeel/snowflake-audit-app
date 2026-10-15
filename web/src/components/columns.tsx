// web/src/components/columns.tsx -- human column names, units and one-sentence help for a wide
// finding's own data table (finding_detail.tsx's DataTable is the only reader). Without it a table
// would print raw snake_case names (est_wasted_usd_list) with no unit and no explanation.
//
// This is a DISPLAY layer only. It never changes what a column IS (that is classify_columns' job,
// app/api/service.py) or what a header text says; it only decides how one column NAME renders, and
// always keeps the raw name one hover away so a reader can match it back to the check's own text.

// A curated definition for a column this app renders often enough, or ambiguously enough, that the
// generic humanize() pass below is not good enough on its own. `unit` overrides the kind-derived
// unit; `help` is one sentence, plain words.
import { ACCOUNT_COLUMN, acctId } from "../api";
import { resolveName } from "./names";
import { UPPER_BOUND_IDS } from "../tabs/tab_area";
import type { Row } from "../types";

/** One curated column definition. */
export interface CuratedColumn { label: string; help?: string; kind?: string; unit?: string | null }

/** One column as GET /api/finding sends it. */
export interface ApiColumn { name: string; kind?: string | null; label?: string | null; [key: string]: any }

/** One planned column: resolved label, unit, help and whether it is numeric. */
export interface PlannedColumn {
  name: string;
  kind: string | null | undefined;
  raw: string;
  label: string;
  unit: string | null;
  help: string | null;
  numeric: boolean;
  reason?: string;
}

export const CURATED: Record<string, CuratedColumn> = {
  status: { label: "Status", help: "CRITICAL/WARN need action soon; OK is clean; NOT_ASSESSED means this one row could not be judged. It is not a pass." },
  not_assessed_reason: { label: "Why not assessed", kind: "enum:not_assessed_reason", help: "The specific reason this row could not be judged." },
  [ACCOUNT_COLUMN]: { label: "Account" },
  account_name: { label: "Account" },
  account_locator: { label: "Account locator" },
  warehouse_id: { label: "Warehouse" },
  warehouse_name: { label: "Warehouse" },
  task_full_name: { label: "Task" },
  job_id: { label: "Task" },
  database_name: { label: "Database" },
  schema_name: { label: "Schema" },
  table_name: { label: "Table" },
  table_fqn: { label: "Table" },
  role_name: { label: "Role", help: "The role the statement ran under, or the role that owns the object." },
  user_name: { label: "User" },
  owner_role: { label: "Owner (role)", help: "The role that owns the object. Owner and ran-as are different things: they are never merged in one column." },
  owner: { label: "Owner", help: "The role or user that owns the object. Owner and ran-as are different things: they are never merged in one column." },
  run_as: { label: "Ran as" },
  query_tag: { label: "Query tag", help: "The QUERY_TAG session parameter the statement ran with. Untagged statements have none." },
  credits: { label: "Credits", unit: "credits" },
  attributed_credits: { label: "Credits attributed to queries", unit: "credits", help: "Credits the warehouse billed while these queries ran. It leaves out idle time and queries under about 100 ms, is empty on adaptive warehouses, and can lag up to 8 hours." },
  est_usd_list: { label: "Est. $" },
  est_wasted_usd_list: { label: "Est. wasted $" },
  est_idle_usd_list: { label: "Est. idle $" },
  est_saving_usd_list: { label: "Est. saving" },
  est_storage_usd_month: { label: "Storage $ per month", unit: "$/mo" },
  est_saving_usd_month: { label: "Saving $ per month", unit: "$/mo" },
  price_basis: { label: "Price basis", help: "Whether this row's dollar figure is priced at your effective $ per credit, or unpriced because no price is available." },
  usage_date: { label: "Day" },
  service_type: { label: "Service type" },
  sku_name: { label: "Service" },
  billing_origin_product: { label: "Service", kind: "enum:billing_origin_product" },
  status_raw: { label: "Status before the floor", help: "The status this row had before a materiality floor (below a size/impact cutoff) moved it to OK." },
  usd_list: { label: "Spend in this row", unit: "$" },
  hour_usd_list: { label: "Spend, this hour of day (whole window)", unit: "$" },
  window_usd_list: { label: "Spend, whole window", unit: "$" },
  // A percentage the backend cannot recognise by name: without this a grouped table would SUM it.
  share_of_window_spend: { label: "Share of window spend", unit: "%", kind: "pct" },
  weekday_num: { label: "Weekday number" },
  // pressure and lever words, per column (labels.tsx ENUM_BY_COLUMN)
  pressure: { label: "Pressure", kind: "enum:pressure", help: "What limits the warehouse: memory (queries spill), capacity (queries wait for a slot), both or neither." },
  scaling_hint: { label: "Lever", kind: "enum:scaling_hint", help: "Scale up means a bigger size; scale out means more clusters; keep warm means avoiding cold starts." },
  row_kind: { label: "Row", kind: "enum:row_kind" },
  pool_kind: { label: "Pool kind", kind: "enum:pool_kind" },
  set_kind: { label: "Set kind", kind: "enum:set_kind" },
  feed_kind: { label: "Feed", kind: "enum:feed_kind", help: "Billing views lag most; activity views may be empty on a quiet account." },
  cause: { label: "Cause", kind: "enum:cause" },
  finding: { label: "Finding", kind: "enum:finding" },
  provider_kind: { label: "Provider", kind: "enum:provider_kind" },
  owner_state: { label: "Owner state", kind: "enum:owner_state" },
  // a warehouse in no SHOW and not dropped is not visible to this role, never "deleted"
  warehouse_deleted: { label: "Dropped", kind: "flag:dropped", help: "True only when a drop event was found." },
  warehouse_not_visible: { label: "Visibility", kind: "flag:not_visible", help: "In no SHOW WAREHOUSES for this role and not dropped: the role cannot see it." },
  root_task_name: { label: "Root task", kind: "root_task" },
  root_task_full_name: { label: "Root task (full name)" },
  est_change_usd_list: { label: "Est. change $" },
  est_storage_usd_month_up_to: { label: "Storage $ per month, up to", unit: "$/mo" },
  our_credits: { label: "Credits (this audit)", unit: "credits" },
  sf_upper_bound: { label: "Snowflake upper bound", unit: "credits", help: "The top of the range Snowflake expects for the day." },
  snowflake_anomaly: { label: "Snowflake flags it" },
  our_spike: { label: "Audit spike" },
  snowflake_row: { label: "Snowflake has a row", help: "False means Snowflake has no row for the day yet (its view lags up to 8 hours)." },
  charge_amount: { label: "Charge (invoice currency)", help: "In the invoice currency, never discounted and never added to a $ figure." },
  unread_amount: { label: "Charge of unread listings (invoice currency)" },
  warehouse_generation: { label: "Generation" },
  credits_per_hour: { label: "Credits per hour", unit: "credits/h" },
  is_exhausted: { label: "Prepaid balance used up" },
  storage_price_basis: { label: "Storage price basis" },
  tagged_pct: { label: "Tagged sensitive", unit: "%", kind: "pct" },
  // A price per credit, not a number of credits: the name's "credit" fooled the credits pattern.
  amount_per_credit: { label: "Amount per credit", kind: "currency", unit: null, help: "In the invoice currency, per credit." },
};

// A setting is a configured value, not a measure: it is never the value a chart or a headline picks.
export const SETTING_COLUMN_RE = /^(auto_suspend(_\w+)?|(min|max)_cluster_count|cluster_count|(warehouse|current|configured|suggested|recommended|target|new|old|from|to)_size|size|\w*retention_(days|time)\w*|data_retention\w*|max_concurrency\w*|statement_timeout\w*|resource_constraint|warehouse_generation|rate_multiplier|credits_per_hour|scaling_policy|min_cluster_\w+|max_cluster_\w+|(min|max)_clusters|auto_stop_minutes|max_cluster_count_seen|warehouse_size)$/i;
export function isSettingColumn(name: string | null | undefined) { return SETTING_COLUMN_RE.test(String(name || "")); }

// Columns whose value repeats the same whole-window figure on many rows: never picked as a headline
// or summed (a sum would count the same money once per row).
export const NO_SUM_COLUMNS = new Set(["hour_usd_list", "window_usd_list", "password_users"]);

// snake_case -> Sentence case, with a small set of abbreviation fixes so a reader never has to
// decode "usd"/"pct" by eye. Trailing "_id" is dropped (a bare id column CURATED does not
// already name gets its noun alone, e.g. "grantee_id" -> "Grantee") and "_disc" is dropped too --
// planColumns() below relabels a live discount twin explicitly, so a humanize() call only ever
// sees "_disc" on a twin that ISN'T live (discount 0%, about to be hidden as a duplicate anyway).
export function humanizeColumnName(name: string | null | undefined) {
  if (!name) return "";
  let s = String(name).replace(/_disc$/, "").replace(/_id$/, "");
  if (!s) s = String(name);
  const words = s.split("_").filter(Boolean);
  if (!words.length) return String(name);
  const FIXES: Record<string, string> = { usd: "$", pct: "%", est: "Est.", cpu: "CPU", mem: "memory", gb: "GB", tb: "TB", ui: "UI", url: "URL", mfa: "MFA", sso: "SSO", udf: "UDF", ip: "IP", qas: "QAS", dt: "DT" };
  return words.map((w) => {
    const lw = w.toLowerCase();
    if (FIXES[lw]) return FIXES[lw];
    if (/^p(50|90|95|99)$/.test(lw)) return lw;
    return lw.charAt(0).toUpperCase() + lw.slice(1);
  }).join(" ");
}

// The unit shown beside a header label -- from the column's own `kind` first (the same magnitude
// families format.tsx's fmtCell already renders with a suffix).
export function unitForClassifiedKind(kind: string | null | undefined) {
  if (kind === "money") return "$";
  if (kind === "credits") return "credits";
  if (kind === "pct") return "%";
  if (kind === "hours") return "h";
  if (kind === "gb" || kind === "gb_bytes") return "GB";
  return null;
}

// A raw-seconds/milliseconds/minutes column-name suffix classify_columns has no `kind` for at
// all -- {unit, bareName}, where bareName has the matched suffix removed so humanizeColumnName()
// is never asked to turn the suffix into a SECOND, word-shaped copy of the very unit this already
// names (setup_s -> unit "s" + bareName "setup" -> label "Setup", not the bare, meaningless
// single-letter word "S" a plain word-split of "setup_s" would otherwise produce).
export function suffixUnit(name: string) {
  if (/_ms$/.test(name)) return { unit: "ms", bareName: name.replace(/_ms$/, "") };
  if (/_minutes$/.test(name)) return { unit: "min", bareName: name.replace(/_minutes$/, "") };
  if (/_seconds$/.test(name)) return { unit: "s", bareName: name.replace(/_seconds$/, "") };
  if (/(^|_)s$/.test(name)) return { unit: "s", bareName: name.replace(/(^|_)s$/, "") };
  return null;
}

// columnMeta(name, kind) -> {label, unit, help, raw}. `raw` is always the column name verbatim, so
// a reader hovering the header can match the label back to the check's own text. Always the real
// unit, even when the label ends in that same symbol: a caller rendering label and unit as ONE
// inline string (planColumns' toMeta below) suppresses the repeat itself.
export function escapeRegExp(s: string) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

export function columnMeta(name: string, kind: string | null | undefined) {
  const curated: Partial<CuratedColumn> = CURATED[name] || {};
  let bareName = name;
  // "bytes" in a gb_bytes column's own name just repeats what the GB unit badge already says.
  if (!curated.label && kind === "gb_bytes") {
    bareName = bareName.replace(/(^|_)bytes(?=_|$)/i, "").replace(/^_|_$|__+/g, (m: string) => (m === "__" ? "_" : ""));
  }
  let unit;
  if (curated.unit !== undefined) {
    unit = curated.unit;
  } else {
    unit = unitForClassifiedKind(kind);
    if (!unit) {
      const suffix = suffixUnit(bareName);
      if (suffix) { unit = suffix.unit; bareName = suffix.bareName; }
    }
  }
  const label = curated.label || humanizeColumnName(bareName);
  return { raw: name, label, unit: unit || null, help: curated.help || null };
}

// The column named for CURATED's own label alone: finding_detail.tsx's actionLine uses this to swap
// a bare column name inside an action sentence for its plain label (never the generic humanize()
// fallback there).
export function curatedColumnLabel(name: string) {
  const c = CURATED[name];
  return c ? c.label : null;
}

// A term from a check's own ORDER BY (e.g. "est_wasted_usd_list DESC, credits DESC") in plain words,
// or null when the term IS the status-rank CASE expression every check with a status column already
// gets (that is exactly what "most severe first" already says). A term this cannot parse as a bare
// "<column> [ASC|DESC]" falls back to a named admission rather than printing raw SQL in the UI.
export function humanizeOrderByTerm(term: string | null | undefined) {
  const t = String(term || "").trim();
  if (!t) return null;
  if (/^case\s+status\b/i.test(t)) return null;
  // Neither a trailing NULLS FIRST/LAST nor a leading table-alias qualifier ("b.column") changes
  // what the term means, so both are stripped first.
  const stripped = t.replace(/\s+nulls\s+(first|last)$/i, "");
  const m = stripped.match(/^(?:[a-zA-Z_][a-zA-Z0-9_]*\.)?([a-zA-Z_][a-zA-Z0-9_]*)\s*(asc|desc)?$/i);
  if (!m) return "this check's own ranking";
  const dir = (m[2] || "desc").toLowerCase();
  return `${columnMeta(m[1], null).label} (${dir === "asc" ? "lowest first" : "highest first"})`;
}

// "Sorted: most severe first, then Est. wasted $ (highest first)": says what the ordering rule
// actually is. null when the check carries no ORDER BY at all.
export function sortOrderNote(orderBy: string | null | undefined) {
  if (!orderBy) return null;
  const parts = String(orderBy).split(",").map(humanizeOrderByTerm).filter((p) => p !== null);
  return parts.length ? `Sorted: most severe first, then ${parts.join(", then ")}` : "Sorted: most severe first";
}

// Singular/plural English noun for each column planColumns' ENTITY_PRIORITY can pick as a finding's
// main entity: lets a caller say "12 warehouses" instead of "12 rows". Mirrors the API's own
// ENTITY_COLUMNS (app/core/finding_columns.py).
export const ENTITY_NOUN: Record<string, { s: string; p: string }> = {
  resource_key: { s: "resource", p: "resources" },
  task_full_name: { s: "task", p: "tasks" },
  job_id: { s: "task", p: "tasks" },
  pipe_name: { s: "pipe", p: "pipes" },
  dynamic_table_name: { s: "dynamic table", p: "dynamic tables" },
  table_name: { s: "table", p: "tables" },
  schema_name: { s: "schema", p: "schemas" },
  database_name: { s: "database", p: "databases" },
  warehouse_id: { s: "warehouse", p: "warehouses" },
  warehouse_name: { s: "warehouse", p: "warehouses" },
  role_name: { s: "role", p: "roles" },
  user_name: { s: "user", p: "users" },
  root_task_name: { s: "task", p: "tasks" },
  runtime_name: { s: "runtime", p: "runtimes" },
  notebook_name: { s: "notebook", p: "notebooks" },
  model_name: { s: "model", p: "models" },
  compute_pool_name: { s: "compute pool", p: "compute pools" },
  alert_full_name: { s: "alert", p: "alerts" },
  stage_full_name: { s: "stage", p: "stages" },
  set_name: { s: "backup set", p: "backup sets" },
  dt_full_name: { s: "dynamic table", p: "dynamic tables" },
  policy_name: { s: "policy", p: "policies" },
  tag_name: { s: "tag", p: "tags" },
  listing_global_name: { s: "listing", p: "listings" },
  source_view: { s: "usage view", p: "usage views" },
};

// The one numeric column a summary (verdict line, top-N chart, grouped table) leads with: wasted
// money first, then any money, then wasted credits, then any credits, then a rate, then a duration
// or size. Only a candidate with NO classified magnitude (a plain count column) reaches the two
// fallbacks: a column named failed/wasted/idle, then the check's own sort column, then whichever
// numeric column the SELECT list put first.
export function pickKeyMetric(visibleMeta: PlannedColumn[], entity: string | null, orderByCol: string | null, allZero?: Set<string> | null) {
  // A column that is zero on every loaded row has nothing to rank: the next candidate leads instead.
  const candidates = visibleMeta.filter((c) => c.numeric && c.name !== entity && c.name !== "status" && !isSettingColumn(c.name) && !NO_SUM_COLUMNS.has(c.name) && c.kind !== "currency" && !(allZero && allZero.has(c.name)));
  if (!candidates.length) return null;
  const byKind = (kind: string) => candidates.find((c) => c.kind === kind);
  return (
    candidates.find((c) => c.kind === "money" && /wasted/i.test(c.name))
    || byKind("money")
    || candidates.find((c) => c.kind === "credits" && /wasted|idle/i.test(c.name))
    || byKind("credits")
    || byKind("pct")
    || byKind("hours")
    || byKind("gb")
    || byKind("gb_bytes")
    || candidates.find((c) => /failed|wasted|idle/i.test(c.name))
    || (orderByCol && candidates.find((c) => c.name === orderByCol))
    || candidates[0]
  );
}

// The lead column of a check's own ORDER BY: pickKeyMetric's second-choice headline when no
// failed/wasted/idle-named column exists, since that column is by definition its "worst first".
export function firstOrderByColumn(orderBy: string | null | undefined) {
  const first = String(orderBy || "").split(",")[0].trim();
  const m = first.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*(asc|desc)?$/i);
  return m ? m[1] : null;
}

// How a metric combines across one entity's rows. Money, credits, hours, sizes and plain counts add
// up; a percentage or ratio averages; an age, a number of days, a lag or a depth is a level, so the
// entity reads its largest, never a sum of ages.
export const LEVEL_METRIC_RE = /(^|_)(age|ages|days|day_count|days_since|idle_days|lag|depth|level|max|min|median|p50|p90|p95|p99|avg|mean|streak|hours_since|minutes_since|seconds_since)(_|$)/i;
export const RATIO_METRIC_RE = /(pct|percent|ratio|rate|share|coverage|per_)/i;
export function aggModeFor(metric: PlannedColumn | null | undefined): "sum" | "avg" | "max" {
  if (!metric) return "sum";
  if (metric.kind === "pct" || RATIO_METRIC_RE.test(metric.name)) return "avg";
  if (metric.kind === "money" || metric.kind === "credits" || metric.kind === "gb" || metric.kind === "gb_bytes") return "sum";
  if (LEVEL_METRIC_RE.test(metric.name)) return "max";
  return "sum";
}
// A metric where more is better (coverage, tagged share, success): its worst entity is the LOWEST.
export const HIGHER_IS_BETTER_RE = /(coverage|covered|tagged|protected|masked|success|hit_rate|hit_pct|cache_hit|pass_rate|watched|monitored|uptime)/i;
export function higherIsBetter(metric: PlannedColumn | null | undefined): boolean {
  return !!metric && HIGHER_IS_BETTER_RE.test(metric.name);
}

// A non-id entity column whose own value is not itself readable: the column to show INSTEAD as that
// entity's display name. None today (Snowflake entity columns already carry names); kept so the
// TABLE_ID / BASE_TABLE_ID rename can name its readable twin here.
export const ENTITY_DISPLAY_COL: Record<string, string> = {};

// planColumns(columns, rows, discountPct, orderBy) -- the column PLAN for a finding's data table:
// what order to show them in, which to hide by default (and why), and the fully-resolved
// label/unit/help/numeric for each. `columns`/`rows` are exactly data.columns/data.rows off
// GET /api/finding; `discountPct` is data.discount_pct (the discount is already baked into each
// money column's own `label`, see the _disc handling below); `orderBy` is data.order_by, read only
// for pickKeyMetric's fallback.
export function planColumns(columns: ApiColumn[] | null | undefined, rows: Row[] | null | undefined, discountPct?: number | null, orderBy?: string | null, queryId?: string | null) {
  const cols = columns || [];
  const byName: Record<string, ApiColumn> = {};
  cols.forEach((c) => { byName[c.name] = c; });
  const loadedRows = rows || [];

  // A task or pipe ranks above the warehouse it runs on, a table above its schema and database. A
  // table mixing kinds of resource (cost_daily_by_resource) counts them by resource_key.
  const ENTITY_PRIORITY = [
    "resource_key", "task_full_name", "root_task_name", "job_id", "pipe_name", "dynamic_table_name", "dt_full_name", "alert_full_name", "stage_full_name",
    "table_name", "schema_name", "database_name", "compute_pool_name", "runtime_name", "notebook_name", "model_name", "set_name",
    "listing_global_name", "tag_name", "source_view", "policy_name", "warehouse_id", "warehouse_name", "role_name", "user_name",
  ];
  const entity = ENTITY_PRIORITY.find((n) => byName[n]) || null;
  const entityNoun = entity ? ENTITY_NOUN[entity] || null : null;
  const entityDisplayCol = entity ? (ENTITY_DISPLAY_COL[entity] && byName[ENTITY_DISPLAY_COL[entity]] ? ENTITY_DISPLAY_COL[entity] : null) : null;

  const hideNames = new Set<string>();
  const hideReason: Record<string, string> = {};
  const overrideLabel: Record<string, string> = {};

  // window_days: the "N d window" badge already says this; a column of identical values is noise.
  if (byName.window_days) { hideNames.add("window_days"); hideReason.window_days = "window"; }
  // The root task reads name (id): its own cell carries the id, so the id column is not repeated.
  if (byName.root_task_name && byName.root_task_id) { hideNames.add("root_task_id"); hideReason.root_task_id = "duplicate"; }
  // The same on every row (password_users): shown once as a fact, not per row.
  if (byName.password_users) { hideNames.add("password_users"); hideReason.password_users = "constant"; }

  // A "_disc" twin: at 0% discount its label is byte-identical to the base column's and its values
  // equal the base's, so the (now-redundant) twin is hidden. Once a real discount is set, the twin's
  // label starts with "what-if:" and its values differ, so the base is hidden instead and the twin
  // is renamed to say plainly what it now is.
  cols.forEach((c) => {
    if (!c.name.endsWith("_disc")) return;
    const base = c.name.slice(0, -"_disc".length);
    if (!byName[base]) return;
    const live = !!(c.label && String(c.label).startsWith("what-if"));
    if (live) {
      hideNames.add(base);
      hideReason[base] = "discount";
      const m = String(c.label).match(/-([\d.]+)%/);
      overrideLabel[c.name] = m ? `After your ${m[1]}% discount` : "After your discount";
    } else {
      hideNames.add(c.name);
      hideReason[c.name] = "discount";
    }
  });

  // A column whose value equals an earlier (still-visible) column's on every loaded row is hidden as
  // a duplicate. It compares on the page actually loaded, so it can only hide a genuine duplicate.
  if (loadedRows.length > 0) {
    const survivors = cols.filter((c) => !hideNames.has(c.name));
    for (let i = 0; i < survivors.length; i++) {
      const a = survivors[i];
      if (hideNames.has(a.name)) continue;
      for (let j = i + 1; j < survivors.length; j++) {
        const b = survivors[j];
        if (hideNames.has(b.name)) continue;
        if (loadedRows.every((r) => r[a.name] === r[b.name])) {
          hideNames.add(b.name);
          hideReason[b.name] = "duplicate";
        }
      }
    }
  }

  // A column with no value on any loaded row says nothing ("—" all the way down): hidden.
  const isBlank = (v: any) => v === null || v === undefined || (typeof v === "string" && v.trim() === "");
  if (loadedRows.length > 0) {
    cols.forEach((c) => {
      if (hideNames.has(c.name)) return;
      if (loadedRows.every((r) => isBlank(r[c.name]))) { hideNames.add(c.name); hideReason[c.name] = "empty"; }
    });
  }
  // One account on every row: the Account column repeats what the page already says.
  if (loadedRows.length > 0) {
    [ACCOUNT_COLUMN, "account_name", "account_locator"].forEach((n) => {
      if (!byName[n] || hideNames.has(n)) return;
      const vals = new Set(loadedRows.map((r) => String(r[n] ?? "")));
      if (vals.size === 1) { hideNames.add(n); hideReason[n] = "single_account"; }
    });
  }
  // A bare id next to its own name column (user_id beside user_name) is a duplicate.
  cols.forEach((c) => {
    const m = /^(.*)_id$/.exec(c.name);
    if (!m || c.name === entity || c.name === ACCOUNT_COLUMN || hideNames.has(c.name)) return;
    if (byName[`${m[1]}_name`] && !hideNames.has(`${m[1]}_name`)) { hideNames.add(c.name); hideReason[c.name] = "duplicate"; }
  });

  // account_name: hidden once the account id already resolves to that exact name on every loaded row
  // (the id renders as a named <Ref>), so a text column repeating it is a duplicate.
  if (byName.account_name && byName[ACCOUNT_COLUMN] && loadedRows.length > 0 && typeof resolveName === "function") {
    const allResolve = loadedRows.every((r) => {
      const nm = resolveName("account", acctId(r), acctId(r));
      return !!nm && nm === r.account_name;
    });
    if (allResolve) { hideNames.add("account_name"); hideReason.account_name = "duplicate"; }
  }

  const NUMERIC_KINDS = new Set<string | null | undefined>(["money", "credits", "pct", "hours", "gb", "gb_bytes"]);
  const isNumericCol = (c: ApiColumn) => {
    if (NUMERIC_KINDS.has(c.kind)) return true;
    if (c.kind === "id") return false;
    if (!loadedRows.length) return false;
    let sawNumber = false;
    const allNumericOrEmpty = loadedRows.every((r) => {
      const v = r[c.name];
      if (v === null || v === undefined || v === "") return true;
      if (typeof v === "number" && Number.isFinite(v)) { sawNumber = true; return true; }
      return false;
    });
    return sawNumber && allNumericOrEmpty;
  };

  const toMeta = (c: ApiColumn): PlannedColumn => {
    const meta = columnMeta(c.name, c.kind);
    let unit = meta.unit;
    let label = overrideLabel[c.name] || meta.label;
    // A currency amount (invoice currency) is never a $ figure: own kind, no "$" unit.
    let kindOut = (CURATED[c.name] && CURATED[c.name].kind) || c.kind;
    if (c.kind === "money" && /_amount$/.test(c.name)) { kindOut = "currency"; unit = null; }
    // A price per credit is money, never "N credits".
    if (kindOut === "credits" && /_per_credit$/.test(c.name)) { kindOut = /amount/.test(c.name) ? "currency" : "money"; unit = kindOut === "money" ? "$/credit" : null; }
    // Beside an account name column, the account id column is the locator, so it says so.
    if (c.name === ACCOUNT_COLUMN && byName.account_name && !hideNames.has("account_name")) label = "Account locator";
    // A check whose $ is an upper bound says so in the header.
    if (queryId && typeof UPPER_BOUND_IDS !== "undefined" && UPPER_BOUND_IDS.has(queryId) && c.name === "est_storage_usd_month") {
      label = CURATED.est_storage_usd_month_up_to.label;
    }
    // Header shows label + unit inline, so drop the unit when the label already has it as a word.
    if (unit && new RegExp(`(^|\\s)${escapeRegExp(unit)}(\\s|$)`, "i").test(label.trim())) unit = null;
    return {
      name: c.name,
      // CURATED's own kind, when it names one, overrides classify_columns: only for a handful of
      // columns that ARE a percentage but whose name has no "pct"/"percent" to match.
      kind: kindOut,
      raw: c.name,
      label,
      unit,
      help: meta.help,
      numeric: isNumericCol(c),
    };
  };

  // Numeric columns that are zero (or empty) on every loaded row: never the headline metric.
  const allZero = new Set<string>();
  if (loadedRows.length > 0) {
    cols.forEach((c) => {
      if (loadedRows.every((r) => isBlank(r[c.name]) || Number(r[c.name]) === 0)) allZero.add(c.name);
    });
  }

  // Priority order: the name, then the key metric, then any %, then status and its not-assessed
  // reason, then the other money columns (wasted-first), then credits, then the SQL's own order.
  const orderIndex: Record<string, number> = {};
  cols.forEach((c, i) => { orderIndex[c.name] = i; });
  const visibleRaw = cols.filter((c) => !hideNames.has(c.name));
  const keyMetric = pickKeyMetric(visibleRaw.map(toMeta), entity, firstOrderByColumn(orderBy), allZero);
  const rank = (c: ApiColumn) => {
    if (c.name === entity) return 0;
    if (keyMetric && c.name === keyMetric.name) return 1;
    if (c.kind === "pct" || (CURATED[c.name] && CURATED[c.name].kind === "pct")) return 2;
    if (c.name === "status") return 3;
    if (c.name === "not_assessed_reason") return 3.5; // why a row reads NOT_ASSESSED, next to it
    if (c.kind === "money") return /wasted/i.test(c.name) ? 4 : 4.5;
    if (c.kind === "credits") return /wasted|idle/i.test(c.name) ? 5 : 5.5;
    return 10;
  };
  const orderedVisible = [...visibleRaw].sort((a, b) => {
    const r = rank(a) - rank(b);
    return r !== 0 ? r : orderIndex[a.name] - orderIndex[b.name];
  });
  const orderedHidden = cols.filter((c) => hideNames.has(c.name));
  const visibleMeta = orderedVisible.map(toMeta);

  return {
    entity,
    entityNoun,
    entityDisplayCol,
    // The column a verdict line/chart/grouped table leads with, or null when this table has no
    // numeric column worth headlining (a pure reference/inventory list) -- see pickKeyMetric.
    keyMetric: keyMetric ? (visibleMeta.find((c) => c.name === keyMetric.name) || keyMetric) : null,
    visible: visibleMeta,
    hidden: orderedHidden.map((c) => ({ ...toMeta(c), reason: hideReason[c.name] })),
    totalCount: cols.length,
  };
}
