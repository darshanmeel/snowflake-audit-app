// web/src/components/tab_registry.tsx -- the curated check-id lists behind every area: AREA_REGISTRY
// maps area -> sub-tabs -> owned query_ids. A "refIds" id is a reference feed (an inventory or a
// chart source): shown on its sub-tab, never counted in the badges. Every id in
// app/queries/manifest.json sits in exactly one sub-tab's `ids` or `refIds`; tools/check_registry_ids.py
// fails when the two drift apart. Badges, the checks table, All-findings links and the Guide's
// "browse by screen" cards all read this one map.
//
// This file is DATA (+ the small lookup builders at the bottom) so every area page and App.tsx can
// share one source of truth without importing each other's markup.

// The backend's own domain taxonomy (app/core/data.py). Every finding's `row.domain` comes from
// this vocabulary; only the labels are Snowflake words.
import { bandOf } from "./primitives";
import type { Row } from "../types";

/** One sub-tab of an area: the checks it owns (`ids`) and its reference feeds (`refIds`). */
export interface SubtabDef {
  key: string;
  label: string;
  ids: string[];
  refIds: string[];
  org?: boolean;
  lead?: string;
}

/** One area of the app: its label, scope line and sub-tabs. */
export interface AreaDef {
  label: string;
  scope: string;
  subtabs: SubtabDef[];
  refIds?: string[];
}

/** The badge tally countsForIds returns. */
export interface BadgeCounts {
  critical: number;
  warn: number;
  noData: boolean;
  notRun?: boolean;
}

/** Where a check lives: its area and sub-tab. */
export interface QueryHome {
  tab: string;
  subtab: string | null;
}

export const DOMAIN_LABELS: Record<string, string> = {
  cost: "Cost",
  compute: "Warehouses",
  jobs_pipelines: "Tasks & loading",
  performance: "Query performance",
  governance_access: "Access & governance",
  storage: "Storage",
  serving_ai: "AI & apps",
};
export const DOMAIN_ORDER = ["cost", "compute", "jobs_pipelines", "performance", "governance_access", "storage", "serving_ai"];

// One scope line for every money page: credits are what Snowflake bills; dollars are credits times
// the account's effective $ per credit (read from the organization billing view when the role can
// see it, else the price passed to the export).
export const MONEY_SCOPE = "Credits × your effective $ per credit · storage at your $ per TB";

// ─────────── Cost ───────────
export const COST_SUBTABS: SubtabDef[] = [
  {
    key: "trend", label: "Trend",
    ids: ["cost_daily_spikes", "sf_cost_anomalies_vs_spikes", "cost_period_over_period", "cost_by_hour_of_day", "sf_cost_month_end_forecast"],
    refIds: ["cost_dollarized_by_service_day", "cost_monthly_actuals", "cost_daily_by_resource"],
  },
  {
    key: "service", label: "By service",
    ids: ["cost_chargeback_by_service", "sf_cost_cloud_services_billed", "sf_cost_cloud_services_drivers", "sf_cost_data_transfer_egress"],
    refIds: [],
  },
  {
    key: "who", label: "Who spent it",
    ids: ["sf_cost_query_attribution_by_user", "sf_chg_by_role", "sf_chg_by_warehouse_and_user_daily", "sf_chg_bi_dashboards", "sf_chg_dbt_models"],
    refIds: [],
  },
  {
    key: "chargeback", label: "Chargeback & tags",
    ids: [
      "sf_chg_tag_based_allocation", "sf_chg_tag_coverage", "sf_cost_query_attribution_by_query_tag",
      "sf_chg_by_database_schema", "sf_chg_allocation_reconciliation", "sf_chg_idle_allocation", "sf_gov_tag_hygiene",
      "cost_chargeback_by_warehouse", "cost_chargeback_by_account",
    ],
    refIds: [],
  },
  {
    // Reads the daily spend and query feeds homed on Cost > Trend and Queries > Trend.
    key: "before", label: "Before & after",
    ids: [],
    refIds: [],
  },
  {
    key: "contract", label: "Contract & rate",
    ids: ["sf_cost_rate_sheet", "sf_cost_invoice_vs_metered", "sf_cost_contract_balance_burn"],
    refIds: [],
  },
  {
    key: "budgets", label: "Budgets & guardrails",
    ids: ["sf_acct_budgets", "sf_cost_resource_monitor_coverage", "sf_cost_resource_monitor_projection", "sf_acct_parameters_posture"],
    refIds: [],
  },
];

