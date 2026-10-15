// web/src/components/names.tsx -- "names, not ids": every warehouse, task or account id renders as
// "name (id)", never a bare id. Fetches GET /api/dims and the accounts route once
// into a module-level cache, so <Ref> instances inside unconnected tables share one fetch.
//
// Exposes:
//   Names.load() / Names.isReady() / Names.subscribe(fn)   the cache itself
//   resolveName(kind, accountId, id)   -> display name string, or null if unresolved
//   <Ref kind id accountId label />    the name-with-id cell, with a copy affordance for the id
//   acctPhrase(accountId)              the account's name for a sentence, never a bare id
//   TaskFocus.open(accountId, taskFullName) / .close() / .subscribe(fn) / .getState()
//                                      the store a task <Ref> uses to open task_panel.tsx's panel
//                                      from anywhere; the task is kept in the URL hash as task=<name>
//   snowsightLink(kind, id, name)      best-guess Snowsight URL, or null when org/account are unknown
//
// A database, schema, role or user has no dim: its name IS its value, so a check that returns one
// shows it as is. A task is keyed by its full name (DB.SCHEMA.TASK); a warehouse by its id.
import React from "react";
import { Api, acctId } from "../api";
import { HashState } from "./hash_state";


export const Names = (function () {
  let dims = { tasks: new Map<string, any>(), warehouses: new Map<string, any>() };
  let accounts = new Map<string, any>(); // account id (string) -> full account record
  let snowsightBase: string | null = null; // https://app.snowflake.com/<org>/<account>, only when both names are known
  let ready = false;
  let loadPromise: Promise<void> | null = null;
  const listeners = new Set<() => void>();

  function notify() {
    listeners.forEach((fn) => {
      try { fn(); } catch (e) { /* one bad listener never blocks the others */ }
    });
  }

  function load() {
    if (loadPromise) return loadPromise;
    loadPromise = Promise.all([Api.dims(), Api.accounts(), Api.meta().catch(() => null)])
      .then(([d, list, meta]: any[]) => {
        const acct = meta && meta.direct_export && meta.direct_export.account;
        const org = acct && (acct.organization_name || acct.org_name);
        const trueName = acct && acct.account_name && String(acct.account_name) !== String(acct.id) ? acct.account_name : null;
        snowsightBase = org && trueName
          ? `https://app.snowflake.com/${encodeURIComponent(String(org).toLowerCase())}/${encodeURIComponent(String(trueName).toLowerCase())}` : null;
        const tasks = new Map<string, any>();
        (d.tasks || []).forEach((x: any) => tasks.set(String(x.task_full_name), x));
        const warehouses = new Map<string, any>();
        (d.warehouses || []).forEach((w: any) => warehouses.set(String(w.warehouse_id), w));
        dims = { tasks, warehouses };
        const accts = new Map<string, any>();
        (list || []).forEach((a: any) => accts.set(String(acctId(a)), a));
        accounts = accts;
      })
      .catch(() => {
        // Names never load: every id column falls back to its raw value, never a blank.
      })
      .finally(() => {
        ready = true;
        notify();
      });
    return loadPromise;
  }

  function isReady() { return ready; }
  function subscribe(fn: () => void): () => void { listeners.add(fn); return () => listeners.delete(fn); }

  function accountRecord(id: any) {
    if (id === undefined || id === null) return null;
    return accounts.get(String(id)) || null;
  }

  function resolveName(kind: string, accountId: any, id: any): string | null {
    if (id === undefined || id === null || id === "") return null;
    switch (kind) {
      case "account": {
        const a = accountRecord(id);
        return (a && a.name) || null;
      }
      case "warehouse": {
        const w = dims.warehouses.get(String(id));
        return (w && w.warehouse_name) || null;
      }
      case "task": {
        const x = dims.tasks.get(String(id));
        return (x && (x.task_full_name || x.task_name)) || null;
      }
      default:
        return null;
    }
  }

  // The numeric id beside a task's full name (dims.dim_task.task_id), or null.
  function taskNumericId(fullName: any): string | null {
    const x = dims.tasks.get(String(fullName));
    return x && x.task_id != null && x.task_id !== "" ? String(x.task_id) : null;
  }
  function getSnowsightBase() { return snowsightBase; }

  load(); // one fetch, at script-load time
  return { load, isReady, subscribe, resolveName, accountRecord, getSnowsightBase, taskNumericId };
})();

