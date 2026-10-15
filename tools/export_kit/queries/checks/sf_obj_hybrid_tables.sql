-- query_id: sf_obj_hybrid_tables
-- title: Hybrid tables: request credits and idle tables
-- domain: cost   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.HYBRID_TABLE_USAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition for the idle test (ACCESS_HISTORY)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 50) usd: at or above this the account row reads WARN; :crit_usd (default 500) usd:
--   at or above this the account row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live hybrid table (Unistore) plus one account row of hybrid request credits (not
--   counted as a table). Snowflake tracks request credits for the whole account, not per table, so
--   credits_used and previous_credits (the window before) are on the account row only. Table rows show
--   size (gb) and reads from ACCESS_HISTORY; hybrid storage is billed per GB at a higher rate than standard
--   storage, so no storage $ is shown.
-- healthy: status = OK when account request credits stay under warn_usd and every hybrid table is read.
-- investigate_if: WARN when account request credits cost >= warn_usd, or a table older than the window was not
--   read by any query in ACCESS_HISTORY (idle hybrid storage); CRITICAL when request credits cost >= crit_usd.
-- actions: 1) drop or convert idle hybrid tables to standard tables (CTAS), since row storage costs
--   more (free); 2) keep analytical scans off hybrid tables (copy to a standard table) and use point
--   lookups by primary key or index (engineering); 3) size the warehouse for the request rate (config).
-- next: none
-- caveats: HYBRID_TABLE_USAGE_HISTORY lags up to 3 hours and has OBJECT_TYPE = ACCOUNT with NULL object id
--   and name, so request credits cannot be split by table. Small request volumes may round to 0 credits.
--   Hybrid tables are only in some regions.
WITH -- Queries that read each object in the window, directly or through a view, from ACCESS_HISTORY
-- (Enterprise edition). Used to ask whether a serverless feature is paid for on an object nobody reads.
sf_cost_object_reads AS (
  SELECT f.value:"objectId"::NUMBER AS object_id,
         COUNT(DISTINCT ah.query_id) AS read_queries,
         COUNT(DISTINCT ah.user_name) AS read_users,
         MAX(ah.query_start_time) AS last_read_at
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT()))) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
  GROUP BY 1
),
u AS (
  -- account-level only: the view leaves OBJECT_ID and OBJECT_NAME NULL for hybrid tables
  SELECT SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS previous_credits,
         MAX(end_time) AS last_request_hour
  FROM SNOWFLAKE.ACCOUNT_USAGE.HYBRID_TABLE_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
t AS (
  SELECT table_id, table_catalog AS database_name, table_schema AS schema_name, table_name,
         table_catalog || '.' || table_schema || '.' || table_name AS table_fqn,
         table_owner, row_count, bytes, created, last_altered, deleted
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE is_hybrid = 'YES'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY table_id ORDER BY deleted DESC NULLS FIRST) = 1
),
seen AS (SELECT COUNT(*) AS n FROM sf_cost_object_reads),
j AS (
  SELECT 'table' AS row_kind, t.table_id, t.table_fqn, t.database_name, t.schema_name, t.table_name,
         t.table_owner, t.row_count, t.bytes / POWER(1024, 3) AS gb, t.created, t.last_altered,
         TRUE AS is_live, CAST(NULL AS DOUBLE) AS credits, CAST(NULL AS DOUBLE) AS previous_credits,
         CAST(NULL AS TIMESTAMP_LTZ) AS last_request_hour, COALESCE(r.read_queries, 0) AS read_queries,
         r.last_read_at, (SELECT n FROM seen) > 0 AS access_history_seen
  FROM t
  LEFT JOIN sf_cost_object_reads r ON r.object_id = t.table_id
  WHERE t.deleted IS NULL
  UNION ALL
  SELECT 'account', CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER), CAST(NULL AS DOUBLE),
         CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS BOOLEAN),
         COALESCE(u.credits, 0), COALESCE(u.previous_credits, 0), u.last_request_hour,
         CAST(NULL AS NUMBER), CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS BOOLEAN)
  FROM u
  WHERE COALESCE(u.credits, 0) > 0 OR COALESCE(u.previous_credits, 0) > 0
),
scored AS (
  SELECT j.*, credits * __CREDIT_PRICE__ AS usd,
         (row_kind = 'table' AND read_queries = 0 AND access_history_seen
          AND created < DATEADD(day, -:period_days, __AS_OF_DATE__)) AS idle,
         (row_kind = 'table' AND NOT access_history_seen
          AND created < DATEADD(day, -:period_days, __AS_OF_DATE__)) AS idle_unknown
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind,
       IFF(row_kind = 'account', '(account hybrid request credits)', NULL) AS row_label,
       table_fqn, table_id, database_name, schema_name, table_name, table_owner, is_live, row_count, gb,
       created, last_altered, last_request_hour, read_queries, last_read_at, credits AS credits_used, previous_credits,
       100 * (credits - previous_credits) / NULLIF(previous_credits, 0) AS change_pct,
       usd AS est_request_usd_list,
       IFF(row_kind = 'account', IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced'), NULL) AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(idle, 'no reads in ' || :period_days || ' days' || COALESCE(' (' || ROUND(gb, 1) || ' GB)', ''), NULL),
         IFF(usd >= :warn_usd, ROUND(usd) || ' USD of request credits', NULL)), '; ') AS reasons,
       CASE WHEN row_kind = 'account' AND __CREDIT_PRICE__ IS NULL AND credits > 0 THEN 'unpriced'
            WHEN idle_unknown THEN 'access_history_unavailable' END AS not_assessed_reason,
       CASE
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd OR idle THEN 'WARN'
         WHEN (row_kind = 'account' AND __CREDIT_PRICE__ IS NULL AND credits > 0) OR idle_unknown THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, credits DESC NULLS LAST, table_fqn
