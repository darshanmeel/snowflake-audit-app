// web/src/components/tag_picker.tsx -- the top bar's tag filter: a "Tag name" dropdown and a
// "Tag value" dropdown, both checkbox lists, applied together with one Apply button. Also the
// banner shown while a tag filter is active (TagScopeBanner).
//
// `value` is null or {groups: [{key, display_key, values: [..], all?}]}: values OR within one name,
// names AND together, an empty `values` means any value of that name (untagged left out), and
// `all` means every value ticked, untagged too, so the name narrows nothing. A picked name starts
// at `all`. GET /api/tags lists the names and, per name, its values; no account-specific setup.
import React from "react";
import { Api } from "../api";
import { fmtInt, fmtMoney } from "../format";
import { normalizeTagKeyLike, tagRollupFetch, useCostCenterSettingState } from "./tag_rollup";
import { fmtShare, pctOf } from "./blocks";
import type { TagFilter } from "../types";

type TagGroup = TagFilter["groups"][number];
interface TagKey { tag_key: string; display_key?: string | null; value_count?: number | null; values?: TagValue[]; values_truncated?: boolean }
interface TagValue { tag_value: string; object_count?: number | null }


export const TAG_SEARCH_DEBOUNCE_MS = 250;
export const TAG_UNTAGGED = "__untagged__";

export function tagValueLabel(v: string | null | undefined): string {
  if (v === TAG_UNTAGGED) return "untagged";
  if (v === "__empty__" || v === "" || v === null || v === undefined) return "(no value)";
  return v;
}

// Closes a popover on an outside click or Escape.
export function usePopoverClose(open: boolean, setOpen: (open: boolean) => void, ref: React.RefObject<HTMLElement | null>) {
  React.useEffect(() => {
    if (!open) return undefined;
    const onDocClick = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDocClick);
    document.addEventListener("keydown", onEsc);
    return () => {
      document.removeEventListener("mousedown", onDocClick);
      document.removeEventListener("keydown", onEsc);
    };
  }, [open]);
}

// Tag keys that mean "cost center" (settings), matched on the key's last name part: COST_CENTER, cost-center.
export function costCenterKeys(keys: TagKey[], settingKeys: string[]): TagKey[] {
  const wanted = new Set(settingKeys.map(normalizeTagKeyLike).filter(Boolean));
  if (!wanted.size) return [];
  const last = (v: string | null | undefined) => normalizeTagKeyLike(String(v || "").split(".").pop());
  return keys.filter((k) => wanted.has(last(k.tag_key)) || wanted.has(last(k.display_key)));
}

