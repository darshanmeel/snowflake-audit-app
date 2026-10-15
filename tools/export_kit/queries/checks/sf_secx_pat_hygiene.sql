-- query_id: sf_secx_pat_hygiene
-- title: Programmatic access tokens: long-lived, unused, unrestricted or outside a network policy
-- domain: governance_access   tier: standard
-- windowed: yes
-- pre: SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CREDENTIALS, SNOWFLAKE.ACCOUNT_USAGE.USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES, SHOW PARAMETERS IN ACCOUNT
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (SECURITY_VIEWER for CREDENTIALS)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :max_pat_days (default 90) days: token lifetime above which the row flags; :unused_days
--   (default 30) days: time since last use above which the row flags
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. ROLE_RESTRICTION is read as a role name or a list.
-- read_this: one row = one ACTIVE programmatic access token (PAT). lifetime_days is creation to expiry,
--   days_since_used counts from last use (or creation when never used). logins and client_ips are
--   sign-ins in the window whose first factor was this token. role_restricted = the token is limited
--   to one role; bypass_network_mins is the number of minutes the token may skip the network-policy
--   requirement (0 = none). network_policy is the user-level policy, else the account one. Token
--   values are never read.
-- healthy: status = OK when the token expires within :max_pat_days days, was used in the last
--   :unused_days days, a network policy applies, and it is role-restricted where it must be.
-- investigate_if: WARN when a token lives longer than :max_pat_days days, is unused for :unused_days
--   days, has no network policy, skips the network-policy requirement, belongs to a disabled or
--   deleted user, or is unrestricted on a service user; CRITICAL when an unrestricted token of a user
--   who can use an admin role has no network policy or skips it.
-- actions: 1) drop or rotate tokens that are unused or belong to disabled users (free); 2) set
--   ROLE_RESTRICTION on service-user tokens and cap PAT_POLICY MAX_EXPIRY_IN_DAYS in an authentication
--   policy (config); 3) attach a network policy to users who hold tokens (config)
-- next: sf_secx_authentication_policy_posture
-- caveats: CREDENTIALS lags up to 2 hours and leaves out deleted tokens; the role only sees tokens it
--   may read. LOGIN_HISTORY links a sign-in to a token by FIRST_AUTHENTICATION_FACTOR_ID.
WITH -- Live users with the auth flags normalised: DISABLED and EXT_AUTHN_DUO can come back as VARIANT
-- text, and a NULL TYPE behaves as PERSON.
sf_sec_users AS (
  SELECT TO_VARCHAR(user_id) AS user_id, name AS user_name, email, created_on,
         COALESCE(UPPER(type), 'PERSON') AS user_type,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE) AS is_disabled,
         COALESCE(has_password, FALSE) AS has_password,
         COALESCE(has_mfa, FALSE) AS has_mfa,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(ext_authn_duo)), FALSE) AS has_duo,
         COALESCE(has_rsa_public_key, FALSE) AS has_rsa_key,
         UPPER(default_role) AS default_role, UPPER(default_secondary_role) AS default_secondary_role,
         last_success_login, password_last_set_time, locked_until_time, owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  -- Snowflake-managed users (SNOWFLAKE, WORKSHEETS_APP_USER) are not the customer's to change.
  WHERE deleted_on IS NULL AND COALESCE(UPPER(type), '') <> 'SNOWFLAKE_SERVICE'
    AND UPPER(name) NOT IN ('SNOWFLAKE', 'WORKSHEETS_APP_USER')
),
-- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
-- every role a user can use through a direct grant. A child role is NAME, its parent GRANTEE_NAME.
sf_sec_role_reach AS (
  SELECT name AS top_role, name AS role_name, 0 AS depth, CAST(name AS VARCHAR) AS path
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT r.top_role, g.name, r.depth + 1, r.path || ' > ' || g.name
  FROM sf_sec_role_reach r
  JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
    ON g.grantee_name = r.role_name AND g.granted_on = 'ROLE' AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
   AND g.privilege = 'USAGE' AND g.deleted_on IS NULL
  -- Snowflake forbids cycles; the cap only guards against a malformed history.
  WHERE r.depth < 20
),
sf_sec_user_roles AS (
  SELECT gu.grantee_name AS user_name, gu.role AS granted_role, r.role_name, r.depth, r.path
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu
  JOIN sf_sec_role_reach r ON r.top_role = gu.role
  WHERE gu.deleted_on IS NULL
),
acct AS (
  SELECT NULLIF(TRIM(p."value"), '') AS policy_name
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) p
  WHERE p."key" = 'NETWORK_POLICY'
),
pats AS (
  SELECT c.credential_id, c.name AS credential_name, c.user_name, c.created_by, c.created_on,
         c.last_used_on, c.expiration_date,
         c.additional_details:ROLE_RESTRICTION AS role_restriction,
         TRY_TO_NUMBER(TO_VARCHAR(c.additional_details:MINS_TO_BYPASS_NETWORK_POLICY_REQUIREMENT)) AS bypass_mins
  FROM SNOWFLAKE.ACCOUNT_USAGE.CREDENTIALS c
  WHERE c.domain = 'PROGRAMMATIC_ACCESS_TOKEN' AND c.status = 'ACTIVE'
),
logins AS (
  SELECT TRY_TO_NUMBER(first_authentication_factor_id) AS credential_id, COUNT(*) AS logins,
         COUNT(DISTINCT client_ip) AS client_ips, MAX(event_timestamp) AS last_login
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
    AND is_success = 'YES' AND first_authentication_factor_id IS NOT NULL
  GROUP BY 1
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
j AS (
  SELECT p.credential_id, p.credential_name, p.user_name, u.user_id, u.user_type, ad.admin_roles,
         p.created_by, p.created_on, p.last_used_on, p.expiration_date,
         (u.user_id IS NULL OR u.is_disabled) AS owner_gone,
         DATEDIFF(day, p.created_on, p.expiration_date) AS lifetime_days,
         DATEDIFF(day, COALESCE(p.last_used_on, p.created_on), __AS_OF_DATE__) AS days_since_used,
         p.last_used_on IS NULL AS never_used,
         COALESCE(p.role_restriction IS NOT NULL AND NOT COALESCE(IS_NULL_VALUE(p.role_restriction), FALSE)
                  AND IFF(IS_ARRAY(p.role_restriction), ARRAY_SIZE(p.role_restriction) > 0,
                          NULLIF(TRIM(TO_VARCHAR(p.role_restriction)), '') IS NOT NULL), FALSE) AS role_restricted,
         COALESCE(p.bypass_mins, 0) AS bypass_network_mins,
         COALESCE(unp.policy_name, (SELECT MAX(policy_name) FROM acct)) AS network_policy,
         COALESCE(l.logins, 0) AS logins, COALESCE(l.client_ips, 0) AS client_ips, l.last_login
  FROM pats p
  LEFT JOIN sf_sec_users u ON u.user_name = p.user_name
  LEFT JOIN admin ad ON ad.user_name = p.user_name
  LEFT JOIN user_np unp ON unp.user_name = p.user_name
  LEFT JOIN logins l ON l.credential_id = p.credential_id
),
s AS (
  SELECT j.*,
         COALESCE(lifetime_days > :max_pat_days, FALSE) AS long_lived,
         days_since_used > :unused_days AS unused,
         (NOT role_restricted AND (COALESCE(user_type, 'SERVICE') <> 'PERSON' OR admin_roles IS NOT NULL)) AS unrestricted,
         network_policy IS NULL AS no_network,
         bypass_network_mins > 0 AS bypasses_network
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, credential_id, credential_name, user_id, user_name,
       user_type, admin_roles, created_by, created_on, expiration_date, lifetime_days, last_used_on, days_since_used,
       never_used, role_restricted, bypass_network_mins, network_policy, logins, client_ips, last_login,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(long_lived, 'lives ' || lifetime_days || ' days', NULL),
         IFF(unused AND never_used, 'never used', NULL),
         IFF(unused AND NOT never_used, 'unused for ' || days_since_used || ' days', NULL),
         IFF(unrestricted, 'not limited to one role', NULL),
         IFF(no_network, 'no network policy applies', NULL),
         IFF(bypasses_network, 'may skip the network policy for ' || bypass_network_mins || ' minutes', NULL),
         IFF(owner_gone, 'owner is disabled or deleted', NULL),
         IFF(admin_roles IS NOT NULL, 'owner can use ' || admin_roles, NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN admin_roles IS NOT NULL AND NOT owner_gone AND unrestricted AND (no_network OR bypasses_network) THEN 'CRITICAL'
         WHEN long_lived OR unused OR unrestricted OR no_network OR bypasses_network OR owner_gone THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, days_since_used DESC, user_name
