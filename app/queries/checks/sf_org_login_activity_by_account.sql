-- query_id: sf_org_login_activity_by_account
-- title: Logins per account across the organization (optional premium view)
-- domain: governance_access   tier: standard
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS, SNOWFLAKE.ORGANIZATION_USAGE.LOGIN_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_USAGE_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_failed_pct (default 20) failed pct: at or above this the row reads WARN;
--   :crit_failed_pct (default 50) failed pct: at or above this the row reads CRITICAL; :min_logins
--   (default 20) logins: least a row needs before it can flag; :warn_password_only_pct (default 50)
--   password only pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live account (account = account locator). logins / failed_logins count
--   login events in the window; users = distinct user names that logged in successfully;
--   password_only_pct = share of successful password logins with no second factor; last_login = latest
--   successful login. An account with no logins at all is a dormant-account candidate (see
--   sf_org_dormant_accounts for its cost).
-- healthy: status = OK when an account has logins, few failures and MFA on password logins.
-- investigate_if: WARN when a live account had no successful login in the window, >= warn_failed_pct of
--   logins failed, or >= warn_password_only_pct of password logins had no MFA; CRITICAL when >=
--   crit_failed_pct failed (with at least min_logins attempts).
-- actions: 1) ask the owner of a silent account whether it is still needed; read the failing users in
--   sf_sec_failed_logins in that account (free); 2) enforce MFA or key-pair / OAuth for the
--   password-only users, block the failing sources with a network policy (config); 3) drop accounts
--   nobody logs into (spend).
-- next: none
-- caveats: OPTIONAL: ORGANIZATION_USAGE.LOGIN_HISTORY is a premium view that exists only in the
--   organization account and needs ORGADMIN or a role granted its premium-view access; elsewhere this
--   check fails. Service users with key-pair auth still count as logins. Lags up to 24 hours.
WITH acct AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(edition) AS edition,
         MAX(created_on) AS created_on
  FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
  WHERE deleted_on IS NULL
  GROUP BY account_locator
),
l AS (
  SELECT account_locator,
         COUNT(*) AS logins,
         COUNT_IF(is_success = 'NO') AS failed_logins,
         COUNT(DISTINCT IFF(is_success = 'YES', user_name, NULL)) AS users,
         COUNT_IF(is_success = 'YES' AND first_authentication_factor = 'PASSWORD') AS password_logins,
         COUNT_IF(is_success = 'YES' AND first_authentication_factor = 'PASSWORD'
                  AND second_authentication_factor IS NULL) AS password_only_logins,
         MAX(IFF(is_success = 'YES', event_timestamp, NULL)) AS last_login
  FROM SNOWFLAKE.ORGANIZATION_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND event_timestamp < __AS_OF_DATE__
  GROUP BY account_locator
),
s AS (
  SELECT acct.*, COALESCE(l.logins, 0) AS logins, COALESCE(l.failed_logins, 0) AS failed_logins,
         COALESCE(l.users, 0) AS users, l.password_logins, l.password_only_logins, l.last_login,
         100 * l.failed_logins / NULLIF(l.logins, 0) AS failed_pct,
         100 * l.password_only_logins / NULLIF(l.password_logins, 0) AS password_only_pct
  FROM acct LEFT JOIN l ON l.account_locator = acct.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       edition, created_on, logins, failed_logins, failed_pct, users, password_logins,
       password_only_logins, password_only_pct, last_login,
       CASE WHEN created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND logins = 0 THEN 'created_in_window' END AS not_assessed_reason,
       CASE
         WHEN created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND logins = 0 THEN 'NOT_ASSESSED'
         WHEN logins >= :min_logins AND failed_pct >= :crit_failed_pct THEN 'CRITICAL'
         WHEN last_login IS NULL THEN 'WARN'
         WHEN logins >= :min_logins AND failed_pct >= :warn_failed_pct THEN 'WARN'
         WHEN password_only_pct >= :warn_password_only_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY status = 'OK', logins
