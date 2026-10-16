// web/src/components/tag_rollup.tsx -- the cost-by-tag rollup, `window.TagRollupView`. Reads
// GET /api/rollup and GET /api/rollup/keys (the API resolves each row's tag in this order: query
// tag, object tag, warehouse tag, user or role tag, account tag; the first level that has one wins,
// so a dollar is counted once). Spend with no tag at any level reads "Untagged", never dropped.
// When the export carried no tags the view says so ("-" and why), never $0.
import React from "react";
import { ACCOUNT_PARAM, Api, ROLLUP_ACCOUNT_FILTERED, ROLLUP_ACCOUNT_LEVEL } from "../api";
import { estLabel, fmtInt, fmtMoney, fmtPct } from "../format";
import { acctPhrase, resolveName } from "./names";
import { numOrZero } from "./hooks";
import { Facts, priceLabelOf } from "./primitives";
import { ChartNote } from "./charts";
import { windowFacts } from "./overview_tile";
import type { Filters, Meta, Row } from "../types";


export function tagRollupQs(params: Record<string, any> | null | undefined) {
  const parts: string[] = [];
  Object.keys(params || {}).forEach((key) => {
    const value = params![key];
    if (value === undefined || value === null || value === "") return;
    if (Array.isArray(value)) {
      value.forEach((v: any) => parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(v)}`));
    } else {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
    }
  });
  return parts.length ? `?${parts.join("&")}` : "";
}

export async function tagRollupFetch(path: string, params: Record<string, any> | null | undefined) {
  const res = await fetch(path + tagRollupQs(params), { headers: { Accept: "application/json" } });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const body = await res.json();
      detail = body.detail || detail;
    } catch (e) { /* not JSON */ }
    const err = new Error(`${res.status} ${detail}`) as Error & { status?: number };
    err.status = res.status;
    throw err;
  }
  return res.json();
}

export function useRollupKeys(area: string, windowDays: number) {
  const [state, setState] = React.useState<{ phase: string; keys: Row[] }>({ phase: "loading", keys: [] });
  React.useEffect(() => {
    let alive = true;
    setState({ phase: "loading", keys: [] });
    tagRollupFetch("/api/rollup/keys", { area, window: windowDays })
      .then((body) => { if (alive) setState({ phase: "ready", keys: body.keys || [] }); })
      .catch(() => { if (alive) setState({ phase: "error", keys: [] }); });
    return () => { alive = false; };
  }, [area, windowDays]);
  return state;
}

export function useRollupData(area: string, tagKey: string | null | undefined, windowDays: number, accountIds: string[] | null | undefined, tagValue: string | null | undefined) {
  const [state, setState] = React.useState<{ phase: string; data: any; error?: any }>({ phase: "loading", data: null });
  const depKey = JSON.stringify({ area, tagKey, windowDays, accountIds, tagValue, tag: Api.tagFilterKey() });
  React.useEffect(() => {
    if (!tagKey) { setState({ phase: "ready", data: null }); return undefined; }
    let alive = true;
    setState({ phase: "loading", data: null });
    tagRollupFetch("/api/rollup", {
      area, tag_key: tagKey, window: windowDays, tag_value: tagValue,
      [ACCOUNT_PARAM]: accountIds,
      ...Api.tagParams(),
    })
      .then((body) => { if (alive) setState({ phase: "ready", data: body }); })
      .catch((err) => { if (alive) setState({ phase: "error", data: null, error: err }); });
    return () => { alive = false; };
  }, [depKey]); // eslint-disable-line react-hooks/exhaustive-deps
  return state;
}

// The level a dollar was counted at, in Snowflake words (the API's own level keys are older).
export const ROLLUP_LEVEL_LABEL: Record<string, string> = { work: "query tag", compute: "warehouse tag", [ROLLUP_ACCOUNT_LEVEL]: "account tag", account: "account" };

export function normalizeTagKeyLike(raw: any) {
  return String(raw || "").toLowerCase().replace(/[ _-]+/g, "");
}

// useCostCenterSettingState -- GET /api/settings/cost-center once: the tag keys the team says mean
// "cost center".
export function useCostCenterSettingState() {
  const [state, setState] = React.useState<{ phase: string; keys: string[]; default: string[]; isDefault: boolean }>({ phase: "loading", keys: [], default: [], isDefault: true });
  React.useEffect(() => {
    let alive = true;
    tagRollupFetch("/api/settings/cost-center", {})
      .then((body) => {
        if (!alive) return;
        const keys = (body && body.keys) || [];
        const def = (body && body.default) || [];
        const isDefault = JSON.stringify(keys.map(normalizeTagKeyLike)) === JSON.stringify(def.map(normalizeTagKeyLike));
        setState({ phase: "ready", keys, default: def, isDefault });
      })
      .catch(() => { if (alive) setState({ phase: "error", keys: [], default: [], isDefault: true }); });
    return () => { alive = false; };
  }, []);
  return state;
}

// useCostCenterAllocation -- the "Spend by cost center" / "No cost center" figures. Reads the
// rollup's own `by_value`, the same one-dollar-basis walk its `total` reconciles to (each unit's
// spend counted at exactly one attributed value), so two cards never show two different numbers for
// the same cost center.
export function useCostCenterAllocation(filters: Filters) {
  const settings = useCostCenterSettingState();
  const active = settings.phase !== "loading";
  const depKey = JSON.stringify({ active, window: filters.window, accountIds: filters.accountIds, tag: Api.tagFilterKey() });
  const [state, setState] = React.useState<{ phase: string; outcome: any; data: any; error: string | null }>({ phase: "loading", outcome: null, data: null, error: null });
  React.useEffect(() => {
    if (!active) { setState({ phase: "loading", outcome: null, data: null, error: null }); return undefined; }
    let alive = true;
    setState({ phase: "loading", outcome: null, data: null, error: null });
    tagRollupFetch("/api/rollup", {
      area: "cost", tag_key: "cost_center", window: filters.window,
      [ACCOUNT_PARAM]: filters.accountIds,
      ...Api.tagParams(),
    })
      .then((body) => { if (alive) setState({ phase: "ready", outcome: body.outcome, data: body, error: null }); })
      .catch((err) => { if (alive) setState({ phase: "error", outcome: null, data: null, error: err.message || String(err) }); });
    return () => { alive = false; };
  }, [depKey]); // eslint-disable-line react-hooks/exhaustive-deps
  return { settingsReady: active, active, phase: state.phase, outcome: state.outcome, data: state.data, error: state.error };
}

// Why the rollup has nothing: the export carried no tags, or none carry this key. Never a $0.
export function rollupNote(data: Row | null | undefined, area: string) {
  const noun = area === "cost" ? "spend" : "statements";
  if (!data) return null;
  if (data.outcome === "not_assessed") {
    return /tag_models_not_built|not built/i.test(String(data.not_assessed_reason || ""))
      ? "Not assessed: the tag rollup is not in this export. Tags are read from TAG_REFERENCES and QUERY_TAG, so the role needs to see them; run the export again once it does."
      : `Not assessed: ${data.not_assessed_reason}`;
  }
  if (data.outcome === "ok_empty_window") return `No ${noun} carrying this key in this window.`;
  if (data.outcome === "ok_empty_filters") return `No ${noun} carrying this key under the current filters.`;
  return null;
}

// "The split ties to the bill": the rollup's own reconciliation (cost only). null for a rollup that was
// not assessed. Never worded as a pass when the two totals differ.
export function reconciliationLine(recon: Row | null | undefined) {
  if (!recon || recon.billing_usd == null || recon.rollup_usd == null) return null;
  // $0 billed and $0 split is a table that was not read, not a tie; a split with no bill cannot tie.
  if (!numOrZero(recon.billing_usd)) return null;
  // Spend the split never covers (storage, transfer) is named, so spend and split tie in one line.
  const outside = numOrZero(recon.outside_split_usd) > 0 && recon.spend_usd != null
    ? ` · spend ${fmtMoney(recon.spend_usd, 0)} = split ${fmtMoney(recon.billing_usd, 0)} + storage & transfer ${fmtMoney(recon.outside_split_usd, 0)}`
    : "";
  if (recon.reconciled) return { tone: "ok", text: `Ties to the bill: yes (${fmtMoney(recon.billing_usd, 0)} billed = ${fmtMoney(recon.rollup_usd, 0)} split)${outside}` };
  return { tone: "crit", text: `Ties to the bill: off by ${fmtMoney(Math.abs(numOrZero(recon.difference_usd)), 0)} (${fmtMoney(recon.billing_usd, 0)} billed, ${fmtMoney(recon.rollup_usd, 0)} split)${outside}` };
}

// A compute-level resource (a warehouse) as "NAME (id)", never a bare id.
export function rollupResourceName(kind: string, id: any) {
  if (kind === "warehouse") return `${resolveName("warehouse", null, id) || id} (${id})`;
  return String(id);
}

interface TagRollupTreeRowProps {
  node: Row;
  depth: number;
  area: string;
  primaryMetric: string;
  expanded: Set<string>;
  onToggle: (id: string) => void;
}

export function TagRollupTreeRow({ node, depth, area, primaryMetric, expanded, onToggle }: TagRollupTreeRowProps) {
  const isOpen = expanded.has(node.id);
  const hasChildren = node.children && node.children.length > 0;
  const fmt = (m: Row) => (area === "cost" ? fmtMoney(numOrZero(m[primaryMetric]), 0) : fmtInt(numOrZero(m[primaryMetric])));
  const untagged = numOrZero(node.untagged && node.untagged[primaryMetric]);
  const detail = isOpen ? [
    ...(node.workspaces || []).map((w: Row) => ({ key: `a:${w.account_id}`, name: acctPhrase(w.account_id), m: w.metrics })),
    ...(node.resources || []).map((r: Row) => ({ key: `r:${r.compute_id}`, name: rollupResourceName(r.compute_kind, r.compute_id), m: r.metrics })),
  ] : [];
  return (
    <React.Fragment>
      <div className="hbar-list-row" style={{ paddingLeft: depth * 16 }}>
        <div className="hbar-list-label" style={{ display: "flex", alignItems: "center", gap: 6 }}>
          {hasChildren || detail.length || node.workspaces || node.resources ? (
            <button type="button" className="tag-rollup-toggle" onClick={() => onToggle(node.id)}
              style={{ background: "none", border: "none", cursor: "pointer", padding: 0, width: 14, color: "inherit" }}>
              {isOpen ? "▾" : "▸"}
            </button>
          ) : <span style={{ display: "inline-block", width: 14 }} />}
          <span title={node.reason || ""}>{node.label}</span>
          {node.source_label && <span className="faint" style={{ fontSize: 11 }}>{`(${node.source_label})`}</span>}
          {untagged > 0 && <span className="faint" style={{ fontSize: 11 }}>{`untagged inside ${area === "cost" ? fmtMoney(untagged, 0) : fmtInt(untagged)}`}</span>}
        </div>
        <div />
        <div className="mono">
          {fmt(node.metrics)}
          {node.share_of_parent != null && <span className="faint" style={{ marginLeft: 6 }}>{`${fmtPct(numOrZero(node.share_of_parent) * 100, 0)} of parent`}</span>}
        </div>
      </div>
      {detail.map((d) => (
        <div key={d.key} className="hbar-list-row faint" style={{ paddingLeft: (depth + 1) * 16 + 20 }}>
          <div className="hbar-list-label">{d.name}</div>
          <div />
          <div className="mono">{fmt(d.m)}</div>
        </div>
      ))}
      {hasChildren && isOpen && node.children.map((c: Row) => (
        <TagRollupTreeRow key={c.id} node={c} depth={depth + 1} area={area} primaryMetric={primaryMetric} expanded={expanded} onToggle={onToggle} />
      ))}
    </React.Fragment>
  );
}

export function TagRollupByValueTable({ byValue, area, primaryMetric, fmtV }: { byValue: Row[] | null | undefined; area: string; primaryMetric: string; fmtV: (v: any) => string }) {
  if (!byValue || !byValue.length) return <div className="chart-note-oneline">No values for this key in this window.</div>;
  return (
    // Scrolls in its own box, so a phone-width page never scrolls sideways.
    <div style={{ overflowX: "auto", maxWidth: "100%" }}>
    <table className="tag-rollup-table" style={{ width: "100%", fontSize: 12, borderCollapse: "collapse" }}>
      <thead>
        <tr className="faint">
          <th style={{ textAlign: "left" }}>Value</th>
          <th style={{ textAlign: "right" }}>{area === "cost" ? "$" : "Statements"}</th>
          <th style={{ textAlign: "right" }}>Share</th>
          <th style={{ textAlign: "left" }}>Tag comes from</th>
          <th style={{ textAlign: "right" }}>Overrides a wider tag</th>
        </tr>
      </thead>
      <tbody>
        {byValue.map((e: Row) => {
          const v = numOrZero(e.metrics[primaryMetric]);
          const ov = numOrZero(e.overrides_outer && e.overrides_outer[primaryMetric]);
          const countedBy = ["work", "compute", ROLLUP_ACCOUNT_LEVEL, "account"]
            .filter((lvl: string) => e.by_level && e.by_level[lvl] && numOrZero(e.by_level[lvl][primaryMetric]) > 0)
            .map((lvl: string) => ROLLUP_LEVEL_LABEL[lvl])
            .join(", ");
          return (
            <tr key={e.value}>
              <td>{e.value === "__untagged__" ? "Untagged" : e.label}</td>
              <td className="mono" style={{ textAlign: "right" }}>{fmtV(v)}</td>
              <td className="mono" style={{ textAlign: "right" }}>{fmtPct(numOrZero(e.share_of_total) * 100, 1)}</td>
              <td className="faint">{countedBy || "-"}</td>
              <td className="mono" style={{ textAlign: "right" }}>{ov > 0 ? fmtV(ov) : "-"}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
    </div>
  );
}

// How many levels a rollup tree has below its root (0 for a bare root).
export function rollupTreeDepth(node: Row | null | undefined): number {
  if (!node || !node.children || !node.children.length) return 0;
  return 1 + Math.max(...node.children.map((c: Row) => rollupTreeDepth(c)));
}

// TagRollupView: pick a tag key, see the spend (or, in performance mode, the statements) by value,
// with what is untagged and the level each value came from.
export function TagRollupView({ filters, area: areaProp, meta }: { filters: Filters; area?: string | null; meta?: Meta | null }) {
  const [area, setArea] = React.useState(areaProp || "cost");
  React.useEffect(() => { if (areaProp) setArea(areaProp); }, [areaProp]);

  const keysState = useRollupKeys(area, filters.window);
  const fromFilter = filters && filters.tag && filters.tag.groups && filters.tag.groups[0];
  const [ownKey, setOwnKey] = React.useState<string | null>(null);
  const chosenKey = (fromFilter && fromFilter.key) || ownKey;
  React.useEffect(() => {
    if (!fromFilter && keysState.phase === "ready" && keysState.keys.length && !ownKey) {
      setOwnKey(keysState.keys[0].tag_key);
    }
  }, [keysState.phase, keysState.keys, fromFilter, ownKey]);

  const data = useRollupData(area, chosenKey, filters.window, filters.accountIds, null);
  const [view, setView] = React.useState("value");
  const [expanded, setExpanded] = React.useState(() => new Set<string>(["account"]));
  const onToggle = (id: string) => setExpanded((prev) => { const next = new Set(prev); if (next.has(id)) next.delete(id); else next.add(id); return next; });
  const winFacts = windowFacts(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days);
  const primaryMetric = area === "cost" ? "usd" : "statements";
  const fmtV = (v: any) => (area === "cost" ? fmtMoney(numOrZero(v), 0) : fmtInt(numOrZero(v)));

  const noKeys = keysState.phase === "ready" && keysState.keys.length === 0;
  const d: any = data.phase === "ready" ? data.data : null;
  const note = d ? rollupNote(d, area) : null;
  // A tree with one level is the by-value list again, and a one-branch tree looks broken: no toggle.
  const hasTree = !!(d && d.tree && rollupTreeDepth(d.tree) >= 2);
  const shownView = hasTree ? view : "value";

  return (
    <div>
      <div className="row wrap" style={{ gap: 12, alignItems: "center", marginBottom: 8 }}>
        {!fromFilter && (
          <select value={chosenKey || ""} onChange={(e: React.ChangeEvent<HTMLSelectElement>) => setOwnKey(e.target.value)} disabled={keysState.phase !== "ready" || !keysState.keys.length}>
            {keysState.phase === "ready" && keysState.keys.length
              ? keysState.keys.map((k) => <option key={k.tag_key} value={k.tag_key}>{k.display_key}</option>)
              : <option value="">
                  {keysState.phase === "loading" ? "Loading tag keys…"
                    : keysState.phase === "error" ? "Could not load tag keys"
                    : "No tags in this export"}
                </option>}
          </select>
        )}
        {fromFilter && <div className="mono">{fromFilter.display_key || fromFilter.key}</div>}
        {areaProp == null && (
          <div className="subtabs">
            <button className={area === "cost" ? "active" : ""} onClick={() => setArea("cost")}>Cost</button>
            <button className={area === "performance" ? "active" : ""} onClick={() => setArea("performance")}>Performance</button>
          </div>
        )}
      </div>

      {noKeys && !fromFilter && (
        <div className="chart-note not_assessed"><div className="chart-note-text">Not assessed: the tag rollup is not in this export. Tags are read from TAG_REFERENCES and QUERY_TAG; the role needs to see them, then run the export again.</div></div>
      )}
      {data.phase === "loading" && chosenKey && <ChartNote state={{ phase: "loading" }} label="rollup" />}
      {data.phase === "error" && <ChartNote state={{ phase: "error" }} label="rollup" />}
      {note && <div className="chart-note not_assessed"><div className="chart-note-text">{note}</div></div>}
      {d && d.outcome === "ok_rows" && (
        <div>
          <div className="chart-card" style={{ marginBottom: 10 }}>
            {(() => {
              const total = d.total || {};
              const untagged = (d.by_value || []).find((e: Row) => e.value === "__untagged__");
              const u = untagged ? numOrZero(untagged.metrics[primaryMetric]) : 0;
              const t = numOrZero(total[primaryMetric]);
              return (
                <div>
                  <div className="metric-label">{area === "cost" ? "Spend" : "Statements"}</div>
                  <div className="metric-value mono">{fmtV(t)}</div>
                  <Facts items={[
                    area === "cost" ? { label: "Basis", value: priceLabelOf(d) || estLabel(0) } : null,
                    ...winFacts,
                    { label: "Untagged", value: fmtV(u), detail: fmtPct(t ? (u / t) * 100 : 0, 0), tone: u > 0 ? "warn" : "ok" },
                    (() => { const r = area === "cost" ? reconciliationLine(d.reconciliation) : null; return r ? { label: "Split", value: r.text, tone: r.tone } : null; })(),
                  ].filter(Boolean)} />
                </div>
              );
            })()}
            {d.scope && d.scope[ROLLUP_ACCOUNT_FILTERED] && d.scope.excluded_account_level && (
              <div className="faint" style={{ fontSize: 11, marginTop: 4 }}>
                {`Spend with no account id is outside the Account filter and excluded from this total${area === "cost" ? ` (${fmtMoney(d.scope.excluded_account_level.usd, 0)})` : ""}.`}
              </div>
            )}
          </div>
          {d.cut_sources && d.cut_sources.length > 0 && (
            <div className="chart-note not_assessed"><div className="chart-note-text">
              {`The export cut ${d.cut_sources.join(", ")} at its row limit, so tagged ${area === "cost" ? "spend" : "statements"} can read low. Export again with a higher --max-rows.`}
            </div></div>
          )}
          <div className="row wrap" style={{ gap: 12, alignItems: "center", marginBottom: 6 }}>
            <div className="chart-card-title" style={{ margin: 0 }}>{shownView === "value" ? "By value" : "Where the tag was set"}</div>
            {hasTree && (
              <div className="subtabs">
                <button type="button" className={shownView === "value" ? "active" : ""} onClick={() => setView("value")}>By value</button>
                <button type="button" className={shownView === "tree" ? "active" : ""} onClick={() => setView("tree")}>Tree</button>
              </div>
            )}
          </div>
          {shownView === "value" ? (
            <TagRollupByValueTable byValue={d.by_value} area={area} primaryMetric={primaryMetric} fmtV={fmtV} />
          ) : d.tree ? (
            <div className="hbar-list">
              <TagRollupTreeRow node={d.tree} depth={0} area={area} primaryMetric={primaryMetric} expanded={expanded} onToggle={onToggle} />
            </div>
          ) : <div className="chart-note-oneline">No tree for this key in this window.</div>}
        </div>
      )}
    </div>
  );
}
