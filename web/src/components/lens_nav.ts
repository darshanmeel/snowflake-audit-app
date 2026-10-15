// web/src/components/lens_nav.ts -- the sidebar per lens: grouped entries, each an area or one
// sub-tab of an area. The rail, the phone drawer, the page head and the role's page list read it.
import { AREA_REGISTRY } from "./tab_registry";

/** One sidebar entry: an area, or one sub-tab of it. No label means the page's own name. */
export interface NavItem { tab: string; subtab?: string; label?: string }
/** A labelled group of entries; the top group has no label. */
export interface NavGroup { label: string | null; items: NavItem[] }

export const LENS_LABEL: Record<string, string> = { finops: "FinOps", data_engineer: "Data engineer", governance: "Governance", cto: "CTO", cfo: "CFO" };

// Labels resolve at render time: this module loads inside the tab_registry/primitives cycle.
const area = (tab: string): NavItem => ({ tab });
const sub = (tab: string, subtab: string, label: string): NavItem => ({ tab, subtab, label });
const TOP: NavGroup = { label: null, items: [{ tab: "overview", label: "Overview" }, { tab: "actions", label: "Fix these first" }] };
const REFERENCE: NavGroup = { label: "Reference", items: [
  { tab: "coverage", label: "Coverage & gaps" }, { tab: "findings", label: "All findings" }, { tab: "guide", label: "How it works" },
] };

export const LENS_NAV: Record<string, NavGroup[]> = {
  cto: [
    TOP,
    { label: "Cost", items: ["cost", "tags", "waste", "warehouses", "serverless", "storage"].map(area) },
    { label: "Reliability", items: ["tasks", "loading"].map(area) },
    { label: "Performance", items: ["queries", "ai"].map(area) },
    { label: "Security", items: ["access", "pii", "audit", "sharing", "lineage"].map(area) },
    REFERENCE,
  ],
  cfo: [
    { label: null, items: [{ tab: "money", label: "Money" }, { tab: "actions", label: "What to do" }] },
    { label: "Explore", items: [
      area("cost"), sub("cost", "chargeback", "Chargeback & tags"), sub("cost", "contract", "Contract & rate"),
      sub("cost", "budgets", "Budgets & guardrails"), area("waste"),
    ] },
    REFERENCE,
  ],
  finops: [
    TOP,
    { label: "Spend", items: [area("cost"), area("tags"), sub("cost", "budgets", "Budgets"), sub("cost", "contract", "Contract")] },
    { label: "Waste", items: ["waste", "warehouses", "serverless", "ai", "storage", "sharing"].map(area) },
    REFERENCE,
  ],
  data_engineer: [
    TOP,
    { label: "Pipelines", items: ["tasks", "loading"].map(area) },
    { label: "Queries & compute", items: ["queries", "warehouses", "serverless"].map(area) },
    { label: "Cost", items: ["cost", "waste", "storage"].map(area) },
    REFERENCE,
  ],
  governance: [
    TOP,
    { label: "Access", items: [sub("access", "roles", "Roles & grants"), sub("access", "users", "Users & sign-ins"), sub("access", "perimeter", "Account perimeter")] },
    { label: "Data", items: ["pii", "lineage", "sharing", "storage"].map(area) },
    { label: "Trail", items: [area("audit")] },
    REFERENCE,
  ],
};

export function lensNav(role: string): NavGroup[] {
  return LENS_NAV[role] || LENS_NAV.finops;
}

// The pages a lens lists, each once, in sidebar order.
export function lensTabs(role: string): string[] {
  const out: string[] = [];
  lensNav(role).forEach((g) => g.items.forEach((it) => { if (!out.includes(it.tab)) out.push(it.tab); }));
  return out;
}

// A page's name in this lens: "Actions" reads "Fix these first" (CFO: "What to do").
export function pageLabel(tab: string, role?: string | null): string {
  if (tab === "actions") return role === "cfo" ? "What to do" : "Fix these first";
  if (tab === "money") return "Money";
  if (tab === "guide") return "How it works";
  if (tab === "tags") return "Tags";
  if (tab === "coverage") return "Coverage & gaps";
  return (AREA_REGISTRY[tab] && AREA_REGISTRY[tab].label) || tab;
}

export function navItemLabel(it: NavItem, role?: string | null): string {
  return it.label || pageLabel(it.tab, role);
}

// The entry that is lit: the one naming the open sub-tab, else the area's own entry, else the
// area's first entry.
export function activeNavItem(role: string, tab: string, subtab: string | null): NavItem | null {
  const all = lensNav(role).flatMap((g) => g.items).filter((it) => it.tab === tab);
  return all.find((it) => it.subtab && it.subtab === subtab) || all.find((it) => !it.subtab) || all[0] || null;
}
