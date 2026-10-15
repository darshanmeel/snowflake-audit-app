// web/src/components/settings_panel.tsx -- the top-bar gear button and its small popover: which
// raw tag key(s) the team says mean "cost center" (GET/PUT /api/settings/cost-center,
// app/core/cost_center.py). Same self-anchored trigger/popover shape as the other top-bar pickers
// (.ws-picker/.ws-trigger/.ws-pop/.ws-search/.ws-actions/.ws-list/.ws-row/.ws-empty/.ws-foot) --
// no new styles.css classes.
import React from "react";
import { Api } from "../api";

interface CostCenterKeyRowProps {
  item: { tag_key: string; display_key?: string | null; object_count?: number | null };
  checked: boolean;
  atLimit: boolean;
  onToggle: () => void;
}

interface PrivacyState { phase: string; mask?: boolean; fields?: string[]; kinds?: string[]; loaded?: string[] }

// The words for each kind of name the export can mask (app/core/masking.py MASK_KINDS).
const MASK_KIND_LABEL: Record<string, string> = {
  user: "user names and emails", warehouse: "warehouses", database: "databases", schema: "schemas",
  object: "tables, views, stages and pipes", role: "roles", task: "tasks", account: "account names",
};

interface CostCenterState {
  phase: string;
  error?: unknown;
  keys?: string[];
  default?: string[];
  suggestions?: CostCenterKeyRowProps["item"][];
  [key: string]: any;
}


export function CostCenterKeyRow({ item, checked, atLimit, onToggle }: CostCenterKeyRowProps) {
  return (
    <label className="ws-row" title={item.tag_key}>
      <input type="checkbox" checked={checked} disabled={!checked && atLimit} onChange={onToggle} />
      <span className="ws-name">{item.display_key || item.tag_key}</span>
      {item.object_count ? <span className="env muted">{item.object_count}</span> : null}
    </label>
  );
}

// "Mask user names and emails": the core's privacy.mask_user_identities. Off by default; saving it
// reloads the page so every figure reads the masked (or unmasked) names.
export function PrivacySwitch() {
  const [state, setState] = React.useState<PrivacyState>({ phase: "loading" });
  const [saving, setSaving] = React.useState(false);
  const [msg, setMsg] = React.useState<string | null>(null);
  React.useEffect(() => {
    Api.privacySettings()
      .then((body: any) => setState({
        phase: "ready", mask: !!body.mask_user_identities, fields: body.mask_fields || [],
        kinds: body.mask_kinds || [], loaded: body.loaded_masked || [],
      }))
      .catch(() => setState({ phase: "error" }));
  }, []);
  // Saved for the next export or Refresh; the data on screen does not change, so no reload.
  const toggleField = (kind: string) => {
    const cur = state.fields || [];
    const next = cur.includes(kind) ? cur.filter((k) => k !== kind) : [...cur, kind];
    setSaving(true);
    setMsg(null);
    Api.saveMaskFields(next)
      .then((body: any) => { setSaving(false); setState((s) => ({ ...s, fields: body.mask_fields || [] })); setMsg("Saved. It applies from the next Refresh."); })
      .catch((err: any) => { setSaving(false); setMsg(err.message || "Could not save"); });
  };
  const toggle = () => {
    const next = !state.mask;
    setSaving(true);
    setMsg(null);
    Api.savePrivacy(next)
      .then(() => { setMsg("Saved -- reloading..."); window.setTimeout(() => window.location.reload(), 600); })
      .catch((err: any) => { setSaving(false); setMsg(err.message || "Could not save"); });
  };
  return (
    <div>
      <div className="ws-foot" style={{ marginTop: 0, paddingTop: 0, borderTop: "none", fontWeight: 600, color: "var(--text-2)" }}>
        Privacy
      </div>
      {state.phase === "loading" && <div className="ws-empty">Loading...</div>}
      {state.phase === "error" && <div className="ws-empty">The privacy setting is not available in this build.</div>}
      {state.phase === "ready" && (
        <label className="ws-row" style={{ cursor: "pointer" }}>
          <input type="checkbox" checked={state.mask!} disabled={saving} onChange={toggle} />
          <span className="ws-name">Mask user names and emails</span>
        </label>
      )}
      <div className="ws-foot">Off by default. Masks user names and emails on screen.</div>
      {state.phase === "ready" && (
        <div>
          <div className="ws-foot" style={{ fontWeight: 600, color: "var(--text-2)" }}>Mask in the next Refresh</div>
          {(state.kinds || []).map((kind) => (
            <label key={kind} className="ws-row" style={{ cursor: "pointer" }}>
              <input type="checkbox" checked={(state.fields || []).includes(kind)} disabled={saving} onChange={() => toggleField(kind)} />
              <span className="ws-name">{MASK_KIND_LABEL[kind] || kind}</span>
            </label>
          ))}
          <div className="ws-foot">
            {"Replaced with tokens before any file is saved; the same name gets the same token everywhere. "}
            {(state.loaded || []).length
              ? `This data has masked ${(state.loaded || []).map((k) => MASK_KIND_LABEL[k] || k).join(", ")}.`
              : "This data has no names masked."}
          </div>
        </div>
      )}
      {msg && <div className="muted" style={{ fontSize: 12 }}>{msg}</div>}
    </div>
  );
}

