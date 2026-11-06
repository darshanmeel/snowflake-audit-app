"""Deploys the audit app to Streamlit in Snowflake. The local app needs none of this.

    python tools/streamlit_deploy/deploy.py             write the files and SQL, with the default names
    python tools/streamlit_deploy/deploy.py --run       also upload and create the app, with the login in .env
    python tools/streamlit_deploy/deploy.py --run --setup   also create the database, schema and stage first

It ships the database the local app opens, or --db. The output goes to data/streamlit_deploy (git-ignored).
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
HERE = Path(__file__).resolve().parent
OUT = ROOT / "data" / "streamlit_deploy"
DIST = ROOT / "app" / "web" / "dist" / "assets"
STREAMLIT_CONFIG = '[client]\ntoolbarMode = "minimal"\n\n[browser]\ngatherUsageStats = false\n'
FRAME_HTML = """<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Snowflake audit</title><link rel="stylesheet" href="assets/{css}"></head>
<body data-bundle="assets/{js}">
<div id="root"><div class="loading-note">Loading…</div></div>
<details style="font:12px monospace;padding:8px 24px"><summary>Browser checks</summary><pre id="audit-browser-checks" style="white-space:pre-wrap">The bridge script has not run.</pre></details>
<script src="bridge_core.js"></script>
<script src="bridge_frame.js"></script>
</body>
</html>
"""


def default_db() -> Path:
    """The file the local app opens: AUDIT_DB, the last load or Refresh, else the data folder's own."""
    sys.path.insert(0, str(ROOT))
    from app.core import data
    return data._db_path()


def check_db(db: Path) -> None:
    """Demo and test data carry the fake account, whatever the file is called."""
    import duckdb
    if not db.exists():
        raise SystemExit(f"No database at {db}. Export and load first (python tools/first_run.py), or pass --db.")
    con = duckdb.connect(str(db), read_only=True)
    try:
        fake = con.execute("SELECT count(*) FROM dims.dim_account "
                           "WHERE account_id LIKE 'FAKE%' OR name LIKE 'FAKE%'").fetchone()[0]
    except duckdb.Error as exc:
        raise SystemExit(f"{db} is not an audit database: it has no dims.dim_account.") from exc
    finally:
        con.close()
    if fake:
        raise SystemExit(f"{db} holds demo or test data. Only a real export ships. Pass --db with your own file.")


def build_frame(frame: Path) -> None:
    """The page warehouse runtime serves as a component; its fonts and script are files beside it."""
    (frame / "assets").mkdir(parents=True)
    for src in DIST.iterdir():
        shutil.copy2(src, frame / "assets" / src.name)
    css = next(DIST.glob("index-*.css"))
    js = next(DIST.glob("index-*.js"))
    # The stylesheet sits beside the fonts, and a page in a frame has no /assets at its root.
    (frame / "assets" / css.name).write_text(
        re.sub(r"url\(/assets/", "url(", css.read_text(encoding="utf-8")), encoding="utf-8")
    (frame / "index.html").write_text(FRAME_HTML.format(css=css.name, js=js.name), encoding="utf-8")
    for name in ("bridge_core.js", "bridge_frame.js"):
        shutil.copy2(HERE / name, frame / name)


def build(db: Path, runtime: str) -> Path:
    bundle = OUT / "bundle"
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)
    shutil.copy2(HERE / "streamlit_app.py", bundle / "streamlit_app.py")
    if runtime == "warehouse":
        shutil.copy2(HERE / "environment.yml", bundle / "environment.yml")
        build_frame(bundle / "frame")
    else:
        shutil.copy2(HERE / "requirements_container.txt", bundle / "requirements.txt")
        for name in ("bridge_core.js", "bridge_container.js"):
            shutil.copy2(HERE / name, bundle / name)
    # A key or database left in these folders must not reach the stage.
    skip = shutil.ignore_patterns("__pycache__", "*.pyc", "*.p8", "*.pem", ".env*", "*.duckdb*")
    shutil.copytree(ROOT / "app", bundle / "app", ignore=skip)
    (bundle / "config").mkdir()
    # With settings.local.yml, so a setting such as masking user names holds there too.
    for settings in (ROOT / "config").glob("*.yml"):
        shutil.copy2(settings, bundle / "config" / settings.name)
    (bundle / ".streamlit").mkdir()
    (bundle / ".streamlit" / "config.toml").write_text(STREAMLIT_CONFIG, encoding="utf-8")
    shutil.copy2(db, bundle / "audit.duckdb")
    for sidecar in db.parent.glob(f"{db.stem}.*.json"):
        shutil.copy2(sidecar, bundle / f"audit{sidecar.name[len(db.stem):]}")
    return bundle


