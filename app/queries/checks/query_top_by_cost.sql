-- query_id: query_top_by_cost
-- title: Top queries by cost
-- domain: performance   tier: standard
-- entity: statement groups = warehouse_id, group_kind, group_id, statement_type
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_cost_usd (default 50) dollars a group must reach in the window to flag WARN;
--   :crit_cost_usd (default 200) the same for CRITICAL; :warn_share_frac (default 0.2) the group's
--   share of its warehouse's own window cost, 0-1, that flags WARN at any dollar amount;
--   :crit_share_frac (default 0.4) the same for CRITICAL; :top_n (default 5000) row cap - keep only the
--   top groups by cost
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row is one group of warehouse statements that cost about the same thing.
--   group_kind says how they were grouped: the same statement text by hash when it is readable,
--   otherwise one ad-hoc bucket, text hidden, per warehouse and user. runs and top_user say who ran
--   it and how often; est_cost_usd_list is the group's credits from QUERY_ATTRIBUTION_HISTORY (compute
--   plus query acceleration) x your price; share_of_warehouse_cost is that as a fraction of the
--   warehouse's own billed credits in the window. Only the top_n groups by cost are kept.
--   statement_shape names the group for charts: statement type plus the first 8 characters of its
--   hash, or "ad-hoc" for the hidden-text bucket.
--   from_result_cache_share close to 1 means most of the group's runs were already free (served
--   from the result cache).
-- healthy: status = OK - below :warn_cost_usd and below :warn_share_frac of its warehouse's window cost
--   (field heuristic).
-- investigate_if: status = WARN or CRITICAL - the group's est_cost_usd_list is at/above :warn_cost_usd
--   (WARN) or :crit_cost_usd (CRITICAL), or its share_of_warehouse_cost is at/above :warn_share_frac
--   (WARN) or :crit_share_frac (CRITICAL) of its warehouse's own window cost, whichever band is worse.
-- actions: 1) open the source by name first - the BI tool, task or notebook that ran it - and check
--   whether it needs to run this often (free); 2) when group_kind is "text hash" and
--   from_result_cache_share is low, look for a cache or materialization it could reuse, and whether
--   it is pruning the files it reads (config); 3) schedule it less often, or move it off a shared
--   warehouse onto one sized for it (spend).
-- next: none
-- caveats: Snowflake version: groups by query_parameterized_hash (no hash: one ad-hoc bucket per
--   warehouse and user); cost is exact per-query credits from QUERY_ATTRIBUTION_HISTORY, share is of
--   the warehouse's credits_used. Attribution leaves out idle time and queries under about 100 ms, is
--   empty on adaptive warehouses and lags up to 8 hours, so the groups add up to less than the bill.
--   spilled_bytes is local + remote; the result-cache share is a heuristic (SUCCESS SELECT that
--   scanned nothing).
WITH __INCLUDE_sf_cs_billed_ratio__,
stmts AS (
  SELECT q.query_id, TO_VARCHAR(q.warehouse_id) AS warehouse_id, q.query_type AS statement_type,
         q.user_name, q.start_time, q.query_parameterized_hash,
         COALESCE(q.execution_time, 0) AS execution_ms,
         COALESCE(q.bytes_scanned, 0) AS read_bytes,
         COALESCE(q.bytes_spilled_to_local_storage, 0) + COALESCE(q.bytes_spilled_to_remote_storage, 0) AS spilled_bytes,
         -- no result-cache flag in ACCOUNT_USAGE: a successful SELECT that touched no partitions is the proxy
         IFF(q.query_type = 'SELECT' AND q.execution_status = 'SUCCESS'
             AND COALESCE(q.bytes_scanned, 0) = 0 AND COALESCE(q.partitions_total, 0) = 0, 1, 0) AS cached
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
    AND q.warehouse_id IS NOT NULL
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY query_id
),
wh_total AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, SUM((credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1))) AS warehouse_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
origin AS (
  SELECT s.*, COALESCE(a.credits, 0) AS credits,
         IFF(s.query_parameterized_hash IS NOT NULL, 'text hash', 'ad-hoc, text hidden') AS group_kind,
         COALESCE(s.query_parameterized_hash, s.user_name) AS group_id
  FROM stmts s
  LEFT JOIN attr a ON a.query_id = s.query_id
),
agg AS (
  SELECT warehouse_id, group_kind, group_id, statement_type,
         COUNT(*) AS runs,
         COUNT(DISTINCT COALESCE(user_name, '__no_identity__')) AS distinct_users,
         SUM(credits) AS credits,
         SUM(execution_ms) AS total_exec_ms,
         CAST(AVG(execution_ms) AS BIGINT) AS avg_exec_ms,
         MAX(execution_ms) AS max_exec_ms,
         SUM(read_bytes) AS read_bytes,
         SUM(spilled_bytes) AS spilled_bytes,
         ROUND(SUM(cached) / COUNT(*), 3) AS from_result_cache_share,
         MIN(start_time) AS first_seen,
         MAX(start_time) AS last_seen,
         MODE(user_name) AS top_user,
         -- the priciest run stands for the group
         MAX_BY(query_id, credits) AS sample_statement_id
  FROM origin
  GROUP BY warehouse_id, group_kind, group_id, statement_type
),
scored AS (
  SELECT a.*, a.credits * __CREDIT_PRICE__ AS usd,
         a.credits / NULLIF(w.warehouse_credits, 0) AS share
  FROM agg a
  LEFT JOIN wh_total w ON w.warehouse_id = a.warehouse_id
  QUALIFY ROW_NUMBER() OVER (ORDER BY a.credits DESC, a.runs DESC, a.warehouse_id, a.group_id) <= :top_n
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, group_kind, group_id,
       statement_type,
       -- a short label for the statement shape, so charts rank statements, not warehouses
       IFF(group_kind = 'text hash', COALESCE(statement_type, 'STATEMENT') || ' #' || LEFT(group_id, 8),
           'ad-hoc ' || COALESCE(statement_type, 'STATEMENT') || ' (text hidden)') AS statement_shape,
       runs, distinct_users, top_user,
       ROUND(usd, 2) AS est_cost_usd_list,
       ROUND(share, 3) AS share_of_warehouse_cost,
       total_exec_ms, avg_exec_ms, max_exec_ms, read_bytes, spilled_bytes, from_result_cache_share,
       sample_statement_id, first_seen, last_seen,
       CASE
         WHEN usd >= :crit_cost_usd OR share >= :crit_share_frac THEN 'CRITICAL'
         WHEN usd >= :warn_cost_usd OR share >= :warn_share_frac THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY credits DESC, runs DESC, warehouse_id, group_kind, group_id
