# Deploy to Streamlit in Snowflake

This runs the same app inside Snowflake. You upload the code and your data to a stage, then create the app with SQL. `python -m app.api` on your machine stays the default and doesn't use anything here.

The app shows the DuckDB file you ship with it, by default the one your local app opens. The deploy refuses a file holding demo or test data, whatever it's called. It doesn't read your account while it runs, so it needs no privileges on `SNOWFLAKE.ACCOUNT_USAGE`.

**Not yet run in Snowflake.** It has only been tested with Streamlit on a local machine. Warehouse runtime is the default and needs no compute pool, but Snowflake's docs don't say it supports the component type it uses. If it fails, use [container runtime](#container-runtime).

## Quick deploy

With your export loaded and a role that has the rights in step 1, run this from the repo folder:

```
$env:SNOWFLAKE_ROLE = "MY_DEPLOY_ROLE"
python tools/streamlit_deploy/deploy.py --database MY_DB --schema MY_SCHEMA --stage MY_STAGE --warehouse MY_WH --run
```

Check that the `database: ...` line it prints is your real export, then open **Snowflake audit** in Snowsight under Projects > Streamlit. The first start can take a few minutes. The steps below give the details and the SnowSQL way.

## 1. Have what it needs

The role needs USAGE on the database, schema and warehouse, READ and WRITE on the stage, and CREATE STREAMLIT on the schema.

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
SNOWFLAKE_PRIVATE_KEY_PASSPHRASE=...      # only if the key is encrypted
```

That login needs the role above, not the audit's read-only role. To keep `.env` unchanged, set the role for this PowerShell window only:

```
$env:SNOWFLAKE_ROLE = "MY_DEPLOY_ROLE"
```

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
- **Cost:** the warehouse runs while the app is open, up to its sleep timer. Each viewer starts their own copy of the app, so opening it takes longer.
- **Large results:** warehouse runtime caps a message at 32 MB. The app splits a page's requests to fit, but one result too large to send, such as a very large CSV, fails with a message.

## Container runtime

Use this if warehouse runtime fails. It needs a compute pool, because it runs the app in a container, and it uses Streamlit's newer component type, which Snowflake documents as supported there.

As ACCOUNTADMIN, once:

```sql
CREATE COMPUTE POOL IF NOT EXISTS AUDIT_APP_POOL
  MIN_NODES = 1 MAX_NODES = 1 INSTANCE_FAMILY = CPU_X64_S AUTO_SUSPEND_SECS = 600;
GRANT USAGE, MONITOR ON COMPUTE POOL AUDIT_APP_POOL TO ROLE MY_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO ROLE MY_ROLE;
```

Then add `--runtime container --pool AUDIT_APP_POOL` to step 2. The pool bills while it runs; `ALTER COMPUTE POOL AUDIT_APP_POOL SUSPEND;` stops it.

## If it doesn't work

- **An SQL error during the deploy:** this is usually a missing privilege or a wrong name.
- **A package doesn't install:** warehouse runtime only has Snowflake's Conda channel. Check `environment.yml` against the error.
- **The page shows an error at the top:** the failed lines under it say which check failed. DuckDB is the most likely, because Snowflake's docs list `.so` files as unsupported, although the channel has `duckdb`.
- **The page stays blank or on "Loading…":** open **Browser checks** in the app, or **Server checks** below it. They list what failed or what Snowflake's security policy blocked. A blank frame on warehouse runtime means it doesn't allow this component; use container runtime.
