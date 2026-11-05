"""Test app for Streamlit in Snowflake: can the real API and React build run there unchanged?

It answers four questions and prints one report to copy: do the packages install, does the DuckDB
file open, does the React page draw inside a component, and how fast is a request through the bridge.
Each check runs on its own, so one failure still leaves the rest of the report.
"""
from __future__ import annotations

import os
import platform
import re
import sys
import tempfile
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import streamlit as st

HERE = Path(__file__).resolve().parent
DB_FILE = HERE / "db_audit_demo.duckdb"
DIST = HERE / "app" / "web" / "dist" / "assets"
os.environ.setdefault("AUDIT_DB", str(DB_FILE))

# Requests a batch runs at once, the same order of load the browser puts on the local server.
BATCH_WORKERS = 4
KEEP_HEADERS = ("content-type", "content-disposition")


def _check(lines: list[str], name: str, fn) -> None:
    """Run one check and add one line: ok with its result and time, or FAILED with the last error."""
    start = time.perf_counter()
    try:
        detail = fn()
        lines.append(f"ok      {name}: {detail} ({(time.perf_counter() - start) * 1000:.0f} ms)")
    except BaseException as exc:  # noqa: BLE001 -- a failed native import can raise anything
        lines.append(f"FAILED  {name}: {type(exc).__name__}: {exc}")
        lines.extend("        " + x for x in traceback.format_exc().strip().splitlines()[-4:])


def _memory_gb() -> str:
    try:
        kb = re.search(r"MemTotal:\s+(\d+)", Path("/proc/meminfo").read_text()).group(1)
        return f"{int(kb) / 1024 / 1024:.1f} GB"
    except (OSError, AttributeError):
        return "unknown"


def _duckdb_memory() -> str:
    import duckdb
    return f"select returned {duckdb.connect(':memory:').execute('select 42').fetchone()[0]}"


def _duckdb_write() -> str:
    import duckdb
    with tempfile.TemporaryDirectory() as tmp:
        con = duckdb.connect(str(Path(tmp) / "t.duckdb"))
        con.execute("create table t as select 1 as a")
        con.close()
    return "created a file in the temp folder"


def _duckdb_file() -> str:
    import duckdb
    if not DB_FILE.exists():
        raise FileNotFoundError(f"{DB_FILE.name} is not in the app's files")
    con = duckdb.connect(str(DB_FILE), read_only=True)
    try:
        n = con.execute(
            "select count(*) from information_schema.tables where table_schema = 'findings'").fetchone()[0]
    finally:
        con.close()
    return f"{DB_FILE.stat().st_size / 1024 / 1024:.0f} MB file, {n} findings tables"


@st.cache_resource
def api_client():
    """The real FastAPI app, called in the same process, with no port and no network."""
    from fastapi.testclient import TestClient

    from app.api.app import app
    from app.core import data
    data.share_connection = True  # as app/api/__main__.py does
    return TestClient(app, raise_server_exceptions=False)


def _api_get(path: str) -> str:
    res = api_client().get(path)
    if res.status_code != 200:
        raise RuntimeError(f"HTTP {res.status_code}: {res.text[:200]}")
    return f"HTTP 200, {len(res.content)} bytes"


@st.cache_resource
def python_report() -> str:
    """Runs once per server: the checks that need no browser."""
    lines = [
        f"python {sys.version.split()[0]} on {platform.platform()}",
        f"streamlit {st.__version__}, {os.cpu_count()} cpus, memory {_memory_gb()}",
    ]
    for module, dist in (("duckdb", "duckdb"), ("pandas", "pandas"), ("pyarrow", "pyarrow"),
                         ("sqlglot", "sqlglot"), ("yaml", "pyyaml"), ("fastapi", "fastapi"), ("httpx", "httpx")):
        def load(m=module, d=dist) -> str:
            from importlib.metadata import version
            __import__(m)
            return version(d)
        _check(lines, f"install {dist}", load)
    _check(lines, "components v2 available", lambda: str(callable(st.components.v2.component)))
    _check(lines, "duckdb in memory", _duckdb_memory)
    _check(lines, "duckdb writes a temp file", _duckdb_write)
    _check(lines, "duckdb opens the demo file", _duckdb_file)
    _check(lines, "import the API", lambda: bool(api_client()) and "app.api.app loaded")
    _check(lines, "GET /api/status", lambda: _api_get("/api/status"))
    _check(lines, "GET /api/meta", lambda: _api_get("/api/meta"))
    return "\n".join(lines)


