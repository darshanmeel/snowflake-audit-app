// web/src/api.ts -- a thin fetch wrapper over app/api's JSON endpoints, exported as `Api` and as
// named helpers.
import { HashState } from "./components/hash_state";
import type { Row, TagFilter } from "./types";

// The settings brand, put into index.html by the server (app/api/app.py) so the first paint reads it.
export const BRAND_NAME: string = (window as unknown as { APP_BRAND?: string }).APP_BRAND || "Crosshire";

type Params = Record<string, any>;
type AccountIds = string[] | null | undefined;
type DimKey = "warehouse" | "database" | "schema";
type DimFilter = { warehouse: string[]; database: string[]; schema: string[]; [dim: string]: string[] };


export function qs(params?: Params | null) {
  const parts: string[] = [];
  Object.keys(params || {}).forEach((key) => {
    const value = params![key];
    if (value === undefined || value === null || value === "") return;
    if (Array.isArray(value)) {
      value.forEach((v: any) => parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(v)}`));
    } else {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
    }
  });
  return parts.length ? `?${parts.join("&")}` : "";
}

export async function getJson(path: string, params?: Params) {
  const res = await fetch(path + qs(params), { headers: { Accept: "application/json" } });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const body = await res.json();
      detail = body.detail || detail;
    } catch (e) { /* body was not JSON */ }
    const err = new Error(`${res.status} ${detail}`) as Error & { status?: number };
    err.status = res.status;
    throw err;
  }
  return res.json();
}

// The Settings panel's PUT: the only call here that writes, and only to the local config file.
export async function putJson(path: string, body: any) {
  const res = await fetch(path, {
    method: "PUT",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const parsed = await res.json();
      detail = parsed.detail || detail;
    } catch (e) { /* body was not JSON */ }
    const err = new Error(`${res.status} ${detail}`) as Error & { status?: number };
    err.status = res.status;
    throw err;
  }
  return res.json();
}

// The names the export and the API use for a few things predate this app: the account id column and
// query parameter, the accounts route, the tag rollup's account level and the credits columns of the
// overview checks. Every other file reads them through the constants and helpers below, so those
// spellings live only here.
export const ACCOUNT_COLUMN = "account_id";
export const ACCOUNT_PARAM = "account_ids";
export const ACCOUNTS_PATH = "/api/accounts";
export const ROLLUP_ACCOUNT_LEVEL = "workspace";
export const ROLLUP_ACCOUNT_FILTERED = "workspace_filtered";
export const CREDITS_COLUMNS = ["net_credits", "credits", "net_dbus"];
export const TOTAL_CREDITS_COLUMNS = ["total_net_credits", "total_credits", "total_net_dbus"];
export const SERVERLESS_CREDITS_COLUMNS = ["serverless_net_credits", "serverless_credits", "serverless_net_dbus"];
export const WAREHOUSE_CREDITS_COLUMNS = ["warehouse_net_credits", "warehouse_credits", "classic_net_credits", "classic_net_dbus"];
export function acctId(row: Row | null | undefined) { return row ? row[ACCOUNT_COLUMN] : undefined; }
export function scopeHasAccount(scope: Row | null | undefined) { return !scope || scope["has_" + ACCOUNT_COLUMN] !== false; }
export function excludedNoAccount(data: Row | null | undefined) { return data ? data["excluded_no_account"] : null; }

// The tag filter is module-level state, not a param every caller threads through by hand -- App
// calls Api.setTagFilter(tagFilter) at the top of its own render, before any child (and so before
// any of the calls below) runs. `filters.tag` shape: null, or {groups: [{key, display_key,
// values: [..]}]} (empty values = any value of that name).
export let _tagFilter: TagFilter | null = null;

export function setTagFilter(tag: TagFilter | null | undefined) {
  _tagFilter = tag || null;
}

export function tagFilterKey() {
  return _tagFilter ? JSON.stringify(_tagFilter.groups.map((g) => [g.key, g.values])) : "";
}

// One repeated `tag` param per value ("key:value"), or "key" alone for any value; the server
// unquotes the key, so a ':' or '%' inside it is escaped.
export function _tagParams() {
  if (!_tagFilter) return {};
  const enc = (k: string) => k.replace(/%/g, "%25").replace(/:/g, "%3A");
  return { tag: _tagFilter.groups.flatMap((g) => (g.values.length ? g.values.map((v) => `${enc(g.key)}:${v}`) : [enc(g.key)])) };
}

// The Owner filter (app/core/data._build_filters' owner-like-column match) -- same module-level,
// set-once-per-render shape as the tag filter above.
export let _ownerFilter = "";

export function setOwnerFilter(text: string | null | undefined) {
  _ownerFilter = (text || "").trim();
}

export function ownerFilterKey() {
  return _ownerFilter;
}

export function _ownerParams() {
  return _ownerFilter ? { owner: _ownerFilter } : {};
}

// The warehouse, database and schema filters (contract 11.5): module-level like the two above, read from
// the hash on load ("wh", "db", "sch", "|"-separated so a name with a comma survives). A warehouse or
// database is its name, a schema is DATABASE.SCHEMA. filters.tsx's pickers write them.
export const DIM_PARAM: Record<DimKey, string> = { warehouse: "wh", database: "db", schema: "sch" };
export let _dimFilter: DimFilter = { warehouse: [], database: [], schema: [] };
try {
  const hp = new URLSearchParams((window.location.hash || "").replace(/^#/, ""));
  (Object.keys(DIM_PARAM) as DimKey[]).forEach((dim) => {
    const raw = hp.get(DIM_PARAM[dim]);
    if (raw) _dimFilter[dim] = raw.split("|").filter(Boolean);
  });
} catch (e) { /* no hash: no dimension filter */ }

export function dimFilter() {
  return _dimFilter;
}

export function setDimFilter(next: Partial<Record<DimKey, string[] | null>> | null | undefined) {
  const clean: DimFilter = { warehouse: [], database: [], schema: [] };
  (Object.keys(clean) as DimKey[]).forEach((dim) => { clean[dim] = ((next && next[dim]) || []).filter(Boolean); });
  _dimFilter = clean;
  try {
    const patch: Record<string, string | null> = {};
    (Object.keys(DIM_PARAM) as DimKey[]).forEach((dim) => { patch[DIM_PARAM[dim]] = clean[dim].length ? clean[dim].join("|") : null; });
    if (HashState) HashState.set(patch);
  } catch (e) { /* the hash is a convenience */ }
  try { window.dispatchEvent(new Event("dimfilterchange")); } catch (e) { /* older browser */ }
}

export function dimFilterKey() {
  return JSON.stringify([_dimFilter.warehouse, _dimFilter.database, _dimFilter.schema]);
}

export function _dimParams() {
  const out: Partial<DimFilter> = {};
  if (_dimFilter.warehouse.length) out.warehouse = _dimFilter.warehouse;
  if (_dimFilter.database.length) out.database = _dimFilter.database;
  if (_dimFilter.schema.length) out.schema = _dimFilter.schema;
  return out;
}

// GET /api/finding/{id}/rows.csv (contract 11.6) as a file download. Resolves {filename, rows,
// matching, truncated}; rejects with the server's plain detail (409 = not assessed, 404 = unknown).
export async function downloadFindingCsv(queryId: string, window_: number, accountIds: AccountIds, statuses?: string[] | null, taskId?: string | null) {
  const params = {
    window: window_, [ACCOUNT_PARAM]: accountIds, status: statuses, job_id: taskId,
    ..._tagParams(), ..._ownerParams(), ..._dimParams(),
  };
  const res = await fetch(`/api/finding/${encodeURIComponent(queryId)}/rows.csv${qs(params)}`);
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const body = await res.json();
      detail = body.detail || detail;
    } catch (e) { /* body was not JSON */ }
    const err = new Error(detail) as Error & { status?: number };
    err.status = res.status;
    throw err;
  }
  const disp = res.headers.get("Content-Disposition") || "";
  const m = /filename="?([^";]+)"?/.exec(disp);
  const filename = m ? m[1] : `${queryId}_${window_}d.csv`;
  const blob = await res.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  const num = (h: string) => { const v = res.headers.get(h); return v === null || v === "" ? null : Number(v); };
  return { filename, rows: num("X-Rows"), matching: num("X-Rows-Matching"), truncated: res.headers.get("X-Truncated") === "true" || res.headers.get("X-Truncated") === "1" };
}

export const Api = {
  // The one call App.tsx makes before anything else: {state, settings_error, database}.
  status: () => getJson("/api/status"),
  meta: () => getJson("/api/meta"),
  accounts: () => getJson(ACCOUNTS_PATH),
  // The Settings panel's cost-center picker: {keys, default, suggestions}. PUT validates 1-5
  // non-empty keys and writes config/settings.local.yml; the next request picks it up.
  costCenterSettings: () => getJson("/api/settings/cost-center"),
  saveCostCenterKeys: (keys: string[]) => putJson("/api/settings/cost-center", { keys }),
  // The Settings panel's privacy switch: {mask_user_identities}. Off by default; masks user names and
  // emails only, never a warehouse, database or role name.
  privacySettings: () => getJson("/api/settings/privacy"),
  savePrivacy: (maskUserIdentities: any) => putJson("/api/settings/privacy", { mask_user_identities: !!maskUserIdentities }),
  // The kinds of names the next export or Refresh replaces with tokens (privacy.mask_fields).
  saveMaskFields: (fields: string[]) => putJson("/api/settings/privacy", { mask_fields: fields }),
  dims: () => getJson("/api/dims"),
  coverage: () => getJson("/api/coverage"),
  refreshStatus: () => getJson("/api/refresh"),
  refreshStart: (days: number) => fetch(`/api/refresh${qs({ days })}`, { method: "POST" }).then((r) => r.json()),
  guide: () => getJson("/api/guide"),
  // The check's own read-only SQL with its params filled in (shown lazily on a check's Guide page).
  guideSql: (queryId: string) => getJson(`/api/guide/sql/${encodeURIComponent(queryId)}`),
  setTagFilter,
  tagFilterKey,
  tagParams: _tagParams,
  setOwnerFilter,
  ownerFilterKey,
  dimFilter,
  setDimFilter,
  dimFilterKey,
  dimParams: _dimParams,
  downloadFindingCsv,
  // The warehouse / database pickers' feeds (contract 11.5).
  warehouses: (accountIds: AccountIds) => getJson("/api/warehouses", { [ACCOUNT_PARAM]: accountIds }),
  databases: () => getJson("/api/databases"),
  // Fix these first (11.8): three groups that are never added.
  fixFirst: (window_: number, accountIds: AccountIds, limit?: number) =>
    getJson("/api/fix-first", { window: window_, [ACCOUNT_PARAM]: accountIds, limit, ..._tagParams(), ..._ownerParams(), ..._dimParams() }),
  // Tag compliance (11.7): the required keys setting and the page's feed. `keys` overrides the setting.
  requiredTags: () => getJson("/api/settings/required-tags"),
  saveRequiredTags: (keys: string[]) => putJson("/api/settings/required-tags", { keys }),
  tagCompliance: (window_: number, accountIds: AccountIds, keys?: string[]) =>
    getJson("/api/tags/compliance", { window: window_, [ACCOUNT_PARAM]: accountIds, keys }),
  // The tag picker's feed. `tagKey` (optional) restricts to one key's values.
  tags: (search?: string, tagKey?: string | null, limitKeys?: number, limitValues?: number) => getJson("/api/tags", { search, tag_key: tagKey, limit_keys: limitKeys, limit_values: limitValues }),
  // The stored tag and owner filters ride along on every call below; no caller passes them.
  tagOrigins: (window_: number, accountIds: AccountIds) =>
    getJson("/api/tag_origins", { window: window_, [ACCOUNT_PARAM]: accountIds, ..._tagParams() }),
  findings: (window_: number, accountIds: AccountIds) =>
    getJson("/api/findings", {
      window: window_, [ACCOUNT_PARAM]: accountIds, ..._tagParams(), ..._ownerParams(), ..._dimParams(),
    }),
  // `taskId` scopes a finding to one task server-side (ignored on a finding without a task column);
  // a task-scoped call is already one task, so it carries neither the tag nor the owner filter.
  // `statuses` scopes to those status values server-side, so a tile that needs only flagged rows
  // fetches only those instead of a capped page.
  finding: (queryId: string, window_: number, accountIds: AccountIds, limit?: number, offset?: number, taskId?: string | null, statuses?: string[] | null) =>
    getJson(`/api/finding/${encodeURIComponent(queryId)}`, {
      window: window_,
      [ACCOUNT_PARAM]: accountIds,
      limit,
      offset,
      job_id: taskId,
      status: statuses,
      ...(taskId ? {} : { ..._tagParams(), ..._ownerParams() }),
      ..._dimParams(),
    }),
  // A server-side GROUP BY/SUM (or COUNT/COUNT DISTINCT) over every row matching the filters, with
  // no row cap before the aggregation. `group` is 0-6 real column names; `opts` is {statuses, top,
  // belowFloor, also, pick}.
  aggregate: (queryId: string, window_: number, accountIds: AccountIds, group?: string[] | string | null, agg?: string | null, value?: string | null, opts?: { statuses?: string[] | null; top?: number | null; belowFloor?: any; also?: string[] | null; pick?: string[] | null } | null) => {
    const o = opts || {};

    return getJson(`/api/finding/${encodeURIComponent(queryId)}/aggregate`, {
      window: window_,
      [ACCOUNT_PARAM]: accountIds,
      group,
      agg,
      value,
      status: o.statuses,
      top: o.top,
      below_floor: o.belowFloor,
      // more columns summed per group, and columns read off each group's largest row
      also: o.also,
      pick: o.pick,
      ..._tagParams(),
      ..._ownerParams(),
      ..._dimParams(),
    });
  },
};

