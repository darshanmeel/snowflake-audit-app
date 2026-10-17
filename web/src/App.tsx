// web/src/App.tsx -- root orchestrator: filters (window + account, ALL accounts selected by default),
// the shell (a left rail with the lens's grouped pages, a top bar with the window, export status, a
// Filters popover and Save as PDF, a menu drawer below ~900px), and cross-tab navigation (next:
// chips, Overview's fix-first list and every "How is this worked out?" link land on the right area via
// QUERY_HOME / homeForQuery, tab_registry.tsx). Every area (except Guide) renders through AreaPage
// (primitives.tsx): this file owns the shell only, never an area's own content.

// An account id no real account can equal: an attribute filter matching none of the currently
// picked accounts sends this rather than [] (this app's own "no filter = every account" convention).
import React from "react";
import { setAuditRange } from "./range_store";
import { Api, acctId, BRAND_NAME } from "./api";
import { LOCALE, fmtInt, fmtMoneyShort } from "./format";
import { HashState } from "./components/hash_state";
import { setCanDrill } from "./components/names";
import { useDims } from "./components/hooks";
import { FirstRunScreen } from "./components/first_run";
import { AttributeFilters, DimFilters, OwnerFilter, useDimFilterKey } from "./components/filters";
import { SettingsGearButton } from "./components/settings_panel";
import { TagPicker, TagScopeBanner, narrowingTag } from "./components/tag_picker";
import { AREA_ORDER, AREA_REGISTRY, OLD_SUBTAB_REDIRECTS, OLD_TAB_REDIRECTS, countsForIds, homeForQuery, visibleSubtabs } from "./components/tab_registry";
import { AreaPage, ErrorBoundary, PageFooter, PageIntro, WindowCoverageNote, pageEyebrow, printWholePage, priceLabelOf, ranCountsOf, ranCountsText } from "./components/primitives";
import { LENS_LABEL, activeNavItem, lensNav, lensTabs, navItemLabel, pageLabel } from "./components/lens_nav";
import type { NavItem } from "./components/lens_nav";
import { buildWasteWorklist, wasteTotal } from "./components/waste_total";
import { registerCheckTitles } from "./components/labels";
import { setCostCutoff, windowRangeLabel } from "./components/overview_tile";
import { TagsPage } from "./tabs/tab_tags";
import { MoneyTab } from "./tabs/tab_money";
import { TaskPanelOverlay } from "./components/task_panel";
import { readNavHash } from "./components/nav_hash";
import { GuideTab } from "./components/guide";
// Each tab module registers its sub-tab content into AreaContent when it loads; some export nothing else.
import { CtoOverview } from "./tabs/tab_overview";
import { DeOverview } from "./tabs/tab_overview_de";
import "./tabs/tab_cost";
import "./tabs/tab_area";
import "./tabs/tab_waste";
import "./tabs/tab_actions";
import "./tabs/tab_findings";
import "./tabs/tab_coverage";
import { PageCopyLink } from "./components/fixcopy_button";
import type { Filters, Finding, GoTo, Meta, Row, TagFilter } from "./types";

interface WindowOpt { days: number; available: boolean; covered_days: number; partial: boolean }
interface RefreshStatus { running?: boolean; elapsed_s?: number | null; step?: string; error?: string | null; [key: string]: any }
interface NavState { tab: string; subtab: string | null; domain: string | null; focusQueryId: string | null }
type AttrFilters = Record<string, Set<string>>;

interface AccountPickerProps {
  accounts: Row[];
  selected: Set<string> | null;
  onToggle: (id: string) => void;
  onAll: () => void;
  onNone: () => void;
  onSetMany: (ids: string[]) => void;
}

/** The filter controls the top bar and the mobile drawer both carry. */
interface FilterControlProps {
  meta: Meta | null;
  windows: WindowOpt[] | null;
  filtersWindow: number;
  onSetWindow: (days: number) => void;
  accounts: Row[];
  pickerSelected: Set<string> | null;
  toggleAccount: (id: string) => void;
  selectAll: () => void;
  selectNone: () => void;
  setManyAccounts: (ids: string[]) => void;
  attrFilters: AttrFilters;
  onAttrChange: (key: string, next: Set<string>) => void;
  tagFilter: TagFilter | null;
  onTagChange: (value: TagFilter | null) => void;
  ownerFilter: string;
  onOwnerChange: (next: string) => void;
  accountIds: string[];
  role: string;
  onRoleChange: (role: string) => void;
  /** "applies to N of M checks" while an owner filter is set, else null. */
  ownerReach?: string | null;
}

interface NavProps {
  role: string;
  activeArea: string;
  activeSubtab: string | null;
  onSelectItem: (item: NavItem) => void;
  findings: Finding[] | null;
  meta: Meta | null;
  /** Possible waste $ (the one wasteTotal figure); null when no waste check gives one. */
  wasteUsd: number | null | undefined;
}

export const NO_ACCOUNT_MATCH = "__no_account_matches_filters__";

// Area keys (tab_registry.tsx's AREA_REGISTRY) plus "guide", the one tab with no AreaPage: the
// sidebar's own row order (every area, not a curated subset).
export const TAB_KEYS = [...AREA_ORDER, "guide"];
// "money" is CFO-only in the sidebar (sidebarKeysForRole below) but still a real, linkable tab:
// accepted here so a shared link naming it, or a bookmark from before a role switch, still opens it.
// A hash may carry an old tab key: accepted here, translated once below.
// "tags" is the mandatory-tag page (tab_tags.tsx): a page of its own, listed under Cost, not an AreaPage.
export const ALL_ACCEPTED_HASH_TABS = [...TAB_KEYS, "money", "tags", ...Object.keys(OLD_TAB_REDIRECTS)];
export const hasTagsPage = () => typeof TagsPage !== "undefined";

export function areaLabel(key: string, role?: string) {
  return pageLabel(key, role);
}

