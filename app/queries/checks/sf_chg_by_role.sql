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
WITH __INCLUDE_sf_chg_query_credits__,
__INCLUDE_sf_chg_cost_tags__,
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
