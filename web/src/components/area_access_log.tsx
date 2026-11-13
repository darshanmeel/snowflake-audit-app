// web/src/components/area_access_log.tsx -- PII › Tags (a tag's objects, who can read them, who did), and the
// suggested-tags and downloads blocks of PII. Activity › Access log is in access_log_page.tsx.
import React from "react";
import { useJson } from "./use_json";
import { openInAccessLog } from "./access_log_page";
import { fmtDayShort, fmtInt } from "../format";
import { numOrZero, useFindingAgg } from "./hooks";
import type { ApPageProps } from "./area_pages";
import { ChartCard } from "./primitives";
import { Slot, isFlagged, useAggCheck, useCheck, useLede } from "./area_ai_storage";
import { CxObjName, CxStat, CxTable } from "./cx_e";
import type { Row } from "../types";

const plural = (n: number, one: string) => `${fmtInt(n)} ${n === 1 ? one : `${one}s`}`;
const day = (v: any) => (v ? fmtDayShort(String(v).slice(0, 10)) : "–");






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