export function TagNameList({ draft, onToggle, onPreset }: { draft: TagGroup[]; onToggle: (k: TagKey) => void; onPreset?: (keys: TagKey[]) => void }) {
  const [q, setQ] = React.useState("");
  const cc = useCostCenterSettingState();
  const [state, setState] = React.useState<{ loading: boolean; keys: TagKey[]; truncated: boolean; error: string | null }>({ loading: true, keys: [], truncated: false, error: null });
  React.useEffect(() => {
    let cancelled = false;
    setState((s) => ({ ...s, loading: true, error: null }));
    const t = setTimeout(() => {
      Api.tags(q, null, 200, 1)
        .then((d: any) => { if (!cancelled) setState({ loading: false, keys: d.keys || [], truncated: !!d.truncated, error: null }); })
        .catch((e: any) => { if (!cancelled) setState({ loading: false, keys: [], truncated: false, error: e.message || String(e) }); });
    }, TAG_SEARCH_DEBOUNCE_MS);
    return () => { cancelled = true; clearTimeout(t); };
  }, [q]);
  return (
    <React.Fragment>
      <input className="ws-search" autoFocus placeholder="Search tag names..." value={q} onChange={(e) => setQ(e.target.value)} />
      {(() => {
        // The cost-center preset: one click picks every key the settings call a cost center.
        const preset = onPreset && !q && cc.phase === "ready" ? costCenterKeys(state.keys, cc.keys) : [];
        return preset.length ? (
          <div className="ws-actions">
            <button type="button" onClick={() => onPreset!(preset)} title={preset.map((k) => k.display_key || k.tag_key).join(", ")}>Cost center</button>
          </div>
        ) : null;
      })()}
      <div className="ws-list">
        {state.loading && <div className="ws-empty">Loading tag names...</div>}
        {state.error && <div className="ws-empty">{/tag index/i.test(state.error)
          ? "Tags aren't in this export; the next export loads them. Filter by Account or Owner meanwhile."
          : `Could not load tags: ${state.error}`}</div>}
        {!state.loading && !state.error && state.keys.length === 0 && <div className="ws-empty">{q ? `No tag names match "${q}".` : "No tags in this export."}</div>}
        {!state.loading && state.keys.map((k) => (
          <label key={k.tag_key} className="ws-row">
            <input type="checkbox" checked={draft.some((g) => g.key === k.tag_key)} onChange={() => onToggle(k)} />
            <span className="ws-name">{k.display_key || k.tag_key}</span>
            <span className="muted">{`${fmtInt(k.value_count)} value${k.value_count === 1 ? "" : "s"}`}</span>
          </label>
        ))}
      </div>
      {state.truncated && <div className="ws-foot">More names exist: search to find them.</div>}
    </React.Fragment>
  );
}

// The groups that narrow anything: a name with every value ticked is left out.
export function narrowingTag(tag: TagFilter | null): TagFilter | null {
  const groups = ((tag && tag.groups) || []).filter((g) => !g.all);
  return groups.length ? (groups.length === tag!.groups.length ? tag : { groups }) : null;
}

// `group` with `val` ticked or unticked, given every value the name has; at least one stays ticked.
// `partial`: the list holds only some of the values, so unticking would silently drop the unlisted
// ones; instead the ticks pick the values to keep, and none ticked is every value again.
export function toggleGroupValue(group: TagGroup, val: string, allValues: string[], partial = false): TagGroup {
  if (partial) {
    const cur = group.all ? [] : group.values;
    const kept = cur.includes(val) ? cur.filter((x) => x !== val) : [...cur, val];
    return kept.length ? { key: group.key, display_key: group.display_key, values: kept }
      : { key: group.key, display_key: group.display_key, values: [], all: true };
  }
  const every = [...allValues, TAG_UNTAGGED];
  const ticked = group.all ? every : group.values.length ? group.values : allValues;
  const next = ticked.includes(val) ? ticked.filter((x) => x !== val) : [...ticked, val];
  const base = { key: group.key, display_key: group.display_key };
  if (!next.length) return group;
  if (every.every((x) => next.includes(x))) return { ...base, values: [], all: true };
  if (!next.includes(TAG_UNTAGGED) && allValues.every((x) => next.includes(x))) return { ...base, values: [] };
  return { ...base, values: next };
}

