# Deploy to Streamlit in Snowflake

Optional second environment: the same FastAPI API and React build, plus a loaded DuckDB file, shipped to a stage and run as a Streamlit app. **Never run in Snowflake yet.**

## Deployment environments

| Environment | Defined? | What it is | Source |
|---|---|---|---|
| Local machine | Yes, default | `python -m app.api` on 127.0.0.1, data in the OS data folder | README.md:498-502; app/api/__main__.py:27-35 |
| Streamlit in Snowflake, warehouse runtime | Yes, default for deploy | v1 component in its own frame, `environment.yml` (Snowflake Conda channel), no compute pool | tools/streamlit_deploy/deploy.py:81-83, 129-131; README.md:505 |
| Streamlit in Snowflake, container runtime | Yes, fallback | v2 component, `requirements.txt` from PyPI, needs a compute pool | tools/streamlit_deploy/deploy.py:84-87, 132-134; tools/streamlit_deploy/README.md:129-144 |
| Dev / test / prod Snowflake accounts, CI, Docker, cloud hosting | Not defined | No pipeline, no environment config, no CI file | inferred: no CI or Dockerfile in the repo |

```mermaid
flowchart TD
  L[local export + load<br/>audit.duckdb] --> D[deploy.py]
  D --> C{check_db: dims.dim_account<br/>has FAKE%?}
  C -- yes --> X[exit: demo or test data]
  C -- no --> B[build data/streamlit_deploy/bundle]
  B --> R{--runtime}
  R -- warehouse --> W[environment.yml + frame/<br/>index.html, assets, bridge_core.js, bridge_frame.js]
  R -- container --> K[requirements.txt +<br/>bridge_core.js, bridge_container.js]
  W --> S[setup.sql, upload.sql, create_app.sql]
  K --> S
  S -- --run --> SF[(Snowflake: REMOVE + PUT to stage,<br/>CREATE OR REPLACE STREAMLIT,<br/>ADD LIVE VERSION)]
  S -- no --run --> Q[run with SnowSQL by hand]
```

## Steps

1. **One-time objects, as ACCOUNTADMIN**: deploy role, `AUDIT_APP` database, `AUDIT_APP.PUBLIC.AUDIT_APP_STAGE` (SSE, directory on), USAGE on db/schema/warehouse, READ+WRITE on stage, `CREATE STREAMLIT` on schema, a service user with its own key, and the role granted to the person who will open the app (tools/streamlit_deploy/README.md:31-48).
   - The read-only audit role must not be used; a separate deploy role (tools/streamlit_deploy/README.md:31).
2. **Dry build** (no login): `python tools/streamlit_deploy/deploy.py --warehouse MY_WH` prints the DB it will ship and the bundle size (tools/streamlit_deploy/README.md:11-15; tools/streamlit_deploy/deploy.py:190-192).
3. **Deploy**: set `SNOWFLAKE_USER`, `SNOWFLAKE_ROLE`, `SNOWFLAKE_PRIVATE_KEY_FILE` for the window, then `deploy.py --warehouse MY_WH --run` (README.md:511-517).
   - `--run` logs in with the export's `connect()`; environment beats `.env`; a key set in the window drops `.env`'s passphrase (tools/streamlit_deploy/deploy.py:142-159).
   - `--setup` with `--run` also creates database, schema, stage (and the pool for container) (tools/streamlit_deploy/deploy.py:103-109, 193-194).
4. **Open** Snowsight > Projects > Streamlit > "Snowflake audit" (README.md:519).
5. **Share**: `GRANT USAGE ON STREAMLIT ... TO ROLE ...`; viewers also need USAGE on db and schema (tools/streamlit_deploy/README.md:109-115).

Defaults: `--database AUDIT_APP`, `--schema PUBLIC`, `--stage AUDIT_APP_STAGE`, `--warehouse COMPUTE_WH`, `--app AUDIT_APP`, `--runtime warehouse`, `--pool AUDIT_APP_POOL`, `--db` = the file the local app opens (tools/streamlit_deploy/deploy.py:36-40, 162-173).

## Rules the deploy enforces

- **Only a real export ships.** `check_db` counts `dims.dim_account` rows with `account_id` or `name LIKE 'FAKE%'`; any → refuse (tools/streamlit_deploy/deploy.py:43-57).
  - Example: the test and demo DBs carry `FAKE01` / `FAKE_ACCOUNT` (tests/fake_snowflake/data.py:25-28) → "holds demo or test data. Only a real export ships."
  - A file without `dims.dim_account` → "is not an audit database".
