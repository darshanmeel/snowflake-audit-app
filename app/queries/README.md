# Snowflake checks

Read-only SQL over `SNOWFLAKE.ACCOUNT_USAGE` (and `ORGANIZATION_USAGE` for prices). Run by
`tools/export_results.py`; load with `tools/load_results.py`; the app reads the result
unchanged.

- `checks/<query_id>.sql`: one check. A file named like an existing check (e.g. `cost_period_over_period`)
  returns exactly that check's columns, so its tab works as is. `sf_*` files are Snowflake-only checks.
- `dims/<name>.sql`: name lookups (`dim_account`, `dim_warehouse`, `dim_task`).
- `common/<name>.sql`: shared CTEs, pulled in with `__INCLUDE_<name>__`.

## Writing a check

Header, one `-- key: value` per line (continuation lines start with `--   `):

```
-- query_id: sf_compute_resource_monitor_coverage      (= file name)
-- title: Warehouses with no resource monitor
-- domain: cost | compute | performance | jobs_pipelines | storage | governance_access | serving_ai
-- windowed: yes | no                                    (sf_* only; ports follow the registry)
-- pre: SHOW WAREHOUSES                                  (optional; read it with RESULT_SCAN(LAST_QUERY_ID()))
-- money: est_wasted_usd_list                          (optional; the one column that is the check's headline money)
-- entity: warehouses = warehouse_id                     (optional; what the "N of M" count counts, and its columns)
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SHOW WAREHOUSES
-- params: warn_usd=20, crit_usd=200                     (sf_* only; ports use the registry's params)
-- read_this: one row = ...; what the numbers mean
-- healthy: status = OK when ...
-- investigate_if: WARN when ...; CRITICAL when ...
-- actions: 1) ... (free); 2) ... (config); 3) ... (spend)
-- caveats: latency, scope, estimates
```

Body rules:
- One `SELECT`/`WITH` statement, no `;`. The exporter refuses anything else.
- First column `:period_days AS window_days` for a windowed check, `0 AS window_days` otherwise.
- Window filter: `col >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND col < __AS_OF_DATE__`.
- Placeholders: `__AS_OF_DATE__` (UTC date), `__ACCOUNT_ID__` (use as `account_id`), `__CLOUD__`,
  `__CREDIT_PRICE__` (USD per credit or NULL), `__STORAGE_PRICE_TB_MONTH__`, `__QUERY_SOURCE__` (the
  audit's own QUERY_TAG).
- Money: `est_<what>_usd_list = credits * __CREDIT_PRICE__`, plus `price_basis` ('priced' | 'unpriced').
- `status` in OK / WARN / CRITICAL / NOT_ASSESSED; with NOT_ASSESSED, `not_assessed_reason` says why.
- Waste and saving columns (`est_wasted_*`, `est_saving_*`) are blanked by the export on rows that are not
  WARN or CRITICAL. Never select query text, policy bodies or other statement text.
- `WAREHOUSE_METERING_HISTORY.CREDITS_ATTRIBUTED_COMPUTE_QUERIES` is NULL on adaptive warehouses: sum it
  without COALESCE and read NOT_ASSESSED (`no_query_attribution`), never idle.
- A row that totals or ties out its own parts sets a boolean `is_total_row`; it is never added to the
  rows it totals or counted as an entity. A row that repeats the same credits under a second basis sets
  `is_alt_basis`: it stays listed and counted, but the money sum leaves it out. Cloud services are priced billed only (after the daily 10%
  adjustment), never as `credits_used_cloud_services` alone.
- Show things as name and id columns (e.g. `warehouse_name`, `warehouse_id`).
- Session time zone is UTC; `ACCOUNT_USAGE` lags up to 3 hours (45 min to 3 h by view).

## Tag sources

`tag_sources/*.sql` are small aggregates the export writes to `tags_src/` (object tags, query-tag credits
and statements, warehouse billed and idle credits, billed credits per service). `tools/load_results.py` turns
them into the `tags.*` tables with `tools/build_tags.py`, so the Tag and cost-center filters and the tag
rollup work. Tag order: query tag, object tag, warehouse tag, user or role tag, account tag.
