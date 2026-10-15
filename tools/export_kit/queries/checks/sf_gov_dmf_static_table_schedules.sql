-- query_id: sf_gov_dmf_static_table_schedules
-- title: Data metric functions billed on tables that did not change
-- domain: governance_access   tier: standard
-- windowed: yes
-- money: est_wasted_usd_list
-- entity: tables = table_fqn
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATA_QUALITY_MONITORING_USAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (data metric functions)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_credits (default 1) DMF credits on an unchanged table at or above which the row reads WARN;
--   :crit_credits (default 20) the same that reads CRITICAL
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The docs do not give the format of SCHEDULE, so the kind
--   is read from its words (TRIGGER_ON_CHANGES, MINUTE, CRON).
-- read_this: one row = one table whose data metric functions (DMFs) Snowflake ran and billed in the window.
--   rows_changed adds the rows added, removed and updated in TABLE_DML_HISTORY over the same days (0 when the
--   table has no DML row: the table is kept, never dropped). unchanged is true when rows_changed is 0 and the
--   table was not altered in the window. schedule_kinds lists how its DMFs are scheduled (on_change,
--   interval, cron); shortest_interval_min is the shortest interval in minutes. dmf_credits is the DMF
--   credits on the table; est_wasted_usd_list prices them at your $ per credit when the table did not
--   change. It is part of the DMF spend on sf_acct_observability_cost, never added to it.
-- healthy: status = OK when the table changed in the window, or its DMFs cost under warn_credits.
-- investigate_if: WARN when an unchanged table's DMFs cost warn_credits or more; CRITICAL at crit_credits.
-- actions: 1) set the table's DATA_METRIC_SCHEDULE to 'TRIGGER_ON_CHANGES' so DMFs run only after DML
--   (config); 2) for a table loaded on a known schedule, use a cron right after the load or a longer
--   interval (config); 3) drop the DMFs from tables nobody loads any more (free)
-- next: sf_acct_observability_cost, sf_gov_dmf_coverage
-- caveats: TABLE_DML_HISTORY lags up to 6 hours, leaves out hybrid tables and background services
--   (clustering, search optimization), and counts Snowpipe loads. A table replaced with CREATE OR REPLACE gets
--   a new id, so last_altered guards that case. DMFs on views are not judged (views have no DML). The
--   schedule text itself is not stored, only its kind and shortest interval.
WITH u AS (
  SELECT table_id, MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(table_name) AS table_name,
         SUM(credits_used) AS dmf_credits, COUNT(*) AS billed_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_QUALITY_MONITORING_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
),
dml AS (
  SELECT table_id, SUM(COALESCE(rows_added, 0) + COALESCE(rows_removed, 0) + COALESCE(rows_updated, 0)) AS rows_changed
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
),
t AS (
  SELECT table_id, table_type, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  QUALIFY ROW_NUMBER() OVER (PARTITION BY table_id ORDER BY deleted DESC NULLS FIRST) = 1
),
r AS (
  -- the kind of each table-level schedule, never its text
  SELECT UPPER(ref_database_name) AS db_key, UPPER(ref_schema_name) AS sch_key, UPPER(ref_entity_name) AS tbl_key,
         COUNT(DISTINCT metric_name) AS dmfs,
         LISTAGG(DISTINCT IFF(UPPER(schedule) LIKE '%TRIGGER_ON_CHANGES%', 'on_change',
                              IFF(UPPER(schedule) LIKE '%CRON%', 'cron',
                                  IFF(UPPER(schedule) LIKE '%MINUTE%', 'interval', 'other'))), ', ') AS schedule_kinds,
         MIN(IFF(UPPER(schedule) LIKE '%MINUTE%' AND UPPER(schedule) NOT LIKE '%CRON%',
                 TRY_TO_NUMBER(REGEXP_SUBSTR(schedule, '[0-9]+')), NULL)) AS shortest_interval_min
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_REFERENCES
  WHERE UPPER(COALESCE(level, 'TABLE')) = 'TABLE'
  GROUP BY 1, 2, 3
),
s AS (
  SELECT u.*, u.database_name || '.' || u.schema_name || '.' || u.table_name AS table_fqn,
         COALESCE(dml.rows_changed, 0) AS rows_changed, t.table_type, t.last_altered,
         r.dmfs, r.schedule_kinds, r.shortest_interval_min,
         COALESCE(dml.rows_changed, 0) = 0
           AND (t.last_altered IS NULL OR t.last_altered < DATEADD(day, -:period_days, __AS_OF_DATE__))
           AND COALESCE(t.table_type, 'BASE TABLE') <> 'VIEW' AS unchanged,
         u.dmf_credits * __CREDIT_PRICE__ AS dmf_usd
  FROM u
  LEFT JOIN dml ON dml.table_id = u.table_id
  LEFT JOIN t ON t.table_id = u.table_id
  LEFT JOIN r ON r.db_key = UPPER(u.database_name) AND r.sch_key = UPPER(u.schema_name) AND r.tbl_key = UPPER(u.table_name)
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, table_fqn, TO_VARCHAR(table_id) AS table_id,
       database_name, schema_name, table_name, dmfs, schedule_kinds, shortest_interval_min, billed_hours,
       rows_changed, last_altered, unchanged, dmf_credits, dmf_usd,
       IFF(unchanged AND dmf_credits >= :warn_credits, dmf_usd, NULL) AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(unchanged, 'no rows changed in ' || :period_days || ' days', NULL),
         IFF(unchanged AND schedule_kinds ILIKE '%interval%', 'runs every ' || shortest_interval_min || ' min', NULL),
         IFF(unchanged AND schedule_kinds ILIKE '%cron%', 'runs on a cron', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE WHEN NOT unchanged OR dmf_credits < :warn_credits THEN 'OK'
            WHEN dmf_credits >= :crit_credits THEN 'CRITICAL'
            ELSE 'WARN' END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, dmf_credits DESC, table_fqn
