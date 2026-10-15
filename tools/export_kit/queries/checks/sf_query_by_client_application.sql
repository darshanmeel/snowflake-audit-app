-- query_id: sf_query_by_client_application
-- title: Warehouse spend by client tool and driver
-- domain: performance   tier: standard
-- entity: client applications = client
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_credits (default 50) credits: at or above this the row reads WARN; :crit_credits
--   (default 500) credits: at or above this the row reads CRITICAL; :warn_untagged_pct (default 80)
--   untagged pct: at or above this the row reads WARN; :warn_failed_pct (default 10) failed pct: at or
--   above this the row reads WARN; :min_queries (default 100) queries: least a row needs before it can
--   flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one client application (the APPLICATION name a tool reports, else the driver
--   from client_application_id) with its drivers' versions. credits = attributed compute credits of its
--   queries; credit_share_pct = its part of all attributed credits; untagged_pct = share of its queries
--   with no QUERY_TAG, which then cannot be charged back below the user.
-- healthy: status = OK when a tool's spend is small, or it tags its queries and rarely fails
-- investigate_if: WARN when credits >= warn_credits and untagged_pct >= warn_untagged_pct, or
--   failed_pct >= warn_failed_pct (with >= min_queries); CRITICAL when credits >= crit_credits and
--   untagged_pct >= warn_untagged_pct
-- actions: 1) set QUERY_TAG in the tool's connection (session parameter) so spend maps to dashboards
--   and jobs (free); 2) give a heavy BI tool its own warehouse and resource monitor (config); 3)
--   upgrade drivers listed in driver_versions that are out of support (free)
-- next: none
-- not_assessed_reasons: no_session_record: the queries' session is not in SESSIONS (opened more than 30
--   days before the window, past its retention, or not visible to the role), so the client is unknown
-- caveats: SESSIONS retention is shorter than QUERY_HISTORY on some accounts, so older queries fall
--   into '(no session record)'. Credits exclude idle time and queries under about 100 ms, and lag up to 8 hours.
WITH s AS (
  SELECT session_id,
         COALESCE(NULLIF(TO_VARCHAR(GET(TRY_PARSE_JSON(client_environment), 'APPLICATION')), ''),
                  SPLIT_PART(client_application_id, ' ', 1)) AS client,
         client_application_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  -- pooled connections live for weeks: look back a month before the window for their session
  WHERE created_on >= DATEADD(day, -:period_days - 30, __AS_OF_DATE__)
),
qh AS (
  SELECT query_id, session_id, warehouse_name, user_name, query_tag, execution_status
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
g AS (
  -- no SESSIONS row is a gap in the data, not a tool: it gets its own label and is not judged
  SELECT CASE WHEN s.session_id IS NULL THEN '(no session record)' ELSE COALESCE(s.client, '(not reported)') END AS client,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT s.client_application_id), 0, 10), ', ') AS driver_versions,
         COUNT(*) AS queries, COUNT(DISTINCT q.user_name) AS distinct_users,
         COUNT(DISTINCT q.warehouse_name) AS distinct_warehouses, MODE(q.warehouse_name) AS warehouse_name,
         MODE(q.user_name) AS main_user_name,
         100 * COUNT_IF(COALESCE(q.query_tag, '') = '') / COUNT(*) AS untagged_pct,
         100 * COUNT_IF(q.execution_status = 'FAIL') / COUNT(*) AS failed_pct,
         SUM(a.credits) AS credits
  FROM qh q
  LEFT JOIN s ON s.session_id = q.session_id
  LEFT JOIN attr a ON a.query_id = q.query_id
  GROUP BY 1
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_name, client, driver_versions,
       queries, distinct_users, main_user_name, distinct_warehouses, untagged_pct, failed_pct,
       credits, 100 * credits / NULLIF(SUM(credits) OVER (), 0) AS credit_share_pct,
       credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(client = '(no session record)', 'no_session_record', NULL) AS not_assessed_reason,
       CASE
         WHEN client = '(no session record)' THEN 'NOT_ASSESSED'
         WHEN credits >= :crit_credits AND untagged_pct >= :warn_untagged_pct THEN 'CRITICAL'
         WHEN (credits >= :warn_credits AND untagged_pct >= :warn_untagged_pct) OR (failed_pct >= :warn_failed_pct AND queries >= :min_queries) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY credits DESC NULLS LAST
