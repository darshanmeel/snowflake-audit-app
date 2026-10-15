import { beforeEach, describe, expect, it } from "vitest";
import { HashState } from "../components/hash_state";
import { navHref, readNavHash, writeNavHash } from "../components/nav_hash";

const setHash = (h: string) => window.history.replaceState(null, "", "/" + h);

describe("HashState", () => {
  beforeEach(() => setHash(""));

  it("sets only the keys it is given and deletes a key set to null or empty", () => {
    setHash("#role=cto&w=30&tab=cost");
    HashState.set({ w: 7, tab: null, subtab: "" });
    const p = HashState.get();
    expect(p.get("role")).toBe("cto");
    expect(p.get("w")).toBe("7");
    expect(p.has("tab")).toBe(false);
    expect(p.has("subtab")).toBe(false);
  });

  it("replaces a whole prefix group and keeps other keys", () => {
    setHash("#a_team=x&a_env=prod&w=30");
    HashState.setGroup("a_", { owner: "me", env: "" });
    const p = HashState.get();
    expect(p.get("a_owner")).toBe("me");
    expect(p.has("a_team")).toBe(false);
    expect(p.has("a_env")).toBe(false);
    expect(p.get("w")).toBe("30");
  });
});

describe("nav hash", () => {
  beforeEach(() => setHash(""));

  it("reads a known tab and drops an unknown one", () => {
    setHash("#tab=cost&subtab=trend&focus=sf_cost_x&view=critical");
    expect(readNavHash(["cost", "overview"])).toEqual({
      tab: "cost", subtab: "trend", view: "critical", focusQueryId: "sf_cost_x", domain: null,
    });
    expect(readNavHash(["overview"])).toBeNull();
  });

  it("drops a token with characters outside the allowed set and an unknown view", () => {
    setHash("#tab=cost&subtab=" + encodeURIComponent("<script>") + "&view=bogus");
    const nav = readNavHash(["cost"]);
    expect(nav && nav.subtab).toBeNull();
    expect(nav && nav.view).toBeNull();
  });

  it("writes the nav keys and leaves the rest of the hash alone", () => {
    setHash("#role=cto&w=7");
    writeNavHash({ tab: "queries", subtab: "heavy", focusQueryId: null });
    const p = new URLSearchParams(window.location.hash.slice(1));
    expect(p.get("role")).toBe("cto");
    expect(p.get("tab")).toBe("queries");
    expect(p.get("subtab")).toBe("heavy");
    expect(p.has("focus")).toBe(false);
  });

  it("navHref merges a patch spelled with either key name", () => {
    setHash("#tab=cost&subtab=trend&w=30");
    const p = new URLSearchParams(navHref({ focus: "q1", subtab: null }).slice(1));
    expect(p.get("tab")).toBe("cost");
    expect(p.get("focus")).toBe("q1");
    expect(p.has("subtab")).toBe(false);
    expect(p.get("w")).toBe("30");
  });
});
