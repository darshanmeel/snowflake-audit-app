-- query_id: sf_cost_openflow_spend
-- title: Openflow spend by runtime, and runtimes that bill every hour
-- domain: cost   tier: standard
-- entity: openflow runtimes = runtime_name
-- windowed: yes
-- money: est_current_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.OPENFLOW_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_always_on_pct (default 90) percent: a runtime billing in at least this share of the hours flags;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. OPENFLOW_USAGE_HISTORY lists BYOC deployments only and
--   documents no latency.
-- read_this: one row = one Openflow service type or one BYOC runtime. A service row is the credits of one Openflow service type in
--   METERING_HISTORY (Snowflake-hosted or BYOC) and carries the $ and the change. A runtime row is one BYOC
--   runtime from OPENFLOW_USAGE_HISTORY; its $ is part of the BYOC service row, so it sits in a separate
--   column and is never added to it. always_on_pct = hours with credits / hours in the window.
-- healthy: status = OK when Openflow spend is small or flat, and no runtime bills every hour.
-- investigate_if: WARN when a runtime or the Snowflake-hosted total spending at least :min_spend_usd grew
--   :warn_increase_pct percent or is new, or a runtime bills in :warn_always_on_pct percent of the hours;
--   CRITICAL when it grew :crit_increase_pct percent or more.
-- actions: 1) stop runtimes with no active flows (free); 2) size the runtime to the flow volume (config);
--   3) schedule batch flows so the runtime is not up all day (config)
-- next: sf_cost_serverless_features
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the credits cannot be priced
-- caveats: DATA_PLANE_CREDITS_USED is always 0 because BYOC infrastructure is billed by the cloud provider,
--   not Snowflake. Loading data into Snowflake is billed separately (Snowpipe Streaming, warehouses). The
--   Snowflake-hosted part has no runtime name in METERING_HISTORY, so it cannot be split by runtime. These
--   credits carry no cloud-services part to adjust. An account without Openflow has no rows.
WITH mh AS (
  SELECT service_type,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS prev_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE service_type IN ('OPENFLOW_COMPUTE_SNOWFLAKE', 'OPENFLOW_COMPUTE_BYOC')
    AND start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
rt AS (
  SELECT runtime_key, MAX(runtime_name) AS runtime_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), runtime_credits_used, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), runtime_credits_used, 0)) AS prev_credits,
         COUNT(DISTINCT IFF(runtime_credits_used > 0 AND start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__),
                            DATE_TRUNC('hour', start_time), NULL)) AS active_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.OPENFLOW_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
r AS (
  SELECT 'service' AS row_kind, service_type, CAST(NULL AS VARCHAR) AS runtime_name,
         CAST(NULL AS VARCHAR) AS runtime_key, credits, prev_credits, CAST(NULL AS BIGINT) AS active_hours,
         CAST(NULL AS DOUBLE) AS always_on_pct
  FROM mh
  UNION ALL
  SELECT 'runtime', 'OPENFLOW_COMPUTE_BYOC', runtime_name, runtime_key, credits, prev_credits, active_hours,
         100 * active_hours / (24 * :period_days)
  FROM rt
),
s AS (
  SELECT r.*, 100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         credits * __CREDIT_PRICE__ AS usd, prev_credits * __CREDIT_PRICE__ AS prev_usd
  FROM r
),
f AS (
  -- min_spend_usd keeps small rows from flagging
  SELECT s.*, COALESCE(usd, 0) >= :min_spend_usd AS judged
  FROM s
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind, service_type, runtime_name, runtime_key,
       IFF(row_kind = 'service', service_type || ' total', NULL) AS row_label,
       credits AS current_credits, prev_credits AS previous_credits, change_pct, active_hours, always_on_pct,
       IFF(row_kind = 'service', usd, NULL) AS est_current_usd_list,
       IFF(row_kind = 'service', usd - prev_usd, NULL) AS est_change_usd_list,
       IFF(row_kind = 'runtime', usd, NULL) AS est_within_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(judged AND row_kind = 'runtime' AND always_on_pct >= :warn_always_on_pct,
             'bills in ' || ROUND(always_on_pct, 0) || '% of the hours', NULL),
         IFF(judged AND change_pct >= :warn_increase_pct, 'up ' || ROUND(change_pct, 0) || '% on the window before', NULL),
         IFF(judged AND prev_credits = 0 AND credits > 0, 'new in this window', NULL)), '; ') AS reasons,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN NOT judged THEN 'OK'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN prev_credits = 0 OR change_pct >= :warn_increase_pct
              OR (row_kind = 'runtime' AND always_on_pct >= :warn_always_on_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY row_kind DESC, credits DESC, runtime_name, service_type
