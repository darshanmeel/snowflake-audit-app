# Deploy to Streamlit in Snowflake

This runs the same app inside Snowflake. You upload the code and your data to a stage, then create the app with SQL. `python -m app.api` on your machine stays the default and doesn't use anything here.

The app shows the DuckDB file you ship with it, by default the one your local app opens. The deploy refuses a file holding demo or test data, whatever it's called. It doesn't read your account while it runs, so it needs no privileges on `SNOWFLAKE.ACCOUNT_USAGE`.

**Not yet run in Snowflake.** It has only been tested with Streamlit on a local machine. Warehouse runtime is the default and needs no compute pool. A Snowflake release note says custom components work if they make no external calls, but the limitations page names only v1 `html` and `iframe`, so the component this app uses is untested there. If it fails, use [container runtime](#container-runtime).

## Quick deploy

With your export loaded and the role and user from step 1, run this in PowerShell from the repo folder. The first line prints the file it will ship, so check that it's your real export before the second:

```
.venv\Scripts\Activate.ps1
python tools/streamlit_deploy/deploy.py --warehouse MY_WH

$env:SNOWFLAKE_USER = "MY_DEPLOY_USER"
$env:SNOWFLAKE_ROLE = "MY_DEPLOY_ROLE"
$env:SNOWFLAKE_PRIVATE_KEY_FILE = "path\to\deploy_key.p8"
python tools/streamlit_deploy/deploy.py --warehouse MY_WH --run
```

On macOS or Linux, use `source .venv/bin/activate` and `export SNOWFLAKE_ROLE=MY_DEPLOY_ROLE`, and the same for the other two. If the deploy key is encrypted, set `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` the same way; `.env`'s passphrase isn't used for it.

Then log in to Snowsight as a person who holds the deploy role and open **Snowflake audit** under Projects > Streamlit. The first start can take a few minutes. Export in a new window afterwards, because these settings beat `.env` and the export would sign in as the deploy user.

The steps below give the details and the SnowSQL way.

## 1. Have what it needs

The audit's user and role are read-only and can't deploy, so make a separate role and a user with its own key pair ([Make the key pair](../../README.md#make-the-key-pair)). Don't give this role to the audit's user. As `ACCOUNTADMIN`, once. These are the default names, so Quick deploy needs only your warehouse; change `MY_WH`, and if you change the others, pass them with the options below:

```sql
CREATE ROLE IF NOT EXISTS MY_DEPLOY_ROLE;
CREATE DATABASE IF NOT EXISTS AUDIT_APP;
CREATE STAGE IF NOT EXISTS AUDIT_APP.PUBLIC.AUDIT_APP_STAGE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE);
GRANT USAGE ON DATABASE AUDIT_APP TO ROLE MY_DEPLOY_ROLE;
GRANT USAGE ON SCHEMA AUDIT_APP.PUBLIC TO ROLE MY_DEPLOY_ROLE;
GRANT USAGE ON WAREHOUSE MY_WH TO ROLE MY_DEPLOY_ROLE;
GRANT READ, WRITE ON STAGE AUDIT_APP.PUBLIC.AUDIT_APP_STAGE TO ROLE MY_DEPLOY_ROLE;
GRANT CREATE STREAMLIT ON SCHEMA AUDIT_APP.PUBLIC TO ROLE MY_DEPLOY_ROLE;
CREATE USER IF NOT EXISTS MY_DEPLOY_USER DEFAULT_ROLE = MY_DEPLOY_ROLE TYPE = SERVICE
  RSA_PUBLIC_KEY = '<public key, without the BEGIN and END lines>';
GRANT ROLE MY_DEPLOY_ROLE TO USER MY_DEPLOY_USER;
-- The deploy user can't log in to Snowsight, so give the role to the person who will open the app.
GRANT ROLE MY_DEPLOY_ROLE TO USER MY_OWN_USER;
```

On a restricted network, an admin must also allow `*.snowflake.app` and `*.snowflake.com` (and `*.snowflakecomputing.app` for container runtime) and not block WebSockets. With private connectivity, follow Snowflake's page on it.

Use your own objects, or these defaults:

| Option | Default |
|---|---|
| `--database` | `AUDIT_APP` |
| `--schema` | `PUBLIC` |
| `--stage` | `AUDIT_APP_STAGE` |
| `--warehouse` | `COMPUTE_WH` |
| `--app` | `AUDIT_APP` |
| `--db` | the file the local app opens |

If the database, schema or stage don't exist yet, `--setup` creates them with `--run`, or run the generated `setup.sql`. The role then needs the rights to create them.

## 2. Build the files

```
python tools/streamlit_deploy/deploy.py --database MY_DB --schema MY_SCHEMA --stage MY_STAGE --warehouse MY_WH --app AUDIT_APP
```

This writes `data/streamlit_deploy/`: the `bundle` folder, `setup.sql`, `upload.sql` and `create_app.sql`.

## 3. Upload and create

With SnowSQL or the Snowflake CLI (`PUT` doesn't run in a Snowsight worksheet):

```
snowsql -f data/streamlit_deploy/upload.sql
snowsql -f data/streamlit_deploy/create_app.sql
```

SnowSQL uses its own config file or command-line options, not this repo's `.env`:

```
snowsql -a MY_ACCOUNT -u MY_USER -r MY_DEPLOY_ROLE --private-key-path path/to/key.p8 -f data/streamlit_deploy/upload.sql
```

Or add `--run` to step 2, which does both. It logs in with the same settings as the export, and an environment variable wins over `.env`:

```
SNOWFLAKE_ACCOUNT=...
SNOWFLAKE_USER=...
SNOWFLAKE_ROLE=...
SNOWFLAKE_WAREHOUSE=...
SNOWFLAKE_PRIVATE_KEY_FILE=path/to/key.p8
SNOWFLAKE_PRIVATE_KEY_PASSPHRASE=...
```

Set the passphrase only if the key is encrypted.

That login needs the user and role from step 1, not the audit's. To keep `.env` unchanged, set them for one PowerShell window, as in Quick deploy.

Without `--run`, `deploy.py` needs no login. Keys and `.env` are not uploaded, and the app in Snowflake needs no key or login, because it runs under its owner role.

Open the app in Snowsight under Projects > Streamlit. The first start installs the packages.

## Who can see it

Anyone you grant the app to sees all the data in the file, whatever their role can read:

```sql
GRANT USAGE ON STREAMLIT MY_DB.MY_SCHEMA.AUDIT_APP TO ROLE MY_VIEWERS;
```

Viewers also need USAGE on the database and schema. To hide names, export with `--mask` before you deploy. `config/settings.local.yml` ships with the app, so a saved setting such as masking user names on screen still applies.

## New data

Export and load as usual, then repeat steps 2 and 3. The upload clears `app_src/` in the stage first, so keep nothing of your own in that folder. This replaces the app, so run the GRANT again.

## What differs from the local app

- **Refresh:** there's no Refresh button, because it needs a login and a local export.
- **Settings:** they are read-only in the app, so a viewer can't turn masking off. Set them locally before you deploy.
- **Copy link:** on warehouse runtime the app runs in its own frame, so a copied link may not open the same page.
- **Cost:** the warehouse stays on for about 15 minutes after the last activity in an open tab, whatever its auto-suspend, and moving the mouse over the app counts as activity. Close the tab when done, or set a sleep timer on the app in Snowsight. Each viewer starts their own copy of the app, so opening it takes longer.
- **Large results:** warehouse runtime caps a message at 32 MB. The app splits a page's requests to fit, but one result too large to send, such as a very large CSV, fails with a message.

## Container runtime

Use this if warehouse runtime fails. It isn't available in every government region, and a trial account may not have it. It needs a compute pool, because it runs the app in a container, and it uses Streamlit's newer component type, which Snowflake documents as supported there.

The simplest way needs no new pool and usually no admin: add `--runtime container --pool SYSTEM_COMPUTE_POOL_CPU` to step 2, without `--setup`. Every account has this shared pool, open to all roles unless an admin revoked that.

For a pool of your own, as ACCOUNTADMIN, once:

```sql
CREATE COMPUTE POOL IF NOT EXISTS AUDIT_APP_POOL
  MIN_NODES = 1 MAX_NODES = 1 INSTANCE_FAMILY = CPU_X64_S AUTO_SUSPEND_SECS = 600;
GRANT USAGE, MONITOR ON COMPUTE POOL AUDIT_APP_POOL TO ROLE MY_DEPLOY_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO ROLE MY_DEPLOY_ROLE;
```

Then add `--runtime container --pool AUDIT_APP_POOL` to step 2. The app keeps its node running until three days after the last viewer, and only then do the 600 seconds apply, so the pool can bill for about three days after each visit. `ALTER COMPUTE POOL AUDIT_APP_POOL SUSPEND;` stops it sooner.

## If it doesn't work

- **An SQL error during the deploy:** this is usually a missing privilege or a wrong name.
- **A package doesn't install:** warehouse runtime only has Snowflake's Conda channel. Check `environment.yml` against the error. If every package fails, ask an ORGADMIN to check the External Offerings Terms under Admin > Terms; Snowflake's docs disagree on whether this is needed.
- **The page shows an error at the top:** the failed lines under it say which check failed. DuckDB is the most likely, because Snowflake's docs list `.so` files as unsupported, although the channel has `duckdb`.
- **The page stays blank or on "Loading…":** open **Browser checks** in the app, or **Server checks** below it. They list what failed or what Snowflake's security policy blocked. A blank frame on warehouse runtime can come from a blocked network, so check the allowlist in step 1 first. Otherwise warehouse runtime doesn't allow this component; use container runtime.