def _answer(req: dict) -> dict:
    start = time.perf_counter()
    try:
        res = api_client().request(req["method"], req["path"], content=req.get("body"), headers=req.get("headers"))
        return {"id": req["id"], "status": res.status_code, "body": res.text,
                "headers": {k: res.headers[k] for k in KEEP_HEADERS if k in res.headers},
                "server_ms": (time.perf_counter() - start) * 1000}
    except Exception as exc:  # noqa: BLE001 -- the page gets the error as a failed response
        return {"id": req["id"], "status": 500, "body": f'{{"detail": "{type(exc).__name__}"}}',
                "headers": {"content-type": "application/json"},
                "server_ms": (time.perf_counter() - start) * 1000}


def _on_batch() -> None:
    """Runs before the fragment reruns: answer the page's requests and keep them for the next mount."""
    batch = st.session_state["bridge"].batch
    if not batch:
        return
    with ThreadPoolExecutor(BATCH_WORKERS) as pool:
        responses = list(pool.map(_answer, batch["requests"]))
    st.session_state["bridge_out"] = {"batch_id": batch["id"], "responses": responses}


@st.cache_resource
def component_parts() -> tuple[str, str]:
    """The real React build plus the bridge, as one script. The build runs only when the bridge starts it."""
    bundle = next(DIST.glob("index-*.js")).read_text(encoding="utf-8")
    # Streamlit's own page already uses the id "root", and the build would draw over it.
    bundle = bundle.replace('getElementById("root")', 'getElementById("audit-root")')
    bridge = (HERE / "bridge.js").read_text(encoding="utf-8")
    css = next(DIST.glob("index-*.css")).read_text(encoding="utf-8")
    # The fonts need static files; the test leaves them out, so the page uses fallback fonts.
    css = re.sub(r"@font-face\s*{[^}]*}", "", css)
    # Streamlit reads a one-line string as a file path; a newline inside marks it as inline content.
    return f"function __startReact() {{\n{bundle}\n}}\n{bridge}", f"/* inline */\n{css}"


@st.fragment
def bridge_view(component, checks: str) -> None:
    st.session_state["fragment_runs"] = st.session_state.get("fragment_runs", 0) + 1
    component(
        key="bridge",
        data={"out": st.session_state.get("bridge_out"), "checks": checks,
              "script_runs": st.session_state["script_runs"], "fragment_runs": st.session_state["fragment_runs"]},
        on_batch_change=_on_batch,
    )


st.set_page_config(page_title="Audit app: Snowflake test", layout="wide")
st.session_state["script_runs"] = st.session_state.get("script_runs", 0) + 1
st.title("Audit app: Snowflake test")
st.caption("Wait until the report says DONE, then copy it. If the box below never fills, copy the Python checks instead.")

python_checks = python_report()
with st.expander("Python checks", expanded=False):
    st.code(python_checks, language=None)

try:
    js, css = component_parts()
    html = ('<textarea id="sis-report" rows="24" readonly style="width:100%;font:12px monospace">'
            "The component script has not run yet.</textarea>\n"
            '<div id="audit-root" style="min-height:600px"></div>\n')
    # Not isolated: the build looks up its root in the document, as it does on the local page.
    bridge_component = st.components.v2.component("audit_bridge", html=html, css=css, js=js, isolate_styles=False)
    bridge_view(bridge_component, python_checks)
except Exception as exc:  # noqa: BLE001 -- the Python checks above stay on screen
    st.error(f"The component could not load: {type(exc).__name__}: {exc}")
