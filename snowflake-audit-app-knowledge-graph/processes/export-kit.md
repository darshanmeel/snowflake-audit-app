# Export kit: someone else runs the SQL

`tools/export_kit/` is a standalone copy of the export (one Python file plus every statement as plain `.sql`) that a customer runs on their own machine without the repo; they send back `sf-audit-out.zip`, which `tools/load_results.py` loads like a normal export (README.md:752-776).

```mermaid
sequenceDiagram
    actor M as Maintainer
    actor C as Customer admin / runner
    participant K as tools/make_export_kit.py
    participant R as run_export.py (kit)
    participant SF as Snowflake
    participant L as tools/load_results.py
    M->>K: python tools/make_export_kit.py [--zip DIR]
    K->>K: write queries/, index.json, grants.sql, verify/, README.md, refresh masking block
    K-->>M: export_kit.zip (no .env, .p8, sf-audit-out*)
    M->>C: send zip
    C->>SF: run grants.sql once (ACCOUNTADMIN), or use any role
    C->>R: .env + python run_export.py [--windows 90] [--credit-price 3.0] [--mask ...] [--source ...]
    R->>SF: SELECT / WITH / SHOW only
    R-->>C: sf-audit-out/ + sf-audit-out.zip
    C->>M: send sf-audit-out.zip
    M->>L: python tools/load_results.py sf-audit-out.zip
```

## Steps

1. **Refresh the kit** after any SQL, check or README "Roles and privileges" change: `python tools/make_export_kit.py` (tools/make_export_kit.py:1-8; STATUS.md "Export kit"). `tests/test_export_kit.py:38-42` fails while the committed kit differs from a fresh build.
2. **What `build` writes** (tools/make_export_kit.py:169-244):
   - `queries/checks/*.sql`, `fallback/`, `shims/`, `common/is_query_history_feed.sql`, `tag_sources/`, `dims/`, each with includes pasted in and `__QUERY_SOURCE__` fixed to the query tag (tools/make_export_kit.py:179-217);
   - `queries/index.json`: per check `domain`, `windowed`, `pre`, `sources`, `params` (header defaults + thresholds), `needs_enterprise`, and `fallback` meta (`pre`, `reads`, `note`, `needs`, `query_feed`, `shims`); plus `defaults` (max_rows, include_today, the three settings prices, query_tag), tag_sources and dims (tools/make_export_kit.py:185-236);
   - `grants.sql`: cut from README "### The grant script", so the two never differ (tools/make_export_kit.py:128-131);
   - `verify/*.sql` from `app/queries/verify` (tools/make_export_kit.py:238-239);
   - `README.md` = fixed head + README "Roles and privileges" with the `--validate` bullet removed (tools/make_export_kit.py:32-102, 110-123, 232);
   - the masking block inside `run_export.py`, copied from `app/core/masking.py` between marker lines (tools/make_export_kit.py `refresh_masking`);
   - the shared block inside `run_export.py`, copied from `tools/export_shared.py` the same way: SQL literals, the read-only SHOW runner `run_all`, shim and fallback helpers, `normalise`, `info_schema_db`, `short`. `tools/export_results.py` imports the same module, so a change there reaches both exports. `tests/test_export_kit.py::test_the_committed_kit_is_up_to_date` fails when the kit was not refreshed.
   - A kit folder elsewhere must be outside the repo (tools/make_export_kit.py:171-172).
