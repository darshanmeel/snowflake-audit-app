// web/src/components/filters.tsx -- one picker per populated account tag-attribute key (cost_center,
// team, business_unit, domain: whatever config/tag_aliases.yml declares AND at least one account
// actually carries, GET /api/meta's `attribute_keys_populated`), for the top bar next to the
// Account picker. Reuses the .filter-group/.filter-label/.ws-picker/.ws-trigger/.ws-pop/
// .ws-actions/.ws-list/.ws-row/.ws-empty/.ws-foot/.caret/.muted classes the Account picker uses.
//
// A key the API does not list as populated renders nothing: an always-empty dropdown would read as
// "nothing has cost centres", never "nothing is tagged", so absence from the UI must mean absence.
// The component is self-contained: it takes the account rows, the populated-key list, the caller's
// own {key: Set(values)} selection and an onChange(key, nextSet) callback.
import React from "react";
import { Api } from "../api";
import { fmtInt } from "../format";
import { usePopoverClose } from "./tag_picker";
import { Badge } from "./primitives";
import type { Row } from "../types";

interface DimOption { value: string; label: string; title?: string; note?: string | null }
type DimApplied = { warehouse?: boolean | null; database?: boolean | null; schema?: boolean | null; [key: string]: any } | null | undefined;


// A popup that would run past the window's right edge opens leftwards from its trigger instead,
// and never starts left of the window either.
export function usePopOnScreen(open: boolean) {
  const popRef = React.useRef<HTMLDivElement>(null);
  const [style, setStyle] = React.useState<React.CSSProperties | undefined>(undefined);
  React.useLayoutEffect(() => {
    if (!open) { setStyle(undefined); return; }
    const el = popRef.current;
    if (!el || typeof window === "undefined") return;
    const r = el.getBoundingClientRect();
    const vw = window.innerWidth || document.documentElement.clientWidth;
    if (r.right > vw - 8) {
      const parent = el.offsetParent as HTMLElement | null;
      const pr = parent ? parent.getBoundingClientRect() : { left: 0, right: vw };
      // Right-align to the trigger, then pull back in if that would cross the left edge.
      const left = Math.max(8 - pr.left, (pr.right - pr.left) - r.width);
      setStyle({ left, right: "auto" });
    }
  }, [open]);
  return { popRef, popStyle: style };
}

export const ATTRIBUTE_OUTCOME_VALUES: Record<string, boolean> = { not_tagged: true, no_usage: true, mixed: true };

