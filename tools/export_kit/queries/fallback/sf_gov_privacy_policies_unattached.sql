-- query_id: sf_gov_privacy_policies_unattached
-- shims: AGGREGATION_POLICIES, PROJECTION_POLICIES, POLICY_REFERENCES
-- reads: INFORMATION_SCHEMA table functions SHOW AGGREGATION POLICIES, SHOW PROJECTION POLICIES, POLICY_REFERENCES (table function, per policy)
-- fallback_note: live policies only; no signature or body; the name stands in for ids; live policies only; no signature or body; the name stands in for ids; masking, row access, projection and aggregation policies only; the name stands in for the policy id
WITH pol AS (
  SELECT 'AGGREGATION_POLICY' AS policy_kind, policy_id, policy_name, policy_catalog AS database_name,
         policy_schema AS schema_name, created
  FROM __SHIM_AGGREGATION_POLICIES__
  WHERE deleted IS NULL
  UNION ALL
  SELECT 'PROJECTION_POLICY', policy_id, policy_name, policy_catalog, policy_schema, created
  FROM __SHIM_PROJECTION_POLICIES__
  WHERE deleted IS NULL
),
refs AS (
  SELECT policy_id,
         CASE WHEN UPPER(policy_kind) LIKE 'AGGREGATION%' THEN 'AGGREGATION_POLICY'
              WHEN UPPER(policy_kind) LIKE 'PROJECTION%' THEN 'PROJECTION_POLICY' END AS policy_kind,
         COUNT(*) AS attachments,
         COUNT_IF(UPPER(COALESCE(policy_status, 'ACTIVE')) <> 'ACTIVE') AS non_active_attachments
  FROM __SHIM_POLICY_REFERENCES__
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
