-- query_id: sf_sec_network_policy_coverage
-- title: Network policy coverage for the account and users
-- domain: governance_access   tier: standard
-- windowed: no
-- pre: SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT
-- reads: SHOW PARAMETERS IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.NETWORK_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row for the account (scope = ACCOUNT) and one per enabled user that is an admin or a
--   program (scope = USER). effective_policy is the user-level policy if any, else the account one;
--   allows_any_ip is TRUE when the policy's allowed list contains 0.0.0.0/0 and it has no network
--   rules.
-- healthy: status = OK when an account-level policy is set and admins / programs have a policy that is
--   narrower than any IP.
-- investigate_if: WARN when there is no account-level policy, or a policy allows any IP; CRITICAL when
--   an admin or service user has no effective network policy at all.
-- actions: 1) create network rules for office/VPN and tool egress IPs and an account-level network
--   policy (config); 2) give service users their own policy with only their egress IPs (config); 3)
--   test with a user-level policy before setting it on the account so no one is locked out (free)
-- next: none
-- caveats: user-level policies come from POLICY_REFERENCES (policy_kind NETWORK_POLICY); if the account
--   does not report them there, user rows fall back to the account policy. Allowed/blocked lists are
--   read from NETWORK_POLICIES as text; network rule contents are not expanded.
WITH __INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
acct AS (
  SELECT NULLIF(TRIM(p."value"), '') AS policy_name, p."level" AS policy_level
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) p
  WHERE p."key" = 'NETWORK_POLICY'
),
-- Read through OBJECT_CONSTRUCT so an account whose view lacks a newer column still runs.
np AS (
  SELECT o:NAME::VARCHAR AS policy_name,
         o:ALLOWED_IP_LIST::VARCHAR AS allowed_ip_list, o:BLOCKED_IP_LIST::VARCHAR AS blocked_ip_list,
         o:ALLOWED_NETWORK_RULE_LIST::VARCHAR AS allowed_rules, o:BLOCKED_NETWORK_RULE_LIST::VARCHAR AS blocked_rules
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o FROM SNOWFLAKE.ACCOUNT_USAGE.NETWORK_POLICIES)
  WHERE o:DELETED IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY policy_name ORDER BY TRY_TO_TIMESTAMP_LTZ(TO_VARCHAR(o:LAST_ALTERED)) DESC NULLS LAST) = 1
),
user_np AS (
  SELECT ref_entity_name AS user_name, MAX(policy_name) AS policy_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  WHERE policy_kind = 'NETWORK_POLICY' AND ref_entity_domain = 'USER'
  GROUP BY ref_entity_name
),
admin AS (
  SELECT user_name, LISTAGG(DISTINCT role_name, ', ') WITHIN GROUP (ORDER BY role_name) AS admin_roles
  FROM sf_sec_user_roles
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN', 'SYSADMIN')
  GROUP BY user_name
),
rows_ AS (
  SELECT 'ACCOUNT' AS scope, CAST(NULL AS VARCHAR) AS user_id, CAST(NULL AS VARCHAR) AS user_name,
         CAST(NULL AS VARCHAR) AS user_type, CAST(NULL AS VARCHAR) AS admin_roles,
         a.policy_name AS own_policy, a.policy_name AS effective_policy
  FROM (SELECT 1 AS one) x LEFT JOIN acct a ON TRUE
  UNION ALL
  SELECT 'USER', u.user_id, u.user_name, u.user_type, ad.admin_roles, un.policy_name,
         COALESCE(un.policy_name, (SELECT MAX(policy_name) FROM acct))
  FROM sf_sec_users u
  LEFT JOIN admin ad ON ad.user_name = u.user_name
  LEFT JOIN user_np un ON un.user_name = u.user_name
  WHERE NOT u.is_disabled AND (ad.admin_roles IS NOT NULL OR u.user_type <> 'PERSON' OR un.policy_name IS NOT NULL)
),
j AS (
  SELECT r.*, np.allowed_ip_list, np.blocked_ip_list, np.allowed_rules, np.blocked_rules,
         (np.allowed_ip_list LIKE '%0.0.0.0/0%' AND COALESCE(np.allowed_rules, '[]') IN ('', '[]')) AS allows_any_ip
  FROM rows_ r
  LEFT JOIN np ON np.policy_name = r.effective_policy
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, scope, user_id, user_name, user_type, admin_roles,
       own_policy, effective_policy,
       -- Counts only: the IP lists and rule names are policy content and are never stored.
       IFF(COALESCE(allowed_ip_list, '') IN ('', '[]'), 0, REGEXP_COUNT(allowed_ip_list, ',') + 1) AS allowed_ip_entries,
       IFF(COALESCE(blocked_ip_list, '') IN ('', '[]'), 0, REGEXP_COUNT(blocked_ip_list, ',') + 1) AS blocked_ip_entries,
       COALESCE(allowed_rules, '[]') NOT IN ('', '[]') AS has_allowed_rules,
       COALESCE(blocked_rules, '[]') NOT IN ('', '[]') AS has_blocked_rules,
       COALESCE(allows_any_ip, FALSE) AS allows_any_ip,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(scope = 'ACCOUNT' AND effective_policy IS NULL, 'no account-level network policy', NULL),
         IFF(scope = 'USER' AND effective_policy IS NULL, 'no network policy applies to this user', NULL),
         IFF(scope = 'USER' AND admin_roles IS NOT NULL, 'can use ' || admin_roles, NULL),
         IFF(scope = 'USER' AND user_type <> 'PERSON', user_type || ' user', NULL),
         IFF(allows_any_ip, 'policy allows any IP (0.0.0.0/0)', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN scope = 'USER' AND effective_policy IS NULL THEN 'CRITICAL'
         WHEN effective_policy IS NULL OR allows_any_ip THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY scope, CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, user_name
