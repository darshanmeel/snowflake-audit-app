-- shim: POLICY_REFERENCES
-- reads: INFORMATION_SCHEMA.POLICY_REFERENCES (table function, per policy)
-- each: policy
-- needs: APPLY MASKING POLICY, APPLY ROW ACCESS POLICY, APPLY PROJECTION POLICY, APPLY AGGREGATION POLICY
-- note: masking, row access, projection and aggregation policies only; the name stands in for the policy id
-- columns: REGION VARCHAR, POLICY_DB VARCHAR, POLICY_SCHEMA VARCHAR, POLICY_ID VARCHAR, POLICY_NAME VARCHAR, POLICY_KIND VARCHAR, REF_DATABASE_NAME VARCHAR, REF_SCHEMA_NAME VARCHAR, REF_ENTITY_NAME VARCHAR, REF_ENTITY_DOMAIN VARCHAR, REF_COLUMN_NAME VARCHAR, REF_ARG_COLUMN_NAMES VARCHAR, TAG_DATABASE VARCHAR, TAG_SCHEMA VARCHAR, TAG_NAME VARCHAR, POLICY_STATUS VARCHAR
-- One call per policy SHOW lists; the global APPLY privileges are what make every reference visible.
SELECT CAST(NULL AS VARCHAR) AS region, CAST(policy_db AS VARCHAR) AS policy_db,
       CAST(policy_schema AS VARCHAR) AS policy_schema,
       policy_db || '.' || policy_schema || '.' || policy_name AS policy_id,
       CAST(policy_name AS VARCHAR) AS policy_name, CAST(policy_kind AS VARCHAR) AS policy_kind,
       CAST(ref_database_name AS VARCHAR) AS ref_database_name, CAST(ref_schema_name AS VARCHAR) AS ref_schema_name,
       CAST(ref_entity_name AS VARCHAR) AS ref_entity_name, CAST(ref_entity_domain AS VARCHAR) AS ref_entity_domain,
       CAST(ref_column_name AS VARCHAR) AS ref_column_name, CAST(ref_arg_column_names AS VARCHAR) AS ref_arg_column_names,
       CAST(tag_database AS VARCHAR) AS tag_database, CAST(tag_schema AS VARCHAR) AS tag_schema,
       CAST(tag_name AS VARCHAR) AS tag_name, CAST(policy_status AS VARCHAR) AS policy_status
FROM TABLE(__INFO_SCHEMA__.POLICY_REFERENCES(POLICY_NAME => __ITEM_LITERAL__))
