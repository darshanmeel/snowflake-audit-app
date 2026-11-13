// web/src/components/area_access_log.tsx -- who touched what: Activity › Access log (one object, every user,
// role and client, per day or hour), PII › Tags (a tag's objects, who can read them, who did), and the
// suggested-tags and downloads blocks of PII. The log is read through /api/access/log*, never whole.
import React from "react";
import { getJson } from "../api";
import { fmtDayShort, fmtInt } from "../format";
import { numOrZero, useFindingAgg } from "./hooks";
import type { ApPageProps } from "./area_pages";
import { IssueTile } from "./blocks";
import { Columns } from "./charts_more";
import { ChartCard } from "./primitives";
import { SummaryTileRow } from "./overview_tile";
import { Slot, isFlagged, useAggCheck, useCheck, useLede } from "./area_ai_storage";
import { CxChip, CxObjName, CxStat, CxTable } from "./cx_e";
import type { Row } from "../types";

const plural = (n: number, one: string) => `${fmtInt(n)} ${n === 1 ? one : `${one}s`}`;
const day = (v: any) => (v ? fmtDayShort(String(v).slice(0, 10)) : "–");
const at = (v: any, grain: string) => (!v ? "–" : grain === "hour" ? `${day(v)} ${String(v).slice(11, 16)}` : day(v));
const sqlLit = (s: string) => `'${s.replace(/'/g, "''")}'`;

/** A GET that keeps only the answer to the last request. */
function useJson(path: string | null, params: Record<string, any>): { data: any; err: string | null; loading: boolean } {
  const [st, setSt] = React.useState<{ data: any; err: string | null; loading: boolean }>({ data: null, err: null, loading: false });
  const key = JSON.stringify(params);
  React.useEffect(() => {
    if (!path) return undefined;
    let live = true;
    setSt({ data: null, err: null, loading: true });
    getJson(path, params).then((d) => { if (live) setSt({ data: d, err: null, loading: false }); })
      .catch((e) => { if (live) setSt({ data: null, err: String(e.message || e), loading: false }); });
    return () => { live = false; };
  }, [path, key]);   // eslint-disable-line react-hooks/exhaustive-deps
  return st;
}

/** The SQL a reader runs in Snowflake for the single queries behind one object: ids, times, user, role, no text. */
function detailSql(object: string, start: string, end: string): string {
  // QUERY_HISTORY bounded to the same days: unbounded, the join scans a year of it
  return [
    "SELECT DISTINCT ah.query_id, ah.query_start_time, ah.user_name, q.role_name, q.query_type,",
    "       f.value:\"objectDomain\"::STRING AS object_domain",
    "FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah",
    "CROSS JOIN LATERAL FLATTEN(input => ARRAY_CAT(ARRAY_CAT(ah.base_objects_accessed, ah.objects_modified),",
    "                                              ARRAY_CONSTRUCT_COMPACT(ah.object_modified_by_ddl))) f",
    "LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q ON q.query_id = ah.query_id",
    `  AND q.start_time >= ${sqlLit(start)} AND q.start_time < DATEADD(day, 1, ${sqlLit(end)})`,
    `WHERE UPPER(f.value:"objectName"::STRING) = ${sqlLit(object)}`,
    `  AND ah.query_start_time >= ${sqlLit(start)} AND ah.query_start_time < ${sqlLit(end)}`,
    "ORDER BY ah.query_start_time DESC;",
  ].join("\n");
}

/** Every day (or hour) from start to end, so quiet ones read as zero rather than vanish. */
function allBuckets(start: string, end: string, grain: string): string[] {
  const step = grain === "hour" ? 3600e3 : 864e5, n = grain === "hour" ? 13 : 10, out: string[] = [];
  for (let t = Date.parse(`${start}T00:00:00Z`); t < Date.parse(`${end}T00:00:00Z`); t += step) out.push(new Date(t).toISOString().slice(0, n));
  return out;
}

