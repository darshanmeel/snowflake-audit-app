// web/src/components/access_log_page.tsx -- Activity › Access log: a left panel with three sections
// (Overview, One object, One person) and a UTC-offset slider that recounts off-hours use in place. Hours
// are stored in UTC; the slider is a what-if, the check's status uses the offset in config/thresholds.yml.
import React from "react";
import "../styles/css/p_access_log.css";
import { fmtDayShort, fmtInt } from "../format";
import { numOrZero } from "./hooks";
import type { ApPageProps } from "./area_pages";
import { Columns } from "./charts_more";
import { useAggCheck, useLede } from "./area_ai_storage";
import { CxStat, CxTable } from "./cx_e";
import { useJson } from "./use_json";
import type { Row } from "../types";

type Section = "overview" | "object" | "person";
const plural = (n: number, one: string) => `${fmtInt(n)} ${n === 1 ? one : `${one}s`}`;
const day = (v: any) => (v ? fmtDayShort(String(v).slice(0, 10)) : "–");
const utc = (o: number) => `UTC${o >= 0 ? "+" : "−"}${Math.abs(o)}`;
const hh = (h: number) => `${String(h).padStart(2, "0")}:00`;
const pct = (a: number, b: number) => (b ? Math.round((100 * a) / b) : 0);
const few = (list: any, n = 3) => { const a = String(list || "").split(", ").filter(Boolean); return a.length > n ? `${a.slice(0, n).join(", ")} +${a.length - n}` : a.join(", "); };
const sqlLit = (s: string) => `'${s.replace(/'/g, "''")}'`;
const WRITES = new Set(["INSERT", "UPDATE", "DELETE", "MERGE", "COPY", "CREATE_TABLE_AS_SELECT", "TRUNCATE_TABLE", "UNLOAD", "MULTI_TABLE_INSERT"]);

let start: { section: Section; object: string } = { section: "overview", object: "" };
/** Open the Access log on one object, from another page (the page mounts fresh on navigation). */
export function openInAccessLog(p: ApPageProps, name: string) {
  start = { section: "object", object: name };
  p.goTo({ tab: "accesslog", subtab: "log", focusQueryId: null });
}

const kindOf = (k: string) => k || undefined;
const prefixOf = (p: string) => p || undefined;

/** Every day from start to end, so quiet days read as zero rather than vanish. */
function allDays(s: string, e: string): string[] {
  const out: string[] = [];
  for (let t = Date.parse(`${s}T00:00:00Z`); t < Date.parse(`${e}T00:00:00Z`); t += 864e5) out.push(new Date(t).toISOString().slice(0, 10));
  return out;
}

/** A chart card with its own controls on the right of the head. */
function Card({ title, sub, right, children }: { title: React.ReactNode; sub?: React.ReactNode; right?: React.ReactNode; children?: React.ReactNode }) {
  return (
    <div className="chart-card-v2">
      <div className="chart-card-v2-head">
        <div className="chart-card-v2-titles"><div className="chart-card-v2-title">{title}</div>{sub && <div className="chart-card-v2-subtitle">{sub}</div>}</div>
        {right && <div className="al-head-right">{right}</div>}
      </div>
      {children}
    </div>
  );
}

function Tile({ l, v, s, mono, warn }: { l: string; v: React.ReactNode; s?: React.ReactNode; mono?: boolean; warn?: boolean }) {
  return <div className={`al-tile${warn ? " warn" : ""}`}><div className="l">{l}</div><div className={`v${mono ? " mono" : ""}`}>{v}</div>{s && <div className="s">{s}</div>}</div>;
}

function Seg({ value, options, onPick, label }: { value: string; options: [string, string][]; onPick: (v: string) => void; label: string }) {
  return (
    <div className="cx-seg" role="group" aria-label={label}>
      {options.map(([k, t]) => <button key={k} type="button" className={value === k ? "on" : ""} aria-pressed={value === k} onClick={() => onPick(k)}>{t}</button>)}
    </div>
  );
}

/** One object name on one line, monospace, the full name on hover. */
function Name({ fqn, sens, onClick }: { fqn: any; sens?: any; onClick?: () => void }) {
  const t = <span className="al-mono" title={String(fqn)}>{String(fqn)}</span>;
  return (
    <span className="al-name">
      {onClick ? <button type="button" className="al-link" onClick={onClick}>{t}</button> : t}
      {sens && <span className="al-chip d">{sens === "tagged" ? "sensitive" : "looks sensitive"}</span>}
    </span>
  );
}

function Chips({ list }: { list: any }) {
  const items = String(list || "").split(", ").filter(Boolean);
  if (!items.length) return <span className="al-meta">–</span>;
  return <span className="al-chips">{items.map((x) => <span key={x} className={`al-chip${WRITES.has(x) ? " w" : /^(CREATE|ALTER|DROP|RENAME)/.test(x) && !WRITES.has(x) ? " dd" : ""}`}>{x}</span>)}</span>;
}

/** Per-day stacked columns from {name, values: {day: n}} series; every day of the window is drawn. */
function dayCols(d: any) {
  const days = allDays(String(d.start), String(d.end));
  return { days, series: (d.per_day?.series || []).map((s: Row) => ({ name: s.name, id: s.name, values: days.map((x) => numOrZero(s.values[x])) })) };
}

/** 24 hourly columns in local time: on-hours blue, off-hours amber, business hours shaded. */
function HourBars({ on, off, startH, endH, max }: { on: number[]; off: number[]; startH: number; endH: number; max: number }) {
  return (
    <div className="al-hbars" aria-label="Queries by hour of day">
      {on.map((v, h) => (
        <span key={h} className={h >= startH && h < endH ? "biz" : ""} title={`${hh(h)}: ${fmtInt(v)} on, ${fmtInt(off[h])} off hours`}>
          <i className="on" style={{ height: `${(100 * v) / max}%` }} /><i className="off" style={{ height: `${(100 * off[h]) / max}%` }} />
        </span>
      ))}
    </div>
  );
}

function OnOff({ on, off }: { on: number; off: number }) {
  const t = on + off;
  return (
    <div>
      <div className="al-hbar3"><i className="w" style={{ width: `${pct(on, t)}%` }} /><i className="o" style={{ width: `${pct(off, t)}%` }} /></div>
      <div className="al-onoff"><span>{`${pct(on, t)}% on · ${fmtInt(on)}`}</span><span className="o">{`${pct(off, t)}% off · ${fmtInt(off)}`}</span></div>
    </div>
  );
}

