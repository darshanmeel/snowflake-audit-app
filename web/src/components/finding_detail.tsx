// web/src/components/finding_detail.tsx -- the expand-in-place detail: summary first (a verdict
// sentence with real numbers, a top-N chart, a table grouped by the check's own main entity),
// details on click. Renders exactly one of the four/five honesty-rule cards (PLAN.md 6.2) for a
// non-ok_rows outcome -- never a generic "no data" fallback, and an empty outcome never reads as
// "no problems".

// The first fetch grabs up to this many rows in one go (the same cap useFindingData uses for a
// chart or tile that needs the WHOLE table) so the verdict line, the chart and the grouped table are
// all computed from the real data. "Load more" (raw view only, and only once a table's true row
// count exceeds this) still pages in PAGE_SIZE-sized chunks.
import React from "react";
import { ACCOUNT_COLUMN, Api, acctId, scopeHasAccount } from "../api";
import { fmtCell, fmtDayShort, fmtInt, fmtMoney, isNumericValue } from "../format";
import { CopyLinkButton } from "./hash_state";
import { FixCopyButton } from "./fixcopy_button";
import { Names, Ref, TaskFocus, resolveName, useNames } from "./names";
import { DimNotAppliedChip, dimAppliedFromScope } from "./filters";
import { Badge, Card, STATUS_WORD, StatusPill, Tip, bandOf, bandPillKind } from "./primitives";
import { getCheckLabel, reasonFix } from "./labels";
import { shortId } from "./charts";
import { RankedBars } from "./charts_more";
import { FindingScopeBadge, NOT_BUILT_READING, isNotBuilt, notAssessedText } from "./scope";
import { aggModeFor, columnMeta, curatedColumnLabel, higherIsBetter, humanizeColumnName, planColumns, sortOrderNote } from "./columns";
import { withoutTotalRows } from "../tabs/tab_area";
import { guideLinkProps } from "./guide";
import type { ApiColumn, PlannedColumn } from "./columns";
import type { Row } from "../types";

/** The column plan planColumns builds for a check's table. */
export type ColumnPlan = ReturnType<typeof planColumns>;
/** A singular/plural noun pair ("warehouse"/"warehouses"). */
export interface Noun { s: string; p: string }

/** A check's header as GET /api/finding sends it: its guidance text, actions and related checks. */
export interface FindingHeader {
  title?: string | null;
  actions?: string[] | null;
  read_this?: string | null;
  healthy?: string | null;
  investigate_if?: string | null;
  caveats?: string | null;
  empty_if?: string[] | null;
  next?: { query_id: string; [key: string]: any }[] | null;
  stars?: any;
  confidence?: string | null;
  confidence_note?: string | null;
  not_assessed_reasons?: Record<string, string> | null;
  [key: string]: any;
}

/** One GET /api/finding response: rows, columns, outcome and the facts the detail reads by name. */
export interface FindingData {
  query_id: string;
  outcome: string;
  header: FindingHeader;
  columns?: ApiColumn[] | null;
  rows: Row[];
  rows_total: number;
  offset: number;
  [key: string]: any;
}

/** A check's materiality floor: {min, unit, label} plus how many rows sat under it. */
export interface Floor {
  min?: number | null;
  unit?: string | null;
  label?: string | null;
  rows_below?: number;
  [key: string]: any;
}

/** One distinct entity of a check, aggregated over every loaded row for it. */
export interface EntityGroup {
  mapKey: string;
  id: any;
  name: any;
  accountId: any;
  count: number;
  noEntity: boolean;
  worstRank: number;
  worstStatus: string | null;
  sum: number;
  hasMetric: boolean;
  min: number;
  max: number;
  days?: Set<string>;
  avg: number | null;
  /** The key metric combined the way it adds up: a sum, an average (a %) or the largest (an age). */
  agg: number | null;
}

export interface EntitySummary {
  entity: string;
  refKind: string | null;
  metric: PlannedColumn | null;
  list: EntityGroup[];
}

export interface GrainCounts { size: number; counts: Record<string, number> }

/** One library correction for a check: what is wrong, its effect and the fix. */
export interface LibraryCorrection { id: string; status: string; problem?: string; effect?: string; fix?: string; [key: string]: any }

export const INITIAL_LIMIT = 5000;
// Grouping, status counts and totals are worked out from the fetched rows, so a check is read in
// full up to this many rows rather than judged from its first page.
export const FULL_FETCH_CAP = 50000;
export const PAGE_SIZE = 100;

export function firstSentence(text: any): string {
  if (!text) return "";
  const m = String(text).match(/^(.*?[.!?])(\s|$)/);
  return (m ? m[1] : String(text)).trim();
}

