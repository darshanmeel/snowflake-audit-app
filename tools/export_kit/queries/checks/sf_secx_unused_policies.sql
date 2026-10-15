-- query_id: sf_secx_unused_policies
-- title: Masking and row access policies that are unattached, broken or never evaluated
-- domain: governance_access   tier: standard
-- entity: policies = policy_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES, SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_age_days (default 14) age days: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live masking or row access policy. attachments counts POLICY_REFERENCES rows
--   (columns, tables, views or tags it is set on); inactive_attachments counts those whose
--   POLICY_STATUS is not ACTIVE (e.g. several masking policies on one column), and inactive_detail says
--   why; queries_evaluated counts queries in the window whose ACCESS_HISTORY lists the policy in
--   POLICIES_REFERENCED.
-- healthy: status = OK when the policy is attached, every attachment is ACTIVE, and queries hit it.
-- investigate_if: WARN when a policy older than :min_age_days days is attached nowhere (someone meant
--   to protect something and did not) or is attached but no query evaluated it in the window (dead
--   data, or the protected objects are read some other way); CRITICAL when an attachment is not ACTIVE,
--   so the policy is not enforced.
-- actions: 1) fix non-ACTIVE attachments (remove the conflicting policy, repair the tag) (free); 2)
--   attach or drop unattached policies (free); 3) check whether objects behind never-evaluated policies
--   are still used (free)
-- next: none
-- caveats: ACCESS_HISTORY needs Enterprise edition and lags up to 3 hours; projection and aggregation
--   policies are not listed. A tag-based masking policy counts as attached once the tag carries it.
WITH pol AS (
  SELECT 'MASKING_POLICY' AS policy_kind, policy_id, policy_catalog AS database_name, policy_schema AS schema_name,
         policy_name, policy_owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES
  WHERE deleted IS NULL
  UNION ALL
  SELECT 'ROW_ACCESS_POLICY', policy_id, policy_catalog, policy_schema, policy_name, policy_owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES
  WHERE deleted IS NULL
),
refs AS (
  SELECT policy_id, COUNT(*) AS attachments,
         COUNT_IF(COALESCE(policy_status, 'ACTIVE') <> 'ACTIVE') AS inactive_attachments,
         LISTAGG(DISTINCT IFF(COALESCE(policy_status, 'ACTIVE') <> 'ACTIVE', policy_status, NULL), ', ') AS inactive_detail,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(
           ref_database_name || '.' || ref_schema_name || '.' || ref_entity_name || COALESCE('.' || ref_column_name, '')
         ) WITHIN GROUP (ORDER BY ref_entity_name), 0, 10), ', ') AS sample_attachments
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  WHERE policy_kind IN ('MASKING_POLICY', 'ROW_ACCESS_POLICY')
  GROUP BY policy_id
),
-- POLICIES_REFERENCED nests policies under objects and columns, so walk it recursively for policyId keys.
evals AS (
  SELECT TRY_TO_NUMBER(TO_VARCHAR(f.value:policyId)) AS policy_id, COUNT(DISTINCT a.query_id) AS queries_evaluated,
         MAX(a.query_start_time) AS last_evaluated
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY a,
       LATERAL FLATTEN(input => a.policies_referenced, recursive => TRUE) f
  WHERE a.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND a.query_start_time < __AS_OF_DATE__
    AND ARRAY_SIZE(a.policies_referenced) > 0
    AND f.value:policyId IS NOT NULL
  GROUP BY 1
),
j AS (
  SELECT p.*, COALESCE(r.attachments, 0) AS attachments, COALESCE(r.inactive_attachments, 0) AS inactive_attachments,
         r.inactive_detail, r.sample_attachments, COALESCE(e.queries_evaluated, 0) AS queries_evaluated,
         e.last_evaluated, DATEDIFF(day, p.created, __AS_OF_DATE__) AS age_days
  FROM pol p
  LEFT JOIN refs r ON r.policy_id = p.policy_id
  LEFT JOIN evals e ON e.policy_id = p.policy_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, policy_kind, TO_VARCHAR(policy_id) AS policy_id,
       database_name, schema_name, policy_name, database_name || '.' || schema_name || '.' || policy_name AS policy_fqn,
       policy_owner, created, last_altered, age_days, attachments, inactive_attachments, inactive_detail,
       sample_attachments, queries_evaluated, last_evaluated,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(attachments = 0, 'attached nowhere', NULL),
         IFF(inactive_attachments > 0, inactive_attachments || ' attachments not ACTIVE: ' || inactive_detail, NULL),
         IFF(attachments > 0 AND queries_evaluated = 0, 'no query evaluated it in the window', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN inactive_attachments > 0 THEN 'CRITICAL'
         WHEN age_days >= :min_age_days AND (attachments = 0 OR queries_evaluated = 0) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, attachments DESC, policy_fqn
