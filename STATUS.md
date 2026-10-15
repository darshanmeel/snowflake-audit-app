# Status

Last updated 15 Oct 2026.

## Where it stands
The POC is feature-complete and on `main`. It has run on one small live trial account (3 days of use) and on the fake and demo accounts.

- **Checks:** 279 in `app/queries/checks`, run by the exporter on `SNOWFLAKE.ACCOUNT_USAGE` and `ORGANIZATION_USAGE`.
- **First live run (trial account, 3 days):** 152 ok, 122 empty, 4 not assessed, 1 failed (`sf_ai_model_serving_spend`, Snowflake error 100038). Prices came from `RATE_SHEET_DAILY` ($3.00 per credit, $2.00 per AI credit).
- **Prices:** for credits, AI credits and storage the export takes the first of: the command-line price, the rate sheet, the 90-day invoice rate, then `config/settings.yml` (3.00 and 2.00).
- **INFORMATION_SCHEMA fallbacks:** five checks have a second version in `app/queries/fallback/` (query load per warehouse, failed queries, queue waits, sign-ins, database storage growth), run when the role cannot read `ACCOUNT_USAGE` or with `--use-fallbacks`. The three query checks share one read of the query history (`common/is_query_history_feed.sql`), run once per export and read with `RESULT_SCAN`. Tested live on both the full export and the export kit.
- **App:** FastAPI + DuckDB backend; React/TypeScript UI built by Vite from `web/` into `app/web/dist`.
- **How it works (Guide):** same layout as the Databricks app (home, tab pages, check pages ending in "Run it yourself", troubleshooting, glossary), plus concept pages and "Traps to know".
- **Test queries:** `app/queries/verify/<section>.sql` (ai, cost, governance, pipelines, queries, storage, warehouses) recompute the app's figures by hand. How it works links them under "Test it yourself", and they ship in the export kit.
- **Export kit:** `tools/export_kit`, refreshed with `python tools/make_export_kit.py`. Refresh it after any SQL, check or README "Roles and privileges" change.
- **Fake data:** `tests/fake_snowflake/`.
  - Base account used by the tests: `data.py`, `gap_*.py`, `new_checks_data.py`, `batch3_data.py`. Don't change these; the base fingerprint is pinned.
  - Demo layers: `demo_*.py`.
  - Build the demo DB with `python tools/build_demo_db.py` (about 3 min) into `data/demo/` (git-ignored). Run the app on it with `AUDIT_DB=data/demo/db_audit_demo.duckdb python -m app.api`.
- **History:** squashed to one commit on 15 Oct 2026.

## Next
1. **A run on a busy account.** The user is running an export with a narrow role (no `ACCOUNT_USAGE`, no organization views), where the fallbacks take over. Read its manifest: confirm the five fallbacks ran, and why database storage growth came back empty (likely `MONITOR USAGE`).
   - Run `app/queries/verify/cost.sql` queries 1–3 next to Overview and Cost on a full-access export.
   - Add any real names seen in an export to the name grep before the next commit.
2. **`sf_ai_model_serving_spend`** fails with error 100038 on the trial account. Find the column or type that differs from the docs.
3. **Chargeback** splits $22 on the trial account against $19 metered and $21 billed. Find where the extra comes from.
4. **More fallbacks, if narrow roles are common:** warehouse metering, data transfer, warehouse load, task and serverless histories have INFORMATION_SCHEMA table functions.
5. **Small leftovers:**
   - the circular import between `area_ai_storage.tsx` and `ai_cortex_agents.tsx`;
   - the tags CSV caps examples at 10 per key;
   - no Copy link on mobile;
   - `check_queries.py` doesn't lint the fallback SQL;
   - the database-role counts in the README's "Roles and privileges" were made at 274 checks; recount them.
6. **Access & Audit enrichment.** Effective user → role → table access with the path, the objects each query touched, object dependencies, and sensitive reads at odd hours. Before starting, settle two open questions: how deep the access path goes, and what counts as odd hours.

## Working preferences
- POC: commit and push to `main` after every finished change, don't over-engineer, and don't keep compatibility with older versions.
- Push back when a request is costly, breaks a rule or doesn't make sense, and offer the better option.
- Pages: less text; a headline figure or %, a chart that shows the cause, and a drill-down.
- Tests and the browser review only at the end. Between batches, run the compile checks only.
- When delegating: Sonnet builds, Opus designs and reviews. No workflows or builder agents unless asked.
