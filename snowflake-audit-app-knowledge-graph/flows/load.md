# Load flow: export folder or zip -> DuckDB file + run_results sidecar

One-line summary: `tools/load_results.py` turns an export folder (or a `.zip` of one) into a fresh DuckDB file with schemas `findings`, `dims`, `summary`, `tags` (built from a temporary `tags_src`), two meta tables in `main`, and a `<db>.run_results.json` sidecar; it then points the app at the new file (tools/load_results.py:1-8, 306-324, 456-703, 727-791).

```mermaid
flowchart TD
  A[SRC: results folder or .zip<br/>default newest results/&lt;stamp&gt;] -->|zip| Z[_zip_data_as_of + safe_unzip<br/>to temp dir]
  A --> R[_content_root: descend single wrapper folder]
  Z --> R
  R --> M{manifest.json?}
  M -->|yes| MF[findings_meta = manifest.findings<br/>dims.available, window_aliases, max_rows]
  M -->|no: import mode| IM[every findings/*.parquet|csv = ok<br/>_infer_window_aliases]
  MF --> T[ATTACH &lt;db&gt;.tmp AS audit_db<br/>TimeZone UTC, memory_limit, threads]
  IM --> T
  T --> F[findings.f_&lt;qid&gt; per ok/empty check<br/>normalise_timestamps, mask, validate window_days,<br/>copy alias windows]
  F --> S[summary.finding_counts + finding_tables<br/>self-check: counts add up]
  S --> D[dims.dim_* real or empty stub<br/>dim_account + env columns]
  D --> TG[tags_src.* -> build_tags.build -> tags.*<br/>dim_account tag columns; DROP tags_src]
  TG --> META[main.direct_export_meta<br/>main.direct_export_findings_meta]
  META --> SW[close, delete .wal, os.replace tmp -> db]
  SW --> RR[&lt;db stem&gt;.run_results.json]
  RR --> P[set_current_db if db is inside data dir]
```

## Steps (with code)

1. **Pick source and target.** No SRC -> newest `results/<stamp>` holding a `manifest.json`, else `results/` itself (tools/load_results.py:218-223, 729). No `--db` -> `<data dir>/audit.duckdb` (tools/load_results.py:735; app/core/datasource.py:13, 65-66).
2. **Refuse a db inside the repo** unless it is a `.duckdb` under `data/` (tools/load_results.py:70-75, 732-738). Exit code 2.
3. **Unzip safely.** Zip date = newest entry under `findings/` or `dims/` (extract does not keep mtimes) (tools/load_results.py:256-279). Any entry starting with `/`, holding `:` or `..` is refused (tools/load_results.py:191-202). Temp dir always removed (tools/load_results.py:323-325).
4. **Find the content root**: descend one wrapping folder, skip dot entries and `__MACOSX` (tools/load_results.py:226-234).
5. **Read manifest** (export run manifest, not `app/queries/manifest.json`): `findings`, `max_rows`, `dims.available`, `window_aliases` (tools/load_results.py:458-484). Bad alias entries are skipped one by one (tools/load_results.py:477-484).
6. **No manifest = import mode**: every `findings/<id>.parquet|csv` with a valid id loads as `ok`; aliases inferred from windows present (tools/load_results.py:486-495, 327-346). None found -> `LoadConfigError` (tools/load_results.py:493-494).
7. **Build into `<db>.tmp`** attached as `audit_db` (avoids a catalog named like a schema), UTC, memory/threads from `settings.load` (tools/load_results.py:497-532).
8. **Per check** (tools/load_results.py:534-592):
   - status not `ok`/`empty` -> not built; `failed`/`not_assessed` keep error, `reason` (cause or `classify_error`), `sources` (unreadable views) (535-544).
   - id must match `[a-z][a-z0-9_]*`, else recorded as missing file (never spliced) (37, 545-547).
   - parquet wins over csv (162-168); CSV ids (`id`, `*_id`) forced to VARCHAR, `window_days` INTEGER (127-147).
   - timestamps -> naive UTC (87-101); masking if on (554-555).
   - `window_days` must exist and be in {0,7,30,90}, else failed (171-178, 560-564).
   - `CREATE TABLE findings."f_<qid>"`; for windowed checks each alias label gets a copy of its source label's rows (565-578).
