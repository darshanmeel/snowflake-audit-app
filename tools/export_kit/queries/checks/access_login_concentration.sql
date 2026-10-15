-- query_id: access_login_concentration
-- title: Login concentration and failed-authentication rollup
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the
--   export date; :warn_failed_logins (default 5) non-success auth events for one
--   user+source_ip+client+factor combo that flags WARN; :crit_failed_logins (default 20) that flags
--   CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account x masked user x source IP x client type x authentication factor
--   combo in the window. The columns that matter are non_success_count (failed/non-200 attempts)
--   and distinct_source_ips (how many DIFFERENT locations that user authenticated from anywhere in
--   the window - the same number on every row for that user, not scoped to this row's own
--   account/IP/service/action).
-- healthy: status = OK; non_success_count below :warn_failed_logins for one user+IP+factor - field
--   heuristic; some non-success events are normal (typos, expired tokens).
-- investigate_if: status = WARN at/above :warn_failed_logins, CRITICAL at/above :crit_failed_logins
--   - field heuristic; also worth a look whenever distinct_source_ips is high for a single user,
--   which this query surfaces but does not score.
-- actions: 1) confirm whether the failed attempts are a known automation or CI credential that
--   rotated or expired (free); 2) if unexplained, force a password or key reset for that user and
--   require MFA (config); 3) if this recurs across many users, send LOGIN_HISTORY to a SIEM or
--   threat-detection tool (spend).
-- next: none
-- caveats: Snowflake version: one row per user x client IP x client type (service_name =
--   reported_client_type) x first authentication factor (action_name); success = is_success YES.
WITH base AS (
  SELECT user_name, client_ip, reported_client_type, first_authentication_factor, is_success, event_timestamp
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
),
principal_ips AS (
  SELECT user_name, COUNT(DISTINCT client_ip) AS distinct_source_ips
  FROM base
  GROUP BY user_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, COALESCE(b.user_name, '(no user name)') AS principal,
       b.client_ip AS source_ip_address, b.reported_client_type AS service_name,
       b.first_authentication_factor AS action_name,
       COUNT(*) AS event_count,
       COUNT_IF(b.is_success = 'YES') AS success_count,
       COUNT_IF(b.is_success IS DISTINCT FROM 'YES') AS non_success_count,
       MAX(p.distinct_source_ips) AS distinct_source_ips,
       MIN(b.event_timestamp) AS first_event_time, MAX(b.event_timestamp) AS last_event_time,
       CASE
         WHEN COUNT_IF(b.is_success IS DISTINCT FROM 'YES') >= :crit_failed_logins THEN 'CRITICAL'
         WHEN COUNT_IF(b.is_success IS DISTINCT FROM 'YES') >= :warn_failed_logins THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM base b
LEFT JOIN principal_ips p ON p.user_name IS NOT DISTINCT FROM b.user_name
GROUP BY b.user_name, b.client_ip, b.reported_client_type, b.first_authentication_factor
ORDER BY non_success_count DESC
