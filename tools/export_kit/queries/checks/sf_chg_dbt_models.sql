-- query_id: sf_chg_dbt_models
-- title: dbt spend per model and per run
-- domain: cost   tier: standard
-- entity: dbt models = dbt_key
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_model_usd (default 50) model usd: at or above this the row reads WARN; :crit_model_usd
--   (default 500) model usd: at or above this the row reads CRITICAL; :warn_invocation_usd (default
--   100) invocation usd: at or above this the row reads WARN; :top_invocations (default 50) top
--   invocations: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one dbt node (row_kind 'model': model, snapshot, seed, test) or one dbt run
--   (row_kind 'invocation', the top_invocations most expensive). dbt metadata is read from a JSON
--   QUERY_TAG (keys node_id, dbt_model, invocation_id, materialized, ... as written by
--   dbt-snowflake-query-tags or a query_tag macro) or, failing that, from dbt's query comment /*
--   {"app": "dbt", "node_id": ...} */. credits = exact per-query compute credits;
--   credits_per_invocation shows what one build of the model costs.
-- healthy: status = OK when each model and each run costs little.
-- investigate_if: WARN when a model costs >= warn_model_usd in the window or a run costs >=
--   warn_invocation_usd; CRITICAL when a model costs >= crit_model_usd. NOT_ASSESSED when no query
--   carries dbt metadata.
-- actions: 1) open the model's SQL: full-refresh table models that could be incremental, and tests that
--   scan whole tables, are the usual top rows (free); 2) make the model incremental, add clustering or
--   a narrower lookback, run heavy models less often (config); 3) move dbt to its own right-sized
--   warehouse (spend).
-- next: none
-- caveats: without a JSON query tag or dbt's default query comment the queries are not recognised. A
--   model's invocations count only runs that write invocation_id. Credits exclude warehouse idle time
--   and queries under about 100 ms; lag up to 8 hours.
WITH -- Exact per-query compute credits (QUERY_ATTRIBUTION_HISTORY) with the query's context from
-- QUERY_HISTORY, which the attribution view does not carry (role, database, schema, session, type).
-- QUERY_HISTORY is read one extra day back so a query started just before the window still joins.
-- The join is outer: a query with no QUERY_HISTORY row keeps its credits, with the user, warehouse and
-- tag the attribution view carries itself and '(no query history row)' for the rest.
sf_chg_attr AS (
  SELECT query_id,
         SUM(credits_attributed_compute) AS credits,
         SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits,
         MAX(user_name) AS user_name, MAX(warehouse_name) AS warehouse_name,
         MAX(warehouse_id) AS warehouse_id, MAX(query_tag) AS query_tag, MIN(start_time) AS start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY query_id
),
sf_chg_query_credits AS (
  SELECT a.query_id, COALESCE(q.start_time, a.start_time) AS start_time,
         COALESCE(NULLIF(TRIM(COALESCE(q.user_name, a.user_name)), ''), '(unknown user)') AS user_name,
         IFF(q.query_id IS NULL, '(no query history row)', q.role_name) AS role_name,
         IFF(q.query_id IS NULL, '(no query history row)', q.database_name) AS database_name, q.database_id,
         IFF(q.query_id IS NULL, '(no query history row)', q.schema_name) AS schema_name, q.schema_id,
         COALESCE(q.warehouse_name, a.warehouse_name) AS warehouse_name,
         TO_VARCHAR(COALESCE(q.warehouse_id, a.warehouse_id)) AS warehouse_id,
         COALESCE(q.query_tag, a.query_tag) AS query_tag, q.session_id, q.query_type, a.credits, a.qas_credits
  FROM sf_chg_attr a
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    ON q.query_id = a.query_id
   AND q.start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__)
   AND q.start_time < __AS_OF_DATE__
),
q AS (
  SELECT q.query_id, q.start_time, q.user_name, q.warehouse_name, q.total_elapsed_time, q.query_tag,
         TRY_PARSE_JSON(q.query_tag) AS tag,
         TRY_PARSE_JSON(REGEXP_SUBSTR(q.query_text,
           '/\\*\\s*(\\{[^*]*"app"\\s*:\\s*"dbt"[^*]*\\})\\s*\\*/', 1, 1, 'e', 1)) AS cmt,
         COALESCE(a.credits, 0) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  LEFT JOIN sf_chg_attr a ON a.query_id = q.query_id
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
    AND (q.query_tag ILIKE '%dbt%' OR q.query_text ILIKE '%"app":%"dbt"%')
),
d AS (
  SELECT q.*,
         COALESCE(TO_VARCHAR(GET(tag, 'node_id')), TO_VARCHAR(GET(cmt, 'node_id')),
                  TO_VARCHAR(GET(tag, 'dbt_model')), TO_VARCHAR(GET(tag, 'model')),
                  TO_VARCHAR(GET(tag, 'node_name')),
                  IFF(tag IS NULL AND cmt IS NULL, query_tag, NULL),
                  '(dbt, no node)') AS node_id,
         COALESCE(TO_VARCHAR(GET(tag, 'invocation_id')), TO_VARCHAR(GET(cmt, 'invocation_id'))) AS invocation_id,
         COALESCE(TO_VARCHAR(GET(tag, 'project_name')), TO_VARCHAR(GET(cmt, 'profile_name'))) AS project_name,
         COALESCE(TO_VARCHAR(GET(tag, 'target_name')), TO_VARCHAR(GET(cmt, 'target_name'))) AS target_name,
         TO_VARCHAR(GET(tag, 'materialized')) AS materialized
  FROM q
  WHERE tag IS NOT NULL OR cmt IS NOT NULL OR query_tag ILIKE '%dbt%'
),
models AS (
  SELECT 'model' AS row_kind, node_id AS dbt_key, MODE(project_name) AS project_name,
         MODE(target_name) AS target_name, MODE(materialized) AS materialized,
         COUNT(*) AS queries, COUNT(DISTINCT invocation_id) AS invocations,
         COUNT(DISTINCT node_id) AS nodes, MODE(warehouse_name) AS warehouse_name,
         MODE(user_name) AS user_name, MIN(start_time) AS first_seen_at, MAX(start_time) AS last_seen_at,
         SUM(total_elapsed_time) / 3600000 AS elapsed_hours, SUM(credits) AS credits
  FROM d
  GROUP BY node_id
),
runs AS (
  SELECT 'invocation' AS row_kind, invocation_id AS dbt_key, MODE(project_name) AS project_name,
         MODE(target_name) AS target_name, NULL AS materialized,
         COUNT(*) AS queries, 1 AS invocations, COUNT(DISTINCT node_id) AS nodes,
         MODE(warehouse_name) AS warehouse_name, MODE(user_name) AS user_name,
         MIN(start_time) AS first_seen_at, MAX(start_time) AS last_seen_at,
         SUM(total_elapsed_time) / 3600000 AS elapsed_hours, SUM(credits) AS credits
  FROM d
  WHERE invocation_id IS NOT NULL
  GROUP BY invocation_id
  QUALIFY ROW_NUMBER() OVER (ORDER BY SUM(credits) DESC) <= :top_invocations
),
rows_ AS (
  SELECT * FROM models
  UNION ALL
  SELECT * FROM runs
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind, dbt_key, project_name,
       target_name, materialized, queries, invocations, nodes, warehouse_name, user_name,
       first_seen_at, last_seen_at, elapsed_hours, credits,
       credits / NULLIF(invocations, 0) AS credits_per_invocation,
       100 * credits / NULLIF(SUM(IFF(row_kind = 'model', credits, 0)) OVER (), 0) AS share_of_dbt_pct,
       credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN row_kind = 'model' AND credits * __CREDIT_PRICE__ >= :crit_model_usd THEN 'CRITICAL'
         WHEN row_kind = 'model' AND credits * __CREDIT_PRICE__ >= :warn_model_usd THEN 'WARN'
         WHEN row_kind = 'invocation' AND credits * __CREDIT_PRICE__ >= :warn_invocation_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM rows_
UNION ALL
-- One explicit row when nothing looks like dbt, so an empty result is not read as "dbt is cheap".
SELECT :period_days, __ACCOUNT_ID__, 'none', NULL, NULL, NULL, NULL, 0, 0, 0, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced'),
       'no_dbt_metadata_in_query_tag_or_comment', 'NOT_ASSESSED'
WHERE NOT EXISTS (SELECT 1 FROM d)
ORDER BY credits DESC NULLS LAST
