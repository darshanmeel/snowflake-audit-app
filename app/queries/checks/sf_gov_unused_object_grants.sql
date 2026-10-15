-- query_id: sf_gov_unused_object_grants
-- title: Table grants that roles in use did not use
-- domain: governance_access   tier: standard
-- windowed: yes
-- entity: roles = role_name
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (Access History)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_grants (default 10) table grants a role must hold before it is judged; :warn_pct (default
--   50) percent of its grants unused at or above which the row reads WARN; :crit_write (default 25) unused
--   INSERT, UPDATE or DELETE grants at or above which it reads CRITICAL
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one role that ran queries in the window x one database it holds table grants in.
--   Only SELECT, INSERT, UPDATE and DELETE on tables and views granted before the window are counted, so
--   a new grant is never called unused. A grant is used when a query run under that role read or wrote the
--   object (ACCESS_HISTORY joined to QUERY_HISTORY's role). An object any query with secondary roles
--   touched counts as used for every role, because the view does not say which role gave the access.
--   unused_grants and unused_write_grants count the rest; unused_share_pct is unused of grants.
--   sample_unused names up to five unused objects. Roles nobody uses are sf_gov_role_hygiene's.
-- healthy: status = OK when the role uses most of what it is granted in this database.
-- investigate_if: WARN when a role with min_grants or more grants left warn_pct percent unused; CRITICAL
--   when crit_write or more unused grants let it change data.
-- actions: 1) revoke the unused write grants first, then the unused reads (free); 2) grant on a schema's
--   future objects only where the role really needs them all (free); 3) split a broad role into a read role
--   and a write role (free)
-- next: sf_gov_role_hygiene, access_broad_grants
-- caveats: heavy: reads ACCESS_HISTORY and QUERY_HISTORY for the window (period_days only), so a grant
--   used monthly or quarterly can read as unused; the window is the export's, not 90 days. Grants to
--   database roles and through role inheritance are not followed. ACCESS_HISTORY lags up to 3 hours.
WITH qr AS (
  SELECT query_id, role_name, secondary_role_stats IS NOT NULL AS has_secondary
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND role_name IS NOT NULL
),
active AS (SELECT DISTINCT role_name FROM qr),
objs AS (
  SELECT ah.query_id, REPLACE(UPPER(o.value:"objectName"::VARCHAR), '"', '') AS object_fqn
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah, LATERAL FLATTEN(input => ah.base_objects_accessed) o
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND ah.query_start_time < __AS_OF_DATE__
  UNION
  SELECT ah.query_id, REPLACE(UPPER(o.value:"objectName"::VARCHAR), '"', '')
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah, LATERAL FLATTEN(input => ah.direct_objects_accessed) o
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND ah.query_start_time < __AS_OF_DATE__
  UNION
  SELECT ah.query_id, REPLACE(UPPER(o.value:"objectName"::VARCHAR), '"', '')
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah, LATERAL FLATTEN(input => ah.objects_modified) o
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND ah.query_start_time < __AS_OF_DATE__
),
used AS (
  SELECT DISTINCT qr.role_name, objs.object_fqn FROM objs JOIN qr ON qr.query_id = objs.query_id
),
used_any AS (
  -- touched by a query with secondary roles: not credited to one role, so never called unused
  SELECT DISTINCT objs.object_fqn FROM objs JOIN qr ON qr.query_id = objs.query_id WHERE qr.has_secondary
),
gr AS (
  SELECT g.grantee_name AS role_name, UPPER(g.table_catalog) AS database_name,
         UPPER(g.table_catalog || '.' || g.table_schema || '.' || g.name) AS object_fqn, UPPER(g.privilege) AS privilege
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
  JOIN active a ON a.role_name = g.grantee_name
  WHERE g.deleted_on IS NULL AND UPPER(g.granted_to) = 'ROLE'
    AND UPPER(g.granted_on) IN ('TABLE', 'VIEW', 'MATERIALIZED_VIEW', 'MATERIALIZED VIEW', 'DYNAMIC_TABLE', 'EXTERNAL_TABLE')
    AND UPPER(g.privilege) IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
    AND g.created_on < DATEADD(day, -:period_days, __AS_OF_DATE__)
),
j AS (
  SELECT gr.*, u.object_fqn IS NOT NULL OR ua.object_fqn IS NOT NULL AS is_used
  FROM gr
  LEFT JOIN used u ON u.role_name = gr.role_name AND u.object_fqn = gr.object_fqn
  LEFT JOIN used_any ua ON ua.object_fqn = gr.object_fqn
),
a AS (
  SELECT role_name, database_name, COUNT(*) AS grants, COUNT_IF(NOT is_used) AS unused_grants,
         COUNT_IF(NOT is_used AND privilege <> 'SELECT') AS unused_write_grants,
         COUNT(DISTINCT object_fqn) AS objects, COUNT(DISTINCT IFF(NOT is_used, object_fqn, NULL)) AS unused_objects,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT IFF(NOT is_used, object_fqn, NULL)), 0, 5), ', ') AS sample_unused
  FROM j
  GROUP BY 1, 2
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, role_name, database_name, grants, unused_grants,
       unused_write_grants, objects, unused_objects, ROUND(100 * unused_grants / NULLIF(grants, 0), 1) AS unused_share_pct,
       NULLIF(sample_unused, '') AS sample_unused,
       IFF(grants >= :min_grants AND unused_grants > 0,
           unused_grants || ' of ' || grants || ' grants unused' || IFF(unused_write_grants > 0, ', ' || unused_write_grants || ' of them writes', ''),
           NULL) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE WHEN grants < :min_grants THEN 'OK'
            WHEN unused_write_grants >= :crit_write THEN 'CRITICAL'
            WHEN 100 * unused_grants / NULLIF(grants, 0) >= :warn_pct THEN 'WARN'
            ELSE 'OK' END AS status
FROM a
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, unused_grants DESC, role_name, database_name
