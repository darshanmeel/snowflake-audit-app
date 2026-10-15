#!/usr/bin/env python3
"""Refresh the export kit in tools/export_kit: one Python file plus the SQL, for someone to run on
their Snowflake account without the rest of this repo. Run it after changing any SQL in app/queries;
tests/test_export_kit.py fails while the kit is out of date.

    python tools/make_export_kit.py                 # rewrites tools/export_kit/ (queries, grants, README)
    python tools/make_export_kit.py --zip DIR       # also writes DIR/export_kit.zip to send
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import config as app_config  # noqa: E402
from app.core import datasource  # noqa: E402
from app.core import reasons as app_reasons  # noqa: E402
from app.core import registry as app_registry  # noqa: E402
from tools import export_results as ex  # noqa: E402
from tools.common import DEFAULT_MAX_ROWS  # noqa: E402

KIT = ROOT / "tools" / "export_kit"

README_HEAD = """# Snowflake audit export kit

Runs read-only SQL (`SELECT`, `WITH` and `SHOW` only) on `SNOWFLAKE.ACCOUNT_USAGE` and
`ORGANIZATION_USAGE`, and writes the results as parquet files. Nothing in the account is changed.
Query text, secrets and policy bodies are never read.

What is in this folder:

- `run_export.py`: the export. The only Python file.
- `queries/`: every statement it runs ({n} checks, plus the dims and tag sources), as plain `.sql`.
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

"""


def _write(path: Path, text: str) -> None:
    # LF on every system, so a rebuild on Windows leaves the committed files unchanged.
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def roles_section() -> str:
    """The README's "Roles and privileges" section, worded for the kit."""
    text = (ROOT / "README.md").read_text(encoding="utf-8").replace("\r\n", "\n")
    section = "## Roles and privileges" + text.split("## Roles and privileges", 1)[1].split("\n## ", 1)[0]
    section = section.replace("The\nexport kit ships the same script as `grants.sql`.", "The\nsame script is in `grants.sql`.")
    # The full export's --validate is not in the kit.
    lines = section.split("\n")
    start = next((i for i, line in enumerate(lines) if line.startswith("- `--validate`")), None)
    if start is not None:
        end = start + 1
        while end < len(lines) and lines[end].startswith("  "):
            end += 1
        lines = lines[:start] + lines[end:]
    return "\n".join(lines).rstrip() + "\n"


def grants_sql() -> str:
    """The grant script from the README's "Roles and privileges" section, so the two never differ."""
    section = roles_section()
    return section.split("```sql", 1)[1].split("```", 1)[0].lstrip()


MASK_START = "# ---- masking: a copy of app/core/masking.py, made by tools/make_export_kit.py; edit it there ----"
MASK_END = "# ---- end of masking ----"


def masking_block() -> str:
    """app/core/masking.py without its docstring and imports (run_export.py imports the same modules)."""
    src = (ROOT / "app" / "core" / "masking.py").read_text(encoding="utf-8").replace("\r\n", "\n")
    body = src.split('"""', 2)[2]
    lines = [line for line in body.split("\n") if not line.startswith(("import ", "from "))]
    return "\n".join(lines).strip("\n")


def refresh_masking(script: Path) -> None:
    """Rewrite the masking block of the kit's run_export.py from app/core/masking.py."""
    text = script.read_text(encoding="utf-8").replace("\r\n", "\n")
    head, rest = text.split(MASK_START + "\n", 1)
    _, tail = rest.split(MASK_END + "\n", 1)
    _write(script, head + MASK_START + "\n" + masking_block() + "\n" + MASK_END + "\n" + tail)


