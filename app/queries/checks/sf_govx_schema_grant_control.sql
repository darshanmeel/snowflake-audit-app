-- query_id: sf_govx_schema_grant_control
-- title: Schemas where object owners hand out access instead of the schema owner
-- domain: governance_access   tier: standard
-- entity: schemas = schema_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :warn_owners (default 3) owners: at or above this the row reads WARN; :warn_grantors (default
--   3) grantors: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live schema that holds objects with grants. is_managed_access is TRUE when
--   only the schema owner (or MANAGE GRANTS) can grant on its objects. object_owners counts roles
--   owning objects in it other than the schema owner; grantors counts roles that granted privileges on
--   its objects; sensitive_objects counts tables and views with a column tagged sensitive.
-- healthy: status = OK when the schema is managed access, or one role owns and grants everything in it.
-- investigate_if: WARN when a regular schema has :warn_owners+ other owning roles or :warn_grantors+
--   grantors (access is decided object by object, by whoever created it); CRITICAL when such a schema
--   also holds sensitive-tagged objects.
-- actions: 1) ALTER SCHEMA ... ENABLE MANAGED ACCESS so grants go through the schema owner (config); 2)
--   GRANT OWNERSHIP ON ALL ... IN SCHEMA to one functional role, COPY CURRENT GRANTS (free); 3) use
--   future grants on the schema instead of per-object grants (config)
-- next: none
-- caveats: future grants (SHOW FUTURE GRANTS IN SCHEMA) are not in ACCOUNT_USAGE, so a schema run
--   purely on future grants shows few grantors; SNOWFLAKE and INFORMATION_SCHEMA are left out. Lags up
--   to 2 hours.
WITH __INCLUDE_sf_gov_sensitive_columns__,
sch AS (
  SELECT catalog_name AS database_name, schema_name, schema_owner, is_managed_access = 'YES' AS is_managed_access
  FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
  WHERE deleted IS NULL AND schema_name <> 'INFORMATION_SCHEMA' AND catalog_name <> 'SNOWFLAKE'
),
g AS (
  SELECT table_catalog AS database_name, table_schema AS schema_name, name AS object_name, privilege,
         grantee_name, granted_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL AND table_schema IS NOT NULL
    AND granted_on NOT IN ('SCHEMA', 'DATABASE', 'ACCOUNT')
),
sensitive AS (
  SELECT database_name, schema_name, COUNT(DISTINCT table_name) AS sensitive_objects
  FROM sf_gov_sensitive_tagged
  GROUP BY 1, 2
),
agg AS (
  SELECT g.database_name, g.schema_name,
         COUNT(DISTINCT g.object_name) AS objects,
         COUNT(DISTINCT IFF(g.privilege = 'OWNERSHIP' AND g.grantee_name <> s.schema_owner, g.grantee_name, NULL)) AS object_owners,
         LISTAGG(DISTINCT IFF(g.privilege = 'OWNERSHIP' AND g.grantee_name <> s.schema_owner, g.grantee_name, NULL), ', ') AS object_owner_roles,
         COUNT(DISTINCT IFF(g.privilege <> 'OWNERSHIP', g.granted_by, NULL)) AS grantors,
         LISTAGG(DISTINCT IFF(g.privilege <> 'OWNERSHIP', g.granted_by, NULL), ', ') AS grantor_roles,
         COUNT_IF(g.privilege <> 'OWNERSHIP') AS object_grants
  FROM g
  JOIN sch s ON s.database_name = g.database_name AND s.schema_name = g.schema_name
  GROUP BY 1, 2
),
j AS (
  SELECT s.*, a.objects, a.object_owners, NULLIF(a.object_owner_roles, '') AS object_owner_roles, a.grantors,
         NULLIF(a.grantor_roles, '') AS grantor_roles, a.object_grants,
         COALESCE(t.sensitive_objects, 0) AS sensitive_objects,
         (NOT s.is_managed_access AND (a.object_owners >= :warn_owners OR a.grantors >= :warn_grantors)) AS decentralised
  FROM sch s
  JOIN agg a ON a.database_name = s.database_name AND a.schema_name = s.schema_name
  LEFT JOIN sensitive t ON t.database_name = UPPER(s.database_name) AND t.schema_name = UPPER(s.schema_name)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name,
       database_name || '.' || schema_name AS schema_fqn, schema_owner, is_managed_access, objects, object_owners,
       object_owner_roles, grantors, grantor_roles, object_grants, sensitive_objects,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NOT is_managed_access, 'not managed access', NULL),
         IFF(object_owners >= :warn_owners, object_owners || ' other roles own objects', NULL),
         IFF(grantors >= :warn_grantors, grantors || ' roles granted access', NULL),
         IFF(sensitive_objects > 0, sensitive_objects || ' objects with sensitive columns', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN decentralised AND sensitive_objects > 0 THEN 'CRITICAL'
         WHEN decentralised THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, grantors DESC, object_owners DESC
