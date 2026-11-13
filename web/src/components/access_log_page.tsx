// web/src/components/access_log_page.tsx -- Activity › Access log: a left panel with three sections
// (Overview, One object, One person) and a UTC-offset slider that recounts off-hours use in place. Hours
// are stored in UTC; the slider is a what-if, the check's status uses the offset in config/thresholds.yml.
import React from "react";
import "../styles/css/p_access_log.css";
import { fmtDayShort, fmtInt } from "../format";
import { numOrZero } from "./hooks";
import type { ApPageProps } from "./area_pages";
import { Columns } from "./charts_more";
import { ChartCard } from "./primitives";
import { useAggCheck, useLede } from "./area_ai_storage";
import { CxObjName, CxStat, CxTable } from "./cx_e";
import { useJson } from "./use_json";
import type { Row } from "../types";

type Section = "overview" | "object" | "person";
const plural = (n: number, one: string) => `${fmtInt(n)} ${n === 1 ? one : `${one}s`}`;
const day = (v: any) => (v ? fmtDayShort(String(v).slice(0, 10)) : "–");
const utc = (o: number) => `UTC${o >= 0 ? "+" : "−"}${Math.abs(o)}`;
const hh = (h: number) => `${String(h).padStart(2, "0")}:00`;
const sqlLit = (s: string) => `'${s.replace(/'/g, "''")}'`;

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

function Chips({ list, write }: { list: any; write?: Set<string> }) {
  const items = String(list || "").split(", ").filter(Boolean);
  if (!items.length) return <span className="al-meta">–</span>;
  return <span>{items.map((x) => <span key={x} className={`al-chip${write && write.has(x) ? " w" : ""}`}>{x}</span>)}</span>;
}

/** Per-day stacked columns from {name, values: {day: n}} series, every day of the window shown. */
function PerDay({ d, title, sub }: { d: any; title: string; sub: string }) {
  const days = allDays(String(d.start), String(d.end));
  const series = (d.per_day?.series || []).map((s: Row) => ({ name: s.name, id: s.name, values: days.map((x) => numOrZero(s.values[x])) }));
  return (
    <ChartCard title={title} subtitle={sub} takeaway={null}>
      <Columns days={days} series={series} n={6} unitLabel="queries / day" ariaLabel={title} />
    </ChartCard>
  );
}