// ─────────── Roles ("View as", top bar): a persona, never a permission boundary -- it only picks
// which areas the sidebar shows, their order, the landing area, and (CTO) whether an area opens
// its summary or its full drill-down. Kept in the hash (role=) and localStorage, same convention
// theme family/mode already use below.
export const ROLES = ["finops", "data_engineer", "governance", "cto", "cfo"];
export const ROLE_LABEL: Record<string, string> = LENS_LABEL;
export function getStoredRole() {
  try {
    const v = localStorage.getItem("role");
    return ROLES.includes(v as string) ? v : null;
  } catch (e) {
    return null; // localStorage unavailable -- FinOps stays the default
  }
}
// Every role lands on its Overview (the CFO's is the money page).
export function homeForRole(role: string) {
  return role === "cfo" ? "money" : "overview";
}
// `priority` first (in the order given), then the rest of `order` in its existing relative order.
export function reorderPriority(order: string[], priority: string[]) {
  const first = new Set(priority);
  return [...priority, ...order.filter((k) => !first.has(k))];
}
// Every content area (AREA_ORDER) minus "overview" and "findings".
export const CONTENT_AREAS = AREA_ORDER.filter((k) => k !== "overview" && k !== "findings");
export const inAreaOrder = (list: string[]) => AREA_ORDER.filter((k) => list.includes(k));
// roleAreasFor: the area keys a lens lists in its sidebar (lens_nav.ts), passed into AreaPage so
// Actions and "All findings" filter to the same set. The CFO's money actions also cover AI spend.
const NOT_CONTENT = new Set(["overview", "findings", "money", "tags", "guide"]);
export const ROLE_AREAS: Record<string, string[]> = Object.fromEntries(ROLES.map((r) => {
  const areas = lensTabs(r).filter((k) => !NOT_CONTENT.has(k));
  return [r, r === "cfo" ? inAreaOrder([...areas, "ai"]) : areas];
}));
export function roleAreasFor(role: string) {
  return ROLE_AREAS[role] || ROLE_AREAS.finops;
}
// The pages a lens lists, each once, in sidebar order.
export function sidebarKeysForRole(role: string) {
  return lensTabs(ROLES.includes(role) ? role : "finops");
}
// A link or bookmark to a page this role does not show lands on the role's home page instead.
export function clampTabForRole(tab: string, role: string) {
  return sidebarKeysForRole(role).includes(tab) ? tab : homeForRole(role);
}

// ─────────── Theme: light or dark; with nothing stored it follows the OS. ───────────
export function getStoredThemeMode() {
  try {
    const v = localStorage.getItem("theme");
    return v === "light" || v === "dark" ? v : null;
  } catch (e) {
    return null;
  }
}
export function prefersDark() {
  return !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
}
export function applyTheme(mode: string | null) {
  const dark = mode === "dark" || (mode === null && prefersDark());
  if (dark) document.documentElement.setAttribute("data-theme", "dark");
  else document.documentElement.removeAttribute("data-theme");
  // Charts that read CSS variables at render time re-render on this event.
  window.dispatchEvent(new Event("themechange"));
}

// One choice for the page: the rail's toggle and the mobile drawer's both read and set it.
export let themeMode: string | null = getStoredThemeMode(); // null = follow the OS

export function ThemeToggle() {
  const [mode, setMode] = React.useState(themeMode);
  const [osDark, setOsDark] = React.useState(prefersDark);
  React.useEffect(() => { applyTheme(mode); }, [mode, osDark]);
  React.useEffect(() => {
    const onTheme = () => setMode(themeMode);
    window.addEventListener("themechange", onTheme);
    const mq = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => setOsDark(mq.matches);
    if (mq) { if (mq.addEventListener) mq.addEventListener("change", onChange); else mq.addListener(onChange); }
    return () => {
      window.removeEventListener("themechange", onTheme);
      if (mq) { if (mq.removeEventListener) mq.removeEventListener("change", onChange); else mq.removeListener(onChange); }
    };
  }, []);
  const isDark = mode === "dark" || (mode === null && osDark);
  const choose = (next: string) => {
    try { localStorage.setItem("theme", next); } catch (e) { /* this session's state still drives it */ }
    themeMode = next;
    setMode(next);
  };
  return (
    <div className="c-theme" role="group" aria-label="Theme">
      <button type="button" aria-pressed={!isDark} onClick={() => choose("light")}>Light</button>
      <button type="button" aria-pressed={isDark} onClick={() => choose("dark")}>Dark</button>
    </div>
  );
}

// The role ("lens") picks which pages the rail lists.
export function LensSelect({ role, onChange }: { role: string; onChange: (role: string) => void }) {
  return (
    <label className="c-lens" title="Picks which pages you see. The data is the same in every lens.">
      <span className="c-rail-label">Lens</span>
      <select value={role} onChange={(e) => onChange(e.target.value)} aria-label="View as">
        {ROLES.map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
      </select>
    </label>
  );
}

export function BrandMark() {
  return (
    <span className="brand-mark" aria-hidden="true">
      <svg width="12" height="12" viewBox="0 0 16 16" fill="none">
        <path d="M8 1V15M1 8H15" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
    </span>
  );
}

// "25 Sep 19:06" (direct export's real as-of instant) or "25 Sep" (a snapshot's as-of date, no
// time captured) -- day + short month first, 24h clock, always UTC (the value this app is given).
export function fmtSnapshotWhen(value: unknown) {
  if (!value) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(String(value).trim());
  if (!m) return null;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4] || 0), Number(m[5] || 0)));
  if (Number.isNaN(d.getTime())) return null;
  const datePart = d.toLocaleDateString(LOCALE, { day: "numeric", month: "short", timeZone: "UTC" });
  if (m[4] == null) return datePart;
  return `${datePart} ${d.toLocaleTimeString(LOCALE, { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: "UTC" })}`;
}

// ─────────── Snapshot status: the common rule's own line -- source, as-of and checks that ran, all
// visible (not hidden behind a hover), plus an amber dot when any model failed or wasn't built. ──
export function SnapshotStatus({ meta }: { meta: Meta | null }) {
  if (!meta) return <span className="muted">…</span>;
  const direct = meta.direct_export;
  const source = direct ? "Snowflake" : null;
  const when = direct ? fmtSnapshotWhen(direct.as_of) : null;
  const m = meta.models || {};
  // The one checks-that-ran count comes from the API (meta.checks_ran), never worked out here.
  const checksText = ranCountsOf(meta) ? ranCountsText(meta) : null;
  const dotCls = !source ? "unknown" : (m.failed > 0 || m.not_built > 0) ? "stale" : "";
  // The export took in today up to its run time, so today's figures are not final.
  const partialToday = !!(direct && direct.includes_today);
  const exportText = source && when ? `Export ${when}${partialToday ? " UTC" : ""}` : source;
  const parts = [exportText, partialToday ? "today partial" : null, checksText].filter(Boolean);
  const notes = [];
  if (m.failed || m.not_built) notes.push(`${fmtInt(m.failed || 0)} failed, ${fmtInt(m.not_built || 0)} not in this export`);
  if (partialToday) notes.push(`Today is included up to ${when} UTC; its figures are partial and billing can lag a few hours`);
  const title = notes.length ? notes.join(". ") : undefined;
  return (
    <span className="row snapshot-status" style={{ gap: 6 }} title={title}>
      <span className={`snapshot-dot ${dotCls}`}></span>
      <span className="muted">{parts.length ? parts.join(" · ") : "no snapshot captured yet"}</span>
    </span>
  );
}

// Refresh from Snowflake: the app is not live, so it says when the data was last pulled and that a
// refresh runs every check on your warehouse (credits), then lets the viewer run it anyway.
export const REFRESH_DAYS = [7, 15, 30, 60, 90];

