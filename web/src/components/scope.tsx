// web/src/components/scope.tsx -- say what the data covers.
//
// Two facts a screen must be able to state, and the one place their words live:
//  1. Why a check did not run. The export records each failed check with the reason Snowflake gave
//     (a view the role cannot see, a view missing from the edition, a timeout); the API reads that
//     as a short label ("the role can't see it", "needs Enterprise edition", ...). A check that did
//     not run shows "-" and that reason, never $0 and never a clean result.
//  2. Filter reach. A check whose rows carry no account id is not narrowed by the Account filter;
//     /api/findings rows say so (read through scopeHasAccount, api.tsx).
// Nothing here decides coverage: the API computes every fact; this file only words it.

// A finding whose own table is missing (the export predates a newly added check) reads
// NOT_ASSESSED with a not_built reason. That raw reason is written for a developer, so every
// reader-facing surface shows this one honest line instead.
import { scopeHasAccount } from "../api";
import { Badge } from "./primitives";
import { NO_ACCOUNT_MATCH } from "../App";
import { numOrZero } from "./hooks";
import type { Filters, Finding, Meta, Row } from "../types";

export const NOT_BUILT_READING = "Not in this export yet: run the export again.";
export const NO_PRICE_READING = "No credit price in this export: pass one to the export.";
export const NO_PRICE_LEDE = "Spend is not shown: there is no credit price in this export.";
// An aggregate whose every value was NULL: the $ column had no price, so its total is unknown.
export function isUnpricedAgg(data: Row | null | undefined) {
  return !!data && data.total_value == null && numOrZero(data.null_value_rows) > 0;
}
export function isNotBuilt(data: Row | null | undefined) {
  return !!(data && data.status_info && data.status_info.not_built_reason);
}

// One line for why a check did not run, from its status_info (or the finding's own `not_assessed`):
// the reason, then the check's own access line (`requires`); the GRANT lines are on Coverage.
export function notAssessedText(data: Row | null | undefined) {
  if (isNotBuilt(data)) return NOT_BUILT_READING;
  const info: Row = (data && data.status_info) || {};
  const na = data && data.not_assessed;
  const label = na && na.label;
  if (label) return `Not assessed: ${label}.${na.requires ? ` Needs: ${na.requires}` : ""}`;
  const src = (info.blocking_sources || [])[0];
  if (src) return `Not assessed: ${src.source} is ${src.reason === "no_grant" ? "not readable by the audit role" : "not in this export"}.`;
  if (info.status === "failed" || info.status === "error") {
    return info.message ? `Not assessed: the check failed (${String(info.message).slice(0, 140)}).` : "Not assessed: the check failed in the export.";
  }
  if (isUnpricedAgg(data)) return NO_PRICE_READING;
  return "Not in this export.";
}

// One tile-sized line for a finding the Account filter does not reach; null when it does.
export function findingScopeLabel(f: Row | null | undefined) {
  if (!f || scopeHasAccount(f)) return null;
  return "Whole account: not narrowed by the Account filter";
}

// Detail-panel badge for a finding the Account filter does not reach.
export function FindingScopeBadge({ scope }: { scope?: Row | null }) {
  if (!scope || scopeHasAccount(scope)) return null;
  return <Badge kind="info">whole account, not narrowed by the Account filter</Badge>;
}

// One line above a checks table: the checks in it that the Account filter does not narrow.
export function TabScopeNote({ findings, filters }: { findings?: Finding[] | null; meta?: Meta | null; filters?: Filters | null }) {
  const rows = findings || [];
  const unfiltered = rows.filter((f: Finding) => !scopeHasAccount(f));
  // Only worth saying while an account filter narrows the page.
  const narrowed = !!(filters && filters.accountIds && filters.accountIds.length);
  if (unfiltered.length === 0 || !narrowed) return null;
  // An attribute filter that matches no account sends the NO_ACCOUNT_MATCH sentinel (App.tsx):
  // exclude it so this reads "0 selected", not "1 selected".
  const selected = filters && filters.accountIds
    ? filters.accountIds.filter((id: string) => id !== NO_ACCOUNT_MATCH).length
    : 0;
  const n = unfiltered.length;
  let text = n === rows.length
    ? `The Account filter doesn't apply to ${n === 1 ? "this check" : `these ${n} checks`}`
    : `The Account filter doesn't apply to ${n} of these ${rows.length} checks`;
  text += selected > 0 ? `: ${n === 1 ? "it covers" : "they cover"} the whole account, not only the ${selected} selected.` : ".";
  return <div className="scope-note">{text}</div>;
}
