-- query_id: sf_storage_schema_sprawl
-- title: Schemas full of empty or unread tables
-- domain: storage   tier: standard
-- entity: schemas = schema_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLES, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA,
--   SNOWFLAKE.ACCOUNT_USAGE.DATABASES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :idle_days (default 90) idle days: value this check uses; :min_tables (default 20) tables:
--   least a row needs before it can flag; :warn_unread_pct (default 50) unread pct: at or above this
--   the row reads WARN; :crit_unread_pct (default 80) unread pct: at or above this the row reads
--   CRITICAL; :crit_usd (default 100) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a live schema. base_tables counts its tables; empty_tables have no rows;
--   unread_tables were created more than idle_days ago and not read since (ACCESS_HISTORY). unread_pct
--   = unread tables / base tables; est_storage_usd_month prices the unread tables' bytes.
--   schema_is_transient / database_is_transient show whether new tables there skip Fail-safe.
-- healthy: status = OK when the schema has fewer than min_tables tables, or under warn_unread_pct of
--   them are unread.
-- investigate_if: WARN when warn_unread_pct or more of at least min_tables tables are unread; CRITICAL
--   at crit_unread_pct, or when the unread tables cost crit_usd a month.
-- actions: 1) list unread tables with sf_storage_unused_tables and ask the schema owner (free); 2) drop
--   abandoned sandboxes/dev schemas, or move scratch work to a TRANSIENT schema with a cleanup job
--   (config); 3) have pipelines drop the tables they create for one run (engineering).
-- next: none
-- caveats: ACCESS_HISTORY needs Enterprise Edition and keeps 365 days (NOT_ASSESSED with no rows).
--   Views and external tables are not counted. Shares and replication reads are not seen.
WITH __INCLUDE_sf_storage_live_tables__,
reads AS (
  SELECT DISTINCT f.value:objectId::NUMBER AS table_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.base_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:idle_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
seen AS (
  SELECT COUNT(*) AS objects_read FROM reads
),
tb AS (
  SELECT lt.*, r.table_id IS NULL
               AND COALESCE(lt.created < DATEADD(day, -:idle_days, __AS_OF_DATE__), TRUE) AS unread
  FROM sf_storage_live_tables lt
  LEFT JOIN reads r ON r.table_id = lt.table_id
  WHERE lt.table_type = 'BASE TABLE'
),
g AS (
  SELECT schema_id, MAX(database_name) AS database_name, MAX(database_id) AS database_id,
         MAX(schema_name) AS schema_name, MAX(database_name || '.' || schema_name) AS schema_fqn,
         COUNT(*) AS base_tables,
         COUNT_IF(COALESCE(row_count, 0) = 0 AND active_bytes = 0) AS empty_tables,
         COUNT_IF(unread) AS unread_tables,
         COUNT_IF(is_transient) AS transient_tables,
         SUM(total_bytes) AS total_bytes,
         SUM(IFF(unread, active_bytes + time_travel_bytes + failsafe_bytes, 0)) AS unread_bytes,
         MAX(last_altered) AS last_altered
  FROM tb
  GROUP BY schema_id
),
t AS (
  SELECT g.*, sc.schema_owner, sc.is_transient = 'YES' AS schema_is_transient,
         db.is_transient = 'YES' AS database_is_transient,
         100 * unread_tables / NULLIF(base_tables, 0) AS unread_pct,
         unread_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS usd
  FROM g
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA sc ON sc.schema_id = g.schema_id AND sc.deleted IS NULL
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.DATABASES db ON db.database_id = g.database_id AND db.deleted IS NULL
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       schema_fqn, schema_id, database_name, database_id, schema_name, schema_owner,
       schema_is_transient, database_is_transient,
       base_tables, empty_tables, unread_tables, transient_tables, ROUND(unread_pct, 1) AS unread_pct,
       total_bytes, unread_bytes, last_altered, :idle_days AS idle_days,
       usd AS est_storage_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       unread_tables || ' of ' || base_tables || ' tables unread in ' || :idle_days || ' days, '
         || empty_tables || ' empty' AS waste_reason,
       CASE WHEN s.objects_read = 0 THEN 'no_access_history' END AS not_assessed_reason,
       CASE
         WHEN s.objects_read = 0 THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN base_tables < :min_tables THEN 'OK'
         WHEN unread_pct >= :crit_unread_pct THEN 'CRITICAL'
         WHEN unread_pct >= :warn_unread_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t CROSS JOIN seen s
ORDER BY unread_bytes DESC, unread_tables DESC