- **No secrets in the bundle.** `app/` is copied skipping `*.p8`, `*.pem`, `.env*`, `*.duckdb*`, `__pycache__` (tools/streamlit_deploy/deploy.py:88-90).
- **Settings ship, including `settings.local.yml`**, so on-screen masking set locally holds (tools/streamlit_deploy/deploy.py:91-94; tools/streamlit_deploy/README.md:115).
- **The stage folder is cleared first**: `REMOVE @stage/app_src/`, then one PUT per folder, or one PUT per file where a folder has subfolders or dotfiles (tools/streamlit_deploy/deploy.py:112-126).
- **Paths with `'`, `[` or `]` are refused** before REMOVE, since PUT has no documented escape (tools/streamlit_deploy/deploy.py:178-180).
- **Runtime is named even for warehouse** (`SYSTEM$WAREHOUSE_RUNTIME`), because omitting it now means container runtime on commercial accounts (tools/streamlit_deploy/deploy.py:129-139).
- **Refresh and settings saves are off in the app**: `POST /api/refresh` and any `PUT` answer 409 (tools/streamlit_deploy/streamlit_app.py:126-133); the UI hides them when `window.APP_HOSTED` (web/src/api.ts:10; web/src/App.tsx:277, 490, 646).
- **Message cap**: responses are packed into ≤ 24 MB per batch (warehouse runtime caps 32 MB); one response over it → 413, others wait for the next batch (tools/streamlit_deploy/streamlit_app.py:34-35, 145-165).

## Packages

| Runtime | File | Pins |
|---|---|---|
| warehouse | environment.yml | python 3.11, streamlit 1.52.2, duckdb 1.5.*, pandas 2.*, pyarrow, pyyaml, fastapi, httpx (tools/streamlit_deploy/environment.yml:1-12) |
| container | requirements_container.txt → bundle `requirements.txt` | streamlit 1.56.0, duckdb 1.5.1, pandas 3.0.3, ... (tools/streamlit_deploy/requirements_container.txt:1-7) |

## Container runtime fallback

- `--runtime container --pool SYSTEM_COMPUTE_POOL_CPU` uses the shared pool, usually no admin needed (tools/streamlit_deploy/README.md:133).
- Own pool: `CREATE COMPUTE POOL AUDIT_APP_POOL ... CPU_X64_S AUTO_SUSPEND_SECS = 600`, `GRANT USAGE, MONITOR`, `SNOWFLAKE.PYPI_REPOSITORY_USER` (tools/streamlit_deploy/README.md:135-142).
- Cost trap: the node keeps running until three days after the last viewer (tools/streamlit_deploy/README.md:144).

## What differs from local

- No Refresh; new data = export, load, deploy again, repeat the GRANT (README.md:528-529; tools/streamlit_deploy/README.md:117-119).
- Anyone granted the app sees all data in the file, whatever their role; use `--mask` at export (README.md:530-531).
- Warehouse stays on ~15 min after last activity in an open tab (README.md:533-534).
- Network: allow `*.snowflake.app`, `*.snowflake.com` (and `*.snowflakecomputing.app` for container) and WebSockets (tools/streamlit_deploy/README.md:50).
- Copy link may not open the same page on warehouse runtime (tools/streamlit_deploy/README.md:125).

## Not yet verified

- Nothing has run in Snowflake: packages, DuckDB, the security policy, speed and `--run` are open (STATUS.md:45; README.md:504-505).
- v1 custom components on warehouse runtime: Snowflake's limitations page lists only `html` and `iframe`, so this may be disallowed (STATUS.md:45; tools/streamlit_deploy/README.md:7).
- DuckDB `.so` files may be unsupported on warehouse runtime (tools/streamlit_deploy/README.md:150).
- The per-file PUT and the named warehouse runtime in CREATE STREAMLIT have not run live (STATUS.md:45).
- Checked only with Streamlit run locally, 1.52.2 and 1.56 on Python 3.11 (STATUS.md:45).
- No automated test covers `tools/streamlit_deploy/` (no test file references it; checked tests/*.py).

## Diagnostics built in

- `server_checks()` runs once per server: package imports, components v2 (container), temp folder, open DB, `GET /api/status`, `GET /api/meta`; a failure shows on top of the page (tools/streamlit_deploy/streamlit_app.py:106-120, 204-221).
- "Browser checks" panel: request and batch counts, MB, API time, CSP violations, script errors (tools/streamlit_deploy/bridge_core.js:15-23, 83-87).
- See flows/streamlit-bridge.md for the request path.
