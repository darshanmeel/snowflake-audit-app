import { describe, expect, it } from "vitest";
import { clampTabForRole, homeForRole, ROLES, roleAreasFor, sidebarKeysForRole } from "../App";
import { OLD_TAB_REDIRECTS } from "../components/tab_registry";
import { activeNavItem, lensNav } from "../components/lens_nav";

describe("roles to pages", () => {
  it("gives the CFO Money, What to do, money pages and the reference group", () => {
    expect(sidebarKeysForRole("cfo")).toEqual(["money", "actions", "cost", "waste", "coverage", "findings", "guide"]);
    expect(homeForRole("cfo")).toBe("money");
  });

  it("starts every other role on Overview and ends on the reference group", () => {
    for (const role of ROLES.filter((r) => r !== "cfo")) {
      const keys = sidebarKeysForRole(role);
      expect(keys.slice(0, 2)).toEqual(["overview", "actions"]);
      expect(keys.slice(-3)).toEqual(["coverage", "findings", "guide"]);
      expect(homeForRole(role)).toBe("overview");
    }
  });

  it("groups each lens's sidebar", () => {
    const labels = (role: string) => lensNav(role).map((g) => g.label).filter(Boolean);
    expect(labels("cto")).toEqual(["Cost", "Reliability", "Performance", "Security", "Reference"]);
    expect(labels("cfo")).toEqual(["Explore", "Reference"]);
    expect(labels("finops")).toEqual(["Spend", "Waste", "Reference"]);
    expect(labels("data_engineer")).toEqual(["Pipelines", "Queries & compute", "Cost", "Reference"]);
    expect(labels("governance")).toEqual(["Access", "Data", "Trail", "Reference"]);
  });

  it("filters Actions and All findings to the sidebar's areas", () => {
    expect(roleAreasFor("governance")).toEqual(["actions", "access", "pii", "lineage", "sharing", "storage", "audit", "coverage"]);
    expect(roleAreasFor("nobody")).toEqual(roleAreasFor("finops"));
  });

  it("lights the sub-tab entry that is open", () => {
    expect(activeNavItem("governance", "access", "users")?.label).toBe("Users & sign-ins");
    expect(activeNavItem("cfo", "cost", "trend")?.subtab).toBeUndefined();
  });

  it("sends a page the role does not show to the role's home", () => {
    expect(clampTabForRole("queries", "finops")).toBe("overview");
    expect(clampTabForRole("queries", "data_engineer")).toBe("queries");
    expect(clampTabForRole("tasks", "cfo")).toBe("money");
  });

  it("keeps the old-hash redirects", () => {
    expect(Object.keys(OLD_TAB_REDIRECTS).length).toBeGreaterThan(0);
  });
});