export function TagValueSection({ group, q, onToggleValue }: { group: TagGroup; q: string; onToggleValue: (key: string, val: string, allValues: string[], partial: boolean) => void }) {
  const [state, setState] = React.useState<{ loading: boolean; values: TagValue[]; truncated: boolean }>({ loading: true, values: [], truncated: false });
  React.useEffect(() => {
    let cancelled = false;
    Api.tags("", group.key, 1, 500)
      .then((d: any) => {
        const row = (d.keys || [])[0];
        if (!cancelled) setState({ loading: false, values: (row && row.values) || [], truncated: !!(row && row.values_truncated) });
      })
      .catch(() => { if (!cancelled) setState({ loading: false, values: [], truncated: false }); });
    return () => { cancelled = true; };
  }, [group.key]);
  const needle = q.trim().toLowerCase();
  const shown = state.values.filter((v) => !needle || tagValueLabel(v.tag_value).toLowerCase().includes(needle));
  const row = (val: string, label: string, count: number | null | undefined) => (
    <label key={val} className="ws-row tag-value-row">
      <input type="checkbox" checked={state.truncated ? group.values.includes(val)
        : !!group.all || (group.values.length ? group.values.includes(val) : val !== TAG_UNTAGGED)}
        onChange={() => onToggleValue(group.key, val, state.values.map((v) => v.tag_value), state.truncated)} />
      <span className="ws-name" title={label}>{label}</span>
      {count != null && <span className="muted">{fmtInt(count)}</span>}
    </label>
  );
  return (
    <div className="tag-key-block">
      <div className="tag-key-head">
        <span className="tag-key-name">{group.display_key || group.key}</span>
        <span className="muted">{group.all ? "all" : group.values.length ? `${group.values.length} selected` : "tagged only"}</span>
      </div>
      {state.loading && <div className="ws-empty">Loading values...</div>}
      {!state.loading && shown.map((v) => row(v.tag_value, tagValueLabel(v.tag_value), v.object_count))}
      {!state.loading && !needle && row(TAG_UNTAGGED, "untagged (no such tag)", null)}
      {!state.loading && state.truncated && <div className="ws-empty">Showing the first {fmtInt(state.values.length)} values: tick the ones to keep.</div>}
    </div>
  );
}

// The applied single-name filter's share of spend: $ and % of the window's priced spend, from the
// cost rollup (each dollar counted at one tag level). null while unknown or for several names.
export function useTagFilterSpend(tag: TagFilter | null, windowDays: number | null | undefined) {
  const g = tag && tag.groups && tag.groups.length === 1 ? tag.groups[0] : null;
  const dep = JSON.stringify([g, windowDays]);
  const [out, setOut] = React.useState<{ usd: number; pct: number | null } | null>(null);
  React.useEffect(() => {
    setOut(null);
    if (!g || !windowDays) return undefined;
    let alive = true;
    tagRollupFetch("/api/rollup", { area: "cost", tag_key: g.key, window: windowDays })
      .then((body: any) => {
        if (!alive || !body || body.outcome !== "ok_rows") return;
        const total = Number(body.total && body.total.usd) || 0;
        const byValue: any[] = body.by_value || [];
        const usdOf = (e: any) => Number(e.metrics && e.metrics.usd) || 0;
        const usd = g.all ? total
          : g.values.length ? byValue.filter((e) => g.values.includes(String(e.value))).reduce((s, e) => s + usdOf(e), 0)
          : byValue.filter((e) => e.value !== TAG_UNTAGGED).reduce((s, e) => s + usdOf(e), 0);
        setOut({ usd, pct: pctOf(usd, total) });
      })
      .catch(() => { /* no figure: the chip shows none rather than a wrong one */ });
    return () => { alive = false; };
  }, [dep]); // eslint-disable-line react-hooks/exhaustive-deps
  return out;
}

