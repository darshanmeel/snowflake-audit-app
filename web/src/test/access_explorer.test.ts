import { describe, expect, it } from "vitest";
import { cutPoints, dormantUsers } from "../components/area_access_explorer";

describe("where to cut", () => {
  it("keeps the roles on every path, in path order, never the two ends", () => {
    expect(cutPoints([
      ["EVA", "BI_ROLE", "ANALYST_ROLE", "T"],
      ["EVA", "DATA_ADMIN", "BI_ROLE", "ANALYST_ROLE", "T"],
    ])).toEqual(["BI_ROLE", "ANALYST_ROLE"]);
  });

  it("finds no cut when two paths share no role", () => {
    expect(cutPoints([["EVA", "A", "T"], ["EVA", "B", "T"]])).toEqual([]);
  });

  it("has no cut for a direct grant or no paths", () => {
    expect(cutPoints([["ROLE", "T"]])).toEqual([]);
    expect(cutPoints([])).toEqual([]);
  });
});

describe("dormant users", () => {
  const users = [
    { name: "RECENT", last_success_login: "2026-09-01" },
    { name: "OLD", last_success_login: "2026-06-01" },
    { name: "NEVER", last_success_login: null },
    { name: "OFF", last_success_login: null, is_disabled: true },
    { name: "SVC", last_success_login: null, user_type: "service" },
    { name: "LEGACY", last_success_login: null, user_type: "LEGACY_SERVICE" },
  ];

  it("counts enabled people with no sign-in in 90 days before the as-of day, or never", () => {
    expect([...dormantUsers(users, "2026-09-28")].sort()).toEqual(["NEVER", "OLD"]);
  });

  it("puts a sign-in exactly 90 days back on the active side", () => {
    expect(dormantUsers([{ name: "EDGE", last_success_login: "2026-06-30" }], "2026-09-28").size).toBe(0);
    expect(dormantUsers([{ name: "EDGE", last_success_login: "2026-06-29" }], "2026-09-28").size).toBe(1);
  });

  it("without an as-of day, counts only those never signed in", () => {
    expect([...dormantUsers(users, null)]).toEqual(["NEVER"]);
  });
});
