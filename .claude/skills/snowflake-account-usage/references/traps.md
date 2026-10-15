# Traps

Checked against docs.snowflake.com on 2026-09-28. AU = SNOWFLAKE.ACCOUNT_USAGE, OU = SNOWFLAKE.ORGANIZATION_USAGE.

## Money

- **Cloud services 10% adjustment.** `CREDITS_USED` in METERING_HISTORY, WAREHOUSE_METERING_HISTORY and METERING_DAILY_HISTORY is gross, and so is `QUERY_HISTORY.CREDITS_USED_CLOUD_SERVICES`. Cloud services are billed only above 10% of the day's warehouse compute.
  - Billed = `METERING_DAILY_HISTORY.CREDITS_BILLED` = CREDITS_USED + CREDITS_ADJUSTMENT_CLOUD_SERVICES, and the adjustment is negative.
  - Never sum hourly CREDITS_USED and call it spend.
- **Attribution gaps.** QUERY_ATTRIBUTION_HISTORY leaves out several things:
  - idle time, cloud services, storage, transfer, serverless and AI tokens;
  - queries of about 100 ms or less;
  - adaptive warehouses (use QUERY_METERING_HISTORY for those).
  - It lags up to 8 h and is complete only from mid-Aug 2024.
  - Its sum is less than `WAREHOUSE_METERING_HISTORY.CREDITS_USED_COMPUTE`. The gap is idle time.
  - For the idle ratio, use `WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES`, which is NULL on adaptive warehouses.
- **AI credits** in the Cortex views leave out warehouse compute.
  - METERING_* with SERVICE_TYPE = 'AI_SERVICES' is the reconciled total.
  - Fine-tuning covers training only. Search serving covers serving only; see also the SEARCH_DAILY and SEARCH_BATCH_QUERY views.
- **Cortex view churn.**
  - CORTEX_FUNCTIONS_USAGE_HISTORY and CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY are no longer updated.
  - CORTEX_AISQL_USAGE_HISTORY (data from 2025-11-17) is superseded by CORTEX_AI_FUNCTIONS_USAGE_HISTORY (data from 2026-01-05, user and role from 2026-02-16).
  - The new view has in-progress rows, so filter `IS_COMPLETED` or dedupe. `METRICS` is an ARRAY.
  - WAREHOUSE_ID and USER_ID types differ between views.
  - Summing the old and new views double counts the overlap.
- **Data transfer** in AU is bytes only, and `BYTES_TRANSFERRED` is VARIANT. Currency comes only from OU.USAGE_IN_CURRENCY_DAILY. INTERNAL_DATA_TRANSFER_HISTORY covers SPCS only.
- **Storage views vs the bill.** STORAGE_USAGE and DATABASE_STORAGE_USAGE_HISTORY do not reconcile with the bill; OU.STORAGE_DAILY_HISTORY does. OU AVERAGE_BYTES includes Time Travel and Fail-safe, and its SERVICE_TYPE is only STORAGE or STORAGE_READER.
- **OU billing.**
  - Needs ORGANIZATION_BILLING_VIEWER. Not available to reseller customers.
  - CONTRACT_ITEMS and REMAINING_BALANCE_DAILY show only the funding org.
  - Lags up to 72 h and can change until month end (IS_ADJUSTMENT).
  - USAGE_TYPE is legacy: classify by BILLING_TYPE, RATING_TYPE, SERVICE_TYPE and IS_ADJUSTMENT.
  - METERING_DAILY_HISTORY, DATA_TRANSFER_HISTORY, STORAGE_DAILY_HISTORY and ACCOUNTS are not premium and work in an ORGADMIN-enabled account. Most other OU views need the organization account.
  - A plain ACCOUNTADMIN often cannot read OU at all, so every OU check must degrade to NOT_ASSESSED.
- **Budgets** have no AU view. They need CALLs on SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET or SNOWFLAKE.CORE.BUDGET instances, which this read-only app does not run.
- **Replication.** REPLICATION_GROUP_USAGE_HISTORY shows only secondary groups in the target account. Auditing the primary account shows none of its replication cost.
- **Snowpipe.**
  - PIPE_USAGE_HISTORY has NULL PIPE_ID and PIPE_NAME for internal auto-refresh pipes (external and directory tables) and for Snowpipe Streaming.
  - Compaction can cost credits while inserting 0 bytes.
  - Streaming credits are in METERING_HISTORY (SNOWPIPE_STREAMING) and SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY. CLIENT_HISTORY and CHANNEL_HISTORY have no credits.
  - FILE_MIGRATION rows and bytes count migrated data, not ingested data.

