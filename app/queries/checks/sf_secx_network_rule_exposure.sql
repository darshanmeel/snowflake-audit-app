-- query_id: sf_secx_network_rule_exposure
-- title: Network rules that allow any IP in, or any host out
-- domain: governance_access   tier: standard
-- entity: network rules = rule_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.NETWORK_RULES, SNOWFLAKE.ACCOUNT_USAGE.NETWORK_RULE_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (SECURITY_VIEWER)
-- params: :wide_ipv4_prefix (default 16) bits: an allowed IPv4 range with a shorter prefix than this
--   reads as wide
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The VALUE_LIST text format is parsed loosely.
-- read_this: one row = one live network rule visible to the role. mode is INGRESS (network policy) or
--   EGRESS (external access). Only counts are kept from the value list: entries, any_ip_entries
--   (0.0.0.0/0 or ::/0), wide_ip_entries (prefix shorter than :wide_ipv4_prefix) and wildcard_hosts
--   (a * in a host, or 0.0.0.0 as host). policy_allow_refs is how many network policies allow it,
--   integration_refs how many external access integrations use it; visible_rules is the number of
--   rules the role can see.
-- healthy: status = OK when no entry is any-IP, wide or wildcard, or an exposed rule is not attached
--   to anything.
-- investigate_if: WARN when an attached rule has wide ranges, or a wildcard host reached by an
--   integration; CRITICAL when a network policy allows a rule with 0.0.0.0/0 or ::/0.
-- actions: 1) replace any-IP ingress rules with office, VPN and tool ranges (config); 2) list the
--   exact hosts in egress rules instead of wildcards (config); 3) drop rules that no policy or
--   integration uses (free)
-- next: sf_sec_network_policy_coverage
-- caveats: NETWORK_RULES shows only rules the role can access, so the count is 'of N visible rules'.
--   Lags up to 2 hours. The rule values themselves are not exported.
-- The docs say DATABASE_NAME/SCHEMA_NAME but accounts return DATABASE/SCHEMA, so read either.
WITH r AS (
  SELECT id AS rule_id, name AS rule_name,
         COALESCE(o:DATABASE_NAME, o:DATABASE)::VARCHAR AS database_name,
         COALESCE(o:SCHEMA_NAME, o:SCHEMA)::VARCHAR AS schema_name,
         owner, UPPER(mode) AS mode, UPPER(type) AS rule_type, value_list
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o, id, name, owner, mode, type, value_list, deleted
        FROM SNOWFLAKE.ACCOUNT_USAGE.NETWORK_RULES)
  WHERE deleted IS NULL
),
-- Keep only host and IP characters, so a JSON-like or comma list both split into entries.
ent AS (
  SELECT r.rule_id, r.rule_type, NULLIF(TRIM(f.value::VARCHAR), '') AS entry
  FROM r,
       LATERAL FLATTEN(INPUT => SPLIT(REGEXP_REPLACE(r.value_list, '[^0-9A-Za-z.:/*_,-]', ''), ','), OUTER => TRUE) f
),
flags AS (
  SELECT rule_id,
         COUNT(entry) AS entries,
         COUNT_IF(entry IN ('0.0.0.0/0', '::/0')) AS any_ip_entries,
         COUNT_IF(rule_type = 'IPV4' AND entry LIKE '%/%' AND entry <> '0.0.0.0/0'
                  AND TRY_TO_NUMBER(SPLIT_PART(entry, '/', 2)) < :wide_ipv4_prefix) AS wide_ip_entries,
         COUNT_IF(rule_type = 'HOST_PORT' AND (entry LIKE '%*%' OR entry LIKE '0.0.0.0%')) AS wildcard_hosts
  FROM ent
  GROUP BY rule_id
),
refs AS (
  SELECT network_rule_id AS rule_id,
         COUNT_IF(container_type = 'NETWORK_POLICY' AND action_type = 'ALLOW') AS policy_allow_refs,
         COUNT_IF(container_type = 'INTEGRATION') AS integration_refs,
         COUNT(*) AS all_refs,
         LISTAGG(DISTINCT container_type || ': ' || container_name, ', ') AS attached_to
  FROM SNOWFLAKE.ACCOUNT_USAGE.NETWORK_RULE_REFERENCES
  GROUP BY network_rule_id
),
j AS (
  SELECT r.rule_id, r.rule_name, r.database_name, r.schema_name, r.owner, r.mode, r.rule_type,
         COALESCE(f.entries, 0) AS entries, COALESCE(f.any_ip_entries, 0) AS any_ip_entries,
         COALESCE(f.wide_ip_entries, 0) AS wide_ip_entries, COALESCE(f.wildcard_hosts, 0) AS wildcard_hosts,
         COALESCE(x.policy_allow_refs, 0) AS policy_allow_refs, COALESCE(x.integration_refs, 0) AS integration_refs,
         COALESCE(x.all_refs, 0) AS all_refs, x.attached_to,
         COUNT(*) OVER () AS visible_rules
  FROM r
  LEFT JOIN flags f ON f.rule_id = r.rule_id
  LEFT JOIN refs x ON x.rule_id = r.rule_id
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, rule_id, rule_name, database_name, schema_name,
       database_name || '.' || schema_name || '.' || rule_name AS rule_fqn, owner, mode, rule_type, entries,
       any_ip_entries, wide_ip_entries, wildcard_hosts, policy_allow_refs, integration_refs, attached_to, visible_rules,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(any_ip_entries > 0, 'allows any IP', NULL),
         IFF(wide_ip_entries > 0, wide_ip_entries || ' ranges wider than /' || :wide_ipv4_prefix, NULL),
         IFF(wildcard_hosts > 0, wildcard_hosts || ' wildcard hosts', NULL),
         IFF(all_refs = 0 AND (any_ip_entries + wide_ip_entries + wildcard_hosts) > 0, 'not attached to any policy or integration', NULL),
         IFF(policy_allow_refs > 0 AND any_ip_entries > 0, 'allowed by ' || policy_allow_refs || ' network policies', NULL),
         IFF(integration_refs > 0 AND wildcard_hosts > 0, 'used by ' || integration_refs || ' integrations', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN any_ip_entries > 0 AND policy_allow_refs > 0 THEN 'CRITICAL'
         WHEN (wide_ip_entries > 0 AND policy_allow_refs > 0) OR (wildcard_hosts > 0 AND integration_refs > 0) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, rule_fqn
