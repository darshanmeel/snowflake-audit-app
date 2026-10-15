# Status

Last updated 13 Oct 2026.

## Where it stands
The POC is feature-complete and on `main`. It has not yet run on a live Snowflake account; the fake account is the test bed.

- **Checks:** 274 in `app/queries/checks`, run by the exporter on `SNOWFLAKE.ACCOUNT_USAGE` and `ORGANIZATION_USAGE`.
- **App:** FastAPI + DuckDB backend; React/TypeScript UI built by Vite from `web/` into `app/web/dist`.
- **Test queries:** `app/queries/verify/<section>.sql` (ai, cost, governance, pipelines, queries, storage, warehouses) recompute the app's figures by hand. How it works links them under "Test it yourself", and they ship in the export kit.
- **Export kit:** `tools/export_kit`, refreshed with `python tools/make_export_kit.py`. Refresh it after any SQL or check change.
- **Fake data:** `tests/fake_snowflake/`.
  - Base account used by the tests: `data.py`, `gap_*.py`, `new_checks_data.py`, `batch3_data.py`. Don't change these; the base fingerprint is pinned.
  - Demo layers: `demo_*.py`.
  - Build the demo DB with `python tools/build_demo_db.py` (about 3 min) into `data/demo/` (git-ignored). Run the app on it with `AUDIT_DB=data/demo/db_audit_demo.duckdb python -m app.api`.
- **History:** squashed to one commit on 13 Oct 2026. The old history is kept only as a local git bundle outside the repo.

## Next
1. **First live export (in progress: the user is getting access to real data).**
   - Use a role that can read the `SNOWFLAKE` database (`ACCOUNTADMIN`, or `IMPORTED PRIVILEGES` on it); a narrow role marks many checks not assessed.
   - Run the export kit, open the result in the app, and run `app/queries/verify/cost.sql` queries 1–3 next to Overview and Cost.
   - Bring back the failed and not-assessed checks with their error text (no data). Fix those first: each points to a column, type or function where the fake data and real Snowflake disagree.
   - Add any real names seen in the export to the name grep before the next commit.
   - Confidence before this run: view and column names high; types, NULL patterns and values only as good as the fake data. The fake tests prove the app agrees with itself, not with Snowflake: the SQL runs on DuckDB through sqlglot, and one author wrote both data and queries. Least certain: Cortex/AI views, Cortex Code, data transfer prices (20 and 90 $/TB are list-price guesses), timezones (fake timestamps are UTC).
2. **Access & Audit enrichment.** Effective user → role → table access with the path, the objects each query touched, object dependencies, and sensitive reads at odd hours. Before starting, settle two open questions: how deep the access path goes, and what counts as odd hours.

## Working preferences
- POC: commit and push to `main` after every finished change, don't over-engineer, and don't keep compatibility with older versions.
- Push back when a request is costly, breaks a rule or doesn't make sense, and offer the better option.
- Pages: less text; a headline figure or %, a chart that shows the cause, and a drill-down.
- Tests and the browser review only at the end. Between batches, run the compile checks only.
- When delegating: Sonnet builds, Opus designs and reviews. No workflows or builder agents unless asked.