// ─────────── Waste & savings ───────────
// A roll-up: every id here is homed on another area's sub-tab. The three money units are never
// added together:
//   dollarCol  possible waste over the window (a waste-kind column)
//   savingCol  possible saving over the window (a saving-kind column, e.g. resizing)
//   monthCol   storage $ per month (a saving or the spend that would stop)
// creditCol is the same waste in credits, when the check carries it. A check with none of the three
// is flagged only. `area` is the AREA_REGISTRY key the "open the check" link lands on.
export const WASTE_ITEMS = [
  // possible waste, priced over the window
  { id: "sf_wh_idle_minutes", area: "warehouses", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Warehouse up with no query running, auto-suspend wait included: credits billed while idle. Possible waste." },
  { id: "cost_failed_statement_waste", area: "queries", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "SQL statements that failed after using warehouse credits. Possible waste; some is unavoidable." },
  { id: "sf_task_warehouse_vs_serverless", area: "tasks", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Short tasks that keep a warehouse awake. The idle credits are the same idle time as the warehouse idle check, so shown as context, not counted twice." },
  { id: "sf_task_noop_runs", area: "tasks", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Task runs that woke a warehouse and changed nothing. Possible waste." },
  { id: "sf_dt_unread_refresh_cost", area: "tasks", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Dynamic tables refreshed although nothing reads them. Possible waste." },
  { id: "sf_perf_query_retries", area: "queries", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Execution time lost to automatic query retries. Possible waste." },
  { id: "sf_wh_resize_left_upsized", area: "warehouses", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Warehouses resized up and left at the bigger size: credits above what the load needs. Possible waste." },
  { id: "sf_ai_provisioned_throughput_use", area: "ai", dollarCol: "est_idle_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Provisioned Cortex throughput paid for on days the model was not used. Possible waste." },
  { id: "sf_obj_iceberg_compaction_cost", area: "loading", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Iceberg compaction credits that cost more than the reads they help. Possible waste." },
  { id: "sf_obj_catalog_linked_db_cost", area: "serverless", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Catalog-linked databases that sync more than they are read. Possible waste." },
  { id: "sf_ai_credits_on_failed_queries", area: "ai", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Cortex AI credits on statements that failed, timed out or were cancelled: the tokens still bill. Possible waste; the warehouse time is in the failed-statements line." },
  { id: "sf_ai_spcs_pool_no_live_service", area: "ai", dollarCol: "est_wasted_usd_list", creditCol: null, savingCol: null, monthCol: null, why: "Compute pools billing with no running service or job. Possible waste." },
  // possible saving, priced over the window (its own figure)
  { id: "sf_wh_oversized", area: "warehouses", dollarCol: null, creditCol: null, savingCol: "est_saving_usd_list", monthCol: null, why: "Large warehouses that mostly run small queries: the credits a smaller size would save. Possible saving, not waste." },
  { id: "sf_wh_consolidation_candidates", area: "warehouses", dollarCol: null, creditCol: null, savingCol: "est_saving_usd_list", monthCol: null, why: "Same-size warehouses lightly loaded at the same hours: the credits one shared warehouse would save. Possible saving, not waste." },
  { id: "sf_wh_snowpark_optimized_fit", area: "warehouses", dollarCol: null, creditCol: null, savingCol: "est_saving_usd_list", monthCol: null, why: "Snowpark-optimized warehouses that run plain SQL: the premium a standard warehouse of the same size would not charge. Possible saving, not waste." },
  // storage, priced per month (its own figure)
  { id: "sf_storage_unused_tables", area: "storage", dollarCol: null, creditCol: null, savingCol: null, monthCol: "est_storage_usd_month", why: "Tables nobody has read: what their storage costs each month." },
  { id: "sf_use_unused_clones", area: "storage", dollarCol: null, creditCol: null, savingCol: null, monthCol: "est_storage_usd_month", why: "Zero-copy clones nobody reads: what the storage they keep alive costs each month." },
  { id: "sf_storage_dropped_not_purged", area: "storage", dollarCol: null, creditCol: null, savingCol: null, monthCol: "est_storage_usd_month", why: "Dropped tables still billed for Time Travel and Fail-safe, per month." },
  { id: "sf_storage_stale_stage_files", area: "storage", dollarCol: null, creditCol: null, savingCol: null, monthCol: "est_saving_usd_month", why: "Stage files nobody cleaned up: the storage removing them frees, per month." },
  { id: "sf_storage_retention_policy", area: "storage", dollarCol: null, creditCol: null, savingCol: null, monthCol: "est_saving_usd_month", why: "Time Travel retention above the account policy: the storage a shorter setting frees, per month." },
  { id: "sf_storage_failsafe_on_staging", area: "storage", dollarCol: null, creditCol: null, savingCol: null, monthCol: "est_saving_usd_month", why: "Staging-like permanent tables paying for Fail-safe: the storage a transient table frees, per month." },
  { id: "sf_storage_churn_unread", area: "storage", dollarCol: null, creditCol: null, savingCol: null, monthCol: "est_saving_usd_month", why: "Churning tables nobody reads: the Time Travel and Fail-safe storage a shorter setting frees, per month. A ceiling." },
  // flagged, not priced
  { id: "sf_storage_stage_bytes", area: "storage", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "All internal-stage storage, per month: spend that holds the stale stage files counted above, so not added." },
  { id: "sf_cost_warehouse_idle_credits_daily", area: "warehouses", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Idle warehouse credits by day: the same idle time as the priced idle check, so not counted twice." },
  { id: "sf_wh_auto_suspend_tuning", area: "warehouses", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "What a shorter auto-suspend would save (60 s, or 5 min where the warehouse cache is reused): an option on the idle check, not an extra amount." },
  { id: "sf_wh_keepalive_pollers", area: "warehouses", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Repeated tiny polls that keep a warehouse from suspending: part of the idle $, so not counted twice." },
  { id: "sf_dt_lag_keeps_warehouse_awake", area: "tasks", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Dynamic tables that refresh sooner than their warehouse can suspend: part of the idle $, so not counted twice." },
  { id: "sf_load_bulk_copy_vs_snowpipe", area: "loading", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Frequent small COPY loads Snowpipe could run for less: an estimate on weak signals, shown on its own and not added to savings." },
  { id: "sf_wh_resume_churn", area: "warehouses", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Runs shorter than the 60-second billing minimum: the top-ups are part of the idle $, so not counted twice." },
  { id: "sf_wh_load_utilization", area: "warehouses", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Warehouses billed for hours with little load. Overlaps the idle check, so not priced here." },
  { id: "sf_storage_clustering_value", area: "serverless", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Automatic clustering that may cost more than the reads it speeds up. Worth reviewing; not priced as waste." },
  { id: "sf_storage_mv_value", area: "serverless", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Materialized views refreshed more than they are read. Worth reviewing; not priced as waste." },
  { id: "sf_storage_search_optimization_value", area: "serverless", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Search optimization that may cost more than the lookups it helps. Worth reviewing; not priced as waste." },
  { id: "sf_perf_query_shape_regression", area: "queries", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Statement shapes that got slower: their extra credits are a change, not waste, so not counted." },
  { id: "sf_ai_cortex_search_stale_index_serving", area: "ai", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Search services serving an index that stopped taking new rows: the serving $ is spend at risk, not waste." },
  { id: "sf_query_result_cache_misses", area: "queries", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Identical queries re-run instead of served from the result cache. Flagged; not priced." },
  { id: "sf_query_repeated_expensive", area: "queries", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Expensive statements run over and over. Flagged; not priced." },
  { id: "sf_cost_cloud_services_billed", area: "cost", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Cloud services billed above the 10% allowance. Flagged; not priced as waste." },
  { id: "sf_pipe_inactive", area: "loading", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Pipes that stopped loading. Flagged; not priced." },
  { id: "sf_stream_stale", area: "tasks", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Streams that are stale or not consumed. Flagged; not priced." },
  { id: "sf_task_suspended_or_stale", area: "tasks", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Tasks that are suspended or no longer run: likely abandoned. Flagged; not priced." },
  { id: "sf_org_dormant_accounts", area: "sharing", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Accounts that still bill storage with little or no compute. Flagged; not priced." },
  { id: "sf_obj_hybrid_tables", area: "serverless", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "Hybrid tables that are idle but still billed. Flagged; not priced." },
  { id: "sf_obj_external_tables", area: "loading", dollarCol: null, creditCol: null, savingCol: null, monthCol: null, why: "External tables that are broken, stale or refreshed for nobody. Flagged; not priced." },
];
export const WASTE_IDS = WASTE_ITEMS.map((w) => w.id);

// ─────────── Warehouses ───────────
export const WAREHOUSE_SUBTABS: SubtabDef[] = [
  {
    // `lead`: the check whose figure is this sub-tab's impact tile (the auto-suspend saving), shown
    // first; the idle waste it overlaps keeps its own tile and is never added to it.
    key: "idle", label: "Idle & settings", lead: "sf_wh_auto_suspend_tuning",
    ids: ["sf_wh_last_activity", "sf_wh_idle_minutes", "sf_cost_warehouse_idle_credits_daily", "sf_wh_auto_suspend_tuning", "sf_wh_keepalive_pollers", "sf_wh_resume_churn", "sf_wh_config_posture"],
    refIds: ["sf_wh_config_current"],
  },
  {
    key: "sizing", label: "Sizing",
    ids: ["sf_wh_oversized", "sf_wh_undersized", "query_warehouse_pressure", "sf_wh_consolidation_candidates", "sf_wh_resize_left_upsized", "sf_wh_snowpark_optimized_fit", "sf_wh_gen2_fit"],
    refIds: [],
  },
  {
    key: "load", label: "Load & scaling",
    ids: ["sf_wh_starts_resumes", "sf_wh_load_utilization", "sf_wh_multicluster_scaling", "sf_wh_mixed_workload_contention", "sf_wh_query_acceleration_eligible", "sf_wh_query_acceleration_spend", "sf_wh_adaptive_attribution"],
    refIds: ["sf_wh_state_daily", "sf_wh_spend_monthly"],
  },
];

// ─────────── Serverless features ───────────
export const SERVERLESS_SUBTABS: SubtabDef[] = [
  {
    key: "feature", label: "By feature",
    ids: ["sf_cost_serverless_features", "sf_cost_openflow_spend", "sf_obj_catalog_linked_db_cost", "sf_obj_hybrid_tables", "sf_acct_observability_cost"],
    refIds: [],
  },
  {
    key: "clustering", label: "Clustering",
    ids: ["sf_storage_clustering_value", "sf_storage_clustering_candidates", "sf_storage_clustering_key_mismatch"],
    refIds: [],
  },
  {
    key: "mvso", label: "MVs & search optimization",
    ids: ["sf_storage_mv_value", "sf_storage_search_optimization_value"],
    refIds: [],
  },
];

// ─────────── Queries ───────────
export const QUERY_SUBTABS: SubtabDef[] = [
  {
    key: "heavy", label: "Heavy",
    ids: ["query_top_by_cost", "sf_query_cost_by_statement_type", "sf_query_repeated_expensive", "sf_query_long_running", "sf_query_large_result_sets", "sf_perf_query_insights_by_warehouse", "sf_perf_query_insights_opportunities"],
    refIds: ["query_costly_statements_grouped"],
  },
  {
    key: "efficiency", label: "Efficiency",
    ids: [
      "query_local_spillage", "sf_query_remote_spill", "query_pruning_effectiveness", "sf_query_full_scans",
      "sf_query_compilation_heavy", "query_cache_coldstart", "sf_query_result_cache_misses",
      "sf_perf_table_pruning_regression", "sf_perf_table_scan_selectivity", "sf_perf_query_shape_regression",
    ],
    refIds: [],
  },
  {
    key: "failures", label: "Failures",
    ids: ["query_failed_queries_daily", "sf_query_failed_by_error", "cost_failed_statement_waste", "sf_perf_query_retries"],
    refIds: [],
  },
  {
    key: "waiting", label: "Waiting",
    ids: ["query_queuing_waits", "sf_query_blocked_lock_waits", "query_workload_mix_hours", "sf_perf_high_frequency_tail_latency"],
    refIds: [],
  },
  {
    // Also hosts the tag rollup (tag_rollup.tsx) in performance mode.
    key: "team", label: "By source & team",
    ids: ["query_provenance_by_source", "sf_query_by_client_application", "sf_use_query_type_mix"],
    refIds: [],
  },
  {
    key: "trend", label: "Trend",
    ids: [],
    refIds: ["sf_qry_daily_by_warehouse"],
  },
];

// ─────────── Tasks & pipelines ───────────
export const TASK_SUBTABS: SubtabDef[] = [
  {
    key: "failures", label: "Failures",
    ids: ["sf_task_failures", "sf_task_silent_failures", "sf_task_graph_health", "sf_task_alerts", "sf_task_alerts_silenced"],
    refIds: ["sf_task_runs_daily", "sf_task_failure_attributes"],
  },
  {
    key: "cost", label: "Cost & timing",
    ids: ["sf_task_run_times", "sf_task_cost", "sf_task_warehouse_vs_serverless", "sf_task_duration_regression", "sf_task_skipped_overlaps", "sf_task_start_delay", "sf_task_noop_runs"],
    refIds: [],
  },
  {
    key: "hygiene", label: "Hygiene",
    ids: ["sf_task_suspended_or_stale", "sf_task_ownership_orphans"],
    refIds: [],
  },
  {
    key: "dynamic", label: "Dynamic tables & streams",
    ids: ["sf_dt_refresh_failures_and_lag", "sf_dt_cost", "sf_dt_unread_refresh_cost", "sf_dt_suspended_still_read", "sf_dt_downstream_orphans", "sf_dt_lag_keeps_warehouse_awake", "sf_stream_stale", "sf_stream_consumers"],
    refIds: [],
  },
];

// ─────────── Data loading ───────────
export const LOADING_SUBTABS: SubtabDef[] = [
  {
    key: "pipes", label: "Snowpipe & streaming",
    ids: ["sf_pipe_cost_and_files", "sf_pipe_inactive", "sf_pipe_invalid_or_unnotified", "sf_load_streaming_cost", "sf_load_snowpipe_latency", "sf_load_streaming_channel_errors"],
    refIds: [],
  },
  {
    key: "copy", label: "COPY, external & Iceberg",
    ids: ["sf_load_copy_errors", "sf_load_small_files", "sf_load_bulk_copy_vs_snowpipe", "sf_load_copy_listing_overhead", "sf_obj_external_tables", "sf_obj_iceberg_tables", "sf_obj_iceberg_compaction_cost"],
    refIds: [],
  },
];

// ─────────── AI & apps ───────────
export const AI_SUBTABS: SubtabDef[] = [
  {
    key: "cortex", label: "Cortex",
    ids: [
      "sf_ai_services_spend_trend", "sf_ai_functions_spend_by_user", "sf_ai_cortex_analyst_spend",
      "sf_ai_cortex_search_spend", "sf_ai_agent_spend", "sf_ai_cortex_code_spend", "sf_ai_cowork_spend",
      "sf_ai_provisioned_throughput_use", "sf_ai_spend_by_feature_reconciled", "sf_ai_access_open_to_all",
      "sf_ai_credits_on_failed_queries", "sf_ai_cortex_search_stale_index_serving",
    ],
    refIds: [],
  },
  {
    key: "apps", label: "Containers, apps & code",
    ids: [
      "sf_ai_snowpark_container_services", "sf_ai_compute_pools_config", "sf_ai_spcs_pool_no_live_service",
      "sf_ai_spcs_costs_outside_pools", "sf_ai_spcs_public_endpoints", "sf_ai_notebook_runtime_by_notebook", "sf_obj_streamlit_notebooks",
      "sf_obj_udfs_procedures", "sf_cost_native_app_spend", "sf_cost_native_app_inventory",
    ],
    refIds: [],
  },
  {
    key: "serving", label: "Model serving",
    ids: ["sf_ai_model_serving_spend"],
    refIds: [],
  },
];

// ─────────── Access ───────────
export const ACCESS_SUBTABS: SubtabDef[] = [
  {
    key: "roles", label: "Roles & grants",
    ids: [
      "access_broad_grants", "sf_gov_public_role_grants", "sf_gov_role_hygiene", "sf_secx_direct_user_grants",
      "sf_secx_grant_option", "sf_govx_schema_grant_control", "sf_gov_ownership_concentration", "sf_secx_secondary_roles_usage",
      "sf_sec_usage_view_access", "sf_gov_unused_object_grants",
    ],
    refIds: ["access_grants_inventory"],
  },
  {
    key: "users", label: "Users & sign-ins",
    ids: [
      "sf_sec_users_without_mfa", "sf_sec_password_service_users", "sf_secx_key_and_password_age", "sf_sec_stale_users",
      "sf_sec_failed_logins", "sf_sec_new_login_sources", "access_login_concentration", "sf_secx_login_client_versions",
      "sf_secx_sso_oauth_integrations", "sf_secx_user_auth_state", "sf_secx_pat_hygiene", "sf_secx_key_pair_age",
      "sf_sec_privatelink_bypass",
    ],
    refIds: [],
  },
  {
    key: "perimeter", label: "Account perimeter",
    ids: [
      "sf_sec_trust_center_findings", "sf_sec_account_security_settings", "sf_sec_network_policy_coverage", "sf_sec_network_policy_unattached",
      "sf_secx_session_policy_coverage", "sf_gov_integrations_exposure", "sf_govx_external_stage_credentials",
      "sf_secx_secrets_hygiene", "sf_secx_authentication_policy_posture", "sf_secx_network_rule_exposure",
      "sf_secx_external_access_calls", "sf_secx_password_policy_posture", "sf_sec_failover_readiness",
      "sf_sec_native_app_permissions", "sf_sec_outbound_privatelink_endpoints", "sf_sec_trust_center_finding_age",
    ],
    refIds: [],
  },
];

// ─────────── Audit ─── who holds the admin roles, how they sign in and what changed in the account.
export const AUDIT_SUBTABS: SubtabDef[] = [
  {
    key: "admins", label: "Admins & sign-ins",
    ids: ["sf_sec_admin_role_holders", "sf_govx_admin_role_daily_use", "sf_audit_admin_signins", "sf_audit_admin_sessions"],
    refIds: [],
  },
  {
    key: "changes", label: "Changes",
    ids: ["sf_sec_privileged_grant_changes", "sf_sec_security_config_changes", "sf_audit_grant_activity", "sf_audit_object_ddl_timeline"],
    refIds: [],
  },
];

// ─────────── PII & policies ───────────
export const PII_SUBTABS: SubtabDef[] = [
  {
    key: "sensitive", label: "Sensitive data",
    ids: ["sf_gov_classification_coverage", "sf_gov_classification_denominator", "sf_gov_sensitive_columns_unprotected", "sf_secx_sensitive_lineage_untagged"],
    refIds: ["access_tags_inventory"],
  },
  {
    key: "policies", label: "Masking & row policies",
    ids: ["sf_secx_unused_policies", "sf_secx_policy_body_exemptions", "sf_gov_privacy_policies_unattached", "sf_gov_policy_separation_of_duties"],
    refIds: ["access_column_masks_inventory", "access_row_filters_inventory"],
  },
  {
    key: "reads", label: "Who reads it, where it goes",
    ids: ["sf_gov_sensitive_data_access", "sf_gov_data_egress", "sf_gov_shares_sensitive_columns", "sf_sec_data_movement_violations", "sf_gov_ai_agent_data_access"],
    refIds: [],
  },
  {
    key: "quality", label: "Data quality",
    ids: ["sf_gov_dmf_coverage", "sf_gov_dmf_expectation_failures", "sf_gov_dmf_static_table_schedules"],
    refIds: [],
  },
];

// ─────────── Lineage & usage ─── what depends on what, and what is used. Unused tables and clones stay
// on Storage, where they carry a $ figure.
export const LINEAGE_SUBTABS: SubtabDef[] = [
  {
    key: "dependencies", label: "Dependencies & lineage",
    ids: ["sf_lin_blast_radius", "sf_obj_broken_views", "sf_lin_table_flows"],
    refIds: ["access_views_inventory"],
  },
  {
    key: "usage", label: "Usage",
    ids: ["sf_use_database_activity", "sf_use_user_activity", "sf_lin_unused_views"],
    refIds: ["sf_acct_object_counts"],
  },
];
export const LINEAGE_IDS = LINEAGE_SUBTABS.flatMap((s) => s.ids);
export const LINEAGE_REF_IDS = LINEAGE_SUBTABS.flatMap((s) => s.refIds);

// ─────────── Sharing & org ─── the org sub-tabs read ORGANIZATION_USAGE and hide when the role
// cannot see it.
export const SHARING_SUBTABS: SubtabDef[] = [
  {
    key: "shares", label: "Shares & listings",
    ids: ["sf_gov_shares_and_listings", "sf_share_reader_accounts", "sf_share_inbound_databases", "sf_cost_marketplace_paid_listings", "sf_cost_listing_auto_fulfillment"],
    refIds: [],
  },
  {
    key: "accounts", label: "Accounts", org: true,
    ids: ["sf_org_account_inventory", "sf_org_dormant_accounts", "sf_org_edition_fit", "sf_org_region_spread", "sf_org_login_activity_by_account", "sf_org_security_posture_by_account"],
    refIds: [],
  },
  {
    key: "spend", label: "Spend across accounts", org: true,
    ids: [
      "sf_org_spend_by_account", "sf_org_spend_by_account_and_service", "sf_org_daily_spikes_by_account",
      "sf_org_serverless_by_account", "sf_org_warehouse_spend_across_accounts", "sf_org_storage_by_account",
      "sf_org_cloud_services_billed_by_account", "sf_org_overage_and_adjustments",
    ],
    refIds: [],
  },
  {
    key: "replication", label: "Replication & transfer",
    ids: ["sf_repl_group_health", "sf_org_replication_cost", "sf_org_listing_auto_fulfillment", "sf_org_data_transfer_by_account"],
    refIds: [],
  },
];

// ─────────── Storage ───────────
export const STORAGE_SUBTABS: SubtabDef[] = [
  {
    key: "growth", label: "Growth & stages",
    ids: ["sf_storage_growth_by_database", "sf_storage_stage_bytes", "sf_storage_stale_stage_files", "sf_storage_archive_retrieval"],
    refIds: ["table_inventory_type"],
  },
  {
    key: "unused", label: "Unused & sprawl",
    ids: ["sf_storage_oldest_untouched_tables", "sf_storage_unused_tables", "sf_storage_schema_sprawl", "sf_use_unused_clones", "sf_storage_dropped_not_purged"],
    refIds: [],
  },
  {
    key: "retention", label: "Time Travel & Fail-safe",
    ids: ["sf_storage_time_travel_heavy", "sf_storage_retention_policy", "sf_storage_failsafe_on_staging", "sf_storage_clone_retained_bytes", "sf_use_table_churn", "sf_storage_churn_unread", "sf_storage_lifecycle_policy_failures"],
    refIds: [],
  },
  {
    key: "backups", label: "Backups",
    ids: ["sf_storage_backup_snapshot"],
    refIds: [],
  },
];

// ─────────── Overview ─── a roll-up: every id is a reference feed for its cards.
export const OVERVIEW_IDS = [
  "overview_spend_estimate", "overview_credits_by_service", "overview_warehouse_vs_serverless",
  "overview_daily_credits_trend",
];

// ─────────── Coverage & Gaps ─── the page reads the export's own record (/api/coverage); the audit's
// own usage is its one reference feed.
export const COVERAGE_REF_IDS = ["cost_audit_self_usage", "sf_cost_source_freshness"];

// The ids each sub-tab of an area shows, by area: used by AREA_REGISTRY below. `org` marks a
// sub-tab that reads ORGANIZATION_USAGE.
export const AREA_REGISTRY: Record<string, AreaDef> = {
  overview: { label: "Overview", scope: MONEY_SCOPE, subtabs: [], refIds: OVERVIEW_IDS },
  actions: { label: "Actions", scope: "Flagged checks as fixes · possible waste at your effective $ per credit", subtabs: [] },
  cost: { label: "Cost", scope: MONEY_SCOPE, subtabs: COST_SUBTABS },
  waste: { label: "Waste & savings", scope: "Possible waste, priced where a source supports it", subtabs: [
    { key: "priced", label: "Priced", ids: [], refIds: [] },
    { key: "unpriced", label: "Flagged, not priced", ids: [], refIds: [] },
    { key: "method", label: "How it's counted", ids: [], refIds: [] },
  ] },
  warehouses: { label: "Warehouses", scope: MONEY_SCOPE, subtabs: WAREHOUSE_SUBTABS },
  serverless: { label: "Serverless features", scope: MONEY_SCOPE, subtabs: SERVERLESS_SUBTABS },
  queries: { label: "Queries", scope: MONEY_SCOPE, subtabs: QUERY_SUBTABS },
  tasks: { label: "Tasks & pipelines", scope: MONEY_SCOPE, subtabs: TASK_SUBTABS },
  loading: { label: "Data loading", scope: MONEY_SCOPE, subtabs: LOADING_SUBTABS },
  ai: { label: "AI & apps", scope: MONEY_SCOPE, subtabs: AI_SUBTABS },
  access: { label: "Access", scope: "Account-wide · what the audit role can see", subtabs: ACCESS_SUBTABS },
  audit: { label: "Audit", scope: "Account-wide · what the audit role can see", subtabs: AUDIT_SUBTABS },
  pii: { label: "PII & policies", scope: "Account-wide · what the audit role can see", subtabs: PII_SUBTABS },
  lineage: { label: "Lineage & usage", scope: "Account-wide · what the audit role can see", subtabs: LINEAGE_SUBTABS },
  sharing: { label: "Sharing & org", scope: "Shares of this account · organization views need an organization role", subtabs: SHARING_SUBTABS },
  storage: { label: "Storage", scope: "Storage at your $ per TB per month · what the audit role can see", subtabs: STORAGE_SUBTABS },
  findings: { label: "All findings", scope: "Every check, one list", subtabs: [] },
  coverage: { label: "Coverage & Gaps", scope: "What this audit does and doesn't cover", subtabs: [
    { key: "sources", label: "Data sources", ids: [], refIds: COVERAGE_REF_IDS },
    { key: "couldnt", label: "Not assessed", ids: [], refIds: [] },
    { key: "limits", label: "Known limitations", ids: [], refIds: [] },
  ] },
};
export const AREA_ORDER = [
  "overview", "actions", "cost", "waste", "warehouses", "serverless", "queries", "tasks", "loading", "ai",
  "access", "pii", "lineage", "audit", "sharing", "storage", "findings", "coverage",
];

// The one money column cost_dollarized_by_service_day carries.
export const COST_MONEY_COL = "net_list_cost";
export const EST_SPEND_CAVEAT = "credits × your effective $ per credit";

// ─────────── countsForIds -- ONE tally function every badge reads (top-bar area badges, SubTabs
// count chips), so the two can never disagree. `ids` is a sub-tab's or area's owned id list;
// `refIds` are reference feeds, not checks, and never add to the badge (the tab's footer counts
// checks only, so the two agree). An empty id list is a roll-up sub-tab
// (Waste, Coverage) that owns no checks: no badge at all. noData is true only when every owned id
// is NOT_ASSESSED/EMPTY_WINDOW/EMPTY_FILTERS/ERROR and none is OK/RANKED/INVENTORY-with-rows. ──
export function countsForIds(findings: Row[] | null | undefined, ids?: string[] | null, _refIds?: string[] | null): BadgeCounts {
  if (!ids || ids.length === 0) return { critical: 0, warn: 0, noData: false };
  const byId: Record<string, Row> = {};
  (findings || []).forEach((f) => { byId[f.query_id] = f; });
  let critical = 0, warn = 0, hasSignal = false, ran = false;
  ids.forEach((id) => {
    const row = byId[id];
    const band = row && bandOf ? bandOf(row) : "NOT_ASSESSED";
    if (band !== "NOT_ASSESSED" && band !== "ERROR") ran = true;
    if (band === "CRITICAL") { critical += 1; hasSignal = true; }
    else if (band === "WARN") { warn += 1; hasSignal = true; }
    else if (band === "OK" || band === "RANKED") { hasSignal = true; }
    else if (band === "INVENTORY" && row && row.row_count > 0) { hasSignal = true; }
  });
  return { critical, warn, noData: !hasSignal, notRun: !ran };
}

// A link or bookmark from before the Snowflake layout still lands on the right place.
export const OLD_TAB_REDIRECTS: Record<string, string> = {
  query: "queries", domains: "findings", compute: "warehouses", jobs: "tasks", mlai: "ai",
  governance: "access",
};
export const OLD_SUBTAB_REDIRECTS: Record<string, string> = {
  warehouses: "idle", config: "idle", product: "service", allocation: "chargeback", resource: "feature",
  pricing: "contract", capacity: "waiting", reliability: "failures", slow: "cost",
};

// The sub-tabs of an area to show. A sub-tab marked `org` reads ORGANIZATION_USAGE, so it is hidden
// when every check it owns did not run (the role has no organization access): the missing views are
// listed on Coverage & Gaps. Once findings load with any org check run, or while they load, it shows.
export function visibleSubtabs(areaKey: string, findings?: Row[] | null): SubtabDef[] {
  const area = AREA_REGISTRY[areaKey];
  const all = (area && area.subtabs) || [];
  if (!findings) return all;
  const byId: Record<string, Row> = {};
  findings.forEach((f) => { byId[f.query_id] = f; });
  return all.filter((s) => {
    if (!s.org) return true;
    const owned = (s.ids || []).map((id) => byId[id]).filter(Boolean);
    if (!owned.length) return false;
    return owned.some((f) => { const b = bandOf ? bandOf(f) : "OK"; return b !== "NOT_ASSESSED" && b !== "ERROR"; });
  });
}

// ─────────── query_id -> {tab, subtab} -- built once from AREA_REGISTRY, so a next:-chip or an
// Overview "top finding" click lands on the SAME tab a person would find it on by browsing. An id
// absent here falls back to the All findings tab. ───────────
export function buildQueryHome() {
  const home: Record<string, QueryHome> = {};
  const add = (tab: string, subtab: string | null, ids?: string[]) => { (ids || []).forEach((id) => { if (id && !(id in home)) home[id] = { tab, subtab }; }); };
  AREA_ORDER.forEach((tab) => {
    const area = AREA_REGISTRY[tab];
    if (tab === "overview") { add("overview", null, area.refIds); return; }
    (area.subtabs || []).forEach((s) => add(tab, s.key, [...(s.ids || []), ...(s.refIds || [])]));
  });
  return home;
}
export const QUERY_HOME = buildQueryHome();

export function homeForQuery(row: Row): QueryHome {
  return QUERY_HOME[row.query_id] || { tab: "findings", subtab: null };
}