/** Reads, writes and DDL by client, role or user, with a toggle in the head. */
function ByCard({ by, scope }: { by: any; scope: string }) {
  const [dim, setDim] = React.useState("client");
  const rows: Row[] = by?.[dim] || [];
  const max = Math.max(1, ...rows.map((r) => numOrZero(r.reads) + numOrZero(r.writes) + numOrZero(r.ddl)));
  const meta = (r: Row) => dim === "client" ? `${plural(numOrZero(r.users), "user")} · ${r.roles}`
    : dim === "role" ? `${plural(numOrZero(r.users), "user")} · ${r.clients}` : `${r.roles} · ${r.clients}`;
  return (
    <Card title={`Queries by ${dim}`} sub={`Writes, reads and DDL summed per row · ${scope} · sorted by volume`}
      right={<Seg label="Group by" value={dim} options={[["client", "Client"], ["role", "Role"], ["user", "User"]]} onPick={setDim} />}>
      {rows.slice(0, 8).map((r) => {
        const tot = numOrZero(r.reads) + numOrZero(r.writes) + numOrZero(r.ddl);
        return (
          <div key={String(r.k)} className="al-byrow">
            <span className="al-two"><b className="al-mono">{String(r.k)}</b><span className="al-meta" title={meta(r)}>{`${plural(numOrZero(r.objects), "object")} · ${meta(r)}`}</span></span>
            <span className="al-hbar3" style={{ width: `${Math.max(2, (100 * tot) / max)}%` }}>
              <i className="w" style={{ width: `${pct(numOrZero(r.writes), tot)}%` }} /><i className="r" style={{ width: `${pct(numOrZero(r.reads), tot)}%` }} /><i className="d" style={{ width: `${pct(numOrZero(r.ddl), tot)}%` }} />
            </span>
            <span className="al-num">{fmtInt(tot)}</span>
          </div>
        );
      })}
      {rows.length > 8 && <div className="al-meta">{`Top 8 of ${fmtInt(rows.length)}`}</div>}
      <div className="al-key"><span><i style={{ background: "var(--c1)" }} />Writes (DML)</span><span><i style={{ background: "var(--c2)" }} />Reads</span><span><i style={{ background: "var(--c3)" }} />DDL</span></div>
    </Card>
  );
}

function StatementsCard({ rows, scope }: { rows: Row[]; scope: string }) {
  const max = Math.max(1, ...rows.map((r) => numOrZero(r.queries)));
  return (
    <Card title="Statement kinds" sub={`Queries per statement type · ${scope}`}>
      {rows.slice(0, 12).map((r) => {
        const k = numOrZero(r.ddl) ? "d" : numOrZero(r.writes) ? "w" : "r";
        return (
          <div key={String(r.k)} className="al-strow">
            <span className={`al-dot ${k}`} />
            <span className="al-mono sm" title={String(r.k)}>{String(r.k)}</span>
            <span className="al-bar"><i className={k} style={{ width: `${(100 * numOrZero(r.queries)) / max}%` }} /></span>
            <span className="al-num">{fmtInt(numOrZero(r.queries))}</span>
            <span className="al-meta al-r">{`${fmtInt(numOrZero(r.objects))} obj · ${fmtInt(numOrZero(r.combos))} combos`}</span>
          </div>
        );
      })}
      {rows.length > 12 && <div className="al-meta">{`Top 12 of ${fmtInt(rows.length)} statement types`}</div>}
      <div className="al-key"><span><i style={{ background: "var(--c1)" }} />Write</span><span><i style={{ background: "var(--c2)" }} />Read</span><span><i style={{ background: "var(--c3)" }} />DDL</span></div>
    </Card>
  );
}

export function ApActivityAccessLog(p: ApPageProps) {
  const c = useAggCheck(p, "sf_use_access_log", [], "read_queries", []);
  const ran = !c.loading && !c.why;
  const [section, setSection] = React.useState<Section>(() => start.section);
  const [object, setObject] = React.useState(() => { const o = start.object; start = { section: "overview", object: "" }; return o; });
  const [person, setPerson] = React.useState("");
  const [otype, setOtype] = React.useState("");
  const [app, setApp] = React.useState("");
  const cfg = useJson(ran ? "/api/access/settings" : null, {});
  const [offset, setOffset] = React.useState<number | null>(null);
  const off = offset ?? cfg.data?.offset ?? 0;
  // go("object", name) opens an object; go("object", app, "streamlit") an app; go("person", user) a user
  const go = (s: Section, name?: string, kind?: string) => {
    if (s === "object" && name && kind === "streamlit") { setOtype("streamlit"); setApp(name); }
    else if (s === "object" && name) { if (otype === "streamlit") setOtype(""); setObject(name); }
    if (s === "person" && name) setPerson(name);
    setSection(s); window.scrollTo({ top: 0 });
  };

  useLede(p, c.loading, ran ? "Who read, wrote or changed which table, view and stage, with which role and client, and when. Hours are UTC; shift them to your business time on the left." : null);
  if (!ran) return <div className="ais-page cx-e"><CxStat>{c.loading ? "…" : c.empty ? c.why : `– ${c.why}`}</CxStat></div>;
  const s = cfg.data || { offset: 0, start: 7, end: 19 };
  return (
    <div className="ais-page cx-e">
      <div className="al-wrap">
        <aside className="al-side" aria-label="Access log sections">
          <h4>Sections</h4>
          <nav className="al-nav">
            {([["overview", "Overview", "off hours, hours of use, busiest"], ["object", "One object", (otype === "streamlit" ? app : object) || "table, view, stage, procedure, app"],
              ["person", "One user or role", person || "pick a user or a role"]] as [Section, string, string][]).map(([k, t, sub]) => (
              <button key={k} type="button" className={section === k ? "on" : ""} aria-current={section === k} onClick={() => setSection(k)}>
                {t}<small>{sub}</small>
              </button>
            ))}
          </nav>
          <div className="al-tz">
            <h4>Business time</h4>
            <div className="al-tz-val">{utc(off)}</div>
            <input type="range" min={-12} max={14} step={1} value={off} aria-label="Hours ahead of UTC" onChange={(e) => setOffset(Number(e.target.value))} />
            <div className="al-tz-scale"><span>−12</span><span>0</span><span>+14</span></div>
            <p>{`${hh(s.start)}–${hh(s.end)} local, Monday to Friday. Config: ${utc(s.offset)}.`}</p>
            {off !== s.offset && <><p className="al-whatif">A what-if: the findings count off hours at {utc(s.offset)}.</p><button type="button" onClick={() => setOffset(null)}>Back to {utc(s.offset)}</button></>}
          </div>
        </aside>
        <div className="al-main">
          {section === "overview" && <Overview p={p} off={off} s={s} go={go} />}
          {section === "object" && (otype === "streamlit"
            ? <AppDetail p={p} go={go} app={app} onPick={setApp} otype={otype} setOtype={setOtype} />
            : <ObjectView p={p} off={off} name={object} onPick={setObject} go={go} otype={otype} setOtype={setOtype} />)}
          {section === "person" && <PersonView p={p} off={off} s={s} name={person} onPick={setPerson} go={go} />}
        </div>
      </div>
    </div>
  );
}
(ApActivityAccessLog as any).ownsTiles = true;
(ApActivityAccessLog as any).ownsLede = true;

// ═══════════════════════ Overview ═══════════════════════

