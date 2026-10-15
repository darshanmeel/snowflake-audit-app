-- query_id: sf_share_inbound_databases
-- title: Databases from inbound shares and installed apps: who reads them
-- domain: governance_access   tier: standard
-- windowed: yes
-- pre: SHOW DATABASES
-- reads: SHOW DATABASES, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one database created from a share another account provides (kind IMPORTED
--   DATABASE; origin = provider.share) or an installed Native App (kind APPLICATION). read_queries and
--   readers count queries and users that read objects in it (ACCESS_HISTORY); context_queries counts
--   queries run with it as the current database. granted_roles lists roles holding a privilege on it.
-- healthy: status = OK when someone reads the database and access is limited to named roles.
-- investigate_if: WARN when no query read it in the window (older than the window), or PUBLIC holds a
--   privilege on it (every user can read third-party data).
-- actions: 1) confirm with the owner that the share is still needed; drop an unused imported database
--   (DROP DATABASE removes only the local mount) and ask the provider to stop sharing (free); 2) grant
--   IMPORTED PRIVILEGES to a functional role, not PUBLIC (config); 3) cancel paid listings nobody reads
--   (spend).
-- next: none
-- caveats: SHOW DATABASES lists databases the export role can see. ACCESS_HISTORY needs Enterprise
--   Edition; with no ACCESS_HISTORY rows unused is not judged. Reads through a Native App's own
--   procedures or Streamlit are not attributed to its database. Paid listing fees are not in
--   ACCOUNT_USAGE and are not shown.
WITH d AS (
  SELECT "name" AS database_name, "kind" AS kind, "origin" AS origin, "owner" AS database_owner,
         CAST("created_on" AS TIMESTAMP_LTZ) AS created_on, "comment" AS comment
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
  WHERE UPPER("kind") IN ('IMPORTED DATABASE', 'APPLICATION')
),
ah AS (
  SELECT ah.query_id, ah.user_name, ah.query_start_time,
         UPPER(SPLIT_PART(f.value:objectName::STRING, '.', 1)) AS db_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.direct_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
reads AS (
  SELECT db_key, COUNT(DISTINCT query_id) AS read_queries, COUNT(DISTINCT user_name) AS readers,
         MAX(query_start_time) AS last_read_at
  FROM ah GROUP BY db_key
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM ah
),
ctx AS (
  SELECT UPPER(database_name) AS db_key, COUNT(*) AS context_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND database_name IS NOT NULL
  GROUP BY 1
),
gr AS (
  SELECT UPPER(name) AS db_key,
         LISTAGG(DISTINCT grantee_name, ', ') WITHIN GROUP (ORDER BY grantee_name) AS granted_roles,
         COUNT_IF(grantee_name = 'PUBLIC') > 0 AS public_access
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE granted_on = 'DATABASE' AND deleted_on IS NULL
  GROUP BY 1
),
j AS (
  SELECT d.*, COALESCE(r.read_queries, 0) AS read_queries, COALESCE(r.readers, 0) AS readers,
         r.last_read_at, COALESCE(c.context_queries, 0) AS context_queries,
         gr.granted_roles, COALESCE(gr.public_access, FALSE) AS public_access,
         (COALESCE(r.read_queries, 0) = 0 AND COALESCE(c.context_queries, 0) = 0
          AND d.created_on < DATEADD(day, -:period_days, __AS_OF_DATE__)) AS unused,
         seen.access_rows
  FROM d
  LEFT JOIN reads r ON r.db_key = UPPER(d.database_name)
  LEFT JOIN ctx c ON c.db_key = UPPER(d.database_name)
  LEFT JOIN gr ON gr.db_key = UPPER(d.database_name)
  CROSS JOIN seen
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       database_name, kind, origin, SPLIT_PART(origin, '.', 1) || '.' || SPLIT_PART(origin, '.', 2) AS provider_account,
       database_owner, created_on, read_queries, readers, last_read_at, context_queries,
       granted_roles, public_access,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(access_rows > 0 AND unused, 'not read in ' || :period_days || ' days', NULL),
         IFF(public_access, 'PUBLIC holds a privilege on it', NULL)), '; ') AS reasons,
       CASE WHEN access_rows = 0 THEN 'no_access_history' END AS not_assessed_reason,
       CASE
         WHEN public_access THEN 'WARN'
         WHEN access_rows = 0 THEN 'NOT_ASSESSED'
         WHEN unused THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, read_queries
