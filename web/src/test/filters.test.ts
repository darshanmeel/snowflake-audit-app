import { afterEach, describe, expect, it, vi } from "vitest";
import { Api, setDimFilter, setOwnerFilter, setTagFilter } from "../api";

function lastUrl(fetchMock: ReturnType<typeof vi.fn>): URL {
  const call = fetchMock.mock.calls[fetchMock.mock.calls.length - 1];
  return new URL(String(call[0]), "http://x");
}

describe("filters reach the API", () => {
  afterEach(() => {
    setTagFilter(null);
    setOwnerFilter("");
    setDimFilter(null);
    vi.unstubAllGlobals();
  });

  it("sends window, accounts, tag, owner and warehouse/database/schema on a finding fetch", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ outcome: "ok_rows", rows: [] }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    setTagFilter({ groups: [{ key: "cost:center", values: ["fin", "ops"] }, { key: "team", values: [] }] });
    setOwnerFilter("  alice ");
    setDimFilter({ warehouse: ["WH_A"], database: [], schema: ["DB.S"] });
    await Api.finding("q1", 30, ["acct1"], 100);
    const u = lastUrl(fetchMock);
    expect(u.pathname).toBe("/api/finding/q1");
    expect(u.searchParams.get("window")).toBe("30");
    expect(u.searchParams.getAll("account_ids")).toEqual(["acct1"]);
    expect(u.searchParams.getAll("tag")).toEqual(["cost%3Acenter:fin", "cost%3Acenter:ops", "team"]);
    expect(u.searchParams.get("owner")).toBe("alice");
    expect(u.searchParams.getAll("warehouse")).toEqual(["WH_A"]);
    expect(u.searchParams.has("database")).toBe(false);
    expect(u.searchParams.getAll("schema")).toEqual(["DB.S"]);
  });

  it("a task-scoped fetch carries neither the tag nor the owner filter", async () => {
    const fetchMock = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    setTagFilter({ groups: [{ key: "team", values: ["x"] }] });
    setOwnerFilter("bob");
    await Api.finding("q1", 7, null, 10, 0, "DB.S.TASK");
    const u = lastUrl(fetchMock);
    expect(u.searchParams.get("job_id")).toBe("DB.S.TASK");
    expect(u.searchParams.has("tag")).toBe(false);
    expect(u.searchParams.has("owner")).toBe(false);
  });

  it("keeps the warehouse filter in the hash", () => {
    setDimFilter({ warehouse: ["A", "B"], database: [], schema: [] });
    expect(new URLSearchParams(window.location.hash.slice(1)).get("wh")).toBe("A|B");
  });

  it("turns an API error into a plain sentence with no exception type", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ detail: "unknown check" }), { status: 404, statusText: "Not Found" })));
    await expect(Api.finding("nope", 30, null, 10)).rejects.toThrow("404 unknown check");
  });
});
