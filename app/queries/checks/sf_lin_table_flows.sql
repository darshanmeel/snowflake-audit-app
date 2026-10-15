-- query_id: sf_lin_table_flows
-- title: Tables that feed the most other tables, from what queries actually wrote
-- domain: governance_access   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (GOVERNANCE_VIEWER); Enterprise edition
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_fan_out (default 5) tables fed: a table that feeds this many other tables reads WARN;
--   :crit_fan_out (default 15) tables fed: a table that feeds this many other tables reads CRITICAL;
--   :warn_fan_in (default 10) source tables: a table built from this many source tables reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table that took part in a copy in the window: a query wrote to one table
--   from columns of another. feeds_tables counts the tables it is a source for (its fan-out), fed_by_tables
--   the tables it is built from (its fan-in), columns_out and columns_in the distinct columns that moved,
--   and writers the distinct users behind them. It is the pipeline view that OBJECT_DEPENDENCIES cannot
--   give: views declare a dependency, but a table loaded by a task or a dbt model only shows up here.
--   Sensitive columns have their own check (sf_secx_sensitive_lineage_untagged).
-- healthy: status = OK when a table feeds a few tables and is built from a few.
-- investigate_if: WARN when feeds_tables >= warn_fan_out or fed_by_tables >= warn_fan_in; CRITICAL when
--   feeds_tables >= crit_fan_out.
-- actions: 1) treat the top rows as shared foundations: name an owner and announce schema changes before
--   they land (free); 2) for a table built from very many sources, look for a job that does too much and
--   split it (config); 3) put a contract or tests on the tables many others copy from (spend).
-- next: sf_lin_blast_radius
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- caveats: ACCESS_HISTORY needs Enterprise edition, lags up to 3 hours and keeps 365 days. Only column
--   lineage of writes is read; a copy through a stage or an external tool is not a flow here. Queries
--   that write a table from itself are left out. Query text is never read.
WITH edges AS (
  SELECT DISTINCT ah.query_id, ah.user_name,
         UPPER(obj.value:objectName::VARCHAR) AS target_fqn,
         UPPER(col.value:columnName::VARCHAR) AS target_column,
         UPPER(src.value:objectName::VARCHAR) AS source_fqn,
         UPPER(src.value:columnName::VARCHAR) AS source_column,
         ah.query_start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(INPUT => ah.objects_modified, OUTER => TRUE) obj,
       LATERAL FLATTEN(INPUT => obj.value:columns, OUTER => TRUE) col,
       LATERAL FLATTEN(INPUT => col.value:baseSources, OUTER => TRUE) src
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND ah.query_start_time < __AS_OF_DATE__
),
paths AS (
  SELECT * FROM edges
  WHERE source_fqn IS NOT NULL AND target_fqn IS NOT NULL AND source_column IS NOT NULL
    AND source_fqn <> target_fqn
),
outgoing AS (
  SELECT source_fqn AS table_fqn, COUNT(DISTINCT target_fqn) AS feeds_tables,
         COUNT(DISTINCT source_column) AS columns_out, COUNT(DISTINCT user_name) AS writers_out,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT target_fqn), 0, 5), ', ') AS sample_targets,
         MAX(query_start_time) AS last_copied_from
  FROM paths GROUP BY source_fqn
),
incoming AS (
  SELECT target_fqn AS table_fqn, COUNT(DISTINCT source_fqn) AS fed_by_tables,
         COUNT(DISTINCT target_column) AS columns_in, COUNT(DISTINCT user_name) AS writers_in,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT source_fqn), 0, 5), ', ') AS sample_sources,
         MAX(query_start_time) AS last_written
  FROM paths GROUP BY target_fqn
),
t AS (
  SELECT COALESCE(o.table_fqn, i.table_fqn) AS table_fqn,
         COALESCE(o.feeds_tables, 0) AS feeds_tables, COALESCE(i.fed_by_tables, 0) AS fed_by_tables,
         COALESCE(o.columns_out, 0) AS columns_out, COALESCE(i.columns_in, 0) AS columns_in,
         GREATEST(COALESCE(o.writers_out, 0), COALESCE(i.writers_in, 0)) AS writers,
         o.sample_targets, i.sample_sources, o.last_copied_from, i.last_written
  FROM outgoing o
  FULL OUTER JOIN incoming i ON i.table_fqn = o.table_fqn
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, table_fqn, feeds_tables, fed_by_tables,
       columns_out, columns_in, writers, sample_targets, sample_sources, last_copied_from, last_written,
       feeds_tables || ' tables built from it, built from ' || fed_by_tables || ' tables' AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN feeds_tables >= :crit_fan_out THEN 'CRITICAL'
         WHEN feeds_tables >= :warn_fan_out OR fed_by_tables >= :warn_fan_in THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY feeds_tables DESC, fed_by_tables DESC, table_fqn
