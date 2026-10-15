-- query_id: sf_qry_daily_by_warehouse
-- reads: INFORMATION_SCHEMA.QUERY_HISTORY (table function)
-- fallback_note: last 7 days at most, only the queries this role can see; no spill or cache figures
-- Same columns as checks/sf_qry_daily_by_warehouse.sql. The warehouse name stands in for its id;
-- spill and cache columns are NULL (the table function does not return them).
WITH -- The INFORMATION_SCHEMA fallback's query feed, shared by the fallback checks.
-- QUERY_HISTORY (the table function) keeps 7 days, returns at most 10,000 rows a call and shows only
-- the queries this role can see (its own, and those on warehouses it has MONITOR or OPERATE on).
-- So: 28 calls of 6 hours each (up to 280,000 queries), the oldest starting 5 minutes inside the
-- 7-day limit, one row per query id. It has no warehouse id: the name stands in for it.
is_query_history AS (
  SELECT *, warehouse_name AS warehouse_id
  FROM (
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -6, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => CURRENT_TIMESTAMP(), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -12, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -6, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -18, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -12, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -24, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -18, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -30, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -24, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -36, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -30, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -42, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -36, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -48, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -42, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -54, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -48, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -60, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -54, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -66, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -60, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -72, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -66, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -78, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -72, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -84, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -78, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -90, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -84, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -96, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -90, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -102, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -96, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -108, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -102, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -114, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -108, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -120, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -114, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -126, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -120, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -132, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -126, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -138, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -132, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -144, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -138, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -150, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -144, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -156, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -150, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -162, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -156, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(minute, -10075, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -162, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
  )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY end_time DESC) = 1
),
q AS (
  SELECT warehouse_id, warehouse_name, warehouse_size, start_time,
         DATE(start_time) AS usage_date,
         UPPER(execution_status) IN ('FAIL', 'INCIDENT', 'FAILED_WITH_ERROR', 'FAILED_WITH_INCIDENT') AS is_failed,
         COALESCE(total_elapsed_time, 0) / 1000 AS elapsed_s,
         COALESCE(queued_overload_time, 0) / 1000 AS q_over_s,
         COALESCE(queued_provisioning_time, 0) / 1000 AS q_prov_s,
         COALESCE(bytes_scanned, 0) AS scanned
  FROM is_query_history
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_name IS NOT NULL
),
wh AS (
  SELECT warehouse_id, MAX_BY(warehouse_name, start_time) AS warehouse_name, COUNT(*) AS wh_queries
  FROM q GROUP BY warehouse_id
),
-- only the days the table function can reach, so days before it never read as quiet
days AS (
  SELECT DATEADD(day, -ROW_NUMBER() OVER (ORDER BY SEQ4()), __AS_OF_DATE__) AS usage_date
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
  QUALIFY usage_date >= GREATEST(DATEADD(day, -:period_days, __AS_OF_DATE__), DATEADD(day, -7, CURRENT_DATE()))
),
d AS (
  SELECT warehouse_id, usage_date,
         MAX_BY(warehouse_size, IFF(warehouse_size IS NULL, NULL, start_time)) AS warehouse_size,
         COUNT(*) AS queries,
         COUNT_IF(is_failed) AS failed_queries,
         SUM(elapsed_s) AS total_elapsed_s,
         AVG(elapsed_s) AS avg_elapsed_s,
         APPROX_PERCENTILE(elapsed_s, 0.95) AS p95_elapsed_s,
         SUM(q_over_s) AS queued_overload_s,
         SUM(q_prov_s) AS queued_provisioning_s,
         SUM(scanned) AS bytes_scanned
  FROM q
  GROUP BY warehouse_id, usage_date
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, g.usage_date,
       w.warehouse_id, w.warehouse_name, d.warehouse_size,
       COALESCE(d.queries, 0) AS queries,
       COALESCE(d.failed_queries, 0) AS failed_queries,
       COALESCE(d.total_elapsed_s, 0) AS total_elapsed_s,
       d.avg_elapsed_s, d.p95_elapsed_s,
       COALESCE(d.queued_overload_s, 0) AS queued_overload_s,
       COALESCE(d.queued_provisioning_s, 0) AS queued_provisioning_s,
       CAST(NULL AS NUMBER) AS bytes_spilled_local,
       CAST(NULL AS NUMBER) AS bytes_spilled_remote,
       CAST(NULL AS NUMBER) AS queries_spilling_remote,
       CAST(NULL AS DOUBLE) AS cache_scan_pct,
       COALESCE(d.bytes_scanned, 0) AS bytes_scanned,
       'OK' AS status,
       CAST(NULL AS VARCHAR) AS not_assessed_reason
FROM wh w
CROSS JOIN days g
LEFT JOIN d ON d.warehouse_id = w.warehouse_id AND d.usage_date = g.usage_date
ORDER BY w.wh_queries DESC, w.warehouse_id, g.usage_date