## Time

- **Latency per view:**
  - QUERY_HISTORY, TASK_HISTORY and COMPLETE_TASK_GRAPHS: 45 min.
  - LOAD_HISTORY and TABLES: 90 min.
  - COPY_HISTORY, STAGES and the security views: 2 h. COPY and LOAD can reach 2 days when activity is low.
  - Metering, warehouses, AGGREGATE_QUERY_HISTORY and dynamic table refresh: 3 h.
  - Query pruning views: 4 h.
  - Cloud services credits, TABLE_PRUNING_HISTORY and TABLE_DML_HISTORY: 6 h.
  - Attribution: 8 h. SNOWPIPE_STREAMING: 12 h. OU billing: 72 h.
  - End windows early or mark them partial.
  - Where the docs contradict themselves, use the larger figure: PIPES 2 h or 3 h, ALERT_HISTORY 45 min or 3 h, EXTERNAL_ACCESS_HISTORY 2 h or 3 h.
- **Timezones.** AU hourly columns are TIMESTAMP_LTZ in the session timezone. OU and USAGE_DATE are UTC. Set `ALTER SESSION SET TIMEZONE = 'UTC'` before reconciling. APPLICATION_DAILY_USAGE_HISTORY and STORAGE_USAGE follow the session timezone.
- **Retention.** AU keeps 365 days, and a 400-day lookback silently returns 365. OU billing views keep data indefinitely (from Jun 2020). OBJECT_DEPENDENCIES is backfilled only from 2022-01-22.

## Types (cast before SUM or compare)

- VARCHAR credits: MATERIALIZED_VIEW_REFRESH_HISTORY.CREDITS_USED, SERVERLESS_TASK_HISTORY.CREDITS_USED.
- VARIANT: RESOURCE_MONITORS.CREDIT_QUOTA and USED_CREDITS (REMAINING_CREDITS is FLOAT), PIPE_USAGE_HISTORY.FILES_INSERTED (BYTES_INSERTED is FLOAT), DATA_TRANSFER_HISTORY.BYTES_TRANSFERRED (AU and OU), EXTERNAL_ACCESS_HISTORY.SENT_BYTES and RECEIVED_BYTES.
- Flags that are not BOOLEAN:
  - USERS.DISABLED and SNOWFLAKE_LOCK are VARIANT.
  - LOGIN_HISTORY.IS_SUCCESS is VARCHAR 'YES'/'NO'.
  - PIPES.IS_AUTOINGEST_ENABLED is VARCHAR.
  - TABLES.IS_TRANSIENT, IS_ICEBERG, IS_DYNAMIC and IS_HYBRID, and SCHEMATA.IS_MANAGED_ACCESS, are VARCHAR 'YES'/'NO'.
- ERROR_CODE is NUMBER in QUERY_HISTORY, ALERT_HISTORY and LOGIN_HISTORY, but VARCHAR in TASK_HISTORY.
- In QUERY_HISTORY, USER_DATABASE_ID and USER_SCHEMA_ID are VARCHAR. ICEBERG_STORAGE_OPTIMIZATION_HISTORY.SCHEMA_ID is VARCHAR. TASK_HISTORY.ROOT_TASK_ID is VARCHAR (same as the SHOW TASKS id), and RUN_ID is epoch ms.
- WAREHOUSE_EVENTS_HISTORY.CLUSTER_COUNT is VARCHAR.
- AGGREGATE_QUERY_HISTORY metrics are OBJECTs, so read `col:sum::NUMBER`. PERCENTAGE_SCANNED_FROM_CACHE, QUERY_LOAD_PERCENT and QUERY_ACCELERATION_UPPER_LIMIT_SCALE_FACTOR have no `sum` key. ERRORS is an ARRAY.
- `DELETED` is BOOLEAN in TABLE_STORAGE_METRICS and TIMESTAMP_LTZ everywhere else. `WHERE NOT deleted` drops NULL rows, so use `NOT COALESCE(deleted, FALSE) AND table_dropped IS NULL`.
- LOGIN_HISTORY.LOGIN_DETAILS and SESSIONS.CLIENT_ENVIRONMENT are VARCHAR holding JSON, so PARSE_JSON them.

