// web/src/components/area_lineage_explorer.tsx -- Lineage › Explorer: pick a table or view and see everything
// upstream and downstream, walked in the browser from sf_lin_declared_links and sf_lin_copied_links.
import React from "react";
import { fmtDayShort, fmtInt } from "../format";
import { numOrZero } from "./hooks";
import type { ApPageProps } from "./area_pages";
import { IssueTile } from "./blocks";
import { ChartCard } from "./primitives";
import { useCheck, useLede } from "./area_ai_storage";
import { NamePicker, RoleGraph } from "./area_access_explorer";
import type { Row } from "../types";
import { SummaryTileRow } from "./overview_tile";
import { CxChip, CxStat, CxTable } from "./cx_e";

const plural = (n: number, one: string) => `${fmtInt(n)} ${n === 1 ? one : `${one}s`}`;
const MAX_DEPTH = 8, MAX_PATHS = 400;   // keeps a very connected object readable; the tables still list every object
const NO_USERS = new Set<string>();

interface Link { from: string; to: string; declared: boolean; copied: boolean; columns: number; writers: number; last: string | null }
interface Reached { name: string; depth: number; link: Link }

function buildLinks(declared: Row[], copied: Row[]): Link[] {
  const m = new Map<string, Link>();
  const at = (from: string, to: string) => {
    const k = `${from}>${to}`;
    const cur = m.get(k) || { from, to, declared: false, copied: false, columns: 0, writers: 0, last: null };
    m.set(k, cur);
    return cur;
  };
  declared.forEach((r) => { at(String(r.source_fqn), String(r.target_fqn)).declared = true; });
  copied.forEach((r) => {
    const l = at(String(r.source_fqn), String(r.target_fqn));
    l.copied = true;
    l.columns = numOrZero(r.columns);
    l.writers = numOrZero(r.writers);
    l.last = r.last_written ? String(r.last_written) : null;
  });
  return [...m.values()];
}

/** Everything reached from `start` one way, nearest first, with the paths for the graph. Links can loop. */
function walk(start: string, next: Map<string, Link[]>, stepOf: (l: Link) => string) {
  const seen = new Map<string, Reached>();
  const paths: string[][] = [];
  let capped = false;
  const go = (at: string, path: string[]) => {
    const links = next.get(at) || [];
    if (!links.length || path.length > MAX_DEPTH) { if (path.length > 1) paths.push(path); return; }
    links.forEach((l) => {
      const to = stepOf(l);
      if (path.includes(to)) return;
      const cur = seen.get(to);
      if (!cur || path.length < cur.depth) seen.set(to, { name: to, depth: path.length, link: l });
      if (paths.length >= MAX_PATHS) { capped = true; return; }
      go(to, [...path, to]);
    });
  };
  go(start, [start]);
  return { reached: [...seen.values()].sort((a, b) => a.depth - b.depth || a.name.localeCompare(b.name)), paths, capped };
}

function ReachTable({ title, rows, onPick }: { title: string; rows: Reached[]; onPick: (n: string) => void }) {
  return (
    <CxTable ariaLabel={title} n={15}
      cols={[{ label: "Object" }, { label: "Steps", num: true }, { label: "Link" }, { label: "Columns", num: true }, { label: "Writers", num: true }, { label: "Last written", num: true }]}
      foot={`${plural(rows.length, "object")}. Columns, writers and last written describe the nearest link, for copies in this window.`}
      rows={rows.map((r) => ({
        key: r.name,
        cells: [<button type="button" className="ax-namebtn" onClick={() => onPick(r.name)}>{r.name}</button>, fmtInt(r.depth),
          <span>{r.link.declared && <CxChip>declared</CxChip>}{r.link.copied && <CxChip status="OK">copied</CxChip>}</span>,
          r.link.copied ? fmtInt(r.link.columns) : "–", r.link.copied ? fmtInt(r.link.writers) : "–",
          r.link.last ? fmtDayShort(r.link.last.slice(0, 10)) : "–"],
      }))} />
  );
}

