-- query_id: sf_sec_account_security_settings
-- title: Account-level security parameters and policies
-- domain: governance_access   tier: standard
-- entity: settings = setting
-- windowed: no
-- pre: SHOW PARAMETERS IN ACCOUNT
-- reads: SHOW PARAMETERS IN ACCOUNT
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account setting that limits data exfiltration or credential risk: selected
--   account parameters (value, default, level). recommended is the safer value; is_recommended compares
--   against it. Session and authentication policies are read by their own checks.
-- healthy: status = OK when the setting has the recommended value.
-- investigate_if: WARN when an exfiltration or session guard is at its permissive value; CRITICAL when no network policy is set on
--   the account and unloads to inline URLs are allowed.
-- actions: 1) ALTER ACCOUNT SET PREVENT_UNLOAD_TO_INLINE_URL = TRUE and
--   REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_* = TRUE once no job needs ad-hoc credentials (config); 2)
--   set a network policy (config)
-- next: none
-- caveats: password, session and authentication policies are not listed in POLICY_REFERENCES, so
--   they are not read here. Parameters that do not exist on the account edition or region simply have no row; a stricter
--   user-level override is not visible here.
WITH p AS (
  SELECT UPPER(s."key") AS setting, s."value" AS value, s."default" AS default_value, s."level" AS level
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
),
want AS (
  SELECT column1 AS setting, column2 AS recommended, column3 AS severity, column4 AS why
  FROM VALUES
    ('NETWORK_POLICY', '<set>', 'WARN', 'restricts where sign-ins come from'),
    ('PREVENT_UNLOAD_TO_INLINE_URL', 'true', 'WARN', 'blocks COPY INTO a URL with inline credentials'),
    ('REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_CREATION', 'true', 'WARN', 'stages must use a governed integration'),
    ('REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_OPERATION', 'true', 'WARN', 'loads and unloads must use a governed integration'),
    ('PREVENT_UNLOAD_TO_INTERNAL_STAGES', 'true', 'OK', 'stops unloads to user/table stages (optional)'),
    ('CLIENT_SESSION_KEEP_ALIVE', 'false', 'WARN', 'sessions should expire when idle'),
    ('ALLOW_CLIENT_MFA_CACHING', 'false', 'OK', 'cached MFA tokens weaken MFA (optional)'),
    ('ALLOW_ID_TOKEN', 'false', 'OK', 'cached SSO tokens outlive the browser session (optional)'),
    ('PERIODIC_DATA_REKEYING', 'true', 'OK', 'yearly re-encryption (Enterprise, optional)'),
    ('ENABLE_UNREDACTED_QUERY_SYNTAX_ERROR', 'false', 'WARN', 'failed statements may log secrets in clear'),
    ('ENABLE_UNREDACTED_SECURE_OBJECT_ERROR', 'false', 'WARN', 'errors may reveal secure object internals')
),
params AS (
  SELECT w.setting, 'PARAMETER' AS kind, p.value, p.default_value, p.level, w.recommended, w.why,
         COALESCE(CASE WHEN w.recommended = '<set>' THEN NULLIF(TRIM(p.value), '') IS NOT NULL
                       ELSE LOWER(p.value) = w.recommended END, FALSE) AS is_recommended,
         w.severity
  FROM want w JOIN p ON p.setting = w.setting
),
allrows AS (
  SELECT * FROM params
),
flags AS (
  SELECT MAX(IFF(setting = 'NETWORK_POLICY' AND NOT is_recommended, 1, 0)) AS no_np,
         MAX(IFF(setting = 'PREVENT_UNLOAD_TO_INLINE_URL' AND NOT is_recommended, 1, 0)) AS inline_unload
  FROM allrows
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, r.setting, r.kind, r.value AS current_value,
       r.default_value, r.level AS set_at_level, r.recommended, r.is_recommended, r.why,
       IFF(r.is_recommended, NULL, r.setting || ' is ' || COALESCE(NULLIF(r.value, ''), 'not set') || '; ' || r.why) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN r.is_recommended THEN 'OK'
         WHEN r.setting IN ('NETWORK_POLICY', 'PREVENT_UNLOAD_TO_INLINE_URL') AND f.no_np = 1 AND f.inline_unload = 1 THEN 'CRITICAL'
         ELSE r.severity
       END AS status
FROM allrows r CROSS JOIN flags f
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, r.kind, r.setting
