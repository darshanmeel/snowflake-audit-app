-- query_id: sf_chg_bi_dashboards
-- title: BI tool spend per tool and per dashboard
-- domain: cost   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_dashboard_usd (default 50) dashboard usd: at or above this the row reads WARN;
--   :crit_dashboard_usd (default 500) dashboard usd: at or above this the row reads CRITICAL;
--   :warn_unidentified_pct (default 50) unidentified pct: at or above this the row reads WARN;
--   :min_tool_usd (default 100) tool usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one BI tool (row_kind 'tool') or one dashboard/workbook in it (row_kind
--   'dashboard'). The tool comes from the session's APPLICATION (client_environment) and driver, or
--   from markers the tool writes into the SQL (Looker Query Context, Sigma and Metabase comments,
--   Tableau temp tables). The dashboard key is taken from a JSON QUERY_TAG (dashboard, dashboard_id,
--   workbook, workbook_id, report ...), a plain QUERY_TAG (e.g. Tableau initial SQL [WorkbookName]), or
--   the tool's comment; '(not identified)' when none is present. unidentified_pct on a tool row is the
--   share of its credits with no dashboard key.
-- healthy: status = OK when each dashboard costs little and most tool spend maps to a dashboard.
-- investigate_if: WARN when a dashboard costs >= warn_dashboard_usd, or a tool spending >= min_tool_usd
--   has >= warn_unidentified_pct of it unidentified; CRITICAL when a dashboard costs >=
--   crit_dashboard_usd.
-- actions: 1) find the owner of the top dashboards; check refresh schedules and live vs extract mode
--   (free); 2) set QUERY_TAG with the workbook/dashboard name in the tool's connection or initial SQL
--   (config); 3) move heavy dashboards to extracts, aggregates or a dedicated warehouse (spend).
-- next: none
-- caveats: tool markers and tag keys vary by tool and version; Sigma and Looker comment keys are read
--   on a best-effort basis. Sessions older than the window plus 7 days are not matched. Credits exclude
--   warehouse idle time and queries under about 100 ms; lag up to 8 hours.
WITH __INCLUDE_sf_chg_query_credits__,
s AS (
  SELECT session_id, TO_VARCHAR(GET(TRY_PARSE_JSON(client_environment), 'APPLICATION')) AS app,
         client_application_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  WHERE created_on >= DATEADD(day, -:period_days - 7, __AS_OF_DATE__)
),
q AS (
  SELECT q.query_id, q.start_time, q.user_name, q.warehouse_name, q.query_tag, q.total_elapsed_time,
         TRY_PARSE_JSON(q.query_tag) AS tag,
         COALESCE(s.app, '') || ' ' || COALESCE(s.client_application_id, '') AS client,
         LEFT(q.query_text, 4000) AS head_text,
         COALESCE(a.credits, 0) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  LEFT JOIN s ON s.session_id = q.session_id
  LEFT JOIN sf_chg_attr a ON a.query_id = q.query_id
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
    AND q.warehouse_id IS NOT NULL
),
t AS (
  SELECT q.*,
         CASE
           WHEN client ILIKE '%tableau%' OR head_text ILIKE '%#tableau_%' OR head_text ILIKE '%"tableau_%' THEN 'Tableau'
           WHEN client ILIKE '%powerbi%' OR client ILIKE '%power bi%' OR client ILIKE '%power_bi%' THEN 'Power BI'
           WHEN client ILIKE '%looker%' OR head_text ILIKE '%Looker Query Context%' THEN 'Looker'
           WHEN client ILIKE '%sigma%' OR head_text ILIKE '%-- Sigma%' THEN 'Sigma'
           WHEN client ILIKE '%metabase%' OR head_text ILIKE '%-- Metabase%' THEN 'Metabase'
           WHEN client ILIKE '%thoughtspot%' THEN 'ThoughtSpot'
           WHEN client ILIKE '%superset%' THEN 'Superset'
           WHEN client ILIKE '%qlik%' THEN 'Qlik'
           WHEN client ILIKE '%microstrategy%' THEN 'MicroStrategy'
           WHEN client ILIKE '%hex%' THEN 'Hex'
         END AS bi_tool,
         TRY_PARSE_JSON(REGEXP_SUBSTR(head_text, 'Looker Query Context ''(\\{[^'']*\\})''', 1, 1, 'e', 1)) AS looker_ctx,
         TRY_PARSE_JSON(REGEXP_SUBSTR(head_text, '-- Sigma[^{\\n]*(\\{[^\\n]*\\})', 1, 1, 'e', 1)) AS sigma_ctx
  FROM q
),
k AS (
  SELECT t.*,
         COALESCE(TO_VARCHAR(GET(tag, 'dashboard_id')), TO_VARCHAR(GET(tag, 'dashboard')),
                  TO_VARCHAR(GET(tag, 'dashboard_name')), TO_VARCHAR(GET(tag, 'workbook_id')),
                  TO_VARCHAR(GET(tag, 'workbook')), TO_VARCHAR(GET(tag, 'workbook_name')),
                  TO_VARCHAR(GET(tag, 'report')), TO_VARCHAR(GET(tag, 'report_name')),
                  TO_VARCHAR(GET(looker_ctx, 'dashboard_id')),
                  IFF(looker_ctx IS NOT NULL, 'explore:' || TO_VARCHAR(GET(looker_ctx, 'history_slug')), NULL),
                  TO_VARCHAR(GET(sigma_ctx, 'workbook-id')), TO_VARCHAR(GET(sigma_ctx, 'url')),
                  IFF(tag IS NULL, NULLIF(TRIM(query_tag), ''), NULL)) AS dashboard_key
  FROM t
  WHERE bi_tool IS NOT NULL
),
dash AS (
  SELECT 'dashboard' AS row_kind, bi_tool, COALESCE(dashboard_key, '(not identified)') AS dashboard_key,
         COUNT(*) AS queries, COUNT(DISTINCT user_name) AS distinct_users,
         COUNT(DISTINCT DATE(start_time)) AS active_days, MODE(warehouse_name) AS warehouse_name,
         MODE(user_name) AS main_user_name, SUM(total_elapsed_time) / 3600000 AS elapsed_hours,
         SUM(credits) AS credits, CAST(NULL AS DOUBLE) AS unidentified_pct
  FROM k
  GROUP BY 2, 3
),
tool AS (
  SELECT 'tool', bi_tool, NULL, COUNT(*), COUNT(DISTINCT user_name), COUNT(DISTINCT DATE(start_time)),
         MODE(warehouse_name), MODE(user_name), SUM(total_elapsed_time) / 3600000, SUM(credits),
         100 * SUM(IFF(dashboard_key IS NULL, credits, 0)) / NULLIF(SUM(credits), 0)
  FROM k
  GROUP BY bi_tool
),
rows_ AS (
  -- dash first: a UNION takes its column names from the first branch.
  SELECT * FROM dash
  UNION ALL
  SELECT * FROM tool
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind, bi_tool, dashboard_key,
       queries, distinct_users, active_days, warehouse_name, main_user_name, elapsed_hours,
       credits AS attributed_credits, credits / NULLIF(queries, 0) AS credits_per_query,
       unidentified_pct,
       100 * credits / NULLIF(SUM(IFF(row_kind = 'tool', credits, 0)) OVER (), 0) AS share_of_bi_pct,
       credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN row_kind = 'tool' AND credits * __CREDIT_PRICE__ >= :min_tool_usd
              AND unidentified_pct >= :warn_unidentified_pct THEN 'WARN'
         WHEN row_kind = 'dashboard' AND dashboard_key <> '(not identified)'
              AND credits * __CREDIT_PRICE__ >= :crit_dashboard_usd THEN 'CRITICAL'
         WHEN row_kind = 'dashboard' AND dashboard_key <> '(not identified)'
              AND credits * __CREDIT_PRICE__ >= :warn_dashboard_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM rows_
ORDER BY bi_tool, row_kind DESC, attributed_credits DESC NULLS LAST
