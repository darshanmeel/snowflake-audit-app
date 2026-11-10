// web/src/components/area_activity.tsx -- the Activity area: what is used across the account, by
// database, schema, table, user and role, and the other objects (stages, views, functions, pipes,
// tasks). Reads, writes and DDL come from ACCESS_HISTORY (Enterprise); nothing here is priced except
// the storage of never-used schemas, which sf_use_database_activity carries.
// Registered into AREA_CHART_PAGES by area_pages.tsx.
import React from "react";
import { fmtDayShort, fmtDuration, fmtInt, fmtMoney } from "../format";
import { numOrZero } from "./hooks";
import { CsvButton } from "./csv";
import { DrawerBus } from "./drawer";
import type { ApPageProps } from "./area_pages";
import { StackedShareBar, fmtShare, pctOf } from "./blocks";
import type { ShareSegment } from "./blocks";
import { CheckTile, Row2, Slot, fmtSize, isFlagged, useCheck, useLede } from "./area_ai_storage";
import { SummaryTile, SummaryTileRow, windowSpan } from "./overview_tile";
import { CxBarRows, CxChip, CxMiniCols, CxObjName, CxRanked, CxStat, CxStrip, CxTable, CxTwoBar } from "./cx_e";
import type { CxBarRow, CxRankItem } from "./cx_e";
import type { Row } from "../types";

// ═══════════════════════ shared helpers ═══════════════════════

const plural = (n: number, one: string, many?: string) => `${fmtInt(n)} ${n === 1 ? one : (many || `${one}s`)}`;
const isTrue = (v: any) => v === true || v === "true" || v === 1;
const day = (v: any) => (v ? String(v).slice(0, 10) : null);
const lastDay = (v: any) => (v ? fmtDayShort(day(v)) : "–");
const okNote = (text: string) => <div className="chart-note-oneline">{text}</div>;
const drawerBy = (id: string, col: string, val: any, label: string) => () => DrawerBus.open({ id, col, val: String(val), label });
/** Reads + writes + DDL: distinct queries per kind, so a query that both reads and writes counts twice. */
const touches = (r: Row) => numOrZero(r.read_queries) + numOrZero(r.write_queries) + numOrZero(r.ddl_queries);
const rwd = (r: Row) => `${fmtInt(numOrZero(r.read_queries))} reads · ${fmtInt(numOrZero(r.write_queries))} writes · ${fmtInt(numOrZero(r.ddl_queries))} DDL`;
const byTouches = (a: Row, b: Row) => touches(b) - touches(a);
const levelRows = (rows: Row[] | null, level: string) => (rows || []).filter((r) => r.row_level === level);
// One schema's rows: by id, since a schema name such as PUBLIC repeats across databases.
const schemaDrawer = (r: Row) => (r.schema_id != null ? drawerBy("sf_use_database_activity", "schema_id", r.schema_id, `${r.database_name}.${r.schema_name}`)
  : drawerBy("sf_use_database_activity", "schema_name", r.schema_name, `${r.database_name}.${r.schema_name}`));

/** A database picker over the rows' databases; "" = all. */
function DbPick({ dbs, db, setDb, note }: { dbs: string[]; db: string; setDb: (d: string) => void; note?: string | null }) {
  if (dbs.length < 2) return null;
  return (
    <div className="act-db-pick">
      <label className="cx-muted">{"Database "}
        <select value={db} onChange={(e) => setDb(e.target.value)} aria-label="Database">
          <option value="">{`All ${plural(dbs.length, "database")}`}</option>
          {dbs.map((d) => <option key={d} value={d}>{d}</option>)}
        </select>
      </label>
      {note && <span className="cx-muted">{` ${note}`}</span>}
    </div>
  );
}

