# Export flow (tools/export_results.py)

One run signs in, works out prices and what the role can read, runs every check (or its INFORMATION_SCHEMA fallback) over the 7/30/90-day windows, and writes `findings/*.parquet`, `dims/`, `tags_src/`, `manifest.json` and `report.md` into a results folder that `tools/load_results.py` loads.

Entry: `python tools/export_results.py --out DIR [...]` -> `main` (tools/export_results.py:1344-1393) -> `run_export` (tools/export_results.py:914-1159). The kit's `run_export.py` follows the same steps on one session (see processes/export-kit.md).

## Sequence

```mermaid
sequenceDiagram
    participant CLI as main()
    participant EX as run_export()
    participant SF as Snowflake session
    participant FS as results folder (.tmp)
    CLI->>EX: args, workers, include_today, mask kinds
    EX->>EX: cutoff, load_sources(), load_checks(), thresholds, window plan
    EX->>FS: create OUT.tmp/findings, dims
    EX->>SF: connect() (UTC, QUERY_TAG, statement timeout)
    EX->>SF: account_context(): account, region, prices (org billing views)
    EX->>SF: probe_visibility(): SELECT 1 ... LIMIT 0 per view, run each SHOW
    EX->>SF: detect_edition()
    EX->>SF: info_schema_db / MONITOR USAGE / account privileges (only if fallbacks exist)
    opt some check's views are unreadable (or --use-fallbacks)
        EX->>SF: run_query_feed(): 28 six-hour QUERY_HISTORY slices, async
        EX->>SF: run_shims(): SHOW + stand-in bodies + UNION joins, async
    end
    loop every check (1 or N worker sessions)
        alt edition too low
            EX->>EX: not_assessed (edition_too_low)
        else unreadable and a fallback exists
            EX->>SF: fallback SQL per window (reads shim results via literal rows / RESULT_SCAN)
        else unreadable, no fallback
            EX->>EX: not_assessed (role_cannot_see)
        else readable
            EX->>SF: pre SHOWs, then check SQL per window, LIMIT max_rows+1
        end
        EX->>FS: findings/<qid>.parquet
    end
    EX->>SF: tag_sources, dims
    EX->>FS: mask_folder(), manifest.json, report.md
    EX->>FS: rename OUT.tmp -> OUT
```

## Steps

1. **Parse flags.** `build_parser` (tools/export_results.py:1296-1319). `--statement-timeout` sets the module global used by `connect` (tools/export_results.py:1345-1347). `--validate` branches to `run_validate` instead (tools/export_results.py:1348-1372).
2. **Pick the money cut-off ("as of").** `_cutoff`: with `include_today` the first day left out is tomorrow; else now minus 8 h (`LAG_HOURS`), as a date (tools/export_results.py:818-825). `main` reads `include_today` from settings (tools/export_results.py:810-815, 1349); the default setting is `True` (app/core/config.py:160).
   - Example (tests/test_export_show.py:136-142): now 21 Sep 12:00 UTC, include_today false -> `2026-09-21`; now 21 Sep 03:00, false -> `2026-09-20`; 03:00, true -> `2026-09-22`.
3. **Refuse an output inside the repo.** `datasource.inside_repo(out_dir)` (tools/export_results.py:930-931; app/core/datasource.py:36-38).
4. **Read `sources:`** (your own copies of the views) into `_SOURCES`; a bad `sources` key stops the run, any other settings error only warns (tools/export_results.py:865-877). See logic/fallbacks.md "Your own copies".
5. **Load checks, thresholds, window plan.** `load_checks` requires header `query_id` == file name (tools/export_results.py:100-109); `--only` must name real checks (tools/export_results.py:934-938). `window_plan`/`window_sources`/`window_aliases_map` (tools/common.py:24-40).
   - Example (tools/common.py:25): `--windows 30` -> plan `[(7,7),(30,30),(90,30)]`; sources run `(7,7)` and `(30,30)`; alias `90 -> 30`, so the 90-day label reuses the 30-day rows.
