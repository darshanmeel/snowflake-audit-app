-- query_id: sf_secx_authentication_policy_posture
-- title: Authentication policy settings on the account: MFA, allowed methods and PAT rules
-- domain: governance_access   tier: standard
-- entity: policies = policy_name
-- windowed: no
-- pre: SHOW AUTHENTICATION POLICIES ON ACCOUNT
-- reads: SHOW AUTHENTICATION POLICIES ON ACCOUNT
-- requires: ownership of, or APPLY AUTHENTICATION POLICY on, the account
-- params: :max_pat_days (default 90) days: a PAT maximum expiry above this flags
-- empty_if: role_cannot_see
-- not_assessed_reasons: role_cannot_see: no policy is listed, which can mean the role holds no privilege on them
--   rather than that none exist; options_not_readable: the policy was listed but its options text came back empty or in a shape this check cannot read
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The OPTIONS text format is unconfirmed, so settings
--   are read with loose patterns.
-- read_this: one row = one authentication policy on the account (built-in system policy
--   left out), or one row saying none is visible. mfa_enrollment is as written in the
--   policy (REQUIRED, REQUIRED_PASSWORD_ONLY, OPTIONAL), or unspecified when the policy does not set it; allows_password is TRUE when PASSWORD, or ALL methods, may sign in;
--   pat_max_expiry_days, pat_network_evaluation and pat_role_restriction_required come from its
--   PAT_POLICY. Policies are not listed in POLICY_REFERENCES, so this is their only source.
-- healthy: status = OK when MFA is not explicitly optional for password sign-ins, and PAT expiry is capped within
--   :max_pat_days days with the network policy enforced.
-- investigate_if: WARN when passwords are allowed and MFA enrolment is explicitly OPTIONAL, or PAT rules
--   are loose (long expiry, network policy not enforced, service-user tokens not role-restricted).
-- actions: 1) create an authentication policy with MFA_ENROLLMENT = REQUIRED and only the methods you
--   use, then set it on the account (config); 2) set PAT_POLICY MAX_EXPIRY_IN_DAYS and
--   NETWORK_POLICY_EVALUATION = ENFORCED_REQUIRED (config); 3) test on one user first with ALTER USER
--   SET AUTHENTICATION POLICY (free)
-- next: sf_secx_pat_hygiene
-- caveats: SHOW lists only what the role may see, so no policy listed is not assessed. An unspecified
--   MFA_ENROLLMENT is not necessarily OPTIONAL: the enforced value shows only in DESCRIBE. a user-level policy that overrides the account one
--   is not read here. The options text is parsed for names only, never stored.
WITH raw AS (
  SELECT s."name" AS policy_name, s."database_name" AS database_name, s."schema_name" AS schema_name,
         UPPER(s."set_on") AS set_on, s."options" AS options_text
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
),
pol AS (
  SELECT database_name || '.' || schema_name || '.' || policy_name AS policy_fqn, set_on,
         NULLIF(TRIM(options_text), '') AS o
  FROM raw
  WHERE COALESCE(set_on, 'ACCOUNT') <> 'SYSTEM' AND database_name IS NOT NULL
),
parsed AS (
  SELECT policy_fqn, set_on, o,
         UPPER(REGEXP_SUBSTR(o, 'MFA_ENROLLMENT[^A-Za-z_]+([A-Za-z_]+)', 1, 1, 'i', 1)) AS mfa_enrollment,
         REGEXP_SUBSTR(o, '(^|[^A-Za-z_])AUTHENTICATION_METHODS([^\\]\\)}]*)', 1, 1, 'i', 2) AS methods_text,
         TRY_TO_NUMBER(REGEXP_SUBSTR(o, 'MAX_EXPIRY_IN_DAYS[^0-9A-Za-z]+([0-9]+)', 1, 1, 'i', 1)) AS pat_max_expiry_days,
         UPPER(REGEXP_SUBSTR(o, 'NETWORK_POLICY_EVALUATION[^A-Za-z_]+([A-Za-z_]+)', 1, 1, 'i', 1)) AS pat_network_evaluation,
         UPPER(REGEXP_SUBSTR(o, 'REQUIRE_ROLE_RESTRICTION_FOR_SERVICE_USERS[^A-Za-z]+([A-Za-z]+)', 1, 1, 'i', 1)) AS pat_role_restriction
  FROM pol
),
s AS (
  SELECT policy_fqn, set_on, o IS NOT NULL AS options_read, mfa_enrollment, pat_max_expiry_days, pat_network_evaluation,
         -- No AUTHENTICATION_METHODS key means the default, ALL.
         COALESCE(methods_text IS NULL OR UPPER(methods_text) LIKE '%ALL%' OR UPPER(methods_text) LIKE '%PASSWORD%', TRUE)
           AS allows_password,
         COALESCE(pat_role_restriction, 'TRUE') = 'TRUE' AS pat_role_restriction_required
  FROM parsed
  UNION ALL
  SELECT CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), FALSE, CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER),
         CAST(NULL AS VARCHAR), TRUE, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM pol)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, COALESCE(policy_fqn, 'none visible') AS policy_name, set_on,
       COALESCE(mfa_enrollment, IFF(policy_fqn IS NULL, NULL, 'unspecified')) AS mfa_enrollment, allows_password,
       pat_max_expiry_days, pat_network_evaluation, pat_role_restriction_required,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(policy_fqn IS NULL, 'no authentication policy visible on the account', NULL),
         IFF(options_read AND allows_password AND mfa_enrollment = 'OPTIONAL',
             'passwords allowed and MFA enrolment optional', NULL),
         IFF(options_read AND COALESCE(pat_max_expiry_days, 365) > :max_pat_days,
             'PAT expiry up to ' || COALESCE(pat_max_expiry_days, 365) || ' days', NULL),
         IFF(options_read AND pat_network_evaluation = 'NOT_ENFORCED', 'PAT network policy not enforced', NULL),
         IFF(options_read AND NOT pat_role_restriction_required, 'service-user tokens need no role restriction', NULL)),
         '; ') AS reasons,
       CASE WHEN policy_fqn IS NULL THEN 'role_cannot_see' WHEN NOT options_read THEN 'options_not_readable' END
         AS not_assessed_reason,
       CASE
         WHEN policy_fqn IS NULL OR NOT options_read THEN 'NOT_ASSESSED'
         WHEN allows_password AND mfa_enrollment = 'OPTIONAL' THEN 'WARN'
         WHEN COALESCE(pat_max_expiry_days, 365) > :max_pat_days OR pat_network_evaluation = 'NOT_ENFORCED'
              OR NOT pat_role_restriction_required THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END, policy_name
