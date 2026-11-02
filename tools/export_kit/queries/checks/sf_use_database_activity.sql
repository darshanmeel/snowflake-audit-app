-- query_id: sf_use_database_activity
-- title: Most and least used databases and schemas
-- domain: storage   tier: standard
-- entity: databases = database_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA, SNOWFLAKE.ACCOUNT_USAGE.DATABASES,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 10) usd: at or above this the row reads WARN; :crit_usd (default 100) usd:
--   at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live schema (row_level = 'schema') or one database (row_level = 'database'). row_level = 'database' (is_total_row): one row
--   per database, with exact distinct counts at database level (never sums of schema counts); live_tables,
--   storage_gb, dml_rows and est_storage_usd_month are sums of its schemas. read_queries / write_queries /
--   ddl_queries count queries that read a table or view in it (also through views), wrote one (INSERT,
--   MERGE, COPY, CTAS, ...) or ran DDL on its tables, views, the schema itself and, on database rows, the
--   database; self-reads are dropped as on every Activity page. tables_read / tables_written count
--   table-like objects only (views are not counted). readers / writers / active_users are
--   distinct users (active_users over read, write and DDL). dml_rows counts rows changed in
--   TABLE_DML_HISTORY (it also has Snowpipe loads). activity_rank orders rows of the same row_level by
--   read + write queries (1 = busiest); db_activity_rank orders databases by read + write + DDL.
--   database_queries (on schema rows too) is the exact count of distinct read + write queries on the whole
--   database (DDL excluded), not a sum of its schemas' counts.
--   never_used = no read, no write and no DML rows in the window on a schema older than the window; on a
--   database row, every live schema is never used. database_owner and database_type come from DATABASES.
--   est_storage_usd_month prices active + Time Travel + Fail-safe bytes.
-- healthy: status = OK when the schema is read or written, or it is unused but nearly free. Database rows
--   are always OK (or NOT_ASSESSED).
-- investigate_if: WARN when a schema older than the window had no read, write or DML and holds tables
--   costing >= warn_usd a month; CRITICAL at crit_usd. NOT_ASSESSED when ACCESS_HISTORY is empty or the
--   storage price is unknown. Database rows never flag, so nothing is counted twice.
-- actions: 1) ask the schema owner whether the unused schema still feeds anything outside Snowflake
--   (extracts, shares) (free); 2) revoke access for a grace period, then drop it or make it transient
--   (config); 3) archive cold data to external storage (engineering).
-- next: none
-- not_assessed_reasons: access_history_empty_or_not_enterprise: ACCESS_HISTORY has no rows in the window
--   (needs Enterprise edition, or the role cannot read it); unpriced: no storage price is available, so
--   the cost of unused schemas cannot be shown
-- caveats: ACCESS_HISTORY needs Enterprise edition and lags up to 3 hours; reads by data-sharing
--   consumers and replication are not in it. Storage and DML work on all editions. Dropped tables still
--   map to their schema (TABLES keeps them). One row per live schema, not capped: more than 5000 schemas
--   exceeds the UI's 5000-row fetch. Schema rows for the busiest end show where to focus performance
--   work; the least used end is cleanup material. Database rows include events on dropped tables and
--   dropped schemas, so their read / write / DDL query counts need not equal the sum of the live schema
--   rows. A database with no live schema (all dropped, or only INFORMATION_SCHEMA) has no row.
WITH -- ACCESS_HISTORY flattened to one event per query x object x kind (read, write, ddl). Columns: query_id,
-- query_start_time, usage_date, user_name, kind, object_domain, object_id, object_name, is_table_like,
-- ddl_operation. sf_use_access_seen holds access_rows. Only ids, names and the DDL operation, never query text.
sf_use_ah AS (
  SELECT ah.query_id, ah.query_start_time, ah.user_name, ah.base_objects_accessed, ah.direct_objects_accessed,
         ah.objects_modified, ah.object_modified_by_ddl
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
sf_use_raw AS (
  SELECT a.query_id, a.query_start_time, a.user_name, 'read' AS kind,
         UPPER(f.value:"objectDomain"::STRING) AS object_domain, f.value:"objectId"::NUMBER AS object_id,
         UPPER(f.value:"objectName"::STRING) AS object_name, CAST(NULL AS VARCHAR) AS ddl_operation
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'read',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER,
         UPPER(f.value:"objectName"::STRING), CAST(NULL AS VARCHAR)
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.direct_objects_accessed) f
  -- table-like objects are already in base_objects_accessed; views, stages, functions, streams are not
  WHERE UPPER(f.value:"objectDomain"::STRING) NOT IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE',
                                                       'EXTERNAL TABLE', 'MATERIALIZED VIEW')
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'write',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER,
         UPPER(f.value:"objectName"::STRING), CAST(NULL AS VARCHAR)
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.objects_modified) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'ddl',
         UPPER(COALESCE(a.object_modified_by_ddl:"objectDomain"::STRING, 'UNKNOWN')),
         a.object_modified_by_ddl:"objectId"::NUMBER,
         UPPER(a.object_modified_by_ddl:"objectName"::STRING),
         UPPER(a.object_modified_by_ddl:"operationType"::STRING)
  FROM sf_use_ah a
  WHERE a.object_modified_by_ddl IS NOT NULL
),
sf_use_raw_t AS (
  SELECT r.*, r.object_domain IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'EXTERNAL TABLE',
                                  'MATERIALIZED VIEW') AS is_table_like
  FROM sf_use_raw r
),
sf_use_events AS (
  SELECT DISTINCT r.query_id, r.query_start_time, DATE(r.query_start_time) AS usage_date, r.user_name, r.kind,
         r.object_domain, r.object_id, r.object_name, r.is_table_like, r.ddl_operation
  FROM sf_use_raw_t r
  -- a MERGE or INSERT ... SELECT from itself is a write, not a read of its target
  LEFT JOIN sf_use_raw_t w
    ON r.kind = 'read' AND w.kind = 'write' AND w.query_id = r.query_id
   AND w.is_table_like = r.is_table_like AND w.object_id = r.object_id
  WHERE w.query_id IS NULL
),
sf_use_access_seen AS (
  SELECT COUNT(*) AS access_rows FROM sf_use_ah
),
sf_use_access_events AS (
  SELECT * FROM sf_use_events
),
seen AS (
  SELECT access_rows FROM sf_use_access_seen
),
-- dropped tables stay mapped; TABLES keeps one row per version, so take one per table_id (live first, then latest)
tbl AS (
  SELECT table_id, table_schema_id AS schema_id, table_catalog_id AS database_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  QUALIFY ROW_NUMBER() OVER (PARTITION BY table_id
                             ORDER BY IFF(deleted IS NULL, 1, 0) DESC, COALESCE(deleted, last_ddl, created) DESC) = 1
),
scm AS (
  SELECT DISTINCT schema_id, catalog_id AS database_id FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
),
-- every event placed on a schema and database; schema DDL has no table, database DDL has no schema
m AS (
  SELECT t.database_id, t.schema_id, e.query_id, e.user_name, e.kind, e.object_id AS table_id, e.is_table_like AS is_tbl, e.query_start_time
  FROM sf_use_access_events e
  JOIN tbl t ON t.table_id = e.object_id
  WHERE e.is_table_like OR e.object_domain = 'VIEW'
  UNION ALL
  SELECT c.database_id, c.schema_id, e.query_id, e.user_name, e.kind, NULL, FALSE, e.query_start_time
  FROM sf_use_access_events e
  JOIN scm c ON c.schema_id = e.object_id
  WHERE UPPER(e.object_domain) = 'SCHEMA'
  UNION ALL
  SELECT e.object_id, NULL, e.query_id, e.user_name, e.kind, NULL, FALSE, e.query_start_time
  FROM sf_use_access_events e
  WHERE UPPER(e.object_domain) = 'DATABASE'
),
a AS (
  SELECT schema_id,
         COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries,
         COUNT(DISTINCT IFF(kind = 'read', user_name, NULL)) AS readers,
         COUNT(DISTINCT IFF(kind = 'write', user_name, NULL)) AS writers,
         COUNT(DISTINCT user_name) AS active_users,
         COUNT(DISTINCT IFF(kind = 'read' AND is_tbl, table_id, NULL)) AS tables_read,
         COUNT(DISTINCT IFF(kind = 'write' AND is_tbl, table_id, NULL)) AS tables_written,
         MAX(query_start_time) AS last_activity_at
  FROM m
  WHERE schema_id IS NOT NULL
  GROUP BY schema_id
),
-- same events grouped by database: exact distincts, not sums of the schema ones
da AS (
  SELECT database_id,
         COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries,
         COUNT(DISTINCT IFF(kind = 'read', user_name, NULL)) AS readers,
         COUNT(DISTINCT IFF(kind = 'write', user_name, NULL)) AS writers,
         COUNT(DISTINCT user_name) AS active_users,
         COUNT(DISTINCT IFF(kind = 'read' AND is_tbl, table_id, NULL)) AS tables_read,
         COUNT(DISTINCT IFF(kind = 'write' AND is_tbl, table_id, NULL)) AS tables_written,
         MAX(query_start_time) AS last_activity_at
  FROM m
  WHERE database_id IS NOT NULL
  GROUP BY database_id
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
         COALESCE(a.ddl_queries, 0) AS ddl_queries,
         COALESCE(a.readers, 0) AS readers, COALESCE(a.writers, 0) AS writers,
         COALESCE(a.active_users, 0) AS active_users, a.last_activity_at,
         COALESCE(a.tables_read, 0) AS tables_read, COALESCE(a.tables_written, 0) AS tables_written,
         COALESCE(st.live_tables, 0) AS live_tables, COALESCE(st.bytes, 0) AS bytes,
         COALESCE(st.bytes, 0) / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS usd,
         COALESCE(dml.dml_rows, 0) AS dml_rows,
         -- Snowpipe and some service writes are not in ACCESS_HISTORY, so DML rows count as use too
         COALESCE(a.read_queries, 0) + COALESCE(a.write_queries, 0) = 0 AND COALESCE(dml.dml_rows, 0) = 0
           AND sc.created < DATEADD(day, -:period_days, __AS_OF_DATE__) AS never_used
  FROM sc
  LEFT JOIN a ON a.schema_id = sc.schema_id
  LEFT JOIN st ON st.schema_id = sc.schema_id
  LEFT JOIN dml ON dml.schema_id = sc.schema_id
),
dsum AS (
  SELECT database_id, MAX(database_name) AS database_name, SUM(live_tables) AS live_tables, SUM(bytes) AS bytes,
         SUM(usd) AS usd, SUM(dml_rows) AS dml_rows, BOOLAND_AGG(never_used) AS never_used
  FROM s
  GROUP BY database_id
),
dbs AS (
  SELECT database_id, database_owner, type
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES
  WHERE deleted IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY database_id ORDER BY last_altered DESC) = 1
),
rows_all AS (
  SELECT 'schema' AS row_level, FALSE AS is_total_row, s.database_name, s.database_id, s.schema_name, s.schema_id,
         s.schema_owner, s.created, s.live_tables, s.tables_read, s.tables_written, s.read_queries,
         s.write_queries, s.ddl_queries, s.readers, s.writers, s.active_users, s.last_activity_at, s.dml_rows,
         s.never_used, s.bytes, s.usd, CAST(NULL AS VARCHAR) AS database_owner, CAST(NULL AS VARCHAR) AS database_type,
         COALESCE(d.read_queries, 0) + COALESCE(d.write_queries, 0) AS database_queries
  FROM s
  LEFT JOIN da d ON d.database_id = s.database_id
  UNION ALL
  SELECT 'database', TRUE, x.database_name, x.database_id, CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER),
         CAST(NULL AS VARCHAR), CAST(NULL AS TIMESTAMP_LTZ), x.live_tables, COALESCE(d.tables_read, 0),
         COALESCE(d.tables_written, 0), COALESCE(d.read_queries, 0), COALESCE(d.write_queries, 0),
         COALESCE(d.ddl_queries, 0), COALESCE(d.readers, 0), COALESCE(d.writers, 0), COALESCE(d.active_users, 0),
         d.last_activity_at, x.dml_rows, x.never_used, x.bytes, x.usd, db.database_owner, db.type,
         COALESCE(d.read_queries, 0) + COALESCE(d.write_queries, 0)
  FROM dsum x
  LEFT JOIN da d ON d.database_id = x.database_id
  LEFT JOIN dbs db ON db.database_id = x.database_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, database_name, database_id,
       schema_name, schema_id, schema_owner, created, live_tables, tables_read, tables_written,
       read_queries, write_queries, readers, writers, dml_rows, never_used,
       RANK() OVER (PARTITION BY row_level ORDER BY read_queries + write_queries DESC) AS activity_rank,
       database_queries,
       bytes / POWER(1024, 3) AS storage_gb, usd AS est_storage_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN seen.access_rows = 0 THEN 'access_history_empty_or_not_enterprise'
            WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN seen.access_rows = 0 OR __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN row_level = 'database' THEN 'OK'
         WHEN never_used AND usd >= :crit_usd THEN 'CRITICAL'
         WHEN never_used AND usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status,
       row_level, is_total_row, ddl_queries, active_users, last_activity_at, database_owner, database_type,
       IFF(row_level = 'database', RANK() OVER (PARTITION BY row_level
                                                 ORDER BY read_queries + write_queries + ddl_queries DESC), NULL)
         AS db_activity_rank
FROM rows_all
CROSS JOIN seen
ORDER BY IFF(row_level = 'database', 0, 1), activity_rank, est_storage_usd_month DESC NULLS LAST
