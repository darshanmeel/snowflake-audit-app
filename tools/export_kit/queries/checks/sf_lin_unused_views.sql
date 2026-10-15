-- query_id: sf_lin_unused_views
-- title: Views that no query has read and nothing depends on
-- domain: governance_access   tier: standard
-- entity: views = view_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.VIEWS, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (GOVERNANCE_VIEWER); Enterprise edition
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_age_days (default 30) age days: a view younger than this is never listed, it may not have
--   been used yet
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live view that nothing read or depends on in the window. No query read it,
--   directly or through another object, no other live view, dynamic table or materialized view is built
--   on it, and it is older than min_age_days. Views cost no storage, so this is clutter and access surface, not dollars: an old
--   secure view nobody uses is still a door, and a view left over from a migration hides which
--   objects are the real ones. age_days counts from creation; days_since_altered from the last change.
-- healthy: status = OK never appears; no rows means every live view is read or in use.
-- investigate_if: WARN for every listed view; CRITICAL when the view is secure (an exposure that
--   nobody uses).
-- actions: 1) ask the owner (view_owner) whether it is still needed, then drop it (free); 2) if it is
--   kept for a rare report, note that in its comment so the next cleanup skips it (free); 3) run this
--   with a 90 day window before dropping anything (free).
-- next: none
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window (Standard edition, or the
--   role cannot see it), so a view that was read cannot be told from one that was not
-- caveats: reads come from ACCESS_HISTORY (Enterprise edition, up to 3 hours late, 365 days kept), so a
--   window longer than its history reads as unused; on Standard edition this check reads NOT_ASSESSED,
--   never "nothing found". A view read only through a BI tool's extract or a share is invisible here.
--   The role sees only views it can see.
WITH v AS (
  SELECT table_id AS view_id, UPPER(table_catalog || '.' || table_schema || '.' || table_name) AS view_fqn,
         table_catalog AS database_name, table_schema AS schema_name, table_name AS view_name,
         table_owner AS view_owner, is_secure = 'YES' AS is_secure, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.VIEWS
  WHERE deleted IS NULL AND table_catalog <> 'SNOWFLAKE'
),
reads AS (
  SELECT f.value:objectId::NUMBER AS object_id, COUNT(DISTINCT ah.query_id) AS read_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(INPUT => ah.direct_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
  GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS rows_seen
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
),
deps AS (
  SELECT referenced_object_id AS object_id, COUNT(DISTINCT referencing_object_id) AS dependents
  FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
  GROUP BY 1
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, v.view_fqn, v.database_name, v.schema_name,
       v.view_name, v.view_owner, v.is_secure, v.created, v.last_altered,
       DATEDIFF(day, v.created, __AS_OF_DATE__) AS age_days,
       DATEDIFF(day, v.last_altered, __AS_OF_DATE__) AS days_since_altered,
       CASE WHEN v.is_secure THEN 'secure view, unread for ' || :period_days || ' days'
            ELSE 'unread for ' || :period_days || ' days, nothing depends on it' END AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(v.is_secure, 'CRITICAL', 'WARN') AS status
FROM v
CROSS JOIN seen s
LEFT JOIN reads r ON r.object_id = v.view_id
LEFT JOIN deps d ON d.object_id = v.view_id
WHERE s.rows_seen > 0 AND COALESCE(r.read_queries, 0) = 0 AND COALESCE(d.dependents, 0) = 0
  AND v.created < DATEADD(day, -:min_age_days, __AS_OF_DATE__)
UNION ALL
SELECT :period_days, __ACCOUNT_ID__, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN), CAST(NULL AS TIMESTAMP),
       CAST(NULL AS TIMESTAMP), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER),
       'no access history rows in the window, so unread cannot be told from unrecorded', 'no_access_history',
       'NOT_ASSESSED'
FROM seen WHERE rows_seen = 0
ORDER BY status, created
