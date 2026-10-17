// Links from the screens into the Guide: a check's own page, a tab's own page, and the concepts a tab leans on.
import React from "react";
import { navHref } from "./nav_hash";

// The Guide pages each tab leans on, shown under its lede. Ids are Guide section slugs (guide.tsx GUIDE_SECTIONS).
export const TAB_CONCEPTS: Record<string, { slug: string; label: string }[]> = {
  overview: [{ slug: "money", label: "How dollars are worked out" }, { slug: "latency", label: "Latency" }],
  actions: [{ slug: "money-kinds", label: "Money kinds" }, { slug: "floors", label: "Materiality floors" }],
  money: [{ slug: "money", label: "How dollars are worked out" }, { slug: "pricing", label: "Price basis" }],
  cost: [{ slug: "cloud-services", label: "Cloud services 10%" }, { slug: "money", label: "How dollars are worked out" }],
  tags: [{ slug: "tags", label: "Tags and chargeback" }],
  waste: [{ slug: "idle", label: "Idle time" }, { slug: "money-kinds", label: "Money kinds" }],
  warehouses: [{ slug: "pressure", label: "Scale up or out" }, { slug: "idle", label: "Idle time" }],
  serverless: [{ slug: "cloud-services", label: "Cloud services 10%" }, { slug: "pricing", label: "Price basis" }],
  queries: [{ slug: "attribution", label: "Query attribution is not a total" }, { slug: "adaptive", label: "Adaptive warehouses" }],
  tasks: [{ slug: "attribution", label: "Query attribution is not a total" }, { slug: "latency", label: "Latency" }],
  loading: [{ slug: "latency", label: "Latency" }],
  ai: [{ slug: "pricing", label: "Price basis" }, { slug: "latency", label: "Latency" }],
  access: [{ slug: "visibility", label: "Role visibility" }],
  pii: [{ slug: "visibility", label: "Role visibility" }],
  lineage: [{ slug: "visibility", label: "Role visibility" }, { slug: "latency", label: "Latency" }],
  audit: [{ slug: "visibility", label: "Role visibility" }],
  sharing: [{ slug: "visibility", label: "Role visibility" }],
  storage: [{ slug: "failsafe", label: "Time Travel and Fail-safe" }, { slug: "upper-bound", label: "\"Up to\" figures" }],
  findings: [{ slug: "status", label: "What each status means" }, { slug: "floors", label: "Materiality floors" }],
  coverage: [{ slug: "visibility", label: "Editions and role visibility" }, { slug: "freshness", label: "Source freshness" }],
};

export function guideHref(focus: string | null) {
  return navHref({ tab: "guide", subtab: null, focus, domain: null });
}

// The Guide page for one tab; Findings has none, so it opens the Guide's home.
export function tabGuideHref(tab?: string | null) {
  return guideHref(tab && tab !== "findings" ? `how-area-${tab}` : null);
}

// A small "?" beside a check's name: opens that check's Guide page without opening the row it sits in.
export function GuideHelp({ id, label }: { id: string; label?: string }) {
  const href = guideHref(id);
  return (
    <a className="gd-help" href={href} title="How this check works" aria-label={`How ${label || "this check"} works`}
      onClick={(e) => { e.stopPropagation(); e.preventDefault(); window.location.hash = href; }}
      onKeyDown={(e) => e.stopPropagation()}>?</a>
  );
}

// "Read: A · B" after a page's method line.
export function GuideConceptLinks({ tab }: { tab?: string | null }) {
  const list = (tab && TAB_CONCEPTS[tab]) || [];
  if (!list.length) return null;
  return (
    <span className="gd-concepts">
      {"Read: "}
      {list.map((c, i) => (
        <React.Fragment key={c.slug}>
          {i > 0 && " · "}
          <a href={guideHref(`how-${c.slug}`)}>{c.label}</a>
        </React.Fragment>
      ))}
    </span>
  );
}
