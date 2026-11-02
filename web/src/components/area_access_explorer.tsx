// web/src/components/area_access_explorer.tsx -- Access › Explorer: pick a user, role or object and see
// every privilege, with every path through the roles (/api/access/explore, walked from sf_acc_grant_links).
// Also the sections of the role-model checks shown on Access › Roles & grants, Users and PII › Reads.
// area_governance.tsx registers the page and renders the sections.
import React from "react";
import { getJson } from "../api";
import { fmtDayShort, fmtInt } from "../format";
import { numOrZero } from "./hooks";
import { DrawerBus } from "./drawer";
import type { ApPageProps } from "./area_pages";
import { IssueTile } from "./blocks";
import { ChartCard } from "./primitives";
import { Row2, Slot, isFlagged, useCheck, useLede } from "./area_ai_storage";
import { SummaryTileRow } from "./overview_tile";
import { CxChip, CxStat, CxTable } from "./cx_e";

const plural = (n: number, one: string, many?: string) => `${fmtInt(n)} ${n === 1 ? one : (many || `${one}s`)}`;
const drawerBy = (id: string, col: string, val: any, label: string) => () => DrawerBus.open({ id, col, val: String(val), label });
const lastDay = (v: any) => (v ? fmtDayShort(String(v).slice(0, 10)) : "never");

