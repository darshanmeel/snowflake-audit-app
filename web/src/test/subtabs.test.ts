import { describe, expect, it } from "vitest";
// tab_area first: it loads the registry cycle in the same order the app does
import "../tabs/tab_area";
import { AREA_REGISTRY } from "../components/tab_registry";
import { AreaContent } from "../area_content";

describe("every sub-tab has a page", () => {
  it("registers content for each sub-tab the registry lists", () => {
    const missing = Object.entries(AREA_REGISTRY).flatMap(([area, def]) =>
      (def.subtabs || []).filter((s) => !AreaContent.get(area, s.key)).map((s) => `${area}/${s.key}`));
    expect(missing).toEqual([]);
  });
});
