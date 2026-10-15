-- query_id: sf_cost_serverless_features
-- title: Serverless feature spend by object, period over period
-- domain: cost   tier: standard
-- entity: serverless objects = feature, object_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :crit_spend_usd (default 1000) spend usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one object (table, view, pipe, task, replication group, warehouse) of one
--   serverless feature. current = the window, previous = the window before it. These credits run
--   without a warehouse, so they are easy to miss in warehouse reports.
-- healthy: status = OK when an object's spend is small or flat.
-- investigate_if: WARN when an object spending >= min_spend_usd is new or grew >= warn_increase_pct;
--   CRITICAL when it grew >= crit_increase_pct, or spends >= crit_spend_usd and grew at all.
-- actions: 1) find the owner and the change behind the jump: new clustering key, a pipe fed more small
--   files, a task schedule tightened (free); 2) suspend clustering / search optimization / MV on
--   objects nobody reads, batch pipe files to 100-250 MB, widen task schedules (config); 3) move steady
--   serverless tasks onto an existing warehouse (spend).
-- next: none
-- caveats: MV refresh and serverless task credits are VARCHAR in the views and are cast. Serverless credits carry Snowflake's per-feature multiplier already; the $ use the one
--   credit price. Dropped objects keep their last name. ACCOUNT_USAGE lags up to 3 h.
WITH raw AS (
  SELECT 'AUTO_CLUSTERING' AS feature, TO_VARCHAR(table_id) AS object_id,
         database_name || '.' || schema_name || '.' || table_name AS object_name, start_time, credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'MATERIALIZED_VIEW', TO_VARCHAR(table_id),
         database_name || '.' || schema_name || '.' || table_name, start_time, TRY_TO_DOUBLE(TO_VARCHAR(credits_used))
  FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  -- BASE_TABLE_ID/NAME or TABLE_ID/NAME, whichever the view has while the rename rolls out.
  SELECT 'SEARCH_OPTIMIZATION', TO_VARCHAR(COALESCE(o:BASE_TABLE_ID, o:TABLE_ID)),
         database_name || '.' || schema_name || '.' || COALESCE(o:BASE_TABLE_NAME, o:TABLE_NAME)::VARCHAR,
         start_time, credits_used
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o, start_time, credits_used, database_name, schema_name
        FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY)
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'SNOWPIPE', TO_VARCHAR(pipe_id), pipe_name, start_time, credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'SERVERLESS_TASK', TO_VARCHAR(task_id),
         database_name || '.' || schema_name || '.' || task_name, start_time, TRY_TO_DOUBLE(TO_VARCHAR(credits_used))
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'REPLICATION', replication_group_name, replication_group_name, start_time, credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'QUERY_ACCELERATION', TO_VARCHAR(warehouse_id), warehouse_name, start_time, credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_HISTORY
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
