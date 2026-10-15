-- query_id: sf_storage_unused_tables
-- title: Tables nobody has read
-- domain: storage   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :idle_days (default 90) idle days: value this check uses; :min_gb (default 1) gb: least a row
--   needs before it can flag; :warn_usd (default 10) usd: at or above this the row reads WARN;
--   :crit_usd (default 100) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a live table of at least min_gb, older than idle_days, that no query read
--   (directly or through a view) in the last idle_days. still_written = TRUE means a pipeline keeps
--   loading it (last_altered inside the window) although nothing reads it, so it costs compute too.
--   last_write_at is the last query that wrote it (ACCESS_HISTORY objects_modified) in the window;
--   written_in_window = TRUE when either source shows a write, FALSE = neither read nor written,
--   NULL when the table has no TABLES row and ACCESS_HISTORY shows no write (unknown).
--   est_storage_usd_month counts active, Time Travel and Fail-safe bytes; est_saving_usd_month is what dropping it saves (flagged rows).
-- healthy: status = OK when the unread table costs less than warn_usd a month.
-- investigate_if: WARN when an unread table costs warn_usd a month or more; CRITICAL at crit_usd.
-- actions: 1) ask the owner (table_owner) and check downstream tools that read via extracts or shares
--   (free); 2) drop it, or first rename/revoke access for a grace period; for still_written tables stop
--   the job that loads them (config); 3) for data kept for compliance, unload it to cheaper external
--   storage and drop the table (engineering).
-- next: none
-- caveats: ACCESS_HISTORY needs Enterprise Edition and keeps 365 days; with no rows at all the check is
--   NOT_ASSESSED. Reads by data sharing consumers and replication are not in ACCESS_HISTORY. Clones
--   are left out (their home is sf_use_unused_clones); a source table shares bytes with its clones, so
--   dropping it may free less than shown.
WITH -- Live tables with their current storage split: TABLE_STORAGE_METRICS holds the bytes, TABLES the
-- settings. The YES/NO text flags are turned into booleans so every storage check reads them alike.
sf_storage_live_tables AS (
  SELECT m.id AS table_id, m.table_catalog AS database_name, m.table_catalog_id AS database_id,
         m.table_schema AS schema_name, m.table_schema_id AS schema_id, m.table_name,
         m.table_catalog || '.' || m.table_schema || '.' || m.table_name AS table_fqn,
         m.clone_group_id,
         COALESCE(m.active_bytes, 0) AS active_bytes,
         COALESCE(m.time_travel_bytes, 0) AS time_travel_bytes,
         COALESCE(m.failsafe_bytes, 0) AS failsafe_bytes,
         COALESCE(m.retained_for_clone_bytes, 0) AS retained_for_clone_bytes,
         COALESCE(m.active_bytes, 0) + COALESCE(m.time_travel_bytes, 0) + COALESCE(m.failsafe_bytes, 0)
           + COALESCE(m.retained_for_clone_bytes, 0) AS total_bytes,
         -- no TABLES row would make this NULL and drop the table from NOT is_transient filters
         COALESCE(m.is_transient = 'YES' OR t.is_transient = 'YES', m.is_transient = 'YES', FALSE) AS is_transient,
         COALESCE(t.table_type, 'BASE TABLE') AS table_type,
         t.retention_time, t.clustering_key,
         COALESCE(t.auto_clustering_on = 'YES', FALSE) AS auto_clustering_on,
         COALESCE(t.is_iceberg = 'YES', FALSE) AS is_iceberg,
         COALESCE(t.is_dynamic = 'YES', FALSE) AS is_dynamic,
         COALESCE(t.is_hybrid = 'YES', FALSE) AS is_hybrid,
         t.row_count, t.bytes AS table_bytes, t.table_owner, t.created, t.last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS m
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t ON t.table_id = m.id AND t.deleted IS NULL
  -- Fail-safe rows have NULL names (and can carry deleted = FALSE): they are not live tables.
  WHERE NOT COALESCE(m.deleted, FALSE) AND m.table_dropped IS NULL
    AND m.schema_dropped IS NULL AND m.catalog_dropped IS NULL
    AND m.table_name IS NOT NULL AND m.table_entered_failsafe IS NULL
),
reads AS (
  SELECT f.value:objectId::NUMBER AS table_id, MAX(ah.query_start_time) AS last_read_at
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.base_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:idle_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
  GROUP BY 1
),
-- writes seen in ACCESS_HISTORY; last_altered covers loads it leaves out (e.g. Snowpipe)
writes AS (
  SELECT f.value:objectId::NUMBER AS table_id, MAX(ah.query_start_time) AS last_write_at
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.objects_modified) f
  WHERE ah.query_start_time >= DATEADD(day, -:idle_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
    -- base tables only (unused_tables lists BASE TABLE rows); the docs spell the domain in mixed case
    AND UPPER(f.value:"objectDomain"::STRING) IN ('TABLE', 'ICEBERG TABLE')
  GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS objects_read FROM reads
),
t AS (
  SELECT lt.*,
         total_bytes / POWER(1024, 3) AS total_gb,
         (active_bytes + time_travel_bytes + failsafe_bytes) / POWER(1024, 4)
           * __STORAGE_PRICE_TB_MONTH__ AS usd,
         lt.last_altered >= DATEADD(day, -:idle_days, __AS_OF_DATE__) AS still_written,
         DATEDIFF(day, lt.created, __AS_OF_DATE__) AS age_days,
         w.last_write_at
  FROM sf_storage_live_tables lt
  LEFT JOIN reads r ON r.table_id = lt.table_id
  LEFT JOIN writes w ON w.table_id = lt.table_id
  WHERE r.table_id IS NULL
    AND lt.table_type = 'BASE TABLE'
    -- a clone is judged in sf_use_unused_clones, so its saving is not counted twice
    AND (lt.clone_group_id IS NULL OR lt.clone_group_id = lt.table_id)
    AND lt.total_bytes >= :min_gb * POWER(1024, 3)
    AND COALESCE(lt.created, '1970-01-01'::TIMESTAMP_LTZ) < DATEADD(day, -:idle_days, __AS_OF_DATE__)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_id, database_name, schema_name, table_name, table_owner, is_transient,
       row_count, created, age_days, last_altered, still_written, :idle_days AS idle_days,
       CAST(NULL AS TIMESTAMP_LTZ) AS last_read_at, last_write_at,
       -- NULL when neither source can say (no ACCESS_HISTORY write and no TABLES row), never a false FALSE
       CASE WHEN last_write_at IS NOT NULL OR still_written THEN TRUE
            WHEN still_written IS NULL THEN NULL ELSE FALSE END AS written_in_window,
       active_bytes, time_travel_bytes, failsafe_bytes, total_gb,
       usd AS est_storage_usd_month, usd AS est_saving_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(total_gb, 1) || ' GB not read in ' || :idle_days || ' days'
         || IFF(still_written, ' but still loaded', '') AS waste_reason,
       CASE WHEN s.objects_read = 0 THEN 'no_access_history'
            WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN s.objects_read = 0 OR __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t CROSS JOIN seen s
ORDER BY total_bytes DESC