type Kind = "user" | "role" | "object";
const KINDS: [Kind, string][] = [["user", "User"], ["role", "Role"], ["object", "Object"]];
// Privilege class -> chip colour: owning and account-wide power reads red, changing data amber.
const CLS_STATUS: Record<string, string | undefined> = { own: "CRITICAL", write: "WARN", read: "OK", use: undefined };
const CLS_WORD: Record<string, string> = { own: "own", write: "write", read: "read", use: "use" };
// A link can open the explorer on one name (#...&explore=role:NAME); read at load, before the shell rewrites the hash.
const START_M = /[#&]explore=(user|role|object):([^&]+)/.exec(window.location.hash);
const START = START_M ? { kind: START_M[1] as Kind, name: decodeURIComponent(START_M[2]) } : null;
const ADMIN = new Set(["ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "SYSADMIN", "ORGADMIN", "GLOBALORGADMIN"]);

/** One path as chips: user › role › role › object; admin roles in red, the last step plain. */
function PathLine({ path, onPick }: { path: string[]; onPick?: (kind: Kind, name: string) => void }) {
  return (
    <span className="ax-path">
      {path.map((x, i) => (
        <React.Fragment key={`${i}-${x}`}>
          {i > 0 && <span className="ax-sep" aria-hidden="true">›</span>}
          {onPick && i > 0 && i < path.length - 1
            ? <button type="button" className={`ax-node${ADMIN.has(x) ? " admin" : ""}`} onClick={(e) => { e.stopPropagation(); onPick("role", x); }}>{x}</button>
            : <span className={`ax-node${ADMIN.has(x) ? " admin" : ""}${i === path.length - 1 ? " last" : ""}`}>{x}</span>}
        </React.Fragment>
      ))}
    </span>
  );
}

/** The shortest path, and the others behind "+N more paths". */
function Paths({ paths, count, onPick }: { paths: string[][]; count: number; onPick: (kind: Kind, name: string) => void }) {
  const [all, setAll] = React.useState(false);
  if (!paths.length) return <span className="cx-muted">–</span>;
  const more = count - 1;
  return (
    <div className="ax-paths">
      {(all ? paths : paths.slice(0, 1)).map((p, i) => <PathLine key={i} path={p} onPick={onPick} />)}
      {more > 0 && (
        <button type="button" className="cx-linkbtn" onClick={(e) => { e.stopPropagation(); setAll(!all); }}>
          {all ? "Show fewer" : `+${fmtInt(more)} more ${more === 1 ? "path" : "paths"}`}
        </button>
      )}
      {all && count > paths.length && <span className="cx-muted">{`First ${fmtInt(paths.length)} of ${fmtInt(count)} shown.`}</span>}
    </div>
  );
}

/** A left-to-right graph from paths that all pass through `focus`: one column per step, one arrow per grant
 *  ("is granted to" runs left to right). A path's leading user (in `users`) is not drawn: it counts as
 *  "N users" on the role the user holds. Columns over CAP boxes show "+N more", which opens them. */
const W = 196, H = 30, GAP = 56, ROW = 40, TOP = 26, CAP = 14;
// Users drawn on the left of a role or object graph: a few per role, so the reader sees who; the table lists all.
const USERS_PER_ROLE = 2, USERS_DRAWN = 12;

function RoleGraph({ paths, focus, users, objects, onPick, laneName }: {
  paths: string[][]; focus: string; users: Set<string>; objects: Set<string>; onPick: (kind: Kind, name: string) => void;
  laneName: (lane: number) => string;
}) {
  const [open, setOpen] = React.useState<Set<number>>(new Set());
  const [hover, setHover] = React.useState<string | null>(null);
  const g = React.useMemo(() => {
    const lane = new Map<string, number>(), held = new Map<string, Set<string>>(), edges = new Map<string, [string, string]>();
    const heldBy: [string, string][] = [];
    paths.forEach((p0) => {
      let p = p0;
      if (p.length > 1 && p[0] !== focus && users.has(p[0])) {
        if (!held.has(p[1])) held.set(p[1], new Set());
        held.get(p[1])!.add(p[0]);
        heldBy.push([p[0], p[1]]);
        p = p.slice(1);
      }
      const f = p.indexOf(focus);
      if (f < 0) return;
      p.forEach((x, i) => {
        const l = i - f, cur = lane.get(x);
        if (cur === undefined || Math.abs(l) < Math.abs(cur)) lane.set(x, l);
        if (i) edges.set(`${p[i - 1]}>${x}`, [p[i - 1], x]);
      });
    });
    // A few users, in one first column before the highest role, each with an arrow to the role it holds.
    const drawn = new Set<string>(), perRole = new Map<string, number>();
    heldBy.forEach(([u, r]) => {
      if (!lane.has(r) || (perRole.get(r) || 0) >= USERS_PER_ROLE || (drawn.size >= USERS_DRAWN && !drawn.has(u))) return;
      drawn.add(u);
      perRole.set(r, (perRole.get(r) || 0) + 1);
      edges.set(`${u}>${r}`, [u, r]);
    });
    if (drawn.size) {
      const first = Math.min(0, ...lane.values()) - 1;
      drawn.forEach((u) => lane.set(u, first));
    }
    // Tables and views the paths end at sit together in one last column, after the deepest role.
    const ends = [...lane.keys()].filter((x) => objects.has(x) && x !== focus);
    if (ends.length) {
      const last = Math.max(0, ...[...lane.entries()].filter(([k]) => !objects.has(k)).map(([, v]) => v)) + 1;
      ends.forEach((x) => lane.set(x, last));
    }
    const lanes = [...new Set(lane.values())].sort((a, b) => a - b);
    const cols = lanes.map((l) => [...lane.entries()].filter(([, v]) => v === l).map(([k]) => k).sort());
    // Order each column by where its parents sit, so arrows cross as little as possible.
    const pos = new Map<string, number>();
    cols.forEach((c) => c.forEach((x, i) => pos.set(x, i)));
    const all = [...edges.values()];
    for (let pass = 0; pass < 2; pass++) {
      cols.forEach((c, ci) => {
        if (!ci) return;
        const bary = (x: string) => {
          const ps = all.filter(([a, b]) => b === x && lane.get(a)! < lane.get(x)!).map(([a]) => pos.get(a)!);
          return ps.length ? ps.reduce((s, v) => s + v, 0) / ps.length : Infinity;
        };
        c.sort((a, b) => bary(a) - bary(b) || a.localeCompare(b));
        c.forEach((x, i) => pos.set(x, i));
      });
    }
    return { lane, lanes, cols, held, edges: all };
  }, [paths, focus, users, objects]);

  const xy = new Map<string, [number, number]>();
  const shown = g.cols.map((c, ci) => (open.has(ci) || c.length <= CAP ? c : c.slice(0, CAP)));
  shown.forEach((c, ci) => c.forEach((x, i) => xy.set(x, [ci * (W + GAP), TOP + i * ROW])));
  const rows = Math.max(1, ...shown.map((c, ci) => c.length + (g.cols[ci].length > CAP ? 1 : 0)));
  const width = Math.max(W, g.cols.length * (W + GAP) - GAP), height = TOP + rows * ROW;
  const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
  return (
    <div className="ax-graph-box">
      <svg className="ax-graph" width={width} height={height} viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`Role graph around ${focus}`}>
        <defs>
          <marker id="ax-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" className="ax-arrow" /></marker>
          <marker id="ax-arrow-on" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" className="ax-arrow on" /></marker>
        </defs>
        {g.lanes.map((l, ci) => <text key={l} className="ax-lane-label" x={ci * (W + GAP)} y={12}>
          {g.cols[ci].some((x) => objects.has(x) && x !== focus) ? "Tables" : g.cols[ci].every((x) => users.has(x) && x !== focus) ? "Users" : laneName(l)}</text>)}
        {g.edges.map(([a, b]) => {
          const pa = xy.get(a), pb = xy.get(b);
          if (!pa || !pb) return null;
          const fwd = g.lane.get(b)! > g.lane.get(a)!;
          const x1 = pa[0] + W, y1 = pa[1] + H / 2, x2 = pb[0], y2 = pb[1] + H / 2;
          // A role also reached by a shorter path sits in an earlier column: that arrow runs back, dashed.
          const d = fwd ? `M${x1},${y1} C${x1 + GAP / 2},${y1} ${x2 - GAP / 2},${y2} ${x2 - 2},${y2}`
            : `M${pa[0] + W / 2},${pa[1] + H} C${pa[0] + W / 2},${pa[1] + H + 40} ${x2 - 40},${y2} ${x2 - 2},${y2}`;
          const on = hover !== null && (a === hover || b === hover);
          return <path key={`${a}>${b}`} d={d} className={`ax-edge${fwd ? "" : " back"}${on ? " on" : ""}`} markerEnd={`url(#${on ? "ax-arrow-on" : "ax-arrow"})`} />;
        })}
        {[...xy.entries()].map(([x, [px, py]]) => {
          const isFocus = x === focus;
          const n = g.held.get(x)?.size || 0;
          const kind: Kind | null = isFocus ? null : users.has(x) ? "user" : objects.has(x) ? "object" : g.lane.get(x)! !== 0 ? "role" : null;
          return (
            <g key={x} className={`ax-gnode${isFocus ? " focus" : ""}${ADMIN.has(x) ? " admin" : ""}${kind ? " link" : ""}${kind === "object" ? " obj" : ""}`}
              transform={`translate(${px},${py})`} onMouseEnter={() => setHover(x)} onMouseLeave={() => setHover(null)}
              onClick={kind ? () => onPick(kind, x) : undefined}>
              <title>{`${x}${n ? ` · granted directly to ${plural(n, "user")}` : ""}${ADMIN.has(x) ? " · admin role" : ""}`}</title>
              <rect width={W} height={H} rx={users.has(x) ? H / 2 : 6} />
              <text x={10} y={H / 2 + 4}>{clip(kind === "object" ? x.split(".").pop() || x : x, n ? 18 : 26)}</text>
              {n > 0 && <text className="ax-badge" x={W - 8} y={H / 2 + 4} textAnchor="end">{`${fmtInt(n)} ${n === 1 ? "user" : "users"}`}</text>}
            </g>
          );
        })}
        {g.cols.map((c, ci) => (c.length > CAP ? (
          <g key={`more-${ci}`} className="ax-gnode link more" transform={`translate(${ci * (W + GAP)},${TOP + shown[ci].length * ROW})`}
            onClick={() => setOpen((s) => { const o = new Set(s); if (o.has(ci)) o.delete(ci); else o.add(ci); return o; })}>
            <rect width={W} height={H} rx={6} />
            <text x={10} y={H / 2 + 4}>{open.has(ci) ? "Show fewer" : `+${fmtInt(c.length - CAP)} more`}</text>
          </g>
        ) : null))}
      </svg>
    </div>
  );
}

const grantKey = (r: any) => `${r.privilege}|${r.granted_on}|${r.object}`;
const holderKey = (r: any) => `${r.kind}|${r.name}|${r.privilege || ""}`;
// Object types drawn as the graph's last column: the data a user ends up reading or changing.
const DATA_KINDS = new Set(["TABLE", "VIEW", "MATERIALIZED_VIEW", "MATERIALIZED VIEW", "DYNAMIC_TABLE", "EXTERNAL_TABLE", "ICEBERG_TABLE", "EVENT_TABLE"]);
const TOP_TABLES = 10;

/** Text, class and privilege filters over the rows: "can X do P on Y?". */
function useFilter(rows: any[]) {
  const [text, setText] = React.useState("");
  const [cls, setCls] = React.useState("");
  const t = text.trim().toUpperCase();
  const shown = rows.filter((r) => (!cls || r.cls === cls) && (!t || String(r.object ?? r.name ?? "").toUpperCase().includes(t)
    || String(r.privilege || "").toUpperCase().includes(t)));
  const bar = (
    <div className="ax-filter">
      <input className="ax-input" placeholder="Filter by name or privilege" value={text} onChange={(e) => setText(e.target.value)} aria-label="Filter" />
      <div className="cx-seg" role="group" aria-label="Privilege kind">
        {["", "read", "write", "own", "use"].map((c) => (
          <button key={c || "all"} type="button" className={cls === c ? "on" : ""} aria-pressed={cls === c} onClick={() => setCls(c)}>{c ? CLS_WORD[c] : "All"}</button>
        ))}
      </div>
    </div>
  );
  return { shown, bar };
}

function GrantsTable({ rows, onPick, onRow, selKey }: {
  rows: any[]; onPick: (kind: Kind, name: string) => void; onRow: (r: any) => void; selKey: string | null;
}) {
  const { shown, bar } = useFilter(rows);
  return (
    <div>
      {bar}
      <CxTable ariaLabel="Privileges and their paths" n={25}
        cols={[{ label: "Privilege" }, { label: "Object" }, { label: "Type" }, { label: "Path", width: "45%" }]}
        foot={`${plural(shown.length, "privilege")}${shown.length < rows.length ? ` of ${fmtInt(rows.length)}` : ""} · red = an admin role or ownership, amber = can change data.`}
        rows={shown.map((r) => ({
          key: grantKey(r), status: r.admin ? "CRITICAL" : undefined, on: grantKey(r) === selKey, onClick: () => onRow(r),
          cells: [<CxChip status={CLS_STATUS[r.cls]}>{r.privilege}</CxChip>,
            r.granted_on !== "ACCOUNT" ? <button type="button" className="ax-namebtn" onClick={(e) => { e.stopPropagation(); onPick("object", r.object); }}>{r.object}</button>
              : <code className="ax-obj">{r.object}</code>,
            String(r.granted_on || "").replace(/_/g, " ").toLowerCase(), <Paths paths={r.paths} count={r.path_count} onPick={onPick} />],
        }))} />
    </div>
  );
}

function HoldersTable({ rows, onPick, withPriv, onRow, selKey }: {
  rows: any[]; onPick: (kind: Kind, name: string) => void; withPriv: boolean; onRow: (r: any) => void; selKey: string | null;
}) {
  const { shown, bar } = useFilter(withPriv ? rows : rows.map((r) => ({ ...r, cls: "" })));
  return (
    <div>
      {withPriv && bar}
      <CxTable ariaLabel="Who holds it" n={25}
        cols={[{ label: "Who" }, ...(withPriv ? [{ label: "Privilege" }] : []), { label: "Last sign-in", num: true }, { label: "Path", width: "50%" }]}
        foot={`${plural(shown.filter((r) => r.kind === "user").length, "user")} and ${plural(shown.filter((r) => r.kind === "role").length, "role")}.`}
        rows={shown.map((r) => ({
          key: holderKey(r), status: r.admin ? "CRITICAL" : r.is_disabled ? "WARN" : undefined, on: holderKey(r) === selKey, onClick: () => onRow(r),
          cells: [
            <span><button type="button" className={`ax-namebtn${r.kind === "user" ? " user" : ""}`} onClick={(e) => { e.stopPropagation(); onPick(r.kind, r.name); }}>{r.name}</button>{r.kind === "user" && r.is_disabled ? <> <CxChip status="WARN">disabled</CxChip></> : null}{r.kind === "user" && r.user_type && r.user_type !== "PERSON" ? <> <CxChip>{String(r.user_type).toLowerCase()}</CxChip></> : null}</span>,
            ...(withPriv ? [<CxChip status={CLS_STATUS[r.cls]}>{r.privilege}</CxChip>] : []),
            r.kind === "user" ? lastDay(r.last_success_login) : "–",
            <Paths paths={r.paths} count={r.path_count} onPick={onPick} />],
        }))} />
    </div>
  );
}

/** A name box with suggestions from the export's users, roles or objects. */
function NamePicker({ kind, names, value, onPick }: { kind: Kind; names: any; value: string; onPick: (n: string) => void }) {
  const [text, setText] = React.useState(value);
  React.useEffect(() => setText(value), [value, kind]);
  const list: string[] = names ? (kind === "user" ? names.users : kind === "role" ? names.roles : names.objects).map((x: any) => x.name) : [];
  const t = text.trim().toUpperCase();
  const hits = t ? list.filter((n) => n.toUpperCase().includes(t)).slice(0, 12) : [];
  const exact = list.find((n) => n.toUpperCase() === t);
  return (
    <div className="ax-pick">
      <input className="ax-input wide" value={text} placeholder={`Type a ${kind} name`} aria-label={`${kind} name`}
        onChange={(e) => setText(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter" && (exact || hits[0])) onPick(exact || hits[0]); }} />
      {t && !exact && hits.length > 0 && (
        <div className="cx-pick-list" role="listbox" aria-label={`${kind} names`}>
          {hits.map((n) => <button key={n} type="button" onClick={() => onPick(n)}>{n}</button>)}
        </div>
      )}
      {t && !exact && !hits.length && <span className="cx-muted">{`No ${kind} by that name.`}</span>}
    </div>
  );
}

export function ApAccessExplorer(p: ApPageProps) {
  const [names, setNames] = React.useState<any>(null);
  const [err, setErr] = React.useState<string | null>(null);
  const [sel, setSel] = React.useState<{ kind: Kind; name: string }>(() => START || { kind: "user", name: "" });
  const [res, setRes] = React.useState<any>(null);
  const [loading, setLoading] = React.useState(false);
  const acct = p.filters.accountIds && p.filters.accountIds.length === 1 ? p.filters.accountIds[0] : undefined;

  React.useEffect(() => {
    getJson("/api/access/names", acct ? { account_id: acct } : undefined)
      .then((d) => { setNames(d); setErr(null); setSel((s) => (s.name ? s : { kind: "user", name: (d.users.find((u: any) => !u.is_disabled && u.roles > 1) || d.users[0] || {}).name || "" })); })
      .catch((e) => setErr(String(e.message || e)));
  }, [acct]);
  React.useEffect(() => {
    if (!sel.name) return;
    setLoading(true);
    getJson("/api/access/explore", { kind: sel.kind, name: sel.name, ...(acct ? { account_id: acct } : {}) })
      .then((d) => { setRes(d); setErr(null); }).catch((e) => { setRes(null); setErr(String(e.message || e)); })
      .finally(() => setLoading(false));
  }, [sel.kind, sel.name, acct]);

  const pick = (kind: Kind, name: string) => { setSel({ kind, name }); window.scrollTo({ top: 0, behavior: "smooth" }); };
  // A row picked in a table: the graph shows only its paths.
  const [focusRow, setFocusRow] = React.useState<{ key: string; label: string; paths: string[][]; count: number } | null>(null);
  React.useEffect(() => setFocusRow(null), [sel.kind, sel.name]);
  const showRow = (key: string, label: string, r: any) => {
    setFocusRow((f) => (f && f.key === key ? null : { key, label, paths: r.paths, count: r.path_count }));
    document.getElementById("ax-graph")?.scrollIntoView({ behavior: "smooth", block: "start" });
  };
  const grants: any[] = (res && res.grants) || [];
  const roles: any[] = (res && res.roles) || [];
  const holders: any[] = (res && res.holders) || [];
  const users = holders.filter((h) => h.kind === "user");
  const adminGrants = grants.filter((g) => g.admin).length;
  const deepest = Math.max(0, ...roles.map((r) => r.depth));
  const objects = new Set(grants.map((g) => g.object)).size;
  // The graph: a user's or role's paths down its roles, a role's holders above it, an object's roles before it.
  // The most used tables it can reach end the graph (by queries in the window, else by name); the rest stay in the table.
  const topTables = React.useMemo(() => {
    if (!res || res.kind === "object") return [] as any[];
    const best = new Map<string, any>();
    (res.grants || []).filter((r: any) => DATA_KINDS.has(r.granted_on)).forEach((r: any) => {
      const cur = best.get(r.object);
      if (!cur || r.paths[0].length < cur.paths[0].length) best.set(r.object, r);
    });
    return [...best.values()].sort((a, b) => (b.queries || 0) - (a.queries || 0) || a.object.localeCompare(b.object)).slice(0, TOP_TABLES);
  }, [res]);
  const graphPaths: string[][] = React.useMemo(() => (!res ? [] : focusRow ? focusRow.paths : [
    ...(res.roles || []).flatMap((r: any) => r.paths), ...(res.holders || []).flatMap((h: any) => h.paths),
    ...topTables.flatMap((r: any) => r.paths.slice(0, 2))]), [res, focusRow, topTables]);
  const graphObjects = React.useMemo(() => new Set<string>([
    ...topTables.map((r: any) => r.object), ...(focusRow ? focusRow.paths.map((p) => p[p.length - 1]) : [])].filter((x) => res && x !== res.name)), [topTables, focusRow, res]);
  const userNames = React.useMemo(() => new Set<string>([...(res && res.kind === "user" ? [res.name] : []),
    ...((res && res.holders) || []).filter((h: any) => h.kind === "user").map((h: any) => h.name)]), [res]);
  const laneName = (l: number) => (l === 0 ? (sel.kind === "user" ? "User" : sel.kind === "role" ? "This role" : "This object")
    : l > 0 ? (l === 1 ? (sel.kind === "user" ? "Granted" : "Inherits") : `${l} steps down`)
    : l === -1 ? (sel.kind === "object" ? "Granted on it" : "Granted to") : `${-l} steps up`);

  useLede(p, !names && !err, names ? `${plural(names.users.length, "user")}, ${plural(names.roles.length, "role")} and ${plural(names.objects.length, "object")} with grants. Pick one to see every path from a user to an object.` : null);

  const tiles = res && sel.kind !== "object" ? (
    <SummaryTileRow compact>
      <IssueTile label="Privileges it can use" headline={fmtInt(grants.length)} unit={` on ${plural(objects, "object")}`} status="neutral"
        base={`${fmtInt(grants.filter((g) => g.direct).length)} held directly, the rest through roles`} />
      <IssueTile label="Roles it can use" headline={fmtInt(roles.filter((r) => r.depth > 0).length)} unit=" roles" status="neutral"
        base={deepest ? `Deepest chain: ${plural(deepest, "role")}` : "No roles"} />
      <IssueTile label="Through an admin role" headline={fmtInt(adminGrants)} unit={` of ${plural(grants.length, "privilege")}`}
        status={adminGrants ? "critical" : "ok"} base={adminGrants ? "Reached through ACCOUNTADMIN, SECURITYADMIN, SYSADMIN or USERADMIN" : "No path goes through an admin role"} />
      <IssueTile label="Can change data" headline={fmtInt(grants.filter((g) => g.cls === "write" || g.cls === "own").length)} unit=" privileges" status="neutral"
        base={`Write or own; ${fmtInt(grants.filter((g) => g.cls === "read").length)} read only`} />
    </SummaryTileRow>
  ) : res && sel.kind === "object" ? (
    <SummaryTileRow compact>
      <IssueTile label="Users who can use it" headline={fmtInt(new Set(users.map((u) => u.name)).size)} unit=" users" status="neutral"
        base={`${fmtInt(new Set(users.filter((u) => u.cls === "write" || u.cls === "own").map((u) => u.name)).size)} can change or own it`} />
      <IssueTile label="Disabled users with a path" headline={fmtInt(new Set(users.filter((u) => u.is_disabled).map((u) => u.name)).size)} unit=" users"
        status={users.some((u) => u.is_disabled) ? "warn" : "ok"} base="Enabling them again brings this access back" />
      <IssueTile label="Roles with a grant" headline={fmtInt(new Set(holders.filter((h) => h.kind === "role").map((h) => h.name)).size)} unit=" roles" status="neutral"
        base={`Directly or through roles they inherit`} />
      <IssueTile label="Through an admin role" headline={fmtInt(new Set(users.filter((u) => u.admin).map((u) => u.name)).size)} unit=" users"
        status={users.some((u) => u.admin) ? "critical" : "ok"} base="Users whose path goes through an admin role" />
    </SummaryTileRow>
  ) : null;

  return (
    <div className="ais-page cx-e">
      <div className="ax-bar">
        <div className="cx-seg" role="group" aria-label="Explore by">
          {KINDS.map(([k, label]) => (
            <button key={k} type="button" className={sel.kind === k ? "on" : ""} aria-pressed={sel.kind === k}
              onClick={() => setSel({ kind: k, name: k === sel.kind ? sel.name : "" })}>{label}</button>
          ))}
        </div>
        <NamePicker kind={sel.kind} names={names} value={sel.name} onPick={(n) => setSel({ kind: sel.kind, name: n })} />
        {loading && <span className="cx-muted">…</span>}
      </div>
      {err && <CxStat>{`– ${err}`}</CxStat>}
      {res && sel.kind === "user" && res.user && (
        <div className="ax-who">{<span><b>{res.name}</b>{` · ${String(res.user.user_type || "PERSON").toLowerCase()}${res.user.is_disabled ? " · disabled" : ""} · default role ${res.user.default_role || "none"} · last sign-in ${lastDay(res.user.last_success_login)}`}</span>}</div>
      )}
      {tiles}
      {res && graphPaths.length > 0 && (
        <div id="ax-graph">
          <ChartCard title={focusRow ? `How ${focusRow.label}` : sel.kind === "user" ? "Roles and tables it can use" : sel.kind === "role" ? "Where it sits in the role tree" : "Roles that reach it"}
            subtitle={focusRow ? `Every path for the row picked below${focusRow.count > focusRow.paths.length ? ` · the first ${fmtInt(focusRow.paths.length)} of ${fmtInt(focusRow.count)}` : ""}`
              : `Arrow = is granted to · one column per step · red = admin role${topTables.length ? ` · the ${fmtInt(topTables.length)} most used tables it can reach, the rest in the table below` : ""} · select a row below for its whole path${sel.kind !== "user" ? " · N users = users granted that role directly" : ""}`}
            takeaway={null}>
            {focusRow && <div className="ax-graph-bar"><button type="button" className="cx-linkbtn" onClick={() => setFocusRow(null)}>{"← Show the whole graph"}</button></div>}
            <RoleGraph key={focusRow ? focusRow.key : "all"} paths={graphPaths} focus={res.name} users={userNames} objects={graphObjects} onPick={pick} laneName={laneName} />
          </ChartCard>
        </div>
      )}
      {res && sel.kind !== "object" && (
        <ChartCard title={`What ${res.name} can do`} subtitle="Every privilege, with the path it comes through · select a row for its whole path in the graph, a name to explore it" takeaway={null}>
          {grants.length ? <GrantsTable rows={grants} onPick={pick} selKey={focusRow && focusRow.key}
            onRow={(r) => showRow(grantKey(r), `${res.name} gets ${r.privilege} on ${r.object}`, r)} /> : <CxStat>{"Holds no privileges on objects."}</CxStat>}
        </ChartCard>
      )}
      {res && sel.kind === "role" && (
        <ChartCard title={`Who can use ${res.name}`} subtitle="Users and roles that hold it, directly or through other roles" takeaway={null}>
          {holders.length ? <HoldersTable rows={holders} onPick={pick} withPriv={false} selKey={focusRow && focusRow.key}
            onRow={(r) => showRow(holderKey(r), `${r.name} gets ${res.name}`, r)} /> : <CxStat>{"No user or role holds it."}</CxStat>}
        </ChartCard>
      )}
      {res && sel.kind === "object" && (
        <ChartCard title={`Who can use ${res.name}`} subtitle={`${String(res.granted_on || "").replace(/_/g, " ").toLowerCase()} · every user and role with a privilege on it, and the path`} takeaway={null}>
          <HoldersTable rows={holders} onPick={pick} withPriv selKey={focusRow && focusRow.key}
            onRow={(r) => showRow(holderKey(r), `${r.name} gets ${r.privilege} on ${res.name}`, r)} />
        </ChartCard>
      )}
    </div>
  );
}
(ApAccessExplorer as any).ownsTiles = true;
(ApAccessExplorer as any).ownsLede = true;

// ═══════════════ role-model sections, shown on the pages that home these checks ═══════════════

/** Access › Roles & grants: access roles handed to users, double grants, read-only roles that write. */
export function AccRoleModel({ p }: { p: ApPageProps }) {
  const both = useCheck(p, "sf_acc_roles_used_both_ways");
  const twice = useCheck(p, "sf_acc_redundant_role_grants");
  const ro = useCheck(p, "sf_acc_readonly_roles_write");
  return (
    <>
      <Row2>
        <Slot c={both} title="Access roles handed straight to users" subtitle="Roles that hold privileges, are built into other roles, and are also granted to users">
          {(rows) => {
            const fl = rows.filter(isFlagged);
            if (!fl.length) return <CxStat>{`None of the ${plural(rows.length, "role")} granted to users is also built into another role.`}</CxStat>;
            return <CxTable ariaLabel="Access roles granted to users" n={8}
              cols={[{ label: "Role" }, { label: "Users", num: true }, { label: "Also inside" }]}
              rows={fl.map((r) => ({ key: String(r.role_name), status: r.status, onClick: drawerBy("sf_acc_roles_used_both_ways", "role_name", r.role_name, String(r.role_name)),
                cells: [<code className="ax-obj">{String(r.role_name)}</code>, <b>{fmtInt(numOrZero(r.direct_users))}</b>, String(r.parent_roles || "")] }))} />;
          }}
        </Slot>
        <Slot c={ro} title="Read-only roles that can change data" subtitle="The name says read-only, or it reads nearly everything it holds">
          {(rows) => {
            const fl = rows.filter(isFlagged);
            if (!fl.length) return <CxStat>{`All ${plural(rows.length, "read-only role")} only read.`}</CxStat>;
            return <CxTable ariaLabel="Read-only roles that write" n={8}
              cols={[{ label: "Role" }, { label: "Why read-only" }, { label: "Can change", num: true }, { label: "Users", num: true }]}
              rows={fl.map((r) => ({ key: String(r.role_name), status: r.status, onClick: drawerBy("sf_acc_readonly_roles_write", "role_name", r.role_name, String(r.role_name)),
                cells: [<code className="ax-obj">{String(r.role_name)}</code>, r.name_says_read ? "its name" : `reads ${fmtInt(numOrZero(r.read_only_tables))} of ${fmtInt(numOrZero(r.tables))} tables`,
                  <b>{fmtInt(numOrZero(r.write_objects))}</b>, fmtInt(numOrZero(r.users))] }))} />;
          }}
        </Slot>
      </Row2>
      <Slot c={twice} title="Roles granted twice" subtitle="A direct grant the user or role already gets through another role · it keeps the access when that role is taken away">
        {(rows) => (
          <CxTable ariaLabel="Roles granted twice" n={8}
            cols={[{ label: "Granted to" }, { label: "Role" }, { label: "Also through" }, { label: "Path", width: "40%" }]}
            foot={`${plural(rows.filter((r) => r.grantee_kind === "USER").length, "grant")} to users, ${plural(rows.filter((r) => r.grantee_kind === "ROLE").length, "grant")} to roles.`}
            rows={rows.map((r) => ({ key: `${r.grantee_kind}|${r.grantee}|${r.granted_role}`, status: r.status,
              onClick: drawerBy("sf_acc_redundant_role_grants", "grantee", r.grantee, String(r.grantee)),
              cells: [r.grantee_kind === "USER" ? <b>{String(r.grantee)}</b> : <code className="ax-obj">{String(r.grantee)}</code>, <code className="ax-obj">{String(r.granted_role)}</code>,
                String(r.through_roles || ""), <PathLine path={String(r.example_path || "").split(" > ")} />] }))} />
        )}
      </Slot>
    </>
  );
}

/** Access › Users & sign-ins: disabled users that still hold roles. */
export function AccDisabledUsers({ p }: { p: ApPageProps }) {
  const c = useCheck(p, "sf_acc_disabled_users_roles");
  return (
    <Slot c={c} title="Disabled users that still hold roles" subtitle="Enabling one again brings all of its access back at once · red = can reach an admin role">
      {(rows) => {
        const fl = rows.filter(isFlagged);
        if (!fl.length) return <CxStat>{`None of the ${plural(rows.length, "disabled user")} holds a role.`}</CxStat>;
        return <CxTable ariaLabel="Disabled users with roles" n={10}
          cols={[{ label: "User" }, { label: "Roles held" }, { label: "Admin role" }, { label: "Last sign-in", num: true }]}
          foot={`${fmtInt(fl.length)} of ${plural(rows.length, "disabled user")} still hold roles.`}
          rows={fl.map((r) => ({ key: String(r.user_name), status: r.status, onClick: drawerBy("sf_acc_disabled_users_roles", "user_name", r.user_name, String(r.user_name)),
            cells: [<b>{String(r.user_name)}</b>, String(r.role_list || ""), r.admin_roles ? <CxChip status="CRITICAL">{String(r.admin_roles)}</CxChip> : <span className="cx-muted">None</span>,
              lastDay(r.last_success_login)] }))} />;
      }}
    </Slot>
  );
}

/** PII › Who reads it: who can read or change each table with sensitive columns. */
export function AccSensitiveReach({ p }: { p: ApPageProps }) {
  const c = useCheck(p, "sf_acc_sensitive_reach");
  return (
    <Slot c={c} title="Who can read each sensitive table" subtitle="Users with a grant path, not who did read it · idle = dormant or disabled · red = idle readers and unmasked columns">
      {(rows) => (
        <CxTable ariaLabel="Who can read sensitive tables" n={10}
          cols={[{ label: "Table" }, { label: "Masked", num: true }, { label: "Can read", num: true }, { label: "Idle readers", num: true }, { label: "People who can change it", num: true }]}
          foot={`${fmtInt(rows.filter(isFlagged).length)} of ${plural(rows.length, "sensitive table")} flagged.`}
          rows={rows.map((r) => ({ key: String(r.table_fqn), status: r.status, onClick: drawerBy("sf_acc_sensitive_reach", "table_fqn", r.table_fqn, String(r.table_fqn)),
            cells: [<code className="ax-obj">{String(r.table_fqn)}</code>, `${fmtInt(numOrZero(r.masked_columns))} of ${fmtInt(numOrZero(r.sensitive_columns))}`,
              fmtInt(numOrZero(r.readers)), numOrZero(r.dormant_readers) + numOrZero(r.disabled_readers) ? <b>{fmtInt(numOrZero(r.dormant_readers) + numOrZero(r.disabled_readers))}</b> : "–",
              numOrZero(r.people_writers) ? <b>{fmtInt(numOrZero(r.people_writers))}</b> : "–"] }))} />
      )}
    </Slot>
  );
}
