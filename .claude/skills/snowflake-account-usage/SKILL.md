---
name: snowflake-account-usage
description: Catalog of SNOWFLAKE.ACCOUNT_USAGE, ORGANIZATION_USAGE and SHOW sources (grain, latency, retention, edition, role visibility, column types, status) plus the known traps and billing rules. Use it before writing, reviewing or fixing any SQL in this repo that reads ACCOUNT_USAGE, ORGANIZATION_USAGE, DATA_SHARING_USAGE, TRUST_CENTER or SHOW output, and before turning credits into dollars, so view and column names are looked up here instead of guessed.
---

# Snowflake account usage

The audit app reads Snowflake through SQL checks in `app/queries/checks` (with `common/` and `dims/`). This skill holds what those checks need to know about the sources they read. It was checked against docs.snowflake.com on 2026-09-28.

## How to use

1. Look up every view you touch in `references/views.md`. Use the exact column names and types given there. When a row says a view does not exist, is deprecated or has renamed columns, follow what the row says.
2. Read `references/traps.md` and go through the list for the views in your query. The short list below covers the ones that break money numbers.
3. If a view or column is not in the catalog, check it on docs.snowflake.com before using it, then add a row here.
4. If the view is missing, the edition is too low, or the role cannot see the data, the check reads NOT_ASSESSED. It never reads "nothing found" or $0.

## Top traps (full list in references/traps.md)

- **Credits used are not billed.** `CREDITS_USED` in METERING_HISTORY, WAREHOUSE_METERING_HISTORY, QUERY_HISTORY and METERING_DAILY_HISTORY is gross. Billed = `METERING_DAILY_HISTORY.CREDITS_BILLED`.
- **Latency.** Queries 45 min, most views 3 h, cloud services 6 h, pruning 4 to 6 h, attribution 8 h, Snowpipe Streaming 12 h, org billing 72 h. Mark the recent window partial.
- **Timezones.** AU hourly views are TIMESTAMP_LTZ in the session timezone. OU views and daily dates are UTC. Run `ALTER SESSION SET TIMEZONE = 'UTC'` first.
- **Retention.** AU keeps 365 days. Asking for more returns fewer rows without an error.
- **Attribution is not a total.** QUERY_ATTRIBUTION_HISTORY leaves out idle time, queries under about 100 ms, adaptive warehouses, cloud services and serverless. Its data is complete only from mid-Aug 2024.
- **Role visibility.** SHOW commands and object views such as RESOURCE_MONITORS, COPY_HISTORY, PIPES, STAGES, SCHEMATA, FUNCTIONS, TAGS, NETWORK_RULES and COMPLETE_TASK_GRAPHS show only what the role can access. Report the gap as "not visible", not as a pass.
- **Types.** Some credit and byte columns are VARCHAR or VARIANT, and some flags are VARCHAR or VARIANT instead of BOOLEAN. Cast before SUM or compare (see traps.md).
- **Dropped objects.** Names are NULL, and names get reused. Join on `*_ID`. In TABLE_STORAGE_METRICS, `DELETED` is BOOLEAN, the key is `ID`, and Fail-safe rows can have NULL names.
- **Missing views.** There is no AU view for STREAMS, EXTERNAL_TABLES, DYNAMIC_TABLES, ICEBERG_TABLES, AUTHENTICATION_POLICIES, BUDGETS or AUTO_REFRESH_REGISTRATION_HISTORY. Use SHOW, the TABLES flags or the named replacement.
- **Renames.** SEARCH_OPTIMIZATION_HISTORY now has `BASE_TABLE_ID`/`BASE_TABLE_NAME` and `INDEX_*` in place of `TABLE_ID`/`TABLE_NAME`. The Cortex usage views moved to CORTEX_AI_FUNCTIONS_USAGE_HISTORY.
- **POLICY_REFERENCES** does not list authentication, password or session policies. Use SHOW ... POLICIES or the INFORMATION_SCHEMA function.
- **Enterprise-only views** exist on Standard edition but return nothing. Empty is not good.

## Billing rules

