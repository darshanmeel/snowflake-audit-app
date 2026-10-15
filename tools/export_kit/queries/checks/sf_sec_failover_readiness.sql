-- query_id: sf_sec_failover_readiness
-- title: Failover groups that would not bring users, roles or network policies across, or fail silently
-- domain: governance_access   tier: standard
-- entity: replication groups = group_name
-- windowed: no
-- pre: SHOW REPLICATION GROUPS
-- reads: SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUPS, SHOW REPLICATION GROUPS,
--   SNOWFLAKE.ACCOUNT_USAGE.NETWORK_POLICIES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that holds MONITOR, OWNERSHIP or
--   REPLICATE on the groups (SHOW lists only those); Business Critical Edition for failover groups
-- params: none
-- empty_if: role_cannot_see, edition_too_low, no_activity
-- not_assessed_reasons: not_in_show_replication_groups: the group is in the usage view but the role cannot see
--   it in SHOW, so primary, schedule and target accounts could not be read
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The exact spelling of OBJECT_TYPES entries (USERS, ROLES,
--   NETWORK POLICIES) follows the CREATE FAILOVER GROUP docs and is matched as text.
-- read_this: one row = one live replication or failover group. object_types is what the group carries,
--   target_account_count how many other accounts may hold a secondary (SHOW lists the primary itself, so one is subtracted), has_error_integration whether a failed
--   refresh raises a notification. A failover group without USERS and ROLES cannot let anyone sign in
--   after a promotion.
-- healthy: status = OK when a failover group carries users, roles and (if the account has any) network
--   policies, has an error integration, a schedule on the primary and at least one target account.
-- investigate_if: WARN when a failover group lacks USERS or ROLES, lacks NETWORK POLICIES while the account
--   has one, has no error integration, has no schedule on the primary, or has no target account besides itself.
-- actions: 1) add USERS, ROLES and NETWORK POLICIES to the failover group's object types (config); 2) set
--   an ERROR_INTEGRATION so a failed refresh is noticed (config); 3) set a REPLICATION_SCHEDULE that
--   matches the recovery point you need; a tighter schedule costs more (spend)
-- next: sf_repl_group_health
-- caveats: Client redirect (a connection object) is not checked here: SHOW CONNECTIONS errors below Business
--   Critical and would fail the whole check. Whether the account uses SSO is not known to this check, so
--   security integrations are not judged. A REPLICATION group that holds account objects is shown in note;
--   it cannot be promoted. Only object types and counts are kept, never account names. The usage view
--   lags up to 2 hours.
WITH g AS (
  SELECT name AS group_name, UPPER(type) AS group_type, UPPER(COALESCE(object_types, '')) AS object_types,
         replication_schedule, error_integration
  FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUPS
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
  SELECT COUNT(*) AS live_network_policies FROM SNOWFLAKE.ACCOUNT_USAGE.NETWORK_POLICIES WHERE deleted IS NULL
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
