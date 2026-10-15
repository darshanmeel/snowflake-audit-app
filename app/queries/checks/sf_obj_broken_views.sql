-- query_id: sf_obj_broken_views
-- title: Views and functions that point at dropped objects
-- domain: governance_access   tier: standard
-- entity: views = object_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS, SNOWFLAKE.ACCOUNT_USAGE.DATABASES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live view, materialized view, dynamic table or SQL function (referencing)
--   whose recorded dependency (referenced) no longer exists under that name: the table, view or
--   function was dropped or renamed and nothing was recreated in its place, so querying the referencing
--   object fails. missing_refs lists every missing name; dependents counts live objects that in turn
--   reference the broken one, which break with it.
-- healthy: status = OK is not used: an object listed here is broken; no rows is healthy.
-- investigate_if: WARN for every broken object; CRITICAL when other live objects depend on it (the
--   failure cascades to them).
-- actions: 1) ask the owner whether the object is still needed; drop it if not (free); 2) repoint the
--   definition to the renamed or replacement object, or UNDROP the table while it is still in Time
--   Travel (config); 3) add a CI step that compiles views after schema changes (engineering).
-- next: none
-- caveats: OBJECT_DEPENDENCIES lags up to 3 hours and records only name-resolved dependencies; objects
--   in databases shared to this account and in the SNOWFLAKE database are ignored, because they are not
--   listed in TABLES. A dependency on a stage, stream or sequence is not checked.
WITH live_objects AS (
  SELECT UPPER(table_catalog || '.' || table_schema || '.' || table_name) AS name_key, table_id AS object_id,
         table_type AS object_type, table_owner AS object_owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  UNION ALL
  SELECT UPPER(function_catalog || '.' || function_schema || '.' || function_name), function_id,
         'FUNCTION', function_owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS
  WHERE deleted IS NULL
),
-- Databases whose objects TABLES lists (local ones), plus every database that exists at all.
local_dbs AS (
  SELECT DISTINCT UPPER(table_catalog) AS db_key FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES WHERE deleted IS NULL
),
live_dbs AS (
  SELECT DISTINCT UPPER(database_name) AS db_key FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES WHERE deleted IS NULL
),
dep AS (
  SELECT d.referencing_object_id, d.referencing_object_domain,
         d.referencing_database || '.' || d.referencing_schema || '.' || d.referencing_object_name AS referencing_fqn,
         d.referencing_database, d.referencing_schema, d.referencing_object_name,
         d.referenced_database,
         d.referenced_database || '.' || d.referenced_schema || '.' || d.referenced_object_name AS referenced_fqn,
         d.referenced_object_domain, d.dependency_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES d
  WHERE UPPER(d.referenced_database) <> 'SNOWFLAKE'
    AND UPPER(d.referenced_object_domain) IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'SECURE VIEW',
        'EXTERNAL TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'FUNCTION', 'SECURE FUNCTION')
),
broken AS (
  SELECT dep.*, ro.object_type AS referencing_type, ro.object_owner AS referencing_owner
  FROM dep
  JOIN live_objects ro ON ro.object_id = dep.referencing_object_id
                      AND ro.name_key = UPPER(dep.referencing_fqn)
  LEFT JOIN live_objects rd ON rd.name_key = UPPER(dep.referenced_fqn)
  LEFT JOIN local_dbs ld ON ld.db_key = UPPER(dep.referenced_database)
  LEFT JOIN live_dbs lv ON lv.db_key = UPPER(dep.referenced_database)
  WHERE rd.name_key IS NULL
    AND (ld.db_key IS NOT NULL OR lv.db_key IS NULL)
),
agg AS (
  SELECT referencing_object_id, MAX(referencing_fqn) AS referencing_fqn,
         MAX(referencing_database) AS database_name, MAX(referencing_schema) AS schema_name,
         MAX(referencing_object_name) AS object_name, MAX(referencing_type) AS object_type,
         MAX(referencing_owner) AS object_owner,
         COUNT(DISTINCT referenced_fqn) AS missing_count,
         LISTAGG(DISTINCT referenced_fqn || ' (' || LOWER(referenced_object_domain) || ')', ', ')
           WITHIN GROUP (ORDER BY referenced_fqn || ' (' || LOWER(referenced_object_domain) || ')') AS missing_refs
  FROM broken
  GROUP BY referencing_object_id
),
downstream AS (
  SELECT d.referenced_object_id, COUNT(DISTINCT d.referencing_object_id) AS dependents
  FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES d
  JOIN live_objects lo ON lo.object_id = d.referencing_object_id
  GROUP BY 1
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       a.referencing_fqn AS object_fqn, TO_VARCHAR(a.referencing_object_id) AS object_id,
       a.database_name, a.schema_name, a.object_name, a.object_type, a.object_owner,
       a.missing_count, a.missing_refs, COALESCE(ds.dependents, 0) AS dependents,
       'references ' || a.missing_count || ' missing object(s): ' || a.missing_refs AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(COALESCE(ds.dependents, 0) > 0, 'CRITICAL', 'WARN') AS status
FROM agg a
LEFT JOIN downstream ds ON ds.referenced_object_id = a.referencing_object_id
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 ELSE 1 END, dependents DESC, object_fqn
