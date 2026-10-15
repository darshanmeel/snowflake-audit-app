-- query_id: sf_org_security_posture_by_account
-- title: Accounts with password-only users, users without MFA or open critical Trust Center findings
-- domain: governance_access   tier: standard
-- entity: accounts = account_locator
-- windowed: no
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS, SNOWFLAKE.ORGANIZATION_USAGE.USERS,
--   SNOWFLAKE.ORGANIZATION_USAGE.TRUST_CENTER_FINDINGS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; the organization account (these premium views
--   exist only there); Enterprise Edition
-- params: :stale_days (default 90) days: an enabled user with no successful sign-in for this long counts as
--   stale; :crit_share (default 0.5) share (0 to 1): accounts where more than this share of person users
--   has a password and no MFA flag CRITICAL
-- empty_if: org_account_only, view_missing, edition_too_low
-- not_assessed_reasons: no_user_rows: ORGANIZATION_USAGE.USERS holds no user for this account, so its
--   posture could not be read
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live account. person_no_mfa counts enabled person users with a password and no
--   MFA, service_with_password service users still on a password, stale_users person users with no sign-in for
--   :stale_days (shown, not judged), has_trust_center_rows whether the account has any Trust Center row, and
--   open_critical_findings open CRITICAL Trust Center findings (open_high_findings HIGH).
--   The single-account checks own the per-user detail; this page points at the account to open.
-- healthy: status = OK when no person user is password-only, no service user has a password and no CRITICAL
--   Trust Center finding is open.
-- investigate_if: WARN when a person user has a password and no MFA, or a service user has a password;
--   CRITICAL when an open CRITICAL finding exists or the no-MFA share of person users is above :crit_share.
-- actions: 1) open the account and run the users-without-MFA and Trust Center checks there (free); 2) enforce
--   MFA or single sign-on through an authentication policy (config); 3) move service users to key pair or
--   OAuth and remove their passwords (config)
-- next: sf_sec_users_without_mfa
-- caveats: Users of type SNOWFLAKE_SERVICE and the Snowflake-managed users are left out. A NULL user type
--   counts as a person. MFA through an external identity provider is not visible, so single sign-on users
--   with no password count as covered. An account with no Trust Center rows may not run scanners: its finding
--   counts read NULL and note says so, never 0. Lags up to 3 hours.
WITH acct AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(edition) AS edition
  FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
  WHERE deleted_on IS NULL
  GROUP BY account_locator
),
u AS (
  SELECT account_locator,
         COUNT(*) AS enabled_users,
         COUNT_IF(COALESCE(UPPER(type), 'PERSON') = 'PERSON') AS person_users,
         COUNT_IF(COALESCE(UPPER(type), 'PERSON') = 'PERSON' AND COALESCE(has_password, FALSE)
                  AND NOT COALESCE(has_mfa, FALSE) AND NOT COALESCE(ext_authn_duo, FALSE)) AS person_no_mfa,
         COUNT_IF(COALESCE(UPPER(type), '') IN ('SERVICE', 'LEGACY_SERVICE') AND COALESCE(has_password, FALSE)) AS service_with_password,
         COUNT_IF(COALESCE(UPPER(type), 'PERSON') = 'PERSON'
                  AND (last_success_login IS NULL OR last_success_login < DATEADD(day, -:stale_days, __AS_OF_DATE__))) AS stale_users
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USERS
  WHERE deleted_on IS NULL AND COALESCE(UPPER(type), '') <> 'SNOWFLAKE_SERVICE'
    AND UPPER(name) NOT IN ('SNOWFLAKE', 'WORKSHEETS_APP_USER')
    AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)
  GROUP BY account_locator
),
t AS (
  SELECT account_locator,
         COUNT_IF(UPPER(state) = 'OPEN' AND UPPER(severity) = 'CRITICAL') AS open_critical_findings,
         COUNT_IF(UPPER(state) = 'OPEN' AND UPPER(severity) = 'HIGH') AS open_high_findings
  FROM SNOWFLAKE.ORGANIZATION_USAGE.TRUST_CENTER_FINDINGS
  GROUP BY account_locator
),
s AS (
  SELECT acct.account_locator, acct.account_name, acct.edition, u.account_locator IS NOT NULL AS has_users,
         COALESCE(u.enabled_users, 0) AS enabled_users, COALESCE(u.person_users, 0) AS person_users,
         COALESCE(u.person_no_mfa, 0) AS person_no_mfa,
         COALESCE(u.service_with_password, 0) AS service_with_password, COALESCE(u.stale_users, 0) AS stale_users,
         t.account_locator IS NOT NULL AS has_trust_center_rows,
         t.open_critical_findings AS open_critical_findings,
         t.open_high_findings AS open_high_findings,
         COALESCE(u.person_no_mfa, 0) / NULLIF(u.person_users, 0) AS no_mfa_share
  FROM acct
  LEFT JOIN u ON u.account_locator = acct.account_locator
  LEFT JOIN t ON t.account_locator = acct.account_locator
)
SELECT 0 AS window_days, account_locator AS account_id, account_name, account_locator, edition, enabled_users,
       person_users, person_no_mfa, no_mfa_share, service_with_password, stale_users, has_trust_center_rows,
       open_critical_findings, open_high_findings,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(COALESCE(open_critical_findings, 0) > 0, open_critical_findings || ' open CRITICAL findings', NULL),
         IFF(no_mfa_share > :crit_share, 'most person users are password-only', NULL),
         IFF(person_no_mfa > 0, person_no_mfa || ' of ' || person_users || ' person users with a password and no MFA', NULL),
         IFF(service_with_password > 0, service_with_password || ' service users on a password', NULL)), '; ') AS reasons,
       IFF(NOT has_users, 'no_user_rows', NULL) AS not_assessed_reason,
       IFF(NOT has_trust_center_rows, 'no Trust Center scanner results: findings not assessed', NULL) AS note,
       CASE
         WHEN NOT has_users THEN 'NOT_ASSESSED'
         WHEN COALESCE(open_critical_findings, 0) > 0 OR COALESCE(no_mfa_share, 0) > :crit_share THEN 'CRITICAL'
         WHEN person_no_mfa > 0 OR service_with_password > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END,
         open_critical_findings DESC NULLS LAST, person_no_mfa DESC, account_name
