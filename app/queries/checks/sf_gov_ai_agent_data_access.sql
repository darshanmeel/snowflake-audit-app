-- query_id: sf_gov_ai_agent_data_access
-- title: Tables AI agents read, and the sensitive columns among them
-- domain: governance_access   tier: standard
-- windowed: yes
-- entity: tables = table_fqn
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (Access History)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export date
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. agents_info is a newer ACCESS_HISTORY column; an account
--   whose view does not have it yet reads Not assessed.
-- read_this: one row = one agent x one base table it read in the window. agent_type is the agent nearest
--   the access in ACCESS_HISTORY.agents_info: CORTEX_AGENT (a named Cortex Agent, agent_name is its
--   name), CORTEX_LITE_AGENT (the REST API or a Snowflake client, no name) or EXTERNAL_AGENT (a
--   SERVICE_AGENT user or an OAuth integration marked agentic). queries and users count the queries and
--   distinct users behind the reads. sensitive_columns counts the columns read that carry a sensitive tag
--   (see sf_gov_sensitive_columns_unprotected); unmasked_columns names those no masking policy covers.
-- healthy: status = OK when the agent read no sensitive column, or only masked ones, and is not external.
-- investigate_if: WARN when an external agent read the table, or an agent read masked sensitive columns;
--   CRITICAL when an agent read a sensitive column no masking policy covers.
-- actions: 1) give each agent its own role and grant it only the tables it needs (free); 2) mask the
--   sensitive columns agents read, allowing clear text only to named roles (config); 3) review the external
--   agents' OAuth integrations and SERVICE_AGENT users, and drop those no one owns (free)
-- next: sf_gov_sensitive_data_access, sf_gov_sensitive_columns_unprotected
-- caveats: heavy: reads ACCESS_HISTORY for the window (period_days only) and flattens the objects each
--   query read. ACCESS_HISTORY lags up to 3 hours. Only tagged columns count as sensitive; a read of a masked
--   column may still have returned clear text to a role the policy allows. Query text is never read.
WITH __INCLUDE_sf_gov_sensitive_columns__,
ah AS (
  -- the agent nearest the access is the array's first element
  SELECT h.query_id, h.user_name, h.query_start_time, h.base_objects_accessed,
         UPPER(a.value:"agentType"::VARCHAR) AS agent_type,
         COALESCE(a.value:"agentName"::VARCHAR, a.value:"agentId"::VARCHAR) AS agent_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY h, LATERAL FLATTEN(input => h.agents_info) a
  WHERE h.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND h.query_start_time < __AS_OF_DATE__
    AND a.index = 0
),
reads AS (
  SELECT ah.query_id, ah.user_name, ah.query_start_time, ah.agent_type, ah.agent_name,
         REPLACE(UPPER(obj.value:"objectName"::VARCHAR), '"', '') AS table_fqn,
         UPPER(col.value:"columnName"::VARCHAR) AS column_name
  FROM ah,
       LATERAL FLATTEN(input => ah.base_objects_accessed) obj,
       LATERAL FLATTEN(input => obj.value:"columns", OUTER => TRUE) col
  WHERE UPPER(obj.value:"objectDomain"::VARCHAR) IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'DYNAMIC TABLE', 'EXTERNAL TABLE')
),
hits AS (
  SELECT r.*, s.column_name IS NOT NULL AS is_sensitive, s.masking_policies IS NOT NULL AS is_masked
  FROM reads r
  LEFT JOIN sf_gov_sensitive_columns s
    ON r.table_fqn = s.database_name || '.' || s.schema_name || '.' || s.table_name AND r.column_name = s.column_name
),
g AS (
  SELECT agent_type, COALESCE(agent_name, '(' || LOWER(agent_type) || ')') AS agent_name, table_fqn,
         SPLIT_PART(table_fqn, '.', 1) AS database_name,
         COUNT(DISTINCT query_id) AS queries, COUNT(DISTINCT user_name) AS users,
         COUNT(DISTINCT IFF(is_sensitive, column_name, NULL)) AS sensitive_columns,
         LISTAGG(DISTINCT IFF(is_sensitive AND NOT is_masked, column_name, NULL), ', ') AS unmasked_columns,
         MIN(query_start_time) AS first_read, MAX(query_start_time) AS last_read
  FROM hits
  GROUP BY 1, 2, 3, 4
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, agent_type, agent_name, table_fqn, database_name,
       queries, users, sensitive_columns, NULLIF(unmasked_columns, '') AS unmasked_columns, first_read, last_read,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NULLIF(unmasked_columns, '') IS NOT NULL, 'unmasked sensitive: ' || unmasked_columns, NULL),
         IFF(sensitive_columns > 0 AND NULLIF(unmasked_columns, '') IS NULL, sensitive_columns || ' masked sensitive columns', NULL),
         IFF(agent_type = 'EXTERNAL_AGENT', 'external agent', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE WHEN NULLIF(unmasked_columns, '') IS NOT NULL THEN 'CRITICAL'
            WHEN agent_type = 'EXTERNAL_AGENT' OR sensitive_columns > 0 THEN 'WARN'
            ELSE 'OK' END AS status
FROM g
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, queries DESC, agent_name, table_fqn
