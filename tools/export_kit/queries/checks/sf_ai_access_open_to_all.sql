-- query_id: sf_ai_access_open_to_all
-- title: Cortex AI open to every user (PUBLIC holds USE AI FUNCTIONS or CORTEX_USER, models 'All')
-- domain: serving_ai   tier: standard
-- entity: access paths = access_path
-- windowed: yes
-- pre: SHOW PARAMETERS LIKE 'CORTEX_MODELS_ALLOWLIST' IN ACCOUNT
-- reads: SHOW PARAMETERS IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- empty_if: role_cannot_see
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- not_assessed_reasons: privilege_not_listed: GRANTS_TO_ROLES has no USE AI FUNCTIONS grant at all (the
--   privilege has not reached this account yet, or the role cannot see account grants);
--   grant_not_listed: GRANTS_TO_ROLES does not list the SNOWFLAKE.CORTEX_USER database role, so who holds
--   it is not known; parameter_not_listed: SHOW PARAMETERS did not return CORTEX_MODELS_ALLOWLIST (it was
--   removed, or the role cannot see it), so model access rests on model RBAC, which this check does not read
-- read_this: one row = one way into Cortex AI functions. use_ai_functions: the USE AI FUNCTIONS account
--   privilege; cortex_user: the SNOWFLAKE.CORTEX_USER database role; models_allowlist: the
--   CORTEX_MODELS_ALLOWLIST parameter. Snowflake grants the first two to PUBLIC by default, and the
--   allowlist defaults to 'All', so every user can call every model. open_to_public is TRUE when PUBLIC
--   holds the grant now. other_roles counts the other roles granted it directly. ai_users and ai_credits
--   are who called AI functions in the window and the AI credits they used: context, not a cost of this
--   finding.
-- healthy: status = OK when PUBLIC holds neither grant and the allowlist is a list of models or 'None'.
-- investigate_if: WARN when PUBLIC holds a grant, or the allowlist is 'All'; CRITICAL when PUBLIC holds a
--   grant and the allowlist is 'All' too (every user, every model, no budget).
-- actions: 1) REVOKE USE AI FUNCTIONS ON ACCOUNT FROM ROLE PUBLIC and REVOKE DATABASE ROLE
--   SNOWFLAKE.CORTEX_USER FROM ROLE PUBLIC, then grant them to the roles that need AI (free); 2) limit
--   models with model RBAC (the SNOWFLAKE."CORTEX-MODEL-ROLE-<model>" application roles) and drop the
--   bootstrap grant of CORTEX-MODEL-ROLE-ALL to SNOWFLAKE.PUBLIC (config); 3) set a budget on AI
--   services (config)
-- next: sf_ai_functions_spend_by_user, sf_ai_credits_on_failed_queries
-- caveats: CORTEX_MODELS_ALLOWLIST is being retired: once Snowflake's 2026_07 behavior change is on, model
--   access is decided by model RBAC only, which needs SHOW GRANTS TO APPLICATION ROLE SNOWFLAKE.PUBLIC
--   and is not read here. Direct grants only: a role that reaches the privilege through another role is
--   not counted in other_roles. GRANTS_TO_ROLES lags up to 2 hours.
WITH g AS (
  SELECT CASE WHEN granted_on = 'ACCOUNT' AND privilege = 'USE AI FUNCTIONS' THEN 'use_ai_functions'
              WHEN granted_on = 'DATABASE_ROLE' AND privilege = 'USAGE'
                   AND UPPER(name) IN ('SNOWFLAKE.CORTEX_USER', 'CORTEX_USER')
                   AND COALESCE(UPPER(table_catalog), 'SNOWFLAKE') = 'SNOWFLAKE' THEN 'cortex_user' END AS access_path,
         grantee_name, granted_to, created_on, deleted_on, granted_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE (granted_on = 'ACCOUNT' AND privilege = 'USE AI FUNCTIONS')
     OR (granted_on = 'DATABASE_ROLE' AND privilege = 'USAGE' AND UPPER(name) IN ('SNOWFLAKE.CORTEX_USER', 'CORTEX_USER'))
),
-- GRANTED_TO reads 'ACCOUNT ROLE' in the docs and 'ROLE' on live accounts: match both.
pub AS (
  SELECT access_path,
         COUNT(*) AS grant_rows,
         COUNT_IF(grantee_name = 'PUBLIC' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL) > 0 AS open_to_public,
         MAX(IFF(grantee_name = 'PUBLIC' AND deleted_on IS NULL, created_on, NULL)) AS public_granted_on,
         MAX(IFF(grantee_name = 'PUBLIC', deleted_on, NULL)) AS public_revoked_on,
         COUNT(DISTINCT IFF(grantee_name <> 'PUBLIC' AND deleted_on IS NULL AND granted_to IN ('ROLE', 'ACCOUNT ROLE'),
                            grantee_name, NULL)) AS other_roles
  FROM g
  GROUP BY access_path
),
paths AS (
  SELECT column1 AS access_path FROM VALUES ('use_ai_functions'), ('cortex_user')
),
al AS (
  SELECT MAX(TRIM(p."value")) AS allowlist, MAX(p."level") AS allowlist_level
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) p
  WHERE UPPER(p."key") = 'CORTEX_MODELS_ALLOWLIST'
),
use_ AS (
  SELECT COUNT(DISTINCT user_id) AS ai_users, SUM(credits) AS ai_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
grants_ AS (
  SELECT pa.access_path, COALESCE(pub.grant_rows, 0) AS grant_rows, pub.open_to_public, pub.public_granted_on,
         pub.public_revoked_on, pub.other_roles, CAST(NULL AS VARCHAR) AS setting_value
  FROM paths pa
  LEFT JOIN pub ON pub.access_path = pa.access_path
),
rows_ AS (
  SELECT access_path, grant_rows, IFF(grant_rows = 0, NULL, COALESCE(open_to_public, FALSE)) AS open_to_public,
         public_granted_on, public_revoked_on, other_roles, setting_value
  FROM grants_
  UNION ALL
  SELECT 'models_allowlist', NULL, CAST(NULL AS BOOLEAN), CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS TIMESTAMP_LTZ),
         CAST(NULL AS NUMBER), (SELECT allowlist FROM al)
),
j AS (
  SELECT r.*, (SELECT allowlist FROM al) AS allowlist,
         (SELECT COUNT_IF(open_to_public) FROM grants_ WHERE grant_rows > 0) > 0 AS any_public
  FROM rows_ r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, access_path,
       CASE access_path WHEN 'use_ai_functions' THEN 'USE AI FUNCTIONS on the account'
                        WHEN 'cortex_user' THEN 'SNOWFLAKE.CORTEX_USER database role'
                        ELSE 'CORTEX_MODELS_ALLOWLIST parameter' END AS access_label,
       open_to_public, public_granted_on, public_revoked_on, other_roles, setting_value,
       (SELECT ai_users FROM use_) AS ai_users, (SELECT ai_credits FROM use_) AS ai_credits,
       CASE WHEN access_path = 'use_ai_functions' AND grant_rows = 0 THEN 'privilege_not_listed'
            WHEN access_path = 'cortex_user' AND grant_rows = 0 THEN 'grant_not_listed'
            WHEN access_path = 'models_allowlist' AND setting_value IS NULL THEN 'parameter_not_listed' END AS not_assessed_reason,
       CASE
         WHEN access_path <> 'models_allowlist' AND grant_rows = 0 THEN 'NOT_ASSESSED'
         WHEN access_path = 'models_allowlist' AND setting_value IS NULL THEN 'NOT_ASSESSED'
         WHEN access_path = 'models_allowlist' AND UPPER(setting_value) = 'ALL' AND any_public THEN 'CRITICAL'
         WHEN access_path = 'models_allowlist' AND UPPER(setting_value) = 'ALL' THEN 'WARN'
         WHEN access_path = 'models_allowlist' THEN 'OK'
         WHEN open_to_public AND UPPER(COALESCE(allowlist, '')) = 'ALL' THEN 'CRITICAL'
         WHEN open_to_public THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE access_path WHEN 'use_ai_functions' THEN 0 WHEN 'cortex_user' THEN 1 ELSE 2 END
