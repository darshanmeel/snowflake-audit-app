// AreaContent: how a page agent registers per-sub-tab content without ever editing
// tab_registry. Call AreaContent.register("cost", "trend", TrendPanel) once, at your own
// tab_*.tsx's load time (top level; App.tsx imports every tab module so each one registers) -- AreaPage
// below then renders <TrendPanel {...tabProps} /> above the checks table whenever that area/
// sub-tab pair is open. A `subtab` of null registers the content for an area with no sub-tabs
// (Overview, All findings, ...).
import type React from "react";

export const AreaContent = (function () {
  const map: Record<string, React.ComponentType<any>> = {};
  const key = (area: string, subtab: string | null | undefined) => `${area}::${subtab || ""}`;
  return {
    register(area: string, subtab: string | null | undefined, Component: React.ComponentType<any>) { map[key(area, subtab)] = Component; },
    get(area: string, subtab: string | null | undefined): React.ComponentType<any> | null { return map[key(area, subtab)] || null; },
  };
})();
