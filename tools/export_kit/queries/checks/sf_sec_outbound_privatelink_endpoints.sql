-- query_id: sf_sec_outbound_privatelink_endpoints
-- title: Outbound private endpoints that failed or are stuck, and ones no rule or call names
-- domain: governance_access   tier: standard
-- entity: endpoints = snowflake_resource_id
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.OUTBOUND_PRIVATELINK_ENDPOINTS, SNOWFLAKE.ACCOUNT_USAGE.NETWORK_RULES,
--   SNOWFLAKE.ACCOUNT_USAGE.EXTERNAL_ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (SECURITY_VIEWER database role); Business
--   Critical Edition for outbound private connectivity
-- params: :min_age_days (default 14) days: a working endpoint younger than this is not flagged as unused
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: usage_not_visible: the endpoint is CREATED and old enough but no network rule or recorded
--   call names it, and use by stages or integrations is not visible in any usage view
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The network rule type PRIVATE_HOST_PORT and the way a host
--   name appears in VALUE_LIST and HOSTNAMES are matched as text and follow the docs.
-- read_this: one row = one live outbound private endpoint. rule_refs counts live network rules of type
--   PRIVATE_HOST_PORT that name the endpoint's host; calls_seen counts distinct queries in the external
--   access history that reached it. provider_kind is the cloud (aws, azure, gcp) taken from the host name.
-- healthy: status = OK when the endpoint is CREATED and a network rule or a recorded call names it, or it is
--   younger than :min_age_days.
-- investigate_if: WARN when the endpoint is FAILED, has been PENDING_CREATION for a day or more. An old CREATED endpoint
--   with no network rule and no recorded call reads NOT_ASSESSED (usage_not_visible), never WARN.
-- actions: 1) recreate or remove a failed or stuck endpoint and ask the provider to approve it (free); 2)
--   add the network rule and external access integration that should use an idle endpoint, or drop it
--   (config); 3) remove endpoints nobody needs, since they may be billed while they exist (spend)
-- next: sf_secx_external_access_calls
-- caveats: Endpoints in PENDING_DELETION or DELETING are left out of the checks. Use by external stages, storage
--   integrations, external functions and API integrations is not visible here. The endpoint fee is in no usage view, so there is no $ column. The full host name and the provider
--   resource id are never kept. EXTERNAL_ACCESS_HISTORY has no timestamp, so calls_seen covers the whole
--   retained history (365 days), so an empty history is not proof of idle. Lags up to 2 hours.
WITH ep AS (
  SELECT snowflake_resource_id, hostname, subresource, UPPER(endpoint_state) AS endpoint_state, created_on,
         COALESCE(last_altered_on, created_on) AS last_change
  FROM SNOWFLAKE.ACCOUNT_USAGE.OUTBOUND_PRIVATELINK_ENDPOINTS
  WHERE deleted_on IS NULL AND UPPER(endpoint_state) IN ('CREATED', 'FAILED', 'PENDING_CREATION')
),
rules AS (
  SELECT e.snowflake_resource_id, COUNT(r.id) AS rule_refs
  FROM ep e
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.NETWORK_RULES r
    ON r.deleted IS NULL AND UPPER(r.type) = 'PRIVATE_HOST_PORT'
   AND POSITION(UPPER(e.hostname) IN UPPER(r.value_list)) > 0
  GROUP BY e.snowflake_resource_id
),
calls AS (
  SELECT e.snowflake_resource_id, COUNT(DISTINCT x.query_id) AS calls_seen
  FROM ep e
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.EXTERNAL_ACCESS_HISTORY x
    ON POSITION(UPPER(e.hostname) IN UPPER(x.hostnames)) > 0
  GROUP BY e.snowflake_resource_id
),
s AS (
  SELECT ep.snowflake_resource_id, ep.subresource, ep.endpoint_state,
         CASE WHEN UPPER(ep.hostname) LIKE '%AMAZONAWS.COM%' THEN 'aws'
              WHEN UPPER(ep.hostname) LIKE '%WINDOWS.NET%' THEN 'azure'
              WHEN UPPER(ep.hostname) LIKE '%GOOGLE%' OR UPPER(ep.hostname) LIKE '%GOOG%' THEN 'gcp'
              ELSE 'other' END AS provider_kind,
         DATEDIFF(day, ep.created_on, __AS_OF_DATE__) AS age_days,
         DATEDIFF(day, ep.last_change, __AS_OF_DATE__) AS days_in_state,
         COALESCE(rules.rule_refs, 0) AS rule_refs, COALESCE(calls.calls_seen, 0) AS calls_seen
  FROM ep
  LEFT JOIN rules ON rules.snowflake_resource_id = ep.snowflake_resource_id
  LEFT JOIN calls ON calls.snowflake_resource_id = ep.snowflake_resource_id
),
f AS (
  SELECT s.*, endpoint_state = 'FAILED' AS failed,
         endpoint_state = 'PENDING_CREATION' AND days_in_state >= 1 AS stuck,
         endpoint_state = 'CREATED' AND age_days >= :min_age_days AND rule_refs = 0 AND calls_seen = 0 AS unused
  FROM s
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, snowflake_resource_id, subresource, provider_kind,
       endpoint_state, age_days, days_in_state, rule_refs, calls_seen,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(failed, 'endpoint failed', NULL),
         IFF(stuck, endpoint_state || ' for ' || days_in_state || ' days', NULL),
         IFF(unused, 'no network rule names it and no call recorded; stage and integration use is not visible', NULL)), '; ') AS reasons,
       IFF(unused AND NOT (failed OR stuck), 'usage_not_visible', NULL) AS not_assessed_reason,
       CASE WHEN failed OR stuck THEN 'WARN' WHEN unused THEN 'NOT_ASSESSED' ELSE 'OK' END AS status
FROM f
ORDER BY CASE WHEN failed OR stuck THEN 0 WHEN unused THEN 1 ELSE 2 END, age_days DESC, snowflake_resource_id
