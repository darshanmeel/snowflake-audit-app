# dims.* — names for ids, and the "of M" count bases

One-line summary: five small tables, one SQL file each in `app/queries/dims/`, run by the export into `dims/<name>.parquet` and loaded as `dims.<name>`; a dim that is missing becomes an empty stub so the app still starts and shows ids instead of names (tools/export_results.py:258, 1319-1324; tools/load_results.py:42-58, 591-627).

```mermaid
flowchart LR
  TV[ACCOUNT_USAGE.TASK_VERSIONS] --> DT[dim_task]
  WMH[ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY<br/>400 days] --> DW[dim_warehouse]
  U[ACCOUNT_USAGE.USERS live] --> DU[dim_user]
  DB[ACCOUNT_USAGE.DATABASES live] --> DD[dim_database]
  CA[CURRENT_ACCOUNT_NAME] --> DA[dim_account]
  DA -->|env_patterns| ENV[env, env_source, env_reason]
  TAGS[tags.tag_account] -->|per canonical key| DA
  DW --> NAMES[/api/dims -> names.tsx: name (id)/]
  DT --> NAMES
  DU --> CNT[N of M users]
  DD --> CNT2[N of M databases]
```

## Tables

| Dim | Key | Rows | Source | Used by |
|---|---|---|---|---|
| `dim_account` | `account_id` | 1 per account | app/queries/dims/dim_account.sql:3-4 | env filter, tag columns, `db_state` gate (app/core/data.py:201-219, 1555-1565) |
| `dim_warehouse` | `warehouse_id` (text) | per id metered in 400 days; latest name | app/queries/dims/dim_warehouse.sql:2-6 | names, warehouse filter by name (app/core/data.py:438-442), `/api/warehouses` (app/api/app.py:1387-1424) |
| `dim_task` | `task_full_name` = DB.SCHEMA.TASK | per task, newest graph version; dropped tasks kept | app/queries/dims/dim_task.sql:1-11 | task names, owner role, `/api/databases` schemas (app/api/app.py:1459-1461) |
| `dim_user` | `user_name` | live users only | app/queries/dims/dim_user.sql:2-4 | "N of M users" (app/core/finding_columns.py:91), tag compliance (app/core/tag_compliance.py:73-75) |
| `dim_database` | `database_name` | live databases only | app/queries/dims/dim_database.sql:2-4 | "N of M databases" (app/core/finding_columns.py:92), tag compliance (app/core/tag_compliance.py:76-78) |

- Placeholders `__ACCOUNT_ID__`, `__AS_OF_DATE__` are filled by the export (tools/export_results.py:609-610).
- No primary keys are declared in DuckDB; keys above are logical (tools/load_results.py:603).

## Rules with examples

- **Latest warehouse name wins.** id 1001 renamed A -> B inside 400 days -> one row `('1001','B')` (MAX_BY on start_time, app/queries/dims/dim_warehouse.sql:3). Inferred example.
- **Task key is the full name.** `RAW_DB.LANDING.LOAD` -> `task_full_name`; graph root resolved by `root_task_id` (app/queries/dims/dim_task.sql:4-8). Test: every task name contains a dot (tests/test_load_results.py:147-157).
- **Env by account name.** `ACME_PROD` -> `env='prod'`, `env_source='name'`; no match -> `unknown`/`none` (tools/load_results.py:104-124; tests/test_load_results.py:359-368). Test DB: `('FAKE01','FAKE_ACCOUNT','unknown')` (tests/test_load_results.py:157).
- **Account tag columns.** Per canonical key in config/tag_aliases.yml: `<key>`, `<key>_share`, `<key>_coverage`, `<key>_reason`; no tag -> `not_tagged` (tools/load_results.py:349-380). Test DB has `domain`, `cost_center`, `team`, `business_unit` sets (read from tests/db_audit_test.duckdb).
- **Missing dim -> stub.** Only dim_account exported -> the other four exist with 0 rows (tests/test_load_results.py:237-243). No dim_account file but manifest names the account -> one-row stub from `manifest.account` (tools/load_results.py:615-626).
- **Stale dim ignored.** A dim file not in `manifest.dims.available` is not loaded (tools/load_results.py:468-472, 594; tests/test_load_results.py:344-356).
- **Join by id alone.** Warehouses join on `warehouse_id` without `account_id` (app/core/data.py:1596-1598; web/src/components/names.tsx:47-48).

## Notes / issues

- `GET /api/warehouses` docstring says "the ones SHOW WAREHOUSES listed", but `dim_warehouse` comes from 400 days of metering, not SHOW (app/api/app.py:1389 vs app/queries/dims/dim_warehouse.sql:1-6). A warehouse with no metering in 400 days is not listed.
- names.tsx says "a database, schema, role or user has no dim" (web/src/components/names.tsx:15); dim_user and dim_database exist but are used only as count bases, not for names. Comment is accurate for name lookup only.
- `read_dim_task` docstring omits `task_id`, which it selects (app/core/data.py:1612-1619).
