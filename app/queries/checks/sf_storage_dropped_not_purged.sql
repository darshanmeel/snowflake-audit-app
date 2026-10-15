-- query_id: sf_storage_dropped_not_purged
-- title: Dropped tables still billed
-- domain: storage   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.DATABASES,
--   SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :min_gb (default 1) gb: least a row needs before it can flag; :churn_instances (default 5)
--   churn instances: value this check uses; :warn_usd (default 10) usd: at or above this the row reads
--   WARN; :crit_usd (default 100) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a table name (database.schema.table) with dropped versions that still hold Time
--   Travel, Fail-safe or clone-retained bytes. dropped_instances > 1 means the same name was dropped
--   and recreated repeatedly (CREATE OR REPLACE loops): every replaced copy is kept for its retention
--   plus 7 days of Fail-safe. purge_by is when the newest dropped copy leaves Fail-safe, unless a clone
--   still holds its bytes.
--   est_saving_usd_month, on flagged rows, is what can be removed: the clone-retained bytes (drop the
--   clone), or the whole figure when the name churns (dropped churn_instances times or more), because
--   the loop keeps re-creating that bill. Time Travel and Fail-safe of a one-off drop age out by themselves.
-- healthy: status = OK when the dropped copies cost less than warn_usd a month.
-- investigate_if: WARN when they cost warn_usd a month or more, or when the name was dropped
--   churn_instances times or more; CRITICAL at crit_usd a month.
-- actions: 1) nothing frees Fail-safe early, so treat existing bytes as sunk and fix the pattern
--   (free); 2) make rebuilt tables TRANSIENT with DATA_RETENTION_TIME_IN_DAYS = 0 or 1, or put them in
--   a transient schema (config); 3) replace CREATE OR REPLACE full rebuilds with incremental loads, and
--   drop clones that pin dropped data (engineering).
-- next: none
-- caveats: id shown is the newest dropped copy. A Fail-safe row with no name reads as 'Fail-safe table (id)',
--   with its database and schema looked up by id. Rows lag up to 90 minutes. A dropped schema or database
--   also marks its tables dropped. purge_by is NULL while every copy is still in Time Travel (it is
--   table_entered_failsafe + 7 days).
WITH db AS (
  SELECT database_id, MAX(database_name) AS database_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES GROUP BY database_id
),
sch AS (
  SELECT schema_id, MAX(schema_name) AS schema_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA GROUP BY schema_id
),
n AS (
  -- Fail-safe rows can have NULL names: look the database and schema up by id, name the table by its id.
  -- No surrounding parentheses, so the entity count does not read the row as a remainder.
  SELECT tsm.*,
         COALESCE(tsm.table_catalog, db.database_name || ' (' || tsm.table_catalog_id || ')',
                  'database ' || tsm.table_catalog_id) AS db_label,
         COALESCE(tsm.table_schema, sch.schema_name || ' (' || tsm.table_schema_id || ')',
                  'schema ' || tsm.table_schema_id) AS schema_label,
         COALESCE(tsm.table_name, 'Fail-safe table (' || tsm.id || ')') AS table_label
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS tsm
  LEFT JOIN db ON db.database_id = tsm.table_catalog_id
  LEFT JOIN sch ON sch.schema_id = tsm.table_schema_id
),
m AS (
  SELECT id AS table_id, table_catalog_id AS database_id, db_label AS database_name, schema_label AS schema_name, table_label AS table_name,
         db_label || '.' || schema_label || '.' || table_label AS table_fqn,
         COALESCE(active_bytes, 0) AS active_bytes,
         COALESCE(time_travel_bytes, 0) AS time_travel_bytes,
         COALESCE(failsafe_bytes, 0) AS failsafe_bytes,
         COALESCE(retained_for_clone_bytes, 0) AS retained_for_clone_bytes,
         COALESCE(table_dropped, schema_dropped, catalog_dropped) AS dropped_at,
         table_entered_failsafe,
         is_transient
  FROM n
  -- Fail-safe rows can carry deleted = FALSE and no drop time, so a NULL name or Fail-safe entry counts too
  WHERE COALESCE(deleted, FALSE) OR table_dropped IS NOT NULL
     OR schema_dropped IS NOT NULL OR catalog_dropped IS NOT NULL
     OR table_entered_failsafe IS NOT NULL OR table_name IS NULL
),
g AS (
  SELECT table_fqn, MAX(database_id) AS database_id, MAX(database_name) AS database_name, MAX(schema_name) AS schema_name,
         MAX(table_name) AS table_name,
         -- a Fail-safe row may have no drop time; MAX_BY skips NULL keys
         COALESCE(MAX_BY(table_id, dropped_at), MAX(table_id)) AS table_id,
         COUNT(*) AS dropped_instances,
         MIN(dropped_at) AS first_dropped_at, MAX(dropped_at) AS last_dropped_at,
         MAX(DATEADD(day, 7, table_entered_failsafe)) AS purge_by,
         BOOLOR_AGG(is_transient = 'YES') AS any_transient,
         SUM(active_bytes) AS active_bytes, SUM(time_travel_bytes) AS time_travel_bytes,
         SUM(failsafe_bytes) AS failsafe_bytes, SUM(retained_for_clone_bytes) AS retained_for_clone_bytes,
         SUM(active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes) AS billed_bytes
  FROM m
  GROUP BY table_fqn
  HAVING SUM(active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes)
         >= :min_gb * POWER(1024, 3)
),
t AS (
  SELECT g.*, billed_bytes / POWER(1024, 3) AS billed_gb,
         billed_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS usd,
         -- only clone bytes can be removed early; a churn loop re-creates the whole bill every cycle
         IFF(dropped_instances >= :churn_instances, billed_bytes, retained_for_clone_bytes)
           / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS removable_usd
  FROM g
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_id, database_id, database_name, schema_name, table_name, dropped_instances,
       first_dropped_at, last_dropped_at, purge_by, any_transient,
       active_bytes, time_travel_bytes, failsafe_bytes, retained_for_clone_bytes, billed_bytes, billed_gb,
       usd AS est_storage_usd_month,
       IFF(usd >= :warn_usd OR dropped_instances >= :churn_instances, removable_usd, NULL) AS est_saving_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(billed_gb, 1) || ' GB still billed for ' || dropped_instances || ' dropped cop'
         || IFF(dropped_instances = 1, 'y', 'ies') AS waste_reason,
       CASE WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd OR dropped_instances >= :churn_instances THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY billed_bytes DESC
