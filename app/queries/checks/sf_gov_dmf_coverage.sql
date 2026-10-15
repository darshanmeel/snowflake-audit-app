-- query_id: sf_gov_dmf_coverage
-- title: Tables watched by a data metric function, per database
-- domain: governance_access   tier: standard
-- entity: databases = database_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (data metric functions, tags)
-- params: :min_tables (default 10) tables: a database with fewer is not flagged for low coverage; :warn_pct
--   (default 10) percent: coverage below this flags
-- empty_if: edition_too_low, role_cannot_see
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. How a schema-level association is listed (which entity name it
--   carries) is not stated in the docs, so it is matched on database and schema only.
-- read_this: one row = one database. base_tables is every live base table; covered_tables those with a data
--   metric function attached to the table or to its schema; active_tables those with a schedule that is running.
--   sensitive_tables counts tables with a column tagged sensitive, and sensitive_uncovered those with no
--   function. The cost of the functions is on the observability cost page, not here.
-- healthy: status = OK when data quality monitoring is not used in the account, or the database is small or
--   covered, and its sensitive tables are covered.
-- investigate_if: WARN when the account uses data metric functions and a database with :min_tables tables or
--   more has coverage under :warn_pct percent, all its functions are suspended, or a sensitive table has none.
-- actions: 1) attach NULL_COUNT, DUPLICATE_COUNT or FRESHNESS to the tables that feed reports, starting with the
--   sensitive ones (config); 2) resume suspended schedules or drop the association (free); 3) set the schedule
--   on the table (TRIGGER_ON_CHANGES or a cron) so it costs only when data changes (config)
-- next: sf_acct_observability_cost
-- caveats: An account with no data metric function at all reads OK on every row: it does not use the feature.
--   Views are not counted as tables. Tables in shared or imported databases may be missing from TABLES. The
--   function text is never read. ACCOUNT_USAGE lags up to 3 hours.
WITH __INCLUDE_sf_gov_sensitive_columns__,
t AS (
  SELECT UPPER(tb.table_catalog) AS db_key, tb.table_catalog AS database_name, UPPER(tb.table_schema) AS sch_key,
         UPPER(tb.table_name) AS tbl_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES tb
  WHERE tb.deleted IS NULL AND tb.table_type = 'BASE TABLE' AND UPPER(tb.table_catalog) <> 'SNOWFLAKE'
),
d AS (
  SELECT UPPER(ref_database_name) AS db_key, UPPER(ref_schema_name) AS sch_key, UPPER(ref_entity_name) AS tbl_key,
         UPPER(COALESCE(level, 'TABLE')) AS lvl, BOOLOR_AGG(UPPER(COALESCE(schedule_status, '')) LIKE 'STARTED%') AS started
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_REFERENCES
  GROUP BY 1, 2, 3, 4
),
dt AS (SELECT db_key, sch_key, tbl_key, started FROM d WHERE lvl = 'TABLE'),
ds AS (SELECT db_key, sch_key, BOOLOR_AGG(started) AS started FROM d WHERE lvl = 'SCHEMA' GROUP BY 1, 2),
sens AS (
  SELECT DISTINCT UPPER(database_name) AS db_key, UPPER(schema_name) AS sch_key, UPPER(table_name) AS tbl_key
  FROM sf_gov_sensitive_columns
),
uses AS (
  SELECT COUNT(*) > 0 AS account_uses_dmf FROM d
),
tt AS (
  SELECT t.db_key, t.database_name,
         dt.tbl_key IS NOT NULL OR ds.sch_key IS NOT NULL AS covered,
         COALESCE(dt.started, FALSE) OR COALESCE(ds.started, FALSE) AS active,
         sens.tbl_key IS NOT NULL AS is_sensitive
  FROM t
  LEFT JOIN dt ON dt.db_key = t.db_key AND dt.sch_key = t.sch_key AND dt.tbl_key = t.tbl_key
  LEFT JOIN ds ON ds.db_key = t.db_key AND ds.sch_key = t.sch_key
  LEFT JOIN sens ON sens.db_key = t.db_key AND sens.sch_key = t.sch_key AND sens.tbl_key = t.tbl_key
),
a AS (
  SELECT db_key, MAX(database_name) AS database_name, COUNT(*) AS base_tables, COUNT_IF(covered) AS covered_tables,
         COUNT_IF(active) AS active_tables, COUNT_IF(is_sensitive) AS sensitive_tables,
         COUNT_IF(is_sensitive AND NOT covered) AS sensitive_uncovered
  FROM tt
  GROUP BY db_key
),
s AS (
  SELECT a.*, 100 * covered_tables / NULLIF(base_tables, 0) AS coverage_pct, u.account_uses_dmf,
         u.account_uses_dmf AND base_tables >= :min_tables AND 100 * covered_tables / NULLIF(base_tables, 0) < :warn_pct AS low,
         u.account_uses_dmf AND covered_tables > 0 AND active_tables = 0 AS all_suspended,
         u.account_uses_dmf AND sensitive_uncovered > 0 AS sensitive_gap
  FROM a CROSS JOIN uses u
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, base_tables, covered_tables, active_tables,
       coverage_pct, sensitive_tables, sensitive_uncovered,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NOT account_uses_dmf, 'no data metric function in the account', NULL),
         IFF(low, covered_tables || ' of ' || base_tables || ' tables covered', NULL),
         IFF(all_suspended, 'every function is suspended', NULL),
         IFF(sensitive_gap, sensitive_uncovered || ' sensitive tables with no function', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(low OR all_suspended OR sensitive_gap, 'WARN', 'OK') AS status
FROM s
ORDER BY IFF(low OR all_suspended OR sensitive_gap, 0, 1), base_tables DESC, database_name
