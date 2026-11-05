"""Builds the Streamlit in Snowflake test app's files, and the SQL that uploads and creates it.

    python tools/sis_probe/make_bundle.py --stage AUDIT_TEST.PUBLIC.AUDIT_APP

The output goes to data/sis_probe (git-ignored). Nothing here connects to Snowflake.
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
HERE = Path(__file__).resolve().parent
DEFAULT_DB = ROOT / "data" / "demo" / "db_audit_demo.duckdb"
OUT = ROOT / "data" / "sis_probe"
SIDECARS = ("coverage.json", "run_results.json")


def build(db: Path) -> Path:
    bundle = OUT / "bundle"
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)
    for name in ("streamlit_app.py", "bridge.js", "requirements.txt"):
        shutil.copy2(HERE / name, bundle / name)
    skip = shutil.ignore_patterns("__pycache__", "*.pyc", "settings.local.yml")
    shutil.copytree(ROOT / "app", bundle / "app", ignore=skip)
    shutil.copytree(ROOT / "config", bundle / "config", ignore=skip)
    shutil.copy2(db, bundle / "db_audit_demo.duckdb")
    for sidecar in SIDECARS:
        src = db.with_name(f"{db.stem}.{sidecar}")
        if src.exists():
            shutil.copy2(src, bundle / f"db_audit_demo.{sidecar}")
    return bundle


def upload_sql(bundle: Path, stage: str) -> str:
    """One PUT per folder, because PUT does not go into subfolders."""
    lines = [f"CREATE STAGE IF NOT EXISTS {stage} ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE);"]
    for folder in sorted({p.parent for p in bundle.rglob("*") if p.is_file()}):
        rel = folder.relative_to(bundle).as_posix()
        target = f"@{stage}/app_src" + ("" if rel == "." else f"/{rel}")
        lines.append(f"PUT 'file://{folder.as_posix()}/*' {target} AUTO_COMPRESS=FALSE OVERWRITE=TRUE;")
    return "\n".join(lines) + "\n"


def create_sql(stage: str, warehouse: str, pool: str, name: str) -> str:
    return f"""-- Run as a role with CREATE STREAMLIT on the schema and READ on the stage.
-- Once per account, as ACCOUNTADMIN, if the role cannot use these yet:
--   CREATE COMPUTE POOL IF NOT EXISTS {pool}
--     MIN_NODES = 1 MAX_NODES = 1 INSTANCE_FAMILY = CPU_X64_S AUTO_SUSPEND_SECS = 600;
--   GRANT USAGE, MONITOR ON COMPUTE POOL {pool} TO ROLE <your_role>;
--   GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO ROLE <your_role>;
CREATE OR REPLACE STREAMLIT {name}
  FROM @{stage}/app_src
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = {warehouse}
  RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
  COMPUTE_POOL = {pool}
  ARTIFACT_REPOSITORIES = (snowflake.snowpark.pypi_shared_repository)
  TITLE = 'Audit app test';

ALTER STREAMLIT {name} ADD LIVE VERSION FROM LAST;

-- When you are finished; the compute pool bills while it runs:
--   DROP STREAMLIT {name};
--   ALTER COMPUTE POOL {pool} SUSPEND;
"""


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--stage", default="AUDIT_TEST.PUBLIC.AUDIT_APP", help="database.schema.stage, internal")
    p.add_argument("--warehouse", default="AUDIT_TEST_WH")
    p.add_argument("--pool", default="AUDIT_TEST_POOL")
    p.add_argument("--name", default="AUDIT_TEST.PUBLIC.AUDIT_APP_TEST", help="database.schema.name of the app")
    p.add_argument("--db", type=Path, default=DEFAULT_DB, help="the DuckDB file to ship")
    args = p.parse_args()
    if not args.db.exists():
        raise SystemExit(f"No database at {args.db}. Build the demo with tools/build_demo_db.py or pass --db.")
    bundle = build(args.db)
    (OUT / "upload.sql").write_text(upload_sql(bundle, args.stage), encoding="utf-8")
    (OUT / "create_app.sql").write_text(create_sql(args.stage, args.warehouse, args.pool, args.name), encoding="utf-8")
    size = sum(f.stat().st_size for f in bundle.rglob("*") if f.is_file()) / 1048576
    print(f"{bundle} ({size:.0f} MB)\n{OUT / 'upload.sql'}\n{OUT / 'create_app.sql'}")


if __name__ == "__main__":
    main()
