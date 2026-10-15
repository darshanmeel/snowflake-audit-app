-- query_id: sf_sec_privatelink_bypass
-- title: Users reaching the account over the public internet while the rest use private link
-- domain: governance_access   tier: standard
-- entity: users = user_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.INGRESS_NETWORK_ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; not available in government regions
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_private_share (default 0.5) share (0 to 1): the account counts as using private link
--   when at least this share of successful requests came in over it
-- empty_if: view_missing, no_activity
-- not_assessed_reasons: no_successful_requests: every request in the window failed, so the private share
--   cannot be worked out
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The docs do not say which ingress paths are logged, so a
--   user's public requests may be missing.
-- read_this: one row = one user. ok_private and ok_public count successful requests that came in with and
--   without a private link id; account_private_share is the same split for the whole account. A user with
--   public requests is only a finding when the rest of the account uses private link.
-- healthy: status = OK when the account does not use private link, or the user has no successful public
--   request.
-- investigate_if: WARN when the account uses private link (share at or above :min_private_share) and the
--   user still made a successful public request; CRITICAL when that user holds an admin role.
-- actions: 1) find what the user connects from and move it onto the private endpoint (free); 2) block the
--   public path with a network policy that allows only private link and the addresses you need (config);
--   3) give admins their own policy first (config)
-- next: sf_sec_network_policy_coverage
-- caveats: Only counts are kept: request paths, the client URL and error messages are never exported, and
--   failures are counted, not described. Requests with no user name read as (unknown) and are left out of the account private share, which counts named users only. Lags up to 4 hours.
WITH __INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
-- The docs name the column CLIENT_PRIVATELINK_ID but accounts return CLIENT_PRIVATE_LINK_ID, so read either.
raw AS (
  SELECT user_name, is_success, client_ip,
         NULLIF(COALESCE(o:CLIENT_PRIVATE_LINK_ID, o:CLIENT_PRIVATELINK_ID)::VARCHAR, '') AS privatelink_id
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o, user_name, is_success, client_ip
        FROM SNOWFLAKE.ACCOUNT_USAGE.INGRESS_NETWORK_ACCESS_HISTORY
        WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__)
),
ing AS (
  SELECT COALESCE(NULLIF(user_name, ''), '(unknown)') AS user_name,
         COUNT_IF(is_success AND privatelink_id IS NOT NULL) AS ok_private,
         COUNT_IF(is_success AND privatelink_id IS NULL) AS ok_public,
         COUNT_IF(NOT is_success) AS failed_requests,
         COUNT(DISTINCT IFF(is_success AND privatelink_id IS NULL, client_ip, NULL)) AS public_client_ips
  FROM raw
  GROUP BY 1
),
admin AS (
  SELECT DISTINCT UPPER(user_name) AS user_key
  FROM sf_sec_user_roles
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN')
),
j AS (
  SELECT i.*, u.user_id, a.user_key IS NOT NULL AS is_admin,
         SUM(IFF(i.user_name = '(unknown)', 0, i.ok_private)) OVER ()
           / NULLIF(SUM(IFF(i.user_name = '(unknown)', 0, i.ok_private + i.ok_public)) OVER (), 0) AS account_private_share
  FROM ing i
  LEFT JOIN sf_sec_users u ON UPPER(u.user_name) = UPPER(i.user_name)
  LEFT JOIN admin a ON a.user_key = UPPER(i.user_name)
),
s AS (
  SELECT j.*, COALESCE(account_private_share >= :min_private_share, FALSE) AS uses_private_link,
         COALESCE(account_private_share >= :min_private_share, FALSE) AND ok_public > 0 AS bypass
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, is_admin, ok_private, ok_public,
       failed_requests, public_client_ips, account_private_share, uses_private_link,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(bypass, ok_public || ' public requests from ' || public_client_ips || ' addresses', NULL),
         IFF(bypass AND is_admin, 'holds an admin role', NULL)), '; ') AS reasons,
       IFF(account_private_share IS NULL, 'no_successful_requests', NULL) AS not_assessed_reason,
       CASE
         WHEN account_private_share IS NULL THEN 'NOT_ASSESSED'
         WHEN bypass AND is_admin THEN 'CRITICAL'
         WHEN bypass THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END, ok_public DESC, user_name
