# Deploy to Streamlit in Snowflake

This runs the same app inside Snowflake. You upload the code and your data to a stage, then create the app with SQL. `python -m app.api` on your machine stays the default and doesn't use anything here.

The app shows the DuckDB file you ship with it, by default the one your local app opens. It never ships demo data. It doesn't read your account while it runs, so it needs no privileges on `SNOWFLAKE.ACCOUNT_USAGE`.

**Not yet run in Snowflake.** It has only been tested with Streamlit on a local machine. Warehouse runtime is the default and needs no compute pool, but Snowflake's docs don't say it supports the component type it uses. If it fails, use [container runtime](#container-runtime).

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

Or add `--run` to step 2, which does both with the login in `.env`. That login needs the role above, not the audit's read-only role; set `SNOWFLAKE_ROLE` in the environment to override it for this command.

Open the app in Snowsight under Projects > Streamlit. The first start installs the packages.

## Who can see it

Anyone you grant the app to sees all the data in the file, whatever their role can read:

```sql
GRANT USAGE ON STREAMLIT MY_DB.MY_SCHEMA.AUDIT_APP TO ROLE MY_VIEWERS;
```

Viewers also need USAGE on the database and schema. To hide names, export with `--mask` before you deploy. `config/settings.local.yml` ships with the app, so a saved setting such as masking user names on screen still applies.

## New data

Export and load as usual, then repeat steps 2 and 3. This replaces the app, so run the GRANT again.

## What differs from the local app

- **Refresh:** there's no Refresh button, because it needs a login and a local export.
- **Settings:** a setting saved in the app is lost when the app restarts or is deployed again, so set it locally before you deploy.
- **Copy link:** on warehouse runtime the app runs in its own frame, so a copied link may not open the same page.
- **Cost:** the warehouse runs while the app is open, up to its sleep timer. Each viewer starts their own copy of the app, so opening it takes longer.
- **Large downloads:** warehouse runtime caps a message at 32 MB, so a very large CSV can fail.

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

- **A package doesn't install:** warehouse runtime only has Snowflake's Conda channel. Check `environment.yml` against the error.
- **The page shows an error at the top:** the failed lines under it say which check failed. DuckDB is the most likely, because Snowflake's docs list `.so` files as unsupported, although the channel has `duckdb`.
- **The page stays blank or on "Loading…":** open **Browser checks** in the app, or **Server checks** below it. They list what failed or what Snowflake's security policy blocked. A blank frame on warehouse runtime means it doesn't allow this component; use container runtime.