export function TagPicker({ value, onChange, windowDays }: { value: TagFilter | null; onChange: (value: TagFilter | null) => void; windowDays?: number | null }) {
  const applied = (value && value.groups) || [];
  const [draft, setDraft] = React.useState<TagGroup[]>(applied);
  const [open, setOpen] = React.useState<string | null>(null); // "name" | "value" | null
  const [valueQ, setValueQ] = React.useState("");
  const boxRef = React.useRef<HTMLDivElement>(null);
  usePopoverClose(!!open, () => setOpen(null), boxRef);
  React.useEffect(() => { setDraft((value && value.groups) || []); }, [JSON.stringify(value)]);

  const toggleName = (k: TagKey) => setDraft((d) => (d.some((g) => g.key === k.tag_key)
    ? d.filter((g) => g.key !== k.tag_key)
    : [...d, { key: k.tag_key, display_key: k.display_key || k.tag_key, values: [], all: true }]));
  const presetNames = (keys: TagKey[]) => setDraft((d) => [
    ...d, ...keys.filter((k) => !d.some((g) => g.key === k.tag_key)).map((k) => ({ key: k.tag_key, display_key: k.display_key || k.tag_key, values: [], all: true })),
  ]);
  const spend = useTagFilterSpend(value, windowDays);
  const toggleValue = (key: string, val: string, allValues: string[], partial: boolean) =>
    setDraft((d) => d.map((g) => (g.key !== key ? g : toggleGroupValue(g, val, allValues, partial))));
  const apply = () => { onChange(draft.length ? { groups: draft } : null); setOpen(null); };
  const clear = () => { setDraft([]); onChange(null); setOpen(null); };
  const toggleOpen = (which: string) => setOpen(open === which ? null : which);

  const nameLabel = applied.length === 0 ? "any"
    : applied.length === 1 ? applied[0].display_key || applied[0].key : `${applied.length} names`;
  const narrowing = applied.filter((g) => !g.all);
  const pickedValues = narrowing.reduce((n, g) => n + g.values.length, 0);
  const firstPicked = narrowing.find((g) => g.values.length);
  const valueLabel = applied.length === 0 ? "any" : narrowing.length === 0 ? "all" : pickedValues === 0 ? "tagged only"
    : pickedValues === 1 && firstPicked ? tagValueLabel(firstPicked.values[0]) : `${pickedValues} values`;
  const actions = (
    <div className="tag-actions">
      <button type="button" className="tag-apply" onClick={apply}>Apply</button>
      <button type="button" onClick={clear}>Clear</button>
    </div>
  );

  return (
    <div className="filter-group ws-picker tag-picker" ref={boxRef}>
      <span className="filter-label">Tag</span>
      <button className="ws-trigger" onClick={() => toggleOpen("name")} title="Pick tag names">
        {`Name: ${nameLabel}`} <span className="caret">{open === "name" ? "▴" : "▾"}</span>
      </button>
      <button className="ws-trigger" onClick={() => toggleOpen("value")} disabled={!draft.length}
        title={draft.length ? "Pick values of the chosen tag names" : "Pick a tag name first"}>
        {`Value: ${valueLabel}`} <span className="caret">{open === "value" ? "▴" : "▾"}</span>
      </button>
      {spend && <span className="tag-chip-spend mono" title={`Priced spend this tag filter reaches, last ${windowDays} days`}>{`${fmtMoney(spend.usd, 0)} · ${fmtShare(spend.pct)}`}</span>}
      {open === "name" && (
        <div className="ws-pop tag-pop">
          <TagNameList draft={draft} onToggle={toggleName} onPreset={presetNames} />
          {actions}
        </div>
      )}
      {open === "value" && (
        <div className="ws-pop tag-pop">
          <input className="ws-search" autoFocus placeholder="Search values..." value={valueQ} onChange={(e) => setValueQ(e.target.value)} />
          <div className="ws-list">
            {draft.map((g) => <TagValueSection key={g.key} group={g} q={valueQ} onToggleValue={toggleValue} />)}
          </div>
          <div className="ws-foot">Every value starts ticked: untick the ones to leave out. Several names must all match.</div>
          {actions}
        </div>
      )}
    </div>
  );
}

// The banner shown while a tag filter is active.
export function TagScopeBanner({ tag }: { tag: TagFilter | null }) {
  const groups = (tag && tag.groups) || [];
  if (!groups.length) return null;
  const parts = groups.map((g) => `${g.display_key || g.key} = ${g.values.length ? g.values.map(tagValueLabel).join(" or ") : "any value, untagged left out"}`);
  return (
    <div className="scope-banner">
      {`Tag filter: ${parts.join("; and ")}. `}
      {"Each check is filtered at the most specific level it can see: query tag, then object tag, "}
      {"then warehouse tag, then user or role tag, then account tag. Checks that cannot see tags are "}
      {'not filtered and are marked "tag n/a". Exact dollars for this tag: Cost > Chargeback & tags.'}
    </div>
  );
}

