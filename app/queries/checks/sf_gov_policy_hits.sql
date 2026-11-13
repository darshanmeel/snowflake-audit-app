-- query_id: sf_gov_policy_hits
-- title: Which queries each masking and row access policy fired on, by user and role
-- domain: governance_access   tier: standard
-- entity: policies = policy_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES, SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition
-- params: :lookback_days (default 90) days of ACCESS_HISTORY it reads, counted back from the export date;
--   :row_cap (default 500000) rows: the export keeps at most this many, newest days first
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one day x user x role x policy x protected object where the policy was enforced.
--   A masking policy is enforced per column read (columns lists them), a row access policy per table or
--   view read. queries counts distinct queries. Whether the user saw clear text or all rows depends on the
--   policy's exempt roles (sf_secx_policy_body_exemptions); the app joins the two. Names only, never
--   the policy body.
-- healthy: status = OK on every row; this check is a log for the policy pages.
-- investigate_if: NOT_ASSESSED when ACCESS_HISTORY has no rows in the lookback.
-- actions: 1) check on PII › Masking & row policies who saw clear text and who can bypass each policy (free)
-- next: sf_secx_policy_body_exemptions
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the lookback (Standard edition, or
--   the role cannot see it), so no policy use can be told from none
-- caveats: ACCESS_HISTORY lags up to 3 hours. Only rows with a policy are scanned in full. The role is
--   the query's primary role; a policy using IS_ROLE_IN_SESSION also lets secondary roles through, which
--   ACCESS_HISTORY does not record.
WITH ah AS (
  SELECT query_id, query_start_time, user_name, policies_referenced
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
    AND query_start_time < __AS_OF_DATE__
    AND ARRAY_SIZE(policies_referenced) > 0
),
seen AS (
  SELECT COUNT(*) AS access_rows
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
    AND query_start_time < __AS_OF_DATE__
),
-- policies on a column (masking) and on the object itself (row access), as POLICIES_REFERENCED nests them
hit AS (
  SELECT a.query_id, a.query_start_time, a.user_name, UPPER(o.value:"objectName"::STRING) AS object_fqn,
         UPPER(c.value:"columnName"::STRING) AS column_name, p.value:"policyId"::NUMBER AS policy_id,
         UPPER(p.value:"policyName"::STRING) AS policy_name, UPPER(p.value:"policyKind"::STRING) AS policy_kind
  FROM ah a, LATERAL FLATTEN(input => a.policies_referenced) o, LATERAL FLATTEN(input => o.value:"columns") c,
       LATERAL FLATTEN(input => c.value:"policies") p
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, UPPER(o.value:"objectName"::STRING), CAST(NULL AS VARCHAR),
         p.value:"policyId"::NUMBER, UPPER(p.value:"policyName"::STRING), UPPER(p.value:"policyKind"::STRING)
  FROM ah a, LATERAL FLATTEN(input => a.policies_referenced) o, LATERAL FLATTEN(input => o.value:"policies") p
),
pol AS (
  SELECT policy_id, policy_catalog || '.' || policy_schema || '.' || policy_name AS policy_fqn, 'MASKING_POLICY' AS kind
  FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES
  UNION ALL
  SELECT policy_id, policy_catalog || '.' || policy_schema || '.' || policy_name, 'ROW_ACCESS_POLICY'
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES
),
qh AS (
  SELECT query_id, MAX(UPPER(role_name)) AS role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -(:lookback_days + 1), __AS_OF_DATE__)
    AND query_id IN (SELECT query_id FROM ah)
  GROUP BY query_id
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, DATE(h.query_start_time) AS usage_date, h.user_name,
       COALESCE(q.role_name, '(unknown role)') AS role_name, TO_VARCHAR(h.policy_id) AS policy_id,
       UPPER(COALESCE(MAX(p.policy_fqn), MAX(h.policy_name))) AS policy_fqn,
       COALESCE(MAX(p.kind), IFF(MAX(h.policy_kind) ILIKE 'ROW%', 'ROW_ACCESS_POLICY', 'MASKING_POLICY')) AS policy_kind,
       h.object_fqn, LISTAGG(DISTINCT h.column_name, ', ') WITHIN GROUP (ORDER BY h.column_name) AS columns,
       COUNT(DISTINCT h.query_id) AS queries, MAX(h.query_start_time)::TIMESTAMP_NTZ AS last_at,
       CAST(NULL AS VARCHAR) AS not_assessed_reason, 'OK' AS status
FROM hit h
LEFT JOIN qh q ON q.query_id = h.query_id
LEFT JOIN pol p ON p.policy_id = h.policy_id
GROUP BY DATE(h.query_start_time), h.user_name, COALESCE(q.role_name, '(unknown role)'), h.policy_id, h.policy_name, h.object_fqn
UNION ALL
SELECT 0, __ACCOUNT_ID__, CAST(NULL AS DATE), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS INTEGER), CAST(NULL AS TIMESTAMP_NTZ), 'no_access_history', 'NOT_ASSESSED'
FROM seen WHERE access_rows = 0
ORDER BY usage_date DESC NULLS FIRST, policy_fqn, user_name
