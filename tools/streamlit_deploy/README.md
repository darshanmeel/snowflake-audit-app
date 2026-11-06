# Deploy to Streamlit in Snowflake

This runs the same app inside Snowflake, on Streamlit's container runtime. `python -m app.api` on your machine stays the default and doesn't use anything here.

The app shows the DuckDB file you ship with it. It doesn't read your account while it runs, so it needs no privileges on `SNOWFLAKE.ACCOUNT_USAGE`.

## Before you start

You need a DuckDB file with your export, the same file `AUDIT_DB` points at locally, or use `--demo` to try it with demo data.

As ACCOUNTADMIN, once per account, if the deploying role doesn't have these yet:

```sql
CREATE COMPUTE POOL IF NOT EXISTS MY_POOL
  MIN_NODES = 1 MAX_NODES = 1 INSTANCE_FAMILY = CPU_X64_S AUTO_SUSPEND_SECS = 600;
GRANT USAGE, MONITOR ON COMPUTE POOL MY_POOL TO ROLE MY_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO ROLE MY_ROLE;
```

The role also needs CREATE STREAMLIT and CREATE STAGE on the schema, and USAGE on the warehouse.

## Deploy

With the login in `.env`, upload and create it in one step:

```
python tools/streamlit_deploy/deploy.py --db PATH/TO/audit.duckdb --stage MY_DB.MY_SCHEMA.AUDIT_APP --warehouse MY_WH --pool MY_POOL --name MY_DB.MY_SCHEMA.AUDIT_APP --run
```

To upload by hand, leave out `--run`. That writes `data/streamlit_deploy/upload.sql` and `create_app.sql`:
1. Run `upload.sql` with SnowSQL or the Snowflake CLI, because `PUT` doesn't run in a Snowsight worksheet.
2. Run `create_app.sql` in a worksheet.

Open the app in Snowsight under Projects > Streamlit. The first start installs the packages and can take a few minutes.

## Who can see it

Anyone you grant the app to sees all the data in the file, whatever their role can read in Snowflake:

```sql
GRANT USAGE ON STREAMLIT MY_DB.MY_SCHEMA.AUDIT_APP TO ROLE MY_VIEWERS;
```

To hide names, export with `--mask` before you deploy. `config/settings.local.yml` ships with the app, so a saved setting such as masking user names on screen still applies.

## New data

Export and load as usual, then run the deploy command again with the new file. It replaces the app, so run the GRANT again.

## What differs from the local app

- **Refresh:** there's no Refresh button, because it needs a login and a local export.
- **Settings:** a setting saved in the app applies to every viewer and is lost when the app is deployed again. Set it locally before you deploy to keep it.
- **Cost:** the compute pool bills while it runs. It suspends after the time you set. To stop it, run `ALTER COMPUTE POOL MY_POOL SUSPEND;`.

## If it doesn't work

- **The page shows an error at the top:** the failed lines under it say which check failed, such as a package install or opening the file.
- **The page stays on "Loading…":** open **Browser checks** below the page. It lists what Snowflake's security policy blocked.
- **Slow or failed requests:** **Browser checks** and **Server checks** show request counts, times and errors.
- **Warehouse runtime:** this doesn't work there, because Streamlit's newer components need container runtime.