/** 24 hourly columns in local time: on-hours blue, off-hours amber, business hours shaded. */
function HourBars({ on, off, startH, endH, max }: { on: number[]; off: number[]; startH: number; endH: number; max: number }) {
  return (
    <div>
      <div className="al-hbars" aria-label="Queries by hour of day">
        {on.map((v, h) => (
          <span key={h} className={h >= startH && h < endH ? "biz" : ""} title={`${hh(h)}: ${fmtInt(v)} on, ${fmtInt(off[h])} off`}>
            <i className="on" style={{ height: `${(100 * v) / max}%` }} />
            <i className="off" style={{ height: `${(100 * off[h]) / max}%` }} />
          </span>
        ))}
      </div>
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
            <p>{`${hh(s.start)}–${hh(s.end)} local, Monday to Friday. Config: ${utc(s.offset)}.`}</p>
            {off !== s.offset && <><p>A what-if: findings count off hours at {utc(s.offset)}.</p><button type="button" onClick={() => setOffset(null)}>Back to {utc(s.offset)}</button></>}
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
  if (ov.loading) return <CxStat>…</CxStat>;
  if (ov.err) return <CxStat>{`– ${ov.err}`}</CxStat>;
  const d = ov.data;
  if (!d) return null;
  const people: Row[] = d.off_hours || [];
  const maxOff = Math.max(1, ...people.flatMap((x) => x.objects.map((o: Row) => numOrZero(o.off_hours))));
  const heatMax = Math.max(1, ...d.heat.flatMap((r: Row) => r.cells.map((v: any) => numOrZero(v))));
  const hours: Row[] = d.hours || [];
  const hMax = Math.max(1, ...hours.flatMap((u) => u.on.map((v: number, i: number) => v + u.off[i])));
  const list: Row[] = (objs.data?.objects || []).filter((o: Row) => !onlySens || o.sensitive);
  return (
    <>
      {d.truncated && <CxStat>{`The export kept the newest rows only (row cap reached): counts before ${day(d.complete_from)} are incomplete.`}</CxStat>}
      <div className="al-tiles">
        <Tile l="Objects touched" v={fmtInt(d.objects)} s={`tables, views and stages · ${plural(d.users, "user")}`} />
        <Tile l="People off hours" v={d.hours_available ? fmtInt(d.people_off_hours) : "–"} warn={d.people_off_hours > 0}
          s={d.hours_available ? `on ${plural(d.objects_off_hours, "object")} · ${utc(off)}` : "the hours check did not run"} />
        <Tile l="Busiest object" v={d.busiest ? <span className="cx-code">{String(d.busiest.object_fqn).split(".").pop()}</span> : "–"} mono
          s={d.busiest ? `${fmtInt(d.busiest.queries)} queries · ${plural(d.busiest.users, "user")}` : undefined} />
        <Tile l="Queries" v={fmtInt(d.queries)} s="reads, writes and DDL in the window" />
      </div>

      <ChartCard title="Off-hours use by people" subtitle={`Queries by people outside ${hh(s.start)}–${hh(s.end)} ${utc(off)} or at weekends · service users and pipelines left out · sensitive and changes first`} takeaway={null}>
        {!d.hours_available ? <CxStat>– Not in this export: run it again with sf_use_access_hours.</CxStat> : !people.length
          ? <CxStat>{`No person used an object outside business hours in ${day(d.start)}–${day(d.end)}.`}</CxStat> : (
          <div className="cj-charts-2" style={{ alignItems: "start" }}>
            <div>
              {people.slice(0, 8).map((u) => (
                <div key={u.user_name} className="al-person">
                  <div className="al-person-h"><b><button type="button" className="ax-namebtn" onClick={() => go("person", u.user_name)}>{u.user_name}</button></b><span>{`${fmtInt(u.off_hours)} off-hours queries`}</span></div>
                  {u.objects.slice(0, 4).map((o: Row) => (
                    <div key={o.object_fqn} className="al-orow">
                      <span><button type="button" className="ax-namebtn" onClick={() => go("object", o.object_fqn)}><CxObjName full={String(o.object_fqn)} /></button>{o.sensitive && <span className="al-chip d">sensitive</span>}</span>
                      <span className="al-bar"><i style={{ width: `${(100 * numOrZero(o.off_hours)) / maxOff}%` }} /></span>
                      <span>{fmtInt(o.off_hours)}</span>
                      <span className="al-meta">{`${o.statements} · ${o.roles}`}</span>
                      <span className="al-meta">{day(o.last_day)}</span>
                    </div>
                  ))}
                  {u.objects.length > 4 && <div className="al-meta" style={{ paddingLeft: 12 }}>{`+${u.objects.length - 4} more objects`}</div>}
                </div>
              ))}
              {people.length > 8 && <div className="al-meta">{`Showing 8 of ${plural(people.length, "person")}.`}</div>}
            </div>
            {d.heat_objects.length > 0 && (
              <div>
                <div className="al-meta" style={{ marginBottom: 6 }}>Who touched which sensitive object off hours · – no grant path</div>
                <table className="al-heat">
                  <thead><tr><th />{d.heat_objects.map((f: string) => <th key={f} title={f}>{f.split(".").pop()}</th>)}</tr></thead>
                  <tbody>{d.heat.map((r: Row) => (
                    <tr key={r.user_name}><td className="u">{r.user_name}</td>{r.cells.map((v: any, i: number) => (
                      <td key={i} style={v ? { background: `color-mix(in srgb, var(--st-warn) ${Math.round(15 + (70 * v) / heatMax)}%, transparent)` } : undefined}>
                        {v == null ? "–" : v === 0 ? "·" : fmtInt(v)}
                      </td>))}</tr>))}</tbody>
                </table>
              </div>
            )}
          </div>
        )}
      </ChartCard>

      {d.hours_available && hours.length > 0 && (
        <ChartCard title="Hours of use" subtitle={`People's queries by hour of day, ${utc(off)} · shaded = business hours · amber = off hours (weekends count as off)`} takeaway={null}>
          <div>
            <div className="al-hours"><span /><div className="al-haxis">{Array.from({ length: 24 }, (_, h) => <span key={h}>{h % 6 === 0 ? h : ""}</span>)}</div><span className="al-meta" style={{ textAlign: "right" }}>off share</span></div>
            {hours.slice(0, 12).map((u) => (
              <div key={u.user_name} className="al-hours">
                <button type="button" className="ax-namebtn" onClick={() => go("person", u.user_name)}>{u.user_name}</button>
                <HourBars on={u.on} off={u.off} startH={s.start} endH={s.end} max={hMax} />
                <span className={`al-share${(u.off_share || 0) >= 0.3 ? " hi" : ""}`}>{u.off_share == null ? "–" : `${Math.round(u.off_share * 100)}%`}</span>
              </div>
            ))}
          </div>
        </ChartCard>
      )}

      <ChartCard title="Objects, busiest first" subtitle="Queries in the window · select a row for its detail" takeaway={null}>
        <div className="al-pick" style={{ marginBottom: 8 }}><Seg label="Which objects" value={onlySens ? "s" : "a"} options={[["a", "All"], ["s", "Sensitive"]]} onPick={(v) => setOnlySens(v === "s")} /></div>
        {objs.loading ? <CxStat>…</CxStat> : (
          <CxTable ariaLabel="Objects, busiest first" n={10}
            cols={[{ label: "Object" }, { label: "Kind" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Users", num: true }, { label: "Clients", num: true }, { label: "Last", num: true }]}
            rows={list.map((o) => ({
              key: String(o.object_fqn), onClick: () => go("object", String(o.object_fqn)),
              cells: [<span><CxObjName full={String(o.object_fqn)} />{o.sensitive && <span className="al-chip d">{o.sensitive === "tagged" ? "sensitive" : "looks sensitive"}</span>}</span>,
                String(o.object_domain || "").toLowerCase(), fmtInt(numOrZero(o.reads)), fmtInt(numOrZero(o.writes)), fmtInt(numOrZero(o.ddl)),
                fmtInt(numOrZero(o.users)), fmtInt(numOrZero(o.clients)), day(o.last_at)],
            }))} />
        )}
      </ChartCard>
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
      <input className="ax-input wide" value={typed} placeholder={name || "Type a table, view or stage name"} aria-label="Object name"
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
  const who: Row[] = (d?.who || []).filter((w: Row) => !people || w.is_person);
  const writes = new Set<string>(["INSERT", "UPDATE", "DELETE", "MERGE", "COPY", "CREATE_TABLE_AS_SELECT", "TRUNCATE_TABLE", "UNLOAD"]);
  return (
    <>
      <div className="al-pick"><ObjectPicker p={p} name={obj} onPick={onPick} />{lg.loading && <span className="cx-muted">…</span>}</div>
      {lg.err && <CxStat>{`– ${lg.err}`}</CxStat>}
      {!obj && !top.loading && <CxStat>No object was read or changed in this window.</CxStat>}
      {d && (
        <>
          <div className="eyebrow al-meta">{"Object detail"}</div>
          <h3 style={{ margin: "0 0 4px" }}><CxObjName full={obj} /> {d.sensitive && <span className="al-chip d">{d.sensitive === "tagged" ? "sensitive" : "looks sensitive"}</span>}</h3>
          <div className="al-tiles">
            <Tile l="Reads" v={fmtInt(numOrZero(t.reads))} s={`${plural(numOrZero(t.users), "user")} · ${plural(numOrZero(t.roles), "role")}`} />
            <Tile l="Writes" v={fmtInt(numOrZero(t.writes))} s="INSERT, UPDATE, MERGE, COPY…" />
            <Tile l="DDL" v={fmtInt(numOrZero(t.ddl))} s={t.ddl_operations || "CREATE, ALTER, DROP…"} warn={numOrZero(t.ddl) > 0} />
            <Tile l="Clients" v={fmtInt(numOrZero(t.clients))} s={t.client_list} />
          </div>
          <PerDay d={d} title={`Queries per day, by ${split}`} sub="Every day of the window · stacked, the top 6 and Other" />
          <div className="al-pick" style={{ marginTop: -8 }}><Seg label="Split by" value={split} options={[["user", "User"], ["role", "Role"], ["client", "Client"], ["statement", "Statement"], ["action", "Read / write / DDL"]]} onPick={setSplit} /></div>
          <div className="cj-charts-2">
            <ChartCard title={`Queries by ${by}`} subtitle="Writes, reads and DDL summed per row · sorted by volume" takeaway={null}>
              <div className="al-pick" style={{ marginBottom: 8 }}><Seg label="Group by" value={by} options={[["client", "Client"], ["role", "Role"], ["user", "User"]]} onPick={setBy} /></div>
              {byRows.slice(0, 8).map((r) => {
                const tot = numOrZero(r.reads) + numOrZero(r.writes) + numOrZero(r.ddl);
                return (
                  <div key={String(r.k)} className="al-orow" style={{ gridTemplateColumns: "minmax(0,1.4fr) minmax(0,2fr) 50px", paddingLeft: 0 }}>
                    <span><b className="cx-code">{String(r.k)}</b><br /><span className="al-meta">{`${plural(numOrZero(r.users), "user")} · ${r.roles}`}</span></span>
                    <span className="al-hbar3" style={{ width: `${(100 * tot) / byMax}%` }}>
                      <i className="w" style={{ width: `${(100 * numOrZero(r.writes)) / (tot || 1)}%` }} /><i className="r" style={{ width: `${(100 * numOrZero(r.reads)) / (tot || 1)}%` }} /><i className="d" style={{ width: `${(100 * numOrZero(r.ddl)) / (tot || 1)}%` }} />
                    </span>
                    <span style={{ textAlign: "right" }}>{fmtInt(tot)}</span>
                  </div>
                );
              })}
              <div className="al-key"><span><i style={{ background: "var(--c1)" }} />Writes</span><span><i style={{ background: "var(--c2)" }} />Reads</span><span><i style={{ background: "var(--c3)" }} />DDL</span></div>
            </ChartCard>
            <ChartCard title="Statement kinds" subtitle="Queries per statement type · user, role and client combinations that ran it" takeaway={null}>
              <CxTable ariaLabel="Statement kinds" n={10}
                cols={[{ label: "Statement" }, { label: "Kind" }, { label: "Queries", num: true }, { label: "Combinations", num: true }]}
                rows={(d.statements as Row[]).map((r) => ({
                  key: String(r.k),
                  cells: [<span className={`al-chip${writes.has(String(r.k)) ? " w" : numOrZero(r.ddl) ? " d" : ""}`}>{String(r.k)}</span>,
                    numOrZero(r.ddl) ? "DDL" : numOrZero(r.writes) ? "write" : "read", fmtInt(numOrZero(r.queries)), fmtInt(numOrZero(r.combos))],
                }))} />
            </ChartCard>
          </div>
          {roles.length > 0 && (
            <ChartCard title="Role × client" subtitle="Queries in each cell · row and column totals" takeaway={null}>
              <table className="al-heat" style={{ width: "100%" }}>
                <thead><tr><th style={{ textAlign: "left" }}>Role</th>{clients.map((cl) => <th key={cl}>{cl}</th>)}<th>Total</th></tr></thead>
                <tbody>{roles.map((r) => (
                  <tr key={r}><td className="u">{r}</td>{clients.map((cl) => { const v = cell(r, cl); return (
                    <td key={cl} style={v ? { background: `color-mix(in srgb, var(--c1) ${Math.round(10 + (70 * v) / mMax)}%, transparent)` } : undefined}>{v ? fmtInt(v) : "–"}</td>); })}
                    <td><b>{fmtInt(clients.reduce((x, cl) => x + cell(r, cl), 0))}</b></td></tr>))}
                  <tr><td className="u"><b>Total</b></td>{clients.map((cl) => <td key={cl}><b>{fmtInt(roles.reduce((x, r) => x + cell(r, cl), 0))}</b></td>)}<td /></tr>
                </tbody>
              </table>
            </ChartCard>
          )}
          <ChartCard title="Who used it" subtitle={`One row per user, role and client · off hours at ${utc(off)} for people`} takeaway={null}>
            <div className="al-pick" style={{ marginBottom: 8 }}><Seg label="Who" value={people ? "p" : "a"} options={[["a", "Everyone"], ["p", "People only"]]} onPick={(v) => setPeople(v === "p")} /></div>
            <CxTable ariaLabel={`Who used ${obj}`} n={15}
              cols={[{ label: "User" }, { label: "Role · client" }, { label: "Statements" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Off hours", num: true }, { label: "Days", num: true }, { label: "First → last" }]}
              rows={who.map((w, i) => ({
                key: `${w.user_name}|${w.role_name}|${w.client}|${i}`, status: numOrZero(w.off_hours) > 0 || numOrZero(w.ddl) > 0 ? "WARN" : undefined,
                cells: [<span><button type="button" className="ax-namebtn" onClick={() => go("person", String(w.user_name))}>{String(w.user_name)}</button><br /><span className="al-meta">{w.is_person ? "person" : String(w.user_type || "").toLowerCase().replace(/_/g, " ")}</span></span>,
                  <span>{String(w.role_name)}<br /><span className="al-meta">{String(w.client)}</span></span>,
                  <Chips list={[w.statements, w.ddl_operations].filter(Boolean).join(", ")} write={writes} />,
                  fmtInt(numOrZero(w.reads)), fmtInt(numOrZero(w.writes)), fmtInt(numOrZero(w.ddl)),
                  w.off_hours == null ? "–" : fmtInt(w.off_hours), fmtInt(numOrZero(w.days)), `${day(w.first_at)} → ${day(w.last_at)}`],
              }))} />
          </ChartCard>
          <ChartCard title="Every query, one by one" subtitle="Run in Snowflake for the query ids and times behind these counts (no query text)" takeaway={null}>
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
          </ChartCard>
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
          <div className="al-tiles">
            <Tile l="Reads" v={fmtInt(numOrZero(t.reads))} s={`${plural(numOrZero(t.objects), "object")}`} />
            <Tile l="Writes" v={fmtInt(numOrZero(t.writes))} />
            <Tile l="DDL" v={fmtInt(numOrZero(t.ddl))} warn={numOrZero(t.ddl) > 0} />
            <Tile l="Roles · clients" v={`${fmtInt(numOrZero(t.roles))} · ${fmtInt(numOrZero(t.clients))}`} s={t.client_list} />
            <Tile l="Off hours" v={d.hours ? fmtInt(d.hours.off.reduce((a: number, b: number) => a + b, 0)) : "–"} warn={!!d.hours && d.hours.off.some((v: number) => v > 0)}
              s={d.hours ? utc(off) : t.is_person ? "the hours check did not run" : "not a person: not judged"} />
          </div>
          {d.hours && (
            <ChartCard title="Hours of use" subtitle={`Queries by hour of day, ${utc(off)} · shaded = business hours · amber = off hours`} takeaway={null}>
              <HourBars on={d.hours.on} off={d.hours.off} startH={s.start} endH={s.end} max={Math.max(1, ...d.hours.on.map((v: number, i: number) => v + d.hours.off[i]))} />
              <div className="al-haxis">{Array.from({ length: 24 }, (_, h) => <span key={h}>{h % 3 === 0 ? h : ""}</span>)}</div>
            </ChartCard>
          )}
          <PerDay d={d} title={`Queries per day, by ${split}`} sub="Every day of the window · stacked, the top 6 and Other" />
          <div className="al-pick" style={{ marginTop: -8 }}><Seg label="Split by" value={split} options={[["object", "Object"], ["role", "Role"], ["client", "Client"], ["statement", "Statement"], ["action", "Read / write / DDL"]]} onPick={setSplit} /></div>
          <ChartCard title="Objects used" subtitle="One row per object · select a row for its detail" takeaway={null}>
            <CxTable ariaLabel="Objects used" n={15}
              cols={[{ label: "Object" }, { label: "Statements" }, { label: "Reads", num: true }, { label: "Writes", num: true }, { label: "DDL", num: true }, { label: "Roles · clients" }, { label: "Days", num: true }, { label: "Last", num: true }]}
              rows={(d.objects as Row[]).map((o) => ({
                key: String(o.object_fqn), onClick: () => go("object", String(o.object_fqn)), status: numOrZero(o.ddl) > 0 ? "WARN" : undefined,
                cells: [<span><CxObjName full={String(o.object_fqn)} />{o.sensitive && <span className="al-chip d">sensitive</span>}</span>, <Chips list={o.statements} />,
                  fmtInt(numOrZero(o.reads)), fmtInt(numOrZero(o.writes)), fmtInt(numOrZero(o.ddl)),
                  <span className="al-meta">{`${o.roles} · ${o.clients}`}</span>, fmtInt(numOrZero(o.days)), day(o.last_at)],
              }))} />
          </ChartCard>
        </>
      )}
    </>
  );
}