def setup_statements(database: str, schema: str, stage: str, runtime: str, pool: str) -> list[str]:
    lines = [f"CREATE DATABASE IF NOT EXISTS {database}", f"CREATE SCHEMA IF NOT EXISTS {database}.{schema}",
             f"CREATE STAGE IF NOT EXISTS {stage} ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE)"]
    if runtime == "container":
        lines.append(f"CREATE COMPUTE POOL IF NOT EXISTS {pool} "
                     "MIN_NODES = 1 MAX_NODES = 1 INSTANCE_FAMILY = CPU_X64_S AUTO_SUSPEND_SECS = 600")
    return lines


def upload_statements(bundle: Path, stage: str) -> list[str]:
    """Clears the app's folder first: files left by another runtime or an older build would ship too.
    The connector rejects a pattern that matches a folder and `*` skips dotfiles, so those folders
    get one PUT per file."""
    lines = [f"REMOVE @{stage}/app_src/"]
    for folder in sorted({p.parent for p in bundle.rglob("*") if p.is_file()}):
        rel = folder.relative_to(bundle).as_posix()
        target = f"@{stage}/app_src" + ("" if rel == "." else f"/{rel}")
        entries = list(folder.iterdir())
        if any(e.is_dir() or e.name.startswith(".") for e in entries):
            sources = [e.as_posix() for e in sorted(entries) if e.is_file()]
        else:
            sources = [f"{folder.as_posix()}/*"]
        lines += [f"PUT 'file://{src}' {target} AUTO_COMPRESS=FALSE OVERWRITE=TRUE" for src in sources]
    return lines


def create_statements(stage: str, warehouse: str, name: str, runtime: str, pool: str) -> list[str]:
    # Named even for the warehouse: leaving it out now means container runtime on commercial accounts.
    extra = "\n  RUNTIME_NAME = 'SYSTEM$WAREHOUSE_RUNTIME'"
    if runtime == "container":
        extra = (f"\n  RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'\n  COMPUTE_POOL = {pool}"
                 "\n  ARTIFACT_REPOSITORIES = (snowflake.snowpark.pypi_shared_repository)")
    return [f"""CREATE OR REPLACE STREAMLIT {name}
  FROM @{stage}/app_src
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = {warehouse}{extra}
  TITLE = 'Snowflake audit'""", f"ALTER STREAMLIT {name} ADD LIVE VERSION FROM LAST"]


def run(statements: list[str]) -> None:
    sys.path.insert(0, str(ROOT))
    from tools.export_results import connect, explain_connection_error
    try:
        con = connect()
    except Exception as exc:  # noqa: BLE001 -- includes a missing connector
        raise SystemExit(explain_connection_error(exc)) from exc
    try:
        cur = con.cursor()
        for sql in statements:
            print(sql.splitlines()[0][:110])
            cur.execute(sql)
    finally:
        con.close()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--db", type=Path, help="the DuckDB file to ship; default: the one the local app opens")
    p.add_argument("--database", default="AUDIT_APP")
    p.add_argument("--schema", default="PUBLIC")
    p.add_argument("--stage", default="AUDIT_APP_STAGE", help="an internal stage in that schema")
    p.add_argument("--warehouse", default="COMPUTE_WH")
    p.add_argument("--app", default="AUDIT_APP", help="the app's name in that schema")
    p.add_argument("--runtime", choices=("warehouse", "container"), default="warehouse")
    p.add_argument("--pool", default="AUDIT_APP_POOL", help="the compute pool; container runtime only")
    p.add_argument("--run", action="store_true", help="upload and create the app, with the login in .env")
    p.add_argument("--setup", action="store_true", help="with --run: first create what setup.sql lists")
    args = p.parse_args()

    db = args.db or default_db()
    check_db(db)
    stage = f"{args.database}.{args.schema}.{args.stage}"
    name = f"{args.database}.{args.schema}.{args.app}"
    bundle = build(db, args.runtime)
    setup = setup_statements(args.database, args.schema, stage, args.runtime, args.pool)
    upload = upload_statements(bundle, stage)
    create = create_statements(stage, args.warehouse, name, args.runtime, args.pool)
    (OUT / "setup.sql").write_text(";\n".join(setup) + ";\n", encoding="utf-8")
    (OUT / "upload.sql").write_text(";\n".join(upload) + ";\n", encoding="utf-8")
    (OUT / "create_app.sql").write_text(";\n\n".join(create) + ";\n", encoding="utf-8")
    size = sum(f.stat().st_size for f in bundle.rglob("*") if f.is_file()) / 1048576
    print(f"database: {db}\n{bundle} ({size:.0f} MB)")
    print(f"{OUT / 'setup.sql'} (optional)\n{OUT / 'upload.sql'}\n{OUT / 'create_app.sql'}")
    if args.run:
        run((setup if args.setup else []) + upload + create)
        print(f"Created {name}. Open it in Snowsight under Projects > Streamlit.")


if __name__ == "__main__":
    main()