export function agoText(asOf: string | null | undefined) {
  const t = asOf ? Date.parse(String(asOf).replace(" ", "T") + (/[zZ]|[+-]\d\d:?\d\d$/.test(asOf) ? "" : "Z")) : NaN;
  if (Number.isNaN(t)) return null;
  const h = (Date.now() - t) / 3600000;
  return h < 1 ? `${Math.max(1, Math.round(h * 60))} min ago` : h < 48 ? `${Math.round(h)} h ago` : `${Math.round(h / 24)} days ago`;
}

export function RefreshControl({ meta }: { meta: Meta | null }) {
  const [open, setOpen] = React.useState(false);
  const [days, setDays] = React.useState(30);
  const [st, setSt] = React.useState<RefreshStatus | null>(null);
  const boxRef = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => { Api.refreshStatus().then(setSt).catch(() => {}); }, []);
  React.useEffect(() => {
    if (!st || !st.running) return undefined;
    const t = setTimeout(() => Api.refreshStatus().then((s: RefreshStatus) => {
      setSt(s);
      if (s.step === "done") window.location.reload();
    }).catch(() => {}), 3000);
    return () => clearTimeout(t);
  }, [st]);
  React.useEffect(() => {
    if (!open) return undefined;
    const onDoc = (e: MouseEvent) => { if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, [open]);

  const direct = meta && meta.direct_export;
  const when = direct ? fmtSnapshotWhen(direct.as_of) : null;
  const ago = direct ? agoText(direct.as_of) : null;
  const running = !!(st && st.running);
  const mins = running && st!.elapsed_s != null ? Math.floor(st!.elapsed_s / 60) : 0;
  const stepText = running ? (st!.step === "load" ? "Loading into the app" : "Running the checks on Snowflake") : null;
  return (
    <div className="ws-picker refresh-control" ref={boxRef}>
      <button type="button" className="ws-trigger" onClick={() => setOpen(!open)} title="Pull fresh data from Snowflake">
        {running ? `Refreshing… ${mins} min` : "Refresh"}
      </button>
      {open && (
        <div className="ws-pop refresh-pop">
          <div className="refresh-last">{when ? `Last refresh: ${when} UTC${ago ? ` (${ago})` : ""}.` : "No refresh from Snowflake yet."}</div>
          <div className="muted refresh-note">
            This dashboard is not live. A refresh runs every check on your Snowflake warehouse, which uses credits, and takes several minutes. Refresh only when you need newer data.
          </div>
          {running ? (
            <div className="refresh-running">{`${stepText}… ${mins} min so far. The page reloads when it is done.`}</div>
          ) : (
            <React.Fragment>
              <div className="ws-actions">
                {REFRESH_DAYS.map((d) => (
                  <button key={d} type="button" className={d === days ? "on" : ""} onClick={() => setDays(d)}>{`Last ${d} days`}</button>
                ))}
              </div>
              {st && st.step === "failed" && <div className="refresh-error">{`Last refresh failed: ${st.error}`}</div>}
              <div className="tag-actions">
                <button type="button" className="tag-apply" onClick={() => Api.refreshStart(days).then(setSt)}>{`Refresh last ${days} days`}</button>
              </div>
            </React.Fragment>
          )}
        </div>
      )}
    </div>
  );
}

// ─────────── Window control: one segmented button per available GET /api/meta `windows` entry.
// A window this database never exported is HIDDEN (never a dead disabled button); a partially
// exported one is labelled "partial", so "30d" never silently reads as a full 30 days of money when
// the export only ran 10. ───────────
export function WindowControl({ windows, value, onChange }: { windows: WindowOpt[] | null; value: number; onChange: (days: number) => void }) {
  const list: WindowOpt[] = windows && windows.length ? windows : [7, 30, 90].map((d) => ({ days: d, available: true, covered_days: d, partial: false }));
  const shown = list.filter((w) => w.available);
  return (
    <div className="seg window-seg">
      {shown.map((w) => (
        <button
          key={w.days}
          type="button"
          className={value === w.days ? "active" : ""}
          title={w.partial ? `Partial: ${fmtInt(w.covered_days)} of ${w.days} days exported` : `${w.days} days`}
          onClick={() => onChange(w.days)}
        >
          {w.days}d{w.partial ? " partial" : ""}
        </button>
      ))}
    </div>
  );
}

// ─────────── Accounts: a dropdown, not a wall of chips (an organization can carry many). Hidden when
// the export holds a single account: there is nothing to pick. ───────
export function AccountPickerBody({ accounts, selected, onToggle, onAll, onNone, onSetMany }: AccountPickerProps) {
  const [q, setQ] = React.useState("");
  const sorted = React.useMemo(() => {
    const copy = accounts.slice();
    copy.sort((a, b) => {
      const an = a.name || "", bn = b.name || "";
      if (!!an !== !!bn) return an ? -1 : 1;
      return (an || String(acctId(a))).localeCompare(bn || String(acctId(b)));
    });
    return copy;
  }, [accounts]);

  const needle = q.trim().toLowerCase();
  const shown = needle
    ? sorted.filter((a) => (a.name || "").toLowerCase().includes(needle) || String(acctId(a)).toLowerCase().includes(needle))
    : sorted;
  const total = accounts.length;
  const n = selected ? accounts.filter((a) => selected.has(acctId(a))).length : 0;

  return (
    <React.Fragment>
      <input className="ws-search" placeholder="Search name or id..." value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="ws-actions">
        <button onClick={needle ? () => onSetMany(shown.map((a) => acctId(a))) : onAll}>{needle ? `All ${shown.length} shown` : "All"}</button>
        <button onClick={onNone}>None</button>
      </div>
      <div className="ws-list">
        {shown.length === 0 && <div className="ws-empty">No account matches "{q}"</div>}
        {shown.map((a) => (
          <label key={acctId(a)} className="ws-row">
            <input type="checkbox" checked={selected ? selected.has(acctId(a)) : false} onChange={() => onToggle(acctId(a))} />
            <span className={`ws-name ${a.name ? "" : "idonly"}`}>{a.name ? `${a.name} (${acctId(a)})` : acctId(a)}</span>
          </label>
        ))}
      </div>
      <div className="ws-foot">{shown.length} shown · {n} of {total} accounts selected</div>
    </React.Fragment>
  );
}

// Self-anchored dropdown trigger for the Account control (same .ws-picker/.ws-trigger/.ws-pop shape
// as AttributePicker/TagPicker, so the top-bar pickers behave identically).
export function AccountsControl({ accounts, selected, onToggle, onAll, onNone, onSetMany }: AccountPickerProps) {
  const [open, setOpen] = React.useState(false);
  const boxRef = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => {
    if (!open) return undefined;
    const onDocClick = (e: MouseEvent) => { if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false); };
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDocClick);
    document.addEventListener("keydown", onEsc);
    return () => { document.removeEventListener("mousedown", onDocClick); document.removeEventListener("keydown", onEsc); };
  }, [open]);

  if (accounts.length < 2) return null;
  const total = accounts.length;
  const n = selected ? accounts.filter((a) => selected.has(acctId(a))).length : 0;
  const label = total > 0 && n === total ? `All ${total}` : n === 0 ? "None" : `${n} of ${total}`;

  return (
    <div className="filter-group ws-picker" ref={boxRef}>
      <span className="filter-label">Account</span>
      <button type="button" className="ws-trigger" onClick={() => setOpen(!open)} title="Filter by account">
        {label} <span className="caret">{open ? "▴" : "▾"}</span>
      </button>
      {open && (
        <div className="ws-pop">
          <AccountPickerBody accounts={accounts} selected={selected} onToggle={onToggle} onAll={onAll} onNone={onNone} onSetMany={onSetMany} />
        </div>
      )}
    </div>
  );
}

