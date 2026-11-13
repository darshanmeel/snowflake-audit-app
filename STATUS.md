# Status

Last updated 13 Nov 2026.

## Where it stands
The POC is feature-complete and on `main`. It has run on one small live trial account (3 days of use) and on the fake and demo accounts.

- **Checks:** 298 in `app/queries/checks`, run by the exporter on `SNOWFLAKE.ACCOUNT_USAGE` and `ORGANIZATION_USAGE`.
- **Heaviest tables:** Activity › Tables ranks tables by query time, partitions read, full scans or spill (`sf_use_table_heaviest`, from TABLE_QUERY_PRUNING_HISTORY plus QUERY_HISTORY spill by statement shape). Browser-checked on the test DB; not yet run live.
- **Your own copies:** settings `sources:` (and the kit's `--source`) swaps `SNOWFLAKE.<schema>.<view>` for a customer copy in every statement the export runs, the probe included (`app/core/config.py` `apply_sources`). Not yet run live.
- **One table, day by day:** Activity › Tables shows "How it ran" for a picked table: time per query, waiting per query, partitions skipped and clustering credits, from `sf_use_table_perf_daily`. It keeps the same busy tables as `sf_use_table_daily` plus the top clustering tables, which adds one more `ACCESS_HISTORY` scan. There is no query cost or storage per table per day, because Snowflake has no such figure. Checked on the demo account only, not yet live.
- **Full scans:** `sf_query_full_scans` now tests each table a shape reads, using `TABLE_QUERY_PRUNING_HISTORY`, and names the biggest fully scanned table. Not yet run live.
- **Activity area:** its own tab (Databases, Schemas, Tables, Users & roles, Stages & other objects) in `web/src/components/area_activity.tsx`; Lineage keeps Dependencies and adds Explorer (`area_lineage_explorer.tsx`: pick a table or view, see all upstream and downstream, from `sf_lin_declared_links` and `sf_lin_copied_links`), and old `lineage/usage` links land on Activity › Databases. Checks: `sf_use_table_activity`, `sf_use_table_daily`, `sf_use_table_readers`, `sf_use_user_data_io`, `sf_use_object_activity` and a reworked `sf_use_database_activity`, on the shared includes `sf_use_access_events` and `sf_use_query_roles`. Tables has a database picker, a reads / writes / rows changed / DDL ranking, and the WHERE and JOIN columns per table (`sf_use_table_columns`, from COLUMN_QUERY_PRUNING_HISTORY; GROUP BY is not recorded by Snowflake). One table and one user (Users page picker) show how their queries run (queries a day, avg and p90 time, partitions per query, spill), their top 10 users or tables, and their top 10 query shapes by runs, time, partitions or spill with each shape's tables read and written and WHERE/JOIN columns (`sf_use_query_profile`, `sf_use_top_query_shapes`, on the include `sf_use_query_metrics`; 25 tables and 25 users). Activity lists show the top 10 or 20 only. Unpriced except never-used schema storage, so nothing new reaches Waste. Checked in a browser on the demo DB.
- **Access log and sensitive data (13 Nov 2026):**
  - Four checks: `sf_use_access_log`, `sf_gov_sensitive_suggestions`, `sf_gov_tag_objects` and `sf_gov_file_downloads`. The logic is in `snowflake-audit-app-knowledge-graph/logic/access-log.md`.
  - **Activity › Access log:** pick any table, view or stage and see who used it, with which role and client, and how many reads, writes and DDL queries per day. Hourly is a setting (`grain` in `config/thresholds.yml`). The page shows the statement types and DDL operations, never query text, plus a SQL to list the single queries.
  - **Off-hours use by people:** queries outside business hours or at weekends. Service users and SYSTEM are left out. Business hours and timezone are set in `config/thresholds.yml`.
  - **PII › Tags:** a tag's objects, who can read them (grant paths) and who queried them.
  - **PII › Sensitive data:** untagged columns whose names look sensitive, with the suggested category and a `SYSTEM$CLASSIFY` call.
  - **PII › Who reads it:** GET and unloads per user and stage, with the sensitive source tables.
  - A check can declare `:row_cap` to raise the 50,000-row export cap; the access log uses 1,000,000.
  - Checked on the fake account through the SQL smoke run and the API; not yet run live.
  - **Review fixes (13 Nov 2026):** the review's Should findings are fixed:
    - masking no longer turns fixed values into name tokens;
    - users with no TYPE are not flagged as people;
    - SESSIONS reads are bounded;
    - the page says when the log was cut at its row cap;
    - the tag explorer uses one query;
    - the chart shows every day;
    - the detail SQL is bounded and includes DDL;
    - the counts come from every row;
    - the search is debounced;
    - the routes have tests.
    Off-hours rows by people stay WARN, and business hours default to UTC.
  - **Shared export helpers:** the 24 helpers the exporter and the kit had twice now live in `tools/export_shared.py`. `tools/make_export_kit.py` copies them into the kit between marker lines, as it does for masking. The run loops (`run_export`, `run_windows`, `_run_check`, `render`, the account context) still differ: the kit has no repo, settings or registry. They stay as two copies.
  - **Pending:** the Playwright check of the two new pages and the two changed PII pages (the Playwright plugin was not loaded); `tests/test_export_kit.py::test_ctrl_c_keeps_what_ran_and_writes_the_report` stops pytest with KeyboardInterrupt on Windows, on the code before this change too. Graph and technical-doc `path:line` cites are remapped to the current code (commit after 8cf5924). `docs/overview.html` and `docs/technical.html` cover the new pages and counts; the technical doc's layout check needs Playwright.
- **Last active:** Activity › Last active shows tables, and separately other objects, by time since last active (under 30, 30–90, 90–180, 180–360, over 360 days); picking a bar lists them oldest first, with a CSV. One check, `sf_use_last_active`, scans up to 365 days of `ACCESS_HISTORY` once. On an account with less history, longer gaps read as "nothing in the N days of history", and bands it can't reach read "–". The Database and Schema filters narrow the bars too; the Owner filter doesn't reach this page. `sf_storage_unused_tables` stays at 90 days, so the Waste figure doesn't change. Run live on one small account; not yet on a busy one.
- **Access explorer:** Access › Explorer picks a user, role or object and shows every privilege with every path through the roles, and who else holds it A graph draws an arrow per grant: a few users on the left, the roles, then what they reach grouped by schema (counts, sensitive badge, arrows coloured by privilege class); a schema box opens to its objects, "Path to" shows the routes to a second name, a table row shows its own paths. Link params: `explore=`, `to=`, `open=`. (`app/api/explorer.py` walks `sf_acc_grant_links`; database roles are nodes; links can open it with `&explore=role:NAME`). Five rule checks sit on the pages that own them: `sf_acc_roles_used_both_ways`, `sf_acc_redundant_role_grants`, `sf_acc_readonly_roles_write` (Roles & grants), `sf_acc_disabled_users_roles` (Users), `sf_acc_sensitive_reach` (PII › Who reads it: who *can* read each sensitive table). Rules come from grant data, not role-name conventions.
- **First live run (trial account, 3 days):** 152 ok, 122 empty, 4 not assessed, 1 failed (`sf_ai_model_serving_spend`, Snowflake error 100038). Prices came from `RATE_SHEET_DAILY` ($3.00 per credit, $2.00 per AI credit).
- **Prices:** for credits, AI credits and storage the export takes the first of: the command-line price, the rate sheet, the 90-day invoice rate, then `config/settings.yml` (3.00 and 2.00).
- **INFORMATION_SCHEMA fallbacks:** 85 checks have a second version, run when the role cannot read `ACCOUNT_USAGE` (or with `--use-fallbacks`): the check's own SQL with each view swapped for a stand-in in `app/queries/shims/` (52 views, from table functions, per-database INFORMATION_SCHEMA views and SHOW). A stand-in with `each:` runs once per database, warehouse, role or policy, and the parts are joined. Gates: MONITOR USAGE (spend, storage), MANAGE GRANTS (SHOW-based: users, roles, grants, policies), the APPLY policy privileges (policy references); the manifest has `monitor_usage` and `manage_grants`. 22 coverable checks are left out on purpose (a needed column is NULL: spill, password age, IP lists, policy settings, revoked grants, Snowpipe loads). Tested live: all 85 ran (53 ok, 32 empty, none failed), and the kit.
- **App:** FastAPI + DuckDB backend; React/TypeScript UI built by Vite from `web/` into `app/web/dist`.
- **How it works (Guide):** same layout as the Databricks app (home, tab pages, check pages ending in "Run it yourself", troubleshooting, glossary), plus concept pages and "Traps to know".
- **Test queries:** `app/queries/verify/<section>.sql` (ai, cost, governance, pipelines, queries, storage, warehouses) recompute the app's figures by hand. How it works links them under "Test it yourself", and they ship in the export kit.
- **Streamlit in Snowflake:** `tools/streamlit_deploy` ships the same API and React build with the DuckDB file the local app opens, and refuses a file holding demo or test data, by its contents. `deploy.py` writes the upload and create SQL, or runs them with `--run`. The upload clears `app_src/` first and leaves keys out. Settings are read-only in the app. Warehouse runtime is the default (a v1 component in its own frame, `environment.yml`, no compute pool); Snowflake's docs list only `html` and `iframe` for v1, so this may not be allowed. Container runtime (v2 component, compute pool) is the fallback. Both checked in a browser with Streamlit run locally (1.52.2 and 1.56 on Python 3.11). The upload sends one PUT per file where a folder has subfolders, and warehouse runtime is named in CREATE STREAMLIT; neither has run live. Not yet run in Snowflake, so packages, DuckDB, the security policy, speed and `--run` are open there.
- **Export kit:** `tools/export_kit`, refreshed with `python tools/make_export_kit.py`. Refresh it after any SQL, check or README "Roles and privileges" change.
- **Not verified yet:** `sf_ai_model_serving_spend` error 100038 is not reproduced (the view is empty on the trial account), and `sf_lin_copied_links` has not run on a live account. The full test suite passed at 485 tests (about 25 minutes); tests added since (Access explorer, sources) pass on their own.
- **Access log redesign (13 Nov 2026):**
  - Activity › Access log has a left panel with three sections:
    - **Overview:** tiles, off-hours use by people with a person × sensitive-object heatmap, hours of use per person, busiest objects;
    - **One object:** per day by user, role, client, statement or read/write/DDL; by client, role and user; statement kinds; role × client; who used it; the single-query SQL;
    - **One person:** hours of use, per day, objects used.
  - A UTC-offset slider (UTC−12 to UTC+14) recounts off hours in place. `sf_use_access_log` now keeps one row per statement type and judges nothing. The new `sf_use_access_hours` keeps people's queries per UTC hour and holds the off-hours WARN at `business_utc_offset`. Both read the shared include `sf_use_access_rows`.
  - Checked in a real browser (Playwright driving Edge, `pip install playwright` in the venv, no browser download) on the fake account: all three sections render, laid out after the design mock (one-line names, a 70/30 off-hours split with the heatmap, hours-of-use rows with an on/off bar, toggles in card heads, statement-type block, activity timelines).
  - `thresholds.yml` takes numbers only, so the old `grain` and `business_tz` settings are gone: `bucket_hours` and `business_utc_offset` replace them.
- **Access log tab (13 Nov 2026):**
  - The Access log is its own top-level tab, no longer under Activity; old links redirect.
  - One object starts with a type (tables, views, stages, procedures, functions, Streamlit apps). A Streamlit app shows:
    - who it is shared with (`sf_acc_streamlit_shares`: grants and revokes from GRANTS_TO_ROLES);
    - who can open it now (grant paths);
    - who opened it: the role they used, their grant path to the app, days, sign-in IP and client;
    - the role its own queries ran as, and whether it runs with owner's or restricted caller's rights (caller's rights: per viewer);
    - what it read.
  - A read by a write statement (INSERT ... SELECT FROM a view) is labelled `INSERT (source)`; views never show a plain INSERT.
  - One user or role: a user's or a role's activity, what was touched by kind, and the apps a user opened.
- **Procedures, Streamlit apps, schema rollup (13 Nov 2026):**
  - Every access row carries `via`: the procedure a query ran inside (`ACCESS_HISTORY.root_query_id`), or the Streamlit app named in its QUERY_TAG.
  - New check `sf_use_streamlit_access`: who opened which Streamlit app, and when. It reads Snowflake's Streamlit query tag (JSON or the older text form) and keeps only the app name.
  - Access log: a fourth section, Streamlit apps (who opened each app, days used, what it read); a By schema / database roll-up with kind filters; and "What it did" for a procedure.
  - Open: whether `user_name` on a Streamlit query is the viewer or the app owner is not in Snowflake's docs; confirm on a live account.
- **Fake data and Guide (13 Nov 2026):** the fake account adds a person's unload of a sensitive table and GET from the same stage, a GET from a user stage, a service user with no TYPE working at night, and a person's weekend DDL (`access_extras` in tests/fake_snowflake/new_checks_data.py). The Guide's Activity, PII and Audit pages describe the new screens.
- **Policies in use (13 Nov 2026):** one new check, `sf_gov_policy_hits`: one 90-day ACCESS_HISTORY scan, keeping only queries a policy was enforced on. `app/api/policies.py` joins it locally with the policy bodies' exempt roles, the grant links and the access log. The UI is in `web/src/components/area_policies.tsx`.
  - **PII › Masking & row policies:** who read masked columns in clear (their role is exempt in the body), who can bypass each policy and each protected table, and policy use by role.
  - **Audit › Changes:** who created, altered or dropped a policy, and when. Attaching a policy to a table shows as that table's ALTER.
  - Limits: secondary roles are not in ACCESS_HISTORY, and a policy that decides by a lookup table reads unknown.
  - Checked on the fake account and in tests/test_policies.py; not yet run live.
- **Full suite (13 Nov 2026, last run at 944b146):** 509 passed, 0 failed; `test_ctrl_c_keeps_what_ran_and_writes_the_report` deselected (it stops pytest on Windows, before this work too). An earlier run that day had 496 passed, 7 failed:
  - Fixed: the kit refresh, Guide summary rules for two new checks, and two stale expectations (`unpriced_rows` in the money payload; 7 not-assessed warehouses in the fake data).
  - Fixed after: the tag-filter test found a real bug. With a tag filter on, "N of M" divided by every object in the account; it now counts only the objects in that tag (`_dim_scope_count`). And Activity › Access log and PII › Tags rendered only their checks list, because the sub-tabs were missing from `web/src/tabs/tab_area.tsx`; `web/src/test/subtabs.test.ts` now fails for any sub-tab without a page.
- **Review fixes (10 Nov 2026):** the whole-repo review findings are fixed. Not done: MFA from `CREDENTIALS` (the fallback has no stand-in; noted in the check's caveat). Changed behaviour: the Overview total reads "–" when any line with usage has no rate (e.g. archive storage); the `APPLY AUTHENTICATION|PASSWORD POLICY` grants are optional. **Pending:** the full test suite (stopped for low memory), and a Playwright check of the changed pages.
- **Fake data:** `tests/fake_snowflake/`.
  - Base account used by the tests: `data.py`, `gap_*.py`, `new_checks_data.py`, `batch3_data.py`. Avoid changing these: tests depend on them. `new_checks_data.py` gained a full-scan statement and a redundant grant so two checks have something to find;
  - Demo layers: `demo_*.py`.
  - Build the demo DB with `python tools/build_demo_db.py` (about 4 min, about 2.3 GB of memory, one at a time) into `data/demo/` (git-ignored). `--list` shows the other kinds of account, `--scenario <name>` builds one, `--scenario all` builds all nine and `data/demo/coverage_report.md`. `worst_case` is the account in trouble: CRITICAL and WARN results no other account reaches. Run the app on it with `AUDIT_DB=data/demo/db_audit_demo.duckdb python -m app.api`.
- **Docs and graph:** `docs/overview.html` (business) and `docs/technical.html` (engineers), built from the knowledge graph in `snowflake-audit-app-knowledge-graph/` (start at its `index.md`; built at commit 556a877). Both are kept in step with the code (CLAUDE.md, How we work).
- **History:** squashed to one commit on 15 Oct 2026.

## Working preferences
- POC: commit and push to `main` after every finished change, don't over-engineer, and don't keep compatibility with older versions.
- Push back when a request is costly, breaks a rule or doesn't make sense, and offer the better option.
- Pages: less text; a headline figure or %, a chart that shows the cause, and a drill-down.
- Tests and the browser review only at the end. Between batches, run the compile checks only.
- When delegating: Sonnet builds, Opus designs and reviews. No workflows or builder agents unless asked.