9. **summary.* + self-check** (tools/load_results.py:427-454, 589). Mismatch raises -> whole load fails.
10. **Dims** (tools/load_results.py:596-632): only dims the manifest lists (stale files ignored); unreadable or absent -> empty stub with the columns readers select (42-58, 613-614); `dim_account` stub from `manifest.account` (615-626); env added by account name (104-124).
11. **Tags** (tools/load_results.py:384-424): load `tags_src/*.parquet` (only those the manifest lists), call `tools/build_tags.build`, add tag columns to `dims.dim_account` (353-380), then `DROP SCHEMA tags_src`.
12. **Meta tables** (tools/load_results.py:635-675). `as_of` = manifest, else zip date, else newest file mtime (630).
13. **Swap**: close, delete leftover `.wal`, `os.replace(tmp, db)`; on any error delete tmp files and re-raise (tools/load_results.py:676-688).
14. **Sidecar** `<stem>.run_results.json` (tools/load_results.py:283-304, 685-686; app/core/datasource.py:69-70).
15. **Point the app** at the db when it sits in the data dir (tools/load_results.py:755-760; app/core/datasource.py:77-84).

## Rules with examples

| Rule | Input -> output | Evidence |
|---|---|---|
| A result file missing or unreadable | manifest says ok, file gone -> the check is loaded as failed with that reason | tools/load_results.py:553, 561 |
| DB file locked by the running app | PermissionError -> "is open in the running app; stop the app, or pass --db <new file>", exit 2 | tools/load_results.py:749 |
| Zip as-of | zip entry time -> converted to UTC | tools/load_results.py |
| Alias windows copy rows | 7-day export of windowed check -> `window_days` {7,30,90}; `window_aliases` = `{"30":"7","90":"7"}`; point-in-time stays {0} | tests/test_load_results.py:270-281 |
| Session DB: 90 is a copy of 30 | `count(window_days=30) == count(window_days=90) > 0` | tests/test_load_results.py:77-89 |
| Bad window rejected | no `window_days` -> "missing column window_days"; 45 -> "window_days must be 0, 7, 30 or 90" | tests/test_load_results.py:318-328 |
| Timestamps naive UTC | 2026-09-20 23:30 +02:00 -> 2026-09-20 21:30 TIMESTAMP | tests/test_load_results.py:302-315 |
| CSV ids stay text | `warehouse_id` "1001" -> VARCHAR "1001"; 7-day CSV fills 30 and 90 | tests/test_load_results.py:389-407 |
| Failed check not built | `status: failed` -> no `f_` table, sidecar `failed` with message; `empty` -> 0-row table, sidecar `ok` | tests/test_load_results.py:227-251 |
| Missing dims -> stubs | only dim_account exported -> others empty stand-ins | tests/test_load_results.py:237-243 |
| Stale dim ignored | dim file not in `dims.available` -> not loaded; account named from manifest | tests/test_load_results.py:344-356 |
| Bad id refused | `x"; DROP TABLE y; --` -> `missing_file`, not spliced | tests/test_load_results.py:337-341 |
| Env by name | account `ACME_PROD` -> env `prod`, source `name` | tests/test_load_results.py:359-368 |
| Truncation recorded | `max_rows 3`, truncated -> meta `(True, 3, [30])`, sidecar "kept the first 3 rows per window" | tests/test_load_results.py:284-299 |

## How the app reads the result

- DB path: `AUDIT_DB`, else `current_db.txt` pointer, else `<data dir>/audit.duckdb` (app/core/data.py:103-112).
- Read-only connections; the API shares one per file and swaps it when the file identity changes (app/core/data.py:120-164).
- `db_state()`: `no_database` / `build_incomplete` (no `dims.dim_account`) / `ready` (app/core/data.py:201-219).
- Missing `findings.f_<qid>` -> `FindingNotBuiltError`, rendered NOT_ASSESSED (app/core/data.py:76-79, 239-250).
- Sidecar read by `run_results()`; a check absent from it is `not_built` (app/core/data.py:1809-1826, 1986-2006).

## CLI

- `python tools/load_results.py [SRC] [--db PATH]` (tools/load_results.py:711-729). README: README.md:303-374, 726-748.
