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
  p.goTo({ tab: "activity", subtab: "accesslog", focusQueryId: null });
}

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

export function ApActivityAccessLog(p: ApPageProps) {
  const c = useAggCheck(p, "sf_use_access_log", [], "read_queries", []);
  const ran = !c.loading && !c.why;
  const [section, setSection] = React.useState<Section>(() => start.section);
  const [object, setObject] = React.useState(() => { const o = start.object; start = { section: "overview", object: "" }; return o; });
  const [person, setPerson] = React.useState("");
  const cfg = useJson(ran ? "/api/access/settings" : null, {});
  const [offset, setOffset] = React.useState<number | null>(null);
  const off = offset ?? cfg.data?.offset ?? 0;
  const go = (s: Section, name?: string) => { if (s === "object" && name) setObject(name); if (s === "person" && name) setPerson(name); setSection(s); window.scrollTo({ top: 0 }); };

  useLede(p, c.loading, ran ? "Who read, wrote or changed which table, view and stage, with which role and client, and when. Hours are UTC; shift them to your business time on the left." : null);
  if (!ran) return <div className="ais-page cx-e"><CxStat>{c.loading ? "…" : c.empty ? c.why : `– ${c.why}`}</CxStat></div>;
  const s = cfg.data || { offset: 0, start: 7, end: 19 };
  return (
    <div className="ais-page cx-e">
      <div className="al-wrap">
        <aside className="al-side" aria-label="Access log sections">
          <h4>Sections</h4>
          <nav className="al-nav">
            {([["overview", "Overview", "off hours, hours of use, busiest"], ["object", "One object", object || "pick a table, view or stage"],
              ["person", "One person", person || "pick a user"]] as [Section, string, string][]).map(([k, t, sub]) => (
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
          {section === "object" && <ObjectView p={p} off={off} name={object} onPick={setObject} go={go} />}
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
  const ov = useJson("/api/access/overview", { window: p.filters.window, offset: off });
  const objs = useJson("/api/access/log/objects", { window: p.filters.window, limit: 50 });
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
          <div className="al-split">
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
            {d.heat_objects.length > 0 && (
              <div className="al-heatbox">
                <div className="al-sub-h">Who touched what</div>
                <div className="al-meta">Off-hours queries · user × sensitive object · – no grant path</div>
                <table className="al-heat">
                  <thead><tr><th />{d.heat_objects.map((f: string) => <th key={f} title={f}>{f.split(".").pop()}</th>)}</tr></thead>
                  <tbody>{d.heat.slice(0, 8).map((r: Row) => (
                    <tr key={r.user_name}><td className="u al-mono">{r.user_name}</td>{r.cells.map((v: any, i: number) => (
                      <td key={i} style={v ? { background: `color-mix(in srgb, var(--st-warn) ${Math.round(15 + (75 * v) / heatMax)}%, transparent)`, color: v / heatMax > 0.6 ? "#fff" : undefined } : undefined}>
                        {v == null ? "–" : v === 0 ? "·" : fmtInt(v)}
                      </td>))}</tr>))}</tbody>
                </table>
                <div className="al-key"><span>Fewer</span><span className="al-ramp" /><span>More</span></div>
              </div>
            )}
          </div>
        )}
      </Card>

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

      <Card title="Objects, busiest first" sub={`All queries in the window · top ${fmtInt(Math.min(objN, list.length))} of ${plural(list.length, "object")} · select a row`}
        right={<Seg label="Which objects" value={onlySens ? "s" : "a"} options={[["a", "All"], ["s", "Sensitive"]]} onPick={(v) => setOnlySens(v === "s")} />}>
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

function ObjectPicker({ p, name, onPick }: { p: ApPageProps; name: string; onPick: (n: string) => void }) {
  const [typed, setTyped] = React.useState("");
  const [search, setSearch] = React.useState("");
  React.useEffect(() => { const t = setTimeout(() => setSearch(typed.trim()), 300); return () => clearTimeout(t); }, [typed]);
  const list = useJson(search ? "/api/access/log/objects" : null, { window: p.filters.window, search, limit: 12 });
  return (
    <div className="ax-pick">
      <input className="ax-input wide" value={typed} placeholder={name ? `Change object (now ${name.split(".").pop()})` : "Type a table, view or stage name"} aria-label="Object name"
        onChange={(e) => setTyped(e.target.value)} />
      {search && (list.data?.objects || []).length > 0 && (
        <div className="cx-pick-list" role="listbox" aria-label="Objects">
          {(list.data.objects as Row[]).map((o) => <button key={String(o.object_fqn)} type="button" onClick={() => { onPick(String(o.object_fqn)); setTyped(""); }}>{String(o.object_fqn)}</button>)}
        </div>
      )}
    </div>
  );
}

function ObjectView({ p, off, name, onPick, go }: { p: ApPageProps; off: number; name: string; onPick: (n: string) => void; go: (s: Section, n?: string) => void }) {
  const [split, setSplit] = React.useState("user");
  const [by, setBy] = React.useState("client");
  const [people, setPeople] = React.useState(false);
  const [sort, setSort] = React.useState("volume");
  const [whoN, setWhoN] = React.useState(15);
  const top = useJson(!name ? "/api/access/log/objects" : null, { window: p.filters.window, limit: 1 });
  const obj = name || String(top.data?.objects?.[0]?.object_fqn || "");
  const lg = useJson(obj ? "/api/access/log" : null, { object: obj, window: p.filters.window, split, offset: off });
  const d = lg.data;
  const t = d?.tiles || {};
  const byRows: Row[] = d?.by?.[by] || [];
  const byMax = Math.max(1, ...byRows.map((r) => numOrZero(r.reads) + numOrZero(r.writes) + numOrZero(r.ddl)));
  const roles = [...new Set((d?.matrix || []).map((m: Row) => String(m.r)))] as string[];
  const clients = [...new Set((d?.matrix || []).map((m: Row) => String(m.c)))] as string[];
  const cell = (r: string, cl: string) => numOrZero((d?.matrix || []).find((m: Row) => m.r === r && m.c === cl)?.q);
  const mMax = Math.max(1, ...(d?.matrix || []).map((m: Row) => numOrZero(m.q)));
  const stMax = Math.max(1, ...(d?.statements || []).map((r: Row) => numOrZero(r.queries)));
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
      <div className="al-pick"><ObjectPicker p={p} name={obj} onPick={onPick} />{lg.loading && <span className="cx-muted">…</span>}</div>
      {lg.err && <CxStat>{`– ${lg.err}`}</CxStat>}
      {!obj && !top.loading && <CxStat>No object was read or changed in this window.</CxStat>}
      {d && (
        <>
          <div className="al-objhead"><span className="al-th">Object detail</span><Name fqn={obj} sens={d.sensitive} /></div>
          <div className="al-tiles">
            <Tile l="Reads" v={fmtInt(numOrZero(t.reads))} s={`${plural(numOrZero(t.users), "user")} · ${plural(numOrZero(t.roles), "role")}`} />
            <Tile l="Writes" v={fmtInt(numOrZero(t.writes))} s="INSERT, UPDATE, DELETE, MERGE, COPY" />
            <Tile l="DDL" v={fmtInt(numOrZero(t.ddl))} s={t.ddl_operations || "CREATE, ALTER, DROP and the like"} warn={numOrZero(t.ddl) > 0} />
            <Tile l="Clients" v={fmtInt(numOrZero(t.clients))} s={few(t.client_list)} />
          </div>
          <div className="al-split">
            <Card title={`Queries by ${by === "action" ? "kind" : by}`} sub="Writes, reads and DDL summed per row · sorted by volume"
              right={<Seg label="Group by" value={by} options={[["client", "Client"], ["role", "Role"], ["user", "User"]]} onPick={setBy} />}>
              {byRows.slice(0, 8).map((r) => {
                const tot = numOrZero(r.reads) + numOrZero(r.writes) + numOrZero(r.ddl);
                return (
                  <div key={String(r.k)} className="al-byrow">
                    <span className="al-two"><b className="al-mono">{String(r.k)}</b><span className="al-meta" title={r.roles}>{`${plural(numOrZero(r.users), "user")} · ${r.roles}`}</span></span>
                    <span className="al-hbar3" style={{ width: `${Math.max(2, (100 * tot) / byMax)}%` }}>
                      <i className="w" style={{ width: `${pct(numOrZero(r.writes), tot)}%` }} /><i className="r" style={{ width: `${pct(numOrZero(r.reads), tot)}%` }} /><i className="d" style={{ width: `${pct(numOrZero(r.ddl), tot)}%` }} />
                    </span>
                    <span className="al-num">{fmtInt(tot)}</span>
                  </div>
                );
              })}
              <div className="al-key"><span><i style={{ background: "var(--c1)" }} />Writes (DML)</span><span><i style={{ background: "var(--c2)" }} />Reads</span><span><i style={{ background: "var(--c3)" }} />DDL</span></div>
            </Card>
            <Card title="Statement kinds" sub="Queries per statement type · user, role and client combinations">
              {(d.statements as Row[]).map((r) => (
                <div key={String(r.k)} className="al-strow">
                  <span className={`al-dot ${numOrZero(r.ddl) ? "d" : numOrZero(r.writes) ? "w" : "r"}`} />
                  <span className="al-mono sm">{String(r.k)}</span>
                  <span className="al-bar"><i className={numOrZero(r.ddl) ? "d" : numOrZero(r.writes) ? "w" : "r"} style={{ width: `${(100 * numOrZero(r.queries)) / stMax}%` }} /></span>
                  <span className="al-num">{fmtInt(numOrZero(r.queries))}</span>
                  <span className="al-meta al-r">{`${fmtInt(numOrZero(r.combos))} combos`}</span>
                </div>
              ))}
            </Card>
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
                    <td><span className="al-two"><span className="al-mono">{String(w.role_name)}</span><span className="al-meta">{String(w.client)}</span></span></td>
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

function PersonView({ p, off, s, name, onPick, go }: { p: ApPageProps; off: number; s: Row; name: string; onPick: (n: string) => void; go: (s: Section, n?: string) => void }) {
  const [split, setSplit] = React.useState("object");
  const list = useJson("/api/access/people", { window: p.filters.window });
  const people: Row[] = list.data?.people || [];
  const user = name || String((people.find((x) => x.is_person) || people[0] || {}).user_name || "");
  const ps = useJson(user ? "/api/access/person" : null, { user, window: p.filters.window, split, offset: off });
  const d = ps.data;
  const t = d?.tiles || {};
  const pd = d ? dayCols(d) : null;
  const on = d?.hours ? d.hours.on.reduce((a: number, b: number) => a + b, 0) : 0;
  const offN = d?.hours ? d.hours.off.reduce((a: number, b: number) => a + b, 0) : 0;
  return (
    <>
      <div className="al-pick">
        <select className="ax-input" value={user} aria-label="User" onChange={(e) => onPick(e.target.value)}>
          {people.map((x) => <option key={String(x.user_name)} value={String(x.user_name)}>{`${x.user_name} · ${x.is_person ? "person" : String(x.user_type || "").toLowerCase()} · ${fmtInt(numOrZero(x.queries))} queries`}</option>)}
        </select>
        {(list.loading || ps.loading) && <span className="cx-muted">…</span>}
      </div>
      {ps.err && <CxStat>{`– ${ps.err}`}</CxStat>}
      {d && (
        <>
          <div className="al-objhead"><span className="al-th">Person detail</span><b className="al-mono">{d.user}</b><span className={`al-badge ${t.is_person ? "p" : ""}`}>{t.is_person ? "Person" : "Service / system"}</span></div>
          <div className="al-tiles">
            <Tile l="Reads" v={fmtInt(numOrZero(t.reads))} s={plural(numOrZero(t.objects), "object")} />
            <Tile l="Writes" v={fmtInt(numOrZero(t.writes))} s="INSERT, UPDATE, MERGE, COPY…" />
            <Tile l="DDL" v={fmtInt(numOrZero(t.ddl))} warn={numOrZero(t.ddl) > 0} s="CREATE, ALTER, DROP…" />
            <Tile l="Roles · clients" v={`${fmtInt(numOrZero(t.roles))} · ${fmtInt(numOrZero(t.clients))}`} s={few(t.client_list)} />
            <Tile l="Off hours" v={d.hours ? fmtInt(offN) : "–"} warn={offN > 0} s={d.hours ? `${pct(offN, on + offN)}% of queries · ${utc(off)}` : t.is_person ? "the hours check did not run" : "not a person: not judged"} />
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
