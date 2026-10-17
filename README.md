# Crosshire

A read-only audit of a Snowflake account. It shows where the credits and dollars go, what looks
wasted, and how warehouses, queries, tasks, loading, storage, AI and access are set up.

It runs 279 SQL checks on `SNOWFLAKE.ACCOUNT_USAGE` (and `ORGANIZATION_USAGE`, where you can read
it) through one small warehouse. The results are saved in a local DuckDB file, and a web app on
your own machine shows them. Nothing is ever written to Snowflake: the checks are `SELECT`, `WITH`
and `SHOW` only. Only the export (and Refresh in the app) queries Snowflake; browsing the app does
not.

The checks have run on one small live trial account, and every check on the demo account, with
its figures recomputed from the source views. Each still says "needs confirmation" in its
confidence note until it has run on a busy account. The test queries ("Check the numbers
yourself") let you check the figures on your own account.

**Contents:** [What you need](#what-you-need) · [Make the key pair](#make-the-key-pair) ·
[Roles and privileges](#roles-and-privileges) · [Set up once](#set-up-once) · [Run](#run) ·
[Update to a new version](#update-to-a-new-version) · [What the app shows](#what-the-app-shows) ·
[What the numbers mean](#what-the-numbers-mean) · [What it checks](#what-it-checks) ·
[Settings](#settings) · [Export only, or load only](#export-only-or-load-only) ·
[Masking names](#masking-names) · [If something fails](#if-something-fails) ·
[Repository](#repository) · [Tests](#tests)

**In short:** make a key pair, run the grant script once as `ACCOUNTADMIN`, fill in `.env`, then
`python tools/first_run.py` and `python -m app.api`, and open `http://127.0.0.1:8000/`. Start on
Overview, then Fix these first; How it works (left rail) explains any number.

## What you need

- **Python 3.11 or newer** (tested on 3.12). pandas 3 does not install on 3.10.
- **A Snowflake account** and a role that can read `SNOWFLAKE.ACCOUNT_USAGE` (see below).
- **A small warehouse** for the role. The export runs 4 checks at once, each on its own session
  (`--workers N` on `tools/export_results.py`; `--workers 1` runs them one by one).
- **A user with key-pair authentication** (`SNOWFLAKE_PRIVATE_KEY_FILE`); see "Make the key pair".

At the start the export probes every view and SHOW command the checks use. A check whose source the
role cannot read is not run and reads "the role can't see it" in the app, never as clean. A check
that needs a higher edition than yours reads "needs a higher Snowflake edition" (no grant changes
that). A check that fails on its own leaves the rest running. The probe also compares the warehouses
that billed with the ones `SHOW WAREHOUSES` lists, and `report.md` and the Coverage page say how many
the role cannot see.

Node is not needed: the built UI is in the repo (`app/web/dist`). Its source is in `web/`.

## Make the key pair

The export signs in with a key pair, so no password is stored. In a terminal (macOS and Linux have
`openssl`; on Windows use Git Bash, WSL, or the OpenSSL that ships with Git for Windows):

```
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
```

To protect the private key with a passphrase, drop `-nocrypt` and use `-v2 des3` instead:

```
openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 des3 -inform PEM -out rsa_key.p8
```

Then set `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` in `.env`.

- `rsa_key.p8` is the private key. Keep it outside the repo, and set `SNOWFLAKE_PRIVATE_KEY_FILE` to
  its full path. Never share it.
- `rsa_key.pub` is the public key. Open it and copy the text between the `-----BEGIN PUBLIC KEY-----`
  and `-----END PUBLIC KEY-----` lines, without those two lines and without line breaks. Paste it
  into the `CREATE USER` statement below (or run `ALTER USER AUDIT_USER SET RSA_PUBLIC_KEY='...'`).

## Roles and privileges

The export signs in with one role, and that role decides what you see. Everything below is
read-only: nothing lets the role change data, warehouses or settings.

### The grant script

Run this once as `ACCOUNTADMIN` (or a role that can create roles and grant on the account). The
export kit ships the same script as `grants.sql`.

```sql
CREATE ROLE IF NOT EXISTS AUDIT_ROLE;

-- The ACCOUNT_USAGE views: all of them.
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE AUDIT_ROLE;
-- Or, when IMPORTED PRIVILEGES is hard to get approved, these four read-only database roles instead.
-- They open about 225 of the checks; the rest read "the role can't see it" (the task checks need
-- TASK_VERSIONS, which none of the four opens).
--   GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER      TO ROLE AUDIT_ROLE;  -- cost and usage
--   GRANT DATABASE ROLE SNOWFLAKE.OBJECT_VIEWER     TO ROLE AUDIT_ROLE;  -- tables and objects
--   GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE AUDIT_ROLE;  -- query and access history, policies, tags
--   GRANT DATABASE ROLE SNOWFLAKE.SECURITY_VIEWER   TO ROLE AUDIT_ROLE;  -- logins, users, roles, grants

-- Account-level usage and billing history in the metering views.
GRANT MONITOR USAGE ON ACCOUNT TO ROLE AUDIT_ROLE;

-- Tasks and pipes: SHOW TASKS and the pipe checks list only what the role may monitor.
GRANT MONITOR EXECUTION ON ACCOUNT TO ROLE AUDIT_ROLE;

-- A small warehouse to run the export on.
CREATE WAREHOUSE IF NOT EXISTS AUDIT_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
GRANT USAGE ON WAREHOUSE AUDIT_WH TO ROLE AUDIT_ROLE;

-- SHOW WAREHOUSES lists only the warehouses the role has a privilege on. Grant MONITOR on each one
-- (repeat for every warehouse, and again whenever a new one is created).
GRANT MONITOR ON WAREHOUSE MY_WAREHOUSE TO ROLE AUDIT_ROLE;

-- Same for resource monitors (SHOW RESOURCE MONITORS).
GRANT MONITOR ON RESOURCE MONITOR MY_MONITOR TO ROLE AUDIT_ROLE;

-- Trust Center findings (the Trust Center check reads SNOWFLAKE.TRUST_CENTER.FINDINGS).
GRANT APPLICATION ROLE SNOWFLAKE.TRUST_CENTER_VIEWER TO ROLE AUDIT_ROLE;

-- Budgets (SHOW SNOWFLAKE.CORE.BUDGET INSTANCES and the budget spend).
GRANT APPLICATION ROLE SNOWFLAKE.BUDGET_VIEWER TO ROLE AUDIT_ROLE;

-- Data quality expectation results (SNOWFLAKE.LOCAL); IMPORTED PRIVILEGES does not open them.
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE AUDIT_ROLE;

-- Authentication and password policies. POLICY_REFERENCES does not list them, so the checks use
-- SHOW AUTHENTICATION POLICIES and SHOW PASSWORD POLICIES, which need a privilege on the account.
GRANT APPLY AUTHENTICATION POLICY ON ACCOUNT TO ROLE AUDIT_ROLE;
GRANT APPLY PASSWORD POLICY ON ACCOUNT TO ROLE AUDIT_ROLE;

-- Optional: the organization billing views (invoice, rates, contract balance).
-- In an ORGADMIN-enabled account they are database roles of the SNOWFLAKE database:
GRANT DATABASE ROLE SNOWFLAKE.ORGANIZATION_BILLING_VIEWER TO ROLE AUDIT_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.ORGANIZATION_USAGE_VIEWER TO ROLE AUDIT_ROLE;
-- In the organization account they are application roles instead (run as GLOBALORGADMIN):
--   GRANT APPLICATION ROLE SNOWFLAKE.ORGANIZATION_BILLING_VIEWER TO ROLE AUDIT_ROLE;

-- The user the export signs in as, with its public key.
CREATE USER IF NOT EXISTS AUDIT_USER DEFAULT_ROLE = AUDIT_ROLE DEFAULT_WAREHOUSE = AUDIT_WH
  TYPE = SERVICE RSA_PUBLIC_KEY = '<public key, without the BEGIN/END lines>';
GRANT ROLE AUDIT_ROLE TO USER AUDIT_USER;
```

### What each grant opens, and what you won't see without it

A check reads one or more sources. If the role cannot read any one of them, the check is skipped.
In the app it reads "–, the role can't see it", with the view or SHOW command it needed. It never
shows $0 or "nothing found". Counts were made at 274 checks, so a few newer checks are not in them; a check can need more than one grant.

| Grant | What it opens | Without it you won't see |
|---|---|---|
| `USAGE` on a warehouse | Runs the export | Nothing: no statement can run. |
| `IMPORTED PRIVILEGES` on the `SNOWFLAKE` database | Every `ACCOUNT_USAGE` view, plus the reader-account and listing views | Almost everything. Only 24 checks read nothing from the `SNOWFLAKE` database (they use SHOW, the organization views or the Trust Center). |
| **Or** the four database roles below, instead of `IMPORTED PRIVILEGES` | 248 of the 274 checks | The 25 checks in the "None of the four" row, and the data quality expectations check. |
| `SNOWFLAKE.USAGE_VIEWER` | 135 checks: credits and metering, spend by service, warehouse metering and load, storage, serverless features, AI and Cortex spend, task and pipe runs, data transfer | Overview spend, most of Cost, Warehouses, Serverless features, Storage, AI & apps, and the run history in Tasks & pipelines and Data loading. |
| `SNOWFLAKE.GOVERNANCE_VIEWER` | 107 checks: query history, access history, masking and row policies, tags, classification, query insights | Queries, Audit, PII & policies, Lineage & usage, Tags, and the "who spent it" cuts. Query attribution opens with this role or `USAGE_VIEWER`. |
| `SNOWFLAKE.SECURITY_VIEWER` | 62 checks: users, roles, grants, sign-ins, sessions, network policies and rules, secrets, shares | Access (roles, grants, users, MFA, stale users), admin sign-ins in Audit, the network perimeter. Policy references open with this role or `GOVERNANCE_VIEWER`. |
| `SNOWFLAKE.OBJECT_VIEWER` | 50 checks: tables, schemas, views, stages, pipes, tasks, object dependencies | Storage by table, unused objects, dependencies in Lineage, object inventories. |
| None of the four: needs `IMPORTED PRIVILEGES` | 25 checks | Nine task checks (task cost, failures, runs per day, failed vs all runs, duration change, skipped overlaps, late starts, no-op runs, warehouse vs serverless, all through `TASK_VERSIONS`). Also alert history, query acceleration, lock waits, compute pools, backups, stale stage files, database replication, Cortex Code Desktop, data movement violations, reader accounts, listings and Marketplace. |
| `MONITOR USAGE` on the account | Account-level usage and history for databases and warehouses | No check is skipped for this alone; the checks read `ACCOUNT_USAGE` through the grants above. |
| `MONITOR EXECUTION` on the account | `SHOW TASKS` and pipes, account-wide | `SHOW TASKS` lists only tasks the role owns, so the suspended, orphaned and stream-consumer checks (4) see fewer tasks; `SHOW PIPES` lists only pipes the role can monitor (1 check: broken or unalerted pipes). |
| `MONITOR` on each warehouse | `SHOW WAREHOUSES` (22 checks: auto-suspend, size, scaling, warehouse settings) | Warehouses you did not grant are missing from the settings checks; their spend still shows from metering. `report.md` says how many billed warehouses `SHOW WAREHOUSES` left out. |
| `MONITOR` on each resource monitor | `SHOW RESOURCE MONITORS` | Monitors you did not grant are missing from resource monitor coverage and projection (2 checks). |
| `APPLY AUTHENTICATION POLICY`, `APPLY PASSWORD POLICY` | `SHOW AUTHENTICATION POLICIES`, `SHOW PASSWORD POLICIES` | The authentication and password policy checks (2) see only policies the role owns. `POLICY_REFERENCES` does not list these policies, so there is no other way. |
| Application role `SNOWFLAKE.BUDGET_VIEWER` | Budgets | The budgets check (1) lists no budgets, or only the role's own. |
| Application role `SNOWFLAKE.TRUST_CENTER_VIEWER` | Trust Center findings | The Trust Center check (1). |
| Application role `SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER` | `SNOWFLAKE.LOCAL` data quality expectation results | The expectations failing check (1); `IMPORTED PRIVILEGES` does not open it. |
| `SNOWFLAKE.ORGANIZATION_BILLING_VIEWER` | The invoice, rate sheet, contract and balance (17 checks) | Dollars at your real rate (pass `--credit-price` instead), the contract and balance checks, overage. |
| `SNOWFLAKE.ORGANIZATION_USAGE_VIEWER` | Spend, storage and sign-ins across all accounts (14 checks) | Sharing & org: spend and storage per account, org-wide users and sign-ins. |
| Ownership or `USAGE` on integrations, shares, stages, Streamlit apps, notebooks, external and Iceberg tables | The SHOW commands that list them | Those checks still run, but list only what the role owns or can use. |

**How a missing grant shows up**

- **The role can't read a source:** the check is skipped. It reads "–, the role can't see it", and
  `report.md` lists every view and SHOW command the role could not read.
- **SHOW lists only part:** the check runs, but on fewer rows. This applies to SHOW WAREHOUSES and
  the other SHOW-based checks.
- **The edition is too low:** the tag, masking, access-history and data-metric checks need
  Enterprise Edition or higher. On Standard they read "needs a higher Snowflake edition"; no grant
  changes that.

**Notes**

- **The database roles are granted once.** They are roles of the built-in `SNOWFLAKE` database and
  cover every database in the account. You don't grant them per database.
- **No bulk grant exists for warehouses or resource monitors.** Snowflake has no
  `GRANT MONITOR ON ALL WAREHOUSES` and no future grant for them. `MANAGE WAREHOUSES` would cover
  every warehouse, but it also allows `MODIFY` and `OPERATE`, which this read-only audit must not
  have. Grant `MONITOR` warehouse by warehouse.
- **Tasks:** `MONITOR EXECUTION` covers tasks and pipes account-wide. To grant per schema instead,
  use `GRANT MONITOR ON FUTURE TASKS IN SCHEMA ...`.
- **Organization views:** they are readable from the organization account, or from an account the
  organization admin has enabled them for.
- `--validate` (below) prints the one GRANT that opens each source your role cannot read. Run
  `SHOW GRANTS TO ROLE AUDIT_ROLE` to confirm, and check
  <https://docs.snowflake.com/en/sql-reference/sql/grant-privilege> for the current syntax.

## Set up once

1. **Get the code.** Either download the ZIP from GitHub (the green **Code** button, then
   **Download ZIP**) and unzip it, or `git clone` the repository. Open a terminal in the unzipped
   folder (the one that holds `README.md`).
2. **Create a virtual environment and install the packages.**

   Use Python 3.11 or 3.12. If you have several versions, the Windows `py` launcher picks one:
   `py -0` lists them, and `py -3.12 -m venv .venv` makes the environment with 3.12. Once it is
   active, `python` means that version.

   Windows (PowerShell):

   ```
   py -3.12 -m venv .venv             # or: python -m venv .venv, if python is already 3.11 or 3.12
   .venv\Scripts\Activate.ps1        # in cmd.exe: .venv\Scripts\activate.bat
   python -m pip install -r requirements.txt
   copy .env.example .env
   ```

   macOS and Linux:

   ```
   python3.12 -m venv .venv
   source .venv/bin/activate
   python -m pip install -r requirements.txt
   cp .env.example .env
   ```

   If PowerShell refuses to run the activate script, run
   `Set-ExecutionPolicy -Scope Process RemoteSigned` first, or use cmd.exe.
3. **Fill in `.env`** (open it in any text editor):

   - `SNOWFLAKE_ACCOUNT`: `<orgname>-<account_name>`, or the locator with its region
   - `SNOWFLAKE_USER`
   - `SNOWFLAKE_PRIVATE_KEY_FILE`: the full path of `rsa_key.p8`
   - `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE`: only if the key is encrypted
   - `SNOWFLAKE_ROLE`
   - `SNOWFLAKE_WAREHOUSE`

   `.env` is git-ignored. Environment variables with the same names work too.

## Run

With the virtual environment active:

```
python tools/first_run.py         # last 30 days; add --windows 90 for 90
python -m app.api
```

Then open `http://127.0.0.1:8000/`. Stop the app with Ctrl+C.

Stop the app before you run `first_run.py` again: on Windows the load cannot replace
`audit.duckdb` while the app has it open. Refresh in the app does not have this problem.

`first_run.py` does two steps, and stops at the first one that fails, naming it:

1. **Export:** runs every check and writes the results to files. This takes minutes.
2. **Load:** builds the local `audit.duckdb` that the app reads.

**Refresh** in the top bar runs both steps from the app, for newer data later:

- Pick 7, 15, 30, 60 or 90 days. It runs every check on your warehouse, so it uses warehouse time
  and takes minutes.
- It writes a new database and switches the app to it. If it fails, the error shows in the same
  panel and the old data stays.
- It keeps the newest two results folders and deletes older ones, including those from
  `first_run.py`.
- It keeps a credit, AI or storage price you typed in for the last export, and reads an invoice or
  rate-sheet price again.

`--windows N` sets the days of history to pull (default 30). The app shows 7, 30 and 90 days, so
anything over 90 pulls the same as 90, and a window longer than N shows only N days. Fewer days run
faster on the big history views.

The export prints one line per check (`[12/279] check_id: ok, 34 rows, 1.2s`), so a long run never
looks hung. Every statement has a time limit (15 minutes; `--statement-timeout SECONDS` on
`tools/export_results.py` changes it): a statement that hits it is recorded as timed out and the
export goes on.

Before the first real run, check that every statement compiles on your account and see which sources
the role cannot read (nothing is exported and no rows are read):

```
python tools/export_results.py --out <folder outside the repo> --windows 7 --validate
```

`validate.md` in that folder groups the checks by cause: real SQL errors first (a fault in a
statement: report these), then the checks the role or account cannot read, with the one GRANT for
each group and the checks it opens. Sources the role cannot read are normal and do not fail the
run: the command exits 1 only when a statement itself has an error.

**Export options.** `first_run.py` takes `--windows` and the three prices. For the rest, run the two
steps by hand: `python tools/export_results.py --out <folder> [options]`, then
`python tools/load_results.py <folder>`.

| Option | What it does |
|---|---|
| `--out DIR` | Output folder, outside the repo. |
| `--windows DAYS` | Days to export (30). |
| `--credit-price`, `--ai-credit-price`, `--storage-price` | Prices in USD (see "Prices"). |
| `--max-rows N` | Rows kept per check, worst first (50,000). |
| `--statement-timeout SECONDS` | Time limit per statement (900). |
| `--workers N` | Checks run at once, each on its own session (4). |
| `--only ID ...` | Only these checks. |
| `--mask KINDS`, `--mask-salt TEXT` | Replace names with tokens (see "Masking names"). |
| `--use-fallbacks` | Run the INFORMATION_SCHEMA versions even when ACCOUNT_USAGE is readable. |
| `--validate` | Compile every statement and probe every source; export nothing. |

`load_results.py` with no folder loads the newest export in the data folder. `--db PATH` writes the
database somewhere else.

### Prices

Dollars need a price per credit. AI usage (Cortex AI, Copilot) is billed in AI credits, which have
their own price. For each price the export takes the first of:

1. `--credit-price`, `--ai-credit-price` and `--storage-price` (USD per TB-month) on
   `tools/first_run.py` or `tools/export_results.py`;
2. your contract rate in `ORGANIZATION_USAGE.RATE_SHEET_DAILY` (credits and AI credits);
3. your effective rate over the last 90 days of `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`
   (consumption only: rebates, support fees, overage and adjustments are left out of the rate);
4. `credit_price_usd`, `ai_credit_price_usd` and `storage_price_usd_tb_month` in
   `config/settings.yml`: defaults of 3.00 (Enterprise list price) and 2.00 per AI credit, used
   when the role cannot read the organization billing views or they have no rows yet.

```
python tools/first_run.py --credit-price 3.0 --storage-price 23
```

A price read from your invoice or rate sheet already includes your discounts, so the `discount_pct`
what-if is not applied on top of it. The app shows where each price came from next to the dollars.

### When the role cannot read ACCOUNT_USAGE

85 checks have a second version in `app/queries/fallback/` that reads the same thing from
`INFORMATION_SCHEMA` and `SHOW`. The export runs it when the role cannot read the check's
`ACCOUNT_USAGE` views, and the page says so under the sub-tabs. Most are the check's own SQL with each
view swapped for a stand-in in `app/queries/shims/`: the view rebuilt from table functions,
`INFORMATION_SCHEMA` views or `SHOW` output, with the same columns (NULL where the source has none).
Covered: spend, cloud services, data transfer, serverless features, warehouses (setup, load, state),
queries, sign-ins, tasks, dynamic tables, pipes and bulk loads, storage, replication, objects
(databases, schemas, tables, views, functions, procedures, stages), users, roles, grants, policies,
secrets, shares and services. `--use-fallbacks` runs them even when `ACCOUNT_USAGE` is readable, to
test them.

What the role needs. Without it the check reads "the role can't see it", never "nothing found":
- **MONITOR USAGE:** spend, storage, data transfer and serverless credits. The table functions
  return nothing without it.
- **MANAGE GRANTS** (SECURITYADMIN has it): users, roles, grants, tasks, tags, secrets, policies,
  shares, services and resource monitors. Without it, `SHOW` lists only what the role holds a
  privilege on, which would look complete.
- **APPLY MASKING / ROW ACCESS / PROJECTION / AGGREGATION POLICY:** which columns and tables the
  policies are set on.
- Nothing extra for queries, sign-ins, task runs, warehouse load and the per-database object lists;
  they show what the role can see.

What they leave out:
- **Spend:** warehouses and serverless features only. AI, containers and other services have no
  table function, and adaptive warehouses are left out of the warehouse function. Pipe, transfer and
  database replication history covers 14 days; the rest 6 months. The cloud-services adjustment is
  worked out with the daily 10% rule.
- **Queries, sign-ins, task runs, dynamic table refreshes:** 7 days. No spill, partition, cache or
  per-query credit figures, so idle-time checks read "not assessed".
- **Loads:** bulk COPY for 14 days only; no Snowpipe loads or file sizes.
- **Objects:** live ones only, in the role's own databases. One call per database; a database that
  fails is left out and the note says how many.
- **Grants:** current grants to account and database roles, one `SHOW` per role; no revoked,
  inherited or future grants.
- **Ids:** there are no ids, so the name stands in.
- **Not covered:** 22 checks whose answer depends on a column the sources lack (spill, pruning,
  password age, IP lists, policy settings and bodies, revoked grants, Snowpipe loads) and the checks
  that need views with no equivalent (access history, query attribution, tag references, table
  storage metrics, warehouse events, AI usage, organization views).

Each stand-in runs once per export, before the checks. Small results (up to 5,000 rows) are passed
to the checks as literal rows, since Snowflake aborts with an internal error (300010) when one
statement reads table-function rows twice.

The query checks share one read of the query history. Before the checks, the export runs 28
six-hour slices at once (the table function returns at most 10,000 queries a call), each its own
statement under the 15-minute limit, and prints how many finished. The checks then read them with
`RESULT_SCAN`, so each takes seconds. A slice that fails or times out leaves only its six hours out,
and the page says how many hours are missing.

Table functions that need `MONITOR USAGE` (storage, and the metering ones) return no rows without
it rather than an error. The export tests for the grant once; without it those checks read "the
role can't see it", never "nothing found". The manifest records the result as `monitor_usage`.

**Today is included, but partial.** The export takes in today up to the moment it runs, and the top
bar then shows "today partial". `ACCOUNT_USAGE` views lag by minutes to hours (the organization
billing views by up to 72 hours), so the last hours before a run can be missing. With
`include_today: false` the windows end at the last complete day: now minus 8 hours (the lag of the
query attribution view), so the day before yesterday when you run just after midnight UTC. The
manifest records the export date, that last complete day and the lag.

### Where the files go

| System | Folder |
|---|---|
| Windows | `%LOCALAPPDATA%\snowflake-audit` |
| macOS | `~/Library/Application Support/snowflake-audit` |
| Linux | `~/.local/share/snowflake-audit` |

To use another folder, set `AUDIT_DATA_DIR`.

- Each export goes to `results/<UTC time>/` (for example `results/20260929T101500Z`; the first run
  and Refresh name it the same way), with a `report.md` inside: a line with the price, edition
  and time limit, then one line per check with its status, rows, duration and error, failed and
  not-assessed checks first.
- The app opens the database the last load or Refresh made. At first, that is `audit.duckdb` in the
  data folder.

These files hold your account's data. Keep them out of the repo and do not share them.

## Update to a new version

1. Download the new zip, or `git pull`.
2. Keep your own files. `.env` and `config/settings.local.yml` are not in the zip, so copy them into
   the new folder if you unpack it somewhere new. `config/tag_aliases.yml`, `config/thresholds.yml`
   and `config/materiality.yml` are in the zip and get replaced; keep a copy if you changed them.
3. Run `python -m pip install -r requirements.txt` again.
4. Run `python tools/first_run.py`. New or changed checks show only after a new export.

The data folder is outside the repo, so an update never touches it. The UI comes built in the zip;
Node is only needed to change it.

## What the app shows

**Pages**

| Page | What it answers |
|---|---|
| Overview | Spend, change against the period before, possible waste and the top findings, charts first. |
| Actions | What to fix first: priced savings in the window, storage savings per month, and CRITICAL findings with no dollar figure (an admin without MFA), as three separate lists. |
| Cost | Trend, by service, who spent it, chargeback and tags, contract and rate, budgets and guardrails. |
| Tags | Required-tag compliance per object type, and the spend no tag reaches. |
| Waste & savings | Priced waste, flagged findings with no price yet, and how each figure is counted. |
| Warehouses | Idle time and settings, sizing, load and scaling. |
| Serverless features | By feature, clustering, materialized views and search optimization. |
| Queries | Heavy, efficiency, failures, waiting, by source and team. |
| Tasks & pipelines | Failures, cost and timing, hygiene, dynamic tables and streams. |
| Data loading | Snowpipe and streaming; COPY, external and Iceberg. |
| AI & apps | Cortex (functions, Search, Analyst, agents, Code, CoWork), containers, apps and notebooks, model serving. |
| Access | Roles and grants, users and sign-ins, the account perimeter (network policies, private link, failover). |
| Audit | Admin sessions and sign-ins, changes to objects and grants. |
| PII & policies | Sensitive data, masking and row policies, who reads it and where it goes, data quality coverage. |
| Lineage & usage | Dependencies and lineage, what is used and what is not. |
| Sharing & org | Shares and listings, accounts, spend across accounts, replication and transfer. |
| Storage | Growth and stages, unused and sprawl, Time Travel and Fail-safe, backups. |
| All findings | Every check in one table, with its status and dollars. |
| Coverage & Gaps | Which checks ran, what the role could read, the edition, how fresh each source is, known limits. |
| How it works | One page per check and topic (below). |

**On every page**

- **Dollars** are credits times your effective price per credit. The export reads the price from the
  organization billing view when your role can see it (see "Prices" below); otherwise pass
  `--credit-price`. Spend, change and possible waste are shown apart and never added together.
- **Filters:** last 7, 30 or 90 days; account; environment; warehouse; database and schema; owner;
  tag. A check that has no warehouse (or database) column says "not filtered by warehouse".
- **Links:** the address bar holds the page, sub-tab, open check, role and filters (for example
  `#tab=cost&subtab=chargeback&role=cfo&w=30`), so a bookmark or a pasted link opens the same view.
  A check's details have a Copy link button.
- **A check that did not run** shows "–" and why (the role can't see it, needs a higher edition,
  not in this export, failed), never $0. Rows under a check's money floor read "Under $X", not OK.
- **Downloads:** every check as CSV (all rows, filters applied); any page as PDF; a printable
  one-page summary from the Overview.
- **Task panel:** click any task name to open its runs, failures, cost and what changed.
- **Snowsight links:** the ↗ next to a warehouse, database, table, task, user, role or query opens it
  in Snowsight. The paths are a best guess and may change.
- **View as** (the lens in the left rail) picks which pages show. It is not a permission: the data
  is the same in every lens.

| Lens | Pages |
|---|---|
| FinOps (default) | Overview, Fix these first; Cost, Tags, Budgets, Contract; Waste & savings, Warehouses, Serverless features, AI & apps, Storage, Sharing & org |
| Data engineer | Overview, Fix these first; Tasks & pipelines, Data loading; Queries, Warehouses, Serverless features; Cost, Waste & savings, Storage |
| Governance | Overview, Fix these first; Roles & grants, Users & sign-ins, Account perimeter; PII & policies, Lineage & usage, Sharing & org, Storage; Audit |
| CTO | Every page, grouped as Cost, Reliability, Performance and Security |
| CFO | Money, What to do; Cost, Chargeback & tags, Contract & rate, Budgets & guardrails, Waste & savings |

Every lens also has Coverage & gaps, All findings and How it works.

**How it works** has one page per check (what it checks, how it is computed, the views
it reads, the grant it needs, its traps, links to docs.snowflake.com and the check's own SQL to
copy into a worksheet), test queries per section to check the app's numbers by hand, concept pages
(the cloud services 10% adjustment, query attribution, latency and retention, Time Travel and
Fail-safe, pricing basis, the kinds of dollars, editions and role visibility) and a walkthrough of
every page. Its left nav folds open and shut by group; the group holding the open page starts open.

Every page links into it:

- a **?** beside each check's name (in check lists, tables, chart cards, Waste, Coverage and
  Actions) opens that check's own page; clicking the row still opens its details;
- **Read:** under each page's lede links the concept pages that page leans on;
- the page footer opens that tab's own How it works page.

## What the numbers mean

**Dollars** are credits times your effective price per credit (see [Prices](#prices)). Cloud
services are priced after Snowflake's daily 10% adjustment, and storage at your price per TB per
month. It is not your invoice line by line: Cost › Contract & rate compares the two where the role
can read the organization billing views.

**Statuses** drive every count, colour and total:

| Status | Meaning |
|---|---|
| Critical | The worst kind of problem this check looks for. |
| Warn | Flagged, but not the worst kind. |
| OK | Ran on real data in this window and found nothing. A verified pass. |
| Ranked | Sorted by size only. Big is not the same as wrong. |
| Not assessed | Did not run: the role can't see a view, the edition is too low, or it failed. Never a pass; it reads "–" with the reason. |
| No data | Ran, but nothing happened in this window. Not a verified zero. |
| No data (filtered) | Rows exist, but your filters exclude them all. |
| Reference | A list to look things up in, with no pass or fail. |

**Possible waste** (Waste & savings) is credits billed for nothing, priced: warehouses running with
no query, failed statements, task runs that changed nothing, dynamic tables nobody reads, query
retries, warehouses left at a bigger size, and provisioned AI throughput that was not used. Each
check adds its money column over the rows it flagged Critical or Warn, and idle time is counted
once, in the warehouse idle check. **Savings** (a resize, a shorter auto-suspend) and **storage per
month** are separate figures. Spend, change, waste and savings are shown side by side and never
added; none is a forecast.

**Query attribution is not a total.** Per-query, per-user and per-team dollars come from
`QUERY_ATTRIBUTION_HISTORY`, which leaves out idle time and queries under about 100 ms, is empty on
adaptive warehouses, and lags up to 8 hours. They add up to less than the warehouse bill; the
chargeback pages show the rest as its own row.

**Materiality floors** in `config/materiality.yml` set a size per check below which a Critical or
Warn row reads "Under $X" instead. Such rows are left out of counts and dollar totals. A dollar
floor is per 30 days and scales with the window. Floors apply when the app reads the data, so a
change needs only a page refresh.

**Thresholds** in `config/thresholds.yml` change a check's own limits, such as the idle gap or the
auto-suspend seconds. The export reads them, so after editing the file, export again.

**Windows.** A window longer than the export reads "partial" in the top bar, never as complete.
Snapshot checks (settings, grants, policies) show the current state and do not follow the window.

**Row cap.** Each check keeps at most 50,000 rows, worst first (`--max-rows`). A capped check's
totals can be low; Coverage & Gaps lists it.

**Visibility.** `SHOW` commands and several views list only what the role can see. Coverage & Gaps
says how many billed warehouses `SHOW WAREHOUSES` left out, and which sources the role could not
read.

## What it checks

279 checks, each a SQL file in `app/queries/checks` with a header the app and How it works read:

| Area | Checks |
|---|---|
| Cost, billing, contract and org | 62 |
| Access, security, PII, audit and lineage | 82 |
| Queries and performance | 31 |
| Tasks, pipelines and loading | 35 |
| Storage | 28 |
| AI, containers and apps | 19 |
| Warehouses | 22 |

They read about 170 `ACCOUNT_USAGE`, `ORGANIZATION_USAGE`, `DATA_SHARING_USAGE` and Trust Center
views and `SHOW` commands. Some things no usage view holds, so no check can show them: budget spend
history (it needs a `CALL`), user-level authentication, password and session policy attachments,
idle time and credits of queries under about 100 ms, and per-stage bytes on GCP.

## Settings

These live in `config/settings.yml`:

| Setting | What it does |
|---|---|
| `default_window` | Days exported when `--windows` is not given (30). |
| `include_today` | Export today up to the run time, marked partial (`true`). `false` = complete days only. |
| `credit_price_usd`, `ai_credit_price_usd`, `storage_price_usd_tb_month` | The export's prices when the organization billing views are not readable or empty and no flag is given (3.0, 2.0, empty). |
| `cost_center_tag_keys` | Which tag names count as "Cost center" (default `[cost_center]`, up to 5). |
| `required_tag_keys` | Tag names every object should carry (empty). With none, the tag page shows coverage by object type. |
| `discount_pct` | Your discount off the credit price, as a fraction (0.15 = 15%). Not applied to a price read from your invoice. |
| `privacy.mask_user_identities` | Masks user names and emails on screen. Off by default. |
| `privacy.mask_fields` | Kinds of names the export and Refresh replace with tokens, e.g. `[warehouse, role]` (empty). See "Masking names". |
| `query_source` | The `QUERY_TAG` on the app's own queries (`crosshire-audit`). |
| `env_patterns` | Word lists that classify an account name as prod, uat or dev. |
| `export_tag_keys` | Keep only these tag names in the export. The cost center, required and `tag_aliases.yml` tags are always kept. |
| `brand` | Name shown in the header and footer. |
| `load.memory_limit`, `load.threads` | DuckDB memory (`1GB`, or e.g. `1500MB`) and threads (4, 1-64) for the load and the app. Above the memory cap the load spills to a `.tmp` folder next to the database file. Lower both on a busy laptop. |
| `load.response_cache_mb` | Memory the app keeps for pages already read (64; 0 turns it off). |

**Your own overrides** go in `config/settings.local.yml`, which is git-ignored. The app's Settings
panel writes there too.

- It overrides only the top-level keys it contains; everything else still comes from
  `settings.yml`.
- A nested block (`brand`, `privacy`, `ui`) is replaced as a whole, so repeat all of its lines.

## Export only, or load only

`tools/first_run.py` does both steps on one machine. They can also run apart: the export on a
machine that can reach Snowflake, the load and the app on another that cannot.

**Export only** (needs Snowflake access; writes parquet files, nothing else):

```
python tools/export_results.py --out <folder outside the repo>      # --windows 90 for 90 days
```

Without the repo, use the export kit below. Either way, zip the folder to move it.

**Load only** (needs no Snowflake access): load a results folder, or its `.zip`, into the app's
database, then start the app:

```
python tools/load_results.py <results folder or .zip>
python -m app.api
```

The app opens the database the last load made. To keep several, pass `--db <file>` to the load
and start the app with `AUDIT_DB=<file>`.

### Export kit: someone else runs the SQL

When someone else runs the export, send them `tools/export_kit/` instead of the repo. Zip the
folder and send it; its own `README.md` says how to install, sign in and run, and which roles and
privileges it needs. Inside:

- `run_export.py`: the export, on its own. It needs only `snowflake-connector-python` and
  `pyarrow`.
- `queries/`: every statement it runs, as plain `.sql`, with the shared parts pasted in.
  `index.json` holds each check's parameters.
- `grants.sql`: the grant script from "Roles and privileges" above.
- `verify/`: test queries, one file per app section, to paste into a worksheet and compare with
  what the app shows (see "Check the numbers yourself").
- `README.md`: how to run it, and "Roles and privileges".

They run `python run_export.py` (add `--credit-price 3.0` without invoice access) and send back
`sf-audit-out.zip`. You load it with `python tools/load_results.py sf-audit-out.zip`. The output is
the same as `tools/export_results.py`'s, so the app shows it the same way. `--mask` works the
same in both (see "Masking names"); `--validate` is in the full export only.

After changing any SQL in `app/queries` (or this README's "Roles and privileges"), refresh the
kit with `python tools/make_export_kit.py`. A test fails while the kit is out of date.
`python tools/make_export_kit.py --zip <folder outside the repo>` also writes `export_kit.zip`,
leaving out any `.env`, key file or results.

### Check the numbers yourself

Each app section has read-only test queries in `app/queries/verify/<section>.sql` (copied into the
kit's `verify/`). Each one recomputes a figure the app shows straight from `ACCOUNT_USAGE`. Set the
window, export date and price in its `p` CTE, run it in a worksheet, and compare. How it works' "Test
it yourself" section links each file.

## Masking names

Off by default. Two independent switches:

- **On screen:** `privacy.mask_user_identities` (Settings, "Mask user names and emails") shows user
  names and emails as `<8 hex> <first 2 characters>***` in the app, CSV and PDF. The data on disk
  is unchanged.
- **In the export:** `--mask` on `tools/export_results.py` and the export kit, or
  `privacy.mask_fields` (Settings, "Mask in the next Refresh") for Refresh, replaces chosen kinds of
  names with tokens before any file is written, so the results folder never holds the real names:

  ```
  python tools/export_results.py --out <folder> --mask warehouse,database,role
  python run_export.py --mask all            # in the export kit
  ```

  Kinds: `user`, `warehouse`, `database`, `schema`, `object` (tables, views, stages, pipes, streams,
  dynamic tables, functions, alerts, notebooks), `role`, `task`, `account`, or `all`.

How export masking works:

- A name becomes the same token in every check, lookup table, tag source and the manifest, for
  example `wh_3f2a9c1b`. Joins, `name (id)` labels, chargeback and per-name totals still add up.
- Full names (`DB.SCHEMA.TABLE`, a task's full name) are masked part by part. Free text (reasons,
  notes, error messages) gets the same tokens wherever a known name appears as a whole word.
- Tokens are salted at random on each export, so a common name such as `COMPUTE_WH` cannot be
  looked up from its token. `--mask-salt TEXT` keeps tokens the same across exports. The salt is
  never saved.
- System names stay: the `SNOWFLAKE` database and its views, `INFORMATION_SCHEMA`, `PUBLIC`, and
  the system roles (`ACCOUNTADMIN`, `SYSADMIN`, ...).
- There is no unmask key: a masked export stays masked. Settings says what the loaded data has
  masked. Snowsight links on masked names do not open the object. Settings that name objects
  (environment words for account names, cost-center tags on a warehouse) cannot match a token.

## API

The app's data comes from a local HTTP API under `/api`. Every route only reads, except the
Settings saves (`PUT /api/settings/...`) and `POST /api/refresh`, which starts an export.
`http://127.0.0.1:8000/docs` lists them all.

## If something fails

The export prints one line for a sign-in or setup failure: what Snowflake said, its error code, and
the fix.

| What you see | What to do |
|---|---|
| Step 1 exits 2 and names a missing credential | Fill in `.env`, or set the variables. |
| Step 1 exits 1 with `390144` or "JWT token is invalid" | The public key on the user does not match the private key file: `ALTER USER ... SET RSA_PUBLIC_KEY`. |
| Step 1 exits 1 with `390100` or "Incorrect username or password" | Check `SNOWFLAKE_USER`, the key pair and that the user is enabled. |
| Step 1 exits 1 and names the role or the warehouse | The role is not granted to the user, or has no `USAGE` on the warehouse. |
| `ImportError` or "DLL load failed" | Run `python -m pip install -r requirements.txt` with the same `python`. |
| The export ends with "N failed" | Open `results/<time>/report.md`. Usually a grant is missing or the view is not in your edition. The app shows those checks as not run, with the grant. |
| Step 2 fails | The export is kept. Fix the problem, then run `python tools/load_results.py` (it loads the newest export; pass a folder to pick another). |
| Step 2 fails on Windows with a permission error | The app has the database open. Stop it, then rerun the load. |
| An export or load refuses a folder (exit 2) | The folder is inside the repo. Pick one outside it. |
| The app shows "No database yet" | Run `python tools/first_run.py`. |
| The app shows "config/settings.yml needs a fix" | Fix the setting and line it names. |
| The page says "The UI is not built" | The zip ships it built; in a git checkout without it, run `cd web && npm ci && npm run build`. |
| Spend by tag says the export cut a tag source | The account has more tagged objects than `--max-rows` (50,000). Export again with a higher `--max-rows`. |
| The app shows old or unexpected data | The first line `python -m app.api` prints names the database it opened. Set `AUDIT_DB` to pick one. |
| The load says `Out of Memory Error` | In `config/settings.local.yml`, lower `load.threads` (e.g. 1) and rerun the load. No new export needed. |
| Port 8000 is busy | Set `AUDIT_API_PORT`, e.g. `$env:AUDIT_API_PORT=8010` in PowerShell. |

## Open items

- **A run on a busy live account.** So far the checks have run on the fake and demo accounts and
  on one small trial account with a few days of use, where many found nothing to judge. Run the
  test queries in `app/queries/verify/` next to the app on the first busy export and compare.
- **`sf_ai_model_serving_spend`** failed on the trial account with Snowflake error 100038.
- **Who can read the usage views** assumes database-role grants appear in `GRANTS_TO_ROLES` as
  `granted_on = 'DATABASE_ROLE'` with the name `SNOWFLAKE.<ROLE>`. The docs do not show it; the
  first live run confirms it.
- **The database-role counts** in "Roles and privileges" were raised by one for each new check.
  Recount them from the docs table once.

## Repository

```
app/api          web server (FastAPI)
app/core         filters, prices, tags, masking, data access
app/queries      the SQL checks, one file each, with a header How it works reads
app/queries/verify  test queries per section, to check the app's numbers by hand
web/             UI source (React 18, TypeScript, Vite, Vitest)
app/web/dist     the built UI, committed; the server serves it
config/          settings, thresholds, materiality floors, docs links
tools/           export, load, lint and build scripts
tools/export_kit the standalone export to send to someone else (refresh: tools/make_export_kit.py)
tests/           pytest suite
```

## Tests

First run `pip install -r requirements-dev.txt`, then:

```
python tools/gate.py     # header lint, manifest, SQL parse, UI type check and tests, pytest
```

The tests run against a fake Snowflake account (`tests/fake_snowflake`): every check runs on it
through DuckDB, and each reaches OK plus WARN or CRITICAL. `python tools/sql_smoke.py` runs only
that part. The full pytest suite takes about 20 minutes.

### Fake data: the app without a Snowflake account

The fake account is code, not a file: `tests/fake_snowflake/` builds the `ACCOUNT_USAGE` views in
DuckDB. `data.py` and the `gap_*` files are the small account the tests use; the `demo_*.py` files
add a large one: 44 warehouses across 8 teams, about 100 users, tasks, pipes, AI use, policies and
partially tagged objects, with 90 days of history. No real names are in it.

To generate the demo database (needs only `requirements.txt`, about 3 minutes), then start the app
on it:

```
python tools/build_demo_db.py      # writes data/demo/db_audit_demo.duckdb, its export and a .coverage.json
AUDIT_DB=data/demo/db_audit_demo.duckdb python -m app.api
```

In PowerShell, set the variable first: `$env:AUDIT_DB="data/demo/db_audit_demo.duckdb"`. Run the
build again after changing anything in `tests/fake_snowflake/`. `data/` is git-ignored.

The UI source is in `web/` (React 18, TypeScript strict, Vite). Changing it needs Node 20 or newer:

```
cd web && npm ci            # once
npm run dev                 # dev server on :5173, /api proxied to the app on :8000
npx tsc --noEmit            # type check
npx vitest run              # UI tests
npm run build               # writes app/web/dist
```

Commit the `web/` source first, then build and commit `app/web/dist`: the build stamps a hash of
the committed source into `dist/source-hash.txt`, and a test fails when the two differ.
