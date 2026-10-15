-- query_id: sf_use_database_activity
-- title: Most and least used databases and schemas
-- domain: storage   tier: standard
-- entity: databases = database_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 10) usd: at or above this the row reads WARN; :crit_usd (default 100) usd:
--   at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live schema. read_queries / write_queries count queries that read a table in
--   it (base, dynamic, Iceberg and external tables and materialized views, also through views) or wrote
--   one (INSERT, MERGE, COPY, CTAS, ...), from ACCESS_HISTORY; readers / writers are distinct users.
--   dml_rows counts rows changed in TABLE_DML_HISTORY (it also has Snowpipe loads). activity_rank orders
--   schemas by total queries (1 = busiest). never_used = no read, no write and no DML rows in the window
--   on a schema older than the window.
--   est_storage_usd_month prices its tables' active + Time Travel + Fail-safe bytes.
-- healthy: status = OK when the schema is read or written, or it is unused but nearly free.
-- investigate_if: WARN when a schema older than the window had no read, write or DML and holds tables
--   costing >= warn_usd a month; CRITICAL at crit_usd. NOT_ASSESSED when ACCESS_HISTORY is empty.
-- actions: 1) ask the schema owner whether the unused schema still feeds anything outside Snowflake
--   (extracts, shares) (free); 2) revoke access for a grace period, then drop it or make it transient
--   (config); 3) archive cold data to external storage (engineering).
-- next: none
-- caveats: ACCESS_HISTORY needs Enterprise edition and lags up to 3 hours; reads by data-sharing
--   consumers and replication are not in it. Schema rows for the busiest end show where to focus
--   performance work; the least used end is cleanup material.
WITH acc AS (
  SELECT ah.query_id, ah.user_name, 'read' AS kind, f.value:"objectId"::NUMBER AS table_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.base_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
    -- every table-like domain; the docs spell the domain in mixed case
    AND UPPER(f.value:"objectDomain"::STRING) IN ('TABLE', 'DYNAMIC TABLE', 'MATERIALIZED VIEW', 'ICEBERG TABLE',
                                                   'EXTERNAL TABLE')
  UNION ALL
  SELECT ah.query_id, ah.user_name, 'write', f.value:"objectId"::NUMBER
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.objects_modified) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
    -- every table-like domain; the docs spell the domain in mixed case
    AND UPPER(f.value:"objectDomain"::STRING) IN ('TABLE', 'DYNAMIC TABLE', 'MATERIALIZED VIEW', 'ICEBERG TABLE',
                                                   'EXTERNAL TABLE')
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM acc
),
tbl AS (
  SELECT table_id, table_schema_id AS schema_id FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
),
a AS (
  SELECT t.schema_id,
         COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(kind = 'read', user_name, NULL)) AS readers,
         COUNT(DISTINCT IFF(kind = 'write', user_name, NULL)) AS writers,
         COUNT(DISTINCT IFF(kind = 'read', acc.table_id, NULL)) AS tables_read,
         COUNT(DISTINCT IFF(kind = 'write', acc.table_id, NULL)) AS tables_written
  FROM acc
  JOIN tbl t ON t.table_id = acc.table_id
  GROUP BY t.schema_id
),
dml AS (
  SELECT schema_id,
         SUM(COALESCE(rows_added, 0) + COALESCE(rows_removed, 0) + COALESCE(rows_updated, 0)) AS dml_rows
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY schema_id
),
st AS (
  SELECT table_schema_id AS schema_id, COUNT(*) AS live_tables,
         SUM(COALESCE(active_bytes, 0) + COALESCE(time_travel_bytes, 0) + COALESCE(failsafe_bytes, 0)
             + COALESCE(retained_for_clone_bytes, 0)) AS bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
  -- Fail-safe rows have NULL names and can carry deleted = FALSE: they are not live tables
  WHERE NOT COALESCE(deleted, FALSE) AND table_dropped IS NULL AND schema_dropped IS NULL
    AND catalog_dropped IS NULL AND table_name IS NOT NULL AND table_entered_failsafe IS NULL
  GROUP BY table_schema_id
),
sc AS (
  SELECT schema_id, schema_name, catalog_name AS database_name, catalog_id AS database_id,
         schema_owner, created
  FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
  WHERE deleted IS NULL AND schema_name <> 'INFORMATION_SCHEMA'
),
s AS (
  SELECT sc.*, COALESCE(a.read_queries, 0) AS read_queries, COALESCE(a.write_queries, 0) AS write_queries,
         COALESCE(a.readers, 0) AS readers, COALESCE(a.writers, 0) AS writers,
         COALESCE(a.tables_read, 0) AS tables_read, COALESCE(a.tables_written, 0) AS tables_written,
         COALESCE(st.live_tables, 0) AS live_tables, COALESCE(st.bytes, 0) AS bytes,
         COALESCE(st.bytes, 0) / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS usd,
         COALESCE(dml.dml_rows, 0) AS dml_rows,
         -- Snowpipe and some service writes are not in ACCESS_HISTORY, so DML rows count as use too
         COALESCE(a.read_queries, 0) + COALESCE(a.write_queries, 0) = 0 AND COALESCE(dml.dml_rows, 0) = 0
           AND sc.created < DATEADD(day, -:period_days, __AS_OF_DATE__) AS never_used,
         seen.access_rows
  FROM sc
  LEFT JOIN a ON a.schema_id = sc.schema_id
  LEFT JOIN st ON st.schema_id = sc.schema_id
  LEFT JOIN dml ON dml.schema_id = sc.schema_id
  CROSS JOIN seen
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, database_name, database_id,
       schema_name, schema_id, schema_owner, created, live_tables, tables_read, tables_written,
       read_queries, write_queries, readers, writers, dml_rows, never_used,
       RANK() OVER (ORDER BY read_queries + write_queries DESC) AS activity_rank,
       SUM(read_queries + write_queries) OVER (PARTITION BY database_id) AS database_queries,
       bytes / POWER(1024, 3) AS storage_gb, usd AS est_storage_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN access_rows = 0 THEN 'access_history_empty_or_not_enterprise'
            WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN access_rows = 0 OR __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN never_used AND usd >= :crit_usd THEN 'CRITICAL'
         WHEN never_used AND usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY activity_rank, est_storage_usd_month DESC NULLS LAST
