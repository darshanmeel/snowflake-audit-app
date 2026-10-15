-- query_id: sf_chg_by_role
-- title: Warehouse spend by role, and roles with no cost owner
-- domain: cost   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 100) usd: at or above this the row reads WARN; :crit_usd (default 1000)
--   usd: at or above this the row reads CRITICAL; :warn_admin_usd (default 50) admin usd: at or above
--   this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one role that ran queries with attributed credits (the query's primary role).
--   credits = exact per-query compute credits; share_pct = its part of all attributed credits.
--   cost_tag_name / cost_tag_value show the cost-center-like tag set on the role, if any; is_admin_role
--   flags system admin roles doing workload work.
-- healthy: status = OK when the role has a cost owner tag or spends little, and admin roles run almost
--   nothing.
-- investigate_if: WARN when an untagged role spends >= warn_usd, or an admin role (ACCOUNTADMIN,
--   SYSADMIN, SECURITYADMIN, USERADMIN, ORGADMIN) spends >= warn_admin_usd; CRITICAL when an untagged
--   role spends >= crit_usd.
-- actions: 1) find the team behind each untagged role (top_users) (free); 2) ALTER ROLE ... SET TAG
--   cost_center = '...' and move workloads off admin roles onto functional roles (config); 3) give
--   heavy roles their own warehouse and resource monitor (config).
-- next: none
-- caveats: secondary roles are not credited; the primary role gets the whole query. Tags are matched by
--   name pattern (COST_CENTER, CHARGEBACK, BUSINESS_UNIT, DEPARTMENT, TEAM, OWNER, PROJECT). Credits
--   exclude warehouse idle time and queries under about 100 ms; lag up to 8 hours.
WITH -- Exact per-query compute credits (QUERY_ATTRIBUTION_HISTORY) with the query's context from
-- QUERY_HISTORY, which the attribution view does not carry (role, database, schema, session, type).
-- QUERY_HISTORY is read one extra day back so a query started just before the window still joins.
-- The join is outer: a query with no QUERY_HISTORY row keeps its credits, with the user, warehouse and
-- tag the attribution view carries itself and '(no query history row)' for the rest.
sf_chg_attr AS (
  SELECT query_id,
         SUM(credits_attributed_compute) AS credits,
         SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits,
         MAX(user_name) AS user_name, MAX(warehouse_name) AS warehouse_name,
         MAX(warehouse_id) AS warehouse_id, MAX(query_tag) AS query_tag, MIN(start_time) AS start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY query_id
),
sf_chg_query_credits AS (
  SELECT a.query_id, COALESCE(q.start_time, a.start_time) AS start_time,
         COALESCE(NULLIF(TRIM(COALESCE(q.user_name, a.user_name)), ''), '(unknown user)') AS user_name,
         IFF(q.query_id IS NULL, '(no query history row)', q.role_name) AS role_name,
         IFF(q.query_id IS NULL, '(no query history row)', q.database_name) AS database_name, q.database_id,
         IFF(q.query_id IS NULL, '(no query history row)', q.schema_name) AS schema_name, q.schema_id,
         COALESCE(q.warehouse_name, a.warehouse_name) AS warehouse_name,
         TO_VARCHAR(COALESCE(q.warehouse_id, a.warehouse_id)) AS warehouse_id,
         COALESCE(q.query_tag, a.query_tag) AS query_tag, q.session_id, q.query_type, a.credits, a.qas_credits
  FROM sf_chg_attr a
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    ON q.query_id = a.query_id
   AND q.start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__)
   AND q.start_time < __AS_OF_DATE__
),
-- The one cost-owner tag per live warehouse, database, user and role, from direct tag references.
-- Tag names are free text, so cost-center-like names are matched by pattern; when an object has
-- several, a COST_CENTER-style name wins over CHARGEBACK/BUSINESS_UNIT/DEPARTMENT, then TEAM/OWNER/PROJECT.
sf_chg_cost_tags AS (
  SELECT domain, UPPER(object_name) AS object_name, object_id,
         tag_database || '.' || tag_schema || '.' || tag_name AS tag_fqn,
         tag_name, tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL
    AND domain IN ('WAREHOUSE', 'DATABASE', 'USER', 'ROLE')
    AND REGEXP_LIKE(UPPER(tag_name),
          '.*(COST_?CENT(ER|RE)|CHARGE_?BACK|BUSINESS_?UNIT|DEPARTMENT|TEAM|OWNER|PROJECT).*')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY domain, UPPER(object_name)
    ORDER BY CASE WHEN REGEXP_LIKE(UPPER(tag_name), '.*COST_?CENT(ER|RE).*') THEN 1
                  WHEN REGEXP_LIKE(UPPER(tag_name), '.*(CHARGE_?BACK|BUSINESS_?UNIT|DEPARTMENT).*') THEN 2
                  ELSE 3 END,
             tag_name) = 1
),
r AS (
  SELECT COALESCE(role_name, '(none)') AS role_name,
         COUNT(*) AS queries, COUNT(DISTINCT user_name) AS distinct_users,
         COUNT(DISTINCT warehouse_name) AS distinct_warehouses,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT user_name), 0, 5), ', ') AS sample_users,
         MODE(warehouse_name) AS main_warehouse_name,
         SUM(credits) AS credits
  FROM sf_chg_query_credits
  GROUP BY 1
),
s AS (
  SELECT r.*, t.tag_fqn AS cost_tag_name, t.tag_value AS cost_tag_value,
         r.role_name IN ('ACCOUNTADMIN', 'SYSADMIN', 'SECURITYADMIN', 'USERADMIN', 'ORGADMIN') AS is_admin_role,
         100 * r.credits / NULLIF(SUM(r.credits) OVER (), 0) AS share_pct,
         r.credits * __CREDIT_PRICE__ AS usd
  FROM r
  LEFT JOIN sf_chg_cost_tags t ON t.domain = 'ROLE' AND t.object_name = UPPER(r.role_name)
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, role_name, is_admin_role,
       cost_tag_name, cost_tag_value, queries, distinct_users, sample_users, distinct_warehouses,
       main_warehouse_name, credits AS attributed_credits, share_pct,
       usd AS est_attributed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cost_tag_value IS NULL AND usd >= :crit_usd THEN 'CRITICAL'
         WHEN cost_tag_value IS NULL AND usd >= :warn_usd THEN 'WARN'
         WHEN is_admin_role AND usd >= :warn_admin_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY credits DESC NULLS LAST
