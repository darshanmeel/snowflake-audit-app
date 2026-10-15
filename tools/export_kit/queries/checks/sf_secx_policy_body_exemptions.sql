-- query_id: sf_secx_policy_body_exemptions
-- title: Who a masking or row access policy lets through, read from its body
-- domain: governance_access   tier: standard
-- entity: policies = policy_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES, SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :warn_exempt_users (default 25) exempt users: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live masking or row access policy. exempt_roles lists the account roles
--   named as quoted literals in the policy body (typically the roles allowed clear text or rows);
--   exempt_users counts users who can use any of them, directly or through the hierarchy. context_check
--   tells how the body decides: IS_ROLE_IN_SESSION (inherited and secondary roles count), CURRENT_ROLE
--   (primary role only), a mapping-table lookup, or NONE (same answer for everyone).
-- healthy: status = OK when a few named functional roles are exempt and the policy is attached.
-- investigate_if: WARN when :warn_exempt_users+ users fall under the exemptions, the body names
--   ACCOUNTADMIN / SECURITYADMIN / SYSADMIN / ORGADMIN (admins then see clear text everywhere), or the
--   body has no role or user check at all; CRITICAL when the body names PUBLIC, so every user is
--   exempt. NOT_ASSESSED when the body only looks roles up in a mapping table, whose rows are not read
--   here.
-- actions: 1) exempt a dedicated reader role, not admin roles or PUBLIC (free); 2) prefer
--   IS_ROLE_IN_SESSION with a narrow role, or a mapping table owned by a governance role (config); 3)
--   review who holds the exempt roles (free)
-- next: none
-- caveats: role names are found by matching quoted literals against live role names, so dynamic names,
--   database roles and user-based conditions are missed; the body is only readable when the audit role
--   can see it. Lags up to 2 hours.
WITH -- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
-- every role a user can use through a direct grant. A child role is NAME, its parent GRANTEE_NAME.
sf_sec_role_reach AS (
  SELECT name AS top_role, name AS role_name, 0 AS depth, CAST(name AS VARCHAR) AS path
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT r.top_role, g.name, r.depth + 1, r.path || ' > ' || g.name
  FROM sf_sec_role_reach r
  JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
    ON g.grantee_name = r.role_name AND g.granted_on = 'ROLE' AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
   AND g.privilege = 'USAGE' AND g.deleted_on IS NULL
  -- Snowflake forbids cycles; the cap only guards against a malformed history.
  WHERE r.depth < 20
),
sf_sec_user_roles AS (
  SELECT gu.grantee_name AS user_name, gu.role AS granted_role, r.role_name, r.depth, r.path
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu
  JOIN sf_sec_role_reach r ON r.top_role = gu.role
  WHERE gu.deleted_on IS NULL
),
pol AS (
  SELECT 'MASKING_POLICY' AS policy_kind, policy_id, policy_catalog AS database_name, policy_schema AS schema_name,
         policy_name, policy_owner, policy_body
  FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES
  WHERE deleted IS NULL
  UNION ALL
  SELECT 'ROW_ACCESS_POLICY', policy_id, policy_catalog, policy_schema, policy_name, policy_owner, policy_body
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES
  WHERE deleted IS NULL
),
lits AS (
  SELECT p.policy_id, p.policy_kind, UPPER(TO_VARCHAR(f.value)) AS literal
  FROM pol p,
       LATERAL FLATTEN(input => REGEXP_SUBSTR_ALL(p.policy_body, '''([A-Za-z0-9_$]+)''', 1, 1, 'e', 1)) f
),
roles_ AS (
  SELECT name AS role_name FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES WHERE deleted_on IS NULL
),
exempt AS (
  SELECT DISTINCT l.policy_id, l.policy_kind, r.role_name
  FROM lits l JOIN roles_ r ON r.role_name = l.literal
),
ex_users AS (
  SELECT e.policy_id, e.policy_kind, COUNT(DISTINCT ur.user_name) AS exempt_users
  FROM exempt e JOIN sf_sec_user_roles ur ON ur.role_name = e.role_name
  GROUP BY 1, 2
),
ex_roles AS (
  SELECT policy_id, policy_kind, LISTAGG(role_name, ', ') WITHIN GROUP (ORDER BY role_name) AS exempt_roles,
         BOOLOR_AGG(role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'ORGADMIN')) AS exempts_admin,
         BOOLOR_AGG(role_name = 'PUBLIC') AS exempts_public
  FROM exempt GROUP BY 1, 2
),
refs AS (
  SELECT policy_id, policy_kind, COUNT(*) AS attachments
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  WHERE policy_kind IN ('MASKING_POLICY', 'ROW_ACCESS_POLICY')
  GROUP BY 1, 2
),
j AS (
  SELECT p.policy_kind, p.policy_id, p.database_name, p.schema_name, p.policy_name, p.policy_owner,
         CASE
           WHEN REGEXP_LIKE(p.policy_body, '.*IS_(DATABASE_)?ROLE_IN_SESSION.*', 'is') THEN 'IS_ROLE_IN_SESSION'
           WHEN REGEXP_LIKE(p.policy_body, '.*(CURRENT_ROLE|INVOKER_ROLE|IS_GRANTED_TO_INVOKER_ROLE).*', 'is') THEN 'CURRENT_ROLE'
           WHEN REGEXP_LIKE(p.policy_body, '.*(CURRENT_USER|CURRENT_ACCOUNT|INVOKER_SHARE|CURRENT_CLIENT).*', 'is') THEN 'USER_OR_ACCOUNT'
           WHEN REGEXP_LIKE(p.policy_body, '.*(SELECT|EXISTS)\\s.*', 'is') THEN 'MAPPING_TABLE'
           ELSE 'NONE'
         END AS context_check,
         REGEXP_LIKE(p.policy_body, '.*(SELECT|EXISTS)\\s.*', 'is') AS uses_lookup,
         p.policy_body IS NULL AS body_hidden,
         r.exempt_roles, COALESCE(r.exempts_admin, FALSE) AS exempts_admin,
         COALESCE(r.exempts_public, FALSE) AS exempts_public, COALESCE(u.exempt_users, 0) AS exempt_users,
         COALESCE(rf.attachments, 0) AS attachments
  FROM pol p
  LEFT JOIN ex_roles r ON r.policy_id = p.policy_id AND r.policy_kind = p.policy_kind
  LEFT JOIN ex_users u ON u.policy_id = p.policy_id AND u.policy_kind = p.policy_kind
  LEFT JOIN refs rf ON rf.policy_id = p.policy_id AND rf.policy_kind = p.policy_kind
),
s AS (
  SELECT j.*,
         CASE
           WHEN body_hidden THEN 'NOT_ASSESSED'
           WHEN exempts_public THEN 'CRITICAL'
           WHEN exempts_admin OR exempt_users >= :warn_exempt_users OR context_check = 'NONE' THEN 'WARN'
           WHEN exempt_roles IS NULL AND uses_lookup THEN 'NOT_ASSESSED'
           ELSE 'OK'
         END AS status
  FROM j
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, policy_kind, TO_VARCHAR(policy_id) AS policy_id,
       database_name, schema_name, policy_name, database_name || '.' || schema_name || '.' || policy_name AS policy_fqn,
       policy_owner, attachments, context_check, uses_lookup, exempt_roles, exempt_users, exempts_admin, exempts_public,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(exempts_public, 'body names PUBLIC: every user is exempt', NULL),
         IFF(exempts_admin, 'admin roles are exempt', NULL),
         IFF(exempt_users >= :warn_exempt_users, exempt_users || ' users hold an exempt role', NULL),
         IFF(context_check = 'NONE' AND NOT body_hidden, 'no role or user check in the body', NULL),
         IFF(uses_lookup, 'uses a lookup table', NULL),
         IFF(attachments = 0, 'not attached', NULL)), '; ') AS reasons,
       CASE WHEN body_hidden THEN 'policy body not visible to the audit role'
            WHEN status = 'NOT_ASSESSED' THEN 'exemptions come from a mapping table that is not read' END AS not_assessed_reason,
       status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END,
         exempt_users DESC, policy_fqn