export function attributeLabel(key: string) {
  // "cost_center" -> "Cost center". Keys are config-driven: this file never assumes which exist.
  const spaced = String(key).replace(/_/g, " ");
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

export function AttributeValueOption({ value, count, avgShare, selected, onToggle }: {
  value: string; count: number; avgShare: number | null; selected: boolean; onToggle: () => void;
}) {
  const isOutcome = value in ATTRIBUTE_OUTCOME_VALUES;
  const pct = typeof avgShare === "number" ? `${Math.round(avgShare * 100)}%` : null;
  const title = isOutcome
    ? `${count} account(s) currently read "${value}" for this key`
    : `${count} account(s)` + (pct ? `, average dominant share ${pct}` : "");
  return (
    <label className="ws-row" title={title}>
      <input type="checkbox" checked={selected} onChange={onToggle} />
      <span className={isOutcome ? "muted" : ""}>{value}</span>
      <span className="muted"> ({count})</span>
    </label>
  );
}

export function AttributePicker({ attrKey, accounts, selectedValues, onChange }: {
  attrKey: string; accounts: Row[] | null | undefined; selectedValues: Set<string> | null | undefined; onChange: (next: Set<string>) => void;
}) {
  // A dropdown, not a wall of chips: an organization can carry many distinct cost-center values.
  const [open, setOpen] = React.useState(false);
  const boxRef = React.useRef<HTMLDivElement>(null);
  const { popRef, popStyle } = usePopOnScreen(open);

  React.useEffect(() => {
    if (!open) return undefined;
    const onDocClick = (e: MouseEvent) => {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDocClick);
    document.addEventListener("keydown", onEsc);
    return () => {
      document.removeEventListener("mousedown", onDocClick);
      document.removeEventListener("keydown", onEsc);
    };
  }, [open]);

  // One row per distinct value this key carries on at least one account. 'no_usage' means "this
  // account has no billed credits at all", not a tag, so it is never an option; 'not_tagged' and
  // 'mixed' are real, selectable outcomes and sink to the bottom, alphabetical otherwise.
  const valueCounts = React.useMemo(() => {
    const counts = new Map<string, number>();
    const shares = new Map<string, number[]>();
    (accounts || []).forEach((w: Row) => {
      const v = w ? w[attrKey] : undefined;
      if (v === undefined || v === null || v === "no_usage") return;
      counts.set(v, (counts.get(v) || 0) + 1);
      const share = w[`${attrKey}_share`];
      if (typeof share === "number") {
        const list = shares.get(v) || [];
        list.push(share);
        shares.set(v, list);
      }
    });
    const entries = Array.from(counts.entries());
    entries.sort((a, b) => {
      const aOutcome = a[0] in ATTRIBUTE_OUTCOME_VALUES;
      const bOutcome = b[0] in ATTRIBUTE_OUTCOME_VALUES;
      if (aOutcome !== bOutcome) return aOutcome ? 1 : -1;
      return String(a[0]).localeCompare(String(b[0]));
    });
    return entries.map(([value, count]) => {
      const list = shares.get(value) || [];
      const avgShare = list.length ? list.reduce((s, x) => s + x, 0) / list.length : null;
      return { value, count, avgShare };
    });
  }, [accounts, attrKey]);

  const selectedSet = selectedValues || new Set<string>();
  const n = selectedSet.size;
  const label = n === 0 ? "All" : `${n} selected`;

  const toggleValue = (value: string) => {
    const next = new Set(selectedSet);
    if (next.has(value)) next.delete(value); else next.add(value);
    onChange(next);
  };

  return (
    <div className="filter-group ws-picker" ref={boxRef}>
      <span className="filter-label">{attributeLabel(attrKey)}</span>
      <button
        className="ws-trigger"
        onClick={() => setOpen(!open)}
        title={`Filter by ${attributeLabel(attrKey)}`}
      >
        {label} <span className="caret">{open ? "▴" : "▾"}</span>
      </button>
      {open && (
        <div className="ws-pop" ref={popRef} style={popStyle}>
          <div className="ws-actions">
            <button onClick={() => onChange(new Set())}>All</button>
          </div>
          <div className="ws-list">
            {valueCounts.length === 0 && (
              <div className="ws-empty">No {attributeLabel(attrKey).toLowerCase()} values yet</div>
            )}
            {valueCounts.map(({ value, count, avgShare }) => (
              <AttributeValueOption
                key={value}
                value={value}
                count={count}
                avgShare={avgShare}
                selected={selectedSet.has(value)}
                onToggle={() => toggleValue(value)}
              />
            ))}
          </div>
          <div className="ws-foot">{valueCounts.length} value(s)</div>
        </div>
      )}
    </div>
  );
}

export function AttributeFilters({ accounts, populatedKeys, selected, onChange }: {
  accounts: Row[] | null | undefined; populatedKeys: string[] | null | undefined;
  selected: Record<string, Set<string>> | null | undefined; onChange: (key: string, next: Set<string>) => void;
}) {
  // `selected` is {canonicalKey: Set(values)}; `onChange(key, nextSet)` sets one key at a time.
  const keys = populatedKeys || [];
  if (keys.length === 0) return null; // nothing populated, render nothing at all
  if ((accounts || []).length <= 1) return null; // one account: an account attribute narrows nothing
  return (
    <React.Fragment>
      {keys.map((key: string) => (
        <AttributePicker
          key={key}
          attrKey={key}
          accounts={accounts}
          selectedValues={(selected && selected[key]) || new Set<string>()}
          onChange={(nextSet) => onChange(key, nextSet)}
        />
      ))}
    </React.Fragment>
  );
}

// OwnerFilter: a person's or role's name isn't an enumerable list the way tag values are, so this is
// a plain text box, not a dropdown, in the same .filter-group shell as every other top-bar control.
// It filters against whichever of "owner", the executing role or the user a check's rows carry,
// server-side (Api.setOwnerFilter); "owner" and "ran as" stay separate columns in the tables.
export function OwnerFilter({ value, onChange }: { value: string | null | undefined; onChange: (next: string) => void }) {
  // A local draft, committed ~400 ms after the last keystroke: onChange feeds Api.ownerFilterKey(),
  // which keys the page, so committing every keystroke would refetch on every character.
  const [draft, setDraft] = React.useState(value || "");
  React.useEffect(() => { setDraft(value || ""); }, [value]);
  const timerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null);
  const handleChange = (next: string) => {
    setDraft(next);
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => onChange(next), 400);
  };
  React.useEffect(() => () => { if (timerRef.current) clearTimeout(timerRef.current); }, []);
  return (
    <div className="filter-group">
      <span className="filter-label">Owner</span>
      <input
        className="ws-search"
        style={{ width: 130, marginBottom: 0 }}
        placeholder="role or user"
        value={draft}
        onChange={(e) => handleChange(e.target.value)}
        title="Filter checks to rows owned by, or run as, this role or user"
      />
    </div>
  );
}


