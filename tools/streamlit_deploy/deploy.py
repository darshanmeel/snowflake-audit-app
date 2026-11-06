"""Deploys the audit app to Streamlit in Snowflake. The local app needs none of this.

    python tools/streamlit_deploy/deploy.py --db PATH --stage DB.SCHEMA.STAGE --warehouse WH --pool POOL --name DB.SCHEMA.APP
    add --run to upload and create it now, with the login in .env; without it, only the files and SQL are written

The output goes to data/streamlit_deploy (git-ignored).
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
HERE = Path(__file__).resolve().parent
DEMO_DB = ROOT / "data" / "demo" / "db_audit_demo.duckdb"
OUT = ROOT / "data" / "streamlit_deploy"
STREAMLIT_CONFIG = '[client]\ntoolbarMode = "minimal"\n\n[browser]\ngatherUsageStats = false\n'


def build(db: Path) -> Path:
    bundle = OUT / "bundle"
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)
    for name in ("streamlit_app.py", "bridge.js", "requirements.txt"):
        shutil.copy2(HERE / name, bundle / name)
    skip = shutil.ignore_patterns("__pycache__", "*.pyc")
    shutil.copytree(ROOT / "app", bundle / "app", ignore=skip)
    # With settings.local.yml, so a setting such as masking user names holds there too.
    shutil.copytree(ROOT / "config", bundle / "config", ignore=skip)
    (bundle / ".streamlit").mkdir()
    (bundle / ".streamlit" / "config.toml").write_text(STREAMLIT_CONFIG, encoding="utf-8")
    shutil.copy2(db, bundle / "audit.duckdb")
    for sidecar in db.parent.glob(f"{db.stem}.*.json"):
        shutil.copy2(sidecar, bundle / f"audit{sidecar.name[len(db.stem):]}")
    return bundle


def upload_statements(bundle: Path, stage: str) -> list[str]:
    """One PUT per folder, because PUT does not go into subfolders."""
    lines = [f"CREATE STAGE IF NOT EXISTS {stage} ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE)"]
    for folder in sorted({p.parent for p in bundle.rglob("*") if p.is_file()}):
        rel = folder.relative_to(bundle).as_posix()
        target = f"@{stage}/app_src" + ("" if rel == "." else f"/{rel}")
        lines.append(f"PUT 'file://{folder.as_posix()}/*' {target} AUTO_COMPRESS=FALSE OVERWRITE=TRUE")
    return lines


def create_statements(stage: str, warehouse: str, pool: str, name: str) -> list[str]:
    return [
        f"""CREATE OR REPLACE STREAMLIT {name}
  FROM @{stage}/app_src
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = {warehouse}
  RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
  COMPUTE_POOL = {pool}
  ARTIFACT_REPOSITORIES = (snowflake.snowpark.pypi_shared_repository)
  TITLE = 'Snowflake audit'""",
        f"ALTER STREAMLIT {name} ADD LIVE VERSION FROM LAST",
    ]


def setup_sql(pool: str) -> str:
    return f"""-- Once per account, as ACCOUNTADMIN, if the deploying role cannot use these yet:
--   CREATE COMPUTE POOL IF NOT EXISTS {pool}
--     MIN_NODES = 1 MAX_NODES = 1 INSTANCE_FAMILY = CPU_X64_S AUTO_SUSPEND_SECS = 600;
--   GRANT USAGE, MONITOR ON COMPUTE POOL {pool} TO ROLE <deploying_role>;
--   GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO ROLE <deploying_role>;
-- The deploying role also needs CREATE STREAMLIT and CREATE STAGE on the schema, and USAGE on the warehouse.
"""


def run(statements: list[str]) -> None:
    sys.path.insert(0, str(ROOT))
    from tools.export_results import connect
    con = connect()
    try:
        cur = con.cursor()
        for sql in statements:
            print(sql.splitlines()[0][:110])
            cur.execute(sql)
    finally:
        con.close()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--db", type=Path, help="the DuckDB file with your export, as AUDIT_DB would name it")
    source.add_argument("--demo", action="store_true", help="ship the demo data instead")
    p.add_argument("--stage", required=True, help="database.schema.stage, internal; created if missing")
    p.add_argument("--warehouse", required=True)
    p.add_argument("--pool", required=True, help="the compute pool")
    p.add_argument("--name", required=True, help="database.schema.name of the app")
    p.add_argument("--run", action="store_true", help="upload and create it now, with the login in .env")
    args = p.parse_args()

    db = DEMO_DB if args.demo else args.db
    if not db.exists():
        raise SystemExit(f"No database at {db}.")
    bundle = build(db)
    upload = upload_statements(bundle, args.stage)
    create = create_statements(args.stage, args.warehouse, args.pool, args.name)
    (OUT / "upload.sql").write_text(";\n".join(upload) + ";\n", encoding="utf-8")
    (OUT / "create_app.sql").write_text(setup_sql(args.pool) + "\n" + ";\n\n".join(create) + ";\n", encoding="utf-8")
    size = sum(f.stat().st_size for f in bundle.rglob("*") if f.is_file()) / 1048576
    print(f"{bundle} ({size:.0f} MB)\n{OUT / 'upload.sql'}\n{OUT / 'create_app.sql'}")
    if args.run:
        run(upload + create)
        print(f"Created {args.name}. Open it in Snowsight under Projects > Streamlit.")


if __name__ == "__main__":
    main()
