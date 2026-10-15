# Snowflake audit app

A read-only audit of a Snowflake account. It shows where the credits and dollars go, what looks wasted, and how warehouses, queries, tasks, loading, storage, AI and access are set up. The export runs SQL checks on `SNOWFLAKE.ACCOUNT_USAGE` (and `ORGANIZATION_USAGE`), and the results are saved in a local DuckDB file. A web app on the user's machine shows them.

It is built the same way as the Databricks audit app (`../databricks-audit-app`), with the same shell, pages, roles, Guide and number rules. Snowflake's views hold more, so it has more tabs and sub-tabs where the data supports them. It must sell to any Snowflake customer: generic, with zero config.

The work plan and the inputs (with local paths) are in `tasks/START-HERE.md`, which is git-ignored. Read it first in a new session.

The current state, next steps and working preferences are in `STATUS.md`. Read it too, and keep it up to date.

## Rules

### Data and SQL
- **Read-only on Snowflake:** SELECT, WITH and SHOW only.
- **Never store:** query text, SQL literals, secrets, policy bodies, raw logs or config values.
- **Names, not ids:** show `name (id)` for warehouses, databases, tasks, users and roles, never a bare id.
- **Keep all rows:** joins and `FLATTEN` are OUTER, so untagged or unmatched rows are never dropped.
- **Known bug classes; check every money query for them:**
  - price joined twice;
  - units added together (credits plus $, spend plus waste);
  - days with zero usage skipped;
  - two "todays" (as-of vs `CURRENT_DATE`).
- **Snowflake traps:**
  - Cloud services must be priced after the 10% adjustment.
  - Query attribution is not a total: it leaves out idle time and queries under about 100 ms, is NULL on adaptive warehouses, and lags up to 8 h.
  - SHOW and several views show only what the role can see.
  - Fail-safe tables have NULL names and can pass as live.
  - `POLICY_REFERENCES` does not list session, password or authentication policies.
  - Read both `TABLE_ID` and `BASE_TABLE_ID` while that rename rolls out.
  - Org billing views lag up to 72 h.
- **Verify on docs.snowflake.com first.** Check every view and column name there before writing SQL. When a view is missing, the edition is too low or the role can't see it, the check reads NOT_ASSESSED, never "nothing found".

### Numbers on screen
- A check that didn't run never reads clean. It shows "–" and why: not in this export, needs Enterprise edition, the role can't see it, or failed. Never $0.
- Numbers agree across pages:
  - one "checks that ran" count;
  - the same $ on Overview, Actions, Waste & savings and the area pages;
  - "…" while loading, never interim values.
- Counts name their unit, for example "12 of 48 warehouses".
- Spend, change and possible waste are never added together.
- There is one money cut-off per page. Today is shown as partial.

### UI
- Explanations:
  - 1–2 lines of explanation on screen;
  - the depth goes in the Guide, with docs.snowflake.com links from a data file.
- Layout:
  - the area Overview comes first, charts first;
  - tables are for drill-down;
  - keep less on screen.
- Empty results read "No data for this in 16–22 Sep 2026". A missing source says which view and how to get access.
- A dashboard shows; it doesn't explain. A tile is a label, a number, one line and a link.
- Each check has one home. Access, PII, Lineage and Audit are separate tabs.
- Masking is optional and off by default: user names and emails on screen (`privacy.mask_user_identities`), and any kind of name
  in the export (`--mask`, `privacy.mask_fields`, app/core/masking.py), the same token everywhere. Never mask by default.
- Keep the Databricks app's look. No new visual design unless asked.

### Repo hygiene
- No customer names, real account, warehouse, user or role names, or absolute local machine paths in the repo.
  - Before every commit, run the name grep in `tasks/START-HERE.md`.
  - Add real names you see in an export to that grep.
- Planning notes, review files and exports stay out of git (`tasks/`, `data/`, `.env`).
- Code style:
  - one-line why-comments;
  - no task ids or dates in code;
  - short docstrings and commit messages.
- No app security hardening. The customer's teams own that.

### How we work
- Answer the user's question first, in 1–2 lines, then the rest.
- Don't agree by default. If a request or design is costly, breaks a rule or doesn't make sense, say so and why, and offer the better option.
- Propose design and behaviour changes and wait for a yes. Plain bugs: fix them, then report.
- Test only when asked. Otherwise run a compile check only: `python -c "import app.api.app"` plus `cd web && npx tsc --noEmit`.
- After any change under `web/`, commit the source, then `cd web && npm run build` and commit `app/web/dist`. A test checks the build matches the committed source.
- Commit and push to `main` after every finished change (it's a POC).
  - Commit as `git -c user.email=darshansingh@crosshire.ch commit ...`.
  - End each commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- The user runs the app from the GitHub zip, so list the changed files after each push.
- No workflows and no background builder agents unless the user names them. Do the work in the main session, in steps.
- Check every changed page in a real browser (Playwright) on real data before calling it done.

## Tools and knowledge
- **Claude Code:**
  - Playwright plugin, for browser checks.
  - skill-creator, to build and keep the `snowflake-account-usage` skill: the view catalog and the traps above.
  - WebFetch and WebSearch, for docs.snowflake.com.
  - frontend-design and workflows only when asked.
- **Machine:**
  - Python 3.11+, Node 20+ (for the UI build in `web/`) and the `gh` CLI;
  - `snowflake-connector-python`, with key-pair auth in `.env`.
- **Knowledge the work leans on:**
  - **Snowflake's usage views:** latency, retention, edition, and role visibility.
  - **Billing:**
    - credits used vs billed;
    - the cloud-services adjustment;
    - serverless, Gen2 and Snowpark-optimized rates;
    - storage (active, Time Travel, Fail-safe, stages);
    - data transfer;
    - AI token credits;
    - effective $/credit.
  - **SQL:** Snowflake (SHOW plus RESULT_SCAN, FLATTEN, VARIANT), and DuckDB on the app side.
  - **App stack:** FastAPI, DuckDB, and React 18 with TypeScript, built by Vite from `web/` into `app/web/dist`.
