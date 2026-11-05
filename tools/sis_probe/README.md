# Streamlit in Snowflake test

A throwaway test, separate from the app. It runs the real API and the real React build inside Streamlit in Snowflake on container runtime, using the demo data, and prints a report. The local app doesn't use anything here.

It reads no account data and needs no privileges on `SNOWFLAKE.ACCOUNT_USAGE`.

## Run it

1. **Build the files.** Use your own names:

   ```
   python tools/sis_probe/make_bundle.py --stage MY_DB.MY_SCHEMA.AUDIT_APP --warehouse MY_WH --pool MY_POOL --name MY_DB.MY_SCHEMA.AUDIT_APP_TEST
   ```

   This writes `data/sis_probe/bundle`, `upload.sql` and `create_app.sql`. It needs the demo database; if it's missing, run `python tools/build_demo_db.py`.

2. **Upload.** `PUT` doesn't run in a Snowsight worksheet, so use SnowSQL or the Snowflake CLI:

   ```
   snowsql -f data/sis_probe/upload.sql
   snow sql -f data/sis_probe/upload.sql
   ```

3. **Create the app.** Read the comments at the top of `create_app.sql`, because the role may need a compute pool and the PyPI grant first. Then run the file in a worksheet.

4. **Open the app** in Snowsight under Projects > Streamlit. The first start installs the packages and can take a few minutes.

5. **Copy the report.** Wait until the box says `DONE`, then copy the whole box. If the box never fills, open **Python checks** and copy that instead, and say that the box stayed empty.

6. **Clean up.** The compute pool bills while it runs. The commands are at the bottom of `create_app.sql`.

## Reading the report

| Line | What it answers |
|---|---|
| `install ...` | The packages install from Snowflake's PyPI mirror |
| `duckdb opens the demo file` | DuckDB's native library loads, and the file survives the stage copy |
| `component script ran` | Snowflake's security policy allows the component's script |
| `one request`, `burst of 20` | The time a request takes through Streamlit |
| `first page`, `go to Warehouses` | The time a real page takes, and how much of it is the API |
| `React page drew` | The real UI runs |
| `blocked by CSP` | What Snowflake's security policy stopped |

## Left out on purpose

- **Fonts:** they need static files, so the page uses fallback fonts.
- **Refresh:** it's turned off, because it needs a login and a local export.
- **Look:** the app's styles apply to the whole Streamlit page, which is fine for a test.
