-- query_id: sf_query_large_result_sets
-- title: Statements returning very large results to clients
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_rows (default 1000000) rows: least a row needs before it can flag; :min_result_gb
--   (default 1) result gb: least a row needs before it can flag; :warn_result_gb (default 50) result
--   gb: at or above this the row reads WARN; :crit_result_gb (default 1000) result gb: at or above this
--   the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement shape (query_parameterized_hash) and client that returned at least
--   min_rows rows or min_result_gb of result in a run. result_gb = bytes written to the result set,
--   which a client then downloads; rows_out_per_gb_scanned >> normal can also point to an exploding
--   join.
-- healthy: status = OK when large results total under warn_result_gb
-- investigate_if: WARN when result_gb >= warn_result_gb; CRITICAL when result_gb >= crit_result_gb
-- actions: 1) aggregate or filter in Snowflake instead of pulling raw rows into the BI tool or notebook
--   (free); 2) for bulk extracts use COPY INTO @stage or data sharing, not a SELECT through the driver
--   (free); 3) check joins for missing keys where rows_produced far exceeds what the inputs hold (free)
-- next: none
-- caveats: SELECT only; CTAS and INSERT results are not downloads. Client names come from SESSIONS and
--   are empty for sessions opened more than 30 days before the window or older than its retention.
WITH qh AS (
  SELECT query_id, query_parameterized_hash, session_id, TO_VARCHAR(warehouse_id) AS warehouse_id,
         warehouse_name, user_name, start_time, rows_produced, bytes_written_to_result, bytes_scanned,
         execution_time, total_elapsed_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type = 'SELECT' AND execution_status = 'SUCCESS'
    AND (rows_produced >= :min_rows OR bytes_written_to_result >= :min_result_gb * POWER(1024, 3))
),
s AS (
  SELECT session_id, client_application_id,
         TO_VARCHAR(GET(TRY_PARSE_JSON(client_environment), 'APPLICATION')) AS client_app_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  -- pooled connections live for weeks: look back a month before the window for their session
  WHERE created_on >= DATEADD(day, -:period_days - 30, __AS_OF_DATE__)
),
g AS (
  SELECT q.query_parameterized_hash,
         COALESCE(NULLIF(s.client_app_name, ''), SPLIT_PART(s.client_application_id, ' ', 1), '(unknown)') AS client,
         -- one id|name pair, so the name never comes from another warehouse than the id
         MODE(q.warehouse_id || '|' || COALESCE(q.warehouse_name, '')) AS main_wh,
         MODE(q.user_name) AS main_user_name, COUNT(DISTINCT q.user_name) AS distinct_users,
         COUNT(*) AS runs, SUM(q.rows_produced) AS rows_out, MAX(q.rows_produced) AS max_rows_out,
         SUM(q.bytes_written_to_result) / POWER(1024, 3) AS result_gb,
         SUM(q.bytes_scanned) / POWER(1024, 3) AS scanned_gb,
         SUM(q.total_elapsed_time) / 3600000 AS elapsed_hours,
         MAX_BY(q.query_id, q.bytes_written_to_result) AS biggest_query_id,
         MAX(q.start_time) AS last_seen
  FROM qh q LEFT JOIN s ON s.session_id = q.session_id
  GROUP BY 1, 2
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       NULLIF(SPLIT_PART(main_wh, '|', 1), '') AS warehouse_id, NULLIF(SPLIT_PART(main_wh, '|', 2), '') AS warehouse_name,
       query_parameterized_hash, client, main_user_name, distinct_users, runs, rows_out, max_rows_out,
       result_gb, scanned_gb, rows_out / NULLIF(scanned_gb, 0) AS rows_out_per_gb_scanned, elapsed_hours,
       biggest_query_id, last_seen,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN result_gb >= :crit_result_gb THEN 'CRITICAL'
         WHEN result_gb >= :warn_result_gb THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY result_gb DESC, rows_out DESC