// Warehouse, database and schema pickers (contract 11.5). The selection lives in Api (module-level,
// mirrored in the hash), so any page's fetch carries it; a component that must refetch when it
// changes calls useDimFilterKey() and puts the key in its deps (App.tsx does for the page).
export function useDimFilterKey() {
  const [key, setKey] = React.useState(Api.dimFilterKey());
  React.useEffect(() => {
    const on = () => setKey(Api.dimFilterKey());
    window.addEventListener("dimfilterchange", on);
    return () => window.removeEventListener("dimfilterchange", on);
  }, []);
  return key;
}

// One searchable multi-select over {value, label} options. A selected value the list no longer has
// (another account, an older link) stays listed so it can be cleared.
export function DimPicker({ label, options, selected, onChange, loadState, emptyText, foot }: {
  label: string; options: DimOption[]; selected: string[]; onChange: (next: string[]) => void;
  loadState: string; emptyText: React.ReactNode; foot?: React.ReactNode;
}) {
  const [open, setOpen] = React.useState(false);
  const [q, setQ] = React.useState("");
  const boxRef = React.useRef<HTMLDivElement>(null);
  usePopoverClose(open, setOpen, boxRef);
  const { popRef, popStyle } = usePopOnScreen(open);
  const known = new Set(options.map((o) => o.value));
  const all: DimOption[] = [...options, ...selected.filter((v) => !known.has(v)).map((v) => ({ value: v, label: v }))];
  const shown = q.trim() ? all.filter((o) => o.label.toLowerCase().includes(q.trim().toLowerCase())) : all;
  const n = selected.length;
  const toggle = (v: string) => onChange(selected.includes(v) ? selected.filter((x) => x !== v) : [...selected, v]);
  return (
    <div className="filter-group ws-picker" ref={boxRef}>
      <span className="filter-label">{label}</span>
      <button className="ws-trigger" onClick={() => setOpen(!open)} title={`Filter by ${label.toLowerCase()}`}>
        {n === 0 ? "All" : `${fmtInt(n)} selected`} <span className="caret">{open ? "▴" : "▾"}</span>
      </button>
      {open && (
        <div className="ws-pop" ref={popRef} style={popStyle}>
          <input className="ws-search" autoFocus placeholder={`Search ${label.toLowerCase()}...`} value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="ws-actions"><button onClick={() => onChange([])}>All</button></div>
          <div className="ws-list">
            {loadState === "loading" && <div className="ws-empty">…</div>}
            {loadState === "error" && <div className="ws-empty">{emptyText}</div>}
            {loadState === "ready" && shown.length === 0 && <div className="ws-empty">{q ? `No ${label.toLowerCase()} matches "${q}".` : emptyText}</div>}
            {shown.map((o) => (
              <label key={o.value} className="ws-row" title={o.title || o.label}>
                <input type="checkbox" checked={selected.includes(o.value)} onChange={() => toggle(o.value)} />
                <span className="ws-name">{o.label}</span>
                {o.note && <span className="muted"> {o.note}</span>}
              </label>
            ))}
          </div>
          {foot && <div className="ws-foot">{foot}</div>}
        </div>
      )}
    </div>
  );
}