function Overview({ p, off, s, go }: { p: ApPageProps; off: number; s: Row; go: (s: Section, n?: string) => void }) {
  const [heatKind, setHeatKind] = React.useState("sensitive");
  const [kind, setKind] = React.useState("");
  const [prefix, setPrefix] = React.useState("");
  const [level, setLevel] = React.useState("schema");
  const roll = useJson("/api/access/rollup", { window: p.filters.window, level });
  const ov = useJson("/api/access/overview", { window: p.filters.window, offset: off, heat: heatKind });
  const objs = useJson("/api/access/log/objects", { window: p.filters.window, limit: 200, kind: kindOf(kind), prefix: prefixOf(prefix) });
  const [onlySens, setOnlySens] = React.useState(false);
  const [allPeople, setAllPeople] = React.useState(false);
  const [objN, setObjN] = React.useState(10);
  if (ov.loading && !ov.data) return <CxStat>…</CxStat>;
  if (ov.err) return <CxStat>{`– ${ov.err}`}</CxStat>;
  const d = ov.data;
  if (!d) return null;
  const people: Row[] = d.off_hours || [];
  const shown = allPeople ? people : people.slice(0, 4);
  const rowsShown = shown.reduce((n, u) => n + Math.min(allPeople ? 99 : 3, u.objects.length), 0);
  const rowsAll = people.reduce((n, u) => n + u.objects.length, 0);
  const maxOff = Math.max(1, ...people.flatMap((x) => x.objects.map((o: Row) => numOrZero(o.off_hours))));
  const heatMax = Math.max(1, ...d.heat.flatMap((r: Row) => r.cells.map((v: any) => numOrZero(v))));
  const hours: Row[] = d.hours || [];
  const hMax = Math.max(1, ...hours.flatMap((u) => u.on.map((v: number, i: number) => v + u.off[i])));
  const sensBy = (u: string) => (people.find((x) => x.user_name === u)?.objects || []).filter((o: Row) => o.sensitive).length;
  const list: Row[] = (objs.data?.objects || []).filter((o: Row) => !onlySens || o.sensitive);
  const actMax = Math.max(1, ...list.map((o) => numOrZero(o.reads) + numOrZero(o.writes) + numOrZero(o.ddl)));
  return (
    <>
      {d.truncated && <CxStat>{`The export kept the newest rows only (row cap reached): counts before ${day(d.complete_from)} are incomplete.`}</CxStat>}
      <div className="al-tiles">
        <Tile l="Objects touched" v={fmtInt(d.objects)} s="tables, views & stages" />
        <Tile l="People off-hours" v={d.hours_available ? fmtInt(d.people_off_hours) : "–"} warn={d.people_off_hours > 0}
          s={d.hours_available ? `on ${plural(d.objects_off_hours, "object")} · weekends or outside business hours` : "the hours check did not run"} />
        <Tile l="Busiest object" mono v={d.busiest ? String(d.busiest.object_fqn).split(".").pop() : "–"}
          s={d.busiest ? `${fmtInt(d.busiest.queries)} queries · ${plural(d.busiest.users, "user")}` : undefined} />
        <Tile l="Queries" v={fmtInt(d.queries)} s={`reads, writes and DDL · ${plural(d.users, "user")}`} />
      </div>

      <Card title="Off-hours use by people" sub={`Queries by people outside ${hh(s.start)}–${hh(s.end)} ${utc(off)} or at weekends · service users and pipelines left out`}>
        {!d.hours_available ? <CxStat>– Not in this export: run it again with sf_use_access_hours.</CxStat> : !people.length
          ? <CxStat>{`No person used an object outside business hours in ${day(d.start)}–${day(d.end)}.`}</CxStat> : (
          <div>
            <div>
              {shown.map((u) => (
                <div key={u.user_name} className="al-person">
                  <div className="al-person-h">
                    <span className="al-av">{String(u.user_name).slice(0, 2)}</span>
                    <span><button type="button" className="al-link" onClick={() => go("person", u.user_name)}><b className="al-mono">{u.user_name}</b></button>
                      <span className="al-meta">{`${plural(u.objects.length, "object")} · last ${day(u.objects.map((o: Row) => String(o.last_day)).sort().pop())}`}</span></span>
                    <span className="al-offn"><b>{fmtInt(u.off_hours)}</b> off-hours queries</span>
                  </div>
                  {u.objects.slice(0, allPeople ? 99 : 3).map((o: Row) => (
                    <div key={o.object_fqn} className="al-orow">
                      <Name fqn={o.object_fqn} sens={o.sensitive} onClick={() => go("object", o.object_fqn)} />
                      <span className="al-bar"><i style={{ width: `${(100 * numOrZero(o.off_hours)) / maxOff}%` }} /></span>
                      <span className="al-num">{fmtInt(o.off_hours)}</span>
                      <span className="al-two"><span className="al-mono sm" title={o.statements}>{o.statements}</span><span className="al-meta" title={o.roles}>{o.roles}</span></span>
                      <span className="al-meta al-r">{day(o.last_day)}</span>
                    </div>
                  ))}
                </div>
              ))}
              <div className="al-foot"><span>{`Showing ${fmtInt(shown.length)} of ${plural(people.length, "person")} · ${fmtInt(rowsShown)} of ${plural(rowsAll, "row")}`}</span>
                {people.length > 4 || rowsShown < rowsAll ? <button type="button" className="al-link" onClick={() => setAllPeople(!allPeople)}>{allPeople ? "Show fewer" : `Show ${fmtInt(rowsAll - rowsShown)} more`}</button> : null}</div>
            </div>
          </div>
        )}
      </Card>

      {d.hours_available && (
        <Card title="Who touched what" sub="Off-hours queries · person × object · – no grant path · · none"
          right={<Seg label="Objects" value={heatKind} options={[["sensitive", "Sensitive objects"], ["all", "All objects"]]} onPick={setHeatKind} />}>
          {!d.heat_objects.length ? <CxStat>{heatKind === "sensitive" ? "No sensitive object was used off hours." : "No object was used off hours."}</CxStat> : (
            <div className="al-heatwide">
              <table className="al-heat">
                <thead><tr><th className="u">Person</th>{d.heat_objects.map((f: string) => <th key={f} title={f}><span className="al-mono sm">{f.split(".").slice(-2).join(".")}</span></th>)}<th>Total</th></tr></thead>
                <tbody>{d.heat.map((r: Row) => (
                  <tr key={r.user_name}><td className="u"><button type="button" className="al-link" onClick={() => go("person", r.user_name)}><span className="al-mono">{r.user_name}</span></button></td>
                    {r.cells.map((v: any, i: number) => (
                      <td key={i} style={v ? { background: `color-mix(in srgb, var(--st-warn) ${Math.round(15 + (75 * v) / heatMax)}%, transparent)`, color: v / heatMax > 0.6 ? "#fff" : undefined } : undefined}>
                        {v == null ? "–" : v === 0 ? "·" : fmtInt(v)}
                      </td>))}
                    <td><b>{fmtInt(r.cells.reduce((acc: number, v: any) => acc + numOrZero(v), 0))}</b></td></tr>))}</tbody>
              </table>
              <div className="al-key"><span>Fewer</span><span className="al-ramp" /><span>More</span></div>
            </div>
          )}
        </Card>
      )}

      <div className="al-split al-split2">
        <ByCard by={d.by} scope="all objects" />
        <StatementsCard rows={d.statements || []} scope="all objects" />
      </div>

      {d.hours_available && hours.length > 0 && (
        <Card title="Hours of use" sub={`People's queries by hour of day, ${utc(off)} · business hours ${hh(s.start)}–${hh(s.end)} shaded · weekends count as off hours`}>
          <div className="al-hours al-hours-h"><span className="al-th">User</span>
            <div className="al-haxis">{Array.from({ length: 24 }, (_, h) => <span key={h}>{h % 6 === 0 || h === 23 ? String(h).padStart(2, "0") : ""}</span>)}</div>
            <span className="al-th">On vs off hours</span><span className="al-th al-r">Off : on</span></div>
          {hours.slice(0, 12).map((u) => {
            const on = u.on.reduce((a: number, b: number) => a + b, 0), offN = u.off.reduce((a: number, b: number) => a + b, 0);
            return (
              <div key={u.user_name} className="al-hours">
                <span><button type="button" className="al-link" onClick={() => go("person", u.user_name)}><b className="al-mono">{u.user_name}</b></button><span className="al-meta">{plural(sensBy(u.user_name), "sensitive object")}</span></span>
                <HourBars on={u.on} off={u.off} startH={s.start} endH={s.end} max={hMax} />
                <OnOff on={on} off={offN} />
                <span className={`al-ratio${on && offN / on >= 0.5 ? " hi" : ""}`}>{on ? (offN / on).toFixed(2) : "–"}<small>off per 1 on</small></span>
              </div>
            );
          })}
          <div className="al-key"><span><i style={{ background: "var(--c1)" }} />On hours</span><span><i style={{ background: "var(--st-warn)" }} />Off hours</span><span><i style={{ background: "var(--surface-2)" }} />Business hours</span></div>
        </Card>
      )}

      <Card title={`By ${level}`} sub={`Every object's activity rolled up to its ${level} · objects of each kind · select a row to list its objects below`}
        right={<Seg label="Level" value={level} options={[["schema", "Schema"], ["database", "Database"]]} onPick={setLevel} />}>
        {roll.loading && !roll.data ? <CxStat>…</CxStat> : roll.err ? <CxStat>{`– ${roll.err}`}</CxStat> : (
          <table className="al-table al-roll">
            <thead><tr><th>{level === "schema" ? "Schema" : "Database"}</th><th>Objects</th><th>Activity</th><th className="n">Reads</th><th className="n">Writes</th><th className="n">DDL</th><th className="n">Users</th><th className="n">Last</th></tr></thead>
            <tbody>{((roll.data?.rows || []) as Row[]).slice(0, 15).map((r) => {
              const rd = numOrZero(r.reads), w = numOrZero(r.writes), dd = numOrZero(r.ddl), tot = rd + w + dd;
              const rmax = Math.max(1, ...((roll.data.rows as Row[]).map((x) => numOrZero(x.reads) + numOrZero(x.writes) + numOrZero(x.ddl))));
              const parts = [["tables", "table"], ["views", "view"], ["stages", "stage"], ["procedures", "proc"], ["functions", "fn"], ["streams", "stream"]]
                .filter(([k]) => numOrZero(r[k]) > 0).map(([k, t]) => `${fmtInt(numOrZero(r[k]))} ${t}`);
              return (
                <tr key={String(r.k)} className={`clickable${prefix === r.k ? " on" : ""}`} onClick={() => { setPrefix(prefix === r.k ? "" : String(r.k)); setObjN(10); }}>
                  <td><span className="al-name"><span className="al-mono">{String(r.k)}</span>{numOrZero(r.sensitive_objects) > 0 && <span className="al-chip d">{`${fmtInt(r.sensitive_objects)} sensitive`}</span>}</span></td>
                  <td className="al-meta">{`${fmtInt(numOrZero(r.objects))} · ${parts.join(", ")}`}</td>
                  <td><span className="al-hbar3" style={{ width: `${Math.max(2, (100 * tot) / rmax)}%` }}><i className="w" style={{ width: `${pct(w, tot)}%` }} /><i className="r" style={{ width: `${pct(rd, tot)}%` }} /><i className="d" style={{ width: `${pct(dd, tot)}%` }} /></span></td>
                  <td className="n">{fmtInt(rd)}</td><td className="n">{fmtInt(w)}</td><td className="n">{fmtInt(dd)}</td><td className="n">{fmtInt(numOrZero(r.users))}</td><td className="n">{day(r.last_at)}</td>
                </tr>
              );
            })}</tbody>
          </table>
        )}
      </Card>

      <Card title="Objects, busiest first" sub={`All queries in the window${prefix ? ` · in ${prefix}` : ""} · top ${fmtInt(Math.min(objN, list.length))} of ${plural(list.length, "object")} · select a row`}
        right={<><Seg label="Kind" value={kind} options={[["", "All kinds"], ["table", "Tables"], ["view", "Views"], ["stage", "Stages"], ["procedure", "Procedures"], ["function", "Functions"], ["other", "Other"]]} onPick={(v) => { setKind(v); setObjN(10); }} />
          <Seg label="Which objects" value={onlySens ? "s" : "a"} options={[["a", "All"], ["s", "Sensitive"]]} onPick={(v) => setOnlySens(v === "s")} /></>}>
        {prefix && <div className="al-pick" style={{ marginBottom: 8 }}><span className="al-chip">{prefix}</span><button type="button" className="al-link" onClick={() => setPrefix("")}>clear</button></div>}
        {objs.loading && !objs.data ? <CxStat>…</CxStat> : (
          <>
            <table className="al-table">
              <thead><tr><th>Object</th><th>Kind</th><th>Activity</th><th className="n">Reads</th><th className="n">Writes</th><th className="n">DDL</th><th className="n">Users</th><th className="n">Last</th></tr></thead>
              <tbody>{list.slice(0, objN).map((o) => {
                const r = numOrZero(o.reads), w = numOrZero(o.writes), dd = numOrZero(o.ddl);
                return (
                  <tr key={String(o.object_fqn)} className="clickable" onClick={() => go("object", String(o.object_fqn))}>
                    <td><Name fqn={o.object_fqn} sens={o.sensitive} /></td><td className="al-meta">{String(o.object_domain || "").toLowerCase()}</td>
                    <td><span className="al-hbar3" style={{ width: `${Math.max(2, (100 * (r + w + dd)) / actMax)}%` }}><i className="w" style={{ width: `${pct(w, r + w + dd)}%` }} /><i className="r" style={{ width: `${pct(r, r + w + dd)}%` }} /><i className="d" style={{ width: `${pct(dd, r + w + dd)}%` }} /></span></td>
                    <td className="n">{fmtInt(r)}</td><td className="n">{fmtInt(w)}</td><td className="n">{fmtInt(dd)}</td><td className="n">{fmtInt(numOrZero(o.users))}</td><td className="n">{day(o.last_at)}</td>
                  </tr>
                );
              })}</tbody>
            </table>
            <div className="al-foot"><span className="al-key"><span><i style={{ background: "var(--c1)" }} />Writes</span><span><i style={{ background: "var(--c2)" }} />Reads</span><span><i style={{ background: "var(--c3)" }} />DDL</span></span>
              {list.length > objN && <button type="button" className="al-link" onClick={() => setObjN(objN + 40)}>{`Show ${fmtInt(Math.min(40, list.length - objN))} more`}</button>}</div>
          </>
        )}
      </Card>
    </>
  );
}

