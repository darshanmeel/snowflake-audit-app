-- query_id: sf_sec_network_policy_unattached
-- shims: NETWORK_POLICIES, POLICY_REFERENCES
-- reads: INFORMATION_SCHEMA table functions SHOW NETWORK POLICIES, POLICY_REFERENCES (table function, per policy)
-- fallback_note: live network policies only; no IP lists (SHOW gives only their counts); the name stands in for the id; masking, row access, projection and aggregation policies only; the name stands in for the policy id
-- pre: SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT
WITH acct AS (
  SELECT NULLIF(TRIM(p."value"), '') AS policy_name
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) p
  WHERE p."key" = 'NETWORK_POLICY'
),
np AS (
  SELECT id AS policy_id, name AS policy_name, owner, created, last_altered
  FROM __SHIM_NETWORK_POLICIES__
  WHERE deleted IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY last_altered DESC NULLS LAST) = 1
),
refs AS (
  SELECT policy_id,
         COUNT(DISTINCT IFF(ref_entity_domain = 'USER', ref_entity_name, NULL)) AS user_count,
         COUNT(DISTINCT IFF(ref_entity_domain = 'ACCOUNT', ref_entity_name, NULL)) AS account_refs,
         COUNT(DISTINCT IFF(ref_entity_domain NOT IN ('USER', 'ACCOUNT'), ref_entity_name, NULL)) AS other_count
  FROM __SHIM_POLICY_REFERENCES__
  WHERE policy_kind = 'NETWORK_POLICY'
  GROUP BY policy_id
),
seen AS (
  SELECT COUNT(*) AS ref_rows FROM __SHIM_POLICY_REFERENCES__ WHERE policy_kind = 'NETWORK_POLICY'
),
s AS (
  SELECT np.*, (SELECT ref_rows FROM seen) AS ref_rows, COALESCE(r.user_count, 0) AS user_count, COALESCE(r.other_count, 0) AS other_count,
         (a.policy_name IS NOT NULL OR COALESCE(r.account_refs, 0) > 0) AS on_account,
         DATEDIFF('day', np.created, __AS_OF_DATE__) AS age_days
  FROM np
  LEFT JOIN refs r ON r.policy_id = np.policy_id
  LEFT JOIN acct a ON a.policy_name = np.policy_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, policy_name || ' (' || policy_id || ')' AS policy_name,
       policy_id, owner, created, last_altered, age_days, on_account, user_count, other_count,
       IFF(NOT on_account AND user_count = 0 AND other_count = 0,
           'set on no account, user or object the role can see', NULL) AS reasons,
       IFF(ref_rows = 0 AND NOT on_account, 'no_network_policy_references', NULL) AS not_assessed_reason,
       IFF(ref_rows = 0 AND NOT on_account, 'NOT_ASSESSED',
           IFF(NOT on_account AND user_count = 0 AND other_count = 0 AND age_days >= :min_age_days, 'WARN', 'OK')) AS status
FROM s
ORDER BY IFF(status = 'WARN', 0, 1), age_days DESC NULLS LAST, policy_name