**Credits used vs billed.** Each hour, compute credits and cloud services credits are metered separately. Cloud services are billed only for the part of a day's cloud services usage above 10% of that day's warehouse compute. `METERING_DAILY_HISTORY` gives:
`CREDITS_BILLED = CREDITS_USED_COMPUTE + CREDITS_USED_CLOUD_SERVICES + CREDITS_ADJUSTMENT_CLOUD_SERVICES`, and the adjustment is negative.
- Price billed credits, never hourly `CREDITS_USED`.
- For hourly or per-warehouse views, price compute in full and handle cloud services at day level, or spread the daily adjustment in proportion.
- `QUERY_HISTORY.CREDITS_USED_CLOUD_SERVICES` is before the adjustment.

**Warehouse rates.** The metering views already report credits, so never rebuild spend from size times hours. Use rates only for what-if estimates, such as resizing or changing auto-suspend.
- Standard Gen1 warehouses: X-Small uses 1 credit per hour, and each size up doubles the rate. Billing is per second, with a 60-second minimum each time a warehouse resumes.
- Gen2 and Snowpark-optimized warehouses use more credits per hour than a Gen1 warehouse of the same size. Take the multipliers from the Snowflake Service Consumption Table, not from code constants, and label any estimate as an estimate.
- Multi-cluster warehouses bill each running cluster.

**Serverless.** Auto clustering, materialized views, search optimization, serverless tasks and alerts, Snowpipe, Snowpipe Streaming, replication, QAS, DMF monitoring, SPCS and others appear in `METERING_HISTORY` / `METERING_DAILY_HISTORY` by `SERVICE_TYPE`. Their own per-object views give the breakdown. Each has its own compute and cloud services multiplier in the consumption table, and the metered credits already include it. They can also have a different $/credit on the rate sheet. Sum by SERVICE_TYPE from METERING_DAILY_HISTORY for totals, and use the per-feature views only to split those totals.

**Storage.** Storage is billed in currency per TB-month on the daily average bytes, not in credits.
- Kinds: active, Time Travel, Fail-safe, internal stage, hybrid table, and archive cool/cold.
- `STORAGE_USAGE` and `DATABASE_STORAGE_USAGE_HISTORY` give the split, but they do not reconcile with the bill.
- `ORGANIZATION_USAGE.STORAGE_DAILY_HISTORY` is the view closest to the bill. Its AVERAGE_BYTES includes Time Travel and Fail-safe.
- Per table: TABLE_STORAGE_METRICS has ACTIVE_BYTES, TIME_TRAVEL_BYTES, FAILSAFE_BYTES and RETAINED_FOR_CLONE_BYTES.
- Transient and temporary tables have no Fail-safe.

**Data transfer.** AU `DATA_TRANSFER_HISTORY` holds bytes only, with `BYTES_TRANSFERRED` as VARIANT. The price per TB depends on the route (same region, cross region, cross cloud, internet). Get currency only from `OU.USAGE_IN_CURRENCY_DAILY`. Without OU access, show bytes and say so.

**AI token credits.** Cortex functions bill token or page credits separately from the warehouse that ran the query.
- `METERING_DAILY_HISTORY` with SERVICE_TYPE `AI_SERVICES` is the reconciled total.
- Split it with CORTEX_AI_FUNCTIONS_USAGE_HISTORY. Filter on `IS_COMPLETED` and parse `METRICS`.
- Add the Cortex Analyst, Search serving, Document Processing, Fine-tuning and Agent views for the rest.
- Never add the old and new Cortex views together, because their date ranges overlap.

**Effective $/credit.** Get it from the org billing views where the role can read them:
- `RATE_SHEET_DAILY.EFFECTIVE_RATE` for each SERVICE_TYPE, RATING_TYPE and date;
- or `USAGE_IN_CURRENCY_DAILY.USAGE_IN_CURRENCY / USAGE`, grouped by SERVICE_TYPE, RATING_TYPE and BILLING_TYPE;
- never by USAGE_TYPE, which is legacy.

Price compute, cloud services and each serverless type at its own rate. Without OU access, fall back to one configured list price and label every $ figure as an estimate. OU billing values lag up to 72 h and can change until month end (`IS_ADJUSTMENT`), so pick one money cut-off before that lag.

**Budgets and resource monitors.** There is no budgets view. Budgets use `CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_HISTORY(...)` and `SHOW SNOWFLAKE.CORE.BUDGET INSTANCES`, which are CALLs and not allowed in this read-only app. RESOURCE_MONITORS is privilege-filtered, and its quota columns are VARIANT.
