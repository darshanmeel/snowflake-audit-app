-- query_id: sf_storage_retention_policy
-- title: Time Travel retention above policy
-- domain: storage   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLES, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.DATABASES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :max_retention_days (default 7) retention days: limit above which the row flags; :warn_usd
--   (default 10) usd: at or above this the row reads WARN; :crit_usd (default 100) usd: at or above
--   this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a live database. database_retention_days is its default; the tables_* columns
--   bucket its tables by effective DATA_RETENTION_TIME_IN_DAYS (0, 1, 2-7, 8-30, 31-90).
--   over_policy_tables keep more than max_retention_days; est_storage_usd_month is their Time Travel
--   bytes today and est_saving_usd_month the part above the policy, assuming bytes scale with days.
-- healthy: status = OK when no table keeps more than max_retention_days, or it costs under warn_usd.
-- investigate_if: WARN when over-policy Time Travel costs warn_usd a month or more; CRITICAL when the
--   part above the policy (est_saving_usd_month) is crit_usd or more.
-- actions: 1) agree the retention each data tier needs (e.g. 1 day for staging, 7 for marts) (free); 2)
--   ALTER DATABASE/SCHEMA/TABLE ... SET DATA_RETENTION_TIME_IN_DAYS; set it at database level so new
--   tables inherit it, and keep the account's MIN_DATA_RETENTION_TIME_IN_DAYS low (config); 3) keep
--   long history as explicit snapshots or clones on a schedule instead of long Time Travel
--   (engineering).
-- next: none
-- caveats: savings are proportional estimates; Time Travel bytes depend on churn, not only days.
--   Transient and temporary tables are capped at 1 day by Snowflake. Bytes lag up to 90 minutes.
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
g AS (
  SELECT database_id, MAX(database_name) AS database_name,
         COUNT(*) AS tables_total,
         COUNT_IF(retention_time = 0) AS tables_0d,
         COUNT_IF(retention_time = 1) AS tables_1d,
         COUNT_IF(retention_time BETWEEN 2 AND 7) AS tables_2_7d,
         COUNT_IF(retention_time BETWEEN 8 AND 30) AS tables_8_30d,
         COUNT_IF(retention_time > 30) AS tables_31_90d,
         MAX(retention_time) AS max_table_retention_days,
         COUNT_IF(retention_time > :max_retention_days) AS over_policy_tables,
         SUM(time_travel_bytes) AS time_travel_bytes,
         SUM(IFF(retention_time > :max_retention_days, time_travel_bytes, 0)) AS over_policy_tt_bytes,
         SUM(IFF(retention_time > :max_retention_days,
                 time_travel_bytes * (1 - :max_retention_days / retention_time), 0)) AS excess_tt_bytes,
         LEFT(LISTAGG(IFF(retention_time > :max_retention_days, table_fqn || ' (' || retention_time || 'd)', NULL), ', ')
                WITHIN GROUP (ORDER BY table_fqn), 1000) AS over_policy_examples
  FROM sf_storage_live_tables
  WHERE table_type = 'BASE TABLE'
  GROUP BY database_id
),
t AS (
  SELECT g.*, db.retention_time AS database_retention_days, db.database_owner,
         db.is_transient = 'YES' AS database_is_transient,
         over_policy_tt_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS usd,
         excess_tt_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS saving_usd
  FROM g
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.DATABASES db ON db.database_id = g.database_id AND db.deleted IS NULL
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       database_name, database_id, database_owner, database_is_transient, database_retention_days,
       :max_retention_days AS max_retention_days,
       tables_total, tables_0d, tables_1d, tables_2_7d, tables_8_30d, tables_31_90d,
       max_table_retention_days, over_policy_tables, over_policy_examples,
       time_travel_bytes, over_policy_tt_bytes,
       usd AS est_storage_usd_month, saving_usd AS est_saving_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       over_policy_tables || ' tables keep more than ' || :max_retention_days
         || ' days of Time Travel (max ' || COALESCE(max_table_retention_days, 0) || ')' AS waste_reason,
       CASE WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL AND over_policy_tables > 0 THEN 'unpriced' END
         AS not_assessed_reason,
       CASE
         WHEN over_policy_tables = 0 THEN 'OK'
         WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN saving_usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY over_policy_tt_bytes DESC, over_policy_tables DESC
