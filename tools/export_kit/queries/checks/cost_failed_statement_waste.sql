-- query_id: cost_failed_statement_waste
-- title: Failed SQL statements and the compute they used (possible waste)
-- domain: cost   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_waste_usd (default 5) dollars of compute used by failed statements on one warehouse
--   that flags WARN; :crit_waste_usd (default 50) the same that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one warehouse with at least one FAILED statement in the window.
--   est_wasted_usd_list is the POSSIBLE waste: the compute Snowflake attributed to those failed
--   statements, at the effective list price. Some of this is unavoidable - a statement can fail on
--   bad input or a permission change - but a warehouse where failures keep costing money points at
--   something to fix. A failed statement with no attributed row counts $0 (it failed before using
--   compute). Cancelled statements are shown (est_canceled_usd_list) and NOT counted: cancelling a
--   runaway query is often the fix. A failed statement that Snowflake also retried is NOT counted
--   here (retried_failed_statements): its lost time is counted once, in sf_perf_query_retries, so no
--   query is possible waste in both. waste_reason says it in one line.
-- healthy: status = OK - failed statements on the warehouse used under :warn_waste_usd dollars of
--   compute in the window (field heuristic).
-- investigate_if: status = WARN (at/above :warn_waste_usd) or CRITICAL (at/above :crit_waste_usd)
--   dollars of compute used by failed statements (field heuristic). NOT_ASSESSED is not a pass: read
--   not_assessed_reason.
-- actions: 1) find the failing statements and their error in query_failed_queries_daily, and fix
--   the SQL, permission or schema problem they point to (free); 2) add a statement timeout or a
--   fail-fast check in the calling task or app, so a statement bound to fail stops early (config);
--   3) when the failures are out-of-memory, size the warehouse up (spend).
-- next: none
-- not_assessed_reasons: no_attributed_usage: failed statements found, but QUERY_ATTRIBUTION_HISTORY
--   has no rows for this warehouse in the window, so the compute they used cannot be measured;
--   unpriced: the failed statements' attributed usage has no list price, so there is no dollar
--   figure (failed_credits credits are shown instead)
-- caveats: a query with retry time is the retries check's, never this one's. Snowflake version: exact per-query credits (QUERY_ATTRIBUTION_HISTORY) for FAIL statements;
--   error 604 (canceled) is shown, not counted. Queries under ~100 ms have no attribution row and count
--   $0.
WITH stmts AS (
  SELECT query_id, TO_VARCHAR(warehouse_id) AS warehouse_id,
         CASE WHEN execution_status = 'FAIL' AND error_code = '604' THEN 'CANCELED'
              WHEN execution_status = 'FAIL' AND COALESCE(query_retry_time, 0) > 0 THEN 'FAIL_RETRIED'
              ELSE execution_status END AS state
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY query_id
),
w AS (
  SELECT s.warehouse_id,
         COUNT(*) AS statements,
         COUNT_IF(s.state = 'FAIL') AS failed_statements,
         COUNT_IF(s.state = 'CANCELED') AS canceled_statements,
         COUNT_IF(s.state = 'FAIL_RETRIED') AS retried_failed_statements,
         COUNT_IF(s.state = 'FAIL' AND a.credits > 0) AS failed_with_cost,
         SUM(IFF(s.state = 'FAIL', a.credits, 0)) AS failed_credits,
         SUM(IFF(s.state = 'CANCELED', a.credits, 0)) AS canceled_credits,
         SUM(a.credits) AS attributed_credits,
         COUNT(a.query_id) AS attributed_rows
  FROM stmts s LEFT JOIN attr a ON a.query_id = s.query_id
  GROUP BY s.warehouse_id
  HAVING COUNT_IF(s.state = 'FAIL') > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, statements,
       failed_statements, canceled_statements, retried_failed_statements, failed_with_cost,
       failed_credits AS failed_credits,
       failed_credits * __CREDIT_PRICE__ AS est_wasted_usd_list,
       canceled_credits * __CREDIT_PRICE__ AS est_canceled_usd_list,
       attributed_credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       100 * failed_credits / NULLIF(attributed_credits, 0) AS failed_cost_share_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       failed_statements || ' failed statements used ' || ROUND(failed_credits, 2) || ' credits' AS waste_reason,
       CASE WHEN attributed_rows = 0 THEN 'no_attributed_usage'
            WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN attributed_rows = 0 OR __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN failed_credits * __CREDIT_PRICE__ >= :crit_waste_usd THEN 'CRITICAL'
         WHEN failed_credits * __CREDIT_PRICE__ >= :warn_waste_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM w
ORDER BY est_wasted_usd_list DESC NULLS LAST
