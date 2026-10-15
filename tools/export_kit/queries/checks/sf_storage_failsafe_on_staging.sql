-- query_id: sf_storage_failsafe_on_staging
-- title: Permanent staging-like tables paying for Fail-safe
-- domain: storage   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :min_failsafe_gb (default 5) failsafe gb: least a row needs before it can flag; :churn_ratio
--   (default 1.0) churn ratio: value this check uses; :warn_usd (default 10) usd: at or above this the
--   row reads WARN; :crit_usd (default 100) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a permanent table whose Fail-safe bytes are large and that looks rebuildable:
--   its name looks like staging/landing/temp work (looks_staging) or it holds at least churn_ratio x
--   its active bytes in Fail-safe (rewritten often). Fail-safe keeps 7 days of every overwritten
--   version and cannot be turned off on a permanent table; a TRANSIENT table has none.
--   est_saving_usd_month = the Fail-safe bytes a transient table would not keep. Time Travel beyond 1
--   day is counted in sf_storage_time_travel_heavy, not here.
-- healthy: status = OK when the Fail-safe on the table costs less than warn_usd a month.
-- investigate_if: WARN when the saving is warn_usd a month or more; CRITICAL when it is crit_usd or
--   more and the name looks like staging.
-- actions: 1) confirm the table can be rebuilt from its source, so disaster recovery is not needed
--   (free); 2) recreate it TRANSIENT (CREATE TRANSIENT TABLE ... in the loader's DDL, or put staging in
--   a TRANSIENT schema/database so new tables inherit it) with DATA_RETENTION_TIME_IN_DAYS 0 or 1
--   (config); 3) truncate or drop staging tables after each load (engineering).
-- next: none
-- caveats: name matching is a heuristic (STG, STAGE, STAGING, LANDING, TMP, TEMP, SCRATCH, WORK, LOAD,
--   RAW_ as whole words); the churn signal is a point-in-time ratio. Existing Fail-safe bytes still age
--   out over 7 days after the change. TABLE_STORAGE_METRICS lags up to 90 minutes.
WITH -- Live tables with their current storage split: TABLE_STORAGE_METRICS holds the bytes, TABLES the
-- settings. The YES/NO text flags are turned into booleans so every storage check reads them alike.
sf_storage_live_tables AS (
  SELECT m.id AS table_id, m.table_catalog AS database_name, m.table_catalog_id AS database_id,
         m.table_schema AS schema_name, m.table_schema_id AS schema_id, m.table_name,
         m.table_catalog || '.' || m.table_schema || '.' || m.table_name AS table_fqn,
         m.clone_group_id,
         COALESCE(m.active_bytes, 0) AS active_bytes,
         COALESCE(m.time_travel_bytes, 0) AS time_travel_bytes,
         COALESCE(m.failsafe_bytes, 0) AS failsafe_bytes,
         COALESCE(m.retained_for_clone_bytes, 0) AS retained_for_clone_bytes,
         COALESCE(m.active_bytes, 0) + COALESCE(m.time_travel_bytes, 0) + COALESCE(m.failsafe_bytes, 0)
           + COALESCE(m.retained_for_clone_bytes, 0) AS total_bytes,
         -- no TABLES row would make this NULL and drop the table from NOT is_transient filters
         COALESCE(m.is_transient = 'YES' OR t.is_transient = 'YES', m.is_transient = 'YES', FALSE) AS is_transient,
         COALESCE(t.table_type, 'BASE TABLE') AS table_type,
         t.retention_time, t.clustering_key,
         COALESCE(t.auto_clustering_on = 'YES', FALSE) AS auto_clustering_on,
         COALESCE(t.is_iceberg = 'YES', FALSE) AS is_iceberg,
         COALESCE(t.is_dynamic = 'YES', FALSE) AS is_dynamic,
         COALESCE(t.is_hybrid = 'YES', FALSE) AS is_hybrid,
         t.row_count, t.bytes AS table_bytes, t.table_owner, t.created, t.last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS m
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t ON t.table_id = m.id AND t.deleted IS NULL
  -- Fail-safe rows have NULL names (and can carry deleted = FALSE): they are not live tables.
  WHERE NOT COALESCE(m.deleted, FALSE) AND m.table_dropped IS NULL
    AND m.schema_dropped IS NULL AND m.catalog_dropped IS NULL
    AND m.table_name IS NOT NULL AND m.table_entered_failsafe IS NULL
),
t AS (
  SELECT lt.*,
         REGEXP_LIKE(UPPER(schema_name || '.' || table_name),
                     '.*(^|[._])(STG|STAGE|STAGING|LANDING|TMP|TEMP|SCRATCH|WORK|WRK|LOAD|RAW)([._0-9]|$).*')
           AS looks_staging,
         failsafe_bytes / NULLIF(active_bytes, 0) AS failsafe_to_active_ratio,
         failsafe_bytes / POWER(1024, 3) AS failsafe_gb,
         -- Fail-safe only: the Time Travel cut belongs to sf_storage_time_travel_heavy
         failsafe_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS saving_usd
  FROM sf_storage_live_tables lt
  WHERE NOT is_transient AND table_type = 'BASE TABLE' AND NOT is_iceberg AND NOT is_hybrid
    AND failsafe_bytes >= :min_failsafe_gb * POWER(1024, 3)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_id, database_name, schema_name, table_name, table_owner,
       retention_time AS retention_days, row_count, created, last_altered,
       active_bytes, time_travel_bytes, failsafe_bytes, failsafe_gb,
       looks_staging, ROUND(failsafe_to_active_ratio, 2) AS failsafe_to_active_ratio,
       failsafe_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS est_storage_usd_month,
       saving_usd AS est_saving_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(failsafe_gb, 1) || ' GB in Fail-safe on a permanent '
         || IFF(looks_staging, 'staging-like', 'often rewritten') || ' table' AS waste_reason,
       CASE WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN saving_usd >= :crit_usd AND looks_staging THEN 'CRITICAL'
         WHEN saving_usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
WHERE looks_staging OR COALESCE(failsafe_to_active_ratio, 99) >= :churn_ratio
ORDER BY failsafe_bytes DESC
