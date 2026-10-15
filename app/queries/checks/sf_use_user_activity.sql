-- query_id: sf_use_user_activity
-- title: Who uses Snowflake, how much, and who holds roles but runs nothing
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :idle_days (default 90) idle days: value this check uses; :heavy_share_pct (default 10) heavy
--   share pct: value this check uses; :crit_roles (default 5) roles: at or above this the row reads
--   CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one enabled user. queries, active_days and active_weeks count the window;
--   attributed_credits are the user's exact query compute credits and credit_share_pct their part of
--   all users'; is_heavy marks users at heavy_share_pct or more. days_since_last_query looks back
--   idle_days (NULL = no query in that time). granted_roles lists roles granted directly (PUBLIC
--   excluded). avg_daily_active_users / avg_weekly_active_users are account-wide for the window.
-- healthy: status = OK when the user ran queries in the last idle_days, or holds no role.
-- investigate_if: WARN when a user older than idle_days ran no query in idle_days but still holds a
--   role; CRITICAL when such a user holds crit_roles or more roles or an admin role.
-- actions: 1) confirm with the user's manager or the service owner (free); 2) revoke the roles, or
--   disable the user (ALTER USER ... SET DISABLED = TRUE) (free); 3) move role grants to IdP groups via
--   SCIM so leavers lose them automatically (config).
-- next: none
-- caveats: complements sf_sec_stale_users (sign-ins); here "idle" means no query at all, so a user who
--   signs in to Snowsight but runs nothing also shows. Users that only own tasks or run through EXECUTE
--   AS OWNER objects look idle. Query history lags up to 45 minutes.
WITH __INCLUDE_sf_sec_users__,
q AS (
  SELECT user_name, DATE(start_time) AS d, COUNT(*) AS queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -GREATEST(:idle_days, :period_days), __AS_OF_DATE__)
    AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
qu AS (
  SELECT user_name,
         SUM(IFF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__), queries, 0)) AS queries,
         COUNT(DISTINCT IFF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__), d, NULL)) AS active_days,
         COUNT(DISTINCT IFF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__), DATE_TRUNC(week, d), NULL)) AS active_weeks,
         MAX(IFF(d >= DATEADD(day, -:idle_days, __AS_OF_DATE__), d, NULL)) AS last_query_day
  FROM q
  GROUP BY user_name
),
acct AS (
  SELECT COUNT(DISTINCT user_name || '|' || d) / NULLIF(:period_days, 0) AS dau,
         COUNT(DISTINCT user_name || '|' || DATE_TRUNC(week, d))
           / NULLIF(COUNT(DISTINCT DATE_TRUNC(week, d)), 0) AS wau
  FROM q
  WHERE d >= DATEADD(day, -:period_days, __AS_OF_DATE__)
),
cr AS (
  SELECT user_name, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY user_name
),
gr AS (
  SELECT grantee_name AS user_name, COUNT(DISTINCT role) AS role_count,
         LISTAGG(DISTINCT role, ', ') WITHIN GROUP (ORDER BY role) AS granted_roles,
         MAX(IFF(role IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'USERADMIN', 'ORGADMIN'), 1, 0)) = 1 AS has_admin_role
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
  WHERE deleted_on IS NULL AND role <> 'PUBLIC'
  GROUP BY grantee_name
),
s AS (
  SELECT u.user_id, u.user_name, u.user_type, u.default_role, u.created_on, u.last_success_login,
         COALESCE(qu.queries, 0) AS queries, COALESCE(qu.active_days, 0) AS active_days,
         COALESCE(qu.active_weeks, 0) AS active_weeks, qu.last_query_day,
         DATEDIFF(day, qu.last_query_day, __AS_OF_DATE__) AS days_since_last_query,
         COALESCE(cr.credits, 0) AS credits,
         100 * COALESCE(cr.credits, 0) / NULLIF(SUM(cr.credits) OVER (), 0) AS credit_share_pct,
         COALESCE(gr.role_count, 0) AS role_count, gr.granted_roles, COALESCE(gr.has_admin_role, FALSE) AS has_admin_role,
         qu.last_query_day IS NULL AND u.created_on < DATEADD(day, -:idle_days, __AS_OF_DATE__)
           AND COALESCE(gr.role_count, 0) > 0 AS idle_with_roles,
         acct.dau, acct.wau
  FROM sf_sec_users u
  LEFT JOIN qu ON qu.user_name = u.user_name
  LEFT JOIN cr ON cr.user_name = u.user_name
  LEFT JOIN gr ON gr.user_name = u.user_name
  CROSS JOIN acct
  WHERE NOT u.is_disabled
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, user_id, user_type,
       default_role, created_on, last_success_login, queries, active_days, active_weeks,
       last_query_day, days_since_last_query, credits AS attributed_credits, credit_share_pct,
       credit_share_pct >= :heavy_share_pct AS is_heavy,
       RANK() OVER (ORDER BY queries DESC) AS query_rank,
       role_count, granted_roles, has_admin_role, idle_with_roles,
       dau AS avg_daily_active_users, wau AS avg_weekly_active_users,
       credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN idle_with_roles AND (has_admin_role OR role_count >= :crit_roles) THEN 'CRITICAL'
         WHEN idle_with_roles THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, queries DESC
