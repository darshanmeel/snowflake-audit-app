// web/src/components/hash_state.tsx -- the one place the app reads/writes location.hash, so every
// view (tab/sub-tab/focus, window/accounts/attributes/tag) has a URL that reproduces it: paste it
// anywhere and it opens to the same place. Plain "key=value" pairs in the hash (never JSON, so a
// pasted link stays readable), merged additively: a caller's own set() only ever touches the keys
// it passes, so two writers can never clobber each other's keys.
import React from "react";


export const HashState = (function () {
  function get() {
    const raw = (window.location.hash || "").replace(/^#/, "");
    return new URLSearchParams(raw);
  }
  function write(params: URLSearchParams) {
    const next = params.toString();
    const url = window.location.pathname + window.location.search + (next ? `#${next}` : "");
    // replaceState, not a location.hash assignment: a filter change must never push a new
    // browser-history entry.
    window.history.replaceState(null, "", url);
  }
  // Sets/clears the given keys (a null/undefined/"" value removes that key), leaving every other
  // key already in the hash untouched.
  function set(patch: Record<string, any> | null | undefined) {
    const params = get();
    Object.keys(patch || {}).forEach((k) => {
      const v = patch![k];
      if (v === null || v === undefined || v === "") params.delete(k);
      else params.set(k, v);
    });
    write(params);
  }
  // Replaces every existing "<prefix>*" key with exactly the ones in `obj`: for a variable-size group
  // (the attribute-filter keys, cost_center/team/...) where `set` alone could not know which
  // earlier keys to clear.
  function setGroup(prefix: string, obj: Record<string, any> | null | undefined) {
    const params = get();
    Array.from(params.keys()).forEach((k) => { if (k.indexOf(prefix) === 0) params.delete(k); });
    Object.keys(obj || {}).forEach((k) => {
      const v = obj![k];
      if (v !== null && v !== undefined && v !== "") params.set(prefix + k, v);
    });
    write(params);
  }
  return { get, set, setGroup };
})();

// <CopyLinkButton label /> -- copies the page's CURRENT address (location.href) to the clipboard.
// Every view reachable through HashState's keys already has that exact state in the address bar by
// the time this renders, so it needs no props beyond a label.
export function CopyLinkButton({ label }: { label?: string }) {
  const [copied, setCopied] = React.useState(false);
  const copy = (e: React.MouseEvent<HTMLButtonElement>) => {
    e.preventDefault();
    e.stopPropagation();
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(window.location.href).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        }).catch(() => {});
      }
    } catch (err) { /* clipboard unavailable here: the button silently does nothing */ }
  };
  return (
    <button
      type="button"
      className="copy-link-btn"
      title="Copy a link to this exact view -- tab, filters and whatever is open here"
      onClick={copy}
    >
      {copied ? "Link copied" : (label || "Copy link")}
    </button>
  );
}
