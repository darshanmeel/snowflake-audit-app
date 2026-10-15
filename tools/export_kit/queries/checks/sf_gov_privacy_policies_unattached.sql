-- query_id: sf_gov_privacy_policies_unattached
-- title: Aggregation and projection policies attached nowhere, or attached in a broken state
-- domain: governance_access   tier: standard
-- entity: policies = policy_kind, policy_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.AGGREGATION_POLICIES, SNOWFLAKE.ACCOUNT_USAGE.PROJECTION_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (aggregation and projection
--   policies)
-- params: :min_age_days (default 14) days: a policy younger than this is not flagged as unattached
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The POLICY_KIND values for these two kinds are matched by
--   prefix (AGGREGATION, PROJECTION) because the docs list the kinds without their spelling. Non-ACTIVE
--   statuses are documented for masking and row access argument mapping and may never occur for these kinds.
-- read_this: one row = one live aggregation or projection policy. attachments counts the objects it is
--   attached to, non_active_attachments those whose POLICY_STATUS is not ACTIVE.
-- healthy: status = OK when the policy is attached and every attachment is ACTIVE, or it is younger than
--   :min_age_days.
-- investigate_if: WARN when the policy is older than :min_age_days and attached nowhere; CRITICAL when an
--   attachment is not ACTIVE (the policy is not protecting that object).
-- actions: 1) attach the policy to the tables or columns it was written for, or drop it (config); 2) fix
--   the attachment that is not ACTIVE: match the column and its data type (free); 3) record who owns each
--   policy (free)
-- next: sf_secx_unused_policies
-- caveats: Both policy views and POLICY_REFERENCES list only the objects the role can access, so a policy
--   attached to objects the role cannot see reads as unattached. The policy body is never read. Lags up to
--   2 hours.
WITH pol AS (
  SELECT 'AGGREGATION_POLICY' AS policy_kind, policy_id, policy_name, policy_catalog AS database_name,
         policy_schema AS schema_name, created
  FROM SNOWFLAKE.ACCOUNT_USAGE.AGGREGATION_POLICIES
  WHERE deleted IS NULL
  UNION ALL
  SELECT 'PROJECTION_POLICY', policy_id, policy_name, policy_catalog, policy_schema, created
  FROM SNOWFLAKE.ACCOUNT_USAGE.PROJECTION_POLICIES
  WHERE deleted IS NULL
),
refs AS (
  SELECT policy_id,
         CASE WHEN UPPER(policy_kind) LIKE 'AGGREGATION%' THEN 'AGGREGATION_POLICY'
              WHEN UPPER(policy_kind) LIKE 'PROJECTION%' THEN 'PROJECTION_POLICY' END AS policy_kind,
         COUNT(*) AS attachments,
         COUNT_IF(UPPER(COALESCE(policy_status, 'ACTIVE')) <> 'ACTIVE') AS non_active_attachments
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  WHERE UPPER(policy_kind) LIKE 'AGGREGATION%' OR UPPER(policy_kind) LIKE 'PROJECTION%'
  GROUP BY 1, 2
),
s AS (
  SELECT pol.policy_kind, pol.policy_name, pol.database_name, pol.schema_name,
         DATEDIFF(day, pol.created, __AS_OF_DATE__) AS age_days,
         COALESCE(refs.attachments, 0) AS attachments,
         COALESCE(refs.non_active_attachments, 0) AS non_active_attachments
  FROM pol
  LEFT JOIN refs ON refs.policy_id = pol.policy_id AND refs.policy_kind = pol.policy_kind
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, policy_kind, policy_name, database_name, schema_name,
       age_days, attachments, non_active_attachments,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(attachments = 0 AND age_days >= :min_age_days, 'attached nowhere for ' || age_days || ' days', NULL),
         IFF(non_active_attachments > 0, non_active_attachments || ' attachments not ACTIVE', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN non_active_attachments > 0 THEN 'CRITICAL'
         WHEN attachments = 0 AND age_days >= :min_age_days THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE WHEN non_active_attachments > 0 THEN 0 WHEN attachments = 0 AND age_days >= :min_age_days THEN 1 ELSE 2 END,
         policy_kind, database_name, schema_name, policy_name