## States and values

- TASK_HISTORY.STATE is only SUCCEEDED, FAILED, CANCELLED or SKIPPED. It never has SCHEDULED or EXECUTING, and never has Databricks-style ERROR or TIMED_OUT.
- DYNAMIC_TABLE_REFRESH_HISTORY.STATE is EXECUTING, SUCCEEDED, FAILED, CANCELLED or UPSTREAM_FAILED. There is no SKIPPED. Exclude EXECUTING before computing durations.
- ALERT_HISTORY.STATE includes CONDITION_FALSE, CONDITION_FAILED, ACTION_FAILED and TRIGGERED.
- COPY_HISTORY.STATUS is mixed case ('Loaded', 'Load failed', 'Partially loaded', 'Load skipped'). LOAD_HISTORY.STATUS is upper case, and LOAD_HISTORY excludes Snowpipe. Their error-position column names also differ.
- Cancelled queries are identified by ERROR_MESSAGE 'SQL execution canceled'. The docs do not document code 604.
- GRANTS_TO_ROLES.GRANTED_TO: the docs say 'ACCOUNT ROLE', but live data has returned 'ROLE'. Match both.
- TABLES.TABLE_TYPE is never 'DYNAMIC TABLE' or 'ICEBERG TABLE'. Use the IS_* flags.
- STAGES.STAGE_TYPE is mixed case: 'Internal Named' or 'External Named'.
- SHOW WAREHOUSES:
  - size is 'X-Small', not 'XSMALL';
  - resource_monitor is the text 'null' when none is assigned;
  - auto_suspend NULL means the warehouse never suspends;
  - auto_resume is text.
- WAREHOUSE_EVENTS_HISTORY:
  - one action produces several rows (STARTED and COMPLETED, at cluster and warehouse level), so filter EVENT_STATE and `CLUSTER_NUMBER IS NULL` for warehouse-level counts;
  - WAREHOUSE_CONSISTENT rows have NULL user, role and query_id.
- WAREHOUSE_LOAD_HISTORY AVG_* columns are load ratios per 5-minute bucket, not counts. Use averages or peaks, never sums.

## Visibility

- Access comes from IMPORTED PRIVILEGES on SNOWFLAKE, or from these database roles:
  - USAGE_VIEWER: metering and usage;
  - GOVERNANCE_VIEWER: query and access history, policies, tag references, classification;
  - OBJECT_VIEWER: objects, tags, dependencies;
  - SECURITY_VIEWER: users, roles, grants, logins, network, secrets, shares, Trust Center.
- OU needs ORGANIZATION_USAGE_VIEWER, or ORGANIZATION_BILLING_VIEWER for the billing views.
- Role-filtered AU views show only what the current role can access:
  - RESOURCE_MONITORS, COPY_HISTORY, COMPLETE_TASK_GRAPHS;
  - PIPES and STAGES, which ignore MANAGE GRANTS;
  - SCHEMATA, FUNCTIONS, PROCEDURES, FILE_FORMATS;
  - NETWORK_RULES, NETWORK_RULE_REFERENCES, MASKING_POLICIES, TAGS, TAG_REFERENCES.
  - DATABASES, TABLES, COLUMNS and FUNCTIONS do not honor MANAGE GRANTS.
  - A low-privilege role gets false "none found". Report it as not visible.
- SHOW commands:
  - show only objects the role holds a privilege on (MANAGE GRANTS sees all);
  - are capped at 10,000 rows, and some error above that without LIMIT;
  - the SHOW SHARES `to` column lists at most 3 consumers.
- RESULT_SCAN works only for the same user within 24 h. Output columns are lower case and must be double quoted ("name"). Duplicate column names get _1, _2 suffixes.
- QUERY_ACCELERATION_ELIGIBLE and QUERY_HISTORY carry QUERY_TEXT, which is never stored. Never select QUERY_TEXT, POLICY_BODY, VIEW_DEFINITION, FUNCTION_DEFINITION or BIND_VALUES into the export.

## Edition

