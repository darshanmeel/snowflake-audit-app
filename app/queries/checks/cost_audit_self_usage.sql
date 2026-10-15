-- query_id: cost_audit_self_usage
-- title: Cost of running this audit itself, by warehouse
-- domain: cost   tier: lite
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one warehouse this export's own statements ran on in :period_days.
--   matched_statement_count/matched_duration_secs are this export's own statements and their
--   runtime; warehouse_all_duration_secs is every statement's runtime on that warehouse in the same
--   window, so matched_share_pct shows how much of the warehouse's traffic was this audit.
--   est_audit_usd_list apportions the warehouse's whole list-price spend by that share - a runtime-
--   share proxy, not a per-statement credit reading (Snowflake exposes no such column).
-- healthy: n/a - coverage/inventory, not a WARN/CRITICAL finding.
-- investigate_if: n/a - coverage/inventory. A large est_audit_usd_list on a warehouse used only for
--   this audit is worth knowing about, but this query does not band it.
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: this audit's own statements, found by the query tag (settings query_source) the
--   export sets.
WITH __INCLUDE_sf_cs_billed_ratio__,
mine AS (
  SELECT query_id, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name,
         total_elapsed_time / 1000 AS secs, start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_tag = __QUERY_SOURCE__ AND warehouse_id IS NOT NULL
),
wh_all AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, SUM(total_elapsed_time) / 1000 AS secs
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND TO_VARCHAR(warehouse_id) IN (SELECT warehouse_id FROM mine)
  GROUP BY 1
),
wh_cost AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, SUM((credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1))) * __CREDIT_PRICE__ AS usd
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
attr AS (
  SELECT a.query_id, a.credits_attributed_compute AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY a
  WHERE a.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND a.start_time < __AS_OF_DATE__
    AND a.query_tag = __QUERY_SOURCE__
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, m.warehouse_id,
       MAX(m.warehouse_name) AS warehouse_name, 'crosshire-audit' AS matched_client_application,
       COUNT(*) AS matched_statement_count, SUM(m.secs) AS matched_duration_secs,
       MAX(w.secs) AS warehouse_all_duration_secs,
       100 * SUM(m.secs) / NULLIF(MAX(w.secs), 0) AS matched_share_pct,
       MAX(c.usd) AS est_usd_list,
       SUM(a.credits) * __CREDIT_PRICE__ AS est_audit_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       MIN(m.start_time) AS first_query_time, MAX(m.start_time) AS last_query_time
FROM mine m
LEFT JOIN wh_all w ON w.warehouse_id = m.warehouse_id
LEFT JOIN wh_cost c ON c.warehouse_id = m.warehouse_id
LEFT JOIN attr a ON a.query_id = m.query_id
GROUP BY m.warehouse_id
