-- query_id: sf_sec_network_policy_unattached
-- title: Network policies attached to nothing
-- domain: governance_access   tier: standard
-- entity: network policies = policy_name
-- windowed: no
-- pre: SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT
-- reads: SHOW PARAMETERS IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.NETWORK_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :min_age_days (default 14) age days: a policy younger than this is not flagged while it is being rolled out
-- empty_if: role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That POLICY_REFERENCES lists a network policy set on a security
--   integration (domain INTEGRATION) is taken from the docs; a policy used only that way may read as unattached.
-- read_this: one row = one live network policy (name and id). on_account is TRUE when it is the account-level
--   policy; user_count is the users it is set on; other_count is other objects (such as security integrations).
--   Only names and counts are read: never the IP lists or rule contents.
-- healthy: status = OK when the policy is set on the account, on at least one user or on another object, or is new.
-- investigate_if: WARN when a policy older than :min_age_days is set on nothing the role can see.
-- actions: 1) confirm with the owner that the policy is not meant for an integration the role cannot see (free);
--   2) attach it to the account, user or integration it was made for (config); 3) drop policies nobody uses so
--   the list of access rules stays true (config)
-- next: sf_sec_network_policy_coverage
-- not_assessed_reasons: no_network_policy_references: POLICY_REFERENCES lists no network policy at all and none is
--   set on the account, so the role cannot see the references (or the account does not report them)
-- caveats: An unattached policy blocks nothing, so this is hygiene and not a hole; the hole (no policy on the
--   account or an admin) is in sf_sec_network_policy_coverage. POLICY_REFERENCES lags up to 2 hours and lists
--   only what the role can see. A policy set on an object in another account is not listed.
WITH acct AS (
  SELECT NULLIF(TRIM(p."value"), '') AS policy_name
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) p
  WHERE p."key" = 'NETWORK_POLICY'
),
np AS (
  SELECT id AS policy_id, name AS policy_name, owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.NETWORK_POLICIES
  WHERE deleted IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY last_altered DESC NULLS LAST) = 1
),
refs AS (
  SELECT policy_id,
         COUNT(DISTINCT IFF(ref_entity_domain = 'USER', ref_entity_name, NULL)) AS user_count,
         COUNT(DISTINCT IFF(ref_entity_domain = 'ACCOUNT', ref_entity_name, NULL)) AS account_refs,
         COUNT(DISTINCT IFF(ref_entity_domain NOT IN ('USER', 'ACCOUNT'), ref_entity_name, NULL)) AS other_count
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  WHERE policy_kind = 'NETWORK_POLICY'
  GROUP BY policy_id
),
seen AS (
  SELECT COUNT(*) AS ref_rows FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES WHERE policy_kind = 'NETWORK_POLICY'
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
