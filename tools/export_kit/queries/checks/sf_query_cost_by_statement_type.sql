-- query_id: sf_query_cost_by_statement_type
-- title: Cost by statement type
-- domain: performance   tier: standard
-- money: est_attributed_usd_list
-- entity: statement types = statement_type
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement type (SELECT, INSERT, MERGE, SET, SHOW, GRANT, ...).
--   statement_kind groups them: read, dml, ddl, metadata, procedural, other. attributed_credits are
--   the warehouse compute plus query acceleration credits Snowflake assigns to those statements, the
--   same basis as query_top_by_cost (qas_credits is the acceleration part); cloud_services_credits are
--   what they used of cloud services before the daily 10% adjustment, and
--   billed_cloud_services_credits is that after it (each day's billed share). The two $ columns are
--   separate figures. SET, USE, SHOW, DESCRIBE, GRANT and the like run no warehouse, so they cost only
--   cloud services, and only on days above the 10% (see sf_cost_cloud_services_billed).
-- healthy: n/a - inventory, not a WARN/CRITICAL finding.
-- investigate_if: n/a - inventory. A metadata or ddl type high in cloud services points at a tool
--   polling; sf_use_query_type_mix shows which warehouse.
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: attributed credits are not the warehouse bill: idle time, queries under about 100 ms,
--   adaptive warehouses and the last 8 hours have none (query_top_by_cost and
--   sf_cost_query_attribution_by_user carry the same rule). query_type names vary by release;
--   unmapped ones read other.
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
-- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
q AS (
  SELECT COALESCE(NULLIF(TRIM(q.query_type), ''), '(unknown)') AS statement_type,
         q.warehouse_id IS NOT NULL AS on_warehouse,
         a.query_id IS NOT NULL AS attributed,
         q.total_elapsed_time,
         COALESCE(a.credits, 0) + COALESCE(a.qas_credits, 0) AS credits,
         COALESCE(a.qas_credits, 0) AS qas_credits,
         COALESCE(q.credits_used_cloud_services, 0) AS cs_credits,
         -- a day with no daily row yet (lag) counts as fully billed
         COALESCE(q.credits_used_cloud_services, 0) * COALESCE(r.billed_ratio, 1) AS billed_cs_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  LEFT JOIN sf_chg_attr a ON a.query_id = q.query_id
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(q.start_time)
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
  UNION ALL
  -- attributed queries with no QUERY_HISTORY row keep their credits, so the total matches chargeback
  SELECT '(no query history row)', a.warehouse_id IS NOT NULL, TRUE, NULL,
         COALESCE(a.credits, 0) + COALESCE(a.qas_credits, 0), COALESCE(a.qas_credits, 0), 0, 0
  FROM sf_chg_attr a
  WHERE NOT EXISTS (SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
                    WHERE q.query_id = a.query_id
                      AND q.start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__)
),
g AS (
  SELECT statement_type, COUNT(*) AS queries,
         COUNT_IF(on_warehouse) AS queries_on_warehouse,
         COUNT_IF(attributed) AS queries_attributed,
         SUM(credits) AS attributed_credits,
         SUM(qas_credits) AS qas_credits,
         SUM(cs_credits) AS cs_credits,
         SUM(billed_cs_credits) AS billed_cs_credits,
         SUM(total_elapsed_time) / 3600000 AS elapsed_hours
  FROM q
  GROUP BY statement_type
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, statement_type,
       -- the same groups as sf_use_query_type_mix
       CASE
         WHEN statement_type = 'SELECT' THEN 'read'
         WHEN statement_type IN ('SHOW', 'DESCRIBE', 'DESCRIBE_QUERY', 'USE', 'SET', 'UNSET', 'ALTER_SESSION',
                                 'LIST_FILES', 'EXPLAIN', 'COMMIT', 'ROLLBACK', 'BEGIN_TRANSACTION')
           OR statement_type LIKE 'SHOW%' OR statement_type LIKE 'DESC%' THEN 'metadata'
         WHEN statement_type IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE', 'MULTI_TABLE_INSERT', 'COPY', 'UNLOAD',
                                 'CREATE_TABLE_AS_SELECT', 'TRUNCATE_TABLE', 'PUT_FILES', 'GET_FILES',
                                 'REMOVE_FILES') THEN 'dml'
         WHEN statement_type LIKE 'CREATE%' OR statement_type LIKE 'ALTER%' OR statement_type LIKE 'DROP%'
           OR statement_type LIKE 'UNDROP%' OR statement_type LIKE 'RENAME%' OR statement_type IN ('GRANT', 'REVOKE')
           THEN 'ddl'
         WHEN statement_type LIKE 'EXECUTE%' OR statement_type = 'CALL' THEN 'procedural'
         ELSE 'other'
       END AS statement_kind,
       queries, queries_on_warehouse, queries_attributed,
       attributed_credits, qas_credits,
       100 * attributed_credits / NULLIF(SUM(attributed_credits) OVER (), 0) AS share_of_attributed_pct,
       cs_credits AS cloud_services_credits,
       billed_cs_credits AS billed_cloud_services_credits,
       100 * cs_credits / NULLIF(SUM(cs_credits) OVER (), 0) AS share_of_cloud_services_pct,
       elapsed_hours,
       attributed_credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       billed_cs_credits * __CREDIT_PRICE__ AS est_billed_cloud_services_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis
FROM g
ORDER BY attributed_credits DESC, cs_credits DESC, statement_type
