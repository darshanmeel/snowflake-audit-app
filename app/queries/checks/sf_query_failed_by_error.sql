-- query_id: sf_query_failed_by_error
-- title: Failed statements grouped by error
-- domain: performance   tier: standard
-- entity: error codes = error_code
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_failures (default 50) failures: at or above this the row reads WARN; :crit_failures
--   (default 1000) failures: at or above this the row reads CRITICAL; :warn_credits (default 5)
--   credits: at or above this the row reads WARN; :crit_credits (default 50) credits: at or above this
--   the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one error code with one message pattern (numbers and quoted names masked so
--   repeats of the same fault group together). failures, users, warehouses and first/last seen show how
--   widespread and how current it is; credits = attributed credits the failed runs burned before
--   failing. Canceled (604) is excluded.
-- healthy: status = OK when an error is rare and cheap
-- investigate_if: WARN when failures >= warn_failures or credits >= warn_credits; CRITICAL when
--   failures >= crit_failures or credits >= crit_credits
-- actions: 1) fix the top error at its source (the job or tool in main_user_name / sample_query_id)
--   (free); 2) timeouts (; 3) and out-of-memory errors point to sizing, see sf_wh_undersized (config);
--   4) add retries with backoff only for transient errors (free)
-- next: none
-- caveats: message masking is a heuristic. Credits exclude queries under about 100 ms and lag up to 8
--   hours.
WITH qh AS (
  SELECT query_id, error_code, warehouse_name, user_name, query_type, start_time, execution_time,
         -- mask numbers and quoted identifiers so one fault is one row
         LEFT(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(error_message, CHR(39) || '[^' || CHR(39) || ']*' || CHR(39), '<name>'),
                                              '"[^"]*"', '<name>'), '[0-9]+', 'N'), 200) AS error_pattern,
         error_message
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND execution_status = 'FAIL' AND (error_code IS NULL OR error_code <> 604)
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
g AS (
  SELECT qh.error_code, qh.error_pattern, COUNT(*) AS failures,
         COUNT(DISTINCT qh.user_name) AS distinct_users, MODE(qh.user_name) AS main_user_name,
         COUNT(DISTINCT qh.warehouse_name) AS distinct_warehouses, MODE(qh.warehouse_name) AS warehouse_name,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT qh.user_name), 0, 10), ', ') AS users,
         MODE(qh.query_type) AS main_query_type,
         MIN(qh.start_time) AS first_seen, MAX(qh.start_time) AS last_seen,
         COUNT(DISTINCT DATE(qh.start_time)) AS days_seen,
         SUM(qh.execution_time) / 3600000 AS exec_hours_before_failure,
         MAX_BY(qh.query_id, qh.start_time) AS sample_query_id,
         SUM(a.credits) AS credits
  FROM qh LEFT JOIN attr a ON a.query_id = qh.query_id
  GROUP BY 1, 2
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_name, error_code, error_pattern,
       failures, days_seen, distinct_users, main_user_name, users, distinct_warehouses,
       main_query_type, first_seen, last_seen, exec_hours_before_failure, sample_query_id,
       credits, credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN failures >= :crit_failures OR credits >= :crit_credits THEN 'CRITICAL'
         WHEN failures >= :warn_failures OR credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY credits DESC NULLS LAST, failures DESC
