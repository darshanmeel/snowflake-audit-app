-- query_id: query_costly_statements_grouped
-- title: Heaviest SQL statement shapes, rolled up by fingerprint
-- domain: performance   tier: standard
-- entity: statement shapes = statement_fingerprint
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_total_hours (default 1) cumulative execution hours for a single shape that flags WARN;
--   :crit_total_hours (default 5) same for CRITICAL; :top_n (default 500) row cap
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one distinct statement SHAPE (statement_fingerprint) run one or more times, OR
--   one redacted statement that could not be grouped into a shape at all (is_redacted = true, keyed by
--   its own statement_id). total_exec_ms (cumulative execution time across every run) is the column
--   that matters - a cheap statement run 10,000 times can outweigh one heavy query. runs and
--   avg_exec_ms tell you whether to fix the shape or its frequency. Only the top_n shapes by total
--   execution time are kept, so "N of 500" means N of the 500 kept, not of every shape.
-- healthy: total_exec_ms below :warn_total_hours hours over the window (field heuristic - tune for your
--   account).
-- investigate_if: total_exec_ms at/above :warn_total_hours (WARN) or :crit_total_hours (CRITICAL)
--   cumulative hours - a hot repeated shape (field heuristic). High runs + low avg_exec_ms means fix
--   the caller (frequency / caching); high avg_exec_ms means tune the statement. A CRITICAL is_redacted
--   row is one statement, not a repeated shape - runs is always 1 for it.
-- actions: 1) cache or materialize the result when the same shape reruns with the same inputs, and
--   dedupe callers (free); 2) batch / schedule the repeated shape, or move it to a right-sized
--   warehouse (config); 3) scale only the genuinely heavy shapes, after tuning (spend).
-- next: none
-- caveats: Snowflake version: statement_fingerprint = query_parameterized_hash (Snowflake's own
--   literal- blind hash); a query with no hash is kept as its own row (is_redacted). Successful queries
--   with execution_time > 0.
WITH fp AS (
  SELECT COALESCE(query_parameterized_hash, 'statement:' || query_id) AS statement_fingerprint,
         query_parameterized_hash IS NULL AS is_redacted,
         query_type, warehouse_id, start_time, execution_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND execution_status = 'SUCCESS'
    AND execution_time > 0
),
agg AS (
  SELECT statement_fingerprint,
         BOOLOR_AGG(is_redacted) AS is_redacted,
         MAX(query_type) AS statement_type,
         COUNT(*) AS runs,
         SUM(execution_time) AS total_exec_ms,
         CAST(AVG(execution_time) AS BIGINT) AS avg_exec_ms,
         MAX(execution_time) AS max_exec_ms,
         COUNT(DISTINCT warehouse_id) AS distinct_warehouses,
         MIN(start_time) AS first_seen,
         MAX(start_time) AS last_seen
  FROM fp
  GROUP BY statement_fingerprint
  QUALIFY ROW_NUMBER() OVER (ORDER BY SUM(execution_time) DESC, statement_fingerprint) <= :top_n
)
SELECT :period_days AS window_days, statement_fingerprint, is_redacted, statement_type,
       runs, total_exec_ms, avg_exec_ms, max_exec_ms, distinct_warehouses, first_seen, last_seen,
       CASE
         WHEN total_exec_ms >= :crit_total_hours * 3600 * 1000 THEN 'CRITICAL'
         WHEN total_exec_ms >= :warn_total_hours * 3600 * 1000 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM agg
ORDER BY total_exec_ms DESC
