import { describe, expect, it } from "vitest";
import { TAG_UNTAGGED, narrowingTag, toggleGroupValue } from "../components/tag_picker";

const values = ["a", "b"];
const picked = { key: "cc", display_key: "cc", values: [], all: true };

describe("tag filter: every value starts ticked", () => {
  it("a just-picked name filters nothing", () => {
    expect(narrowingTag({ groups: [picked] })).toBeNull();
  });

  it("unticking untagged leaves 'any tagged value', which narrows", () => {
    const g = toggleGroupValue(picked, TAG_UNTAGGED, values);
    expect(g).toEqual({ key: "cc", display_key: "cc", values: [] });
    expect(narrowingTag({ groups: [g] })).toEqual({ groups: [g] });
  });

  it("unticking one value keeps the rest, untagged included", () => {
    expect(toggleGroupValue(picked, "a", values).values).toEqual(["b", TAG_UNTAGGED]);
  });

  it("ticking everything back returns to all, and the last value can't be unticked", () => {
    const g = toggleGroupValue({ key: "cc", display_key: "cc", values: ["b", TAG_UNTAGGED] }, "a", values);
    expect(g.all).toBe(true);
    const one = { key: "cc", display_key: "cc", values: ["a"] };
    expect(toggleGroupValue(one, "a", values)).toBe(one);
  });

  it("only the narrowing names reach the filter", () => {
    const narrow = { key: "env", display_key: "env", values: ["prod"] };
    expect(narrowingTag({ groups: [picked, narrow] })).toEqual({ groups: [narrow] });
  });

  it("a cut-off list picks the values to keep, so unlisted values never drop silently", () => {
    const g = toggleGroupValue(picked, "a", values, true);
    expect(g).toEqual({ key: "cc", display_key: "cc", values: ["a"] });
    expect(toggleGroupValue(g, "a", values, true).all).toBe(true);
  });
});
