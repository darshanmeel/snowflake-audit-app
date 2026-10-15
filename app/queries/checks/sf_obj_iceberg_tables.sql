-- query_id: sf_obj_iceberg_tables
-- title: Iceberg tables: catalog, external volume and freshness
-- domain: storage   tier: standard
-- windowed: yes
-- pre: SHOW ICEBERG TABLES IN ACCOUNT
-- reads: SHOW ICEBERG TABLES IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :stale_days (default 7) stale days: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one Iceberg table. catalog_name = SNOWFLAKE means Snowflake manages the
--   metadata; any other value is an external catalog (Glue, Open Catalog / Polaris, object store) and
--   the table only shows new data after a refresh (auto_refresh or ALTER ICEBERG TABLE ... REFRESH).
--   external_volume_name / base_location say where the files live: that storage is billed by your cloud
--   provider, not by Snowflake. days_since_change is from TABLES.last_altered.
-- healthy: status = OK when auto-refresh is running or the table changed within stale_days.
-- investigate_if: WARN when an externally managed table has no auto-refresh and has not changed in
--   stale_days (queries may read an old snapshot), or nobody read it in the window; CRITICAL when
--   auto-refresh is set up but its state is not RUNNING (catalog integration, volume or metadata
--   file broken).
-- actions: 1) fix the catalog integration / external volume of tables whose refresh stopped (config); 2) turn on
--   AUTO_REFRESH for externally managed tables that must be current, or schedule a refresh (config); 3)
--   drop unread tables; the files stay in your bucket until you delete them (free).
-- next: none
-- caveats: SHOW ICEBERG TABLES lists what the export role can see. It has no invalid flag, so refresh
--   health comes from auto_refresh_status (external tables only). Auto-refresh and Snowflake-managed compaction
--   credits are not split out here. ACCESS_HISTORY needs Enterprise Edition.
WITH i AS (
  SELECT "database_name" AS database_name, "schema_name" AS schema_name, "name" AS table_name,
         "database_name" || '.' || "schema_name" || '.' || "name" AS table_fqn,
         "owner" AS table_owner, "catalog_name" AS catalog_name,
         "iceberg_table_type" AS iceberg_table_type,
         "catalog_table_name" AS catalog_table_name, "catalog_namespace" AS catalog_namespace,
         "external_volume_name" AS external_volume_name, "base_location" AS base_location,
         -- auto_refresh_status is the JSON of SYSTEM$AUTO_REFRESH_STATUS, set for external tables only.
         UPPER(GET(TRY_PARSE_JSON("auto_refresh_status"), 'executionState')::VARCHAR) AS refresh_state,
         CAST("created_on" AS TIMESTAMP_LTZ) AS created_on
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
t AS (
  SELECT UPPER(table_catalog || '.' || table_schema || '.' || table_name) AS name_key,
         MAX(table_id) AS table_id, MAX(row_count) AS row_count, MAX(bytes) AS bytes,
         MAX(last_altered) AS last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL AND is_iceberg = 'YES'
  GROUP BY 1
),
-- Direct plus base objects, matched by id (a rename keeps reads) and by name when TABLES has no row,
-- the same read count sf_obj_iceberg_compaction_cost shows.
ah AS (
  SELECT ah.query_id, ah.query_start_time, f.value:"objectId"::NUMBER AS table_id,
         UPPER(f.value:"objectName"::STRING) AS name_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT()))) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
reads AS (
  SELECT table_id, COUNT(DISTINCT query_id) AS read_queries, MAX(query_start_time) AS last_read_at
  FROM ah WHERE table_id IS NOT NULL GROUP BY 1
),
reads_by_name AS (
  SELECT name_key, COUNT(DISTINCT query_id) AS read_queries, MAX(query_start_time) AS last_read_at
  FROM ah GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM ah
),
j AS (
  SELECT i.*, t.table_id, t.row_count, t.bytes, t.last_altered,
         DATEDIFF(day, COALESCE(t.last_altered, i.created_on), LEAST(CURRENT_TIMESTAMP(), CAST(__AS_OF_DATE__ AS TIMESTAMP))) AS days_since_change,
         UPPER(COALESCE(i.catalog_name, 'SNOWFLAKE')) <> 'SNOWFLAKE' AS externally_managed,
         COALESCE(r.read_queries, rn.read_queries, 0) AS read_queries,
         COALESCE(r.last_read_at, rn.last_read_at) AS last_read_at, seen.access_rows,
         (seen.access_rows > 0 AND r.table_id IS NULL AND rn.name_key IS NULL
          AND i.created_on < DATEADD(day, -:period_days, __AS_OF_DATE__)) AS unread
  FROM i
  LEFT JOIN t ON t.name_key = UPPER(i.table_fqn)
  LEFT JOIN reads r ON r.table_id = t.table_id
  LEFT JOIN reads_by_name rn ON t.table_id IS NULL AND rn.name_key = UPPER(i.table_fqn)
  CROSS JOIN seen
),
scored AS (
  SELECT j.*, refresh_state IS NOT NULL AS auto_refresh,
         (refresh_state IS NOT NULL AND refresh_state <> 'RUNNING') AS refresh_stopped,
         (externally_managed AND refresh_state IS NULL AND days_since_change >= :stale_days) AS maybe_stale
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_id, table_name, database_name, schema_name, table_owner, catalog_name,
       iceberg_table_type, externally_managed, catalog_namespace, catalog_table_name,
       external_volume_name, base_location, auto_refresh, refresh_state, created_on,
       last_altered, days_since_change, row_count, bytes / POWER(1024, 3) AS gb, read_queries, last_read_at,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(refresh_stopped, 'auto-refresh is ' || LOWER(refresh_state), NULL),
         IFF(maybe_stale, 'external catalog, auto-refresh off, unchanged ' || days_since_change || ' days', NULL),
         IFF(unread, 'not read in ' || :period_days || ' days', NULL)), '; ') AS reasons,
       CASE WHEN access_rows = 0 THEN 'no_access_history' END AS not_assessed_reason,
       CASE
         WHEN refresh_stopped THEN 'CRITICAL'
         WHEN maybe_stale OR unread THEN 'WARN'
         WHEN access_rows = 0 THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, table_fqn
