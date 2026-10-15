-- query_id: sf_ai_model_serving_spend
-- title: Model Registry inference spend by model version, and always-on model services
-- domain: serving_ai   tier: standard
-- entity: model versions = model_name, model_version_name
-- windowed: yes
-- money: est_within_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.MODEL_SERVING_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 10) spend usd: least a row needs before it can flag;
--   :warn_always_on_pct (default 90) percent: a model service with credits in at least this share of the hours flags;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN
-- empty_if: role_cannot_see, view_missing, no_activity, ingestion_lag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Data before 25 Aug 2026 is documented as possibly incomplete,
--   so the growth test reads only when the window before starts on or after that date; the always-on test
--   is unaffected.
-- read_this: one row = one model version served one way (in a container service, or on a warehouse). For
--   container rows active_hours and always_on_pct show how much of the window the service billed; for
--   warehouse rows invocations and users count the queries and people. The credits are Snowflake's estimate
--   and overlap the compute pool or warehouse credits counted elsewhere, so the $ is context, never added.
-- healthy: status = OK when a model's spend is small or flat and no model service bills every hour.
-- investigate_if: WARN when a version spending at least :min_spend_usd is served by a service (not a job)
--   with credits in :warn_always_on_pct percent of the hours, or grew :warn_increase_pct percent on the
--   window before (the growth test is skipped while that window starts before 25 Aug 2026).
-- actions: 1) suspend or drop model services nobody calls (free); 2) let the service scale to zero, or
--   lower its minimum instances (config); 3) serve rarely called models from a warehouse instead (config)
-- next: sf_ai_compute_pools_config
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the credits cannot be priced
-- caveats: The credits are an estimate and may not match the bill. They overlap pool credits (containers) and
--   warehouse credits (warehouse inference) shown on other pages. Warehouse rows lag up to 8 hours. Query ids
--   are used only to count queries and are never kept.
WITH m AS (
  SELECT UPPER(invocation_type) AS invocation_type, UPPER(workload_type) AS workload_type,
         model_id, model_version_id, compute_pool_id, service_id,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(model_name) AS model_name,
         MAX(model_version_name) AS model_version_name, MAX(compute_pool_name) AS compute_pool_name,
         MAX(service_name) AS service_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS prev_credits,
         COUNT(DISTINCT IFF(UPPER(invocation_type) = 'SPCS' AND credits > 0
                            AND start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__),
                            DATE_TRUNC('hour', start_time), NULL)) AS active_hours,
         COUNT(DISTINCT IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), query_id, NULL)) AS invocations,
         COUNT(DISTINCT IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), user_name, NULL)) AS users
  FROM SNOWFLAKE.ACCOUNT_USAGE.MODEL_SERVING_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2, model_id, model_version_id, compute_pool_id, service_id
),
s AS (
  SELECT m.*,
         IFF(DATEADD(day, -2 * :period_days, __AS_OF_DATE__) < DATE '2026-08-25', NULL,
             100 * (credits - prev_credits) / NULLIF(prev_credits, 0)) AS change_pct,
         IFF(invocation_type = 'SPCS', 100 * active_hours / (24 * :period_days), NULL) AS always_on_pct,
         credits * __CREDIT_PRICE__ AS usd
  FROM m
  WHERE credits > 0 OR prev_credits > 0
),
f AS (
  SELECT s.*, COALESCE(invocation_type = 'SPCS' AND workload_type = 'SERVICE'
                       AND always_on_pct >= :warn_always_on_pct, FALSE) AS always_on,
         COALESCE(prev_credits > 0 AND change_pct >= :warn_increase_pct, FALSE) AS growing
  FROM s
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, invocation_type, workload_type,
       database_name, schema_name, model_name, model_id, model_version_name, model_version_id,
       compute_pool_name, compute_pool_id, service_name, service_id,
       credits AS current_credits, prev_credits AS previous_credits, change_pct, active_hours, always_on_pct,
       IFF(invocation_type = 'SPCS', NULL, invocations) AS invocations,
       IFF(invocation_type = 'SPCS', NULL, users) AS users,
       usd AS est_within_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(always_on, 'service bills in ' || ROUND(always_on_pct, 0) || '% of the hours', NULL),
         IFF(growing, 'up ' || ROUND(change_pct, 0) || '% on the window before', NULL)), '; ') AS reasons,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd < :min_spend_usd THEN 'OK'
         WHEN always_on OR growing THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY credits DESC, model_name, model_version_name
