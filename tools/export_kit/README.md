# Snowflake audit export kit

Runs read-only SQL (`SELECT`, `WITH` and `SHOW` only) on `SNOWFLAKE.ACCOUNT_USAGE` and
`ORGANIZATION_USAGE`, and writes the results as parquet files. Nothing in the account is changed.
Query text, secrets and policy bodies are never read.

What is in this folder:

- `run_export.py`: the export. The only Python file.
- `queries/`: every statement it runs (279 checks, plus the dims and tag sources), as plain `.sql`.
  `queries/index.json` holds each check's parameters. Read them before running if you like.
- `grants.sql`: the role and the grants it needs (see "Roles and privileges" below).
- `verify/`: test queries, one file per app section, to paste into a worksheet and compare with what
  the app shows. Read-only too.

## How to run it

1. **Install** (Python 3.9 or newer):

   ```
   python -m pip install "snowflake-connector-python[pandas]" "pyarrow>=14"
   ```

2. **Grants:** edit the names in `grants.sql` and run it once as `ACCOUNTADMIN`. "Roles and
   privileges" below says what each grant opens and what is missing without it.

3. **Sign-in:** create a file called `.env` in this folder:

   ```
   SNOWFLAKE_ACCOUNT=<orgname-accountname>
   SNOWFLAKE_USER=<user>
   SNOWFLAKE_ROLE=<role from grants.sql>
   SNOWFLAKE_WAREHOUSE=<warehouse>              # an XS warehouse is enough
   SNOWFLAKE_PRIVATE_KEY_FILE=<path to .p8>     # or SNOWFLAKE_PASSWORD=..., or leave both out
                                                # to sign in through the browser
   ```

4. **Run**, from this folder:

   ```
   python run_export.py                         # last 30 days
   python run_export.py --windows 90            # last 90 days
   python run_export.py --credit-price 3.0      # without invoice access: your $ per credit
   ```

   It prints one line per check as it goes. A check that fails (a SQL error, a view the account
   does not have, a timeout) is recorded and the next one runs. A check the role cannot read is
   skipped; that is normal. Ctrl+C stops the run and still writes the report for the checks that
   ran.

5. **Send back `sf-audit-out.zip`.** It holds the parquet files, `manifest.json` and
   `report.md`. `report.md` lists every check's status, every view the role could not read, and
   every error in full.

`--windows N` is the days of history (default 30). Anything over 90 pulls the same as 90; fewer
days run faster.

`--mask user,warehouse,database` replaces those kinds of names with tokens before any file is
written (also `schema`, `object`, `role`, `task`, `account`, or `all`). The same name gets the same
token in every file, so the results still add up. The tokens are salted at random on each run;
`--mask-salt TEXT` keeps them the same across runs.

Other options: `--only <check ids>` runs just those checks, `--statement-timeout SECONDS` (default
900) stops a slow statement, and `--out <folder>` writes somewhere else.

## Roles and privileges

The export signs in with one role, and that role decides what you see. Everything below is
read-only: nothing lets the role change data, warehouses or settings.

### The grant script

Run this once as `ACCOUNTADMIN` (or a role that can create roles and grant on the account). The
same script is in `grants.sql`.

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
shows $0 or "nothing found". Counts are checks out of 274; a check can need more than one grant.

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