// Subscribes a component to Names' cache so it re-renders once the dims have loaded (before that,
// every <Ref> renders off the raw id; this only upgrades the same cell in place).
export function useNames() {
  const [, force] = React.useReducer((x: number) => x + 1, 0);
  React.useEffect(() => {
    if (Names.isReady()) return undefined;
    return Names.subscribe(force);
  }, []);
  return Names;
}

export function resolveName(kind: string, accountId: any, id: any) { return Names.resolveName(kind, accountId, id); }

// canDrill: true everywhere except the CTO persona's summary-only view, set once by App.tsx as the
// role changes. A module flag rather than a prop on every caller: <Ref> sits inside tables that
// this app does not thread every prop through.
export let _canDrill = true;
export function setCanDrill(v: any) { _canDrill = v !== false; }
export function getCanDrill() { return _canDrill; }

// TaskFocus: open/close store for task_panel.tsx. A task <Ref> click calls open, so the panel is
// reachable from a task anywhere in the app. The open task also lives in the URL hash (task=<full
// name>), so a copied link reopens into it.
export interface TaskFocusState { open: boolean; accountId: any; taskId: any }
export const TaskFocus = (function () {
  let state: TaskFocusState = { open: false, accountId: null, taskId: null };
  const listeners = new Set<(s: TaskFocusState) => void>();
  function emit() { listeners.forEach((fn) => { try { fn(state); } catch (e) { /* noop */ } }); }
  function syncHash() {
    try { HashState.set({ task: state.open ? state.taskId : null }); } catch (e) { /* no hash here */ }
  }
  (function restoreFromHash() {
    try {
      const raw = HashState.get().get("task");
      if (raw) state = { open: true, accountId: null, taskId: raw };
    } catch (e) { /* start closed */ }
  })();
  return {
    open(accountId: any, taskId: any) {
      if (!getCanDrill()) return; // the CTO's summary-only view has no drill-down
      state = { open: true, accountId: accountId == null ? null : accountId, taskId };
      syncHash();
      emit();
    },
    close() {
      state = { open: false, accountId: null, taskId: null };
      syncHash();
      emit();
    },
    getState() { return state; },
    subscribe(fn: (s: TaskFocusState) => void): () => void { listeners.add(fn); return () => listeners.delete(fn); },
  };
})();

// Best-guess Snowsight paths (the common ones; Snowflake does not publish most of them, so a path may
// change and a link may land on the parent page). A dotted id (DB.SCHEMA.OBJECT) is split into parts.
export const enc = encodeURIComponent;
export const snowParts = (id: any) => String(id).split(".").map((x) => enc(x.replace(/^"|"$/g, "")));
export function snowObjPath(id: any, kind: string) {
  const [db, schema, name] = snowParts(id);
  if (!schema) return null;
  if (!name) return `#/data/databases/${db}/schemas/${schema}`;
  return `#/data/databases/${db}/schemas/${schema}/${kind}/${name}`;
}
export const SNOWSIGHT_PATHS: Record<string, (id: any, name?: any) => string | null> = {
  warehouse: (id: any, name: any) => (name ? `#/compute/warehouses/${enc(name)}` : "#/compute/warehouses"),
  database: (id: any) => `#/data/databases/${enc(id)}`,
  schema: (id: any) => snowObjPath(id, "schema"),
  table: (id: any) => snowObjPath(id, "table"),
  view: (id: any) => snowObjPath(id, "view"),
  task: (id: any) => snowObjPath(id, "task"),
  user: () => "#/account/users",
  role: () => "#/account/roles",
  query: (id: any) => `#/compute/history/queries/${enc(id)}/detail`,
  streamlit: (id: any) => `#/streamlit-apps/${enc(id)}`,
};