/** The note when the export cut the log at its row cap: older days are incomplete. */
function CutNote({ d }: { d: any }) {
  if (!d?.truncated) return null;
  return <CxStat>{`The export kept the newest rows only (row cap reached): counts before ${day(d.complete_from)} are incomplete.`}</CxStat>;
}

function Sensitivity({ v }: { v: string | null | undefined }) {
  if (v === "tagged") return <CxChip status="WARN">sensitive</CxChip>;
  if (v === "suggested") return <CxChip>looks sensitive</CxChip>;
  return null;
}

// ═══════════════════════ Activity › Access log ═══════════════════════

let startObject = "";   // set by a link from another page; the page mounts fresh on navigation
export function openInAccessLog(p: ApPageProps, name: string) {
  startObject = name;
  p.goTo({ tab: "activity", subtab: "accesslog", focusQueryId: null });
}

export function ApActivityAccessLog(p: ApPageProps) {
  const c = useAggCheck(p, "sf_use_access_log", [], "read_queries", []);
  const ran = !c.loading && !c.why;
  const [typed, setTyped] = React.useState("");
  const [search, setSearch] = React.useState("");
  // one request when typing pauses, not one full scan of the log per key
  React.useEffect(() => { const t = setTimeout(() => setSearch(typed.trim()), 300); return () => clearTimeout(t); }, [typed]);
  const [onlySensitive, setOnlySensitive] = React.useState(false);
  const [picked, setPicked] = React.useState(() => { const s = startObject; startObject = ""; return s; });
  const list = useJson(ran ? "/api/access/log/objects" : null, { window: p.filters.window, search, sensitive: onlySensitive, limit: 200 });
  const objects: Row[] = list.data?.objects || [];
  const name = picked || String(objects[0]?.object_fqn || "");
  const log = useJson(ran && name ? "/api/access/log" : null, { object: name, window: p.filters.window });
  const off = useJson(ran ? "/api/access/log/offhours" : null, { window: p.filters.window });
  const offRows: Row[] = off.data?.rows || [];
  const d = log.data;
  const grain = String(d?.grain || list.data?.grain || "day");
  const who: Row[] = d?.who || [];
  const sum = (k: string) => who.reduce((s, r) => s + numOrZero(r[k]), 0);

  useLede(p, c.loading || list.loading, list.data ? `${plural(numOrZero(list.data.total), "object")} were read or changed in this window. Pick one to see who, with which role and client, and when.` : null);

  const buckets: Row[] = d?.buckets || [];
  const byBucket = new Map(buckets.map((b) => [String(b.bucket).slice(0, grain === "hour" ? 13 : 10), b]));
  const labels = d ? allBuckets(String(d.start), String(d.end), grain) : [];
  const series = (k: string) => labels.map((l) => numOrZero(byBucket.get(l)?.[k]));
  return (
    <div className="ais-page cx-e">
      {!ran && <CxStat>{c.loading ? "…" : `– ${c.why}`}</CxStat>}
      {ran && (
        <div className="ax-bar">
          <input className="ax-input wide" value={typed} placeholder="Filter tables, views and stages" aria-label="Object name filter"
            onChange={(e) => setTyped(e.target.value)} />
          <div className="cx-seg" role="group" aria-label="Which objects">
            <button type="button" className={!onlySensitive ? "on" : ""} aria-pressed={!onlySensitive} onClick={() => setOnlySensitive(false)}>All</button>
            <button type="button" className={onlySensitive ? "on" : ""} aria-pressed={onlySensitive} onClick={() => setOnlySensitive(true)}>Sensitive</button>
          </div>
          {(list.loading || log.loading) && <span className="cx-muted">…</span>}
          {list.err && <span className="cx-muted">{`– ${list.err}`}</span>}
        </div>
      )}
      {ran && <CutNote d={list.data} />}
      {ran && off.data && (
        <ChartCard title="Off-hours use by people" subtitle="Queries by people outside business hours or at weekends · service users and pipelines left out · sensitive and changes first · select a row" takeaway={null}>
          {offRows.length ? (
            <CxTable ariaLabel="Off-hours use by people" n={8}
              foot={`${plural(numOrZero(off.data.users), "person")} on ${plural(numOrZero(off.data.objects), "object")}. Business hours are set in config/thresholds.yml (sf_use_access_log).`}
              cols={[{ label: "User" }, { label: "Object" }, { label: "Roles" }, { label: "Off hours", num: true }, { label: "Statements" }, { label: "Last", num: true }]}
              rows={offRows.map((r, i) => ({
                key: `${r.user_name}|${r.object_fqn}|${i}`, status: r.sensitive || numOrZero(r.ddl) + numOrZero(r.writes) > 0 ? "WARN" : "OK",
                onClick: () => setPicked(String(r.object_fqn)),
                cells: [String(r.user_name || "–"), <span><CxObjName full={String(r.object_fqn)} /> <Sensitivity v={r.sensitive} /></span>, String(r.roles || "–"),
                  fmtInt(numOrZero(r.off_hours)), <span className="cx-code">{[r.statement_types, r.ddl_operations].filter(Boolean).join(" · ") || "–"}</span>, at(r.last_at, grain)],
              }))} />
          ) : <CxStat>{`No person used an object outside business hours in ${day(off.data.start)}–${day(off.data.end)}.`}</CxStat>}
        </ChartCard>
      )}
      {ran && list.data && !objects.length && <CxStat>{`No ${onlySensitive ? "sensitive " : ""}object was read or changed in this window${search ? ` matching "${search}"` : ""}.`}</CxStat>}
      {ran && objects.length > 0 && (
        <ChartCard title="Objects, busiest first" subtitle={`Queries in the window · select a row · ${fmtInt(Math.min(objects.length, numOrZero(list.data.total)))} of ${plural(numOrZero(list.data.total), "object")}`} takeaway={null}>
          <CxTable ariaLabel="Objects read or changed" n={8}
            cols={[{ label: "Object" }, { label: "Kind" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Users", num: true }, { label: "Last", num: true }]}
            rows={objects.map((o) => ({
              key: String(o.object_fqn), on: o.object_fqn === name, onClick: () => setPicked(String(o.object_fqn)),
              cells: [<span><CxObjName full={String(o.object_fqn)} /> <Sensitivity v={o.sensitive} /></span>, String(o.object_domain || "").toLowerCase(),
                fmtInt(numOrZero(o.reads)), fmtInt(numOrZero(o.writes)), fmtInt(numOrZero(o.ddl)), fmtInt(numOrZero(o.users)), at(o.last_at, grain)],
            }))} />
        </ChartCard>
      )}
      {d && (
        <SummaryTileRow compact>
          <IssueTile label="Reads" headline={fmtInt(sum("reads"))} unit=" queries" status="neutral" base={`${plural(new Set(who.map((r) => r.user_name)).size, "user")} · ${plural(new Set(who.map((r) => r.role_name)).size, "role")}`} />
          <IssueTile label="Writes" headline={fmtInt(sum("writes"))} unit=" queries" status="neutral" base="INSERT, UPDATE, DELETE, MERGE, COPY" />
          <IssueTile label="DDL" headline={fmtInt(sum("ddl"))} unit=" queries" status="neutral" base="CREATE, ALTER, DROP and the like" />
          <IssueTile label="Clients" headline={fmtInt(new Set(who.map((r) => r.client)).size)} unit="" status="neutral" base={[...new Set(who.map((r) => String(r.client)))].slice(0, 3).join(", ") || "–"} />
        </SummaryTileRow>
      )}
      {d && buckets.length > 0 && (
        <ChartCard title={`${name}, per ${grain}`} subtitle={`Queries a ${grain} · every ${grain} of the window`} takeaway={null}>
          <Columns days={labels} unitLabel={`queries / ${grain}`} ariaLabel={`Queries on ${name} per ${grain}`}
            series={[{ name: "Reads", id: "reads", values: series("reads") },
              { name: "Writes", id: "writes", values: series("writes") },
              { name: "DDL", id: "ddl", values: series("ddl") }]} />
        </ChartCard>
      )}
      {d && (
        <ChartCard title={`Who used ${name}`} subtitle={`One row per user, role and client · counts are queries · active = ${grain}s with use`} takeaway={null}>
          {who.length ? (
            <CxTable ariaLabel={`Who used ${name}`} n={15}
              cols={[{ label: "User" }, { label: "Role" }, { label: "Client" }, { label: "Statements" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Off hours", num: true }, { label: `Active ${grain}s`, num: true }, { label: "First", num: true }, { label: "Last", num: true }]}
              rows={who.map((r, i) => ({
                key: `${r.user_name}|${r.role_name}|${r.client}|${i}`, status: r.is_person && numOrZero(r.off_hours) > 0 ? "WARN" : undefined,
                cells: [String(r.user_name || "–"), String(r.role_name || "–"), String(r.client || "–"),
                  <span className="cx-code">{[r.statement_types, r.ddl_operations].filter(Boolean).join(" · ") || "–"}</span>,
                  fmtInt(numOrZero(r.reads)), fmtInt(numOrZero(r.writes)), fmtInt(numOrZero(r.ddl)), r.is_person ? fmtInt(numOrZero(r.off_hours)) : "not a person", fmtInt(numOrZero(r.buckets)), at(r.first_at, grain), at(r.last_at, grain)],
              }))} />
          ) : <CxStat>{`No data for this in ${day(d.start)}–${day(d.end)}`}</CxStat>}
        </ChartCard>
      )}
      {d && (
        <ChartCard title="Every query, one by one" subtitle="Run in Snowflake for the query ids and times behind these counts (no query text)" takeaway={null}>
          <pre className="cx-code">{detailSql(name, String(d.start), String(d.end))}</pre>
        </ChartCard>
      )}
    </div>
  );
}
(ApActivityAccessLog as any).ownsTiles = true;
(ApActivityAccessLog as any).ownsLede = true;

// ═══════════════════════ PII › Tags ═══════════════════════

export function ApPiiTags(p: ApPageProps) {
  const c = useAggCheck(p, "sf_gov_tag_objects", [], "column_count", []);
  const ran = !c.loading && !c.why;
  const tags = useJson(ran ? "/api/access/tags" : null, {});
  const list: Row[] = tags.data?.tags || [];
  const [sel, setSel] = React.useState<{ tag: string; value: string | null } | null>(null);
  const cur = sel || (list[0] ? { tag: String(list[0].tag_fqn), value: String(list[0].tag_value) } : null);
  const res = useJson(cur ? "/api/access/tag" : null, cur ? { tag: cur.tag, ...(cur.value != null ? { value: cur.value } : {}), window: p.filters.window } : {});
  const objs: Row[] = res.data?.objects || [];

  useLede(p, c.loading || tags.loading, list.length ? `${plural(new Set(list.map((t) => t.tag_fqn)).size, "tag")} with ${plural(list.length, "value")} on databases, schemas, tables and columns. Pick one to see who can read its objects and who did.` : null);

  return (
    <div className="ais-page cx-e">
      {!ran && <CxStat>{c.loading ? "…" : c.empty ? c.why : `– ${c.why}`}</CxStat>}
      {ran && list.length > 0 && (
        <ChartCard title="Tags and values" subtitle="Objects carrying each value · select a row" takeaway={null}>
          <CxTable ariaLabel="Tag values" n={10}
            cols={[{ label: "Tag" }, { label: "Value" }, { label: "Objects", num: true }, { label: "Columns", num: true }, { label: "Set on" }]}
            rows={list.map((t) => ({
              key: `${t.tag_fqn}=${t.tag_value}`, on: !!cur && cur.tag === t.tag_fqn && cur.value === t.tag_value,
              onClick: () => setSel({ tag: String(t.tag_fqn), value: String(t.tag_value) }),
              cells: [<span className="cx-code">{String(t.tag_fqn)}</span>, String(t.tag_value || "(no value)"), fmtInt(numOrZero(t.objects)),
                fmtInt(numOrZero(t.columns)), String(t.levels || "").toLowerCase()],
            }))} />
        </ChartCard>
      )}
      {cur && res.data && (
        <ChartCard title={`Where ${cur.tag.split(".").pop()} = ${cur.value || "(no value)"} is set`}
          subtitle="Can read = users with a SELECT or ownership path through roles · queried = users in the window · a database or schema row covers every table in it · select a table for its access log" takeaway={null}>
          {objs.length ? (
            <CxTable ariaLabel="Objects carrying the tag" n={15}
              cols={[{ label: "Object" }, { label: "Set on" }, { label: "Columns" }, { label: "Can read", num: true }, { label: "Queried by", num: true }, { label: "Top users" }]}
              rows={objs.map((o, i) => ({
                key: `${o.object}|${o.level}|${i}`,
                onClick: o.level === "TABLE" || o.level === "COLUMN" ? () => openInAccessLog(p, String(o.object)) : undefined,
                cells: [<CxObjName full={String(o.object)} />, String(o.level || "").toLowerCase(), <span className="cx-code">{String(o.columns || "–")}</span>,
                  o.can_read ? fmtInt(o.can_read.length) : "–",
                  o.queried_by ? fmtInt(new Set(o.queried_by.map((u: Row) => u.user_name)).size) : "–",
                  o.queried_by ? o.queried_by.slice(0, 3).map((u: Row) => `${u.user_name} (${u.role_name})`).join(", ") || "none" : "–"],
              }))} />
          ) : <CxStat>No object carries this value.</CxStat>}
          <div className="cx-muted">"–" under Can read: no grant path in this export (a database or schema row, or no grant links). "–" under Queried by: no access log in this export.</div>
        </ChartCard>
      )}
    </div>
  );
}
(ApPiiTags as any).ownsTiles = true;
(ApPiiTags as any).ownsLede = true;

// ═══════════════════════ PII › Sensitive data: suggested tags ═══════════════════════

export function PiiSuggestions({ p }: { p: ApPageProps }) {
  const c = useCheck(p, "sf_gov_sensitive_suggestions");
  // the page loads one 5,000-row page; the counts come from every row
  const id = c.f ? "sf_gov_sensitive_suggestions" : null;
  const st = useFindingAgg(id, p.filters.window, p.filters.accountIds, ["status"], "count");
  const tb = useFindingAgg(id, p.filters.window, p.filters.accountIds, ["database_name", "schema_name", "table_name"], "count");
  const all = numOrZero(st.data?.rows_total);
  const warn = numOrZero((st.data?.groups || []).find((g: Row) => g.key?.[0] === "WARN")?.value);
  return (
    <Slot c={c} title="Columns that look sensitive but carry no tag" subtitle="From column names only · confirm with Snowflake classification, which reads the data · select a row">
      {(rows) => {
        const byTable = new Map<string, Row[]>();
        rows.forEach((r) => { const k = `${r.database_name}.${r.schema_name}.${r.table_name}`; byTable.set(k, [...(byTable.get(k) || []), r]); });
        const groups = [...byTable.entries()].map(([k, rs]) => ({ k, rs, flagged: rs.filter(isFlagged).length }))
          .sort((a, b) => b.flagged - a.flagged || b.rs.length - a.rs.length);
        return (
          <div>
            <CxStat>{st.data ? <span><b>{`${fmtInt(warn)} of ${plural(all, "column")}`}</b>{` look like identifiers or secrets, in ${plural(numOrZero(tb.data?.group_count), "table")}.`}</span> : "…"}</CxStat>
            <CxTable ariaLabel="Columns that look sensitive" n={10}
              foot={rows.length < all ? `Tables of the first ${fmtInt(rows.length)} of ${plural(all, "column")}; the full list is in the check's rows.` : undefined}
              cols={[{ label: "Table" }, { label: "Columns and suggested category" }, { label: "Classify it" }]}
              rows={groups.map((g) => ({
                key: g.k, status: g.flagged ? "WARN" : "OK",
                cells: [<CxObjName full={g.k} />,
                  <span className="cx-code">{g.rs.slice(0, 6).map((r) => `${r.column_name} → ${r.suggested_category} (${r.confidence})`).join(", ")}{g.rs.length > 6 ? ` +${g.rs.length - 6}` : ""}</span>,
                  <span className="cx-code">{`CALL SYSTEM$CLASSIFY('${g.k}', {'auto_tag': true});`}</span>],
              }))} />
          </div>
        );
      }}
    </Slot>
  );
}

// ═══════════════════════ PII › Who reads it: downloads ═══════════════════════

export function PiiDownloads({ p }: { p: ApPageProps }) {
  const c = useCheck(p, "sf_gov_file_downloads");
  const n = useFindingAgg(c.f ? "sf_gov_file_downloads" : null, p.filters.window, p.filters.accountIds, [], "count");
  const all = numOrZero(n.data?.rows_total);
  return (
    <Slot c={c} title="Files taken out: GET and unloads" subtitle="Per user, role and stage in the window · result downloads from Snowsight or drivers are not logged by Snowflake">
      {(rows) => {
        const m = new Map<string, Row & { n: number; tables: Set<string>; sens: Set<string>; flagged: boolean; days: Set<string> }>();
        rows.forEach((r) => {
          const k = `${r.user_name}|${r.role_name}|${r.kind}|${r.stage_name}`;
          const g = m.get(k) || { ...r, n: 0, tables: new Set<string>(), sens: new Set<string>(), flagged: false, days: new Set<string>() };
          g.n += numOrZero(r.queries);
          String(r.source_tables || "").split(", ").filter(Boolean).forEach((t) => g.tables.add(t));
          String(r.sensitive_tables || "").split(", ").filter(Boolean).forEach((t) => g.sens.add(t));
          g.flagged = g.flagged || isFlagged(r);
          g.days.add(String(r.usage_date).slice(0, 10));
          if (String(r.last_at) > String(g.last_at)) g.last_at = r.last_at;
          m.set(k, g);
        });
        const groups = [...m.values()].sort((a, b) => Number(b.flagged) - Number(a.flagged) || b.n - a.n);
        return (
          <CxTable ariaLabel="Files taken out" n={10}
            foot={rows.length < all ? `From the first ${fmtInt(rows.length)} of ${fmtInt(all)} rows; the full list is in the check's rows.` : undefined}
            cols={[{ label: "User" }, { label: "Role" }, { label: "Kind" }, { label: "Stage" }, { label: "Queries", num: true }, { label: "Days", num: true }, { label: "Sensitive tables" }, { label: "Last", num: true }]}
            rows={groups.map((g, i) => ({
              key: `${g.user_name}|${g.role_name}|${g.kind}|${g.stage_name}|${i}`, status: g.flagged ? "WARN" : "OK",
              cells: [String(g.user_name || "–"), String(g.role_name || "–"), g.kind === "GET" ? "GET (download)" : "unload", <span className="cx-code">{String(g.stage_name || "–")}</span>,
                fmtInt(g.n), fmtInt(g.days.size), g.sens.size ? [...g.sens].slice(0, 3).join(", ") : g.tables.size ? "none" : "–", day(g.last_at)],
            }))} />
        );
      }}
    </Slot>
  );
}