/** A day as "Sep 19", with the year when it falls before the window. */
function dayYear(v: any, p: ApPageProps): string {
  const d = day(v);
  if (!d) return "–";
  const span = windowSpan(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
  const t = Date.parse(`${d}T00:00:00Z`);
  return span && Number.isFinite(t) && t < span.first ? `${fmtDayShort(d)}, ${d.slice(0, 4)}` : fmtDayShort(d);
}

/** Label-above-bar rows: the top `n` only, with how many there are in all. */
function RankedAbove({ items, noun, ariaLabel, n = 10 }: { items: CxRankItem[]; noun: string; ariaLabel: string; n?: number }) {
  if (!items.length) return null;
  return (
    <div>
      <CxRanked items={items.slice(0, n)} layout="above" max={Math.max(1, ...items.map((x) => x.value))} ariaLabel={ariaLabel} />
      {items.length > n && <div className="cx-foot"><span>{`Top ${fmtInt(n)} of ${fmtInt(items.length)} ${noun}.`}</span></div>}
    </div>
  );
}

const TOUCH_FOOT = "Bar = reads + writes + DDL, in distinct queries; a query that reads and writes counts in both.";

// ═══════════════════════ Activity › Databases ═══════════════════════

export function ApActivityDatabases(p: ApPageProps) {
  const da = useCheck(p, "sf_use_database_activity");
  const dbs = levelRows(da.allRows, "database");
  const active = dbs.filter((r) => touches(r) > 0);
  const all = dbs.reduce((s, r) => s + touches(r), 0);
  const top = [...dbs].sort(byTouches)[0];
  useLede(p, da.loading, dbs.length ? [
    `${fmtInt(active.length)} of ${plural(dbs.length, "database")} had a read, write or DDL in the window.`,
    top && all > 0 ? `${top.database_name} carries ${fmtShare(pctOf(touches(top), all))} of it.` : null,
  ].filter(Boolean).join(" ") : null);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <CheckTile c={da} label="Databases in use" build={() => ({
          headline: fmtInt(active.length), unit: ` of ${plural(dbs.length, "database")}`,
          base: `${fmtInt(dbs.length - active.length)} with no read, write or DDL.`, openLabel: "By database ↓",
        })} />
        <CheckTile c={da} label="Busiest database" build={() => ({
          headline: top ? fmtShare(pctOf(touches(top), all)) : null, unit: " of reads, writes and DDL", missingReason: top ? undefined : "no database rows",
          base: top ? String(top.database_name) : null,
          cause: top ? `${plural(numOrZero(top.active_users), "active user")} · ${rwd(top)}` : undefined,
        })} />
        <CheckTile c={da} label="Most users" build={() => {
          const u = [...dbs].sort((a, b) => numOrZero(b.active_users) - numOrZero(a.active_users))[0];
          return {
            headline: u ? fmtInt(numOrZero(u.active_users)) : null, unit: " users", missingReason: u ? undefined : "no database rows",
            base: u ? `on ${u.database_name}, the most of any database` : null,
            cause: "Distinct users who read, wrote or changed it.",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={da} title="Databases by activity" subtitle="Reads, writes and DDL in the window · select one for its schemas">
          {() => {
            const items: CxRankItem[] = [...dbs].sort(byTouches).filter((r) => touches(r) > 0).map((r) => ({
              key: String(r.database_name), label: String(r.database_name), value: touches(r),
              strong: fmtShare(pctOf(touches(r), all)), rest: `${rwd(r)} · ${plural(numOrZero(r.active_users), "user")}`,
              onClick: drawerBy("sf_use_database_activity", "database_name", r.database_name, String(r.database_name)),
            }));
            return items.length ? <div><RankedAbove items={items} noun="databases" ariaLabel="Databases by activity" /><div className="cx-foot">{TOUCH_FOOT}</div></div>
              : okNote("No database had a read, write or DDL in the window.");
          }}
        </Slot>
        <Slot c={da} title="Storage against use" subtitle="Storage per database, with its queries · amber dot = every schema never used">
          {() => {
            const items: CxBarRow[] = dbs.map((r) => ({
              key: String(r.database_name), name: String(r.database_name), id: r.database_id, value: numOrZero(r.storage_gb),
              status: isTrue(r.never_used) ? "WARN" : "OK", strong: fmtSize(numOrZero(r.storage_gb)),
              rest: isTrue(r.never_used) ? "never used" : `${fmtInt(touches(r))} queries`,
              onClick: drawerBy("sf_use_database_activity", "database_name", r.database_name, String(r.database_name)),
            })).filter((it) => it.value > 0).sort((x, y) => y.value - x.value);
            return items.length ? <CxBarRows rows={items} ariaLabel="Database storage and queries" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={da} title="Databases in detail" subtitle="The top 20 by reads, writes and DDL · select a row for its schemas">
        {() => dbs.length ? (
          <CxTable ariaLabel="Databases" foot={dbs.length > 20 ? `Top 20 of ${plural(dbs.length, "database")}.` : undefined}
            cols={[{ label: "Database" }, { label: "Owner" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true },
              { label: "Users", num: true }, { label: "Last activity", num: true }, { label: "Storage", num: true }]}
            rows={[...dbs].sort(byTouches).slice(0, 20).map((r) => ({
              key: String(r.database_name), onClick: drawerBy("sf_use_database_activity", "database_name", r.database_name, String(r.database_name)),
              cells: [<span>{String(r.database_name)}{r.database_type && r.database_type !== "STANDARD" ? <div className="cx-muted">{String(r.database_type).toLowerCase()}</div> : null}</span>,
                String(r.database_owner || "–"), fmtInt(numOrZero(r.read_queries)), fmtInt(numOrZero(r.write_queries)), fmtInt(numOrZero(r.ddl_queries)),
                fmtInt(numOrZero(r.active_users)), lastDay(r.last_activity_at), fmtSize(numOrZero(r.storage_gb))],
            }))} />
        ) : null}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Activity › Schemas ═══════════════════════

export function ApActivitySchemas(p: ApPageProps) {
  const da = useCheck(p, "sf_use_database_activity");
  const allSchemas = levelRows(da.rows, "schema");
  const dbs = React.useMemo(() => [...new Set(allSchemas.map((r) => String(r.database_name || "")))].filter(Boolean).sort(), [da.rows]); // eslint-disable-line react-hooks/exhaustive-deps
  const [db, setDb] = React.useState("");
  const schemas = db ? allSchemas.filter((r) => r.database_name === db) : allSchemas;
  const never = schemas.filter((r) => isTrue(r.never_used));
  const usd = (r: Row) => numOrZero(r.est_storage_usd_month) * (1 - da.disc);
  const live = schemas.reduce((s, r) => s + numOrZero(r.live_tables), 0);
  const read = schemas.reduce((s, r) => s + numOrZero(r.tables_read), 0);
  useLede(p, da.loading, schemas.length ? `${db ? `In ${db}, ` : ""}${fmtInt(never.length)} of ${plural(schemas.length, "schema")} were never used; ${fmtInt(read)} of ${plural(live, "live table")} were read.` : null);
  return (
    <div className="ais-page cx-e">
      <DbPick dbs={dbs} db={db} setDb={setDb} />
      <SummaryTileRow compact>
        <CheckTile c={da} label="Schemas nobody uses" badge build={(rows) => {
          const priced = rows.some((r) => r.price_basis === "priced");
          return {
            headline: fmtInt(never.length), unit: ` of ${plural(schemas.length, "schema")}`,
            base: "No read, write or DML in the window.",
            cause: priced ? `${fmtMoney(never.reduce((s, r) => s + usd(r), 0), 0)} a month of storage sits in them.` : undefined, openLabel: "By schema ↓",
          };
        }} />
        <CheckTile c={da} label="Tables read" build={() => ({
          headline: fmtShare(pctOf(read, live)), unit: " of live tables",
          base: `${fmtInt(read)} of ${plural(live, "live table")} read in the window.`,
        })} />
        <CheckTile c={da} label="Where the reads go" build={() => {
          const reads = schemas.map((r) => numOrZero(r.read_queries)).sort((a, b) => b - a);
          const all = reads.reduce((s, v) => s + v, 0);
          const top = reads.slice(0, 3).reduce((s, v) => s + v, 0);
          return {
            headline: fmtShare(pctOf(top, all)), unit: " of read queries",
            base: `${fmtInt(top)} of ${fmtInt(all)} read queries hit 3 of ${plural(schemas.length, "schema")}.`, openLabel: "By schema ↓",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={da} title="Busiest schemas" subtitle="Reads, writes and DDL in the window">
          {() => {
            const all = schemas.reduce((s, r) => s + touches(r), 0);
            const items: CxRankItem[] = [...schemas].sort(byTouches).filter((r) => touches(r) > 0).map((r) => ({
              key: `${r.database_name}.${r.schema_name}`, label: <CxObjName full={`${r.database_name}.${r.schema_name}`} />, value: touches(r),
              strong: fmtShare(pctOf(touches(r), all)), rest: `${rwd(r)} · ${plural(numOrZero(r.active_users), "user")}`,
              onClick: schemaDrawer(r),
            }));
            return items.length ? <div><RankedAbove items={items} noun="schemas" ariaLabel="Schemas by activity" /><div className="cx-foot">{TOUCH_FOOT}</div></div>
              : okNote("No schema had a read, write or DDL in the window.");
          }}
        </Slot>
        <Slot c={da} title="Schemas: storage against reads" subtitle="Storage per month, with the queries that used each schema · amber dot = never used">
          {() => {
            const priced = schemas.some((r) => r.price_basis !== "unpriced" && r.est_storage_usd_month != null);
            const valOf = (r: Row) => (priced ? usd(r) : numOrZero(r.storage_gb));
            const fmtV = (v: number) => (priced ? `${fmtMoney(v, 0)}/mo` : fmtSize(v));
            const items: CxBarRow[] = schemas.map((r) => ({
              key: `${r.database_name}.${r.schema_name}`, name: `${r.database_name}.${r.schema_name}`, id: r.schema_id, value: valOf(r),
              status: isTrue(r.never_used) ? "WARN" : "OK", strong: fmtV(valOf(r)),
              rest: isTrue(r.never_used) ? "never used" : `${fmtInt(numOrZero(r.read_queries) + numOrZero(r.write_queries))} queries`,
              onClick: schemaDrawer(r),
            })).filter((it) => it.value > 0).sort((x, y) => y.value - x.value);
            return items.length ? <CxBarRows rows={items} ariaLabel="Schema storage and queries" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={da} title="Schemas in detail" subtitle="The top 20 by reads, writes and DDL · select a row for the check's rows">
        {() => schemas.length ? (
          <CxTable ariaLabel="Schemas" foot={schemas.length > 20 ? `Top 20 of ${plural(schemas.length, "schema")}.` : undefined}
            cols={[{ label: "Schema" }, { label: "Tables read", num: true }, { label: "Tables written", num: true }, { label: "Reads", num: true },
              { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Users", num: true }, { label: "Last activity", num: true }]}
            rows={[...schemas].sort(byTouches).slice(0, 20).map((r) => ({
              key: `${r.database_name}.${r.schema_name}`, status: r.status,
              onClick: schemaDrawer(r),
              cells: [<CxObjName full={`${r.database_name}.${r.schema_name}`} id={r.schema_id} />,
                `${fmtInt(numOrZero(r.tables_read))} of ${fmtInt(numOrZero(r.live_tables))}`, fmtInt(numOrZero(r.tables_written)),
                fmtInt(numOrZero(r.read_queries)), fmtInt(numOrZero(r.write_queries)), fmtInt(numOrZero(r.ddl_queries)),
                fmtInt(numOrZero(r.active_users)), lastDay(r.last_activity_at)],
            }))} />
        ) : null}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Activity › Tables ═══════════════════════

const CLASSES: [string, string, string][] = [
  ["active", "Active", "var(--c1)"], ["cooling", "Cooling", "var(--c2)"], ["written_never_read", "Written, never read", "var(--c4)"],
  ["new", "New", "var(--c3)"], ["idle", "Idle", "var(--c-other)"],
];
const CLASS_WORD: Record<string, string> = Object.fromEntries(CLASSES.map(([k, w]) => [k, w]));
// Busiest tables ranked by one kind of use: [key, button, value, unit one, unit many].
const RANK_BY: [string, string, (r: Row) => number, string, string][] = [
  ["all", "All", touches, "query", "queries"], ["read", "Reads", (r) => numOrZero(r.read_queries), "read", "reads"],
  ["write", "Writes", (r) => numOrZero(r.write_queries), "write", "writes"], ["dml", "Rows changed", (r) => numOrZero(r.dml_rows), "row changed", "rows changed"],
  ["ddl", "DDL", (r) => numOrZero(r.ddl_queries), "DDL", "DDL"],
];
// Heaviest tables by one measure: [key, button, value, its rank column, value as text].
const HEAVY_BY: [string, string, (r: Row) => number, string, (r: Row) => string][] = [
  ["time", "Query time", (r) => numOrZero(r.exec_s), "exec_rank", (r) => fmtDuration(r.exec_s)],
  ["scan", "Partitions read", (r) => numOrZero(r.partitions_scanned), "scan_rank", (r) => plural(numOrZero(r.partitions_scanned), "partition")],
  ["full", "Full scans", (r) => numOrZero(r.full_scan_queries), "full_scan_rank", (r) => plural(numOrZero(r.full_scan_queries), "full scan")],
  ["spill", "Spill", (r) => numOrZero(r.spilled_gb), "spill_rank", (r) => `${fmtSize(numOrZero(r.spilled_gb))} spilled`],
];
const HEAVY_FOOT: Record<string, string> = {
  time: "Execution time of the queries that read the table (TABLE_QUERY_PRUNING_HISTORY). A join counts in full on each table it reads.",
  scan: "Micro-partitions read from the table itself, after pruning.",
  full: "Runs of statement shapes that read most of a large table's partitions: pruning did little. Their cost is under Queries.",
  spill: "Spill of the queries that read the table, by statement shape (QUERY_HISTORY). A join counts in full on each table it reads.",
};

export function ApActivityTables(p: ApPageProps) {
  const ta = useCheck(p, "sf_use_table_activity");
  const td = useCheck(p, "sf_use_table_daily");
  const tr = useCheck(p, "sf_use_table_readers");
  const tc = useCheck(p, "sf_use_table_columns");
  const qp = useCheck(p, "sf_use_query_profile");
  const qs = useCheck(p, "sf_use_top_query_shapes");
  // 70 tables over 90 days pass one page, and the rows past it would drop from the $ and the picker.
  const tp = useCheck(p, "sf_use_table_perf_daily", true);
  const th = useCheck(p, "sf_use_table_heaviest");
  const [heavyBy, setHeavyBy] = React.useState("time");
  const allTables = levelRows(ta.rows, "table");
  const dbOf = (fqn: any) => String(fqn || "").split(".")[0];
  const dbs = React.useMemo(() => [...new Set(allTables.map((r) => String(r.database_name || dbOf(r.table_fqn))))].filter(Boolean).sort(), [ta.rows]); // eslint-disable-line react-hooks/exhaustive-deps
  const [db, setDb] = React.useState("");
  const inDb = (fqn: any) => !db || dbOf(fqn) === db;
  const tables = allTables.filter((r) => inDb(r.table_fqn));
  // One database: its classes are counted from its table rows; the account keeps the uncapped class rows.
  const classes = db ? CLASSES.map(([k]) => {
    const rs = tables.filter((r) => r.usage_class === k);
    return { usage_class: k, tables: rs.length, storage_gb: rs.reduce((s, r) => s + numOrZero(r.storage_gb), 0) } as Row;
  }) : levelRows(ta.allRows, "class");
  const cls = (k: string) => classes.find((r) => r.usage_class === k);
  // Table rows are capped (most active and largest), so a database's counts can miss quiet small tables.
  const capped = !!db && allTables.length < levelRows(ta.allRows, "class").reduce((s, r) => s + numOrZero(r.tables), 0);
  const nTables = classes.reduce((s, r) => s + numOrZero(r.tables), 0);
  const gb = classes.reduce((s, r) => s + numOrZero(r.storage_gb), 0);
  // The tables the daily check kept, busiest first: the picker for the day-by-day view. Tables kept only
  // for their clustering credits follow, so a costly table that is rarely read can still be picked.
  const dailyTables = React.useMemo(() => {
    const m = new Map<string, number>();
    (td.rows || []).forEach((r) => { if (inDb(r.table_fqn) && !m.has(String(r.table_fqn))) m.set(String(r.table_fqn), numOrZero(r.table_rank)); });
    const busy = [...m.entries()].sort((a, b) => a[1] - b[1]).map(([k]) => k);
    const more = new Map<string, number>();
    (tp.rows || []).forEach((r) => { const k = String(r.table_fqn); if (r.rank_basis === "clustering" && inDb(k) && !m.has(k) && !more.has(k)) more.set(k, numOrZero(r.table_rank)); });
    return [...busy, ...[...more.entries()].sort((a, b) => a[1] - b[1]).map(([k]) => k)];
  }, [td.rows, tp.rows, db]); // eslint-disable-line react-hooks/exhaustive-deps
  const [sel, setSel] = React.useState<string | null>(null);
  const [rankBy, setRankBy] = React.useState("all");
  const cur = sel && dailyTables.includes(sel) ? sel : dailyTables[0] || null;
  const pick = (fqn: string) => (dailyTables.includes(fqn) ? () => { setSel(fqn); document.getElementById("act-table-day")?.scrollIntoView({ behavior: "smooth", block: "start" }); }
    : drawerBy("sf_use_table_activity", "table_fqn", fqn, fqn));
  const nRead = numOrZero(cls("active")?.tables) + numOrZero(cls("cooling")?.tables);
  useLede(p, ta.loading, classes.length ? `${db ? `In ${db}, ` : ""}${fmtInt(nRead)} of ${plural(nTables, "table")} were read in the window; ${fmtInt(numOrZero(cls("written_never_read")?.tables))} were written but never read.` : null);
  const classTile = (k: string, label: string, cause: string) => (
    <CheckTile c={ta} label={label} build={() => {
      const r = cls(k);
      return {
        headline: fmtInt(numOrZero(r?.tables)), unit: ` of ${plural(nTables, "table")}`,
        base: `${fmtSize(numOrZero(r?.storage_gb))} · ${fmtShare(pctOf(numOrZero(r?.storage_gb), gb))} of storage`, cause,
      };
    }} />
  );
  return (
    <div className="ais-page cx-e">
      <DbPick dbs={dbs} db={db} setDb={setDb} note={capped ? "Counts for one database come from the tables the export listed (the most active and the largest)." : null} />
      <SummaryTileRow compact>
        {classTile("active", "Active tables", "Read in the newer half of the window.")}
        {classTile("cooling", "Cooling", "Read only in the older half of the window.")}
        {classTile("written_never_read", "Written, never read", "Loaded or changed, but no query read them.")}
        {classTile("idle", "Idle", "No read, write or DDL in the window.")}
      </SummaryTileRow>
      <>
        <Slot c={ta} title="Tables by use" subtitle="Every live table, by count and by storage">
          {() => {
            const seg = (val: (r: Row) => number): ShareSegment[] => CLASSES.map(([k, w, c]) => ({ key: k, label: w, value: val(cls(k) || {}), color: c }));
            return nTables ? (
              <div className="ais-stack-pair">
                <StackedShareBar segments={seg((r) => numOrZero(r.tables))} valueFmt={(v) => plural(v, "table")} ariaLabel="Tables by use class"
                  totalLabel={<span><b>{plural(nTables, "table")}</b>{" by count"}</span>} />
                <StackedShareBar segments={seg((r) => numOrZero(r.storage_gb))} valueFmt={(v) => fmtSize(v)} ariaLabel="Storage by use class"
                  totalLabel={<span><b>{fmtSize(gb)}</b>{" by storage"}</span>} />
              </div>
            ) : okNote("No live table.");
          }}
        </Slot>
        <Slot c={ta} title="Busiest tables" subtitle="Most reads, writes, rows changed or DDL in the window · select one for its days">
          {() => {
            const [, word, val, one, many] = RANK_BY.find((x) => x[0] === rankBy) || RANK_BY[0];
            const items: CxRankItem[] = tables.filter((r) => r.activity_rank != null && val(r) > 0).sort((a, b) => val(b) - val(a)).map((r) => ({
              key: String(r.table_fqn), label: <CxObjName full={String(r.table_fqn)} id={r.table_id} />, value: val(r),
              strong: plural(val(r), one, many), rest: rankBy === "all" ? `${plural(numOrZero(r.readers), "reader")} · ${plural(numOrZero(r.writers), "writer")}` : rwd(r),
              onClick: pick(String(r.table_fqn)),
            }));
            return (
              <div>
                <div className="cx-seg" role="group" aria-label="Rank by">
                  {RANK_BY.map(([k, w]) => <button key={k} type="button" className={rankBy === k ? "on" : ""} aria-pressed={rankBy === k} onClick={() => setRankBy(k)}>{w}</button>)}
                </div>
                {items.length ? <div className="cx-block"><RankedAbove key={rankBy} items={items} noun="tables" ariaLabel={`Busiest tables by ${word}`} />
                  <div className="cx-foot">{rankBy === "dml" ? "Rows inserted, updated and deleted (TABLE_DML_HISTORY)." : TOUCH_FOOT}
                    {rankBy === "dml" || rankBy === "ddl" ? " Ranked among the tables the export kept: the most active and the largest." : ""}</div></div>
                  : okNote(`No table had ${many} in the window.`)}
              </div>
            );
          }}
        </Slot>
        <Slot c={th} title="Heaviest tables" subtitle="Most query time, partitions read, full scans or spill in the window · select one for its days">
          {(rows) => {
            const [, word, val, rankCol, text] = HEAVY_BY.find((x) => x[0] === heavyBy) || HEAVY_BY[0];
            const items: CxRankItem[] = rows.filter((r) => inDb(r.table_fqn) && r[rankCol] != null && val(r) > 0)
              .sort((a, b) => numOrZero(a[rankCol]) - numOrZero(b[rankCol])).map((r) => ({
                key: String(r.table_fqn), label: <CxObjName full={String(r.table_fqn)} id={r.table_id} />, value: val(r),
                strong: text(r), rest: `${plural(numOrZero(r.queries), "query", "queries")} · ${fmtDuration(r.avg_exec_s)} each`,
                onClick: dailyTables.includes(String(r.table_fqn)) ? pick(String(r.table_fqn)) : drawerBy("sf_use_table_heaviest", "table_fqn", r.table_fqn, String(r.table_fqn)),
              }));
            return (
              <div>
                <div className="cx-seg" role="group" aria-label="Heaviest by">
                  {HEAVY_BY.map(([k, w]) => <button key={k} type="button" className={heavyBy === k ? "on" : ""} aria-pressed={heavyBy === k} onClick={() => setHeavyBy(k)}>{w}</button>)}
                </div>
                {items.length ? <div className="cx-block"><RankedAbove key={heavyBy} items={items} noun="tables" ariaLabel={`Heaviest tables by ${word}`} />
                  <div className="cx-foot">{HEAVY_FOOT[heavyBy]}</div></div>
                  : okNote(heavyBy === "full" ? "No query read most of a large table in the window." : heavyBy === "spill" ? "No query that read these tables spilled in the window." : "No query read a table in the window.")}
              </div>
            );
          }}
        </Slot>
      </>
      <div id="act-table-day">
        <Slot c={td} title="One table, day by day" subtitle="What happened to it each day and how it ran: reads, writes, DDL, rows changed, query time, waiting, partitions skipped and clustering credits">
          {(rows) => {
            if (!cur) return okNote("No table had activity in the window.");
            const mine = sumByDay(rows.filter((r) => String(r.table_fqn) === cur), ["read_queries", "write_queries", "ddl_queries", "dml_rows"]);
            const days = mine.map((r) => String(day(r.usage_date)));
            const dmlOnly = mine.some((r) => r.access_basis === "dml_only");
            const panels: [string, string, string][] = [["read_queries", "Reads", "var(--c1)"], ["write_queries", "Writes", "var(--c2)"], ["ddl_queries", "DDL", "var(--c4)"], ["dml_rows", "Rows changed", "var(--c3)"]];
            const users = (tr.rows || []).filter((r) => String(r.table_fqn) === cur).sort(byTouches);
            return (
              <div>
                <label className="cx-muted">{"Table "}
                  <select value={cur} onChange={(e) => setSel(e.target.value)} aria-label="Table">
                    {dailyTables.map((t) => <option key={t} value={t}>{t}</option>)}
                  </select>
                </label>
                {mine.length > 0 ? (
                  <>
                    <div className="cx-minis">
                      {panels.filter(([k]) => !(dmlOnly && k !== "dml_rows")).map(([k, w, c]) => {
                        const vals = mine.map((r) => numOrZero(r[k]));
                        return <CxMiniCols key={k} title={w} color={c} days={days} values={vals}
                          sub={`${fmtInt(vals.reduce((s, v) => s + v, 0))} in all`} dayLabel={(d) => fmtDayShort(d)} />;
                      })}
                    </div>
                    <div className="cx-foot"><span>{dmlOnly ? "Reads, writes and DDL need ACCESS_HISTORY (Enterprise edition): only rows changed are shown." : "Reads, writes and DDL in distinct queries; rows changed from TABLE_DML_HISTORY."}</span></div>
                  </>
                ) : okNote("Reads, writes and rows changed: not among the busiest tables, which the export keeps. It is listed for its clustering credits.")}
                <TablePerf c={tp} name={cur} ddlDays={!mine.length ? undefined : dmlOnly ? null : mine.filter((r) => numOrZero(r.ddl_queries) > 0).map((r) => String(day(r.usage_date)))} />
                <QueryDetail prof={qp} shapes={qs} level="table" name={cur} />
                <TableColumns rows={(tc.rows || []).filter((r) => String(r.table_fqn).toUpperCase() === String(cur).toUpperCase())} loading={tc.loading} why={tc.why} />
                {users.length > 0 && !levelRows(qp.rows, "table_user").some((r) => String(r.table_fqn).toUpperCase() === String(cur).toUpperCase()) && (
                  <div className="cx-block">
                    <CxTable ariaLabel={`Who uses ${cur}`}
                      foot={users[0] && numOrZero(users[0].table_users) > new Set(users.slice(0, 10).map((r) => r.user_name)).size ? `${fmtInt(new Set(users.slice(0, 10).map((r) => r.user_name)).size)} of ${plural(numOrZero(users[0].table_users), "user")} shown.` : undefined}
                      cols={[{ label: "User" }, { label: "Role" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Days", num: true }, { label: "Last", num: true }]}
                      rows={users.slice(0, 10).map((r) => ({
                        key: `${r.user_name}|${r.role_name}`,
                        cells: [<span>{String(r.user_name || "–")}{isTrue(r.is_service_user) ? <> <CxChip>{"service"}</CxChip></> : null}</span>, String(r.role_name || "–"),
                          fmtInt(numOrZero(r.read_queries)), fmtInt(numOrZero(r.write_queries)), fmtInt(numOrZero(r.ddl_queries)), fmtInt(numOrZero(r.active_days)), lastDay(r.last_at)],
                      }))} />
                  </div>
                )}
              </div>
            );
          }}
        </Slot>
      </div>
      <Slot c={ta} title="Unread tables, largest first" subtitle="Written but never read, and idle · the cost is on Storage › Unused & sprawl">
        {() => {
          const list = tables.filter((r) => r.usage_class === "written_never_read" || r.usage_class === "idle").sort((a, b) => numOrZero(b.storage_gb) - numOrZero(a.storage_gb));
          return list.length ? (
            <CxTable ariaLabel="Unread tables" foot={list.length > 10 ? `Top 10 of ${plural(list.length, "table")}.` : undefined}
              cols={[{ label: "Table" }, { label: "Use" }, { label: "Owner" }, { label: "Storage", num: true }, { label: "Last write", num: true }, { label: "Last DDL", num: true }]}
              rows={list.slice(0, 10).map((r) => ({
                key: String(r.table_id ?? r.table_fqn), onClick: drawerBy("sf_use_table_activity", "table_fqn", r.table_fqn, String(r.table_fqn)),
                cells: [<CxObjName full={String(r.table_fqn)} id={r.table_id} />, CLASS_WORD[String(r.usage_class)] || String(r.usage_class), String(r.table_owner || "–"),
                  fmtSize(numOrZero(r.storage_gb)), r.last_write_at ? dayYear(r.last_write_at, p) : "–", r.last_ddl ? dayYear(r.last_ddl, p) : "–"],
              }))} />
          ) : okNote("Every table was read in the window.");
        }}
      </Slot>
    </div>
  );
}

/** One row per day. A table rebuilt with CREATE OR REPLACE has a new id each time, under the same name. */
function sumByDay(rows: Row[], keys: string[]): Row[] {
  const byDay = new Map<string, Row>();
  rows.forEach((r) => {
    const d = String(r.usage_date);
    const seen = byDay.get(d);
    if (!seen) { byDay.set(d, { ...r }); return; }
    keys.forEach((k) => { if (r[k] != null) seen[k] = numOrZero(seen[k]) + numOrZero(r[k]); });
  });
  return [...byDay.values()].sort((a, b) => String(a.usage_date).localeCompare(String(b.usage_date)));
}

const PERF_SUMS = ["queries", "elapsed_s", "compile_s", "exec_s", "num_scans", "partitions_scanned", "partitions_pruned", "clustering_credits", "bytes_reclustered", "est_clustering_usd_list"];

/** How one table ran each day: time per query, time waiting, partitions skipped and clustering credits.
 *  Running against waiting tells a table problem from a warehouse one. Quiet days read "–", never 0. */
function TablePerf({ c, name, ddlDays }: { c: ReturnType<typeof useCheck>; name: string; ddlDays?: string[] | null }) {
  if (c.loading) return <div className="chart-note-oneline">…</div>;
  if (c.why) return <div className="chart-note-oneline">{`How it ran: – ${c.why}`}</div>;
  // The per-query and per-partition figures are worked out again from the day's sums.
  const mine = sumByDay((c.rows || []).filter((r) => String(r.table_fqn) === name), PERF_SUMS).map((r): Row => {
    const queries = numOrZero(r.queries), scans = numOrZero(r.partitions_scanned) + numOrZero(r.partitions_pruned);
    const waited = Math.max(numOrZero(r.elapsed_s) - numOrZero(r.compile_s) - numOrZero(r.exec_s), 0);
    return { ...r, avg_exec_s: queries ? numOrZero(r.exec_s) / queries : null, avg_wait_s: queries ? waited / queries : null,
             prune_pct: scans ? 100 * numOrZero(r.partitions_pruned) / scans : null };
  });
  if (!mine.length) return <div className="chart-note-oneline">How it ran: not among the tables with the most queries or clustering credits, which the export keeps.</div>;
  const days = mine.map((r) => String(day(r.usage_date)));
  const dayWord = (d: string) => fmtDayShort(d);
  const sum = (k: string) => mine.reduce((s, r) => s + numOrZero(r[k]), 0);
  const queries = sum("queries");
  const ps = sum("partitions_scanned"), pp = sum("partitions_pruned");
  const credits = sum("clustering_credits");
  const usd = mine.some((r) => r.est_clustering_usd_list != null) ? sum("est_clustering_usd_list") : null;
  const wait = sum("elapsed_s") - sum("compile_s") - sum("exec_s");
  // A figure per day, or "–" with the reason on a day that has nothing to measure.
  const panel = (k: string, fmt: (v: number) => string, none: string) => ({
    values: mine.map((r) => numOrZero(r[k])),
    tip: (i: number) => (mine[i][k] == null ? `– ${none}` : fmt(numOrZero(mine[i][k]))),
  });
  const secs = (v: number) => fmtDuration(v);
  const pct = (v: number) => fmtShare(v);
  return (
    <div className="cx-block">
      <div className="cx-eyebrow">How it ran</div>
      <div className="cx-minis">
        <CxMiniCols title="Time per query" color="var(--c1)" days={days} dayLabel={dayWord} fine marks={ddlDays || undefined}
          {...panel("avg_exec_s", secs, "no scans recorded")} sub={queries ? `${secs(sum("exec_s") / queries)} on average, ${plural(queries, "query", "queries")} that scanned it` : "No scans recorded in the window"} />
        <CxMiniCols title="Waiting per query" color="var(--c4)" days={days} dayLabel={dayWord} fine marks={ddlDays || undefined}
          {...panel("avg_wait_s", secs, "no scans recorded")} sub={queries ? `${secs(Math.max(wait, 0) / queries)} on average` : "No scans recorded in the window"} />
        <CxMiniCols title="Partitions skipped" color="var(--c2)" days={days} dayLabel={dayWord} marks={ddlDays || undefined}
          {...panel("prune_pct", pct, "no scans recorded")} sub={ps + pp ? `${pct(100 * pp / (ps + pp))} of ${fmtInt(ps + pp)} partitions` : "No scans recorded in the window"} />
        {credits > 0 && (
          <CxMiniCols title="Clustering credits" color="var(--c3)" days={days} dayLabel={dayWord} fine marks={ddlDays || undefined}
            values={mine.map((r) => numOrZero(r.clustering_credits))} tip={(i) => numOrZero(mine[i].clustering_credits).toFixed(2)}
            sub={`${credits.toFixed(1)} credits${usd != null ? ` · ${fmtMoney(usd)}` : ""}`} />
        )}
      </div>
      <div className="cx-foot"><span>{`Only queries that scanned the table are recorded here. Time is the whole query's, so a join counts in full for each table it reads. Waiting is queues, locks and other time doing no work. ${credits > 0 ? "" : "No automatic clustering in the window. "}${ddlDays === undefined ? "DDL is only recorded for the busiest tables." : ddlDays === null ? "DDL days need ACCESS_HISTORY (Enterprise edition)." : ddlDays.length ? "Dashed lines mark days with DDL." : "No DDL in the window."}`}</span></div>
    </div>
  );
}

/** The columns queries filter (WHERE) and join on for one table, with the share of partitions they skip. */
function TableColumns({ rows, loading, why }: { rows: Row[]; loading: boolean; why: string | null }) {
  if (loading) return <div className="chart-note-oneline">…</div>;
  if (why) return <div className="chart-note-oneline">{`Filter and join columns: – ${why}`}</div>;
  if (!rows.length) return <div className="chart-note-oneline">No WHERE or JOIN columns recorded for this table in the window.</div>;
  const list = (kind: string): CxRankItem[] => rows.filter((r) => r.access_type === kind).sort((a, b) => numOrZero(b.queries) - numOrZero(a.queries)).map((r) => ({
    key: `${kind}|${r.column_name}`, label: String(r.column_name), value: numOrZero(r.queries), strong: plural(numOrZero(r.queries), "query", "queries"),
    rest: r.prune_pct != null ? `skips ${fmtShare(numOrZero(r.prune_pct))} of partitions` : "",
  }));
  const where = list("WHERE"), join = list("JOIN");
  return (
    <div className="cx-block">
      <Row2>
        <div><div className="cx-eyebrow">Filtered on (WHERE)</div>{where.length ? <CxRanked items={where} layout="above" max={Math.max(...where.map((x) => x.value))} ariaLabel="WHERE columns" /> : okNote("None recorded.")}</div>
        <div><div className="cx-eyebrow">Joined on (JOIN)</div>{join.length ? <CxRanked items={join} layout="above" max={Math.max(...join.map((x) => x.value))} ariaLabel="JOIN columns" /> : okNote("None recorded.")}</div>
      </Row2>
      <div className="cx-foot"><span>{"Snowflake records WHERE and JOIN columns only, not GROUP BY. A busy filter column that skips few partitions is a clustering candidate."}</span></div>
    </div>
  );
}

const SHAPE_BY: [string, string, string][] = [["runs", "Runs", "rank_runs"], ["time", "Total time", "rank_time"], ["scanned", "Partitions scanned", "rank_scanned"], ["spilled", "Spilled", "rank_spilled"]];
const listOf = (v: any) => (v ? String(v).split(", ").filter(Boolean) : []);

/** How the queries on one table (level "table") or of one user (level "user") run: figures, the top 10 users
 *  or tables, and the top 10 query shapes with what each one reads, writes, filters and joins on. */
function QueryDetail({ prof, shapes, level, name }: { prof: ReturnType<typeof useCheck>; shapes: ReturnType<typeof useCheck>; level: "table" | "user"; name: string }) {
  const [by, setBy] = React.useState("runs");
  const [pick, setPick] = React.useState<string | null>(null);
  const keyCol = level === "table" ? "table_fqn" : "user_name";
  const mine = (r: Row) => String(r[keyCol] || "").toUpperCase() === name.toUpperCase();
  if (prof.loading || shapes.loading) return <div className="chart-note-oneline">…</div>;
  if (prof.why) return <div className="chart-note-oneline">{`How its queries run: – ${prof.why}`}</div>;
  const main = levelRows(prof.rows, level).find(mine);
  if (!main) return <div className="chart-note-oneline">{`How its queries run: not among the ${level === "table" ? "tables" : "users"} with the most queries, which the export keeps.`}</div>;
  const pairs = levelRows(prof.rows, level === "table" ? "table_user" : "user_table").filter(mine)
    .sort((a, b) => numOrZero(a.pair_rank) - numOrZero(b.pair_rank)).slice(0, 10);
  const [, byWord, rankCol] = SHAPE_BY.find((x) => x[0] === by) || SHAPE_BY[0];
  const list = levelRows(shapes.rows, level).filter(mine).filter((r) => r[rankCol] != null && numOrZero(r[rankCol]) <= 10)
    .sort((a, b) => numOrZero(a[rankCol]) - numOrZero(b[rankCol]));
  const cur = list.find((r) => String(r.shape_hash) === pick) || null;
  const days = numOrZero(main.window_days) || 1;
  const perDay = numOrZero(main.queries) / days;
  const pairWord = level === "table" ? "User" : "Table";
  return (
    <div className="cx-block">
      <div className="cx-eyebrow">{level === "table" ? "How queries on it run" : "How their queries run"}</div>
      <CxStrip>
        <SummaryTile label="Queries a day" value={perDay < 10 ? perDay.toFixed(1) : fmtInt(Math.round(perDay))} base={`${plural(numOrZero(main.queries), "query", "queries")} in ${plural(days, "day")} · ${plural(numOrZero(main.active_days), "active day")}`} />
        <SummaryTile label="Time per query" value={fmtDuration(main.avg_elapsed_s)} unit=" on average" base={`90% within ${fmtDuration(main.p90_elapsed_s)} · slowest ${fmtDuration(main.max_elapsed_s)}`} />
        <SummaryTile label="Partitions per query" value={main.avg_partitions_scanned != null ? fmtInt(Math.round(numOrZero(main.avg_partitions_scanned))) : "–"} base={main.scan_pct != null ? `${fmtShare(numOrZero(main.scan_pct))} of the partitions they could read` : undefined} />
        <SummaryTile label="Queries that spill" value={main.spill_pct != null ? fmtShare(numOrZero(main.spill_pct)) : "–"} base={`${fmtSize(numOrZero(main.gb_spilled))} spilled · ${fmtSize(numOrZero(main.gb_scanned))} scanned`} />
      </CxStrip>
      {pairs.length > 0 && (
        <div className="cx-block">
          <CxTable ariaLabel={level === "table" ? `Top users of ${name}` : `Top tables of ${name}`}
            foot={`Top ${pairs.length} ${level === "table" ? "users" : "tables"} by queries${level === "table" && numOrZero(main.users) > pairs.length ? `, of ${plural(numOrZero(main.users), "user")}` : level === "user" && numOrZero(main.tables) > pairs.length ? `, of ${plural(numOrZero(main.tables), "table")}` : ""}. A query's time and scan are the whole query's.`}
            cols={[{ label: pairWord }, { label: "Queries", num: true }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "Avg time", num: true }, { label: "Partitions / query", num: true }, { label: "Spill", num: true }]}
            rows={pairs.map((r) => ({
              key: String(level === "table" ? r.user_name : r.table_id ?? r.table_fqn),
              cells: [level === "table" ? String(r.user_name || "–") : <CxObjName full={String(r.table_fqn)} id={r.table_id} />,
                fmtInt(numOrZero(r.queries)), fmtInt(numOrZero(r.read_queries)), fmtInt(numOrZero(r.write_queries)), fmtDuration(r.avg_elapsed_s),
                r.avg_partitions_scanned != null ? fmtInt(Math.round(numOrZero(r.avg_partitions_scanned))) : "–", r.spill_pct != null && numOrZero(r.spill_pct) > 0 ? fmtShare(numOrZero(r.spill_pct)) : "–"],
            }))} />
        </div>
      )}
      <div className="cx-block">
        <div className="cx-eyebrow">{`Top queries by ${byWord.toLowerCase()}`}</div>
        <div className="cx-seg" role="group" aria-label="Top queries by">
          {SHAPE_BY.map(([k, w]) => <button key={k} type="button" className={by === k ? "on" : ""} aria-pressed={by === k} onClick={() => setBy(k)}>{w}</button>)}
        </div>
        {list.length ? (
          <div className="cx-block">
            <CxTable ariaLabel={`Top queries by ${byWord}`}
              foot="One row = one query shape: the same statement with different values. Select one for the tables and columns it uses."
              cols={[{ label: "Query" }, { label: "Runs", num: true }, { label: "Users", num: true }, { label: "Avg time", num: true }, { label: "Total time", num: true }, { label: "Partitions / run", num: true }, { label: "Spilled", num: true }]}
              rows={list.map((r) => ({
                key: String(r.shape_hash), on: cur === r, onClick: () => setPick(cur === r ? null : String(r.shape_hash)),
                cells: [<span>{String(r.query_type || "–")}<span className="cx-muted">{` · ${r.warehouse_name || "no warehouse"} · ${String(r.shape_hash || "").slice(0, 8)}`}</span></span>,
                  fmtInt(numOrZero(r.runs)), fmtInt(numOrZero(r.users)), fmtDuration(r.avg_elapsed_s), fmtDuration(r.total_elapsed_s),
                  r.avg_partitions_scanned != null ? fmtInt(Math.round(numOrZero(r.avg_partitions_scanned))) : "–", numOrZero(r.gb_spilled) > 0 ? fmtSize(numOrZero(r.gb_spilled)) : "–"],
              }))} />
            {cur && <ShapeLineage r={cur} />}
          </div>
        ) : okNote(by === "spilled" ? "No query spilled." : "No query shape recorded.")}
      </div>
    </div>
  );
}

/** What one query shape reads, writes, filters on and joins on, and its slowest run. */
function ShapeLineage({ r }: { r: Row }) {
  const line = (label: string, v: any, none: string) => (
    <CxStat><span><b>{`${label}: `}</b>{listOf(v).length ? listOf(v).join(" · ") : <span className="cx-muted">{none}</span>}</span></CxStat>
  );
  return (
    <div className="cx-block">
      <div className="cx-eyebrow">{`${r.query_type || "Query"} · ${String(r.shape_hash || "").slice(0, 8)}`}</div>
      {line("Reads", r.tables_read, "no table")}
      {line("Writes", r.tables_written, "no table")}
      {line("Filters on (WHERE)", r.where_columns, "none recorded")}
      {line("Joins on (JOIN)", r.join_columns, "none recorded")}
      <div className="cx-foot"><span>{`Slowest run ${fmtDuration(r.max_elapsed_s)}: query id ${r.slowest_query_id || "–"}, to open in Snowsight's query profile. Snowflake records WHERE and JOIN columns, not GROUP BY.`}</span></div>
    </div>
  );
}

// ═══════════════════════ Activity › Users & roles ═══════════════════════

const LOGIN_BANDS: [string, number, number][] = [["within 7 days", 0, 8], ["8-30 days", 8, 31], ["31-90 days", 31, 91], ["over 90 days", 91, Infinity]];

export function ApActivityUsers(p: ApPageProps) {
  const io = useCheck(p, "sf_use_user_data_io");
  const ua = useCheck(p, "sf_use_user_activity");
  const tr = useCheck(p, "sf_use_table_readers");
  const qp = useCheck(p, "sf_use_query_profile");
  const qs = useCheck(p, "sf_use_top_query_shapes");
  const profUsers = levelRows(qp.rows, "user").sort((a, b) => numOrZero(a.entity_rank) - numOrZero(b.entity_rank)).map((r) => String(r.user_name));
  const [selUser, setSelUser] = React.useState<string | null>(null);
  const curUser = selUser && profUsers.includes(selUser) ? selUser : profUsers[0] || null;
  const users = levelRows(io.rows, "user");
  const roles = levelRows(io.rows, "role");
  // The user and role lists are capped; the counts and shares come from the check's uncapped total row.
  const tot = levelRows(io.allRows, "total")[0] || null;
  const nUsers = tot ? numOrZero(tot.users) : users.length;
  const allQ = tot ? numOrZero(tot.data_queries) : users.reduce((s, r) => s + numOrZero(r.data_queries), 0);
  const svcPct = tot ? numOrZero(tot.service_query_pct) : pctOf(users.filter((r) => isTrue(r.is_service_user)).reduce((s, r) => s + numOrZero(r.data_queries), 0), allQ);
  const nSvc = tot ? numOrZero(tot.service_users) : users.filter((r) => isTrue(r.is_service_user)).length;
  const roleQ = allQ;
  const topRole = [...roles].sort((a, b) => numOrZero(b.data_queries) - numOrZero(a.data_queries))[0];
  const idle = (ua.rows || []).filter((r) => isTrue(r.idle_with_roles));
  const asOf = p.meta && p.meta.as_of_date ? Date.parse(`${String(p.meta.as_of_date).slice(0, 10)}T00:00:00Z`) : NaN;
  useLede(p, io.loading || ua.loading, [
    nUsers ? `${plural(nUsers, "user")} read, wrote or changed data; service users ran ${fmtShare(svcPct)} of those queries.` : null,
    ua.rows ? `${fmtInt(idle.length)} of ${plural(ua.rows.length, "user")} hold roles but ran nothing.` : null,
  ].filter(Boolean).join(" ") || null);
  const userItem = (r: Row): CxRankItem => ({
    key: String(r.user_name), value: numOrZero(r.data_queries),
    label: <span>{String(r.user_name || "(no user)")}{isTrue(r.is_service_user) ? <> <CxChip>{"service"}</CxChip></> : null}</span>,
    strong: plural(numOrZero(r.data_queries), "query", "queries"), rest: `${plural(numOrZero(r.tables_read), "table")} read · ${fmtInt(numOrZero(r.tables_written))} written`,
    onClick: profUsers.includes(String(r.user_name))
      ? () => { setSelUser(String(r.user_name)); document.getElementById("act-user-q")?.scrollIntoView({ behavior: "smooth", block: "start" }); }
      : drawerBy("sf_use_user_data_io", "user_name", r.user_name, String(r.user_name)),
  });
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <CheckTile c={io} label="Users touching data" build={() => ({
          headline: fmtInt(nUsers), unit: " users",
          base: `${plural(allQ, "query", "queries")} read, wrote or changed a data object.`,
        })} />
        <CheckTile c={io} label="Run by service users" build={() => ({
          headline: fmtShare(svcPct), unit: " of data queries",
          base: `${fmtInt(nSvc)} of ${plural(nUsers, "user")} are service users.`,
        })} />
        <CheckTile c={io} label="Busiest role" build={() => ({
          headline: topRole ? fmtShare(pctOf(numOrZero(topRole.data_queries), roleQ)) : null, unit: " of data queries", missingReason: topRole ? undefined : "no role rows",
          base: topRole ? String(topRole.role_name) : null,
          cause: topRole ? `${plural(numOrZero(topRole.users), "user")} used it.` : undefined,
        })} />
        <CheckTile c={ua} label="Hold roles, run nothing" badge build={(rows) => ({
          headline: fmtShare(pctOf(idle.length, rows.length)), unit: " of users",
          base: `${fmtInt(idle.length)} of ${plural(rows.length, "user")} hold roles but ran nothing.`,
          cause: `${fmtInt(idle.filter((r) => isTrue(r.has_admin_role)).length)} of them can use an admin role.`, openLabel: "By last sign-in ↓",
        })} />
      </SummaryTileRow>
      <Row2>
        <Slot c={io} title="Most active users" subtitle="Queries that read, wrote or changed a data object">
          {() => {
            const items = [...users].sort((a, b) => numOrZero(b.data_queries) - numOrZero(a.data_queries)).map(userItem);
            return items.length ? <RankedAbove items={items} noun="users" ariaLabel="Most active users" /> : okNote("No user touched data in the window.");
          }}
        </Slot>
        <Slot c={io} title="Most active roles" subtitle="Queries run under each primary role · share run by service users">
          {() => {
            const items: CxRankItem[] = [...roles].sort((a, b) => numOrZero(b.data_queries) - numOrZero(a.data_queries)).map((r) => ({
              key: String(r.role_name), label: String(r.role_name || "(no role)"), value: numOrZero(r.data_queries),
              strong: fmtShare(pctOf(numOrZero(r.data_queries), roleQ)),
              rest: `${plural(numOrZero(r.users), "user")} · ${fmtShare(numOrZero(r.service_query_pct))} by service users`,
              onClick: drawerBy("sf_use_user_data_io", "role_name", r.role_name, String(r.role_name)),
            }));
            return items.length ? <RankedAbove items={items} noun="roles" ariaLabel="Most active roles" /> : null;
          }}
        </Slot>
      </Row2>
      <div id="act-user-q">
        <Slot c={qp} title="One user's queries" subtitle="How their queries run, the tables they use most and their top queries, with the tables and columns each one uses">
          {() => curUser ? (
            <div>
              <label className="cx-muted">{"User "}
                <select value={curUser} onChange={(e) => setSelUser(e.target.value)} aria-label="User">
                  {profUsers.map((u) => <option key={u} value={u}>{u}</option>)}
                </select>
              </label>
              <QueryDetail prof={qp} shapes={qs} level="user" name={curUser} />
            </div>
          ) : okNote("No user read or wrote a table in the window.")}
        </Slot>
      </div>
      <Slot c={tr} title="Who uses which tables" subtitle="User and role on the busiest tables · the top 20 by queries">
        {(rows) => rows.length ? (
          <CxTable ariaLabel="Users on tables"
            cols={[{ label: "User" }, { label: "Role" }, { label: "Table" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Days", num: true }, { label: "Last", num: true }]}
            rows={[...rows].sort(byTouches).slice(0, 20).map((r) => ({
              key: `${r.user_name}|${r.role_name}|${r.table_id ?? r.table_fqn}`,
              onClick: drawerBy("sf_use_table_readers", "user_name", r.user_name, String(r.user_name)),
              cells: [<span>{String(r.user_name || "–")}{isTrue(r.is_service_user) ? <> <CxChip>{"service"}</CxChip></> : null}</span>, String(r.role_name || "–"),
                <CxObjName full={String(r.table_fqn)} id={r.table_id} />, fmtInt(numOrZero(r.read_queries)), fmtInt(numOrZero(r.write_queries)),
                fmtInt(numOrZero(r.ddl_queries)), fmtInt(numOrZero(r.active_days)), lastDay(r.last_at)],
            }))} />
        ) : okNote("No user read or wrote a table in the window.")}
      </Slot>
      <Slot c={ua} title="Users by last sign-in" subtitle="days since the last successful sign-in, as of the export · dark bar = can use an admin role">
        {(rows) => {
          const bandOfRow = (r: Row) => {
            const s = r.last_success_login ? String(r.last_success_login) : "";
            const t = s ? Date.parse(s.slice(0, 19) + (s.length <= 10 ? "T00:00:00Z" : "Z")) : NaN;
            if (!Number.isFinite(t) || !Number.isFinite(asOf)) return s ? null : "never";
            const d = Math.max(0, Math.floor((asOf - t) / 86400000));
            const b = LOGIN_BANDS.find(([, lo, hi]) => d >= lo && d < hi);
            return b ? b[0] : null;
          };
          const by = new Map<string, { value: number; whole: number }>();
          [...LOGIN_BANDS.map((b) => b[0]), "never"].forEach((k) => by.set(k, { value: 0, whole: 0 }));
          rows.forEach((r) => {
            const k = bandOfRow(r);
            if (!k) return;
            const c = by.get(k)!;
            c.whole += 1;
            if (isTrue(r.has_admin_role)) c.value += 1;
          });
          // Bands stay in time order, the most recent first; "never" last.
          const items = [...by.entries()].filter(([, v]) => v.whole > 0).map(([name, v]) => ({ name: name === "never" ? "Never signed in" : name.charAt(0).toUpperCase() + name.slice(1), value: v.value, whole: v.whole }));
          if (items.length < 2) return null;
          const old = by.get("over 90 days")!.whole + by.get("never")!.whole;
          const max = Math.max(...items.map((x) => x.whole));
          return (
            <div>
              <CxStat>{<span><b>{`${fmtInt(old)} of ${plural(rows.length, "user")}`}</b>{" have not signed in for over 90 days, or never."}</span>}</CxStat>
              <div className="cx-block"><CxTable ariaLabel="Users by last sign-in, admins" cols={[{ label: "Last sign-in" }, { label: "", width: "40%" }, { label: "Users", num: true }, { label: "Admins", num: true }]}
                foot="Dark part: can use an admin role."
                rows={items.map((x) => ({ key: x.name, cells: [x.name, <CxTwoBar part={x.value} whole={x.whole} max={max} />, fmtInt(x.whole), x.value ? <b>{fmtInt(x.value)}</b> : "–"] }))} /></div>
            </div>
          );
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Activity › Stages & other objects ═══════════════════════

const KIND_WORD: Record<string, string> = {
  STAGE: "Stages", VIEW: "Views", FUNCTION: "Functions", PROCEDURE: "Procedures", PIPE: "Pipes", TASK: "Tasks",
  STREAM: "Streams", SEQUENCE: "Sequences", "FILE FORMAT": "File formats", ALERT: "Alerts",
};
const KIND_ORDER = Object.keys(KIND_WORD);
const kindWord = (k: any) => KIND_WORD[String(k)] || String(k || "").toLowerCase();
const objTouches = (r: Row) => touches(r) + numOrZero(r.executions);

export function ApActivityObjects(p: ApPageProps) {
  const oa = useCheck(p, "sf_use_object_activity");
  const uv = useCheck(p, "sf_lin_unused_views");
  const kinds = levelRows(oa.allRows, "domain").filter((r) => KIND_WORD[String(r.object_domain)])
    .sort((a, b) => KIND_ORDER.indexOf(String(a.object_domain)) - KIND_ORDER.indexOf(String(b.object_domain)));
  const objects = levelRows(oa.rows, "object");
  const kind = (k: string) => kinds.find((r) => r.object_domain === k);
  const counted = kinds.filter((r) => r.objects != null && r.active_objects != null);
  const inactive = counted.reduce((s, r) => s + Math.max(0, numOrZero(r.objects) - numOrZero(r.active_objects)), 0);
  const total = counted.reduce((s, r) => s + numOrZero(r.objects), 0);
  const unread = (uv.rows || []).filter(isFlagged);
  useLede(p, oa.loading || uv.loading, counted.length ? `${fmtInt(inactive)} of ${plural(total, "object")} (stages, views, functions, procedures, pipes, tasks) had no use in the window.` : null);
  const kindTile = (k: string, label: string, cause: string) => (
    <CheckTile c={oa} label={label} build={() => {
      const r = kind(k);
      if (!r || r.active_objects == null) return { headline: null, missingReason: r ? "needs ACCESS_HISTORY (Enterprise edition)" : "none the role can see" };
      return { headline: fmtInt(numOrZero(r.active_objects)), unit: ` of ${plural(numOrZero(r.objects), kindWord(k).toLowerCase().replace(/s$/, ""))} in use`, cause };
    }} />
  );
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        {kindTile("STAGE", "Stages in use", "Read or written by a query (COPY, GET, PUT, SELECT).")}
        {kindTile("TASK", "Tasks that ran", "At least one run in the window.")}
        {kindTile("PIPE", "Pipes that loaded", "At least one file loaded in the window.")}
        <CheckTile c={uv} label="Views never read" badge build={(rows) => ({
          // The check lists flagged views only; the count of all views comes from the object inventory.
          headline: fmtInt(rows.filter(isFlagged).length), unit: " views",
          base: kind("VIEW") && kind("VIEW")!.objects != null ? `of ${plural(numOrZero(kind("VIEW")!.objects), "view")} the role can see` : null,
          cause: `No query in the window; ${fmtInt(rows.filter((r) => isFlagged(r) && isTrue(r.is_secure)).length)} of them are secure views.`, openLabel: "Which ones ↓",
        })} />
      </SummaryTileRow>
      <Row2>
        <Slot c={oa} title="Objects in use, by kind" subtitle="Dark part = used in the window">
          {() => {
            if (!kinds.length) return okNote("No stage, view, function, procedure, pipe or task the role can see.");
            const max = Math.max(1, ...kinds.map((r) => numOrZero(r.objects ?? r.active_objects)));
            return (
              <CxTable ariaLabel="Objects by kind"
                foot="Runs / files: task runs, or files a pipe loaded."
                cols={[{ label: "Kind" }, { label: "", width: "30%" }, { label: "In use", num: true }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "Runs / files", num: true }]}
                rows={kinds.map((r) => ({
                  key: String(r.object_domain), status: r.status === "NOT_ASSESSED" ? "NOT_ASSESSED" : null,
                  onClick: drawerBy("sf_use_object_activity", "object_domain", r.object_domain, kindWord(r.object_domain)),
                  cells: [kindWord(r.object_domain), r.objects != null ? <CxTwoBar part={numOrZero(r.active_objects)} whole={numOrZero(r.objects)} max={max} /> : "–",
                    r.active_objects == null ? "–" : r.objects != null ? `${fmtInt(numOrZero(r.active_objects))} of ${fmtInt(numOrZero(r.objects))}` : fmtInt(numOrZero(r.active_objects)),
                    r.read_queries == null ? "–" : fmtInt(numOrZero(r.read_queries)), r.write_queries == null ? "–" : fmtInt(numOrZero(r.write_queries)),
                    numOrZero(r.executions) ? fmtInt(numOrZero(r.executions)) : "–"],
                }))} />
            );
          }}
        </Slot>
        <Slot c={oa} title="Most active objects" subtitle="Reads, writes and DDL, plus task runs and pipe files">
          {() => {
            const items: CxRankItem[] = objects.filter((r) => objTouches(r) > 0).sort((a, b) => objTouches(b) - objTouches(a)).map((r) => ({
              key: `${r.object_domain}|${r.object_key}`, value: objTouches(r),
              label: <span className="cx-dotlabel"><CxChip>{kindWord(r.object_domain).replace(/s$/, "").toLowerCase()}</CxChip> <CxObjName full={String(r.object_fqn || r.object_name || "(unnamed)")} /></span>,
              strong: fmtInt(objTouches(r)), rest: !numOrZero(r.executions) ? rwd(r) : touches(r) ? `${rwd(r)} · ${fmtInt(numOrZero(r.executions))} runs / files` : "runs / files",
              onClick: drawerBy("sf_use_object_activity", "object_key", r.object_key, String(r.object_fqn || r.object_name)),
            }));
            return items.length ? <RankedAbove items={items} noun="objects" ariaLabel="Most active objects" /> : okNote("No object was used in the window.");
          }}
        </Slot>
      </Row2>
      <Slot c={uv} title="Views never read in the window" subtitle="Views with no reader · select a row for the fix">
        {() => (
          unread.length ? <CxTable ariaLabel="Views never read" foot={unread.length > 10 ? `Top 10 of ${plural(unread.length, "view")}.` : undefined}
            cols={[{ label: "View" }, { label: "Owner" }, { label: "Created", num: true }, { label: "Last changed", num: true }]}
            rows={unread.slice(0, 10).map((r) => ({
              key: `${r.account_id}|${r.view_fqn}`, status: r.status, onClick: drawerBy("sf_lin_unused_views", "view_fqn", r.view_fqn, String(r.view_fqn)),
              cells: [<span><CxObjName full={String(r.view_fqn)} />{isTrue(r.is_secure) ? <div className="cx-muted">{"Secure view"}</div> : null}</span>, String(r.view_owner || "–"),
                dayYear(r.created, p), dayYear(r.last_altered, p)],
            }))} /> : okNote("Every view was read in the window.")
        )}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Activity › Last active ═══════════════════════

const LA_BANDS = ["under_30", "d30_90", "d90_180", "d180_360", "over_360", "beyond_history"];
const LA_RECENT = "under_30";
const OBJ_KINDS = ["VIEW", "STAGE", "FUNCTION", "PROCEDURE", "PIPE", "TASK"];
// Tasks and pipes date from their own history; everything else needs ACCESS_HISTORY.
const ownHistory = (k: unknown) => k === "TASK" || k === "PIPE";
// The shortest gap each band holds: under that much history it can't fill, which isn't a measured 0.
const LA_FROM: Record<string, number> = { d30_90: 30, d90_180: 90, d180_360: 180, over_360: 360 };
const PATTERN_WORD: Record<string, string> = {
  read_and_written: "Read and written", read_not_written: "Read, no write", written_not_read: "Written, no read",
  no_read_no_write: "No read, no write", used: "Used", not_used: "Not used",
};
const fullDay = (v: any) => { const d = day(v); return d ? `${fmtDayShort(d)}, ${d.slice(0, 4)}` : "–"; };
const laTime = (r: Row) => (r.last_active_at ? Date.parse(String(r.last_active_at)) : 0);

function bandWord(b: string, history: number): string {
  switch (b) {
    case "under_30": return "Active in the last 30 days";
    case "d30_90": return "Not active for 30–90 days";
    case "d90_180": return "Not active for 90–180 days";
    case "d180_360": return "Not active for 180–360 days";
    case "over_360": return "Not active for over 360 days";
    default: return `Nothing in the ${fmtInt(history)} days of history`;
  }
}

/** One chart of bands and the list behind it: pick a band to see which ones, oldest first. */
function LastActiveBlock({ c, kinds, noun, title, tables }: { c: ReturnType<typeof useCheck>; kinds: string[]; noun: string; title: string; tables: boolean }) {
  const [band, setBand] = React.useState("");
  const [kind, setKind] = React.useState("");
  const [db, setDb] = React.useState("");
  const [pattern, setPattern] = React.useState("");
  const [sort, setSort] = React.useState("oldest");
  const picked = kind ? [kind] : kinds;
  const totals = levelRows(c.allRows, "band").filter((r) => picked.includes(String(r.object_kind)));
  const rows = levelRows(c.rows, "object").filter((r) => picked.includes(String(r.object_kind)));
  const dated = totals.filter((r) => !ownHistory(r.object_kind) && r.active_band !== "not_assessed");
  const history = numOrZero(dated[0]?.history_days);
  const tooShort = (b: string) => dated.length > 0 && history < (LA_FROM[b] ?? 0);
  const count = (b: string) => totals.filter((r) => r.active_band === b).reduce((s, r) => s + numOrZero(r.objects), 0);
  const size = (b: string) => totals.filter((r) => r.active_band === b).reduce((s, r) => s + numOrZero(r.storage_gb), 0);
  const whole = LA_BANDS.reduce((s, b) => s + count(b), 0);
  const blocked = count("not_assessed");
  const inBand = (r: Row) => (band ? r.active_band === band : r.active_band !== LA_RECENT && r.active_band !== "not_assessed");
  const listed = rows.filter(inBand);
  const dbs = Array.from(new Set(listed.map((r) => String(r.database_name || "")).filter(Boolean))).sort();
  // A database picked earlier can leave the list when the page filters change.
  const dbOn = dbs.includes(db) ? db : "";
  const filtered = !!dbOn || !!pattern;
  const shown = listed.filter((r) => (!dbOn || r.database_name === dbOn) && (!pattern || r.use_pattern === pattern));
  const order = sort === "largest" ? (a: Row, b: Row) => numOrZero(b.storage_gb) - numOrZero(a.storage_gb)
    : sort === "newest" ? (a: Row, b: Row) => laTime(b) - laTime(a) : (a: Row, b: Row) => laTime(a) - laTime(b);
  const sorted = [...shown].sort(order);
  const expected = band ? count(band) : LA_BANDS.filter((b) => b !== LA_RECENT).reduce((s, b) => s + count(b), 0);
  const capped = listed.length < expected;
  const lastUsed = (r: Row) => r.last_read_at || r.last_run_at;
  const csv = [
    { label: "Name", value: (r: Row) => r.object_fqn }, { label: "Id", value: (r: Row) => r.object_id }, { label: "Kind", value: (r: Row) => r.object_kind },
    { label: "Owner", value: (r: Row) => r.object_owner }, { label: "Last active", value: (r: Row) => day(r.last_active_at) },
    { label: "Days since", value: (r: Row) => r.days_since_active }, { label: "Last read", value: (r: Row) => day(r.last_read_at) },
    { label: "Last write", value: (r: Row) => day(r.last_write_at) }, { label: "Last run", value: (r: Row) => day(r.last_run_at) },
    { label: "Use", value: (r: Row) => PATTERN_WORD[String(r.use_pattern)] }, { label: "Depends on it", value: (r: Row) => r.dependents },
    { label: "Storage GB", value: (r: Row) => r.storage_gb },
  ];
  const nameCell = (r: Row) => <CxObjName full={String(r.object_fqn || r.object_name)} id={r.object_id} />;
  const since = (r: Row) => (r.active_band === "beyond_history" ? `over ${fmtInt(numOrZero(r.history_days))} days` : r.days_since_active == null ? "–" : plural(numOrZero(r.days_since_active), "day"));
  return (
    <Slot c={c} title={title} subtitle="Pick a bar to see which ones">
      {() => (
        <div>
          {!tables && (
            <div className="act-db-pick"><label className="cx-muted">{"Kind "}
              <select value={kind} onChange={(e) => { setKind(e.target.value); setDb(""); }} aria-label="Kind">
                <option value="">{"All kinds"}</option>
                {kinds.map((k) => <option key={k} value={k}>{kindWord(k)}</option>)}
              </select>
            </label></div>
          )}
          {!whole && blocked > 0 && okNote(`– needs ACCESS_HISTORY (Enterprise edition): ${plural(blocked, noun)} can't be dated.`)}
          {!whole && !blocked && okNote(`No ${kind ? kindWord(kind).toLowerCase() : `${noun}s`} the role can see in this selection.`)}
          {whole > 0 && (<>
            <CxBarRows legend={false} ariaLabel={title} max={Math.max(1, ...LA_BANDS.map(count))} n={LA_BANDS.length}
              rows={LA_BANDS.filter((b) => b !== "beyond_history" || count(b) > 0).map((b) => {
                const pick = () => { setBand(band === b ? "" : b); setDb(""); };
                if (tooShort(b) && !picked.some(ownHistory)) return { key: b, name: bandWord(b, history), value: 0, strong: "–", rest: ` · needs ${fmtInt(LA_FROM[b])}+ days of history` };
                return {
                  key: b, name: bandWord(b, history), value: count(b),
                  strong: `${fmtInt(count(b))} of ${plural(whole, noun)}`,
                  rest: tooShort(b) ? " · tasks and pipes only" : tables ? ` · ${fmtSize(size(b))}` : undefined,
                  onClick: pick,
                };
              })} />
            {dated.length > 0 && history < 360 && (
              <div className="cx-foot"><span>{`This account has ${fmtInt(history)} days of access history, so longer gaps can't be told apart yet.`}</span></div>
            )}
            {blocked > 0 && (
              <div className="cx-foot"><span>{`${plural(blocked, noun)} can't be dated without ACCESS_HISTORY (Enterprise edition). The bars count only the rest.`}</span></div>
            )}
            <h4 className="act-la-head">{band ? bandWord(band, history) : "Not active for 30 days or more"}{` · ${filtered ? `${fmtInt(sorted.length)} of ` : ""}${plural(expected, noun)}`}</h4>
            <div className="act-db-pick">
              <DbPick dbs={dbs} db={dbOn} setDb={setDb} />
              {tables && (
                <label className="cx-muted">{"Use "}
                  <select value={pattern} onChange={(e) => setPattern(e.target.value)} aria-label="Use">
                    <option value="">{"Any"}</option>
                    {["no_read_no_write", "written_not_read", "read_not_written", "read_and_written"].map((k) => <option key={k} value={k}>{PATTERN_WORD[k]}</option>)}
                  </select>
                </label>
              )}
              <label className="cx-muted">{" Sort "}
                <select value={sort} onChange={(e) => setSort(e.target.value)} aria-label="Sort">
                  <option value="oldest">{"Oldest first"}</option>
                  <option value="newest">{"Newest first"}</option>
                  {tables && <option value="largest">{"Largest first"}</option>}
                </select>
              </label>
              <CsvButton fileName={tables ? "tables_last_active" : "objects_last_active"} columns={csv} rows={sorted} />
            </div>
            {sorted.length ? (
              <CxTable ariaLabel={`${title}: which ones`} n={10}
                foot={`– = none in the history, or not known.${capped ? ` Lists the ${tables ? "largest" : "oldest"} ${fmtInt(listed.length)} of ${fmtInt(expected)}; the bars count them all${filtered ? ", and a filter only sees those listed" : ""}.` : ""}`}
                cols={tables
                  ? [{ label: "Table" }, { label: "Owner" }, { label: "Last active" }, { label: "Since", num: true }, { label: "Last read" }, { label: "Last write" }, { label: "Use" }, { label: "Depends on it", num: true }, { label: "Storage", num: true }]
                  : [{ label: "Object" }, { label: "Kind" }, { label: "Owner" }, { label: "Last active" }, { label: "Since", num: true }, { label: "Last read or run" }, { label: "Depends on it", num: true }]}
                rows={sorted.map((r) => ({
                  key: String(r.object_key), onClick: drawerBy("sf_use_last_active", "object_key", r.object_key, String(r.object_fqn || r.object_name)),
                  cells: tables
                    ? [nameCell(r), String(r.object_owner || "–"), fullDay(r.last_active_at), since(r), fullDay(r.last_read_at), fullDay(r.last_write_at), PATTERN_WORD[String(r.use_pattern)] || "–", r.dependents == null ? "–" : fmtInt(numOrZero(r.dependents)), fmtSize(numOrZero(r.storage_gb))]
                    : [nameCell(r), kindWord(String(r.object_kind)).replace(/s$/, ""), String(r.object_owner || "–"), fullDay(r.last_active_at), since(r), fullDay(lastUsed(r)), r.dependents == null ? "–" : fmtInt(numOrZero(r.dependents))],
                }))} />
            ) : okNote(!listed.length && expected > 0 ? "The export's row limit left these out; the bars count them all." : `No ${noun} in this selection.`)}
          </>)}
        </div>
      )}
    </Slot>
  );
}

export function ApActivityLastActive(p: ApPageProps) {
  const c = useCheck(p, "sf_use_last_active", true);
  const totals = levelRows(c.allRows, "band");
  const sum = (kinds: string[], bands: string[]) => totals.filter((r) => kinds.includes(String(r.object_kind)) && bands.includes(String(r.active_band))).reduce((s, r) => s + numOrZero(r.objects), 0);
  const old = LA_BANDS.filter((b) => b !== LA_RECENT);
  const tOld = sum(["TABLE"], old);
  const tAll = sum(["TABLE"], LA_BANDS);
  const oOld = sum(OBJ_KINDS, old);
  const oAll = sum(OBJ_KINDS, LA_BANDS);
  const dated = totals.find((r) => !ownHistory(r.object_kind) && r.active_band !== "not_assessed");
  const history = numOrZero(dated?.history_days);
  const blocked = sum(["TABLE"], ["not_assessed"]) > 0;
  const oBlocked = sum(OBJ_KINDS, ["not_assessed"]);
  useLede(p, c.loading, tAll ? `${fmtInt(tOld)} of ${plural(tAll, "table")} had no activity for 30 days or more. Check what depends on one and ask its owner before dropping it.` : null);
  const noHistory = "needs ACCESS_HISTORY (Enterprise edition)";
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <CheckTile c={c} label="Tables not active, 30+ days" build={() => (blocked ? { headline: null, missingReason: noHistory } : !tAll ? { headline: null, missingReason: "no table in this selection" } : { headline: fmtInt(tOld), unit: ` of ${plural(tAll, "table")}`, cause: "No read, write, change or new table." })} />
        <CheckTile c={c} label="Tables not active, 360+ days" build={() => (blocked ? { headline: null, missingReason: noHistory }
          : !tAll ? { headline: null, missingReason: "no table in this selection" }
          : history < 360 ? { headline: null, missingReason: `only ${fmtInt(history)} days of access history` }
          : { headline: fmtInt(sum(["TABLE"], ["over_360"])), unit: ` of ${plural(tAll, "table")}`, cause: "The longest band." })} />
        <CheckTile c={c} label="Other objects not active, 30+ days" build={() => (!oAll ? { headline: null, missingReason: oBlocked ? noHistory : "no object in this selection" }
          : { headline: fmtInt(oOld), unit: ` of ${plural(oAll, "object")}`, cause: oBlocked ? `Tasks and pipes only; ${plural(oBlocked, "other")} need ACCESS_HISTORY.` : "Views, stages, functions, procedures, pipes, tasks." })} />
        <CheckTile c={c} label="Access history" build={() => (blocked || oBlocked ? { headline: null, missingReason: noHistory } : !dated ? { headline: null, missingReason: "no table or object in this selection" } : { headline: fmtInt(history), unit: " days", cause: "How far back reads and writes can be dated." })} />
      </SummaryTileRow>
      <LastActiveBlock c={c} kinds={["TABLE"]} noun="table" title="Tables, by time since last active" tables />
      <LastActiveBlock c={c} kinds={OBJ_KINDS} noun="object" title="Other objects, by time since last active" tables={false} />
    </div>
  );
}

/** The Activity sub-tab pages, merged into AREA_CHART_PAGES by area_pages.tsx. */
export const ACTIVITY_CHART_PAGES: Record<string, Record<string, (p: ApPageProps) => React.JSX.Element>> = {
  activity: { databases: ApActivityDatabases, schemas: ApActivitySchemas, tables: ApActivityTables, lastactive: ApActivityLastActive, users: ApActivityUsers, objects: ApActivityObjects },
};
Object.values(ACTIVITY_CHART_PAGES).forEach((m) => Object.values(m).forEach((fn) => { (fn as any).ownsTiles = true; (fn as any).ownsLede = true; }));