// DimFilters: the three pickers for the top bar. `accountIds` narrows the warehouse list.
export function DimFilters({ accountIds }: { accountIds: string[] | null | undefined }) {
  useDimFilterKey();
  const cur = Api.dimFilter();
  const [wh, setWh] = React.useState<{ state: string; list: DimOption[]; note?: string | null }>({ state: "loading", list: [], note: null });
  const [dbs, setDbs] = React.useState<{ state: string; list: Row[] }>({ state: "loading", list: [] });
  const acctKey = JSON.stringify(accountIds || []);
  React.useEffect(() => {
    let live = true;
    Api.warehouses(accountIds)
      .then((d: any) => {
        if (!live) return;
        const seen = new Set();
        const list: DimOption[] = [];
        (d.warehouses || []).forEach((w: Row) => {
          if (seen.has(w.warehouse_name)) return;
          seen.add(w.warehouse_name);
          list.push({ value: w.warehouse_name, label: w.label || w.warehouse_name, note: w.source === "billing" ? "billed, not listed" : null });
        });
        setWh({ state: "ready", list });
      })
      .catch(() => { if (live) setWh({ state: "error", list: [] }); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [acctKey]);
  React.useEffect(() => {
    let live = true;
    Api.databases()
      .then((d: any) => { if (live) setDbs({ state: "ready", list: d.databases || [] }); })
      .catch(() => { if (live) setDbs({ state: "error", list: [] }); });
    return () => { live = false; };
  }, []);
  const set = (dim: "warehouse" | "database" | "schema") => (vals: string[]) => Api.setDimFilter({ ...Api.dimFilter(), [dim]: vals });
  const dbOptions = dbs.list.map((d) => ({ value: d.database_name, label: d.label || d.database_name }));
  // Schemas of the chosen databases, or of every database when none is chosen.
  const chosen = new Set(cur.database.map((x) => x.toUpperCase()));
  const schemaOptions: DimOption[] = [];
  dbs.list.forEach((d) => {
    if (chosen.size && !chosen.has(String(d.database_name).toUpperCase())) return;
    (d.schemas || []).forEach((sc: Row) => schemaOptions.push({ value: sc.fqn, label: sc.fqn }));
  });
  return (
    <React.Fragment>
      <DimPicker label="Warehouse" options={wh.list} selected={cur.warehouse} onChange={set("warehouse")} loadState={wh.state}
        emptyText="No warehouses in this export." foot={`${fmtInt(wh.list.length)} warehouses`} />
      <DimPicker label="Database" options={dbOptions} selected={cur.database} onChange={set("database")} loadState={dbs.state}
        emptyText="No databases in this export." foot={`${fmtInt(dbOptions.length)} databases`} />
      <DimPicker label="Schema" options={schemaOptions} selected={cur.schema} onChange={set("schema")} loadState={dbs.state}
        emptyText="No schemas in this export." foot={`${fmtInt(schemaOptions.length)} schemas`} />
    </React.Fragment>
  );
}

// "not filtered by warehouse" for a check whose rows ignored an asked-for dimension. `dimApplied` is a
// finding row's dim_applied, or a finding response's scope.{warehouse,database,schema}_applied.
export function dimNotApplied(dimApplied: DimApplied) {
  const out: string[] = [];
  ["warehouse", "database", "schema"].forEach((d) => { if (dimApplied && dimApplied[d] === false) out.push(d); });
  return out;
}
export function dimAppliedFromScope(scope: Row | null | undefined): DimApplied {
  if (!scope) return null;
  return { warehouse: scope.warehouse_applied, database: scope.database_applied, schema: scope.schema_applied };
}
export function DimNotAppliedChip({ dimApplied }: { dimApplied: DimApplied }) {
  const off = dimNotApplied(dimApplied);
  if (!off.length) return null;
  return <Badge kind="info">{`not filtered by ${off.join(" or ")}`}</Badge>;
}

