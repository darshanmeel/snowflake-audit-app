// web/src/components/labels.tsx -- a plain display title and one-line "why it matters" for every
// check, and a word for the enum codes the UI would otherwise print raw.
//
// Titles come from the checks themselves: the export's own title reads "<what it finds> - <why it
// matters>" (or just "<what it finds>"), so the label is derived from it and no per-check list has
// to be kept in step with the SQL. registerCheckTitles(findings) is called once when
// GET /api/findings arrives; getCheckLabel(queryId, fallbackTitle) is what every screen calls.
import type { Finding } from "../types";


/** A check's display title and its one-line why (null when the title has none). */
export interface CheckLabel { title: string; why: string | null }

export const CHECK_TITLES: Record<string, CheckLabel> = {};

export function sentenceCase(text: string | null | undefined): string {
  const s = String(text || "").trim();
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

// "warehouse idle minutes - running with no query for more than a minute (possible waste)"
//   -> {title: "Warehouse idle minutes", why: "Running with no query for more than a minute (possible waste)."}
export function splitTitle(raw: string | null | undefined): CheckLabel {
  const text = String(raw || "").trim();
  const at = text.indexOf(" - ");
  if (at < 0) return { title: sentenceCase(text), why: null };
  const why = sentenceCase(text.slice(at + 3));
  return { title: sentenceCase(text.slice(0, at)), why: /[.!?]$/.test(why) ? why : `${why}.` };
}

export function registerCheckTitles(findings: Finding[] | null | undefined) {
  (findings || []).forEach((f: Finding) => { if (f && f.query_id && f.title) CHECK_TITLES[f.query_id] = splitTitle(f.title); });
}

// The one function every screen calls: the derived label, else the finding's own title, else the id.
export function getCheckLabel(queryId: string, fallbackTitle?: string | null): CheckLabel {
  const known = CHECK_TITLES[queryId];
  if (known) return known;
  if (fallbackTitle) return splitTitle(fallbackTitle);
  return { title: queryId, why: null };
}

// Status and state words a check's rows carry (task and query states, warehouse states).
export const ENUM_LABELS: Record<string, string> = {
  SUCCESS: "Succeeded",
  SUCCEEDED: "Succeeded",
  FAILED: "Failed",
  FAIL: "Failed",
  ERROR: "Error",
  SKIPPED: "Skipped",
  CANCELLED: "Cancelled",
  CANCELED: "Cancelled",
  SUSPENDED: "Suspended",
  STARTED: "Running",
  RESUMED: "Running",
  SCHEDULED: "Scheduled",

  // reason codes (not_assessed_reason and similar): see REASON_INFO below
};

// A reason a row or a whole check reads NOT_ASSESSED: [plain label, the fix]. A check that could not
// judge never reads clean: the label says why and the fix says what would let it run.
export const SEE = "The role sees only the objects it owns or holds MONITOR on: use a role that can see them.";
export const REASON_INFO: Record<string, [string, string]> = {
  no_baseline_history: ["No earlier history to compare against", "Nothing to fix: it needs more days of usage."],
  previous_window_not_covered: ["The account is too young to compare with the previous period", "Nothing to fix: it compares once the account has usage before this window."],
  last_month_not_covered: ["No full last month to compare with", "Nothing to fix: it works once the account has a full month of usage."],
  too_early_in_month: ["Too early in the month to project", "Nothing to fix: the projection starts after the first few days of the month."],
  baseline_too_short: ["Too few earlier days to set a baseline", "Nothing to fix: it needs about a week of earlier usage."],
  too_few_queries: ["Too few statements to judge pressure", "Nothing to fix: it needs more statements on the warehouse in the window."],
  too_few_scanned_queries: ["Too few scanned statements that day to judge", "Nothing to fix: fewer than 10 statements scanned data in that day and warehouse."],
  current_period_unpriced: ["This window's spend could not be priced", "Pass the price per credit to the export (--credit-price) or set it in Settings."],
  previous_period_unpriced: ["The previous window's spend could not be priced", "Pass the price per credit to the export (--credit-price) or set it in Settings."],
  not_assessed_no_price: ["No price per credit is available for this export", "Pass the price per credit to the export (--credit-price) or set it in Settings."],
  unpriced: ["Not priced: no $ per credit or $ per TB", "Pass the price to the export (--credit-price, --storage-price) or set it in Settings. Archive tiers have no published price."],
  not_consumption: ["Not consumption billing, so it has no metered match", "Nothing to fix: this billing type is not metered usage."],
  not_in_show_applications: ["Billed app not in SHOW APPLICATIONS", SEE],
  no_quota: ["The monitor has no credit quota", "Nothing to fix here: set a credit quota on the monitor to track pace."],
  no_reset_cycle: ["The monitor has no start or frequency", "Use a role that can run SHOW RESOURCE MONITORS."],
  not_started: ["The monitor has not started yet", "Nothing to fix: it projects once the cycle starts."],
  no_attribution: ["No attributed queries on this warehouse", "Nothing to fix: adaptive warehouses and very short queries have no attribution."],
  no_warehouse_metering: ["No metered credits for this warehouse", "Nothing to fix: the warehouse had no billed usage in the window."],
  not_in_show_warehouses: ["Billed warehouse not in SHOW WAREHOUSES", SEE],
  not_in_show: ["Billed warehouse not in SHOW WAREHOUSES", SEE],
  no_load_history: ["No load history for this warehouse in the window", "Nothing to fix: load history has no rows for it (adaptive, or it ran nothing)."],
  unknown_size: ["Size or credit rate unknown (adaptive or not in SHOW)", "Nothing to fix: an adaptive warehouse has no fixed size to judge."],
  size_unknown: ["Size or credit rate unknown (adaptive or not in SHOW)", "Nothing to fix: an adaptive warehouse has no fixed size to judge."],
  no_baseline_hours: ["No hours at the earlier size to compare with", "Nothing to fix: it needs usage before the resize."],
  no_session_record: ["No session record, so the client is unknown", "Nothing to fix here: the session is past SESSIONS retention or opened long before the window."],
  warehouse_not_visible: ["Not visible to this role", "In no SHOW and not dropped. " + SEE],
  monitor_not_visible: ["Resource monitor not visible to this role", "Grant MONITOR on the resource monitors, or use a role that owns them."],
  integrations_not_visible: ["Integrations not visible to this role", SEE],
  integration_not_visible: ["Integration not visible to this role", SEE],
  stages_not_visible: ["Stages not visible to this role", SEE],
  streams_not_visible_or_none: ["No streams visible to this role", SEE],
  tasks_not_visible: ["Tasks not visible to this role", SEE],
  alerts_not_visible: ["Alerts not visible to this role", SEE],
  services_not_visible: ["Services not visible to this role", SEE],
  dts_not_visible: ["Dynamic tables not visible to this role", SEE],
  attachment_not_visible: ["Policy attachments not visible to this role", "Use a role that can read the policy references (Enterprise edition)."],
  settings_not_visible: ["Policy settings not visible to this role", "Use a role that can run SHOW PASSWORD POLICIES."],
  usage_not_visible: ["Endpoint usage not visible to this role", SEE],
  access_history_unavailable: ["Read history needs Enterprise edition", "Needs ACCESS_HISTORY: Enterprise edition and a role that can read it."],
  no_access_history: ["Read history needs Enterprise edition", "Needs ACCESS_HISTORY: Enterprise edition and a role that can read it."],
  no_credential_record: ["No credential record", "Snowflake holds no record for this key: nothing to age."],
  no_sensitive_tags: ["Nothing is tagged sensitive in this account", "Tag sensitive columns first (classification or your own tags)."],
  no_data_metric_function: ["No data metric function in the account: not in use", "Data metric functions need Enterprise edition."],
  no_database: ["No database behind the listing", "Nothing to fix."],
  no_rows_in_lookback: ["No rows in the lookback", "Nothing to fix: the view has no rows in the period."],
  not_in_show_replication_groups: ["Group not in SHOW REPLICATION GROUPS", SEE],
  no_successful_requests: ["No successful requests to compare", "Nothing to fix: it needs successful sign-ins in the window."],
  scanners_not_enabled: ["Trust Center scanners are not enabled", "Enable the Trust Center scanner packages, then re-run the export."],
  no_policies_visible: ["No data movement policy visible to this role", SEE],
  no_user_rows: ["No users read for the account", "Use a role that can read USERS for that account."],
  runs_jobs: ["The pool runs jobs, so idle time cannot be judged", "Nothing to fix: job pools are billed for the job."],
  edition_too_low: ["Needs a higher Snowflake edition", "No grant helps: it needs Enterprise or Business Critical edition."],
  no_access: ["The role cannot read this view", "Run the GRANT shown for the check, or use a role that can read it."],
  view_missing: ["The view is not in this account", "Nothing to fix here: the view is missing or not rolled out to this account yet."],
  timeout: ["The query timed out", "Re-run the export with a longer --statement-timeout."],
  unknown: ["The check failed for an unknown reason", "See the error on Coverage & Gaps."],
  not_built: ["Not built in this export", "Re-run the export."],
  build_failed: ["Failed to build", "See the error on Coverage & Gaps."],
  not_exported: ["Not in this export", "Re-run the export, or use an export from a newer version."],
  all_rows_not_assessed: ["Ran, but no row could be judged", "See why on each row."],
};

// Words for the code columns a table shows, per column (a code means one thing in one column only).
export const ENUM_BY_COLUMN: Record<string, Record<string, string>> = {
  pressure: {
    MEMORY: "Memory pressure", CAPACITY: "Waiting for capacity", MEMORY_AND_CAPACITY: "Memory and capacity pressure", NONE: "No pressure",
  },
  scaling_hint: {
    SCALE_UP: "Scale up (a bigger size)", SCALE_OUT: "Scale out (more clusters)", KEEP_WARM: "Keep warm (fewer cold starts)",
    SCALE_UP_THEN_OUT: "Scale up, then out", SCALE_UP_THEN_WARM: "Scale up, then keep warm", NONE: "No change needed",
    ENABLE_MULTI_CLUSTER: "Turn on multi-cluster", RAISE_MAX_CLUSTERS: "Raise the maximum clusters", SWITCH_TO_STANDARD: "Switch to the Standard policy",
    LOWER_MIN_CLUSTERS: "Lower the minimum clusters", TRY_ECONOMY: "Try the Economy policy", MAX_NEVER_REACHED: "Maximum never reached",
  },
  row_kind: { user: "User", unattributed: "Not attributed" },
  pool_kind: { system_notebook: "Notebook runtime (system)", application: "Native app", user: "User pool" },
  set_kind: { backup: "Backup", snapshot: "Snapshot (deprecated)" },
  feed_kind: { billing: "Billing view", always_on: "Always-on view", activity: "Activity view" },
  cause: {
    no_access: "Role cannot read it", view_missing: "View missing", timeout: "Timed out", edition_too_low: "Needs a higher edition", unknown: "Unknown",
  },
  provider_kind: { azure: "Azure", other: "Other" },
  owner_state: { not_listed: "Owner not listed", deleted: "Owner deleted", disabled: "Owner disabled", active: "Active" },
  finding: {
    ok: "OK", silent_failures: "Fails with no one notified", execute_as_user_gone: "Runs as a user who no longer exists",
    admin_owner: "Owned by an admin role", allow_all_overlap: "Overlap policy allows all runs",
    auto_suspended: "Suspended by Snowflake after failures", suspended_stale: "Suspended and left", started_not_evaluating: "Started but not evaluating",
    suspended_and_read: "Suspended but still read", suspended_unread: "Suspended, not read", suspended_reads_unknown: "Suspended, reads unknown",
    orphaned: "Orphaned stage", owner_gone: "Owner gone", stale: "Stale files",
  },
  billing_origin_product: {
    DATA_TRANSFER: "Data transfer (estimated per TB)", STORAGE_ARCHIVE: "Storage archive (no price: unpriced)",
  },
  not_assessed_reason: {},
};
Object.keys(REASON_INFO).forEach((k) => { ENUM_BY_COLUMN.not_assessed_reason[k] = REASON_INFO[k][0]; });

export function columnEnumLabel(column: string, value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  const map = ENUM_BY_COLUMN[column];
  return (map && map[String(value)]) || null;
}

// The plain label of a not_assessed_reason (or any status word above), else the code as written.
export function enumLabel(code: string | null | undefined): string | null {
  if (code === null || code === undefined || code === "") return null;
  if (REASON_INFO[code]) return REASON_INFO[code][0];
  return ENUM_LABELS[code] || String(code);
}
// What would let the check run, or null when the code has no known fix.
export function reasonFix(code: string): string | null {
  return REASON_INFO[code] ? REASON_INFO[code][1] : null;
}