- Enterprise+ only (on Standard the views exist but come back empty):
  - MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_*, DATA_QUALITY_MONITORING_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY;
  - ACCESS_HISTORY and AGGREGATE_ACCESS_HISTORY (Preview);
  - DATA_CLASSIFICATION_LATEST, TAG_REFERENCES, and masking and row access policies.
- Business Critical+: replication of object types other than databases and shares.
- Hybrid tables exist only in AWS and Azure commercial regions.

## Objects and names

- Dropped objects have NULL names, including the parent database and schema names. Names get reused after drop and recreate, so join on `*_ID`.
- TABLE_STORAGE_METRICS:
  - the key is `ID`, not TABLE_ID, and there is no BASE_TABLE_ID;
  - Fail-safe rows can have NULL names and look live, so COALESCE the FQN or label by ID;
  - several rows can share a name, so group by ID;
  - clone bytes appear as RETAINED_FOR_CLONE_BYTES on the source, and CLONE_GROUP_ID = ID means not a clone;
  - hybrid tables are not tracked.
- SEARCH_OPTIMIZATION_HISTORY replaced TABLE_ID and TABLE_NAME with INDEX_ID, INDEX_NAME, INDEX_TYPE, BASE_TABLE_ID and BASE_TABLE_NAME (BCR-2384).
  - Group cost by BASE_TABLE_ID.
  - SEARCH_OPTIMIZATION_BENEFITS still uses TABLE_ID, so join BASE_TABLE_ID = TABLE_ID.
  - While the rename rolls out, read both.
- MATERIALIZED_VIEW_REFRESH_HISTORY TABLE_ID and TABLE_NAME are the MV itself, not its base table.
- HYBRID_TABLES uses ID, NAME and OWNER.
- HYBRID_TABLE_USAGE_HISTORY is account level: OBJECT_ID and OBJECT_NAME are always NULL. It has not been billed since 2026-03-01.
- TASK_VERSIONS has no DELETED column, so a dropped task keeps its last row. Use SHOW TASKS for the current state.
- VIEWS.LAST_ALTERED moves with background maintenance. Use LAST_DDL.
- OBJECT_DEPENDENCIES:
  - misses CTAS, INSERT and MERGE;
  - for shared objects, REFERENCED_OBJECT_ID is NULL, so a missing referenced object does not always mean a broken view.
- ACCESS_HISTORY:
  - join on objectDomain plus objectId;
  - omits failed queries, reader accounts, AU reads, RESULT_SCAN, stream updates and replication;
  - POLICIES_REFERENCED holds masking and row access policies only.
- TAG_REFERENCES records direct assignments only (no inheritance). Filter OBJECT_DELETED IS NULL.
- DATA_CLASSIFICATION_LATEST keeps the latest result only, and the row vanishes on drop, rename or reclassify. A failed run shows as LAST_CLASSIFICATION_ATTEMPT > LAST_CLASSIFIED_ON.
- Grant views keep revoked rows: filter DELETED_ON IS NULL.
  - A re-grant adds a new row.
  - GRANTS_TO_ROLES skips grants on dropped objects, and database-role grants from share-derived databases.
  - An empty GRANTED_BY means the SYSTEM role granted it.
- ROLES and grants include DATABASE_ROLE, APPLICATION_ROLE and INSTANCE_ROLE rows, so filter ROLE_TYPE and GRANTED_TO.
- Policies:
  - POLICY_REFERENCES documents aggregation, feature, masking, network, projection, row access and storage-lifecycle policies only.
  - For authentication, password and session policy attachments, use `SHOW ... POLICIES ON ACCOUNT / ON USER` or `INFORMATION_SCHEMA.POLICY_REFERENCES(REF_ENTITY_DOMAIN => 'ACCOUNT' | 'USER', ...)`.
  - There is no AUTHENTICATION_POLICIES view.
- NETWORK_POLICIES does not show where a policy is attached (see POLICY_REFERENCES or SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT). Rules attached through NETWORK_RULE_REFERENCES are not in ALLOWED_IP_LIST.
- MFA coverage = USERS.HAS_MFA, plus USERS.EXT_AUTHN_DUO, plus CREDENTIALS rows where DOMAIN = 'MFA_METHOD'. CREDENTIALS excludes deleted credentials and Duo.
- USERS:
  - service users (TYPE = SERVICE) have NULL password and MFA columns, so branch on TYPE;
  - LAST_SUCCESS_LOGIN reflects only 1 year.
