-- query_id: query_costly_statements_grouped
-- shims: QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions QUERY_HISTORY
-- fallback_note: queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
WITH fp AS (
  SELECT COALESCE(query_parameterized_hash, 'statement:' || query_id) AS statement_fingerprint,
         query_parameterized_hash IS NULL AS is_redacted,
         query_type, warehouse_id, start_time, execution_time
  FROM __SHIM_QUERY_HISTORY__
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