// ─────────── Filters: one button in the top bar; the tag, owner, warehouse, database, schema and
// account pickers, plus refresh and settings, open in its popover. The button counts the active ones.
export function FiltersControl({
  meta, filtersWindow, accounts, pickerSelected, toggleAccount, selectAll, selectNone, setManyAccounts,
  attrFilters, onAttrChange, tagFilter, onTagChange, ownerFilter, onOwnerChange, accountIds, ownerReach, activeCount,
}: FilterControlProps & { activeCount: number }) {
  const [open, setOpen] = React.useState(false);
  const boxRef = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => {
    if (!open) return undefined;
    const onDoc = (e: MouseEvent) => { if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false); };
    const onEsc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onEsc);
    return () => { document.removeEventListener("mousedown", onDoc); document.removeEventListener("keydown", onEsc); };
  }, [open]);
  const countText = activeCount > 0 ? `${fmtInt(activeCount)} filter${activeCount === 1 ? "" : "s"} on` : "No filters on";
  return (
    <div className="ws-picker filters-control" ref={boxRef}>
      <button type="button" className="topbar-btn" aria-expanded={open} onClick={() => setOpen(!open)} title={countText}>
        <svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <path d="M2 3.5h12M4.5 8h7M7 12.5h2" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
        Filters
        {activeCount > 0 && <span className="filters-count" aria-label={countText}>{fmtInt(activeCount)}</span>}
      </button>
      {open && (
        <div className="ws-pop filters-pop">
          <div className="filters-pop-body">
            <AttributeFilters
              accounts={accounts}
              populatedKeys={(meta && meta.attribute_keys_populated) || []}
              selected={attrFilters}
              onChange={onAttrChange}
            />
            <TagPicker value={tagFilter} onChange={onTagChange} windowDays={filtersWindow} />
            <OwnerFilter value={ownerFilter} onChange={onOwnerChange} />
            {ownerReach && <span className="muted owner-reach" title="Checks with no owner, role or user column are not narrowed by the owner filter">{ownerReach}</span>}
            <DimFilters accountIds={accountIds} />
            <AccountsControl
              accounts={accounts} selected={pickerSelected} onToggle={toggleAccount}
              onAll={selectAll} onNone={selectNone} onSetMany={setManyAccounts}
            />
          </div>
          <div className="filters-pop-foot">
            <RefreshControl meta={meta} />
            <SettingsGearButton />
          </div>
        </div>
      )}
    </div>
  );
}

