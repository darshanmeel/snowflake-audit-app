-- query_id: sf_use_query_type_mix
-- title: What each warehouse is used for, by statement type
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_queries (default 1000) queries: least a row needs before it can flag; :warn_metadata_pct
--   (default 50) metadata pct: at or above this the row reads WARN; :crit_metadata_pct (default 80)
--   metadata pct: at or above this the row reads CRITICAL; :warn_cs_usd (default 10) cs usd: at or
--   above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse ('(no warehouse)' for statements that ran none). Statements are
--   grouped into read (SELECT), dml (INSERT, UPDATE, DELETE, MERGE, COPY, UNLOAD, CTAS, TRUNCATE), ddl
--   (CREATE, ALTER, DROP, GRANT, ...), metadata (SHOW, DESCRIBE, USE, SET, LIST, transaction control,
--   EXPLAIN), procedural (CALL, EXECUTE ...) and other. *_pct are shares of the warehouse's statements;
--   *_credits_pct are shares of its attributed compute plus query acceleration credits. cs_credits is the cloud services
--   credits the statements used (before the 10% adjustment; est_metadata_billed_cs_usd_list is priced after it).
-- healthy: status = OK when most statements on a warehouse do real work.
-- investigate_if: WARN when metadata_pct >= warn_metadata_pct over >= min_queries statements and their
--   cloud services cost >= warn_cs_usd; CRITICAL at crit_metadata_pct. Such a mix is a tool or driver
--   polling (SHOW, DESCRIBE, USE, SET before every query) and can keep a warehouse awake.
-- actions: 1) find the client and user behind the metadata statements (sf_query_by_client_application)
--   (free); 2) turn off connection validation/metadata refresh in the tool, cache SHOW results, set
--   session defaults on the user instead of per query (config); 3) separate DML loads from read
--   dashboards onto their own warehouses when the mix is balanced and queuing shows (spend).
-- next: none
-- caveats: query_type names vary by release; unmapped ones fall into other. Many metadata statements
--   need no warehouse but still list the session's warehouse. Credits exclude idle time and queries
--   under about 100 ms.
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
-- Share of the window's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- A per-query cloud services credit is before that adjustment, so a billed figure is credits * billed_ratio.
sf_cs_window AS (
  SELECT COALESCE(GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
                    / NULLIF(SUM(credits_used_cloud_services), 0), 1) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
q AS (
  SELECT TO_VARCHAR(q.warehouse_id) AS warehouse_id, COALESCE(q.warehouse_name, '(no warehouse)') AS warehouse_name,
         CASE
           WHEN q.query_type = 'SELECT' THEN 'read'
           WHEN q.query_type IN ('SHOW', 'DESCRIBE', 'DESCRIBE_QUERY', 'USE', 'SET', 'UNSET', 'ALTER_SESSION',
                                 'LIST_FILES', 'EXPLAIN', 'COMMIT', 'ROLLBACK', 'BEGIN_TRANSACTION')
             OR q.query_type LIKE 'SHOW%' OR q.query_type LIKE 'DESC%' THEN 'metadata'
           WHEN q.query_type IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE', 'MULTI_TABLE_INSERT', 'COPY', 'UNLOAD',
                                 'CREATE_TABLE_AS_SELECT', 'TRUNCATE_TABLE', 'PUT_FILES', 'GET_FILES',
                                 'REMOVE_FILES') THEN 'dml'
           WHEN q.query_type LIKE 'CREATE%' OR q.query_type LIKE 'ALTER%' OR q.query_type LIKE 'DROP%'
             OR q.query_type LIKE 'UNDROP%' OR q.query_type LIKE 'RENAME%' OR q.query_type IN ('GRANT', 'REVOKE')
             THEN 'ddl'
           WHEN q.query_type IN ('CALL', 'EXECUTE_STREAMLIT', 'EXECUTE_TASK') OR q.query_type LIKE 'EXECUTE%'
             THEN 'procedural'
           ELSE 'other'
         END AS kind,
         q.total_elapsed_time, q.credits_used_cloud_services,
         COALESCE(a.credits, 0) + COALESCE(a.qas_credits, 0) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  LEFT JOIN sf_chg_attr a ON a.query_id = q.query_id
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
),
g AS (
  -- by id, so a recreated warehouse with the same name stays apart
  SELECT warehouse_id, MAX(warehouse_name) AS warehouse_name, COUNT(*) AS queries,
         100 * COUNT_IF(kind = 'read') / COUNT(*) AS read_pct,
         100 * COUNT_IF(kind = 'dml') / COUNT(*) AS dml_pct,
         100 * COUNT_IF(kind = 'ddl') / COUNT(*) AS ddl_pct,
         100 * COUNT_IF(kind = 'metadata') / COUNT(*) AS metadata_pct,
         100 * COUNT_IF(kind = 'procedural') / COUNT(*) AS procedural_pct,
         100 * COUNT_IF(kind = 'other') / COUNT(*) AS other_pct,
         SUM(credits) AS credits,
         100 * SUM(IFF(kind = 'read', credits, 0)) / NULLIF(SUM(credits), 0) AS read_credits_pct,
         100 * SUM(IFF(kind = 'dml', credits, 0)) / NULLIF(SUM(credits), 0) AS dml_credits_pct,
         100 * SUM(IFF(kind IN ('ddl', 'metadata'), credits, 0)) / NULLIF(SUM(credits), 0) AS ddl_metadata_credits_pct,
         SUM(credits_used_cloud_services) AS cs_credits,
         SUM(IFF(kind = 'metadata', credits_used_cloud_services, 0)) AS metadata_cs_credits,
         SUM(total_elapsed_time) / 3600000 AS elapsed_hours
  FROM q
  GROUP BY warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, queries,
       read_pct, dml_pct, ddl_pct, metadata_pct, procedural_pct, other_pct,
       CASE GREATEST(read_pct, dml_pct, ddl_pct, metadata_pct, procedural_pct, other_pct)
         WHEN read_pct THEN 'read' WHEN dml_pct THEN 'dml' WHEN metadata_pct THEN 'metadata'
         WHEN ddl_pct THEN 'ddl' WHEN procedural_pct THEN 'procedural' ELSE 'other' END AS main_kind,
       credits AS attributed_credits, read_credits_pct, dml_credits_pct, ddl_metadata_credits_pct,
       cs_credits, metadata_cs_credits, elapsed_hours,
       credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       metadata_cs_credits * w.billed_ratio AS metadata_billed_cs_credits,
       metadata_cs_credits * w.billed_ratio * __CREDIT_PRICE__ AS est_metadata_billed_cs_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN queries < :min_queries OR metadata_cs_credits * w.billed_ratio * __CREDIT_PRICE__ < :warn_cs_usd THEN 'OK'
         WHEN metadata_pct >= :crit_metadata_pct THEN 'CRITICAL'
         WHEN metadata_pct >= :warn_metadata_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g CROSS JOIN sf_cs_window w
ORDER BY queries DESC