6. **Work in `OUT.tmp`.** Created fresh with `findings/`, `dims/` (tools/export_results.py:944-948); renamed to `OUT` only at the end (tools/export_results.py:1156-1158), so a failed run never leaves a half folder under the final name.
7. **Connect.** `_load_env` reads the 8 `SNOWFLAKE_*` keys from the environment, then `.env` at the repo root; `SNOWFLAKE_ACCOUNT` and `SNOWFLAKE_USER` are required (tools/export_results.py:51-55, 450-461). `connect`: key file > password > browser (`externalbrowser`, with stored temporary credential); session `TIMEZONE=UTC`, `QUERY_TAG=query_source()`, `STATEMENT_TIMEOUT_IN_SECONDS` (tools/export_results.py:485-508). Any sign-in error becomes one line with a fix via `explain_connection_error` (tools/export_results.py:560-587, 933-941).
8. **Account context and prices.** `account_context` reads `CURRENT_ACCOUNT/REGION/ACCOUNT_NAME/ORGANIZATION_NAME`, derives cloud from region, and fills the three prices (tools/export_results.py:623-675). Its failure is treated as a session problem (tools/export_results.py:960-967). Price order: logic/pricing.md.
9. **Probe what the role can read.** `probe_visibility`: `SELECT 1 FROM SNOWFLAKE.<schema>.<view> LIMIT 0` for every source schema in `_VIEW_SCHEMAS`, every check `pre:` SHOW run unfetched, and a warehouse gap count (billed in 30 days vs `SHOW WAREHOUSES`) (tools/export_results.py:709-758).
10. **Edition.** `detect_edition`: `ORGANIZATION_USAGE.ACCOUNTS`, else "ENTERPRISE" (meaning at least) from feature evidence, else unknown (tools/export_results.py:590-620). A missing feature never proves Standard.
11. **Fallback prerequisites** (only when the selected checks have fallbacks): `info_schema_db`, `has_monitor_usage`, `account_privileges` (tools/export_results.py:970-973). Fallbacks to run = those whose check has an unreadable source, or all with `--use-fallbacks` (tools/export_results.py:974-975).
12. **Shared fallback inputs, once.** `run_query_feed` when any fallback reads the query feed (tools/export_results.py:976-977, 252-279); `run_shims` for the stand-ins those fallbacks read (tools/export_results.py:978-979, 282-382). Details: logic/fallbacks.md.
13. **Run each check** (`run_one`, tools/export_results.py:998-1081), in this order of decisions:
    - edition below Enterprise and the check needs it -> `not_assessed`, `edition_too_low`, not run (tools/export_results.py:1003-1013);
    - a source is unreadable (or `--use-fallbacks`) and a fallback exists -> run the fallback; any failure -> `not_assessed` `role_cannot_see`, never "empty" (tools/export_results.py:1014-1049);
    - a source is unreadable, no fallback -> `not_assessed` with each unreadable source and its error (tools/export_results.py:1050-1059);
    - else run it; an exception -> `failed` with `error_code` and `cause` from `reasons.classify_error` (tools/export_results.py:1060-1076).
14. **Per window.** `_run_check`: run the `pre:` SHOWs, render, pin `LAST_QUERY_ID()` to the SHOW's own query id, run with `LIMIT max_rows+1`, cut to `max_rows` and record the window as truncated, overwrite `window_days` with the label, blank unflagged waste (tools/export_results.py:772-788, 508-516; tools/common.py:70-85).
15. **Render.** `render`: paste `__INCLUDE_x__` from `app/queries/common/`, fill `:params` (header defaults overridden by `config/thresholds.yml`, `params_for` tools/export_results.py:212-219) and `:period_days`, the `__AS_OF_DATE__`/price/account placeholders, the query feed and shim results; leftover params raise; finally `apply_sources` (tools/export_results.py:409-452).
16. **Read-only guard.** Every statement passes `assert_read_only`: one `SELECT`/`WITH`/`SHOW`, no `;` outside string literals (tools/export_results.py:455-460); `run_sql` applies it on every call (tools/export_results.py:537-545).
17. **Normalise.** Lower-case column names (except `access_grants_inventory.grantee` -> `GRANTEE`), NUMBER -> int64/float64 (tools/export_results.py:512, 530-540).
18. **Workers.** `--workers N` (default 4, or 1 with browser sign-in: `default_workers` tools/export_results.py:550-557) gives each thread its own session, because a SHOW pre-step and its RESULT_SCAN must share one (tools/export_results.py:987-996, 1058-1071).
19. **Tag sources and dims** on the main session after all checks; failures only warn (tools/export_results.py:1097-1119; `_run_source` 1006-1022).
20. **Manifest.** Dates (`as_of_date`, `last_complete_day`, `export_date`, `lag_hours`), visibility, sources, edition, timeout, `monitor_usage`, `manage_grants`, windows/coverage/aliases, account, pricing with sources and `rate_basis`, `max_rows`, `masked`, per-check findings, dims, tag sources (tools/export_results.py:1123-1150).
21. **Mask, then write.** `app_masking.mask_folder` runs on the parquet files and the manifest before `manifest.json` and `report.md` are written, so no real name stays in the folder when masking is on (tools/export_results.py:1151-1155). Kinds: `--mask`, else `privacy.mask_fields` (tools/export_results.py:1334-1341).
22. **report.md.** Failed first, then not assessed, then all-NOT_ASSESSED rows, then the rest; header has price, edition, timeout, copies read, role visibility (tools/export_results.py:880-911, 818-845).
23. **Exit codes.** 2 = config error (`ExportConfigError`), 1 = connection error, 0 = done; prints the next command (tools/export_results.py:1379-1393).

There is **no zip step** in `export_results.py`; only the kit zips its output (`--no-zip` to skip, tools/export_kit/run_export.py:1576-1578). README says "zip the folder to move it" (README.md:739).

## Statuses written per check

| status | when | cite |
|---|---|---|
| `ok` / `empty` | ran; rows / no rows | tools/export_results.py:1066-1069 |
| `not_assessed` + `edition_too_low` | edition below Enterprise | tools/export_results.py:1005-1013 |
| `not_assessed` + `role_cannot_see` | source unreadable and no (working) fallback | tools/export_results.py:1034-1059 |
| `failed` | SQL error, timeout, view missing | tools/export_results.py:1070-1074 |

`--validate` instead runs every check and dim with `LIMIT 0` and writes `validate.json`/`validate.md`, grouping unreadable checks by cause with the GRANT for each; exits 1 only on real SQL errors (tools/export_results.py:1175-1289, 1342-1343).
