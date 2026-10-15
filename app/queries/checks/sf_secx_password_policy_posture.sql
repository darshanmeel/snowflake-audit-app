-- query_id: sf_secx_password_policy_posture
-- title: Password policy on the account: length, expiry and lockout
-- domain: governance_access   tier: standard
-- entity: password policies = policy_name
-- windowed: no
-- pre: SHOW PASSWORD POLICIES ON ACCOUNT
-- reads: SHOW PASSWORD POLICIES ON ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.PASSWORD_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ownership of, or APPLY PASSWORD POLICY on, the
--   account (SHOW lists only what the role can see)
-- params: :min_length (default 14) characters: a policy on the account below this flags when users sign in
--   with a password; :max_age_days (default 365) days: a password that never expires, or lives longer than
--   this, flags; :max_retries (default 5) attempts: more failed sign-ins than this before lockout flags
-- empty_if: role_cannot_see
-- not_assessed_reasons: attachment_not_visible: password policies exist but SHOW returned none on the account,
--   which can mean none is attached or that the role cannot see it; settings_not_visible: SHOW lists an
--   account policy that PASSWORD_POLICIES does not (lag, or the role cannot read it)
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Attachment to a single user is not listed anywhere in bulk.
-- read_this: one row = one password policy, or one row saying none exists. is_account_policy is TRUE for the
--   policy SHOW lists as set on the account. password_users counts enabled users with a password.
--   POLICY_REFERENCES does not list password policies, so SHOW is the only account-level source.
-- healthy: status = OK when the account policy asks for at least :min_length characters, expires passwords
--   within :max_age_days and locks after :max_retries failures, or nobody signs in with a password.
-- investigate_if: WARN when users have passwords and no policy exists or the account policy is weak;
--   CRITICAL when the account policy allows passwords shorter than 8 characters.
-- actions: 1) create a password policy with PASSWORD_MIN_LENGTH, PASSWORD_MAX_AGE_DAYS and
--   PASSWORD_MAX_RETRIES and set it on the account (config); 2) move people and service users off passwords
--   to SSO or key pair so the policy matters less (free); 3) test on one user with ALTER USER SET PASSWORD
--   POLICY before the account (free)
-- next: sf_secx_authentication_policy_posture
-- caveats: A policy set on one user overrides the account one and is not listed in bulk, so an account with
--   only user-level policies reads as not attached. The policy text is never stored, only its numeric
--   settings. ACCOUNT_USAGE lags up to 2 hours.
WITH __INCLUDE_sf_sec_users__,
acct AS (
  SELECT UPPER(s."database_name" || '.' || s."schema_name" || '.' || s."name") AS policy_key
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
  WHERE s."database_name" IS NOT NULL
),
pol AS (
  SELECT UPPER(pp.database || '.' || pp.schema || '.' || pp.name) AS policy_key,
         pp.database || '.' || pp.schema || '.' || pp.name AS policy_fqn,
         password_min_length, password_max_length, password_min_upper_case_chars, password_min_lower_case_chars,
         password_min_numeric_chars, password_min_special_chars, password_min_age_days, password_max_age_days,
         password_max_retries, password_lockout_time_mins, password_history, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.PASSWORD_POLICIES pp
  WHERE pp.deleted IS NULL
),
usr AS (
  SELECT COUNT_IF(has_password AND NOT is_disabled) AS password_users FROM sf_sec_users
),
j AS (
  SELECT COALESCE(p.policy_fqn, a.policy_key) AS policy_fqn, a.policy_key IS NOT NULL AS is_account_policy,
         p.policy_key IS NOT NULL AS settings_known,
         p.password_min_length, p.password_max_length, p.password_min_upper_case_chars, p.password_min_lower_case_chars,
         p.password_min_numeric_chars, p.password_min_special_chars, p.password_min_age_days, p.password_max_age_days,
         p.password_max_retries, p.password_lockout_time_mins, p.password_history, p.last_altered
  FROM pol p
  FULL OUTER JOIN acct a ON a.policy_key = p.policy_key
),
r AS (
  SELECT j.*, COUNT_IF(j.is_account_policy) OVER () AS account_policies
  FROM j
),
s AS (
  SELECT r.*, u.password_users,
         (password_min_length < :min_length OR COALESCE(password_max_age_days, 0) = 0
          OR password_max_age_days > :max_age_days OR password_max_retries > :max_retries) AS weak
  FROM r CROSS JOIN usr u
  UNION ALL
  SELECT CAST(NULL AS VARCHAR), FALSE, FALSE, CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS NUMBER),
         CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS NUMBER),
         CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS NUMBER),
         CAST(NULL AS TIMESTAMP_LTZ), 0,
         u.password_users, FALSE
  FROM usr u
  WHERE NOT EXISTS (SELECT 1 FROM j)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, COALESCE(policy_fqn, '(no password policy)') AS policy_name,
       is_account_policy, password_users, password_min_length AS min_length, password_max_length AS max_length,
       password_min_upper_case_chars AS min_upper_chars, password_min_lower_case_chars AS min_lower_chars,
       password_min_numeric_chars AS min_numeric_chars, password_min_special_chars AS min_special_chars,
       password_min_age_days AS min_age_days, password_max_age_days AS max_age_days,
       password_max_retries AS max_retries, password_lockout_time_mins AS lockout_mins, password_history AS history,
       last_altered,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(policy_fqn IS NULL, 'no password policy exists; ' || password_users || ' users have a password', NULL),
         IFF(is_account_policy AND settings_known AND password_min_length < :min_length,
             'minimum length ' || password_min_length, NULL),
         IFF(is_account_policy AND settings_known AND COALESCE(password_max_age_days, 0) = 0, 'passwords never expire', NULL),
         IFF(is_account_policy AND settings_known AND password_max_age_days > :max_age_days,
             'passwords live up to ' || password_max_age_days || ' days', NULL),
         IFF(is_account_policy AND settings_known AND password_max_retries > :max_retries,
             password_max_retries || ' failed sign-ins before lockout', NULL),
         IFF(NOT is_account_policy AND policy_fqn IS NOT NULL AND account_policies > 0,
             'defined but not set on the account', NULL)), '; ') AS reasons,
       CASE WHEN is_account_policy AND NOT settings_known THEN 'settings_not_visible'
            WHEN policy_fqn IS NOT NULL AND NOT is_account_policy AND account_policies = 0 THEN 'attachment_not_visible'
       END AS not_assessed_reason,
       CASE
         WHEN policy_fqn IS NULL THEN IFF(password_users > 0, 'WARN', 'OK')
         WHEN is_account_policy AND NOT settings_known THEN 'NOT_ASSESSED'
         WHEN is_account_policy AND password_users > 0 AND password_min_length < 8 THEN 'CRITICAL'
         WHEN is_account_policy AND password_users > 0 AND weak THEN 'WARN'
         WHEN is_account_policy THEN 'OK'
         WHEN account_policies = 0 THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END, policy_name
