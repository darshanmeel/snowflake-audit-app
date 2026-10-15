-- query_id: sf_secx_key_pair_age
-- title: Key pairs: age, last use and who holds them
-- domain: governance_access   tier: standard
-- entity: key pairs = user_name, credential_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CREDENTIALS, SNOWFLAKE.ACCOUNT_USAGE.USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :max_age_days (default 180) days: a key older than this flags; :stale_days (default 90) days:
--   a key not used for this long, or never used and older than this, flags
-- empty_if: role_cannot_see
-- not_assessed_reasons: no_credential_record: the user has an RSA public key but CREDENTIALS lists no key pair
--   for it (a key set before the view tracked keys, or lag), so its age is unknown
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one key pair credential of a user (a user can hold two while rotating), or one user
--   whose RSA key CREDENTIALS does not list. key_age_days counts from creation to the audit's as-of date,
--   days_since_last_use from the last authentication with it (empty when never used). Only key status,
--   dates and names are read, never the key or its fingerprint.
-- healthy: status = OK when an active key is younger than :max_age_days and used within :stale_days days.
-- investigate_if: WARN when an active key is older than :max_age_days, unused for :stale_days days, never
--   used, or belongs to a disabled user; CRITICAL when an old key that is still used belongs to a user who
--   can use an admin role.
-- actions: 1) rotate old keys through RSA_PUBLIC_KEY_2, then unset the old one (free); 2) remove keys nobody
--   uses and keys of disabled users (free); 3) move admin users to SSO or MFA and keep keys for service
--   users only (config)
-- next: sf_secx_key_and_password_age
-- caveats: CREDENTIALS lags up to 2 hours and leaves out deleted credentials. LAST_USED_ON is the last time
--   the key authenticated, not the last query. A key that does not appear in CREDENTIALS is shown as not
--   assessed rather than as clean.
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
admin AS (
  SELECT user_name, LISTAGG(DISTINCT role_name, ', ') WITHIN GROUP (ORDER BY role_name) AS admin_roles
  FROM sf_sec_user_roles
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN', 'SYSADMIN')
  GROUP BY user_name
),
k AS (
  SELECT c.credential_id, c.name AS credential_name, c.user_name, UPPER(c.status) AS key_status, c.created_on,
         c.last_used_on, c.expiration_date
  FROM SNOWFLAKE.ACCOUNT_USAGE.CREDENTIALS c
  WHERE UPPER(c.type) = 'KEYPAIR' OR UPPER(c.domain) = 'KEYPAIR'
),
j AS (
  SELECT k.credential_id, k.credential_name, u.user_name, u.user_id, u.user_type, u.is_disabled, u.has_password,
         k.key_status, k.created_on, k.last_used_on, k.expiration_date, TRUE AS has_record
  FROM k
  LEFT JOIN sf_sec_users u ON u.user_name = k.user_name
  UNION ALL
  SELECT CAST(NULL AS NUMBER), '(no credential record)', u.user_name, u.user_id, u.user_type, u.is_disabled,
         u.has_password, CAST(NULL AS VARCHAR), CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS TIMESTAMP_LTZ),
         CAST(NULL AS TIMESTAMP_LTZ), FALSE
  FROM sf_sec_users u
  WHERE u.has_rsa_key AND NOT EXISTS (SELECT 1 FROM k WHERE k.user_name = u.user_name)
),
s AS (
  SELECT j.*, a.admin_roles,
         DATEDIFF(day, created_on, __AS_OF_DATE__) AS key_age_days,
         DATEDIFF(day, last_used_on, __AS_OF_DATE__) AS days_since_last_use,
         COUNT(*) OVER (PARTITION BY j.user_name) AS keys_on_user,
         COALESCE(key_status, 'ACTIVE') = 'ACTIVE' AS is_active
  FROM j
  LEFT JOIN admin a ON a.user_name = j.user_name
),
f AS (
  SELECT s.*,
         COALESCE(key_age_days > :max_age_days, FALSE) AS old_key,
         is_active AND has_record AND (days_since_last_use > :stale_days
           OR (last_used_on IS NULL AND key_age_days > :stale_days)) AS unused_key,
         is_active AND has_record AND COALESCE(is_disabled, FALSE) AS on_disabled_user
  FROM s
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, user_type, credential_id, credential_name,
       key_status, created_on, last_used_on, expiration_date, key_age_days, days_since_last_use, keys_on_user,
       admin_roles, has_password,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(is_active AND old_key, 'key is ' || key_age_days || ' days old', NULL),
         IFF(unused_key AND last_used_on IS NULL, 'never used', NULL),
         IFF(unused_key AND last_used_on IS NOT NULL, 'not used for ' || days_since_last_use || ' days', NULL),
         IFF(on_disabled_user, 'active key on a disabled user', NULL),
         IFF(is_active AND old_key AND NOT unused_key AND admin_roles IS NOT NULL, 'can use ' || admin_roles, NULL),
         IFF(NOT has_record, 'RSA key set but no key pair credential listed', NULL)), '; ') AS reasons,
       IFF(NOT has_record, 'no_credential_record', NULL) AS not_assessed_reason,
       CASE
         WHEN NOT has_record THEN 'NOT_ASSESSED'
         WHEN NOT is_active THEN 'OK'
         WHEN old_key AND NOT unused_key AND admin_roles IS NOT NULL THEN 'CRITICAL'
         WHEN old_key OR unused_key OR on_disabled_user THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END,
         key_age_days DESC NULLS LAST, user_name