// The Snowsight URL for an object, or null when the org and account names, or the path for that
// kind, are not known. Hidden in the summary-only view. name: the resolved name, for kinds keyed by id.
export function snowsightLink(kind: string, id: any, name?: any) {
  if (!getCanDrill()) return null;
  const base = Names.getSnowsightBase();
  const path = SNOWSIGHT_PATHS[kind];
  if (!base || !path || id === undefined || id === null || id === "") return null;
  const p = path(id, name);
  return p ? `${base}/${p}` : null;
}

export function SnowLink({ kind, id, name }: { kind: string; id: any; name?: any }) {
  const url = snowsightLink(kind, id, name);
  if (!url) return null;
  return (
    <a className="ref-ext" href={url} target="_blank" rel="noopener noreferrer"
       title="Best-guess Snowsight link"
       onClick={(e) => e.stopPropagation()}>
      {"Open in Snowsight ↗"}
    </a>
  );
}

// The account's name for a sentence: the resolved name, else "account <id>", else (a row with no
// account id at all) "an unknown account".
export function acctPhrase(accountId: any) {
  return resolveName("account", accountId, accountId)
    || (accountId === null || accountId === undefined || accountId === "" ? "an unknown account" : `account ${accountId}`);
}

// <Ref kind id accountId label /> renders the resolved NAME as the visible text (the raw id when
// there is no dim row or Names has not loaded yet, never a blank) with the id beside it in mono,
// and a copy affordance, because the id is what gets pasted into a Snowflake query.
export function Ref({ kind, id, accountId, label }: { kind: string; id: any; accountId?: any; label?: string | null }) {
  useNames();
  const [copied, setCopied] = React.useState(false);
  if (id === undefined || id === null || id === "") return <span className="ref-empty">{"—"}</span>;
  const idStr = String(id);
  // Three name states: resolved from the dims (full ink, "name (id)"), a caller-supplied label that
  // did not go through that lookup (dotted underline), or no name at all (the bare id, muted).
  const resolved = resolveName(kind, accountId, id);
  const name = label || resolved;
  const hasName = !!name;
  const unverified = !!label && label !== resolved;
  const display = name || idStr;
  const nameTitle = !hasName ? `${idStr}: no name in this export` : unverified ? `${idStr}: name not verified against the account views` : idStr;
  const nameCls = ["ref-name", unverified ? "ref-unverified" : "", !hasName ? "ref-noname" : ""].filter(Boolean).join(" ");

  const copyId = (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(idStr).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        }).catch(() => {});
      }
    } catch (err) { /* clipboard unavailable here: the affordance silently does nothing */ }
  };

  // A task name opens the in-app task panel; every other kind stays plain text.
  const nameEl = kind === "task" && getCanDrill() ? (
    <button
      type="button"
      className={`${nameCls} ref-job-open`}
      title={`${nameTitle}: open the task panel`}
      onClick={(e) => { e.preventDefault(); e.stopPropagation(); TaskFocus.open(accountId, id); }}
    >
      {display}
    </button>
  ) : <span className={nameCls} title={nameTitle}>{display}</span>;

  return (
    <span className="ref">
      {nameEl}
      {hasName && idStr !== name && !(kind === "task" && Names.taskNumericId(id)) && <span className="ref-id" title={idStr}>{`(${idStr})`}</span>}
      {kind === "task" && Names.taskNumericId(id) && <span className="ref-id" title="task id">{`(${Names.taskNumericId(id)})`}</span>}
      <SnowLink kind={kind} id={id} name={resolved || label} />
      {getCanDrill() && (
        <button type="button" className="ref-copy" title={`Copy id: ${idStr}`} onClick={copyId}>
          {copied ? "✓" : "⧉"}
        </button>
      )}
    </span>
  );
}