// ═══════════════════════ One object ═══════════════════════

const TYPES: [string, string][] = [["", "All"], ["table", "Tables"], ["view", "Views"], ["stage", "Stages"], ["procedure", "Procedures"],
  ["function", "Functions"], ["streamlit", "Streamlit apps"]];

function TypePick({ otype, setOtype }: { otype: string; setOtype: (v: string) => void }) {
  return <div className="al-pick al-types"><span className="al-th">Type</span><Seg label="Object type" value={otype} options={TYPES} onPick={setOtype} /></div>;
}

function ObjectPicker({ p, name, onPick, kind }: { p: ApPageProps; name: string; onPick: (n: string) => void; kind?: string }) {
  const [typed, setTyped] = React.useState("");
  const [search, setSearch] = React.useState("");
  const [focused, setFocused] = React.useState(false);
  React.useEffect(() => { const t = setTimeout(() => setSearch(typed.trim()), 300); return () => clearTimeout(t); }, [typed]);
  const list = useJson(search || kind ? "/api/access/log/objects" : null, { window: p.filters.window, search, limit: 12, kind: kind || undefined });
  return (
    <div className="ax-pick">
      <input className="ax-input wide" value={typed} placeholder={name ? `Change object (now ${name.split(".").pop()})` : "Type a table, view or stage name"} aria-label="Object name"
        onChange={(e) => setTyped(e.target.value)} onFocus={() => setFocused(true)} onBlur={() => setTimeout(() => setFocused(false), 200)} />
      {(search || (kind && typed === "" && focused)) && (list.data?.objects || []).length > 0 && (
        <div className="cx-pick-list" role="listbox" aria-label="Objects">
          {(list.data.objects as Row[]).map((o) => <button key={String(o.object_fqn)} type="button" onClick={() => { onPick(String(o.object_fqn)); setTyped(""); }}>{String(o.object_fqn)}</button>)}
        </div>
      )}
    </div>
  );
}

