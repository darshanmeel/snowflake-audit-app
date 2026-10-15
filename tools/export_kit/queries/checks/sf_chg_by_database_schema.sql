-- query_id: sf_chg_by_database_schema
-- title: Full cost per database and schema
-- domain: cost   tier: standard
-- money: est_total_usd_list
-- entity: databases = database_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.PIPES, SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_share_pct (default 25) share pct: at or above this the row reads WARN; :crit_share_pct
--   (default 50) share pct: at or above this the row reads CRITICAL; :min_spend_usd (default 100) spend
--   usd: least a row needs before it can flag; :warn_unassigned_pct (default 20) unassigned pct: at or
--   above this the row reads WARN; :crit_unassigned_pct (default 40) unassigned pct: at or above this
--   the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a database (row_kind 'database') or one of its schemas (row_kind 'schema').
--   query_credits = exact per-query compute credits of queries whose current database/schema was this
--   one; serverless_credits = auto-clustering, materialized view, search optimization, serverless task
--   and Snowpipe credits of objects in it; est_storage_usd_window = its average database + Fail-safe
--   bytes priced for the days of the window. est_total_usd_list adds the three. '(no database)'
--   collects queries run with no current database set. Schema rows carry query credits only, so they do
--   not add up to the database row.
-- healthy: status = OK when no database takes most of the spend and little query spend lacks a
--   database.
-- investigate_if: WARN when a database is >= warn_share_pct of total spend (and >= min_spend_usd), or
--   '(no database)' is >= warn_unassigned_pct of query credits; CRITICAL at crit_share_pct /
--   crit_unassigned_pct.
-- actions: 1) send each database owner their row; ask the owner of the top one what drives it (free);
--   2) set a default database/schema (or a QUERY_TAG) on service users and tool connections so '(no
--   database)' shrinks (config); 3) split shared databases per team so cost follows ownership (config).
-- next: none
-- caveats: without a storage price est_storage_usd_window is empty (never $0) and est_total_usd_list is compute
--   only (storage_price_basis = unpriced). query credits follow the session's current database, not the tables read: a query in
--   ANALYTICS that reads RAW is charged to ANALYTICS. Credits exclude warehouse idle time and queries
--   under about 100 ms. Storage excludes stages and hybrid tables. Lags up to 8 hours.
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
qc AS (
  SELECT COALESCE(database_name, '(no database)') AS database_name,
         TO_VARCHAR(database_id) AS database_id,
         COALESCE(schema_name, '(no schema)') AS schema_name,
         COUNT(*) AS queries, COUNT(DISTINCT user_name) AS users, SUM(credits) AS credits
  FROM sf_chg_query_credits
  GROUP BY 1, 2, 3
),
srv AS (
  SELECT database_name, SUM(credits_used) AS credits
  FROM (
    SELECT database_name, credits_used FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
    WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    UNION ALL
    SELECT database_name, TRY_TO_DOUBLE(TO_VARCHAR(credits_used)) FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY
    WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    UNION ALL
    SELECT database_name, credits_used FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY
    WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    UNION ALL
    SELECT database_name, TRY_TO_DOUBLE(TO_VARCHAR(credits_used)) FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
    WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    UNION ALL
    -- PIPE_USAGE_HISTORY has no database column; the pipe's database comes from PIPES.
    SELECT COALESCE(p.pipe_catalog, '(unknown pipe)'), u.credits_used
    FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY u
    LEFT JOIN (SELECT pipe_id, MAX(pipe_catalog) AS pipe_catalog
               FROM SNOWFLAKE.ACCOUNT_USAGE.PIPES GROUP BY pipe_id) p ON p.pipe_id = u.pipe_id
    WHERE u.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND u.start_time < __AS_OF_DATE__
  )
  GROUP BY database_name
),
st AS (
  SELECT database_name, TO_VARCHAR(MAX(database_id)) AS database_id,
         SUM(COALESCE(average_database_bytes, 0) + COALESCE(average_failsafe_bytes, 0)) AS byte_days,
         MAX_BY(COALESCE(average_database_bytes, 0) + COALESCE(average_failsafe_bytes, 0), usage_date) AS end_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY database_name
),
db AS (
  SELECT COALESCE(q.database_name, s.database_name, st.database_name) AS database_name,
         COALESCE(q.database_id, st.database_id) AS database_id,
         q.queries, q.users, COALESCE(q.credits, 0) AS query_credits,
         COALESCE(s.credits, 0) AS serverless_credits, st.end_bytes,
         -- byte-days / 30.4 turns daily averages into TB-months for the window (the same month length as the
         -- overview); NULL, never 0, when no storage price is known.
         COALESCE(st.byte_days, 0) / POWER(1024, 4) / 30.4 * __STORAGE_PRICE_TB_MONTH__ AS storage_usd
  FROM (SELECT COALESCE(database_name, '(no database)') AS database_name,
               TO_VARCHAR(MAX(database_id)) AS database_id, COUNT(*) AS queries,
               COUNT(DISTINCT user_name) AS users, SUM(credits) AS credits
        FROM sf_chg_query_credits GROUP BY 1) q
  FULL OUTER JOIN srv s ON s.database_name = q.database_name
  FULL OUTER JOIN st ON st.database_name = COALESCE(q.database_name, s.database_name)
),
rows_ AS (
  SELECT 'database' AS row_kind, database_name, database_id, CAST(NULL AS VARCHAR) AS schema_name,
         queries, users, query_credits, serverless_credits, end_bytes, storage_usd
  FROM db
  UNION ALL
  SELECT 'schema', database_name, database_id, schema_name, queries, users, credits, NULL, NULL, NULL
  FROM qc
),
s AS (
  SELECT r.*,
         (COALESCE(query_credits, 0) + COALESCE(serverless_credits, 0)) * __CREDIT_PRICE__
           + COALESCE(storage_usd, 0) AS total_usd,
         SUM(IFF(row_kind = 'database', (COALESCE(query_credits, 0) + COALESCE(serverless_credits, 0))
               * __CREDIT_PRICE__ + COALESCE(storage_usd, 0), 0)) OVER () AS all_usd,
         SUM(IFF(row_kind = 'database', query_credits, 0)) OVER () AS all_query_credits
  FROM rows_ r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind, database_name, database_id,
       schema_name, queries, users AS distinct_users, query_credits, serverless_credits,
       100 * query_credits / NULLIF(all_query_credits, 0) AS share_of_query_credits_pct,
       end_bytes / POWER(1024, 4) AS end_tb,
       query_credits * __CREDIT_PRICE__ AS est_query_usd_list,
       serverless_credits * __CREDIT_PRICE__ AS est_serverless_usd_list,
       storage_usd AS est_storage_usd_window,
       IFF(row_kind = 'database', total_usd, NULL) AS est_total_usd_list,
       IFF(row_kind = 'database', 100 * total_usd / NULLIF(all_usd, 0), NULL) AS share_of_total_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS storage_price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN row_kind = 'schema' THEN 'OK'
         WHEN database_name = '(no database)' AND query_credits * __CREDIT_PRICE__ >= :min_spend_usd
              AND 100 * query_credits / NULLIF(all_query_credits, 0) >= :crit_unassigned_pct THEN 'CRITICAL'
         WHEN database_name = '(no database)' AND query_credits * __CREDIT_PRICE__ >= :min_spend_usd
              AND 100 * query_credits / NULLIF(all_query_credits, 0) >= :warn_unassigned_pct THEN 'WARN'
         WHEN total_usd < :min_spend_usd THEN 'OK'
         WHEN 100 * total_usd / NULLIF(all_usd, 0) >= :crit_share_pct THEN 'CRITICAL'
         WHEN 100 * total_usd / NULLIF(all_usd, 0) >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY database_name, row_kind, query_credits DESC NULLS LAST
