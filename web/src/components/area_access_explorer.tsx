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

/** Roles a user or role can use, one column per depth: the role tree in lanes. */
function Lanes({ roles, onPick, user }: { roles: any[]; onPick: (kind: Kind, name: string) => void; user: boolean }) {
  const byDepth = new Map<number, any[]>();
  roles.filter((r) => r.depth > 0).forEach((r) => byDepth.set(r.depth, [...(byDepth.get(r.depth) || []), r]));
  const depths = [...byDepth.keys()].sort((a, b) => a - b);
  if (!depths.length) return null;
  return (
    <div className="ax-lanes">
      {depths.map((d) => (
        <div key={d} className="ax-lane">
          <div className="ax-lane-head">{d === 1 ? (user ? "Granted" : "Inherits") : `${d} steps down`}</div>
          {byDepth.get(d)!.map((r) => (
            <button key={r.role} type="button" className={`ax-node${r.admin ? " admin" : ""}`} onClick={() => onPick("role", r.role)}
              title={r.paths[0].join(" › ")}>{r.role}</button>
          ))}
        </div>
      ))}
    </div>
  );
}

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

function GrantsTable({ rows, onPick }: { rows: any[]; onPick: (kind: Kind, name: string) => void }) {
  const { shown, bar } = useFilter(rows);
  return (
    <div>
      {bar}
      <CxTable ariaLabel="Privileges and their paths" n={25}
        cols={[{ label: "Privilege" }, { label: "Object" }, { label: "Type" }, { label: "Path", width: "45%" }]}
        foot={`${plural(shown.length, "privilege")}${shown.length < rows.length ? ` of ${fmtInt(rows.length)}` : ""} · red = an admin role or ownership, amber = can change data.`}
        rows={shown.map((r) => ({
          key: `${r.privilege}|${r.granted_on}|${r.object}`, status: r.admin ? "CRITICAL" : undefined,
          onClick: r.granted_on !== "ACCOUNT" ? () => onPick("object", r.object) : null,
          cells: [<CxChip status={CLS_STATUS[r.cls]}>{r.privilege}</CxChip>, <code className="ax-obj">{r.object}</code>,
            String(r.granted_on || "").replace(/_/g, " ").toLowerCase(), <Paths paths={r.paths} count={r.path_count} onPick={onPick} />],
        }))} />
    </div>
  );
}

function HoldersTable({ rows, onPick, withPriv }: { rows: any[]; onPick: (kind: Kind, name: string) => void; withPriv: boolean }) {
  const { shown, bar } = useFilter(withPriv ? rows : rows.map((r) => ({ ...r, cls: "" })));
  return (
    <div>
      {withPriv && bar}
      <CxTable ariaLabel="Who holds it" n={25}
        cols={[{ label: "Who" }, ...(withPriv ? [{ label: "Privilege" }] : []), { label: "Last sign-in", num: true }, { label: "Path", width: "50%" }]}
        foot={`${plural(shown.filter((r) => r.kind === "user").length, "user")} and ${plural(shown.filter((r) => r.kind === "role").length, "role")}.`}
        rows={shown.map((r) => ({
          key: `${r.kind}|${r.name}|${r.privilege || ""}`, status: r.admin ? "CRITICAL" : r.is_disabled ? "WARN" : undefined,
          onClick: () => onPick(r.kind, r.name),
          cells: [
            <span>{r.kind === "user" ? <b>{r.name}</b> : <code className="ax-obj">{r.name}</code>}{r.kind === "user" && r.is_disabled ? <> <CxChip status="WARN">disabled</CxChip></> : null}{r.kind === "user" && r.user_type && r.user_type !== "PERSON" ? <> <CxChip>{String(r.user_type).toLowerCase()}</CxChip></> : null}</span>,
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
  const grants: any[] = (res && res.grants) || [];
  const roles: any[] = (res && res.roles) || [];
  const holders: any[] = (res && res.holders) || [];
  const users = holders.filter((h) => h.kind === "user");
  const adminGrants = grants.filter((g) => g.admin).length;
  const deepest = Math.max(0, ...roles.map((r) => r.depth));
  const objects = new Set(grants.map((g) => g.object)).size;

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
      {res && sel.kind !== "object" && roles.some((r) => r.depth > 0) && (
        <ChartCard title="Roles it can use" subtitle="One column per step down the role tree · red = admin role · select a role to explore it" takeaway={null}>
          <Lanes roles={roles} onPick={pick} user={sel.kind === "user"} />
        </ChartCard>
      )}
      {res && sel.kind !== "object" && (
        <ChartCard title={`What ${res.name} can do`} subtitle="Every privilege, with the path it comes through · select a row to see who else can use that object" takeaway={null}>
          {grants.length ? <GrantsTable rows={grants} onPick={pick} /> : <CxStat>{"Holds no privileges on objects."}</CxStat>}
        </ChartCard>
      )}
      {res && sel.kind === "role" && (
        <ChartCard title={`Who can use ${res.name}`} subtitle="Users and roles that hold it, directly or through other roles" takeaway={null}>
          {holders.length ? <HoldersTable rows={holders} onPick={pick} withPriv={false} /> : <CxStat>{"No user or role holds it."}</CxStat>}
        </ChartCard>
      )}
      {res && sel.kind === "object" && (
        <ChartCard title={`Who can use ${res.name}`} subtitle={`${String(res.granted_on || "").replace(/_/g, " ").toLowerCase()} · every user and role with a privilege on it, and the path`} takeaway={null}>
          <HoldersTable rows={holders} onPick={pick} withPriv />
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
