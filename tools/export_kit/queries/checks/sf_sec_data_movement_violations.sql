-- query_id: sf_sec_data_movement_violations
-- title: Data movement policy hits: who moved protected tables to stages, downloads or agents
-- domain: governance_access   tier: standard
-- entity: users = user_name, movement_type
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATA_MOVEMENT_VIOLATIONS, SNOWFLAKE.ACCOUNT_USAGE.DATA_MOVEMENT_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (data movement policies)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_blocked (default 5) blocked queries: one user with this many blocked attempts flags
-- empty_if: edition_too_low, view_missing, role_cannot_see, no_activity
-- not_assessed_reasons: no_policies_visible: no data movement policy is visible to this role (none exist, or
--   the role cannot see them), so nothing can be said about blocked or alerted movement
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Both views list only the objects the role can access.
-- read_this: one row = one user x movement type. blocked_queries were stopped by a policy; alert_only_queries
--   ran but matched an alert rule. tables_touched counts the distinct tables involved. live_policies is
--   how many data movement policies this role can see.
-- healthy: status = OK when the user has no alert-only copy to an external stage, programmatic fetch or agent access and
--   fewer than :warn_blocked blocked attempts.
-- investigate_if: WARN for alert-only movement to COPY_INTO_EXTERNAL_STAGE, PROGRAMMATIC_FETCH or AGENT_ACCESS (allowed
--   today, flagged by the policy) and for :warn_blocked or more blocked attempts by one user.
-- actions: 1) ask the user why they moved the tables and whether the destination is approved (free); 2)
--   switch the alert-only rule to block for the movement types nobody should use (config); 3) attach the
--   policy to the tables that hold sensitive data (config)
-- next: sf_gov_data_egress
-- caveats: No query text is read; only the query count, table names and the policy name are kept. A missing
--   violation is not proof of no movement: only tables with a policy attached are watched. Downloads from
--   the Snowsight results grid (UI_DOWNLOAD) are not in this view. Lags up to 3 hours.
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
v AS (
  SELECT d.user_name, d.movement_type, d.query_id, d.enforced_policy, d.alerted_policies, d.timestamp AS event_time,
         TO_VARCHAR(f.value) AS entity
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_MOVEMENT_VIOLATIONS d,
       LATERAL FLATTEN(input => d.data_entities, outer => TRUE) f
  WHERE d.timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND d.timestamp < __AS_OF_DATE__
),
a AS (
  SELECT COALESCE(user_name, '(unknown)') AS user_name, COALESCE(movement_type, '(unknown)') AS movement_type,
         COUNT(DISTINCT IFF(enforced_policy IS NOT NULL, query_id, NULL)) AS blocked_queries,
         COUNT(DISTINCT IFF(enforced_policy IS NULL AND alerted_policies IS NOT NULL, query_id, NULL)) AS alert_only_queries,
         COUNT(DISTINCT entity) AS tables_touched,
         MAX(LEFT(COALESCE(enforced_policy, alerted_policies), 200)) AS policy_name,
         MIN(event_time) AS first_seen, MAX(event_time) AS last_seen
  FROM v
  GROUP BY 1, 2
),
p AS (
  SELECT COUNT_IF(deleted IS NULL) AS live_policies FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_MOVEMENT_POLICIES
),
r AS (
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, u.user_id, a.user_name, a.movement_type,
         a.blocked_queries, a.alert_only_queries, a.tables_touched, a.policy_name, a.first_seen, a.last_seen,
         p.live_policies,
         ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           IFF(a.alert_only_queries > 0 AND a.movement_type IN ('COPY_INTO_EXTERNAL_STAGE', 'PROGRAMMATIC_FETCH', 'AGENT_ACCESS'),
               a.alert_only_queries || ' alert-only queries to ' || a.movement_type, NULL),
           IFF(a.blocked_queries >= :warn_blocked, a.blocked_queries || ' blocked attempts', NULL)), '; ') AS reasons,
         CAST(NULL AS VARCHAR) AS not_assessed_reason,
         CASE
           WHEN a.alert_only_queries > 0 AND a.movement_type IN ('COPY_INTO_EXTERNAL_STAGE', 'PROGRAMMATIC_FETCH', 'AGENT_ACCESS') THEN 'WARN'
           WHEN a.blocked_queries >= :warn_blocked THEN 'WARN'
           ELSE 'OK'
         END AS status
  FROM a
  CROSS JOIN p
  LEFT JOIN sf_sec_users u ON UPPER(u.user_name) = UPPER(a.user_name)
  UNION ALL
  SELECT :period_days, __ACCOUNT_ID__, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
         CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR),
         CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS TIMESTAMP_LTZ), p.live_policies, CAST(NULL AS VARCHAR),
         'no_policies_visible', 'NOT_ASSESSED'
  FROM p
  WHERE p.live_policies = 0 AND NOT EXISTS (SELECT 1 FROM a)
)
SELECT * FROM r
ORDER BY CASE status WHEN 'WARN' THEN 0 WHEN 'NOT_ASSESSED' THEN 1 ELSE 2 END, blocked_queries DESC NULLS LAST, user_name