function ObjectView({ p, off, name, onPick, go, otype, setOtype }: { p: ApPageProps; off: number; name: string; onPick: (n: string) => void;
  go: (s: Section, n?: string, k?: string) => void; otype: string; setOtype: (v: string) => void }) {
  const [split, setSplit] = React.useState("user");
  const [people, setPeople] = React.useState(false);
  const [sort, setSort] = React.useState("volume");
  const [whoN, setWhoN] = React.useState(15);
  const top = useJson(!name ? "/api/access/log/objects" : null, { window: p.filters.window, limit: 1, kind: otype || undefined });
  const obj = name || String(top.data?.objects?.[0]?.object_fqn || "");
  // picking a type opens that type's busiest object
  const pickType = (v: string) => { setOtype(v); if (v !== "streamlit") onPick(""); };
  const lg = useJson(obj ? "/api/access/log" : null, { object: obj, window: p.filters.window, split, offset: off });
  const d = lg.data;
  const t = d?.tiles || {};
  const roles = [...new Set((d?.matrix || []).map((m: Row) => String(m.r)))] as string[];
  const clients = [...new Set((d?.matrix || []).map((m: Row) => String(m.c)))] as string[];
  const cell = (r: string, cl: string) => numOrZero((d?.matrix || []).find((m: Row) => m.r === r && m.c === cl)?.q);
  const mMax = Math.max(1, ...(d?.matrix || []).map((m: Row) => numOrZero(m.q)));
  const total = numOrZero(t.reads) + numOrZero(t.writes) + numOrZero(t.ddl);
  const days = d ? allDays(String(d.start), String(d.end)) : [];
  const perDay = new Map((d?.days || []).map((r: Row) => [String(r.d).slice(0, 10), r]));
  const dayTot = days.map((x) => { const r: any = perDay.get(x) || {}; return numOrZero(r.writes) + numOrZero(r.reads) + numOrZero(r.ddl); });
  const busiest = days.length ? days[dayTot.indexOf(Math.max(...dayTot))] : null;
  let who: Row[] = (d?.who || []).filter((w: Row) => !people || w.is_person);
  if (sort === "days") who = [...who].sort((a, b) => numOrZero(b.days) - numOrZero(a.days));
  if (sort === "last") who = [...who].sort((a, b) => String(b.last_at).localeCompare(String(a.last_at)));
  const span = (v: any) => (d ? Math.max(0, Math.min(100, (100 * (Date.parse(String(v).slice(0, 10)) - Date.parse(String(d.start)))) / (Date.parse(String(d.end)) - Date.parse(String(d.start))))) : 0);
  const pd = d ? dayCols(d) : null;
  return (
    <>
      <TypePick otype={otype} setOtype={pickType} />
      <div className="al-pick"><ObjectPicker p={p} name={obj} onPick={onPick} kind={otype} />{lg.loading && <span className="cx-muted">…</span>}</div>
      {lg.err && <CxStat>{`– ${lg.err}`}</CxStat>}
      {!obj && !top.loading && <CxStat>No object was read or changed in this window.</CxStat>}
      {d && (
        <>
          <div className="al-objhead"><span className="al-th">Object detail</span><Name fqn={obj} sens={d.sensitive} /></div>
          <div className="al-tiles">
            <Tile l={d.kind === "PROCEDURE" || d.kind === "FUNCTION" ? "Calls" : "Reads"} v={fmtInt(numOrZero(t.reads))} s={`${plural(numOrZero(t.users), "user")} · ${plural(numOrZero(t.roles), "role")}`} />
            <Tile l="Writes" v={fmtInt(numOrZero(t.writes))} s="INSERT, UPDATE, DELETE, MERGE, COPY" />
            <Tile l="DDL" v={fmtInt(numOrZero(t.ddl))} s={t.ddl_operations || "CREATE, ALTER, DROP and the like"} warn={numOrZero(t.ddl) > 0} />
            <Tile l="Clients" v={fmtInt(numOrZero(t.clients))} s={few(t.client_list)} />
          </div>
          {d.kind === "PROCEDURE" && (
            <Card title="What it did" sub="Tables and views the procedure's own queries read and wrote (linked through the CALL) · in the window">
              {(d.did as Row[]).length ? (
                <table className="al-table">
                  <thead><tr><th>Object</th><th>Statements</th><th className="n">Reads</th><th className="n">Writes</th><th className="n">DDL</th><th>Roles</th><th className="n">Last</th></tr></thead>
                  <tbody>{(d.did as Row[]).map((r) => (
                    <tr key={String(r.object_fqn)} className="clickable" onClick={() => go("object", String(r.object_fqn))}>
                      <td><Name fqn={r.object_fqn} /></td><td><Chips list={r.statements} /></td><td className="n">{fmtInt(numOrZero(r.reads))}</td>
                      <td className="n">{fmtInt(numOrZero(r.writes))}</td><td className="n">{fmtInt(numOrZero(r.ddl))}</td><td className="al-meta">{r.roles}</td><td className="n">{day(r.last_at)}</td>
                    </tr>))}</tbody>
                </table>
              ) : <CxStat>No query ran inside this procedure in the window, or ACCESS_HISTORY has no root query ids for it.</CxStat>}
            </Card>
          )}
          <div className="al-split al-split2">
            <ByCard by={d.by} scope="this object" />
            <StatementsCard rows={d.statements} scope="this object" />
          </div>
          {roles.length > 0 && (
            <Card title="Role × client" sub="Queries in each cell · row and column totals">
              <table className="al-heat al-matrix">
                <thead><tr><th className="u">Role</th>{clients.map((cl) => <th key={cl}>{cl}</th>)}<th>Total</th></tr></thead>
                <tbody>{roles.map((r) => (
                  <tr key={r}><td className="u al-mono">{r}</td>{clients.map((cl) => { const v = cell(r, cl); return (
                    <td key={cl} style={v ? { background: `color-mix(in srgb, var(--c1) ${Math.round(10 + (75 * v) / mMax)}%, transparent)`, color: v / mMax > 0.6 ? "#fff" : undefined } : undefined}>{v ? fmtInt(v) : "–"}</td>); })}
                    <td><b>{fmtInt(clients.reduce((x, cl) => x + cell(r, cl), 0))}</b></td></tr>))}
                  <tr className="tot"><td className="u"><b>Total</b></td>{clients.map((cl) => <td key={cl}><b>{fmtInt(roles.reduce((x, r) => x + cell(r, cl), 0))}</b></td>)}<td><b>{fmtInt(total)}</b></td></tr>
                </tbody>
              </table>
            </Card>
          )}
          <Card title="Queries by statement type" sub={`Per day · ${day(d.start)} – ${day(d.end)} · ${fmtInt(total)} queries`}>
            <div className="al-tiles">
              <Tile l="DML · writes" v={<>{fmtInt(numOrZero(t.writes))} <small className="al-pct">{`${pct(numOrZero(t.writes), total)}%`}</small></>} s="INSERT · MERGE · COPY · UPDATE" />
              <Tile l="Reads" v={<>{fmtInt(numOrZero(t.reads))} <small className="al-pct">{`${pct(numOrZero(t.reads), total)}%`}</small></>} s="SELECT · CTAS source · UNLOAD" />
              <Tile l="DDL" v={<>{fmtInt(numOrZero(t.ddl))} <small className="al-pct">{`${pct(numOrZero(t.ddl), total)}%`}</small></>} s="CREATE · ALTER · DROP" />
            </div>
            <div className="al-hbar3 big"><i className="w" style={{ width: `${pct(numOrZero(t.writes), total)}%` }} /><i className="r" style={{ width: `${pct(numOrZero(t.reads), total)}%` }} /><i className="d" style={{ width: `${pct(numOrZero(t.ddl), total)}%` }} /></div>
            <Columns days={days} n={3} unitLabel="queries / day" ariaLabel="Queries per day by kind"
              series={[{ name: "DML · writes", id: "w", values: days.map((x) => numOrZero((perDay.get(x) as any)?.writes)) },
                { name: "Reads", id: "r", values: days.map((x) => numOrZero((perDay.get(x) as any)?.reads)) },
                { name: "DDL", id: "d", values: days.map((x) => numOrZero((perDay.get(x) as any)?.ddl)) }]} />
            <div className="al-stats">
              <span><span className="al-th">Busiest day</span><b>{day(busiest)}</b></span>
              <span><span className="al-th">Average a day</span><b>{days.length ? `~${fmtInt(Math.round(total / days.length))}` : "–"}</b></span>
              <span><span className="al-th">Active days</span><b>{`${fmtInt(dayTot.filter((x) => x > 0).length)} of ${fmtInt(days.length)}`}</b></span>
            </div>
          </Card>
          <Card title={`Queries per day, by ${split === "action" ? "read / write / DDL" : split}`} sub="Every day of the window · the top 4 and Other"
            right={<Seg label="Split by" value={split} options={[["user", "User"], ["role", "Role"], ["client", "Client"], ["statement", "Statement"], ["action", "R / W / DDL"]]} onPick={setSplit} />}>
            {pd && <Columns days={pd.days} series={pd.series} n={pd.series.length + 1} unitLabel="queries / day" ariaLabel="Queries per day" />}
          </Card>
          <Card title="Who used it" sub={`One row per user, role and client · off hours at ${utc(off)}, people only`}
            right={<><Seg label="Sort" value={sort} options={[["volume", "Volume"], ["days", "Active days"], ["last", "Last seen"]]} onPick={setSort} />
              <Seg label="Who" value={people ? "p" : "a"} options={[["a", "Everyone"], ["p", "People only"]]} onPick={(v) => setPeople(v === "p")} /></>}>
            <table className="al-table al-who">
              <thead><tr><th>User</th><th>Role · client</th><th>Statements</th><th className="n">Queries</th><th className="n">Off-hrs</th><th>Activity · {day(d.start)} – {day(d.end)}</th></tr></thead>
              <tbody>{who.slice(0, whoN).map((w, i) => {
                const q = numOrZero(w.reads) + numOrZero(w.writes) + numOrZero(w.ddl);
                return (
                  <tr key={`${w.user_name}|${w.role_name}|${w.client}|${i}`} className={w.is_person ? "person" : ""}>
                    <td><span className="al-two"><button type="button" className="al-link" onClick={() => go("person", String(w.user_name))}><b className="al-mono">{String(w.user_name)}</b></button>
                      <span className={`al-badge ${w.is_person ? "p" : ""}`}>{w.is_person ? "Person" : w.user_type === "UNKNOWN" ? "System" : "Service"}</span></span></td>
                    <td><span className="al-two"><span className="al-mono">{String(w.role_name)}</span><span className="al-meta">{String(w.client)}</span>{w.via && <span className="al-chip v" title={String(w.via)}>{`via ${String(w.via).replace(/^(procedure|streamlit) /, (m) => m.trim() === "procedure" ? "proc " : "app ").split(".").pop()}`}</span>}</span></td>
                    <td><Chips list={[w.statements, w.ddl_operations].filter(Boolean).join(", ")} /></td>
                    <td className="n"><b>{fmtInt(q)}</b><div className="al-meta">{`${fmtInt(numOrZero(w.writes))} DML · ${fmtInt(numOrZero(w.reads))} rd${numOrZero(w.ddl) ? ` · ${fmtInt(w.ddl)} DDL` : ""}`}</div></td>
                    <td className={`n${numOrZero(w.off_hours) > 0 ? " al-o" : ""}`}>{w.off_hours == null ? "–" : fmtInt(w.off_hours)}</td>
                    <td><div className="al-tl"><i style={{ left: `${span(w.first_at)}%`, width: `${Math.max(1.5, span(w.last_at) - span(w.first_at))}%` }} className={w.is_person ? "p" : ""} /></div>
                      <span className="al-meta">{`${fmtInt(numOrZero(w.days))} of ${fmtInt(days.length)} days · ${day(w.first_at)} → ${day(w.last_at)}`}</span></td>
                  </tr>
                );
              })}</tbody>
            </table>
            <div className="al-foot"><span>{`Showing ${fmtInt(Math.min(whoN, who.length))} of ${plural(who.length, "row")}`}</span>
              {who.length > whoN && <button type="button" className="al-link" onClick={() => setWhoN(whoN + 40)}>{`Show ${fmtInt(Math.min(40, who.length - whoN))} more`}</button>}</div>
          </Card>
          <Card title="Every query, one by one" sub="Run in Snowflake for the query ids and times behind these counts (no query text)">
            <pre className="al-sql">{[
              "SELECT DISTINCT ah.query_id, ah.query_start_time, ah.user_name, q.role_name, q.query_type,",
              "       f.value:\"objectDomain\"::STRING AS object_domain",
              "FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah",
              "CROSS JOIN LATERAL FLATTEN(input => ARRAY_CAT(ARRAY_CAT(ah.base_objects_accessed, ah.objects_modified),",
              "                                              ARRAY_CONSTRUCT_COMPACT(ah.object_modified_by_ddl))) f",
              "LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q ON q.query_id = ah.query_id",
              `  AND q.start_time >= ${sqlLit(String(d.start))} AND q.start_time < DATEADD(day, 1, ${sqlLit(String(d.end))})`,
              `WHERE UPPER(f.value:"objectName"::STRING) = ${sqlLit(obj)}`,
              `  AND ah.query_start_time >= ${sqlLit(String(d.start))} AND ah.query_start_time < ${sqlLit(String(d.end))}`,
              "ORDER BY ah.query_start_time DESC;",
            ].join("\n")}</pre>
          </Card>
        </>
      )}
    </>
  );
}

