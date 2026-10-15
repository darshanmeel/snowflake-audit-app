-- query_id: sf_secx_sso_oauth_integrations
-- title: SSO and OAuth integrations versus how people really sign in
-- domain: governance_access   tier: standard
-- entity: integrations = integration_name
-- windowed: yes
-- pre: SHOW SECURITY INTEGRATIONS
-- reads: SHOW SECURITY INTEGRATIONS, SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_password_pct (default 20) password pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one SAML2, OAuth (Snowflake or custom), external OAuth or SCIM security
--   integration, or a single NO_INTEGRATION row when the account has none. matching_logins counts
--   successful sign-ins in the window with the factor that integration issues (SAML2_ASSERTION for
--   SAML2, OAUTH_ACCESS_TOKEN for OAuth); it is account-wide, because LOGIN_HISTORY does not name the
--   integration. person_password_pct is the share of PERSON-user sign-ins that still used a password;
--   person_users_with_password counts enabled PERSON users that keep one.
-- healthy: status = OK when an enabled SSO integration carries most person sign-ins, passwords are
--   rare, and every enabled OAuth integration is in use.
-- investigate_if: WARN when SAML2 is enabled but :warn_password_pct%+ of person sign-ins still use a
--   password (SSO can be bypassed), an enabled integration had no matching sign-ins in the window, a
--   custom OAuth client is enabled (its blocked roles and refresh-token validity need review), or there
--   is no SSO at all while people sign in with passwords.
-- actions: 1) UNSET PASSWORD for people who sign in through SSO so the IdP's MFA cannot be skipped
--   (free); 2) DESCRIBE SECURITY INTEGRATION on each OAuth client: keep ACCOUNTADMIN / SECURITYADMIN in
--   BLOCKED_ROLES_LIST, OAUTH_REFRESH_TOKEN_VALIDITY short and OAUTH_ISSUE_REFRESH_TOKENS off where not
--   needed (config); 3) disable integrations nothing uses (free)
-- next: none
-- caveats: blocked roles, redirect URIs and token validity are only visible with DESCRIBE per
--   integration and are not read here. SHOW lists what the audit role can see; LOGIN_HISTORY lags up to
--   2 hours. SSO sign-ins with no integration in SHOW read NOT_ASSESSED (integrations_not_visible), never
--   "no SSO".
WITH si AS (
  SELECT x."name" AS integration_name, UPPER(x."type") AS integration_type,
         LOWER(TO_VARCHAR(x."enabled")) = 'true' AS is_enabled, x."created_on" AS created_on,
         x."comment" AS integration_comment
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) x
  WHERE UPPER(x."type") LIKE 'SAML2%' OR UPPER(x."type") LIKE 'OAUTH%'
     OR UPPER(x."type") LIKE 'EXTERNAL_OAUTH%' OR UPPER(x."type") LIKE 'SCIM%'
),
persons AS (
  SELECT name AS user_name, COALESCE(has_password, FALSE) AS has_password
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL AND COALESCE(UPPER(type), 'PERSON') = 'PERSON'
    AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)
),
lg AS (
  SELECT COUNT_IF(l.first_authentication_factor = 'SAML2_ASSERTION') AS saml_logins,
         COUNT_IF(l.first_authentication_factor = 'OAUTH_ACCESS_TOKEN') AS oauth_logins,
         COUNT_IF(p.user_name IS NOT NULL) AS person_logins,
         COUNT_IF(p.user_name IS NOT NULL AND l.first_authentication_factor = 'PASSWORD') AS person_password_logins,
         COUNT(DISTINCT IFF(p.user_name IS NOT NULL AND l.first_authentication_factor = 'PASSWORD', l.user_name, NULL)) AS person_password_users
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY l
  LEFT JOIN persons p ON p.user_name = l.user_name
  WHERE l.event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND l.event_timestamp < __AS_OF_DATE__
    AND l.is_success = 'YES'
),
acct AS (
  SELECT lg.*, (SELECT COUNT_IF(has_password) FROM persons) AS person_users_with_password,
         ROUND(100 * person_password_logins / NULLIF(person_logins, 0), 1) AS person_password_pct,
         (SELECT COUNT_IF(is_enabled AND integration_type LIKE 'SAML2%') FROM si) AS enabled_saml
  FROM lg
),
rows_ AS (
  SELECT integration_name, integration_type, is_enabled, created_on, integration_comment,
         CASE WHEN integration_type LIKE 'SAML2%' THEN 'SAML2_ASSERTION'
              WHEN integration_type LIKE 'OAUTH%' OR integration_type LIKE 'EXTERNAL_OAUTH%' THEN 'OAUTH_ACCESS_TOKEN'
         END AS login_factor
  FROM si
  UNION ALL
  SELECT 'NO_INTEGRATION', 'NONE', FALSE, CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR)
  FROM (SELECT 1 AS one) WHERE NOT EXISTS (SELECT 1 FROM si)
),
j AS (
  SELECT r.*, a.person_logins, a.person_password_logins, a.person_password_users, a.person_password_pct,
         a.person_users_with_password, a.enabled_saml, a.saml_logins + a.oauth_logins AS sso_logins,
         CASE r.login_factor WHEN 'SAML2_ASSERTION' THEN a.saml_logins
                             WHEN 'OAUTH_ACCESS_TOKEN' THEN a.oauth_logins END AS matching_logins
  FROM rows_ r CROSS JOIN acct a
),
s AS (
  SELECT j.*,
         (is_enabled AND integration_type LIKE 'SAML2%' AND person_password_pct >= :warn_password_pct) AS sso_bypassed,
         (is_enabled AND login_factor IS NOT NULL AND COALESCE(matching_logins, 0) = 0) AS unused,
         (is_enabled AND integration_type LIKE 'OAUTH%CUSTOM%') AS custom_oauth,
         -- SHOW lists nothing yet people signed in through SAML or OAuth: the role cannot see the integrations
         (integration_name = 'NO_INTEGRATION' AND sso_logins > 0) AS hidden_integrations,
         (integration_name = 'NO_INTEGRATION' AND person_password_logins > 0 AND sso_logins = 0) AS passwords_only
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, integration_name, integration_type,
       is_enabled, created_on, login_factor, matching_logins, person_logins, person_password_logins,
       person_password_users, person_password_pct, person_users_with_password, integration_comment,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NOT is_enabled AND integration_name <> 'NO_INTEGRATION', 'disabled', NULL),
         IFF(sso_bypassed, person_password_pct || '% of person sign-ins still use a password', NULL),
         IFF(unused, 'enabled but no ' || login_factor || ' sign-ins in the window', NULL),
         IFF(custom_oauth, 'custom OAuth client: review BLOCKED_ROLES_LIST and refresh-token validity', NULL),
         IFF(passwords_only, 'no SSO or OAuth integration; ' || person_password_users || ' people sign in with passwords', NULL)),
         '; ') AS reasons,
       IFF(hidden_integrations, 'integrations_not_visible', NULL) AS not_assessed_reason,
       CASE WHEN hidden_integrations THEN 'NOT_ASSESSED'
            WHEN sso_bypassed OR unused OR custom_oauth OR passwords_only THEN 'WARN' ELSE 'OK' END AS status
FROM s
ORDER BY CASE status WHEN 'WARN' THEN 0 ELSE 1 END, integration_type, integration_name