- LOGIN_HISTORY.USER_NAME can be NULL on early failures. Internal logins show CLIENT_IP 'INTERNAL_SNOWFLAKE_IP' or 0.0.0.0.
- SESSIONS omits SQL API transient sessions and system sessions.
- EXTERNAL_ACCESS_HISTORY has one row per IP, so use COUNT(DISTINCT QUERY_ID). It has no user column; join QUERY_HISTORY.
- TRUST_CENTER_FINDINGS (AU) has IDs, severity and state only. Details are in SNOWFLAKE.TRUST_CENTER.FINDINGS (TRUST_CENTER_VIEWER app role).
- AU SHARES lists outbound shares only, and TARGET_ACCOUNTS is a comma-separated string. Inbound shares need SHOW SHARES.
- The pruning views keep only the 1,000 longest scans per query, and skip hybrid tables. TABLE_PRUNING_HISTORY uses START_TIME; the query pruning views use INTERVAL_START_TIME.
- TABLE_DML_HISTORY skips hybrid tables and background DML.
- LOCK_WAIT_HISTORY.BLOCKER_QUERIES is a VARIANT array, so FLATTEN it OUTER.
- QUERY_HISTORY.QUERY_TEXT is truncated at 100K characters and ERROR_MESSAGE at 5K.
- STAGE_STORAGE_USAGE_HISTORY is one account number per day. No view gives bytes per stage.
- FUNCTIONS lists UDFs only. PROCEDURES has no ID, so key it by catalog, schema, name and ARGUMENT_SIGNATURE.
- SHOW ICEBERG TABLES has `auto_refresh_status`. It has no auto_refresh, invalid or invalid_reason columns.

## Missing, deprecated or renamed

| Name | What to use |
|---|---|
| AU.STREAMS | SHOW STREAMS IN ACCOUNT (stale, stale_after, mode) |
| AU.EXTERNAL_TABLES | TABLES WHERE TABLE_TYPE = 'EXTERNAL TABLE', or SHOW EXTERNAL TABLES IN ACCOUNT |
| AU.DYNAMIC_TABLES | TABLES.IS_DYNAMIC, SHOW DYNAMIC TABLES; DYNAMIC_TABLE_REFRESH_HISTORY exists |
| AU.ICEBERG_TABLES, CATALOG_INTEGRATIONS | TABLES.IS_ICEBERG, SHOW ICEBERG TABLES; ICEBERG_STORAGE_OPTIMIZATION_HISTORY exists |
| AU.AUTHENTICATION_POLICIES | SHOW AUTHENTICATION POLICIES + DESCRIBE |
| AU.BUDGETS / BUDGET_* | Budget class methods (CALL), out of scope for read-only |
| AU.AUTO_REFRESH_REGISTRATION_HISTORY | Does not exist (INFORMATION_SCHEMA function only, 14 days, deprecated). Use PIPE_USAGE_HISTORY WHERE PIPE_NAME IS NULL |
| REPLICATION_USAGE_HISTORY | Deprecated. Use REPLICATION_GROUP_USAGE_HISTORY or DATABASE_REPLICATION_USAGE_HISTORY |
| EVENT_USAGE_HISTORY | Deprecated. Use METERING_* with SERVICE_TYPE TELEMETRY_DATA_INGEST |
| CORTEX_FUNCTIONS_USAGE_HISTORY, CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY | No longer updated. Use CORTEX_AI_FUNCTIONS_USAGE_HISTORY |
| CORTEX_AISQL_USAGE_HISTORY | Superseded by CORTEX_AI_FUNCTIONS_USAGE_HISTORY |
| DOCUMENT_AI_USAGE_HISTORY | Decommissioned (BCR-2156). Use CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY |
| HYBRID_TABLE_USAGE_HISTORY | Exists, but has not been billed since 2026-03-01. Use for history only |
| SEARCH_OPTIMIZATION_HISTORY.TABLE_ID/TABLE_NAME | BASE_TABLE_ID/BASE_TABLE_NAME + INDEX_* (BCR-2384) |
| TABLE_STORAGE_METRICS.TABLE_ID | ID |
| OU.ACCOUNTS *_BILLING_ENTITY_NAME | Removed after 2026-10-26. Use CONTRACT_NUMBER |
| USAGE_IN_CURRENCY_DAILY.USAGE_TYPE | Legacy. Use SERVICE_TYPE, RATING_TYPE and BILLING_TYPE |

