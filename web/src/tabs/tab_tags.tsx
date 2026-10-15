// web/src/tabs/tab_tags.tsx -- the Tags page: which warehouses, databases, users and roles miss the
// required cost tags (settings required_tag_keys), and how much spend each tag key reaches
// (GET /api/tags/compliance). A page that could not be built reads "-" and why, never zeros.
// Mounted by App.tsx's route for the tags page: <TagsPage filters={filters} windowDays={filters.window} />.
import React from "react";
import { Api } from "../api";
import { fmtInt, fmtMoney, fmtPct } from "../format";
import { IssueTile, StatusBars, fmtShare } from "../components/blocks";
import type { StatusBarItem } from "../components/blocks";
import { PatternCard } from "../components/primitives";
import { DrillTable, SplitBar } from "../components/drill_table";
import { scrollToAnchor } from "../components/overview_tile";
import { CsvButton } from "../components/csv";
import type { CsvColumn } from "../components/csv";
import type { Filters, Row } from "../types";


export const TAG_EXAMPLES_SHOWN = 5;

export function tagPlain(v: any) {
  if (v === null || v === undefined || v === "") return "-";
  if (typeof v === "object") {
    return Object.keys(v).map((k) => `${k} ${typeof v[k] === "object" ? "" : v[k]}`.trim()).join(", ") || "-";
  }
  return String(v);
}

export function tagUsdCell(v: any) {
  return v === null || v === undefined ? "-" : fmtMoney(v, 0);
}

export function tagNounFor(t: Row, n: any) {
  const noun = t.noun || t.entity_type || "objects";
  return n === 1 && /s$/.test(noun) ? noun.slice(0, -1) : noun;
}