export function capitalize(s: string): string {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

// Which Ref kind (names.tsx) an "id"-kind column renders as, detected by column NAME alone. A column
// this does not recognise keeps its raw fallback (fmtCell), never a blank.
export function refKindForColumn(name: string): string | null {
  if (name === ACCOUNT_COLUMN) return "account";
  if (name === "task_full_name" || name === "job_id") return "task";
  if (name === "warehouse_id" || /_warehouse_id$/.test(name)) return "warehouse";
  return null;
}
// A task or account column links by its name, whatever kind the server gave it: the task checks
// carry no resource_type and their task column is plain text.
export function cellRefKind(name: string, kind: string | null | undefined): string | null {
  if (kind === "id" || name === "task_full_name" || name === "job_id" || name === ACCOUNT_COLUMN) return refKindForColumn(name);
  return null;
}

// A mixed-resource row (cost_daily_by_resource): its key as "name (id)" from the type's own columns,
// so the leading column is never a bare "warehouse:1001".
export function resourceLabel(row: Row): React.ReactNode {
  if (row.is_other) return `Other ${row.resource_type}s${row.pooled_count != null ? ` (${row.pooled_count})` : ""}`;
  if (row.resource_type === "warehouse" && row.warehouse_id) return <Ref kind="warehouse" id={row.warehouse_id} accountId={acctId(row)} />;
  if (row.resource_type === "task" && row.task_full_name) return <Ref kind="task" id={row.task_full_name} accountId={acctId(row)} />;
  const name = row.pipe_name || row.warehouse_name || row.task_full_name;
  const id = row.pipe_id || row.warehouse_id || row.task_id;
  return name ? (id ? `${name} (${id})` : name) : row.resource_key;
}

// A day/date-grain column, by name alone: "day" and "usage_date" are this library's two spellings; a
// check with neither has no day grain and its verdict line says "row", not "day".
export function findDayColumn(rawCols: { name: string }[] | null | undefined): string | null {
  const hit = (rawCols || []).find((c) => /^day$/i.test(c.name) || /_date$/i.test(c.name));
  return hit ? hit.name : null;
}

export const STATUS_TO_BADGE_KIND: Record<string, string> = { CRITICAL: "critical", WARN: "warn", OK: "ok", NOT_ASSESSED: "not_assessed" };
export function statusBadgeKind(status: string): string { return STATUS_TO_BADGE_KIND[status] || "reference"; }
export function statusColorVar(status: string | null): string {
  return ({ CRITICAL: "var(--st-crit)", WARN: "var(--st-warn)", OK: "var(--st-ok)", NOT_ASSESSED: "var(--st-na)" } as Record<string, string>)[status as string]
    || "var(--st-ref)";
}
export function rankOfStatus(status: any): number | undefined {
  return ({ CRITICAL: 0, WARN: 1, NOT_ASSESSED: 2, OK: 3 } as Record<string, number | undefined>)[status];
}
// Rows arrive worst-status-first, so tallying the LOADED page already gives the exact true count for
// every status rank ahead of the one the load ran out on; only that rank can be an undercount, so
// it reads "X+".
export function statusCutRank(rows: Row[] | null | undefined, rowsTotal: number): number | null | undefined {
  if (!rows || !rows.length || rows.length >= rowsTotal) return null;
  return rankOfStatus(rows[rows.length - 1].status);
}
export function countLabel(n: number, isCut: boolean): string { return `${fmtInt(n)}${isCut ? "+" : ""}`; }

export function tallyStatusCounts(rows: Row[] | null | undefined): Record<string, number> {
  const counts: Record<string, number> = {};
  (rows || []).forEach((r) => {
    const s = r.status;
    if (s === null || s === undefined) return;
    counts[s] = (counts[s] || 0) + 1;
  });
  return counts;
}

// The noun a verdict line/chart/table counts in -- the check's own entity ("warehouse"), combined
// with "-day" when the grain also has a day column (query_pruning_effectiveness's "warehouse-
// day"), or a bare "row"/"day" when there is no entity to name at all.
export function grainNounFor(plan: ColumnPlan, dayCol: string | null): Noun {
  if (plan.entity && plan.entityNoun) {
    return dayCol
      ? { s: `${plan.entityNoun.s}-day`, p: `${plan.entityNoun.s}-days` }
      : plan.entityNoun;
  }
  return dayCol ? { s: "day", p: "days" } : { s: "row", p: "rows" };
}

// The verdict line counts distinct GRAIN UNITS, never raw rows: one entity when the check has no day
// column, one (entity, day) pair when it does, so "N <noun> CRITICAL" always counts the same units
// the noun names. Returns null when the check has no entity at all: the raw per-row tally is exactly
// right then, since each row already IS the grain unit.
export function buildGrainCounts(rows: Row[] | null | undefined, plan: ColumnPlan, dayCol: string | null, hasStatus: boolean): GrainCounts | null {
  const entity = plan.entity;
  if (!entity) return null;
  const compositeKey = entity === "task_full_name" || entity === "job_id";
  const counts: Record<string, number> = { CRITICAL: 0, WARN: 0, NOT_ASSESSED: 0, OK: 0 };
  const RANK_STATUS = ["CRITICAL", "WARN", "NOT_ASSESSED", "OK"];
  const map = new Map<string, number | null>();
  // A total or tie-out row is never summed next to its parts.
  withoutTotalRows(rows || []).forEach((row: Row) => {
    const raw = row[entity];
    if (raw === null || raw === undefined || raw === "") return;
    const entityKey = compositeKey ? `${acctId(row)}:${raw}` : String(raw);
    const key = dayCol ? `${entityKey}|${row[dayCol]}` : entityKey;
    if (!hasStatus) { map.set(key, null); return; }
    const r = rankOfStatus(row.status);
    const rr = r === undefined ? 4 : r;
    const cur = map.get(key);
    if (cur === undefined || rr < (cur as number)) map.set(key, rr);
  });
  if (hasStatus) {
    map.forEach((rank) => { if ((rank as number) <= 3) counts[RANK_STATUS[rank as number]] += 1; });
  }
  return { size: map.size, counts };
}

// A metric value shown next to a name in the verdict line: fmtCell already appends a unit for a
// classified kind (money/credits/pct/hours/gb); a plain count is rounded like every other count and
// gets the column's own unit or label, so a verdict figure never reads as a bare digit.
export const UNIT_CARRYING_KINDS = new Set(["money", "currency", "credits", "pct", "hours", "gb", "gb_bytes"]);
export function metricValueText(metric: PlannedColumn | null | undefined, value: any, row?: Row) {
  if (!metric || !isNumericValue(value)) return null;
  if (UNIT_CARRYING_KINDS.has(metric.kind as string)) return fmtCell(value, metric.kind, row);
  const suffix = metric.unit || metric.label;
  const numText = fmtInt(Math.round(Number(value)));
  return suffix ? `${numText} ${suffix}` : numText;
}

// A resolved name that is not unique among this check's own entities (one warehouse name matching
// several ids) reads as if it named one thing when it does not: it is disambiguated with the
// account it belongs to, or a short id when even that repeats.
export function disambiguateName(name: any, id: any, accountId: any, list: { name: any }[] | null | undefined): any {
  if (!name || !list || list.length < 2) return name;
  const dupes = list.filter((g) => g.name === name).length;
  if (dupes <= 1) return name;
  const wsName = accountId !== undefined && accountId !== null
    ? resolveName("account", accountId, accountId)
    : null;
  const tag = wsName || (id !== undefined && id !== null ? shortId(id) : null);
  return tag ? `${name} (${tag})` : name;
}

// "worst: name — value on 16 Sep" / "largest: name — value": the row the check's own ORDER BY put
// first, named in plain words, only when there is something worth pointing at.
export function worstEntityClause(plan: ColumnPlan, worstRow: Row | null, band: string | null, rawCols: { name: string }[] | null | undefined, entitySummary: EntitySummary | null): string | null {
  if (!worstRow || !plan.entity) return null;
  if (band !== "CRITICAL" && band !== "WARN" && band !== "RANKED") return null;
  const rawId = worstRow[plan.entity];
  if (rawId === null || rawId === undefined || rawId === "") return null;
  const refKind = refKindForColumn(plan.entity);
  let name = refKind ? (resolveName(refKind, acctId(worstRow), rawId) || String(rawId)) : String(rawId);
  if (refKind) name = disambiguateName(name, rawId, acctId(worstRow), entitySummary && entitySummary.list);
  let metricText = "";
  if (plan.keyMetric) {
    const v = metricValueText(plan.keyMetric, worstRow[plan.keyMetric.name], worstRow);
    if (v) metricText = ` — ${v}`;
  }
  const dayCol = findDayColumn(rawCols);
  const dateText = dayCol && worstRow[dayCol] ? ` on ${fmtDayShort(worstRow[dayCol])}` : "";
  const verb = band === "RANKED" ? "largest" : "worst";
  return `${verb}: ${name}${metricText}${dateText}`;
}

// Same sort GroupedTable renders by (worst status first when it means something, else the key
// metric, else row count), so the verdict line never names a different entity than the first row.
// `moneyFirst`: the table view leads with the largest $ (status second); the verdict's "worst"
// keeps status first. A higher-is-better metric (coverage) ranks its LOWEST value worst.
export function sortEntityGroups(list: EntityGroup[], metric: PlannedColumn | null | undefined, statusMeaningful: boolean, moneyFirst = false): EntityGroup[] {
  const asc = higherIsBetter(metric);
  const byMetric = (a: EntityGroup, b: EntityGroup) => {
    const av = a.agg;
    const bv = b.agg;
    if (av === null && bv === null) return 0;
    if (av === null) return 1;
    if (bv === null) return -1;
    return asc ? (av as number) - (bv as number) : (bv as number) - (av as number);
  };
  const leadMoney = moneyFirst && !!metric && metric.kind === "money";
  return [...list].sort((a, b) => {
    if (leadMoney) {
      const m = byMetric(a, b);
      if (m !== 0) return m;
    }
    if (statusMeaningful) {
      const r = a.worstRank - b.worstRank;
      if (r !== 0) return r;
    }
    if (metric) {
      const m = byMetric(a, b);
      if (m !== 0) return m;
    }
    return b.count - a.count;
  });
}

// "worst: name — total" / "largest: name — total" from the entity the grouped table leads with (its
// aggregated total or average, not one day's peak).
export function worstGroupClause(topGroup: EntityGroup | null, plan: ColumnPlan, band: string | null, list: EntityGroup[] | null | undefined): string | null {
  if (!topGroup) return null;
  if (band !== "CRITICAL" && band !== "WARN" && band !== "RANKED") return null;
  const rawName = topGroup.name || String(topGroup.id);
  const name = disambiguateName(rawName, topGroup.id, topGroup.accountId, list);
  const metric = plan.keyMetric;
  let metricText = "";
  if (metric && topGroup.hasMetric) {
    const v = metricValueText(metric, topGroup.agg);
    if (v) metricText = ` — ${v}`;
  }
  const verb = band === "RANKED" ? "largest" : "worst";
  return `${verb}: ${name}${metricText}`;
}

// The one verdict sentence: counts by status in the check's own grain noun, plus the entity that
// matters most -- everything a reader used to have to infer from a wide raw table, in one line.
// The headline counts distinct grain units (buildGrainCounts); a raw-row total that collapsed onto
// fewer units is kept as a parenthetical ("4 grantees CRITICAL (3,432 rows)").
export function buildVerdictText(data: FindingData, plan: ColumnPlan, band: string | null, hasStatus: boolean, statusCounts: Record<string, number>, worstRow: Row | null, topGroup: EntityGroup | null, entitySummary: EntitySummary | null): string {
  const dayCol = findDayColumn(data.columns);
  const noun = grainNounFor(plan, dayCol);
  const plural = (n: number, w: Noun) => (n === 1 ? w.s : w.p);
  const cutRank = statusCutRank(data.rows, data.rows_total);
  const grain = plan.entity ? buildGrainCounts(data.rows, plan, dayCol, hasStatus) : null;
  const total = grain ? grain.size : data.rows_total;
  const counts = grain ? grain.counts : statusCounts;
  const rawNote = (word: string) => {
    if (!grain) return "";
    const raw = (statusCounts && statusCounts[word]) || 0;
    const distinct = counts[word] || 0;
    return raw > distinct ? ` (${fmtInt(raw)} rows)` : "";
  };

  let main: string;
  if (!hasStatus) {
    main = `${fmtInt(total)} ${plural(total, noun)}`;
  } else if (band === "RANKED") {
    main = plan.keyMetric
      ? `${fmtInt(total)} ${plural(total, noun)} ranked by ${plan.keyMetric.label}`
      : `${fmtInt(total)} ${plural(total, noun)}`;
  } else {
    const critC = counts.CRITICAL || 0;
    const warnC = counts.WARN || 0;
    if (critC > 0 || warnC > 0) {
      const raw: [string, string, string][] = [];
      if (critC > 0) raw.push([countLabel(critC, cutRank === 0), "CRITICAL", rawNote("CRITICAL")]);
      if (warnC > 0) raw.push([countLabel(warnC, cutRank === 1), "WARN", rawNote("WARN")]);
      main = raw.map(([label, word, note], i) => `${label}${i === 0 ? ` ${plural(critC || warnC, noun)}` : ""} ${word}${note}`).join(", ");
    } else {
      const okC = counts.OK || 0;
      const naC = counts.NOT_ASSESSED || 0;
      if (okC > 0 && naC === 0) main = `${fmtInt(total)} ${plural(total, noun)}, all OK`;
      else if (naC > 0 && okC === 0) main = `${fmtInt(total)} ${plural(total, noun)}, none could be judged (not assessed)`;
      else main = `${fmtInt(total)} ${plural(total, noun)}: ${fmtInt(okC)} OK, ${fmtInt(naC)} not assessed`;
    }
  }

  const clause = topGroup
    ? worstGroupClause(topGroup, plan, band, entitySummary && entitySummary.list)
    : worstEntityClause(plan, worstRow, band, data.columns, entitySummary);
  const sentence = clause ? `${main}; ${clause}` : main;
  return `${sentence}.`;
}

// A bare snake_case token inside an action SENTENCE -- a column name (scaling_hint) or another
// check's own query_id (cost_dollarized_by_sku_day) -- read as raw code to anyone outside this
// codebase. Never matches the ALL-CAPS enum values (SCALE_UP_MEMORY) those sentences also carry;
// those are already meant to read as fixed vocabulary, not a column to translate.
export const ACTION_TOKEN_RE = /\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/g;
export function actionToken(name: string): string {
  const curated = curatedColumnLabel(name);
  if (curated) return curated;
  const check = getCheckLabel(name);
  if (check.title !== name) return check.title;
  return humanizeColumnName(name);
}

// header.actions[0] is already this check's own most-immediate fix (a list, most-actionable
// first) -- cut to its first clause (the full multi-branch instruction is one click away, in
// Details' own Actions list) and every raw column name or query_id inside it turned into its
// plain label, so the one line shown by default never reads as SQL.
export function actionLine(actions: any[] | null | undefined): string | null {
  if (!actions || !actions.length) return null;
  let s = String(actions[0]).trim();
  const cut = s.search(/;| - /);
  if (cut > 0) s = s.slice(0, cut);
  s = s.replace(ACTION_TOKEN_RE, actionToken).replace(/[;,]+$/, "").trim();
  if (!s) return null;
  if (!/[.!?]$/.test(s)) s += ".";
  return s;
}

// One (entity, worst status, row count, key-metric total) per distinct entity value, computed from
// every loaded row (up to INITIAL_LIMIT): the source both the grouped table and the top-N chart read
// from, so the two can never disagree. A task is unique only within an account, so tasks group on
// account id + full name. A row with NO entity value lands in one explicit "(no <entity>)" group
// instead of vanishing.

export function buildEntitySummary(rows: Row[] | null | undefined, plan: ColumnPlan, hasStatus: boolean, dayCol: string | null): EntitySummary | null {
  const entity = plan.entity;
  if (!entity) return null;
  const refKind = refKindForColumn(entity);
  const metric = plan.keyMetric;
  const displayCol = plan.entityDisplayCol;
  const noEntityName = `(no ${(plan.entityNoun && plan.entityNoun.s) || "entity"})`;
  const compositeKey = entity === "task_full_name" || entity === "job_id";
  const map = new Map<string, Omit<EntityGroup, "avg" | "agg">>();
  (rows || []).forEach((row: Row) => {
    const raw = row[entity];
    const hasEntity = raw !== null && raw !== undefined && raw !== "";
    const mapKey = hasEntity ? (compositeKey ? `${acctId(row)}:${raw}` : String(raw)) : "\u0000none";
    let g = map.get(mapKey);
    if (!g) {
      g = {
        mapKey, id: hasEntity ? raw : null,
        name: hasEntity ? null : noEntityName,
        accountId: acctId(row), count: 0, noEntity: !hasEntity,
        worstRank: 5, worstStatus: null, sum: 0, hasMetric: false, min: Infinity, max: -Infinity,
      };
      map.set(mapKey, g);
    }
    g.count += 1;
    // Several rows can share a day (per statement type, per error): days are counted once.
    if (dayCol && row[dayCol] != null) (g.days || (g.days = new Set())).add(String(row[dayCol]));
    if (hasStatus) {
      const r = rankOfStatus(row.status);
      const rr = r === undefined ? 4 : r;
      if (rr < g.worstRank) { g.worstRank = rr; g.worstStatus = row.status; }
    }
    if (metric) {
      const v = row[metric.name];
      if (typeof v === "number" && Number.isFinite(v)) {
        g.sum += v;
        g.hasMetric = true;
        if (v < g.min) g.min = v;
        if (v > g.max) g.max = v;
      }
    }
    // A non-id entity column already IS the name; an id entity with its own display column shows
    // THAT instead of the raw id.
    if (hasEntity && !refKind && g.name === null) g.name = displayCol ? (row[displayCol] || raw) : raw;
  });
  const mode = aggModeFor(metric);
  const list = Array.from(map.values()).map((g) => {
    const avg = g.hasMetric ? g.sum / g.count : null;
    return {
      ...g,
      name: g.noEntity ? g.name : (refKind ? (resolveName(refKind, g.accountId, g.id) || null) : g.name),
      avg,
      agg: !g.hasMetric ? null : mode === "avg" ? avg : mode === "max" ? g.max : g.sum,
    };
  });
  return { entity, refKind, metric, list };
}

// Starred, needs-confirmation and scope read as detail, not verdict, so they live here with
// everything else a reader only needs on request.
export interface GuidanceProps {
  header: FindingHeader;
  queryId: string;
  hasStatus: boolean;
  stars?: any;
  confidenceNote?: string | null;
  scopeBadge?: React.ReactNode;
}

export function Guidance({ header, queryId, hasStatus, stars, confidenceNote, scopeBadge }: GuidanceProps) {
  // Fully collapsed by default: the verdict line already carries the numbers.
  const [open, setOpen] = React.useState(false);
  const fields: [string, React.ReactNode][] = ([
    ["What this is", header.read_this],
    ["Healthy looks like", header.healthy],
    ["Investigate if", header.investigate_if],
    ["Caveats", header.caveats],
  ] as [string, React.ReactNode][]).filter(([, v]) => v && !String(v).toLowerCase().startsWith("n/a"));
  if (hasStatus) fields.push(["Status bands", columnMeta("status", null).help]);
  if (stars) fields.push(["Starred", "Marked as a priority check to watch."]);
  if (confidenceNote) fields.push(["Needs confirmation", confidenceNote]);
  if (scopeBadge) fields.push(["Scope", scopeBadge]);

  return (
    <div className={`guidance ${open ? "open" : ""}`}>
      <div className="g-lede">
        <button type="button" className="g-toggle" onClick={() => setOpen(!open)} aria-expanded={open}>
          {open ? "Hide how to read this" : "How to read this and what to do"}
        </button>
      </div>
      {open && (
        <React.Fragment>
          <div className="d-grid">
            {fields.map(([k, v]) => (
              <div className="d-field" key={k}>
                <div className="k">{k}</div>
                <div className="v">{v}</div>
              </div>
            ))}
          </div>
          {header.actions && header.actions.length > 0 && (
            <div className="d-actions">
              <div className="k" style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
                <span>Actions</span>
                <FixCopyButton text={header.actions.map((a, i) => `${i + 1}. ${a}`).join("\n")} />
              </div>
              <ol>{header.actions.map((a, i) => <li key={i}>{a}</li>)}</ol>
            </div>
          )}
          <a className="g-guide-link" {...guideLinkProps(queryId)}>{"How this check works →"}</a>
        </React.Fragment>
      )}
    </div>
  );
}

// The corrections register's own entries for this query_id, if any: a small "N known issue(s)" /
// "corrected" badge that opens the full problem/effect/fix list on click. Renders nothing when the
// array is empty (the common case).
export function LibraryIssueBadge({ corrections }: { corrections?: LibraryCorrection[] | null }) {
  const [open, setOpen] = React.useState(false);
  if (!corrections || corrections.length === 0) return null;
  const allFixed = corrections.every((c) => c.status === "fixed");
  const label = allFixed ? "corrected" : `${corrections.length} known issue${corrections.length === 1 ? "" : "s"}`;
  const kind = allFixed ? "ok" : "warn";
  return (
    <div className={`guidance lib-corrections ${open ? "open" : ""}`}>
      <button type="button" className="lib-badge-trigger" onClick={() => setOpen(!open)}
        title={allFixed ? "This check's query was corrected after review; click for what changed and why." : "Known issues with this check's query; click for their effect on the numbers."}>
        <Badge kind={kind}>{label}</Badge>
      </button>
      {open && (
        <div className="d-grid" style={{ gridTemplateColumns: "minmax(0, 1fr)" }}>
          {corrections.map((c) => (
            <div className="d-field" key={c.id}>
              <div className="k">
                <Badge kind={c.status === "fixed" ? "ok" : "warn"}>
                  {c.status === "fixed" ? "Corrected" : "Not fixed yet"}
                </Badge>
              </div>
              <div className="v">
                <div><b>What's wrong: </b>{c.problem}</div>
                <div><b>Effect on this finding: </b>{c.effect}</div>
                <div><b>{c.status === "fixed" ? "Fix: " : "Fix or plan: "}</b>{c.fix}</div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// A source classified as name-lookup-only or partially exported never blocks a finding (it still
// computes), but the finding is not perfectly clean either: this renders a small note saying exactly
// what is degraded or partial and why, on top of whichever outcome card the finding reached.
export const NAME_COLUMN_LABEL: Record<string, string> = {
  account_name: "Account names",
  task_name: "Task names",
  warehouse_name: "Warehouse names",
};

export function DataQualityNote({ data }: { data: FindingData }) {
  const degraded: Row[] = data.degraded_sources || [];
  const partial: Row[] = data.partial_sources || [];
  if (degraded.length === 0 && partial.length === 0) return null;
  return (
    <div className="honest-card warn dq-note">
      <div className="h-title">Partial data</div>
      {degraded.map((s) => (
        <div className="h-note" key={`degraded-${s.source}`}>
          {NAME_COLUMN_LABEL[s.degrades] || "Names"} could not be looked up, so ids show instead
          -- <span className="mono">{s.source}</span>{s.reason ? ` (${s.reason})` : ""}
        </div>
      ))}
      {partial.map((s) => (
        <div className="h-note" key={`partial-${s.source}`}>
          <span className="mono">{s.source}</span> only exported part of its window
          {s.missing_days && s.missing_days.length > 0
            ? ` -- missing ${s.missing_days.join(", ")}`
            : ""}
          {s.reason ? ` (${s.reason})` : ""}
        </div>
      ))}
    </div>
  );
}

export function EmptyIfList({ tokens }: { tokens?: string[] | null }) {
  if (!tokens || !tokens.length) return null;
  return (
    <div>
      <div className="d-field"><div className="k">Why this could be empty</div></div>
      <ul>
        {tokens.map((t) => (
          <li key={t}>{String(t).replace(/_/g, " ")}</li>
        ))}
      </ul>
    </div>
  );
}

// A raw source name ("ACCOUNT_USAGE.QUERY_HISTORY") reads better as its last, plain-word segment
// than as a dotted identifier: used only for the one-line summary; the raw name still appears
// verbatim in Details, since that is what a reader would look up on docs.snowflake.com.
export function friendlySourceName(src: any): string {
  if (!src) return "unknown source";
  const last = String(src).split(".").pop();
  return last!.replace(/_/g, " ");
}

// `info.message` is the export's raw error text (can be a multi-line dump): the card shows one line
// naming why the check did not run, with the raw text and the per-source detail behind Details.
// A row that reads OK only because it sits under the check's materiality floor: grey "Under $50",
// never a green pass. `floor` is the finding's own {min, unit, label}.
export function floorWord(floor: Floor | null | undefined): string {
  if (!floor || floor.min == null) return "Under floor";
  return floor.unit === "USD" ? `Under ${fmtMoney(floor.min, 0)}` : `Under ${fmtInt(floor.min)}`;
}
export function isUnderFloor(row: Row | null | undefined): boolean {
  return !!(row && row.below_floor && (row.status === "OK" || !row.status));
}
// The whole check is under its floor: it has rows, every one of them below the floor, none flagged.
export function checkUnderFloor(floor: Floor | null | undefined, rowsTotal: number | null | undefined, band: string | null): boolean {
  return !!(floor && band === "OK" && (floor.rows_below as number) > 0 && (rowsTotal as number) > 0);
}

// Rows of one check as a CSV file (contract 11.6) with the page filters, and any status or task scope passed in. A 409 (check not
// assessed) or any other refusal shows the server's own one-line reason next to the button.
export interface RowsCsvButtonProps {
  queryId: string;
  windowDays: number;
  accountIds: string[] | null | undefined;
  statuses?: string[] | null;
  taskId?: string | null;
  className?: string;
  label?: string;
}

export function RowsCsvButton({ queryId, windowDays, accountIds, statuses, taskId, className, label }: RowsCsvButtonProps) {
  const [state, setState] = React.useState<{ busy: boolean; note: string | null; error: string | null }>({ busy: false, note: null, error: null });
  const click = (e?: React.MouseEvent) => {
    if (e) { e.stopPropagation(); e.preventDefault(); }
    setState({ busy: true, note: null, error: null });
    Api.downloadFindingCsv(queryId, windowDays, accountIds, statuses, taskId)
      .then((r: any) => setState({
        busy: false, error: null,
        note: r.truncated ? `Capped: ${fmtInt(r.rows)} of ${fmtInt(r.matching)} rows in the file.` : (r.rows != null ? `${fmtInt(r.rows)} rows saved.` : null),
      }))
      .catch((err: any) => setState({
        busy: false, note: null,
        error: err.status === 409 ? `Not assessed: ${err.message}` : `Could not download: ${err.message}`,
      }));
  };
  return (
    <span className="csv-rows-wrap">
      <button type="button" className={className || "csv-download-btn"} disabled={state.busy} onClick={click}
        title="Download every row of this check for the window, accounts and tag, owner and warehouse filters, as a CSV file.">
        {state.busy ? "…" : (label || "Download rows (CSV)")}
      </button>
      {state.note && <span className="muted csv-rows-note">{` ${state.note}`}</span>}
      {state.error && <span className="csv-rows-note chart-note-oneline">{` ${state.error}`}</span>}
    </span>
  );
}

// Lines under the verdict that come from the check's own /api/findings row: money the check could not
// price (shown as "-", never $0), and flagged rows that are not entities of the counted noun.
export function RowFacts({ row, rows }: { row: Row | null; rows: Row[] | null | undefined }) {
  if (!row) return null;
  // password_users is the same on every row, so it is hidden per row and read once here.
  const pw = rows && rows[0] && typeof rows[0].password_users === "number" ? rows[0].password_users : null;
  const a = row.affected;
  const other = a && a.flagged_other > 0 ? a.flagged_other : 0;
  const unpriced = row.money_reason === "unpriced";
  if (!other && !unpriced && pw === null) return null;
  return (
    <div className="scope-note">
      {pw !== null && <div>{`${fmtInt(pw)} ${pw === 1 ? "user signs" : "users sign"} in with a password.`}</div>}
      {unpriced && <div>{"$ -, not priced: no price was available for this check's usage."}</div>}
      {other > 0 && <div>{`${fmtInt(other)} more flagged row${other === 1 ? "" : "s"} that ${other === 1 ? "is" : "are"} not ${a.noun || "objects"}, for example a remainder line. Counted in the $, not in the "N of M" above.`}</div>}
    </div>
  );
}

// The role could see only part of what a check lists (SHOW WAREHOUSES needs MONITOR).
export function VisibilityNote({ row }: { row: Row | null }) {
  const v = row && row.visibility;
  if (!v || !v.limited) return null;
  return <div className="scope-note">{v.note || `Role sees ${fmtInt(v.visible)} of ${fmtInt(v.billed)} billed ${v.unit || "warehouses"}.`}</div>;
}

export function NotAssessedCard({ data, row }: { data: FindingData; row: Row | null }) {
  const info: Row = data.status_info || {};
  const [open, setOpen] = React.useState(false);
  const blocking: Row[] = info.blocking_sources || [];
  const oneLine = isNotBuilt(data) ? NOT_BUILT_READING
    : (blocking.length > 0
      ? `Source not ok: ${blocking.map((s) => friendlySourceName(s.source)).join(", ")}.`
      : notAssessedText(data));
  const hasDetail = !!(info.message || info.error_class || blocking.length > 0);
  const na = row && row.not_assessed;
  return (
    <div className="honest-card not_assessed">
      <div className="h-title">Not assessed</div>
      <div className="h-note">{oneLine}</div>
      <div className="h-note">Unknown for now: not a clean result, and not $0.</div>
      {na && na.requires && <div className="h-note">{`Needs: ${na.requires}`}</div>}
      {na && na.code && reasonFix(na.code) && <div className="h-note">{reasonFix(na.code)}</div>}
      {na && na.grants && na.grants.length > 0 && (
        <div className="h-note">
          <div>{"To open it, run as an admin:"}</div>
          <ul>{na.grants.map((g: string, i: number) => <li key={i} className="mono">{g}</li>)}</ul>
        </div>
      )}
      {hasDetail && (
        <React.Fragment>
          <button type="button" className="g-toggle" onClick={() => setOpen(!open)} aria-expanded={open}>
            {open ? "Hide why it did not run" : "Why it did not run"}
          </button>
          {open && (
            <div className="d-grid" style={{ gridTemplateColumns: "minmax(0, 1fr)" }}>
              {info.error_class && (
                <div className="d-field"><div className="k">Error</div><div className="v mono">{info.error_class}</div></div>
              )}
              {blocking.length > 0 && (
                <div className="d-field">
                  <div className="k">Sources not ok</div>
                  <div className="v">
                    <ul>
                      {blocking.map((s) => (
                        <li key={s.source}>
                          <span className="mono">{s.source}</span> -- {s.state}
                          {s.reason ? ` (${s.reason})` : ""}
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>
              )}
              {info.message && (
                <div className="d-field"><div className="k">Raw error</div><div className="v mono">{info.message}</div></div>
              )}
            </div>
          )}
        </React.Fragment>
      )}
    </div>
  );
}

// "A longer window may have rows" only makes sense on a windowed check; raw source names and states
// sit behind Details instead of an always-open list.
export function EmptyWindowCard({ data }: { data: FindingData }) {
  const cov: Row = data.window_coverage || {};
  const sources: Record<string, Row> = cov.sources || {};
  const [open, setOpen] = React.useState(false);
  return (
    <div className="honest-card empty_window">
      <div className="h-title">Nothing in window</div>
      {data.header.healthy && !data.header.healthy.toLowerCase().startsWith("n/a") && (
        <div className="h-note">{data.header.healthy}</div>
      )}
      <div className="h-note">
        Nothing matched in this window. This is not a verified zero -- see the source coverage
        below before reading it as "no problems".
      </div>
      {data.windowed && <div className="h-note">A longer window may have rows for this.</div>}
      <EmptyIfList tokens={data.header.empty_if} />
      {Object.keys(sources).length > 0 && (
        <React.Fragment>
          <button type="button" className="g-toggle" onClick={() => setOpen(!open)}>
            {open ? "hide source coverage" : "Source coverage"}
          </button>
          {open && (
            <ul>
              {Object.entries(sources).map(([src, info]) => (
                <li key={src}>
                  {friendlySourceName(src)} -- {info.state || "unknown"}
                  {info.partial ? " (partial -- snapshot shorter than this window)" : ""}
                  {" "}<span className="mono muted">{src}</span>
                </li>
              ))}
            </ul>
          )}
        </React.Fragment>
      )}
    </div>
  );
}

// A materiality floor (config/materiality.yml) already moved every below-floor CRITICAL/WARN row to
// OK before this data reached the browser; floor.label is the full plain-word phrase. Nothing renders
// when this check has no floor, or the floor caught nothing.
export function FloorLine({ floor }: { floor: Floor | null | undefined }) {
  if (!floor || !floor.rows_below) return null;
  const n = floor.rows_below;
  return (
    <div className="floor-line muted">
      {`${fmtInt(n)} row${n === 1 ? "" : "s"} under ${floor.label} not judged.`}
    </div>
  );
}

export function EmptyFiltersCard({ data }: { data: FindingData }) {
  return (
    <div className="honest-card empty_filters">
      <div className="h-title">Excluded by current filters</div>
      <div className="h-note">
        {fmtInt(data.rows_in_window)} row{data.rows_in_window === 1 ? "" : "s"} exist in this
        window, but the current Account, tag and owner filters exclude every one of them.
      </div>
    </div>
  );
}

export function ErrorCard({ data }: { data: FindingData }) {
  return (
    <div className="honest-card error">
      <div className="h-title">Could not read this table</div>
      <div className="h-note mono">{data.error}</div>
      <div className="h-note">
        The local database file can be briefly locked while an export loads. Reload to retry.
      </div>
    </div>
  );
}

// The box below is the one thing that scrolls sideways for a wide finding. Its own horizontal
// scrollbar sits at the BOTTOM of a 460px box, easy to miss, so this ref + these handlers are the
// "is there more, and how much" signal: a muted count above the box, a fading right edge and a
// click-to-scroll button, all driven by comparing the scrollable width against what is visible, and
// all three disappear together the moment nothing is cut off.
export function useHorizontalScrollCue(depsKey: string) {
  const wrapRef = React.useRef<HTMLDivElement>(null);
  const [state, setState] = React.useState({ needsScroll: false, scrolledLeft: false, moreCols: 0 });

  const measure = React.useCallback(() => {
    const el = wrapRef.current;
    if (!el) return;
    const needsScroll = el.scrollWidth > el.clientWidth + 1;
    const scrolledLeft = el.scrollLeft > 0;
    let moreCols = 0;
    if (needsScroll) {
      const visibleRight = el.scrollLeft + el.clientWidth;
      el.querySelectorAll<HTMLElement>("table.data thead th").forEach((th) => {
        if (th.offsetLeft + th.offsetWidth > visibleRight + 4) moreCols += 1;
      });
    }
    setState({ needsScroll, scrolledLeft, moreCols });
  }, []);

  React.useEffect(() => {
    measure();
    const el = wrapRef.current;
    if (!el || typeof ResizeObserver === "undefined") return undefined;
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [depsKey, measure]);

  const scrollMore = () => {
    const el = wrapRef.current;
    if (el) el.scrollBy({ left: el.clientWidth * 0.8, behavior: "smooth" });
  };

  return { wrapRef, ...state, onScroll: measure, scrollMore };
}

// What a hidden column's own reason (columns.tsx's planColumns) reads as in the Columns menu.
export function hideReasonText(reason: string | undefined) {
  return ({
    window: "same on every row -- the window chip above already says this",
    discount: "superseded by the discounted column",
    duplicate: "identical to another visible column",
    empty: "no value on any row",
    single_account: "one account on every row",
  } as Record<string, string>)[reason as string] || reason;
}

// A small "Columns (N hidden)" menu -- replaces the old always-on "N columns -- scroll sideways"
// sentence and the plain show/hide button with one compact trigger that also says WHY each column
// is hidden (columns.tsx already computes the reason; nothing showed it before this).
export function ColumnsMenu({ plan, showAll, onToggleAll }: { plan: ColumnPlan; showAll: boolean; onToggleAll: () => void }) {
  const [open, setOpen] = React.useState(false);
  const boxRef = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => {
    if (!open) return undefined;
    const onDocClick = (e: MouseEvent) => { if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false); };
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDocClick);
    document.addEventListener("keydown", onEsc);
    return () => {
      document.removeEventListener("mousedown", onDocClick);
      document.removeEventListener("keydown", onEsc);
    };
  }, [open]);
  if (!plan.hidden.length) return null;
  return (
    <div className="ws-picker columns-menu" ref={boxRef}>
      <button type="button" className="ws-trigger" onClick={() => setOpen((o) => !o)}>
        {`Columns (${plan.hidden.length} hidden)`} <span className="caret">{open ? "▴" : "▾"}</span>
      </button>
      {open && (
        <div className="ws-pop">
          <div className="ws-list">
            {plan.hidden.map((c) => (
              <div className="ws-row columns-hidden-row" key={c.name}>
                <span className="ws-name">{c.label}</span>
                <span className="muted">{hideReasonText(c.reason)}</span>
              </div>
            ))}
          </div>
          <div className="ws-foot">
            <button type="button" className="ck-link" onClick={() => { onToggleAll(); setOpen(false); }}>
              {showAll ? "Hide these again" : `Show all ${plan.totalCount} columns`}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

export function DataTable({ data, plan, onLoadMore, loadingMore }: { data: FindingData; plan: ColumnPlan; onLoadMore: () => void; loadingMore: boolean }) {
  const loaded = data.rows || [];
  const [showAll, setShowAll] = React.useState(false);
  const cols = showAll ? [...plan.visible, ...plan.hidden] : plan.visible;
  // Largest $ first by default; a header click sorts by that column instead (again flips it).
  const moneyKey = plan.keyMetric && plan.keyMetric.kind === "money" ? plan.keyMetric.name : null;
  const [sort, setSort] = React.useState<{ col: string | null; desc: boolean }>({ col: moneyKey, desc: true });
  const rows = React.useMemo(() => {
    if (!sort.col) return loaded;
    const c = sort.col;
    const num = (v: any) => (isNumericValue(v) ? Number(v) : null);
    return [...loaded].sort((a, b) => {
      const av = a[c], bv = b[c];
      const an = num(av), bn = num(bv);
      let r: number;
      if (an !== null && bn !== null) r = an - bn;
      else if (an === null && bn === null) r = String(av ?? "").localeCompare(String(bv ?? ""));
      else return an === null ? 1 : -1; // blanks last either way
      return sort.desc ? -r : r;
    });
  }, [loaded, sort.col, sort.desc]);
  const onSort = (name: string) => setSort((cur) => (cur.col === name ? { col: name, desc: !cur.desc } : { col: name, desc: true }));
  const scrollCue = useHorizontalScrollCue(`${cols.length}:${rows.length}`);

  // One line stating the $ basis ONCE for the whole table, instead of repeating "(list price
  // (effective))" after every money header (the old per-header suffix this replaces). The
  // compared string is app/api/service.py's own est_label text, which now matches format.tsx's
  // client-side estLabel word for word.
  const rawCols = data.columns || [];
  const moneyCol = rawCols.find((c) => c.kind === "money" && c.label);
  const moneyNote = moneyCol
    ? (moneyCol.label === "list price (effective)"
        ? "$ = your effective rate, not your invoice line by line"
        : `$ = ${moneyCol.label}`)
    : null;

  return (
    <div>
      {moneyNote && <div className="data-money-note muted">{moneyNote}</div>}
      <div className="data-table-bar">
        <ColumnsMenu plan={plan} showAll={showAll} onToggleAll={() => setShowAll(!showAll)} />
        {/* Above the table, never over its header row. */}
        {scrollCue.needsScroll && scrollCue.moreCols > 0 && (
          <button type="button" className="data-scroll-more" onClick={scrollCue.scrollMore}>
            &rarr; {scrollCue.moreCols} more column{scrollCue.moreCols === 1 ? "" : "s"}
          </button>
        )}
      </div>
      <div className="data-table-outer">
      <div
        className={`data-table-wrap ${scrollCue.scrolledLeft ? "scrolled" : ""}`}
        ref={scrollCue.wrapRef}
        onScroll={scrollCue.onScroll}
      >
        <table className="data">
          <thead>
            <tr>
              {cols.map((c) => (
                <th key={c.name} className="th-sortable" onClick={() => onSort(c.name)}
                  aria-sort={sort.col === c.name ? (sort.desc ? "descending" : "ascending") : "none"}>
                  <Tip text={`${c.help ? `${c.help} ` : ""}column: ${c.raw}`} placement="down">
                    <div className="th-label">
                      {c.label}
                      {c.unit && <span className="th-unit">{" "}{c.unit}</span>}
                      {sort.col === c.name && <span className="th-sort">{sort.desc ? " ↓" : " ↑"}</span>}
                    </div>
                  </Tip>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, i) => (
              <tr key={i} className={row.below_floor ? "row-below-floor" : undefined}>
                {cols.map((c) => {
                  const value = row[c.name];
                  const statusClass = c.name === "status" && value ? ` status-${value}` : "";
                  const refKind = cellRefKind(c.name, c.kind);
                  const hasValue = value !== null && value !== undefined && value !== "";
                  let content: React.ReactNode;
                  if (c.name === "status" && isUnderFloor(row)) {
                    content = <StatusPill kind="reference" word={floorWord(data.floor)} />;
                  } else if (refKind && hasValue) {
                    content = <Ref kind={refKind} id={value} accountId={acctId(row)} />;
                  } else if (c.name === "resource_key" && hasValue) {
                    content = resourceLabel(row);
                  } else if (c.name === "not_assessed_reason" && hasValue) {
                    // The header's own not_assessed_reasons dict puts this code into words, never the
                    // raw code a reader has no way to look up.
                    const words = data.header && data.header.not_assessed_reasons;
                    content = (words && words[value]) || value;
                  } else {
                    content = fmtCell(value, c.kind, row);
                  }
                  return (
                    <td
                      key={c.name}
                      className={(c.numeric ? "num" : c.kind === "id" ? "id" : "") + statusClass}
                    >
                      {content}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {scrollCue.needsScroll && scrollCue.moreCols > 0 && <div className="data-scroll-fade" />}
      </div>
      {data.truncated && (
        <div className="data-truncated-note muted">
          Worst {fmtInt(data.truncated_max_rows)} rows shown; the check returned more.
        </div>
      )}
      <div className="data-foot">
        <span className="muted mono">
          Showing {fmtInt(data.offset + rows.length)} of {fmtInt(data.rows_total)} rows
          {data.order_by ? ` -- ${sortOrderNote(data.order_by)}` : ""}
        </span>
        {data.offset + rows.length < data.rows_total && (
          <button className="load-more" disabled={loadingMore} onClick={onLoadMore}>
            {loadingMore ? "Loading..." : `Load ${Math.min(PAGE_SIZE, data.rows_total - data.offset - rows.length)} more`}
          </button>
        )}
      </div>
    </div>
  );
}

// The default view for a check with a real entity: one row per entity, worst status first, the
// key metric aggregated across it -- exactly what the old wide daily-rows table forced a reader
// to reconstruct in their head. "Total" for an additive figure (money/credits/hours/GB/a plain
// count); "Average" for a rate (a pct column) -- summing a percentage across rows is meaningless.
// A check whose entity has real cardinality (hundreds of jobs/tables) would otherwise turn
// "grouped" into just as long a scroll as the raw table it replaces -- capped at a page, same as
// the raw table's own "Load more", with a plain "Show all N" past it rather than silently cutting
// the list.
export const GROUPED_PAGE_SIZE = 25;

// T-75B review should-fix "grouped table headers are unclear": "Rows" reads as "Days" when the
// check groups by day (each row already IS one day for that entity); the metric column says
// Total/Avg up front instead of only in its hover tip.
export function GroupedTable({ summary, plan, statusMeaningful, dayCol }: { summary: EntitySummary; plan: ColumnPlan; statusMeaningful: boolean; dayCol: string | null }) {
  const [showAll, setShowAll] = React.useState(false);
  const noun = plan.entityNoun || { s: "row", p: "rows" };
  const metric = plan.keyMetric;
  const mode = aggModeFor(metric);
  const sortedAll = sortEntityGroups(summary.list, metric, statusMeaningful, true);
  const sorted = showAll ? sortedAll : sortedAll.slice(0, GROUPED_PAGE_SIZE);
  const countWord = dayCol ? "Days" : "Rows";
  const metricPrefix = mode === "avg" ? "Avg" : mode === "max" ? "Largest" : "Total";
  const metricWord = mode === "avg" ? "Average" : mode === "max" ? "Largest" : "Total";
  return (
    <div className="data-table-outer">
      <table className="data">
        <thead>
          <tr>
            <th>
              <Tip text={`One row = one ${noun.s}, combining every loaded row for it.`} placement="down">
                <div className="th-label">{capitalize(noun.s)}</div>
              </Tip>
            </th>
            {statusMeaningful && (
              <th>
                <Tip text={columnMeta("status", null).help} placement="down">
                  <div className="th-label">Worst status</div>
                </Tip>
              </th>
            )}
            <th>
              <Tip text={`How many of the loaded ${dayCol ? "days" : "rows"} this ${noun.s} covers.`} placement="down">
                <div className="th-label">{countWord}</div>
              </Tip>
            </th>
            {metric && (
              <th>
                <Tip
                  text={`${metricWord} ${metric.label}${metric.help ? ` -- ${metric.help}` : ""}, across every row for this ${noun.s}.`}
                  placement="down"
                >
                  <div className="th-label">
                    {metricPrefix} {metric.label}
                    {metric.unit && <span className="th-unit">{" "}{metric.unit}</span>}
                  </div>
                </Tip>
              </th>
            )}
          </tr>
        </thead>
        <tbody>
          {sorted.map((g) => (
            <tr key={g.mapKey}>
              <td className={summary.refKind && !g.noEntity ? "id" : ""}>
                {summary.refKind && !g.noEntity
                  ? <Ref kind={summary.refKind} id={g.id} accountId={g.accountId} />
                  : (g.name || String(g.id))}
              </td>
              {statusMeaningful && (
                <td className={g.worstStatus ? `status-${g.worstStatus}` : ""}>
                  {g.worstStatus
                    ? <Badge kind={statusBadgeKind(g.worstStatus)}>{STATUS_WORD[statusBadgeKind(g.worstStatus)]}</Badge>
                    : <span className="muted">{"—"}</span>}
                </td>
              )}
              <td className="num">{fmtInt(dayCol && g.days ? g.days.size : g.count)}</td>
              {metric && (
                <td className="num">
                  {g.hasMetric ? (
                    <Tip text={`min ${fmtCell(g.min, metric.kind)} · max ${fmtCell(g.max, metric.kind)} across ${fmtInt(g.count)} ${g.count === 1 ? noun.s : noun.p}`}>
                      {fmtCell(g.agg, metric.kind)}
                    </Tip>
                  ) : <span className="muted">{"—"}</span>}
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
      {sortedAll.length > GROUPED_PAGE_SIZE && (
        <div className="data-foot">
          <span className="muted mono">
            Showing {fmtInt(sorted.length)} of {fmtInt(sortedAll.length)} {noun.p}
          </span>
          <button type="button" className="load-more" onClick={() => setShowAll(!showAll)}>
            {showAll ? "Show fewer" : `Show all ${fmtInt(sortedAll.length)} ${noun.p}`}
          </button>
        </div>
      )}
    </div>
  );
}

// T-75B review must-fix 3 (accepted fallback: "or at least mark the table as partial"): the
// entity summary is built only from the rows this page actually fetched (INITIAL_LIMIT), so a
// check with more rows than that has a grouped table/chart built from a subset -- said here
// rather than silently shown as if it were the whole table.
export function PartialGroupNote({ data }: { data: FindingData }) {
  if (!data.rows || data.rows.length >= data.rows_total) return null;
  return (
    // Reuses data-money-note's own spacing (styles.css, owned by another branch right now) rather
    // than adding a new selector to a file two tasks are editing at once.
    <div className="data-money-note muted">
      {`Grouped from the first ${fmtInt(data.rows.length)} of ${fmtInt(data.rows_total)} rows -- totals below may be undercounts.`}
    </div>
  );
}

// The toggle between the grouped default and the old raw-rows view -- only shown when this check
// actually has an entity to group by; a check with none (or a pure reference list with nothing to
// aggregate) just shows the raw table, exactly as before.
export interface FindingTableSectionProps {
  data: FindingData;
  plan: ColumnPlan;
  canGroup: boolean;
  entitySummary: EntitySummary | null;
  statusMeaningful: boolean;
  dayCol: string | null;
  loadingMore: boolean;
  onLoadMore: () => void;
}

export function FindingTableSection({ data, plan, canGroup, entitySummary, statusMeaningful, dayCol, loadingMore, onLoadMore }: FindingTableSectionProps) {
  const [showRaw, setShowRaw] = React.useState(!canGroup);
  const title = !canGroup ? "Rows" : (showRaw ? "All rows" : `By ${plan.entityNoun!.s}`);
  const toggle = canGroup && (
    <button type="button" className="table-mode-toggle" onClick={() => setShowRaw(!showRaw)}>
      {showRaw ? `Group by ${plan.entityNoun!.s}` : `Show all rows (${fmtInt(data.rows_total)})`}
    </button>
  );
  return (
    <Card title={title} right={toggle}>
      {(!canGroup || showRaw)
        ? <DataTable data={data} plan={plan} loadingMore={loadingMore} onLoadMore={onLoadMore} />
        : (
          <React.Fragment>
            <PartialGroupNote data={data} />
            <GroupedTable summary={entitySummary!} plan={plan} statusMeaningful={statusMeaningful} dayCol={dayCol} />
          </React.Fragment>
        )}
    </Card>
  );
}

// Top N entities by the key metric, bars coloured by worst status -- skipped entirely (both here
// and by the caller) when there is no entity+numeric metric pair worth plotting. A magnitude-only
// ranking (RANKED band, e.g. cost_by_job) draws one uniform colour instead: status is not
// meaningful there, so colouring by it would imply a verdict the check never makes.
export function EntityChart({ summary, plan, statusMeaningful, data }: { summary: EntitySummary | null; plan: ColumnPlan; statusMeaningful: boolean; data: FindingData }) {
  if (!summary || !plan.keyMetric) return null;
  const metric = plan.keyMetric;
  const mode = aggModeFor(metric);
  const asc = higherIsBetter(metric);
  const items = summary.list
    .filter((g) => g.hasMetric)
    .map((g) => ({
      name: summary.refKind ? g.name : (g.name || String(g.id)),
      id: summary.refKind && !g.noEntity ? g.id : undefined,
      accountId: g.accountId,
      // A higher-is-better metric charts its shortfall, so the worst still draws longest.
      value: (asc && metric.kind === "pct" ? Math.max(0, 100 - (g.agg as number)) : g.agg) as number,
      // Status rides on the dot before the label; the bar stays neutral.
      dot: statusMeaningful ? statusColorVar(g.worstStatus) : undefined,
    }));
  // Every value zero: nothing to rank, so no chart at all (never a "Nothing to plot" box).
  if (!items.length || items.every((it) => !(Number(it.value) > 0))) return null;
  const word = mode === "avg" ? "average " : mode === "max" ? "largest " : "";
  const title = asc && metric.kind === "pct" ? `Lowest ${metric.label}: gap to 100%` : `Top ${Math.min(10, items.length)} by ${word}${metric.label}`;
  const onItemClick = summary.refKind === "task" ? (it: any) => TaskFocus.open(it.accountId, it.id) : null;
  return (
    <Card title={title}>
      <PartialGroupNote data={data} />
      <RankedBars
        items={items}
        n={10}
        valueFmt={(v: number) => fmtCell(v, metric.kind) as string}
        unitLabel={metric.unit || metric.label}
        ariaLabel={`Top entities by ${metric.label}`}
        onItemClick={onItemClick}
      />
    </Card>
  );
}

// One short line of links to related checks ("Also check: Disk spills · Shuffle-heavy queries"),
// replacing the old "next: <title> -- <if>" chips -- a related check this page's own findingsIndex
// does not know about is skipped rather than falling back to its raw query_id.
export function RelatedChecks({ next, findingsIndex, onJumpTo }: { next: { query_id: string }[] | null | undefined; findingsIndex: Record<string, Row> | null | undefined; onJumpTo: (queryId: string) => void }) {
  const items = (next || [])
    .map((n) => ({ queryId: n.query_id, target: findingsIndex && findingsIndex[n.query_id] }))
    .filter((x) => x.target);
  if (!items.length) return null;
  return (
    <div className="related-checks">
      <span className="related-checks-label">Also check:</span>
      {items.map((x, i) => (
        <React.Fragment key={x.queryId}>
          {i > 0 && <span className="related-checks-sep">{"·"}</span>}
          <button type="button" className="related-checks-link" onClick={() => onJumpTo(x.queryId)}>
            {x.target!.title}
          </button>
        </React.Fragment>
      ))}
    </div>
  );
}

// P4-T-IDX (section 5.7): one line from scope.tag, only while a tag filter is actually set
// (data.tag is non-null -- app/api/app.py's own "tag": {...} | null echo).
export function TagScopeLine({ data }: { data: FindingData }) {
  const tag = data && data.tag;
  const scopeTag = data && data.scope && data.scope.tag;
  if (!tag || !scopeTag) return null;
  const text = scopeTag.applied
    ? `Tag filter applied by: ${scopeTag.chain_label}.`
    : `Tag filter not applied: ${scopeTag.reason}`;
  return <div className="scope-note">{text}</div>;
}

export interface FindingDetailProps {
  queryId: string;
  windowDays: number;
  accountIds: string[] | null | undefined;
  onJumpTo: (queryId: string) => void;
  findingsIndex?: Record<string, Row> | null;
}

export function FindingDetail({ queryId, windowDays, accountIds, onJumpTo, findingsIndex }: FindingDetailProps) {
  // Subscribes this component to Names' cache: a name that finishes loading after plan/entitySummary
  // were first computed must re-render, or the verdict line and chart keep showing raw ids.
  useNames();
  const [data, setData] = React.useState<FindingData | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [loadError, setLoadError] = React.useState<string | null>(null);
  const [loadingMore, setLoadingMore] = React.useState(false);

  const load = React.useCallback((offset: number, append: boolean) => {
    const setBusy = offset > 0 ? setLoadingMore : setLoading;
    setBusy(true);
    const limit = offset === 0 ? INITIAL_LIMIT : PAGE_SIZE;
    Api.finding(queryId, windowDays, accountIds, limit, offset)
      .then((d: FindingData) => {
        setLoadError(null);
        setData((prev) => {
          if (append && prev && prev.rows) {
            return { ...d, rows: [...prev.rows, ...d.rows] };
          }
          return d;
        });
      })
      .catch((err: any) => setLoadError(err.message || String(err)))
      .finally(() => setBusy(false));
    // Api.finding reads the module-level tag and owner filters, not props: they are dependencies so
    // "Load more" never appends rows fetched under a new filter onto a page fetched under the old.
  }, [queryId, windowDays, JSON.stringify(accountIds), Api.tagFilterKey(), Api.ownerFilterKey(), Api.dimFilterKey()]);

  React.useEffect(() => {
    let live = true;
    setData(null);
    setLoading(true);
    (async () => {
      try {
        const first: FindingData = await Api.finding(queryId, windowDays, accountIds, INITIAL_LIMIT, 0);
        let rows: Row[] = first.rows || [];
        const want = Math.min(first.rows_total || 0, FULL_FETCH_CAP);
        while (live && first.outcome === "ok_rows" && rows.length < want) {
          const next: FindingData = await Api.finding(queryId, windowDays, accountIds, INITIAL_LIMIT, rows.length);
          if (!next.rows || !next.rows.length) break;
          rows = rows.concat(next.rows);
        }
        if (live) { setLoadError(null); setData({ ...first, rows }); }
      } catch (err: any) {
        if (live) setLoadError(err.message || String(err));
      } finally {
        if (live) setLoading(false);
      }
    })();
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryId, windowDays, JSON.stringify(accountIds), Api.tagFilterKey(), Api.ownerFilterKey(), Api.dimFilterKey()]);

  const isOkRows = !!(data && data.outcome === "ok_rows");
  const rawCols: ApiColumn[] = isOkRows ? (data!.columns || []) : [];
  const rows: Row[] = isOkRows ? (data!.rows || []) : [];
  const dayCol = React.useMemo(() => findDayColumn(rawCols), [rawCols]);
  // Names.isReady() as a dep: an id column resolved via resolveName inside planColumns or
  // buildEntitySummary must recompute once names finish loading.
  const plan = React.useMemo(
    () => planColumns(rawCols, rows, data && data.discount_pct, data && data.order_by, data && data.query_id),
    [rawCols, rows, data && data.discount_pct, data && data.order_by, Names.isReady()]
  );
  const hasStatus = rawCols.some((c) => c.name === "status");
  const statusCounts = React.useMemo<Record<string, number>>(() => (hasStatus ? tallyStatusCounts(rows) : {}), [rows, hasStatus]);
  const band = data
    ? bandOf({ outcome: data.outcome, status_counts: (isOkRows && hasStatus) ? statusCounts : null, query_id: data.query_id })
    : null;
  const statusMeaningful = hasStatus && band !== "RANKED";
  const entitySummary = React.useMemo(
    () => (isOkRows ? buildEntitySummary(rows, plan, hasStatus, dayCol) : null),
    [rows, plan, hasStatus, isOkRows, dayCol, Names.isReady()]
  );
  const canGroup = !!(entitySummary && entitySummary.list.length > 0);
  // A check with no status column, or whose every entity has only one row (a plain reference list),
  // has nothing for grouping to add: it keeps the plain raw table and no chart.
  const groupingMeaningful = canGroup && hasStatus && entitySummary!.list.some((g) => g.count > 1);
  const topGroup = canGroup ? sortEntityGroups(entitySummary!.list, plan.keyMetric, statusMeaningful)[0] : null;

  if (loading && !data) return <div className="loading-note">Loading this check...</div>;
  if (loadError && !data) return <div className="honest-card error"><div className="h-title">Could not load this finding</div><div className="h-note mono">{loadError}</div></div>;
  if (!data) return null;

  const header = data.header;
  const findingRow = (findingsIndex && findingsIndex[queryId]) || null;
  const underFloor = checkUnderFloor(data.floor, data.rows_total, band);
  const worstRow = isOkRows && rows.length > 0 ? rows[0] : null;
  const verdictText = isOkRows ? buildVerdictText(data, plan, band, hasStatus, statusCounts, worstRow, topGroup, entitySummary) : null;
  const fixText = isOkRows && (band === "CRITICAL" || band === "WARN") ? actionLine(header.actions) : null;

  return (
    <div className="detail-wrap">
      <div className="d-head">
        <div>
          <div className="d-title">{getCheckLabel(data.query_id, header.title).title}</div>
          <div className="d-meta">
            {band && (underFloor ? <StatusPill kind="reference" word={floorWord(data.floor)} /> : <StatusPill kind={bandPillKind(band)} />)}
            <Badge kind="info">{data.windowed ? `${data.window_days} d window` : "snapshot"}</Badge>
            <DimNotAppliedChip dimApplied={dimAppliedFromScope(data.scope)} />
          </div>
        </div>
        {/* FindingsTable syncs its expanded query_id to location.hash, so the address already reopens here. */}
        <div className="d-head-actions" style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
          {isOkRows && <RowsCsvButton queryId={queryId} windowDays={windowDays} accountIds={accountIds} />}
          <CopyLinkButton label="Copy link to this finding" />
        </div>
      </div>

      <LibraryIssueBadge corrections={data.library_corrections} />

      {isOkRows && (
        <React.Fragment>
          <div className="verdict-line">{verdictText}</div>
          <RowFacts row={findingRow} rows={rows} />
          <VisibilityNote row={findingRow} />
          <FloorLine floor={data.floor} />
          {fixText && <div className="fix-line"><b>Fix now: </b>{fixText}</div>}
          {groupingMeaningful && (
            <EntityChart summary={entitySummary} plan={plan} statusMeaningful={statusMeaningful} data={data} />
          )}
          <FindingTableSection
            data={data}
            plan={plan}
            canGroup={groupingMeaningful}
            entitySummary={entitySummary}
            statusMeaningful={statusMeaningful}
            dayCol={dayCol}
            loadingMore={loadingMore}
            onLoadMore={() => load(data.offset + data.rows.length, true)}
          />
        </React.Fragment>
      )}

      {/* The outcome card for a non-ok_rows result IS this finding's content, so it comes first. */}
      {data.outcome === "not_assessed" && <NotAssessedCard data={data} row={findingRow} />}
      {data.outcome === "error" && <ErrorCard data={data} />}
      {data.outcome === "ok_empty_window" && <EmptyWindowCard data={data} />}
      {data.outcome === "ok_empty_filters" && <EmptyFiltersCard data={data} />}

      <Guidance
        header={header}
        queryId={queryId}
        hasStatus={hasStatus}
        stars={header.stars}
        confidenceNote={header.confidence === "needs_confirmation" ? header.confidence_note : null}
        scopeBadge={data.scope && !scopeHasAccount(data.scope) ? <FindingScopeBadge scope={data.scope} /> : null}
      />
      <RelatedChecks next={header.next} findingsIndex={findingsIndex} onJumpTo={onJumpTo} />

      <div style={{ marginTop: 14 }}>
        <TagScopeLine data={data} />
        {data.outcome !== "not_assessed" && data.outcome !== "error" && (
          <DataQualityNote data={data} />
        )}
      </div>
    </div>
  );
}
