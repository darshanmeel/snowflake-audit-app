-- query_id: sf_cost_serverless_features
-- shims: AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, PIPE_USAGE_HISTORY, SERVERLESS_TASK_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY
-- reads: INFORMATION_SCHEMA table functions AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, PIPE_USAGE_HISTORY, SERVERLESS_TASK_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY
-- fallback_note: clustering credits for 6 months at most; no database or schema names, and the table name stands in for its id; materialized view credits for 6 months at most; no database or schema names, and the view name stands in for its id; search optimization credits for 6 months at most; no database or schema names, and the table name stands in for its id; pipe credits for the last 14 days only; the pipe name stands in for its id; serverless task credits for 6 months at most; no database or schema names, and the task name stands in for its id; replication credits for 6 months at most; the group name stands in for its id; query acceleration credits for 6 months at most; the warehouse name stands in for its id
-- needs: MONITOR USAGE
WITH raw AS (
  SELECT 'AUTO_CLUSTERING' AS feature, TO_VARCHAR(table_id) AS object_id,
         database_name || '.' || schema_name || '.' || table_name AS object_name, start_time, credits_used
  FROM __SHIM_AUTOMATIC_CLUSTERING_HISTORY__
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'MATERIALIZED_VIEW', TO_VARCHAR(table_id),
         database_name || '.' || schema_name || '.' || table_name, start_time, TRY_TO_DOUBLE(TO_VARCHAR(credits_used))
  FROM __SHIM_MATERIALIZED_VIEW_REFRESH_HISTORY__
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  -- BASE_TABLE_ID/NAME or TABLE_ID/NAME, whichever the view has while the rename rolls out.
  SELECT 'SEARCH_OPTIMIZATION', TO_VARCHAR(COALESCE(o:BASE_TABLE_ID, o:TABLE_ID)),
         database_name || '.' || schema_name || '.' || COALESCE(o:BASE_TABLE_NAME, o:TABLE_NAME)::VARCHAR,
         start_time, credits_used
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o, start_time, credits_used, database_name, schema_name
        FROM __SHIM_SEARCH_OPTIMIZATION_HISTORY__)
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'SNOWPIPE', TO_VARCHAR(pipe_id), pipe_name, start_time, credits_used
  FROM __SHIM_PIPE_USAGE_HISTORY__
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'SERVERLESS_TASK', TO_VARCHAR(task_id),
         database_name || '.' || schema_name || '.' || task_name, start_time, TRY_TO_DOUBLE(TO_VARCHAR(credits_used))
  FROM __SHIM_SERVERLESS_TASK_HISTORY__
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'REPLICATION', replication_group_name, replication_group_name, start_time, credits_used
  FROM __SHIM_REPLICATION_GROUP_USAGE_HISTORY__
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'QUERY_ACCELERATION', TO_VARCHAR(warehouse_id), warehouse_name, start_time, credits_used
  FROM __SHIM_QUERY_ACCELERATION_HISTORY__
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
o AS (
  SELECT feature, object_id, MAX(object_name) AS object_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS cur_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS prev_credits
  FROM raw
  GROUP BY feature, object_id
),
s AS (
  SELECT o.*, 100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         cur_credits * __CREDIT_PRICE__ AS cur_usd
  FROM o
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, feature, object_name, object_id,
       cur_credits AS current_credits, prev_credits AS previous_credits,
       cur_credits - prev_credits AS change_credits, change_pct,
       cur_credits * __CREDIT_PRICE__ AS est_current_usd_list,
       prev_credits * __CREDIT_PRICE__ AS est_previous_usd_list,
       (cur_credits - prev_credits) * __CREDIT_PRICE__ AS est_change_usd_list,
       100 * cur_credits / NULLIF(SUM(cur_credits) OVER (PARTITION BY feature), 0) AS share_of_feature_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_usd < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN cur_usd >= :crit_spend_usd AND change_pct > 0 THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY est_change_usd_list DESC NULLS LAST, change_credits DESC