// ─────────── Top bar: window, export status, then Filters and Save as PDF. Pages are in the rail.
export function TopBar(props: FilterControlProps & { onOpenNavDrawer: () => void; activeFilterCount: number }) {
  const { meta, onOpenNavDrawer, filtersWindow, windows, onSetWindow, activeFilterCount } = props;
  // Sticky panels below the bar offset themselves by its real height; it wraps on narrow screens.
  const barRef = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => {
    const el = barRef.current;
    if (!el || !window.ResizeObserver) return undefined;
    const ro = new ResizeObserver(() => document.documentElement.style.setProperty("--topbar-h", `${el.offsetHeight}px`));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return (
    <div className="topbar" ref={barRef}>
      <button type="button" className="topbar-menu-btn" onClick={onOpenNavDrawer} aria-label="Open areas menu">☰</button>
      <div className="brand topbar-brand">
        <BrandMark />
        <span className="brand-title">{(meta && meta.brand && meta.brand.name) || BRAND_NAME}</span>
      </div>

      <div className="topbar-controls">
        <WindowControl windows={windows} value={filtersWindow} onChange={onSetWindow} />
        <SnapshotStatus meta={meta} />
        <span className="topbar-spacer" />
        <FiltersControl {...props} activeCount={activeFilterCount} />
        <PageCopyLink />
        <button type="button" className="topbar-btn print-page-btn" onClick={printWholePage}>Save as PDF</button>
      </div>
    </div>
  );
}

// ─────────── Left sidebar: the lens's pages in its groups (lens_nav.ts), each with one count. Sub-tabs
// live in the page head, not here. Hidden below ~900px -- SideNavDrawer takes over. ───────────
interface NavCount { text: string; crit?: boolean; title: string }

// The count beside an entry: critical checks in that area or sub-tab (crit colour); Waste & savings
// its possible-waste $; Coverage the checks that did not run; All findings the checks that ran.
export function navCountFor(item: NavItem, findings: Finding[] | null, meta: Meta | null, wasteUsd: number | null | undefined): NavCount | null {
  const ran = ranCountsOf(meta);
  if (item.tab === "findings") return ran ? { text: fmtInt(ran.assessed), title: ranCountsText(meta) } : null;
  if (item.tab === "coverage") {
    if (!ran) return null;
    const notRun = ran.total - ran.assessed;
    return { text: `${fmtInt(notRun)} not run`, title: `${fmtInt(notRun)} of ${fmtInt(ran.total)} ${ran.unit} did not run` };
  }
  if (!findings) return null;
  if (item.tab === "waste") {
    return wasteUsd != null
      ? { text: fmtMoneyShort(wasteUsd), title: "Possible waste over the window, the same figure as on Waste & savings" }
      : { text: "–", title: "No possible-waste figure: no waste check ran, or the flagged ones carry no $" };
  }
  const area = AREA_REGISTRY[item.tab];
  if (!area || !area.subtabs.length) return null;
  const subs = item.subtab ? area.subtabs.filter((s) => s.key === item.subtab) : visibleSubtabs(item.tab, findings);
  const crit = subs.reduce((n, s) => n + countsForIds(findings, s.ids, s.refIds).critical, 0);
  return crit > 0 ? { text: fmtInt(crit), crit: true, title: `${fmtInt(crit)} critical check${crit === 1 ? "" : "s"}` } : null;
}

// The lit entry: AreaPage opens an area on its first visible sub-tab when the hash names none.
export function useActiveNavItem(role: string, activeArea: string, activeSubtab: string | null, findings: Finding[] | null) {
  const subs = AREA_REGISTRY[activeArea] ? visibleSubtabs(activeArea, findings) : [];
  const currentSub = subs.some((s) => s.key === activeSubtab) ? activeSubtab : (subs[0] ? subs[0].key : null);
  return activeNavItem(role, activeArea, currentSub);
}

export function SideNav({ role, activeArea, activeSubtab, onSelectItem, findings, meta, wasteUsd, variant = "rail" }: NavProps & { variant?: "rail" | "drawer" }) {
  const active = useActiveNavItem(role, activeArea, activeSubtab, findings);
  const drawer = variant === "drawer";
  return (
    <nav className={drawer ? "mobile-nav-list" : "side-nav"} aria-label="Pages">
      {lensNav(role).map((g, gi) => (
        <div key={gi} className="side-nav-group">
          {g.label && <div className={drawer ? "mobile-nav-group" : "c-rail-label side-nav-label"}>{g.label}</div>}
          {g.items.map((it) => {
            const isActive = active === it;
            const c = navCountFor(it, findings, meta, wasteUsd);
            return (
              <button
                key={`${it.tab}:${it.subtab || ""}`}
                type="button"
                className={`${drawer ? "mobile-nav-link" : "side-nav-link"} ${isActive ? "active" : ""}`}
                aria-current={isActive ? "page" : undefined}
                onClick={() => onSelectItem(it)}
              >
                <span className="side-nav-text">{navItemLabel(it, role)}</span>
                {c && <span className={`side-nav-count${c.crit ? " crit" : ""}`} title={c.title}>{c.text}</span>}
              </button>
            );
          })}
        </div>
      ))}
    </nav>
  );
}

// The dark left rail: brand, lens, the lens's grouped pages, then the theme pinned at the bottom.
export function Rail(props: NavProps & { onRoleChange: (role: string) => void }) {
  const { meta, role, onRoleChange } = props;
  return (
    <aside className="c-rail">
      <div className="brand c-brand">
        <BrandMark />
        <span className="brand-title">{(meta && meta.brand && meta.brand.name) || BRAND_NAME}</span>
      </div>
      <LensSelect role={role} onChange={onRoleChange} />
      <div className="c-rail-nav">
        <SideNav {...props} />
      </div>
      <div className="c-rail-foot">
        <ThemeToggle />
      </div>
    </aside>
  );
}

// ─────────── Mobile nav drawer (below ~900px): the same grouped pages as the rail, plus the window
// control, every filter and the theme: the top bar's controls are hidden at this width. ───────
export function SideNavDrawer(props: FilterControlProps & NavProps & { onClose: () => void }) {
  const {
    onClose, windows, filtersWindow, onSetWindow, meta,
    accounts, pickerSelected, toggleAccount, selectAll, selectNone, setManyAccounts,
    attrFilters, onAttrChange, tagFilter, onTagChange, ownerFilter, onOwnerChange, accountIds,
    role, onRoleChange, onSelectItem,
  } = props;
  return (
    <React.Fragment>
      <div className="mobile-nav-backdrop" onClick={onClose}></div>
      <div className="mobile-nav">
        <button type="button" className="mobile-nav-close" onClick={onClose} aria-label="Close">✕</button>
        <WindowControl windows={windows} value={filtersWindow} onChange={onSetWindow} />
        <div className="mobile-nav-filters">
          <AttributeFilters
            accounts={accounts}
            populatedKeys={(meta && meta.attribute_keys_populated) || []}
            selected={attrFilters}
            onChange={onAttrChange}
          />
          <TagPicker value={tagFilter} onChange={onTagChange} windowDays={filtersWindow} />
          <OwnerFilter value={ownerFilter} onChange={onOwnerChange} />
          <DimFilters accountIds={accountIds} />
          <AccountsControl
            accounts={accounts} selected={pickerSelected} onToggle={toggleAccount}
            onAll={selectAll} onNone={selectNone} onSetMany={setManyAccounts}
          />
        </div>
        <div className="mobile-nav-row">
          <LensSelect role={role} onChange={onRoleChange} />
          <SettingsGearButton />
          <ThemeToggle />
          <PageCopyLink className="topbar-btn" />
        </div>
        <SideNav {...props} variant="drawer" onSelectItem={(it) => { onSelectItem(it); onClose(); }} />
      </div>
    </React.Fragment>
  );
}

// This page's own address bar at mount time, read exactly once: every "restore on load" below reads
// off this ONE snapshot rather than location.hash directly.
export function useInitialHash() {
  return React.useState(() => {
    try { return HashState.get(); } catch (e) { return new URLSearchParams(); }
  })[0];
}

// The filters a link carries: window, account ids, attribute filters and tag filter.
export function filtersFromHash(p: URLSearchParams) {
  const w = Number(p.get("w"));
  const ws = p.get("ws");
  const attr: AttrFilters = {};
  Array.from(p.keys()).forEach((k) => {
    const v = p.get(k);
    if (k.indexOf("attr_") === 0 && v) attr[k.slice(5)] = new Set(v.split(","));
  });
  let tag: TagFilter | null = null;
  try {
    const groups = JSON.parse(p.get("tags") || "null");
    if (Array.isArray(groups) && groups.length) tag = { groups: groups.map(([key, display_key, values, all]: [string, string, string[] | null, number?]) => ({ key, display_key, values: values || [], ...(all ? { all: true } : {}) })) };
  } catch (e) { /* a hand-edited link with a broken tags value just drops the tag filter */ }
  return {
    window: w > 0 ? w : null,
    acctIds: ws ? new Set(ws.split(",").filter(Boolean)) : null,
    attr,
    tag,
  };
}

export function accountSetFromHash(acctIds: Set<string> | null, list: Row[]) {
  const matched = acctIds ? list.filter((a) => acctIds.has(String(acctId(a)))).map((a) => acctId(a)) : [];
  return new Set(matched.length ? matched : list.map((a) => acctId(a)));
}

export const sameSet = (a: Set<string> | null, b: Set<string> | null) => !!a && !!b && a.size === b.size && Array.from(a).every((x) => b.has(x));
export const attrFiltersKey = (a: AttrFilters) => JSON.stringify(Object.keys(a).filter((k) => a[k] && a[k].size).sort()
  .map((k) => [k, Array.from(a[k]).sort()]));
export const tagFilterStateKey = (t: TagFilter | null) => (t ? JSON.stringify(t.groups) : "");

// A link carrying an old tab/sub-tab key still lands on the right place.
export function applyOldKeyRedirects<T extends { tab: string; subtab: string | null }>(nav: T | null): T | null {
  if (!nav) return nav;
  let tab = nav.tab;
  let subtab = nav.subtab;
  if (OLD_TAB_REDIRECTS[tab] && !AREA_REGISTRY[tab]) tab = OLD_TAB_REDIRECTS[tab];
  // A key in the map can also be a real sub-tab of the resolved area: the real key always wins over
  // the stale redirect.
  // Admin and change checks moved from Access to their own Audit tab.
  if (tab === "access" && subtab === "admins") tab = "audit";
  const area = AREA_REGISTRY[tab];
  const isLiveSubtab = area && (area.subtabs || []).some((s) => s.key === subtab);
  if (subtab && !isLiveSubtab && OLD_SUBTAB_REDIRECTS[subtab]) subtab = OLD_SUBTAB_REDIRECTS[subtab];
  return { ...nav, tab, subtab };
}

// An empty brand part is dropped with its separator, so the line never shows a gap.
export function BrandFooter({ meta }: { meta: Meta | null }) {
  const brand = (meta && meta.brand) || {};
  const parts: React.ReactNode[] = [`© ${new Date().getFullYear()} ${brand.name || BRAND_NAME}`];
  if (brand.url) {
    const bare = brand.url.replace(/^https?:\/\//, "");
    const href = bare === brand.url ? `https://${bare}` : brand.url;
    parts.push(<a key="url" href={href} target="_blank" rel="noreferrer">{bare}</a>);
  }
  if (brand.contact_name) parts.push(brand.contact_name);
  if (brand.contact_email) {
    parts.push(<a key="mail" href={`mailto:${brand.contact_email}`}>{brand.contact_email}</a>);
  }
  return (
    <div className="footer-note">
      {parts.map((part, i) => (
        <React.Fragment key={i}>
          {i > 0 && " · "}
          {part}
        </React.Fragment>
      ))}
    </div>
  );
}

// The Tags page (tab_tags.tsx) with the shell's usual page header: it reports its own verdict line.
export function TagsRoute({ filters, meta, role }: { filters: Filters; meta: Meta | null; role: string }) {
  const [verdict, setVerdict] = React.useState<React.ReactNode>(null);
  return (
    <div>
      <PageIntro
        overline={pageEyebrow(role, "Tags", meta, filters.window)}
        title="Tags"
        scope="Required cost tags, and how much spend each tag key reaches"
        guideTab="tags"
        verdict={verdict}
      />
      <WindowCoverageNote meta={meta} windowDays={filters.window} />
      <TagsPage filters={filters} windowDays={filters.window} onVerdict={setVerdict} priceLabel={priceLabelOf(meta)} />
      <PageFooter meta={meta} tab="tags" />
    </div>
  );
}

export function App() {
  const initHash = useInitialHash();
  const [meta, setMeta] = React.useState<Meta | null>(null);
  const [accounts, setAccounts] = React.useState<Row[]>([]);
  const [findings, setFindings] = React.useState<Finding[] | null>(null);
  const [loadError, setLoadError] = React.useState<string | null>(null);
  const [appState, setAppState] = React.useState<Row | null>(null);
  const [navDrawerOpen, setNavDrawerOpen] = React.useState(false);
  const initFilters = React.useMemo(() => filtersFromHash(initHash), [initHash]);
  const initHashWindow = initFilters.window;
  const [window_, setWindow_] = React.useState(initHashWindow || 30);
  const [accountIdSet, setAccountIdSet] = React.useState<Set<string> | null>(null);
  const accountsRef = React.useRef<Row[]>([]);
  accountsRef.current = accounts;
  const dimKey = useDimFilterKey();
  const [attrFilters, setAttrFilters] = React.useState(initFilters.attr);
  const [tagFilter, setTagFilterState] = React.useState(initFilters.tag);
  const [ownerFilter, setOwnerFilter] = React.useState(() => (initHash.get("owner") || "").trim());
  const initialRole = React.useMemo(() => {
    const fromHash = initHash.get("role");
    if (ROLES.includes(fromHash as string)) return fromHash as string;
    return getStoredRole() || "finops";
  }, [initHash]);
  const [role, setRoleState] = React.useState(initialRole);
  const [nav, setNav] = React.useState<NavState>(() => {
    const fromHash = applyOldKeyRedirects(readNavHash(ALL_ACCEPTED_HASH_TABS));
    return fromHash
      ? { tab: clampTabForRole(fromHash.tab, initialRole), subtab: fromHash.subtab, domain: fromHash.domain, focusQueryId: fromHash.focusQueryId }
      : { tab: homeForRole(initialRole), subtab: null, domain: null, focusQueryId: null };
  });
  // `navigateHome: false` keeps the current area (CTO's "Full view" switches persona without
  // jumping away from whatever area was open); the picker (applyRole, the role menu's onChange)
  // always wants the new persona's own landing area.
  const applyRole = (next: string, opts?: { navigateHome?: boolean }) => {
    try { localStorage.setItem("role", next); } catch (e) { /* this session's state still drives it */ }
    setRoleState(next);
    if (!opts || opts.navigateHome !== false) {
      setNav({ tab: homeForRole(next), subtab: null, domain: null, focusQueryId: null });
    }
  };
  // Safety net for every path that can hand a role a page it does not list (a pasted link, browser
  // back/forward): it lands on the role's home.
  React.useEffect(() => {
    if (!sidebarKeysForRole(role).includes(nav.tab)) {
      setNav((prev) => ({ ...prev, tab: homeForRole(role), subtab: null, focusQueryId: null }));
    }
  }, [role, nav.tab]);
  React.useEffect(() => {
    HashState.set({ role: role === "finops" ? null : role });
    // Switching to a role that does not show the current page goes to that role's home page.
    if (!sidebarKeysForRole(role).includes(nav.tab)) {
      setNav((prev) => ({ ...prev, tab: homeForRole(role), subtab: null, focusQueryId: null }));
    }
  }, [role]);
  React.useEffect(() => {
    const onHash = () => {
      const n = applyOldKeyRedirects(readNavHash(ALL_ACCEPTED_HASH_TABS));
      if (!n) return;
      setNav((prev) => ({ ...prev, tab: n.tab, subtab: n.subtab, domain: n.domain, focusQueryId: n.focusQueryId }));
      const f = filtersFromHash(HashState.get());
      if (f.window) setWindow_(f.window);
      setAttrFilters((prev) => (attrFiltersKey(prev) === attrFiltersKey(f.attr) ? prev : f.attr));
      setTagFilterState((prev) => (tagFilterStateKey(prev) === tagFilterStateKey(f.tag) ? prev : f.tag));
      const hOwner = (HashState.get().get("owner") || "").trim();
      setOwnerFilter((prev) => (prev.trim() === hOwner ? prev : hOwner));
      const hRole = HashState.get().get("role");
      if (ROLES.includes(hRole as string)) setRoleState((prev) => (hRole !== prev ? hRole! : prev));
      const list = accountsRef.current;
      if (list.length) {
        const next = accountSetFromHash(f.acctIds, list);
        setAccountIdSet((prev) => (sameSet(prev, next) ? prev : next));
      }
    };
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const dims = useDims();

  // A name with every value ticked stays in the picker but filters nothing.
  const activeTag = React.useMemo(() => narrowingTag(tagFilter), [tagFilter]);
  Api.setTagFilter(activeTag);
  Api.setOwnerFilter(ownerFilter);
  React.useEffect(() => { HashState.set({ owner: (ownerFilter || "").trim() || null }); }, [ownerFilter]);
  // Every lens can drill to the rows: the CTO's links land on the area's own panel, not the Guide.
  setCanDrill(true);

  React.useEffect(() => {
    Api.status().then(setAppState).catch((e) => setLoadError(String(e)));
  }, []);

  const ready = !!appState && appState.state === "ready";

  React.useEffect(() => {
    if (!ready) return;
    Api.meta().then((m: Meta) => {
      setMeta(m);
      setCostCutoff(m.cost_cutoff);
      // The app opens on the window GET /api/meta says this db actually has (open_window), never a
      // fixed default the db might not have, unless the hash already named one.
      if (!initHashWindow) setWindow_(m.open_window != null ? m.open_window : m.default_window);
      if (m.brand && m.brand.name) document.title = m.brand.name;
    }).catch((e) => setLoadError(String(e)));
    Api.accounts().then((list: Row[]) => {
      setAccounts(list);
      setAccountIdSet(accountSetFromHash(initFilters.acctIds, list));
    }).catch((e) => setLoadError(String(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready]);

  const attrMatchedIds = React.useMemo(() => {
    const activeKeys = Object.keys(attrFilters).filter((k) => attrFilters[k] && attrFilters[k].size > 0);
    if (activeKeys.length === 0) return null;
    const matched = new Set<string>();
    accounts.forEach((a) => {
      if (activeKeys.every((k) => attrFilters[k].has(a[k]))) matched.add(acctId(a));
    });
    return matched;
  }, [accounts, attrFilters]);

  const accountIds = React.useMemo(() => {
    if (!accountIdSet) return [];
    // "None" picked (an explicitly empty selection, not "not loaded yet") must never fall through to
    // [], this app's own "no filter = every account" convention: checked before either branch below,
    // so Account > None reads as no spend under every filter combination.
    if (accountIdSet.size === 0) return [NO_ACCOUNT_MATCH];
    if (attrMatchedIds === null) {
      if (accountIdSet.size === accounts.length) return [];
      return Array.from(accountIdSet);
    }
    const narrowed = Array.from(accountIdSet).filter((id) => attrMatchedIds.has(id));
    return narrowed.length === 0 ? [NO_ACCOUNT_MATCH] : narrowed;
  }, [accountIdSet, accounts.length, attrMatchedIds]);

  const effectiveAccountIdSet = React.useMemo(() => {
    if (!accountIdSet) return new Set<string>();
    if (attrMatchedIds === null) return accountIdSet;
    return new Set(Array.from(accountIdSet).filter((id) => attrMatchedIds.has(id)));
  }, [accountIdSet, attrMatchedIds]);

  React.useEffect(() => {
    if (accountIdSet === null) return;
    setFindings(null);
    Api.findings(window_, accountIds)
      .then((d: any) => {
        registerCheckTitles(d.findings);
        // Each finding carries the export's price, so a check that ran empty still reads "–" when unpriced.
        setFindings((d.findings || []).map((f: Finding) => ({ ...f, export_price: d.price_basis || null })));
      })
      .catch((e) => setLoadError(String(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [window_, JSON.stringify(accountIds), accountIdSet === null, Api.tagFilterKey(), Api.ownerFilterKey(), dimKey]);

  React.useEffect(() => {
    HashState.set({
      tab: nav.tab, subtab: nav.subtab || null, domain: nav.domain || null, focus: nav.focusQueryId || null,
      w: String(window_),
    });
  }, [nav, window_]);

  React.useEffect(() => {
    if (!accountIdSet) return;
    const allSelected = accounts.length > 0 && accountIdSet.size === accounts.length;
    HashState.set({ ws: allSelected ? null : Array.from(accountIdSet).join(",") });
  }, [accountIdSet, accounts.length]);

  React.useEffect(() => {
    const obj: Record<string, string> = {};
    Object.keys(attrFilters).forEach((k) => {
      if (attrFilters[k] && attrFilters[k].size > 0) obj[k] = Array.from(attrFilters[k]).join(",");
    });
    HashState.setGroup("attr_", obj);
  }, [attrFilters]);

  React.useEffect(() => {
    HashState.set({
      tags: tagFilter ? JSON.stringify(tagFilter.groups.map((g) => (g.all ? [g.key, g.display_key, g.values, 1] : [g.key, g.display_key, g.values]))) : null,
    });
  }, [tagFilter]);

  const toggleAccount = (id: string) => {
    setAccountIdSet((prev) => {
      // With every account ticked (the default), a click means "just this one", not "all but this one".
      if (prev && accounts.length > 1 && prev.size === accounts.length) return new Set([id]);
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };
  const selectAll = () => setAccountIdSet(new Set(accounts.map((a) => acctId(a))));
  const selectNone = () => setAccountIdSet(new Set());
  const setManyAccounts = (ids: string[]) => setAccountIdSet(new Set(ids));

  const onAttrChange = (key: string, nextSet: Set<string>) => {
    setAttrFilters((prev) => {
      const next = { ...prev };
      if (nextSet && nextSet.size > 0) next[key] = nextSet; else delete next[key];
      return next;
    });
  };

  const filters = { window: window_, accountIds, accountIdSet: effectiveAccountIdSet, tag: activeTag };
  const pickerSelected = accountIdSet || new Set();
  const maxCat = (meta && meta.max_chart_categories) || 8;
  // The owner filter narrows only checks with an owner, role or user column: say how many.
  const ownerReach = React.useMemo(() => {
    if (!ownerFilter.trim() || !findings || !findings.some((f) => f.owner_applied != null)) return null;
    const n = findings.filter((f) => f.owner_applied === true).length;
    return `applies to ${fmtInt(n)} of ${fmtInt(findings.length)} checks`;
  }, [ownerFilter, findings]);

  const allFindingsIndex = React.useMemo(() => {
    const idx: Record<string, Finding> = {};
    (findings || []).forEach((f) => { idx[f.query_id] = f; });
    return idx;
  }, [findings]);

  const goTo = React.useCallback((target: GoTo) => {
    setNav({
      tab: target.tab || "findings",
      subtab: target.subtab || null,
      domain: target.domain || null,
      focusQueryId: target.focusQueryId || null,
    });
  }, []);

  const onExternalJump = React.useCallback((queryId: string) => {
    const row = allFindingsIndex[queryId];
    if (!row) return;
    const home = homeForQuery(row);
    goTo({ ...home, focusQueryId: queryId, domain: row.domain });
  }, [allFindingsIndex, goTo]);

  const selectNavItem = (it: NavItem) => setNav({ tab: it.tab, subtab: it.subtab || null, domain: null, focusQueryId: null });
  const onSubtabChange = (key: string) => setNav((prev) => ({ ...prev, subtab: key, focusQueryId: null }));
  // The one possible-waste $ (waste_total.tsx), the same figure Overview and Waste & savings show.
  const wasteUsd = React.useMemo(
    () => (findings ? wasteTotal(buildWasteWorklist(allFindingsIndex)).waste.usd : undefined),
    [findings, allFindingsIndex]
  );
  const activeFilterCount = Object.keys(attrFilters).filter((k) => attrFilters[k] && attrFilters[k].size > 0).length
    + (activeTag ? activeTag.groups.length : 0)
    + (ownerFilter.trim() ? 1 : 0)
    + (dimKey ? Object.values(Api.dimFilter()).filter((v) => v && v.length).length : 0)
    + (accountIdSet && accounts.length > 1 && accountIdSet.size !== accounts.length ? 1 : 0);
  const navProps = { role, activeArea: nav.tab, activeSubtab: nav.subtab, onSelectItem: selectNavItem, findings, meta, wasteUsd };

  const brandOf = (src: Row | null) => src && src.brand && src.brand.name;
  const brandName = brandOf(meta) || brandOf(appState) || BRAND_NAME;

  if (appState && appState.state !== "ready") {
    if (nav.tab === "guide") {
      return (
        <div className="shell">
          <div className="topbar">
            <div className="brand">
              <span className="brand-title">{brandName}</span>
            </div>
          </div>
          <ErrorBoundary><GuideTab focus={nav.focusQueryId} filters={filters} /></ErrorBoundary>
        </div>
      );
    }
    return <FirstRunScreen appState={appState} />;
  }

  if (appState === null && !loadError) {
    return (
      <div className="fr-shell">
        <div className="brand fr-brand">
          <span className="brand-title">{brandName}</span>
        </div>
        <div className="loading-note">…</div>
      </div>
    );
  }

  const windowOptions = (meta && meta.window_options) || [7, 30, 90];
  const windows = (meta && meta.windows) || windowOptions.map((d: number) => ({ days: d, available: true, covered_days: d, partial: false }));

  // Tiles read the window's dates for their empty line; set before any child renders.
  setAuditRange(windowRangeLabel(meta && meta.as_of_date, filters.window, meta && meta.snapshot_days));

  return (
    <div className="c-app">
      <Rail {...navProps} onRoleChange={applyRole} />
      <div className="c-main">
      <TopBar
        meta={meta}
        onOpenNavDrawer={() => setNavDrawerOpen(true)}
        filtersWindow={window_}
        windows={windows}
        onSetWindow={setWindow_}
        accounts={accounts}
        pickerSelected={pickerSelected}
        toggleAccount={toggleAccount}
        selectAll={selectAll}
        selectNone={selectNone}
        setManyAccounts={setManyAccounts}
        attrFilters={attrFilters}
        onAttrChange={onAttrChange}
        tagFilter={tagFilter}
        onTagChange={setTagFilterState}
        ownerFilter={ownerFilter}
        onOwnerChange={setOwnerFilter}
        accountIds={accountIds}
        role={role}
        onRoleChange={applyRole}
        ownerReach={ownerReach}
        activeFilterCount={activeFilterCount}
      />
      {navDrawerOpen && (
        <SideNavDrawer
          {...navProps}
          onClose={() => setNavDrawerOpen(false)}
          windows={windows}
          filtersWindow={window_}
          onSetWindow={setWindow_}
          meta={meta}
          accounts={accounts}
          pickerSelected={pickerSelected}
          toggleAccount={toggleAccount}
          selectAll={selectAll}
          selectNone={selectNone}
          setManyAccounts={setManyAccounts}
          attrFilters={attrFilters}
          onAttrChange={onAttrChange}
          tagFilter={tagFilter}
          onTagChange={setTagFilterState}
          ownerFilter={ownerFilter}
          onOwnerChange={setOwnerFilter}
          accountIds={accountIds}
          role={role}
          onRoleChange={applyRole}
          findings={findings}
        />
      )}

      <div className="c-content">
      <TagScopeBanner tag={activeTag} />

      {loadError && (
        <div className="honest-card error" style={{ marginBottom: 16 }}>
          <div className="h-title">Could not load</div>
          <div className="h-note mono">{loadError}</div>
        </div>
      )}

      <div className="app-body">
        {/* Overviews and Actions get the roomier executive look (c_exec.css). */}
        <div className={`app-main${["overview", "money", "actions"].includes(nav.tab) ? " exec" : ""}`}>
          {findings === null && !loadError && <div className="loading-note">…</div>}

          {findings !== null && nav.tab !== "guide" && nav.tab !== "money" && nav.tab !== "tags"
            && !((role === "cto" || role === "data_engineer") && nav.tab === "overview") && (
            <ErrorBoundary>
              <AreaPage
                key={Api.ownerFilterKey() + dimKey}
                areaKey={nav.tab}
                findings={findings}
                filters={filters}
                dims={dims}
                maxCat={maxCat}
                meta={meta}
                allFindingsIndex={allFindingsIndex}
                onExternalJump={onExternalJump}
                initialFocusId={nav.focusQueryId || undefined}
                initialSubtab={nav.subtab}
                onSubtabChange={onSubtabChange}
                setManyAccounts={setManyAccounts}
                goTo={goTo}
                summaryOnly={false}
                role={role}
                roleAreas={roleAreasFor(role)}
              />
            </ErrorBoundary>
          )}

          {/* CFO's Money home; the CTO's Overview is its posture page. */}
          {findings !== null && nav.tab === "money" && (
            <ErrorBoundary>
              <MoneyTab filters={filters} meta={meta} findingsById={allFindingsIndex} goTo={goTo} role={role} />
            </ErrorBoundary>
          )}
          {findings !== null && role === "cto" && nav.tab === "overview" && (
            <ErrorBoundary>
              <CtoOverview filters={filters} meta={meta} findingsById={allFindingsIndex} goTo={goTo} role={role} roleAreas={roleAreasFor(role)} />
            </ErrorBoundary>
          )}
          {findings !== null && role === "data_engineer" && nav.tab === "overview" && (
            <ErrorBoundary>
              <DeOverview filters={filters} meta={meta} findingsById={allFindingsIndex} goTo={goTo} role={role} />
            </ErrorBoundary>
          )}

          {findings !== null && nav.tab === "tags" && hasTagsPage() && (
            <ErrorBoundary><TagsRoute filters={filters} meta={meta} role={role} /></ErrorBoundary>
          )}

          {nav.tab === "guide" && (
            <ErrorBoundary><GuideTab focus={nav.focusQueryId} filters={filters} findingsById={allFindingsIndex} meta={meta} role={role} /></ErrorBoundary>
          )}
        </div>
      </div>

      <TaskPanelOverlay windowDays={window_} />
      <BrandFooter meta={meta} />
      </div>
      </div>
    </div>
  );
}

