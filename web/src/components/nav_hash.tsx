// web/src/components/nav_hash.tsx -- the screen the reader is on, in location.hash, so a link
// opens the same tab, sub-tab, chart topic and finding. Keys a caller does not name are untouched.
export const NAV_HASH_KEYS: [string, string][] = [["tab", "tab"], ["subtab", "subtab"], ["view", "view"], ["focusQueryId", "focus"], ["domain", "domain"]];
export const NAV_VIEW_KEYS = ["overview", "critical", "warning", "ok", "not_assessed", "reference"];
export const NAV_TOKEN_RE = /^[A-Za-z0-9_.:-]{1,200}$/;

export function readNavHash(validTabs: string[] | null | undefined) {
  let p;
  try { p = new URLSearchParams((window.location.hash || "").replace(/^#/, "")); } catch (e) { return null; }
  const tab = p.get("tab");
  if (!tab || !(validTabs || []).includes(tab)) return null;
  const tok = (k: string) => { const v = p.get(k); return v && NAV_TOKEN_RE.test(v) ? v : null; };
  const view = p.get("view");
  return {
    tab,
    subtab: tok("subtab"),
    view: NAV_VIEW_KEYS.includes(view!) ? view : null,
    focusQueryId: tok("focus"),
    domain: tok("domain"),
  };
}

export function writeNavHash(nav: Record<string, any> | null | undefined) {
  let p;
  try { p = new URLSearchParams((window.location.hash || "").replace(/^#/, "")); } catch (e) { p = new URLSearchParams(); }
  NAV_HASH_KEYS.forEach(([field, key]) => {
    const v = nav && nav[field];
    if (v === null || v === undefined || v === "") p.delete(key); else p.set(key, String(v));
  });
  const next = "#" + p.toString();
  if (window.location.hash !== next) {
    try { window.history.replaceState(null, "", next); } catch (e) { /* file:// or a sandbox: skip */ }
  }
}

// `patch` merges into the current hash; a key it does not name is left as-is, a null value deletes it.
export function navHref(patch: Record<string, any> | null | undefined) {
  let p;
  try { p = new URLSearchParams((window.location.hash || "").replace(/^#/, "")); } catch (e) { p = new URLSearchParams(); }
  const given: Record<string, any> = patch || {};
  NAV_HASH_KEYS.forEach(([fieldName, key]) => {
    // a caller may spell the patch key either as the nav field name or the short hash key
    const k = fieldName in given ? fieldName : (key in given ? key : null);
    if (k === null) return; // not named by this patch -- leave as-is
    const v = given[k];
    if (v === null || v === undefined || v === "") p.delete(key); else p.set(key, String(v));
  });
  return "#" + p.toString();
}
