-- query_id: sf_sec_failover_readiness
-- shims: REPLICATION_GROUPS, NETWORK_POLICIES
-- reads: INFORMATION_SCHEMA table functions SHOW REPLICATION GROUPS, SHOW NETWORK POLICIES
-- fallback_note: live groups in this account only; live network policies only; no IP lists (SHOW gives only their counts); the name stands in for the id
-- pre: SHOW REPLICATION GROUPS
WITH g AS (
  SELECT name AS group_name, UPPER(type) AS group_type, UPPER(COALESCE(object_types, '')) AS object_types,
         replication_schedule, error_integration
  FROM __SHIM_REPLICATION_GROUPS__
  WHERE deleted IS NULL
),
sh AS (
  SELECT "name" AS group_name, BOOLOR_AGG(LOWER(TO_VARCHAR("is_primary")) = 'true') AS is_primary,
         MAX(IFF(NULLIF(TRIM("allowed_accounts"), '') IS NULL, 0,
                 ARRAY_SIZE(SPLIT("allowed_accounts", ',')))) AS allowed_account_count
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
  WHERE UPPER("account_locator") = CURRENT_ACCOUNT()
  GROUP BY "name"
),
np AS (
  SELECT COUNT(*) AS live_network_policies FROM __SHIM_NETWORK_POLICIES__ WHERE deleted IS NULL
),
j AS (
  SELECT g.*, sh.group_name IS NOT NULL AS in_show, sh.is_primary, sh.allowed_account_count, np.live_network_policies,
         g.group_type = 'FAILOVER' AND (g.object_types NOT LIKE '%USERS%' OR g.object_types NOT LIKE '%ROLES%') AS no_users_roles,
         g.group_type = 'FAILOVER' AND np.live_network_policies > 0 AND g.object_types NOT LIKE '%NETWORK POLICIES%' AS no_net_policies,
         g.error_integration IS NULL AS no_error_integration,
         COALESCE(sh.is_primary, FALSE) AND g.replication_schedule IS NULL AS no_schedule,
         COALESCE(sh.is_primary AND sh.allowed_account_count <= 1, FALSE) AS no_targets,
         g.group_type = 'REPLICATION'
           AND LENGTH(REPLACE(REPLACE(REPLACE(REPLACE(g.object_types, 'DATABASES', ''), 'SHARES', ''), ',', ''), ' ', '')) > 0 AS repl_with_account_objects
  FROM g
  LEFT JOIN sh ON sh.group_name = g.group_name
  CROSS JOIN np
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, group_name, group_type, is_primary, object_types,
       GREATEST(CAST(allowed_account_count AS BIGINT) - 1, 0) AS target_account_count, replication_schedule IS NOT NULL AS has_schedule,
       NOT no_error_integration AS has_error_integration, live_network_policies,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(no_users_roles, 'failover group without users or roles: nobody can sign in after a promotion', NULL),
         IFF(no_net_policies, 'network policies are not in the group', NULL),
         IFF(no_error_integration, 'no error integration: failed refreshes go unnoticed', NULL),
         IFF(no_schedule, 'primary has no replication schedule', NULL),
         IFF(no_targets, 'no other account is allowed to hold a secondary', NULL)), '; ') AS reasons,
       IFF(repl_with_account_objects, 'replication group holds account objects and cannot be promoted', NULL) AS note,
       CASE WHEN NOT (no_users_roles OR no_net_policies OR no_error_integration OR no_schedule OR no_targets)
                 AND NOT in_show THEN 'not_in_show_replication_groups' END AS not_assessed_reason,
       CASE
         WHEN no_users_roles OR no_net_policies OR no_error_integration OR no_schedule OR no_targets THEN 'WARN'
         WHEN NOT in_show THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'WARN' THEN 0 WHEN 'NOT_ASSESSED' THEN 1 ELSE 2 END, group_name