// ═══════════════════════ One person ═══════════════════════

function PersonView({ p, off, s, name, onPick, go }: { p: ApPageProps; off: number; s: Row; name: string; onPick: (n: string) => void; go: (s: Section, n?: string, k?: string) => void }) {
  const [split, setSplit] = React.useState("object");
  const [mode, setMode] = React.useState("user");
  const [role, setRole] = React.useState("");
  const list = useJson("/api/access/people", { window: p.filters.window });
  const people: Row[] = list.data?.people || [];
  const roleList: Row[] = list.data?.roles || [];
  const user = name || String((people.find((x) => x.is_person) || people[0] || {}).user_name || "");
  const rname = role || String((roleList[0] || {}).role_name || "");
  const ps = useJson(mode === "user" ? (user ? "/api/access/person" : null) : (rname ? "/api/access/person" : null),
    mode === "user" ? { user, window: p.filters.window, split, offset: off } : { role: rname, window: p.filters.window, split, offset: off });
  const d = ps.data;
  const t = d?.tiles || {};
  const pd = d ? dayCols(d) : null;
  const on = d?.hours ? d.hours.on.reduce((a: number, b: number) => a + b, 0) : 0;
  const offN = d?.hours ? d.hours.off.reduce((a: number, b: number) => a + b, 0) : 0;
  return (
    <>
      <div className="al-pick">
        <Seg label="User or role" value={mode} options={[["user", "User"], ["role", "Role"]]} onPick={setMode} />
        {mode === "user" ? (
          <select className="ax-input" value={user} aria-label="User" onChange={(e) => onPick(e.target.value)}>
            {people.map((x) => <option key={String(x.user_name)} value={String(x.user_name)}>{`${x.user_name} · ${x.is_person ? "person" : String(x.user_type || "").toLowerCase()} · ${fmtInt(numOrZero(x.queries))} queries`}</option>)}
          </select>
        ) : (
          <select className="ax-input" value={rname} aria-label="Role" onChange={(e) => setRole(e.target.value)}>
            {roleList.map((x) => <option key={String(x.role_name)} value={String(x.role_name)}>{`${x.role_name} · ${plural(numOrZero(x.users), "user")} · ${fmtInt(numOrZero(x.queries))} queries`}</option>)}
          </select>
        )}
        {(list.loading || ps.loading) && <span className="cx-muted">…</span>}
      </div>
      {ps.err && <CxStat>{`– ${ps.err}`}</CxStat>}
      {d && (
        <>
          {d.user ? <div className="al-objhead"><span className="al-th">User detail</span><b className="al-mono">{d.user}</b><span className={`al-badge ${t.is_person ? "p" : ""}`}>{t.is_person ? "Person" : "Service / system"}</span></div>
            : <div className="al-objhead"><span className="al-th">Role detail</span><b className="al-mono">{d.role}</b><span className="al-meta">{`used by ${few(t.user_list, 5)}`}</span></div>}
          <div className="al-tiles">
            <Tile l="Reads" v={fmtInt(numOrZero(t.reads))} s={plural(numOrZero(t.objects), "object")} />
            <Tile l="Writes" v={fmtInt(numOrZero(t.writes))} s="INSERT, UPDATE, MERGE, COPY…" />
            <Tile l="DDL" v={fmtInt(numOrZero(t.ddl))} warn={numOrZero(t.ddl) > 0} s="CREATE, ALTER, DROP…" />
            {d.user ? <Tile l="Roles · clients" v={`${fmtInt(numOrZero(t.roles))} · ${fmtInt(numOrZero(t.clients))}`} s={few(t.client_list)} />
              : <Tile l="Users · clients" v={`${fmtInt(numOrZero(t.users))} · ${fmtInt(numOrZero(t.clients))}`} s={few(t.client_list)} />}
            <Tile l="Off hours" v={d.hours ? fmtInt(offN) : "–"} warn={offN > 0} s={d.hours ? `${pct(offN, on + offN)}% of queries · ${utc(off)}` : !d.user ? "judged per person: pick a user" : t.is_person ? "the hours check did not run" : "not a person: not judged"} />
          </div>
          {d.hours && (
            <Card title="Hours of use" sub={`Queries by hour of day, ${utc(off)} · business hours ${hh(s.start)}–${hh(s.end)} shaded · weekends count as off hours`}>
              <div className="al-hours one"><HourBars on={d.hours.on} off={d.hours.off} startH={s.start} endH={s.end} max={Math.max(1, ...d.hours.on.map((v: number, i: number) => v + d.hours.off[i]))} /><OnOff on={on} off={offN} /></div>
              <div className="al-hours one"><div className="al-haxis">{Array.from({ length: 24 }, (_, h) => <span key={h}>{h % 3 === 0 ? String(h).padStart(2, "0") : ""}</span>)}</div><span /></div>
            </Card>
          )}
          <Card title={`Queries per day, by ${split === "action" ? "read / write / DDL" : split}`} sub="Every day of the window · the top 4 and Other"
            right={<Seg label="Split by" value={split} options={[["object", "Object"], ["role", "Role"], ["client", "Client"], ["statement", "Statement"], ["action", "R / W / DDL"]]} onPick={setSplit} />}>
            {pd && <Columns days={pd.days} series={pd.series} n={pd.series.length + 1} unitLabel="queries / day" ariaLabel="Queries per day" />}
          </Card>
          <div className="al-split al-split2">
            <Card title="What was touched, by kind" sub="Objects of each kind read, written or changed in the window">
              {(d.kinds as Row[]).length ? (
                <table className="al-table">
                  <thead><tr><th>Kind</th><th className="n">Objects</th><th className="n">Reads / calls</th><th className="n">Writes</th><th className="n">DDL</th><th className="n">Last</th></tr></thead>
                  <tbody>{(d.kinds as Row[]).map((k) => (
                    <tr key={String(k.kind)}><td>{`${String(k.kind)}s`}</td><td className="n">{fmtInt(numOrZero(k.objects))}</td><td className="n">{fmtInt(numOrZero(k.reads))}</td>
                      <td className="n">{fmtInt(numOrZero(k.writes))}</td><td className="n">{fmtInt(numOrZero(k.ddl))}</td><td className="n">{day(k.last_at)}</td></tr>))}</tbody>
                </table>
              ) : <CxStat>Nothing touched in the window.</CxStat>}
            </Card>
            <Card title="Streamlit apps opened" sub={d.user ? "Apps this user opened · select a row" : "Apps are opened by users: pick a user"}>
              {d.user && (d.apps as Row[]).length ? (
                <table className="al-table">
                  <thead><tr><th>App</th><th className="n">Runs</th><th className="n">Days</th><th className="n">Last</th></tr></thead>
                  <tbody>{(d.apps as Row[]).map((a) => (
                    <tr key={String(a.app_name)} className="clickable" onClick={() => go("object", String(a.app_name), "streamlit")}><td><span className="al-mono">{String(a.app_name)}</span></td>
                      <td className="n">{fmtInt(numOrZero(a.runs))}</td><td className="n">{fmtInt(numOrZero(a.days))}</td><td className="n">{day(a.last_at)}</td></tr>))}</tbody>
                </table>
              ) : <CxStat>{d.user ? "No Streamlit app opened in the window." : "–"}</CxStat>}
            </Card>
          </div>
          <Card title="Objects used" sub="One row per object · select a row for its detail">
            <CxTable ariaLabel="Objects used" n={15}
              cols={[{ label: "Object" }, { label: "Statements" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Roles · clients" }, { label: "Days", num: true }, { label: "Last", num: true }]}
              rows={(d.objects as Row[]).map((o) => ({
                key: String(o.object_fqn), onClick: () => go("object", String(o.object_fqn)), status: numOrZero(o.ddl) > 0 ? "WARN" : undefined,
                cells: [<Name fqn={o.object_fqn} sens={o.sensitive} />, <Chips list={o.statements} />,
                  fmtInt(numOrZero(o.reads)), fmtInt(numOrZero(o.writes)), fmtInt(numOrZero(o.ddl)),
                  <span className="al-meta">{`${o.roles} · ${o.clients}`}</span>, fmtInt(numOrZero(o.days)), day(o.last_at)],
              }))} />
          </Card>
        </>
      )}
    </>
  );
}

// ═══════════════════════ One object: a Streamlit app ═══════════════════════

function AppDetail({ p, go, app, onPick, otype, setOtype }: { p: ApPageProps; go: (s: Section, n?: string, k?: string) => void; app: string;
  onPick: (n: string) => void; otype: string; setOtype: (v: string) => void }) {
  const ap = useJson("/api/access/apps", { window: p.filters.window, app: app || undefined });
  const d = ap.data;
  const apps: Row[] = d?.apps || [];
  const days = d ? allDays(String(d.start), String(d.end)) : [];
  const live = (d?.shares || []).filter((r: Row) => !r.revoked_at && r.privilege === "USAGE");
  return (
    <>
      <TypePick otype={otype} setOtype={setOtype} />
      <div className="al-pick">
        <select className="ax-input" value={d?.app || ""} aria-label="Streamlit app" onChange={(e) => onPick(e.target.value)}>
          {apps.map((r) => <option key={String(r.app_name)} value={String(r.app_name)}>{`${r.app_name} · ${plural(numOrZero(r.users), "person")}`}</option>)}
        </select>
        {ap.loading && <span className="cx-muted">…</span>}
      </div>
      {ap.err && <CxStat>{`– ${ap.err}`}</CxStat>}
      {d && !apps.length && <CxStat>{`No Streamlit app ran or was shared in ${day(d.start)}–${day(d.end)}.`}</CxStat>}
      {d && d.app && (
        <>
          <div className="al-objhead"><span className="al-th">Streamlit app</span><span className="al-mono">{String(d.app)}</span></div>
          <div className="al-tiles">
            <Tile l="People who opened it" v={fmtInt((d.who as Row[]).length)} s={`${fmtInt((d.who as Row[]).reduce((n: number, w: Row) => n + numOrZero(w.runs), 0))} runs in the window`} />
            <Tile l="Can open it now" v={d.can_open == null ? "–" : fmtInt(d.can_open.length)} s={d.can_open == null ? "no grant links in this export" : "users through the roles it is shared with"} />
            <Tile l="Shared with" v={d.shares == null ? "–" : fmtInt(live.length)} warn={live.some((r: Row) => r.grantee_name === "PUBLIC")}
              s={d.shares == null ? "the share check did not run" : few(live.map((r: Row) => r.grantee_name).join(", "))} />
            <Tile l="Runs as" mono v={(d.runs_as as Row[])[0]?.role_name || "–"} s="the app's own queries (owner's rights)" />
          </div>
          <Card title="Who opened it" sub="One row per user · runs = the app starting or rerunning for them · a tick per day used · client and sign-in IP of their session">
            {(d.who as Row[]).length ? (
              <table className="al-table al-apps">
                <thead><tr><th>User</th><th>Roles</th><th className="n">Runs</th><th>Days used · {day(d.start)} – {day(d.end)}</th><th>From</th><th className="n">First → last</th></tr></thead>
                <tbody>{(d.who as Row[]).map((w) => (
                  <tr key={String(w.user_name)} className={w.user_type === "PERSON" ? "person" : ""}>
                    <td><span className="al-two"><button type="button" className="al-link" onClick={() => go("person", String(w.user_name))}><b className="al-mono">{String(w.user_name)}</b></button>
                      <span className={`al-badge ${w.user_type === "PERSON" ? "p" : ""}`}>{w.user_type === "PERSON" ? "Person" : "Service"}</span></span></td>
                    <td className="al-meta">{w.roles}</td><td className="n">{fmtInt(numOrZero(w.runs))}</td>
                    <td><div className="al-ticks">{days.map((x) => <i key={x} className={(w.dates || []).includes(x) ? "on" : ""} title={x} />)}</div><span className="al-meta">{`${fmtInt(numOrZero(w.days))} of ${fmtInt(days.length)} days`}</span></td>
                    <td><span className="al-two"><span className="al-mono sm">{w.client_ips || "–"}</span><span className="al-meta">{w.clients || "–"}</span></span></td>
                    <td className="n al-meta">{`${day(w.first_at)} → ${day(w.last_at)}`}</td>
                  </tr>))}</tbody>
              </table>
            ) : <CxStat>{`Nobody opened it in ${day(d.start)}–${day(d.end)}.`}</CxStat>}
          </Card>
          <div className="al-split al-split2">
            <Card title="Shared with" sub="Grants on the app: granted and revoked, by whom and when (GRANT USAGE ON STREAMLIT … TO ROLE)">
              {d.shares == null ? <CxStat>– Not in this export: run it again with sf_acc_streamlit_shares.</CxStat> : (d.shares as Row[]).length ? (
                <table className="al-table">
                  <thead><tr><th>Role</th><th>Privilege</th><th>Granted by</th><th className="n">Granted</th><th className="n">Revoked</th></tr></thead>
                  <tbody>{(d.shares as Row[]).map((r, i) => (
                    <tr key={`${r.grantee_name}|${r.privilege}|${i}`}><td><span className="al-mono">{String(r.grantee_name)}</span>{r.grantee_name === "PUBLIC" && <span className="al-chip d">every user</span>}</td>
                      <td>{String(r.privilege).toLowerCase()}</td><td className="al-meta">{r.granted_by || "SYSTEM"}</td><td className="n">{day(r.granted_at)}</td>
                      <td className="n">{r.revoked_at ? day(r.revoked_at) : "—"}</td></tr>))}</tbody>
                </table>
              ) : <CxStat>Not shared with any role.</CxStat>}
            </Card>
            <Card title="Who can open it now" sub="Users who hold a role it is shared with, directly or through other roles">
              {d.can_open == null ? <CxStat>– No grant links in this export.</CxStat> : d.can_open.length ? (
                <div className="al-chips">{(d.can_open as string[]).map((u) => <span key={u} className={`al-chip${(d.who as Row[]).some((w) => w.user_name === u) ? " w" : ""}`}>{u}</span>)}</div>
              ) : <CxStat>Nobody.</CxStat>}
              <div className="al-key"><span><i style={{ background: "color-mix(in srgb, var(--c1) 18%, transparent)" }} />opened it in the window</span></div>
            </Card>
          </div>
          <Card title="What it read and wrote" sub="Tables and views the app's own queries touched, as its owner · select a row">
            {(d.objects as Row[]).length ? (
              <table className="al-table">
                <thead><tr><th>Object</th><th className="n">Reads</th><th className="n">Writes</th><th className="n">DDL</th><th>Ran as</th><th className="n">Last</th></tr></thead>
                <tbody>{(d.objects as Row[]).map((o) => (
                  <tr key={String(o.object_fqn)} className="clickable" onClick={() => go("object", String(o.object_fqn))}>
                    <td><Name fqn={o.object_fqn} sens={o.sensitive} /></td><td className="n">{fmtInt(numOrZero(o.reads))}</td><td className="n">{fmtInt(numOrZero(o.writes))}</td>
                    <td className="n">{fmtInt(numOrZero(o.ddl))}</td><td className="al-meta">{(d.runs_as as Row[]).map((r) => `${r.user_name} · ${r.role_name}`).join(", ")}</td><td className="n">{day(o.last_at)}</td>
                  </tr>))}</tbody>
              </table>
            ) : <CxStat>The app read no table in the window, or its queries are not in the access log.</CxStat>}
          </Card>
          <div className="al-meta">Apps run with owner's rights: their queries carry the owner's role, and the viewer is read from the query that opens the app. Snowflake does not record which rows a viewer saw.</div>
        </>
      )}
    </>
  );
}