def build(kit: Path = KIT) -> Path:
    """Write queries/, grants.sql and README.md into kit (and run_export.py when kit is elsewhere)."""
    if kit.resolve() != KIT.resolve() and datasource.inside_repo(kit):
        raise ex.ExportConfigError(f"{kit} is inside the repository; use tools/export_kit or a folder outside it")
    for sub in ("queries", "verify"):
        if (kit / sub).exists():
            shutil.rmtree(kit / sub)
    thresholds = app_config.load_thresholds()
    query_tag = app_config.query_source()

    def inline(text: str) -> str:
        # Includes are pasted in and the query tag fixed, so each file is the statement as run.
        sql = ex._INCLUDE_RE.sub(lambda m: (ex.SQL_DIR / "common" / f"{m.group(1)}.sql")
                                 .read_text(encoding="utf-8").strip(), text)
        return sql.replace("__QUERY_SOURCE__", ex._literal(query_tag)).replace("\r\n", "\n")

    checks = {}
    for qid, text in ex.load_checks().items():
        spec = app_registry.by_id(qid)
        _write(kit / "queries" / "checks" / f"{qid}.sql", inline(text))
        checks[qid] = {"domain": spec.domain, "windowed": bool(spec.windowed), "pre": list(spec.pre),
                       "sources": [f"{sch}.{name}" for sch, name in spec.sources],
                       "params": ex.params_for(qid, thresholds),
                       "needs_enterprise": app_reasons.needs_enterprise(spec.requires, spec.empty_if)}
    # INFORMATION_SCHEMA fallbacks: run when the role cannot read a check's ACCOUNT_USAGE views
    for qid, text in ex.load_fallbacks().items():
        head = ex.parse_header(text)
        _write(kit / "queries" / "fallback" / f"{qid}.sql", inline(text))
        checks[qid]["fallback"] = {"pre": [x.strip() for x in head.get("pre", "").split(";") if x.strip()],
                                   "reads": head.get("reads"), "note": head.get("fallback_note"),
                                   "needs": head.get("needs"),
                                   "query_feed": "__INCLUDE_is_query_history__" in text}
    # The query history those fallbacks share: run once in slices, then read with RESULT_SCAN.
    _write(kit / "queries" / "common" / "is_query_history_feed.sql",
           inline((ex.SQL_DIR / "common" / "is_query_history_feed.sql").read_text(encoding="utf-8")))
    tag_sources = {}
    for name, text in ex.load_tag_sources().items():
        _write(kit / "queries" / "tag_sources" / f"{name}.sql", inline(text))
        tag_sources[name] = ex.parse_header(text).get("windowed", "no").strip().lower().startswith("yes")
    dims = []
    for name, text in ex.load_dims().items():
        _write(kit / "queries" / "dims" / f"{name}.sql", inline(text))
        dims.append(name)
    try:
        settings = app_config.load_settings()
    except Exception:  # noqa: BLE001 -- defaults are fine for a kit
        settings = {}
    index = {
        "defaults": {"max_rows": DEFAULT_MAX_ROWS, "include_today": bool(settings.get("include_today", False)),
                     # fallback prices when the org billing view has none
                     "credit_price_usd": settings.get("credit_price_usd"),
                     "ai_credit_price_usd": settings.get("ai_credit_price_usd"),
                     "storage_price_usd_tb_month": settings.get("storage_price_usd_tb_month"), "query_tag": query_tag},
        "checks": checks, "tag_sources": tag_sources, "dims": dims,
    }
    _write(kit / "queries" / "index.json", json.dumps(index, indent=1) + "\n")
    _write(kit / "grants.sql", grants_sql())
    for f in sorted((ex.SQL_DIR / "verify").glob("*.sql")):
        _write(kit / "verify" / f.name, f.read_text(encoding="utf-8"))
    _write(kit / "README.md", README_HEAD.replace("{n}", str(len(checks))) + roles_section())
    if kit.resolve() != KIT.resolve():
        shutil.copy2(KIT / "run_export.py", kit / "run_export.py")
    refresh_masking(kit / "run_export.py")
    return kit


def zip_kit(out: Path, kit: Path = KIT) -> Path:
    """export_kit.zip in out (outside the repo), without local files such as .env or results."""
    if datasource.inside_repo(out):
        raise ex.ExportConfigError(f"{out} is inside the repository; choose a folder outside it")
    out.mkdir(parents=True, exist_ok=True)
    staging = out / kit.name
    if staging.exists():
        shutil.rmtree(staging)
    shutil.copytree(kit, staging, ignore=shutil.ignore_patterns(
        ".env", "*.p8", "sf-audit-out*", "__pycache__"))
    archive = shutil.make_archive(str(out / kit.name), "zip", root_dir=out, base_dir=kit.name)
    shutil.rmtree(staging)
    return Path(archive)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--zip", type=Path, metavar="DIR", help="also write DIR/export_kit.zip, outside the repo")
    args = p.parse_args(argv)
    try:
        kit = build()
        print(f"refreshed {kit.relative_to(ROOT)}")
        if args.zip:
            print(f"wrote {zip_kit(args.zip)}")
    except ex.ExportConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
