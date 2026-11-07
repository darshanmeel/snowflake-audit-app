-- query_id: sf_lin_copied_links
-- title: Every copy between tables in the window: which table was written from which
-- domain: governance_access   tier: standard
-- entity: lineage links = source_fqn, target_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (GOVERNANCE_VIEWER); Enterprise edition
-- params: :period_days (default 30) days of history the check looks at, counted back from the export date
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table (target_fqn) that a query wrote from another (source_fqn) in the window.
--   columns counts the target columns written, queries the writes and writers the users behind them. The
--   Lineage explorer walks these links with sf_lin_declared_links.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: sf_lin_table_flows
-- caveats: ACCESS_HISTORY needs Enterprise edition, lags up to 3 hours and keeps 365 days. Only column
--   lineage of writes is read; a copy through a stage or an external tool is not a link here. A query that
--   writes a table from itself is left out. Query text is never read. On a very large account the export
--   row cap can cut this list.
WITH edges AS (
  SELECT ah.query_id, ah.user_name, ah.query_start_time,
         UPPER(obj.value:objectName::VARCHAR) AS target_fqn,
         UPPER(col.value:columnName::VARCHAR) AS target_column,
         UPPER(src.value:objectName::VARCHAR) AS source_fqn,
         UPPER(src.value:columnName::VARCHAR) AS source_column
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(INPUT => ah.objects_modified, OUTER => TRUE) obj,
       LATERAL FLATTEN(INPUT => obj.value:columns, OUTER => TRUE) col,
       LATERAL FLATTEN(INPUT => col.value:baseSources, OUTER => TRUE) src
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND ah.query_start_time < __AS_OF_DATE__
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, source_fqn, target_fqn,
       COUNT(DISTINCT target_column) AS columns, COUNT(DISTINCT query_id) AS queries,
       COUNT(DISTINCT user_name) AS writers, MAX(query_start_time) AS last_written
FROM edges
WHERE source_fqn IS NOT NULL AND target_fqn IS NOT NULL AND source_column IS NOT NULL AND source_fqn <> target_fqn
GROUP BY source_fqn, target_fqn
ORDER BY source_fqn, target_fqn