3. **Zip to send.** `--zip DIR` (outside the repo) copies the kit without `.env`, `*.p8`, `sf-audit-out*`, `__pycache__` and writes `DIR/export_kit.zip` (tools/make_export_kit.py:247-259). Test: tests/test_export_kit.py:59-64.
4. **Customer grants.** `grants.sql` creates placeholder `AUDIT_ROLE`, service `AUDIT_USER` with a public key, XS `AUDIT_WH`; grants `IMPORTED PRIVILEGES` (or four `SNOWFLAKE.*_VIEWER` database roles: 249 of 298 checks), `MONITOR USAGE`, `MONITOR EXECUTION`, Trust Center / Budget / Data quality application roles, optional `APPLY AUTHENTICATION|PASSWORD POLICY` (commented out: they let the role change those policies); per-warehouse `MONITOR` and org billing roles are commented (tools/export_kit/grants.sql:1-57). What each grant opens: README.md:203-230.
5. **Customer sign-in.** `.env` next to `run_export.py` or environment: the same 8 `SNOWFLAKE_*` keys; key file > password > browser (tools/export_kit/run_export.py:39-43, 972-1006).
6. **Run.** `python run_export.py` (tools/export_kit/run_export.py:1535-1579). Flags: `--out` (default `sf-audit-out`), `--windows` (30), `--credit-price`, `--ai-credit-price`, `--storage-price`, `--use-fallbacks`, `--only`, `--max-rows`, `--statement-timeout` (900), `--no-zip`, `--mask`, `--mask-salt`, `--source VIEW=COPY` (repeatable) (tools/export_kit/run_export.py:1537-1554).
7. **Same decisions as the full export**, on one session: account context, probe, edition, fallback prerequisites, query feed, shims, then per check edition / fallback / not assessed / run (tools/export_kit/run_export.py:1345-1463). Prices default to `index.json` defaults instead of settings (tools/export_kit/run_export.py:1108-1152, 1286).
8. **Ctrl+C** keeps what ran, marks the rest `failed` "not run: the export was stopped ...", skips remaining tag sources and dims, and still writes `manifest.json` (`stopped_early: true`) and `report.md` (tools/export_kit/run_export.py:1410-1416, 1402-1408, 1433-1435, 1447-1449, 1480; report line 1201). Test: tests/test_export_kit.py:125-163.
9. **Output.** Same folder layout and manifest keys as `export_results.py`, masked before the manifest is written, renamed from `.tmp`, then zipped to `<out>.zip` unless `--no-zip` (tools/export_kit/run_export.py:1502-1531, 1533-1535). Test that both write the same: tests/test_export_kit.py:67-88.
10. **Load.** `python tools/load_results.py sf-audit-out.zip` (README.md:768-770; tools/load_results.py:711-729).

## Business rules

- **Read-only, refused before sending:** anything but one SELECT/WITH/SHOW raises `StopExport` (tools/export_kit/run_export.py:961-966). Test: tests/test_export_kit.py:90-106.
- **One failure never stops the run:** errors are recorded per check (tools/export_kit/run_export.py:1452-1456). Test: tests/test_export_kit.py:108-123.
- **A role that reads nothing still finishes**, every check `not_assessed` (tests/test_export_kit.py:165).
- **One Python file, no repo imports** (tests/test_export_kit.py:45-56).

## Differences from tools/export_results.py

| Topic | Full export | Kit | Cite |
|---|---|---|---|
| Copies of views | settings `sources:` | `--source` flag | tools/export_results.py:865-877; tools/export_kit/run_export.py:1552-1563 |
| Sessions | `--workers` (4, or 1 with browser) | one session | tools/export_results.py:987-996 |
| `--validate` | yes | no | tools/make_export_kit.py:117-124 |
| Zip | no | `<out>.zip` | tools/export_kit/run_export.py:1576-1578 |
| Ctrl+C | not caught | report still written | tools/export_kit/run_export.py:1410-1416 |
| Default prices | settings at run time | settings at kit build time (`index.json`) | tools/make_export_kit.py:222-226 |
| `include_snowflake_tasks` | from settings | from `index.json` defaults (kit build time) | tools/make_export_kit.py:227; tools/export_kit/run_export.py:1349 |
| `git_commit` in manifest | `git rev-parse HEAD` | null; `queries_sha256` (digest of the kit's `queries/*.sql`) names the SQL version instead | tools/common.py:88-93; tools/export_kit/run_export.py:1503; tools/make_export_kit.py:234 |
| Sign-in error | one line + fix (`explain_connection_error`) | "could not sign in: ..." plus a fix hint; the `.tmp` work folder is removed | tools/export_results.py:560-587; tools/export_kit/run_export.py:1338-1342 |