Newer AU views not yet in the catalog, to verify before use:
- CORTEX_REST_API_USAGE_HISTORY, CORTEX_SEARCH_BATCH_QUERY_USAGE_HISTORY;
- SERVERLESS_ALERT_HISTORY, DATABASE_REPLICATION_USAGE_HISTORY;
- OU.DATA_TRANSFER_DAILY_HISTORY;
- FEATURE_, PRIVACY_ and JOIN_POLICIES (AGGREGATION_ and PROJECTION_POLICIES are in views.md).

Counted-once rules the checks follow:
- Snowpipe Streaming migration credits (SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY) are already inside METERING_HISTORY service SNOWPIPE_STREAMING; price the metered total, show migration as a breakdown only. High-performance streaming also bills under that service type, not PIPE_USAGE_HISTORY.
- Warehouse rows (WAREHOUSE_METERING_HISTORY.CREDITS_USED) carry cloud services before the daily 10% adjustment; a billed figure is compute plus cloud services times that day's billed share from METERING_DAILY_HISTORY.
- Query acceleration is its own service in METERING_HISTORY; it is not part of warehouse compute, so never subtract it from compute to find idle.
- Idle = compute minus attributed query compute only for hours older than the 8 h attribution lag and only where CREDITS_ATTRIBUTED_COMPUTE_QUERIES is not NULL (adaptive warehouses are NULL).
- OBJECT_MODIFIED_BY_DDL (ACCESS_HISTORY) gives operationType and objectDomain per DDL query without query text; Enterprise edition.
- SESSIONS has no end time; IS_OPEN is a point-in-time flag, so an open session's age is measured to the export's as-of date.
- QUERY_METERING_HISTORY is the per-query credit source for adaptive warehouses only, needs Enterprise and has several rows per long query (one per metering hour); its in-progress rows hold NULLs. Sum per warehouse and hour, never count rows as queries.
- ANOMALIES_DAILY: the docs do not say whether ACTUAL_VALUE is used or billed credits. Compare it to the audit's own daily spikes as a second opinion, never add it to spend.
- MARKETPLACE_PAID_USAGE_DAILY lives in DATA_SHARING_USAGE (docs under /collaboration/views/). REPORT_DATE can repeat a usage line, so keep the newest REPORT_DATE per line before summing CHARGE. It is a consumer-side charge, in the listing's currency.
- BACKUP_STORAGE_USAGE and SNAPSHOT_STORAGE_USAGE bytes overlap across sets (the same micro-partitions sit in several backups). Do not sum LOGICAL_BYTES as storage or as what deleting a set saves. SNAPSHOT_* is deprecated in favour of BACKUP_*.
- MODEL_SERVING_USAGE_HISTORY.CREDITS is an attribution of compute pool usage to a model, not a separate charge; it is already inside the pool's SNOWPARK_CONTAINER_SERVICES credits. Data before 2026-08-25 is incomplete.
- OPENFLOW_USAGE_HISTORY covers BYOC deployments only; Snowflake-deployment Openflow is billed as service type OPENFLOW_COMPUTE_SNOWFLAKE in METERING_HISTORY.
- STAGE_STORAGE_USAGE_DETAILS keeps 90 days, is AWS and Azure only and misses some days; never read a missing day as zero bytes.
- SHOW PASSWORD POLICIES needs APPLY PASSWORD POLICY on the account or OWNERSHIP on the policy; without it the list is empty, so an empty result reads NOT_ASSESSED unless ACCOUNT_USAGE.PASSWORD_POLICIES also shows none. set_on is USER, ACCOUNT or SYSTEM.
- Warehouse generation and resource constraint come from SHOW WAREHOUSES (generation, resource_constraint), not from ACCOUNT_USAGE. Gen2 and Snowpark-optimized warehouses bill at a multiple of the standard credits per hour (Service Consumption Table 1(b) to 1(d)); adaptive warehouses have no fixed rate.
- Hidden objects: SHOW output and role-filtered views list only what the role can see. When grants, logins or task history prove an object exists that SHOW did not list, read NOT_ASSESSED, not "none found".