export function useTagCompliance(filters: Filters, windowDays: number, version: number) {
  const key = JSON.stringify([windowDays, filters.accountIds || [], version]);
  const [state, setState] = React.useState<{ phase: string; data: any; error: string | null }>({ phase: "loading", data: null, error: null });
  React.useEffect(() => {
    let live = true;
    setState({ phase: "loading", data: null, error: null });
    Api.tagCompliance(windowDays, filters.accountIds)
      .then((d: any) => { if (live) setState({ phase: "ready", data: d, error: null }); })
      .catch((e: any) => { if (live) setState({ phase: "error", data: null, error: e.message || String(e) }); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return state;
}

// The required keys, edited as a comma list. PUT writes the local settings file; the page refetches.
export function RequiredTagsEditor({ onSaved }: { onSaved?: (() => void) | null }) {
  const [cfg, setCfg] = React.useState<any>(null);
  const [draft, setDraft] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<string | null>(null);
  React.useEffect(() => {
    let live = true;
    Api.requiredTags()
      .then((d: any) => { if (live) { setCfg(d); setDraft((d.keys || []).join(", ")); } })
      .catch((e: any) => { if (live) setMsg(`Could not load the setting: ${e.message}`); });
    return () => { live = false; };
  }, []);
  const parse = () => draft.split(",").map((k) => k.trim()).filter(Boolean);
  const save = (keys: string[]) => {
    setBusy(true);
    setMsg(null);
    Api.saveRequiredTags(keys)
      .then((d: any) => { setCfg(d); setDraft((d.keys || []).join(", ")); setMsg("Saved."); if (onSaved) onSaved(); })
      .catch((e: any) => setMsg(`Not saved: ${e.message}`))
      .finally(() => setBusy(false));
  };
  const max = cfg ? cfg.max : 20;
  return (
    <div className="filter-group" style={{ flexWrap: "wrap", gap: 8, marginBottom: 10 }}>
      <span className="filter-label">Required tag keys</span>
      <input
        className="ws-search"
        style={{ width: 320, marginBottom: 0 }}
        placeholder="cost_center, team"
        value={draft}
        onChange={(e: React.ChangeEvent<HTMLInputElement>) => setDraft(e.target.value)}
        title={`Up to ${max} keys, comma separated. Empty means no required keys: the page shows the most used keys instead.`}
      />
      <button type="button" className="csv-download-btn" disabled={busy || !cfg} onClick={() => save(parse())}>Save</button>
      {cfg && (cfg.default || []).join(",") !== parse().join(",") && (
        <button type="button" className="ck-link" disabled={busy} onClick={() => save(cfg.default || [])}>Reset to default</button>
      )}
      {msg && <span className="muted">{msg}</span>}
    </div>
  );
}

export function TagTypeCard({ t }: { t: Row }) {
  const [showAll, setShowAll] = React.useState(false);
  const title = (t.noun || t.entity_type || "objects");
  const partial = t.total === null || t.total === undefined;
  return (
    <div className="card" style={{ marginBottom: 14 }}>
      <div className="card-head">
        <div>
          <div className="card-title">{title.charAt(0).toUpperCase() + title.slice(1)}</div>
          <div className="metric-note">
            {partial
              ? `The export lists only tagged ${title}, so how many miss a tag is not known ("-").`
              : `${fmtInt(t.total)} ${tagNounFor(t, t.total)}${t.universe ? `, ${t.universe}` : ""}.`}
          </div>
        </div>
      </div>
      <div className="table-wrap">
        <table className="data">
          <thead>
            <tr>
              <th>Tag key</th>
              <th className="num">{`Tagged ${title}`}</th>
              <th className="num">{`Missing ${title}`}</th>
              <th className="num">Coverage</th>
              <th className="num">Spend of those without it</th>
              <th>Examples missing it</th>
            </tr>
          </thead>
          <tbody>
            {(t.per_key || []).map((k: Row) => {
              const ex = k.missing_examples || [];
              const shown = showAll ? ex : ex.slice(0, TAG_EXAMPLES_SHOWN);
              return (
                <tr key={k.tag_key}>
                  <td>{k.display_key || k.tag_key}</td>
                  <td className="num mono">{partial ? fmtInt(k.tagged) : `${fmtInt(k.tagged)} of ${fmtInt(t.total)}`}</td>
                  <td className="num mono">{k.missing === null || k.missing === undefined ? "-" : fmtInt(k.missing)}</td>
                  <td className="num mono">{k.coverage_pct === null || k.coverage_pct === undefined ? "-" : fmtPct(k.coverage_pct, 0)}</td>
                  <td className="num mono">{tagUsdCell(k.missing_usd)}</td>
                  <td className="wrap tag-examples">
                    {ex.length === 0 ? <span className="muted">-</span> : shown.join(", ")}
                    {ex.length > TAG_EXAMPLES_SHOWN && (
                      <button type="button" className="ck-link" onClick={() => setShowAll(!showAll)}>
                        {showAll ? " fewer" : ` +${fmtInt(ex.length - TAG_EXAMPLES_SHOWN)} more`}
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// One row per key: the spend no tag of that key reaches, as $ and % of billed, largest first. A key that is
// not required reads grey: missing it is a fact, not a finding. Each key is its own view of the same spend.
export function TagKeySpendBars({ spend, required }: { spend: Row | null | undefined; required: boolean }) {
  if (!spend) return null;
  const why = spend.reason === "unpriced" ? "– Spend is not priced in this export."
    : spend.reason === "no_cost_data" ? "– No cost data in this window." : null;
  const items: StatusBarItem[] = (spend.per_key || []).filter((k: Row) => k.untagged_usd != null).map((k: Row) => {
    const pct = k.untagged_pct == null ? null : Number(k.untagged_pct);
    return {
      key: k.tag_key, name: k.display_key || k.tag_key, value: Number(k.untagged_usd) || 0,
      valueText: `${fmtMoney(k.untagged_usd, 0)} · ${fmtShare(pct)}${k.covered_by === "account tag" ? " · account tag reaches all" : ""}`,
      status: !required ? "OK" : pct == null ? null : pct >= 50 ? "CRITICAL" : pct >= 20 ? "WARN" : "OK",
    };
  });
  return why ? <div className="chart-note-oneline">{why}</div>
    : <StatusBars items={items} n={12} unitLabel="reached by no value" ariaLabel="Untagged spend by tag key" emptyText="No tag key in this window." />;
}

// Key x object type: the share of each type that carries the key. Shaded by the share missing it,
// red for a required key and grey for one that is not; "–" where only tagged objects are listed.
export function TagKeyMatrix({ types, keys, required }: { types: Row[]; keys: Row[]; required: boolean }) {
  if (!types.length || !keys.length) return null;
  const tint = (missingPct: number) => `color-mix(in srgb, ${required ? "var(--st-crit)" : "var(--text-3)"} ${Math.round(8 + missingPct * 0.5)}%, transparent)`;
  return (
    <div className="table-wrap">
      <table className="tag-matrix">
        <thead>
          <tr><th />{types.map((t) => <th key={t.entity_type}>{`${String(t.noun || t.entity_type)}${t.total != null ? ` · ${fmtInt(t.total)}` : ""}`}</th>)}</tr>
        </thead>
        <tbody>
          {keys.map((k) => (
            <tr key={k.tag_key}>
              <th className="tm-key" title={k.display_key || k.tag_key}>{k.display_key || k.tag_key}</th>
              {types.map((t) => {
                const c = (t.per_key || []).find((x: Row) => x.tag_key === k.tag_key);
                if (!c || c.coverage_pct == null) {
                  return <td key={t.entity_type} className="tm-na blk-hatch" title={`Only tagged ${t.noun || "objects"} are listed${c ? `: ${fmtInt(c.tagged)} carry it` : ""}`}>–</td>;
                }
                const cov = Number(c.coverage_pct);
                return (
                  <td key={t.entity_type} style={{ background: tint(100 - cov) }}
                    title={`${k.display_key || k.tag_key} on ${t.noun}: ${fmtInt(c.tagged)} of ${fmtInt(t.total)} carry it, ${fmtInt(c.missing)} missing`}>
                    {fmtShare(cov)}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

const normKey = (k: any) => String(k || "").toLowerCase().replace(/[\s_-]/g, "");
// One row per (type, key, listed example). The API sends only the first 10 examples per key and
// type, so each row carries the key's full missing count beside it, never a per-object key list.
const MISSING_EXAMPLES_CAP = 10;
interface MissingTagRow { type: string; key: string; name: string; missing: number | null; total: number | null }
const MISSING_TAG_CSV: CsvColumn<MissingTagRow>[] = [
  { label: "Object type", value: (r) => r.type },
  { label: "Tag key", value: (r) => r.key },
  { label: "Object missing it (name, id where known)", value: (r) => r.name },
  { label: `Objects of this type missing the key (all, the file lists the first ${MISSING_EXAMPLES_CAP})`, value: (r) => (r.missing != null ? r.missing : "") },
  { label: "Objects of this type", value: (r) => (r.total != null ? r.total : "") },
];
export function missingTagRows(types: Row[]): MissingTagRow[] {
  const out: MissingTagRow[] = [];
  types.forEach((t) => (t.per_key || []).forEach((k: Row) => (k.missing_examples || []).forEach((name: string) => {
    out.push({
      type: String(t.entity_type), key: String(k.display_key || k.tag_key), name,
      missing: k.missing != null ? Number(k.missing) : null, total: t.total != null ? Number(t.total) : null,
    });
  })));
  return out;
}

type TileSev = "critical" | "warn" | "ok" | "not_assessed" | "neutral";

export function TagsPage({ filters, windowDays, onVerdict }: { filters: Filters; windowDays?: number | null; onVerdict?: ((verdict: string) => void) | null; priceLabel?: string | null }) {
  const win = windowDays || filters.window;
  const [version, setVersion] = React.useState(0);
  const state = useTagCompliance(filters, win, version);
  const d = state.data;
  const ok = state.phase === "ready" && !!d && d.available;
  const required = ok && d.mode === "required";
  const types: Row[] = ok ? (d.object_types || []) : [];
  const keys: Row[] = ok ? (d.keys || []) : [];
  const spend: Row | null = ok ? d.spend || null : null;
  const seen: Row[] = ok ? (d.keys_seen || []) : [];
  const missingRows = missingTagRows(types);
  const spendKeys: Row[] = spend && !spend.reason ? (spend.per_key || []) : [];

  // The key chargeback depends on: a cost-center key when one is in use, else the first key shown.
  const costKey = keys.find((k) => normKey(k.tag_key).includes("costcent")) || keys[0] || null;
  const costName = costKey ? (costKey.display_key || costKey.tag_key) : null;
  const costSpend = costKey ? spendKeys.find((k) => k.tag_key === costKey.tag_key) : null;
  const totalUsd = spend && spend.total_usd != null ? Number(spend.total_usd) : null;
  const cellOf = (etype: string, key: Row | null) => {
    const t = types.find((x) => x.entity_type === etype);
    const c = t && key ? (t.per_key || []).find((x: Row) => x.tag_key === key.tag_key) : null;
    return t && c ? { t, c } : null;
  };
  const whCell = cellOf("warehouse", costKey);
  const listed = types.filter((t) => t.total != null);
  const unlisted = types.filter((t) => t.total == null);
  // The biggest hole: the listed type with the most objects missing the cost key.
  const hole = costKey ? listed.map((t) => ({ t, c: (t.per_key || []).find((x: Row) => x.tag_key === costKey.tag_key) }))
    .filter((x) => x.c && x.c.missing != null).sort((a, b) => Number(b.c.missing) - Number(a.c.missing))[0] : null;
  const requiredInUse = required ? keys.filter((k) => seen.some((s) => s.tag_key === k.tag_key)).length : 0;
  const keysInUse = seen.length;
  const sev = (pct: number | null): TileSev => (pct == null ? "neutral" : !required ? (pct >= 20 ? "warn" : "ok") : pct >= 50 ? "critical" : pct >= 20 ? "warn" : "ok");

  const verdict = state.phase === "loading" ? "…"
    : state.phase === "error" ? "Tag compliance could not be loaded."
    : !ok ? "Tag compliance: –, not in this export."
    : [costSpend && costSpend.untagged_pct != null && totalUsd != null
        ? `${fmtShare(Number(costSpend.untagged_pct))} of billed spend (${fmtMoney(costSpend.untagged_usd, 0)} of ${fmtMoney(totalUsd, 0)}) reaches no ${costName}.` : null,
      `${fmtInt(keysInUse)} tag keys are in use and ${fmtInt(required ? keys.length : 0)} are required${hole && hole.c && Number(hole.c.missing) > 0 ? `; the biggest hole is ${hole.t.noun}, ${fmtInt(hole.c.missing)} of ${fmtInt(hole.t.total)} without one.` : "."}`].filter(Boolean).join(" ");
  React.useEffect(() => { if (onVerdict) onVerdict(verdict); }, [verdict, onVerdict]);

  const typeNoun = (t: Row) => String(t.noun || t.entity_type);
  const otherTypes = costKey ? listed.filter((t) => t.entity_type !== "warehouse").map((t) => {
    const c = (t.per_key || []).find((x: Row) => x.tag_key === costKey.tag_key);
    return c ? `${typeNoun(t)} ${fmtInt(c.tagged)} of ${fmtInt(t.total)}` : null;
  }).filter(Boolean).slice(0, 3).join(" · ") : "";
  const covRows = costKey ? types.map((t) => {
    const c = (t.per_key || []).find((x: Row) => x.tag_key === costKey.tag_key);
    return { t, c };
  }).filter((x) => x.c) : [];
  const covMax = Math.max(1, ...covRows.map((x) => (x.t.total != null ? Number(x.t.total) : Number(x.c.tagged) || 0)));

  return (
    <div className="sx-page">
      {state.phase === "loading" && <div className="loading-note">…</div>}
      {state.phase === "error" && (
        <div className="honest-card error"><div className="h-title">Could not load tag compliance</div><div className="h-note mono">{state.error}</div></div>
      )}
      {state.phase === "ready" && !ok && (
        <div className="honest-card not_assessed">
          <div className="h-title">Tag compliance not assessed</div>
          <div className="h-note">{(d && d.reason) || "The tag tables are not in this export."}</div>
          <div className="h-note">Unknown for now: not a clean result, and not zero.</div>
        </div>
      )}
      {ok && (
        <React.Fragment>
          {unlisted.length > 0 && (
            <div className="scope-note">{`– ${unlisted.map(typeNoun).join(" and ")}: the export lists only tagged ones, so what is missing there is not known. Listed: ${listed.map((t) => `${fmtInt(t.total)} ${typeNoun(t)}`).join(" · ")}.`}</div>
          )}
          <div className="summary-tile-row compact sx-tiles-4">
            <IssueTile label={costName ? `No ${costName}` : "Spend no tag reaches"} status={costSpend ? sev(costSpend.untagged_pct == null ? null : Number(costSpend.untagged_pct)) : "not_assessed"}
              headline={costSpend && costSpend.untagged_pct != null ? fmtShare(Number(costSpend.untagged_pct)) : null} unit="of billed spend"
              missingReason={!costKey ? "no tag key in use" : spend && spend.reason === "unpriced" ? "spend is not priced in this export" : "no cost data in this window"}
              base={costSpend && totalUsd != null ? `${fmtMoney(costSpend.untagged_usd, 0)} of ${fmtMoney(totalUsd, 0)} · tag ${costName}` : null}
              cause={whCell && whCell.c.missing_usd != null ? `Warehouses without it spent ${fmtMoney(whCell.c.missing_usd, 0)} of their own.` : null}
              onOpen={() => scrollToAnchor("tg-spend")} openLabel="Spend no tag reaches ↓" />
            <IssueTile label="Required tag keys" status={required ? (requiredInUse < keys.length ? "warn" : "ok") : "warn"}
              headline={`${fmtInt(required ? requiredInUse : 0)} of ${fmtInt(required ? keys.length : keysInUse)}`}
              unit={required ? "required keys are in use" : "keys in use are required"}
              base={seen.slice(0, 3).map((s) => `${s.display_key || s.tag_key} on ${fmtInt(s.objects)}`).join(" · ") || null}
              cause={required ? "Coverage below is for the required keys." : "With no required key, coverage counts as missing; below are the keys most objects carry."}
              onOpen={() => scrollToAnchor("tg-keys")} openLabel="Most used keys ↓" />
            <IssueTile label={costName ? `${costName} on warehouses` : "Tag on warehouses"}
              status={whCell && whCell.c.coverage_pct != null ? sev(100 - Number(whCell.c.coverage_pct)) : "not_assessed"}
              headline={whCell && whCell.c.coverage_pct != null ? fmtShare(Number(whCell.c.coverage_pct)) : null} unit="of warehouses carry it"
              missingReason={!costKey ? "no tag key in use" : "warehouses are not listed in this export"}
              base={whCell && whCell.c.coverage_pct != null ? [`${fmtInt(whCell.c.tagged)} of ${fmtInt(whCell.t.total)}`, otherTypes].filter(Boolean).join(" · ") : null}
              cause="Warehouses are where the $ is; tasks, users and roles have none of their own here."
              onOpen={() => scrollToAnchor("tg-matrix")} openLabel="Coverage matrix ↓" />
            {unlisted.length > 0 && (
              <IssueTile label={unlisted.map(typeNoun).join(" & ")} status="not_assessed" headline={null}
                missingReason={`not judged · ${unlisted.map((t) => { const c = costKey ? (t.per_key || []).find((x: Row) => x.tag_key === costKey.tag_key) : null; return `${fmtInt(c ? c.tagged : 0)} ${typeNoun(t)}`; }).join(" and ")} carry ${costName || "a key"}; the untagged ones are not listed`}
                onOpen={() => scrollToAnchor("tg-matrix")} openLabel="Coverage matrix ↓" />
            )}
          </div>

          <div className="cj-charts-2">
            <div id="tg-spend">
              <PatternCard title="Spend no tag reaches, by key" sub={totalUsd != null ? `Of ${fmtMoney(totalUsd, 0)} billed · each key is its own view of the same spend · compare, never add` : "Each key is its own view of the same spend"}>
                <TagKeySpendBars spend={spend} required={!!required} />
                {spend && spend.note && <div className="sx-foot">{spend.note}</div>}
              </PatternCard>
            </div>
            <PatternCard title={costName ? `${costName}: tagged vs not, by object type` : "Tagged vs not, by object type"} sub="Of each type's own count · untagged hatched · not listed reads –">
              {!covRows.length ? <div className="chart-note-oneline">No tag key in use.</div> : (
                <DrillTable aria="Tagged vs not, by object type" n={10}
                  cols={[{ label: "Object type" }, { label: "Tagged · not", width: "minmax(70px, 1.4fr)" }, { label: "Carry it", num: true, width: "auto" }, { label: "Missing $", num: true, width: "auto" }]}
                  rows={covRows.map(({ t, c }) => ({
                    key: String(t.entity_type),
                    cells: [typeNoun(t).charAt(0).toUpperCase() + typeNoun(t).slice(1),
                      t.total != null ? <SplitBar key="b" max={covMax} parts={[{ value: Number(c.tagged) || 0 }, { value: Number(c.missing) || 0, hatched: true }]} /> : <SplitBar key="b" max={covMax} parts={[{ value: Number(c.tagged) || 0 }]} />,
                      t.total != null ? `${fmtInt(c.tagged)} of ${fmtInt(t.total)}` : `${fmtInt(c.tagged)} · not listed`,
                      c.missing_usd != null ? fmtMoney(c.missing_usd, 0) : "–"],
                  }))} />
              )}
            </PatternCard>
          </div>

          <div id="tg-matrix">
            <PatternCard title="Coverage by key and object type" sub="% of each type that carries the key · darker = more missing · hatched = only tagged ones are listed">
              <TagKeyMatrix types={types} keys={keys} required={!!required} />
            </PatternCard>
          </div>

          <div id="tg-keys">
            <PatternCard title="Most used tag keys" sub={`${fmtInt(seen.length)} keys on objects${(d.query_tag_keys || []).length ? ` · ${fmtInt(d.query_tag_keys.length)} more seen in QUERY_TAG` : ""}`}>
              <DrillTable aria="Most used tag keys" n={10} empty="No tag key on any object."
                cols={[{ label: "Tag key", width: "minmax(110px, 1fr)" }, { label: "By object type", width: "minmax(0, 3fr)" }, { label: "Objects", num: true, width: "auto" }]}
                rows={seen.map((k) => ({ key: String(k.tag_key), cells: [k.display_key || k.tag_key, tagPlain(k.by_type), fmtInt(k.objects)] }))} />
            </PatternCard>
          </div>

          <details className="card ws-method-list">
            <summary>Objects missing each key, by type</summary>
            {missingRows.length > 0 && (
              <div style={{ display: "flex", justifyContent: "flex-end", margin: "8px 0" }}>
                <CsvButton fileName={`tags-missing-first${MISSING_EXAMPLES_CAP}-per-key-${win}d`} columns={MISSING_TAG_CSV} rows={missingRows} />
              </div>
            )}
            {types.map((t: Row) => <TagTypeCard key={t.entity_type} t={t} />)}
          </details>
          <RequiredTagsEditor onSaved={() => setVersion((v) => v + 1)} />
          {filters.tag && filters.tag.groups && filters.tag.groups.length ? <div className="scope-note">The Tag filter does not narrow this page.</div> : null}
        </React.Fragment>
      )}
    </div>
  );
}
