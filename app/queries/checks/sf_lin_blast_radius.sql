-- query_id: sf_lin_blast_radius
-- title: Tables and views that the most other objects depend on
-- domain: governance_access   tier: standard
-- entity: source objects = source_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :warn_dependents (default 10) dependents: a source with this many objects downstream reads WARN;
--   :crit_dependents (default 30) dependents: a source with this many objects downstream reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live table or view (source_fqn) that at least one other object is built on.
--   direct_dependents are the views, materialized views, dynamic tables and functions that name it;
--   total_dependents adds everything built on those in turn (up to 10 levels, each object counted once,
--   so the count is objects and never edges). dependent_databases counts the databases they live in, so
--   a value above 1 means a change here reaches other teams' databases. max_depth is the longest chain.
-- healthy: status = OK when few objects depend on the source.
-- investigate_if: WARN when total_dependents >= warn_dependents; CRITICAL when it is >= crit_dependents,
--   or the dependents reach more than one database and are at least warn_dependents.
-- actions: 1) before changing or dropping one of these, list its dependents (this row's
--   total_dependents) and tell their owners (free); 2) put the heaviest sources under change review and
--   give them a named owner (config); 3) split a source that too many objects share into a stable
--   interface view and a private table (spend).
-- next: sf_obj_broken_views
-- empty_if: role_cannot_see, no_activity
-- caveats: OBJECT_DEPENDENCIES records declared dependencies (views, materialized views, dynamic tables and
--   functions on tables and views), not who reads a table through a pipeline or a copy; see
--   sf_lin_table_flows for that. It shows only objects the role can see and lags up to 3 hours. A
--   dependency on a dropped object is sf_obj_broken_views, not here.
WITH edges AS (
  SELECT UPPER(referenced_database || '.' || referenced_schema || '.' || referenced_object_name) AS source_fqn,
         UPPER(referencing_database || '.' || referencing_schema || '.' || referencing_object_name) AS dependent_fqn,
         referencing_object_domain AS dependent_domain, referencing_database AS dependent_database
  FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
  WHERE referenced_object_name IS NOT NULL AND referencing_object_name IS NOT NULL
),
reach AS (
  SELECT source_fqn, dependent_fqn, dependent_domain, dependent_database, 1 AS depth
  FROM edges
  UNION ALL
  SELECT r.source_fqn, e.dependent_fqn, e.dependent_domain, e.dependent_database, r.depth + 1
  FROM reach r
  JOIN edges e ON e.source_fqn = r.dependent_fqn
  -- a dependency chain has no cycle; the cap only guards a malformed history
  WHERE r.depth < 10
),
agg AS (
  SELECT source_fqn,
         COUNT(DISTINCT dependent_fqn) AS total_dependents,
         COUNT(DISTINCT IFF(depth = 1, dependent_fqn, NULL)) AS direct_dependents,
         MAX(depth) AS max_depth,
         COUNT(DISTINCT dependent_database) AS dependent_databases,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT dependent_domain), 0, 6), ', ') AS dependent_kinds
  FROM reach
  GROUP BY source_fqn
),
live AS (
  SELECT UPPER(table_catalog || '.' || table_schema || '.' || table_name) AS source_fqn,
         MAX(table_type) AS source_type, MAX(table_owner) AS source_owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  GROUP BY 1
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, a.source_fqn, l.source_type, l.source_owner,
       a.direct_dependents, a.total_dependents, a.max_depth, a.dependent_databases, a.dependent_kinds,
       a.total_dependents || ' objects depend on it, ' || a.direct_dependents || ' directly, across '
         || a.dependent_databases || ' database(s)' AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN a.total_dependents >= :crit_dependents THEN 'CRITICAL'
         WHEN a.total_dependents >= :warn_dependents AND a.dependent_databases > 1 THEN 'CRITICAL'
         WHEN a.total_dependents >= :warn_dependents THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM agg a
JOIN live l ON l.source_fqn = a.source_fqn
ORDER BY a.total_dependents DESC, a.source_fqn
