// web/src/components/first_run.tsx -- the friendly screen App.tsx renders in place of the whole
// shell whenever GET /api/status says the app is not ready, so a fresh checkout (no database yet),
// a build that failed or never finished (dims.dim_account unreadable), or a typo in
// config/settings.yml never reads as a raw "500 Internal Server Error". Each screen names the ONE
// next command, so a first-time user has something concrete to type instead of a stack trace.
//
// This file only words the four states GET /api/status can report: "settings_invalid" |
// "no_database" | "build_incomplete" | "ready". It decides nothing; the API already has.
import React from "react";
import { BRAND_NAME } from "../api";
import { navHref } from "./nav_hash";


export function CommandBlock({ command }: { command: string }) {
  return <pre className="fr-command mono">{command}</pre>;
}

export function firstRunGuideLinkProps() {
  const build = () => navHref({ tab: "guide", focusQueryId: "how-flow" });
  return {
    href: build(),
    onClick: (e: React.MouseEvent<HTMLAnchorElement>) => { e.preventDefault(); window.location.hash = build(); },
  };
}

interface FirstRunShellProps {
  brandName: string;
  tone: string;
  title: string;
  children?: React.ReactNode;
}

export function FirstRunShell({ brandName, tone, title, children }: FirstRunShellProps) {
  return (
    <div className="fr-shell">
      <div className="brand fr-brand">
        <span className="brand-title">{brandName}</span>
        
      </div>
      <div className={`honest-card fr-card ${tone}`}>
        <div className="h-title">{title}</div>
        {children}
      </div>
      <a className="guide-linklike" {...firstRunGuideLinkProps()}>How this app works -&gt;</a>
    </div>
  );
}

/** GET /api/status settings_error: what in config/settings.yml failed to parse. */
interface SettingsError { key?: string; line?: number; message?: string }

export function SettingsInvalidScreen({ brandName, settingsError }: { brandName: string; settingsError?: SettingsError | null }) {
  const err: SettingsError = settingsError || {};
  return (
    <FirstRunShell brandName={brandName} tone="error" title="config/settings.yml needs a fix">
      <div className="h-note">
        {err.key && (
          <React.Fragment>
            Problem with <span className="mono">{err.key}</span>
            {err.line ? <span> (line {err.line})</span> : null}:{" "}
          </React.Fragment>
        )}
        {err.message || "The file could not be read."}
      </div>
      <CommandBlock command="config/settings.yml" />
      <div className="h-note">
        Open that file, fix the line above, save it, then reload this page. Nothing else in the
        app can load while this file does not match the documented shape -- every route reads it.
      </div>
    </FirstRunShell>
  );
}

export function NoDatabaseScreen({ brandName }: { brandName: string }) {
  return (
    <FirstRunShell brandName={brandName} tone="info" title="No database yet">
      <div className="h-note">
        This looks like a fresh checkout: there is nothing to show yet. First copy
        <span className="mono"> .env.example</span> to <span className="mono">.env</span> and fill in your
        Snowflake account, user, key-pair private key file, role and warehouse (README.md, "Give it
        access", creates a read-only role). Then, from a terminal in the repo root, run:
      </div>
      <CommandBlock command="python tools/first_run.py" />
      <div className="h-note">
        It exports the checks from your account, then loads them here. Then reload this page. This can
        take several minutes; only SELECT, WITH and SHOW statements are sent to Snowflake.
      </div>
    </FirstRunShell>
  );
}

export function BuildIncompleteScreen({ brandName, database }: { brandName: string; database?: { detail?: string | null } | null }) {
  const detail = database && database.detail;
  return (
    <FirstRunShell brandName={brandName} tone="warn" title="The database build didn't finish">
      <div className="h-note">
        A database file exists, but the app could not read <span className="mono">dims.dim_account</span> from
        it: the load failed before it finished, or the file is not a usable database. Run the export
        and load again from a terminal in the repo root:
      </div>
      <CommandBlock command="python tools/first_run.py" />
      <div className="h-note">Then reload this page.</div>
      {detail && <div className="h-note mono">{detail}</div>}
    </FirstRunShell>
  );
}

export function UnknownStateScreen({ brandName, state }: { brandName: string; state?: string | null }) {
  return (
    <FirstRunShell brandName={brandName} tone="error" title="Could not load">
      <div className="h-note">
        The app is not ready and did not say why (state: <span className="mono">{state || "unknown"}</span>).
        Reload this page, or check the terminal running <span className="mono">python -m app.api</span> for
        an error.
      </div>
    </FirstRunShell>
  );
}

// The one entry point App.tsx renders: appState is GET /api/status's own body, or null while it
// is still loading (never rendered in that case -- App.tsx keeps its own lightweight loading note
// for that, so this component only ever sees a resolved, non-"ready" state).
/** GET /api/status body. */
interface AppState {
  state?: string;
  brand?: { name?: string } | null;
  settings_error?: SettingsError | null;
  database?: { detail?: string | null } | null;
  [key: string]: any;
}

export function FirstRunScreen({ appState }: { appState: AppState | null }) {
  const state = appState && appState.state;
  const brandName = (appState && appState.brand && appState.brand.name) || BRAND_NAME;
  React.useEffect(() => {
    document.title = brandName;
  }, [brandName]);
  if (state === "settings_invalid") {
    return <SettingsInvalidScreen brandName={brandName} settingsError={appState!.settings_error} />;
  }
  if (state === "no_database") return <NoDatabaseScreen brandName={brandName} />;
  if (state === "build_incomplete") {
    return <BuildIncompleteScreen brandName={brandName} database={appState!.database} />;
  }
  return <UnknownStateScreen brandName={brandName} state={state} />;
}