export function SettingsGearButton() {
  const [open, setOpen] = React.useState(false);
  const [state, setState] = React.useState<CostCenterState>({ phase: "idle" }); // idle | loading | ready | error
  const [selected, setSelected] = React.useState<string[]>([]);
  const [query, setQuery] = React.useState("");
  const [saving, setSaving] = React.useState(false);
  const [saveMsg, setSaveMsg] = React.useState<string | null>(null);
  const boxRef = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    if (!open) return undefined;
    const onDocClick = (e: MouseEvent) => { if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false); };
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDocClick);
    document.addEventListener("keydown", onEsc);
    return () => {
      document.removeEventListener("mousedown", onDocClick);
      document.removeEventListener("keydown", onEsc);
    };
  }, [open]);

  React.useEffect(() => {
    if (!open || state.phase !== "idle") return;
    setState({ phase: "loading" });
    Api.costCenterSettings()
      .then((body: any) => { setState({ phase: "ready", ...body }); setSelected(body.keys || []); })
      .catch((err: unknown) => setState({ phase: "error", error: err }));
  }, [open, state.phase]);

  const suggestions = state.suggestions || [];
  const needle = query.trim().toLowerCase();
  const shown = needle
    ? suggestions.filter((s) => s.tag_key.includes(needle) || (s.display_key || "").toLowerCase().includes(needle))
    : suggestions;
  const exactTyped = needle && !suggestions.some((s) => s.tag_key === needle) && !selected.includes(query.trim());

  const toggle = (key: string) => {
    setSaveMsg(null);
    setSelected((prev) => {
      if (prev.includes(key)) return prev.filter((k) => k !== key);
      if (prev.length >= 5) return prev;
      return [...prev, key];
    });
  };
  const addCustom = () => {
    const key = query.trim();
    if (!key || selected.includes(key) || selected.length >= 5) return;
    setSaveMsg(null);
    setSelected((prev) => [...prev, key]);
    setQuery("");
  };

  const save = () => {
    setSaving(true);
    setSaveMsg(null);
    Api.saveCostCenterKeys(selected)
      .then(() => {
        setSaveMsg("Saved -- reloading...");
        window.setTimeout(() => window.location.reload(), 600);
      })
      .catch((err: any) => { setSaving(false); setSaveMsg(err.message || "Could not save"); });
  };

  return (
    <div className="ws-picker" ref={boxRef}>
      <button
        type="button" className="ws-trigger" onClick={() => setOpen(!open)}
        title="Settings" aria-label="Settings"
      >
        ⚙ <span className="caret">{open ? "▴" : "▾"}</span>
      </button>
      {open && (
        <div className="ws-pop" style={{ left: "auto", right: 0, width: 320 }}>
          <PrivacySwitch />
          <div className="ws-foot" style={{ fontWeight: 600, color: "var(--text-2)" }}>
            Cost center tag key
          </div>
          {state.phase === "loading" && <div className="ws-empty">Loading...</div>}
          {state.phase === "error" && <div className="ws-empty">Could not load settings.</div>}
          {state.phase === "ready" && (
            <React.Fragment>
              <div className="ws-actions">
                {selected.length
                  ? selected.map((k) => (
                    <button key={k} type="button" title="Remove" onClick={() => toggle(k)}>{k} ✕</button>
                  ))
                  : <span className="muted" style={{ fontSize: 12 }}>Using the default: {(state.default || []).join(", ")}</span>}
              </div>
              <input
                className="ws-search" placeholder="Search tag keys..."
                value={query} onChange={(e) => setQuery(e.target.value)}
              />
              <div className="ws-list">
                {shown.length
                  ? shown.map((s) => (
                    <CostCenterKeyRow
                      key={s.tag_key} item={s} checked={selected.includes(s.tag_key)}
                      atLimit={selected.length >= 5} onToggle={() => toggle(s.tag_key)}
                    />
                  ))
                  : <div className="ws-empty">No matching tag keys.</div>}
                {exactTyped && selected.length < 5 && (
                  <label className="ws-row" style={{ cursor: "pointer" }} onClick={addCustom}>
                    <span className="ws-name">Add "{query.trim()}" as a custom key</span>
                  </label>
                )}
              </div>
              <div className="ws-foot">Used by the Cost center filter and Cost &rsaquo; Chargeback &amp; tags.</div>
              <div className="ws-actions" style={{ marginTop: 6 }}>
                <button type="button" onClick={save} disabled={saving || selected.length === 0}>
                  {saving ? "Saving..." : "Save"}
                </button>
                {saveMsg && <span className="muted" style={{ fontSize: 12, alignSelf: "center" }}>{saveMsg}</span>}
              </div>
            </React.Fragment>
          )}
        </div>
      )}
    </div>
  );
}