export function ApLineageExplorer(p: ApPageProps) {
  const dec = useCheck(p, "sf_lin_declared_links", true);
  const cop = useCheck(p, "sf_lin_copied_links", true);
  const loading = dec.loading || cop.loading;
  const links = React.useMemo(() => buildLinks(dec.rows || [], cop.rows || []), [dec.rows, cop.rows]);
  const graph = React.useMemo(() => {
    const down = new Map<string, Link[]>(), up = new Map<string, Link[]>();
    links.forEach((l) => {
      down.set(l.from, [...(down.get(l.from) || []), l]);
      up.set(l.to, [...(up.get(l.to) || []), l]);
    });
    return { down, up };
  }, [links]);
  // Busiest first, so the page opens on something worth reading.
  const names = React.useMemo(() => {
    const count = (n: string) => (graph.down.get(n)?.length || 0) + (graph.up.get(n)?.length || 0);
    return [...new Set(links.flatMap((l) => [l.from, l.to]))].sort((a, b) => count(b) - count(a) || a.localeCompare(b));
  }, [links, graph]);
  const [picked, setPicked] = React.useState("");
  const name = picked && names.includes(picked) ? picked : names[0] || "";
  const res = React.useMemo(() => {
    if (!name) return null;
    const upstream = walk(name, graph.up, (l) => l.from);
    const downstream = walk(name, graph.down, (l) => l.to);
    // One path per line of the graph: reading left to right is always "feeds".
    const paths = [...upstream.paths.map((x) => [...x].reverse()), ...downstream.paths];
    return { upstream, downstream, paths };
  }, [name, graph]);

  useLede(p, loading, names.length ? `${plural(names.length, "object")} joined by ${plural(links.length, "lineage link")}. Pick one to see what it is built from and what it feeds.` : null);

  const blocked = !loading && !dec.rows?.length && !cop.rows?.length;
  const copyGap = !loading && !cop.rows?.length && !!dec.rows?.length;
  return (
    <div className="ais-page cx-e">
      <div className="ax-bar">
        <NamePicker kind="object" names={{ objects: names.map((n) => ({ name: n })) }} value={name} onPick={setPicked} />
        {loading && <span className="cx-muted">…</span>}
      </div>
      {blocked && <CxStat>{`– ${dec.why || cop.why || "No lineage links in this export."}`}</CxStat>}
      {copyGap && <CxStat>{`Declared links only. Copies between tables: ${cop.why || "none in this window."}`}</CxStat>}
      {res && (
        <SummaryTileRow compact>
          <IssueTile label="Built from" headline={fmtInt(res.upstream.reached.length)} unit=" objects" status="neutral"
            base={`${fmtInt(res.upstream.reached.filter((r) => r.depth === 1).length)} directly`} />
          <IssueTile label="Feeds" headline={fmtInt(res.downstream.reached.length)} unit=" objects" status="neutral"
            base={`${fmtInt(res.downstream.reached.filter((r) => r.depth === 1).length)} directly`} />
          <IssueTile label="Levels" headline={fmtInt(Math.max(0, ...res.upstream.reached.map((r) => r.depth)))} unit={` up, ${fmtInt(Math.max(0, ...res.downstream.reached.map((r) => r.depth)))} down`} status="neutral"
            base="Steps to the furthest object each way" />
        </SummaryTileRow>
      )}
      {res && res.paths.length > 0 && (
        <ChartCard title={`Lineage of ${name}`} subtitle={`Arrow = feeds · select a box to explore it${res.upstream.capped || res.downstream.capped ? ` · the first ${fmtInt(MAX_PATHS)} paths each way` : ""}`} takeaway={null}>
          <RoleGraph key={name} paths={res.paths} focus={name} users={NO_USERS} objects={NO_USERS} onPick={(_k, n) => setPicked(n)}
            shortName={(x) => x.split(".").slice(-2).join(".")}
            laneName={(l) => (l === 0 ? "This object" : l < 0 ? `${-l} ${l === -1 ? "step" : "steps"} up` : `${l} ${l === 1 ? "step" : "steps"} down`)} />
        </ChartCard>
      )}
      {res && res.upstream.reached.length > 0 && (
        <ChartCard title="What it is built from" subtitle="Every object upstream, nearest first" takeaway={null}>
          <ReachTable title="Upstream objects" rows={res.upstream.reached} onPick={setPicked} />
        </ChartCard>
      )}
      {res && res.downstream.reached.length > 0 && (
        <ChartCard title="What it feeds" subtitle="Every object downstream: what a change to it can break" takeaway={null}>
          <ReachTable title="Downstream objects" rows={res.downstream.reached} onPick={setPicked} />
        </ChartCard>
      )}
    </div>
  );
}
(ApLineageExplorer as any).ownsTiles = true;
(ApLineageExplorer as any).ownsLede = true;
