-- One row per query in ACCESS_HISTORY's window with how it ran, from QUERY_HISTORY: shape (parameterized
-- hash), type, warehouse, seconds, partitions, bytes scanned and spilled. Needs sf_use_ah. Never query text.
sf_use_query_metrics AS (
  SELECT q.query_id, MAX(q.query_parameterized_hash) AS shape_hash, MAX(UPPER(q.query_type)) AS query_type,
         MAX(UPPER(q.warehouse_name)) AS warehouse_name,
         MAX(q.total_elapsed_time) / 1000 AS elapsed_s,
         MAX(q.partitions_scanned) AS partitions_scanned, MAX(q.partitions_total) AS partitions_total,
         MAX(q.bytes_scanned) AS bytes_scanned,
         MAX(COALESCE(q.bytes_spilled_to_local_storage, 0) + COALESCE(q.bytes_spilled_to_remote_storage, 0)) AS bytes_spilled,
         MAX(COALESCE(q.bytes_spilled_to_remote_storage, 0)) AS bytes_spilled_remote
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  WHERE q.start_time >= DATEADD(day, -(:period_days + 1), __AS_OF_DATE__)
    AND q.query_id IN (SELECT query_id FROM sf_use_ah)
  GROUP BY q.query_id
)
