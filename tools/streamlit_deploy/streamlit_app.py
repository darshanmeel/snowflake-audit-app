"""The audit app in Streamlit in Snowflake: the same API and React build as the local app.

The browser cannot reach a port on Snowflake's side, so the page's /api/... calls come here through
a Streamlit component, and the API answers them in this process. Warehouse runtime uses a v1 component
in its own frame (frame/, built by deploy.py). Container runtime uses a v2 component.
"""
from __future__ import annotations

import base64
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
import streamlit.components.v1  # noqa: F401 -- st.components.v1 is used below

HERE = Path(__file__).resolve().parent
DB_FILE = HERE / "audit.duckdb"
DIST = HERE / "app" / "web" / "dist" / "assets"
FRAME = HERE / "frame"
os.environ["AUDIT_DB"] = str(DB_FILE)

# Requests a batch runs at once, about what a browser sends the local server at a time.
BATCH_WORKERS = 4
# The client has already decoded the body, and the browser works out its length.
DROP_HEADERS = {"content-length", "content-encoding", "transfer-encoding"}
# Streamlit's own header and margins, so the app fills the page as it does locally.
PAGE_CSS = """
[data-testid="stHeader"], [data-testid="stToolbar"], [data-testid="stDecoration"] { display: none !important; }
[data-testid="stMainBlockContainer"] { padding: 0 !important; max-width: none !important; }
[data-testid="stMain"] [data-testid="stVerticalBlock"] { gap: 0 !important; }
.stApp, [data-testid="stAppViewContainer"], [data-testid="stMain"] { background: transparent !important; }
#audit-diag { font: 12px monospace; padding: 8px 24px; }
#audit-diag pre { white-space: pre-wrap; margin: 4px 0; }
"""
PAGE_HTML = """<div id="audit-root"><div class="loading-note">Loading… If this stays, open Browser checks below this page.</div></div>
<details id="audit-diag"><summary>Browser checks</summary><pre id="audit-browser-checks">The page script has not run. Snowflake's security policy may have blocked it.</pre></details>
"""


def _check(lines: list[str], name: str, fn) -> bool:
    """Run one check and add one line: ok with its result and time, or FAILED with the last error."""
    start = time.perf_counter()
    try:
        detail = fn()
        lines.append(f"ok      {name}: {detail} ({(time.perf_counter() - start) * 1000:.0f} ms)")
        return True
    except BaseException as exc:  # noqa: BLE001 -- a failed native import can raise anything
        lines.append(f"FAILED  {name}: {type(exc).__name__}: {exc}")
        lines.extend("        " + x for x in traceback.format_exc().strip().splitlines()[-4:])
        return False


def _installed(module: str, dist: str) -> str:
    from importlib.metadata import version
    __import__(module)
    return version(dist)


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
    return f"{DB_FILE.stat().st_size / 1048576:.0f} MB file, {n} findings tables"


def _temp_write() -> str:
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "t").write_text("1")
    return "the temp folder is writable"


def _api_get(path: str) -> str:
    res = api_client().get(path)
    if res.status_code != 200:
        raise RuntimeError(f"HTTP {res.status_code}: {res.text[:200]}")
    return f"HTTP 200, {len(res.content)} bytes"


@st.cache_resource
def api_client():
    """The FastAPI app, called in this process with no port and no network."""
    from fastapi.testclient import TestClient

    from app.api.app import app
    from app.core import data
    data.share_connection = True  # as app/api/__main__.py does
    return TestClient(app, raise_server_exceptions=False)


@st.cache_resource
def server_checks() -> tuple[bool, str]:
    """Runs once per server. Shown under the app, and on top of it when one fails."""
    lines = [f"python {sys.version.split()[0]} on {platform.platform()}",
             f"streamlit {st.__version__}, {os.cpu_count()} cpus"]
    results = [_check(lines, f"install {dist}", lambda m=module, d=dist: _installed(m, d))
               for module, dist in (("duckdb", "duckdb"), ("pandas", "pandas"), ("fastapi", "fastapi"),
                                    ("httpx", "httpx"), ("yaml", "pyyaml"))]
    if not FRAME.exists():
        results.append(_check(lines, "components v2", lambda: str(callable(st.components.v2.component))))
    results.append(_check(lines, "temp folder", _temp_write))
    results.append(_check(lines, "open the database", _duckdb_file))
    results.append(_check(lines, "GET /api/status", lambda: _api_get("/api/status")))
    results.append(_check(lines, "GET /api/meta", lambda: _api_get("/api/meta")))
    return all(results), "\n".join(lines)


def _answer(req: dict) -> dict:
    start = time.perf_counter()
    base = {"id": req["id"], "path": req["path"].split("?")[0]}
    # A refresh needs a login and a local export; the page hides it, and this holds for any other caller.
    if req["method"] == "POST" and base["path"] == "/api/refresh":
        return {**base, "status": 409, "body": '{"detail": "Refresh is off in Streamlit in Snowflake."}',
                "headers": {"content-type": "application/json"}, "server_ms": 0}
    try:
        res = api_client().request(req["method"], req["path"], content=req.get("body"), headers=req.get("headers"))
        return {**base, "status": res.status_code, "body": res.text,
                "headers": {k: v for k, v in res.headers.items() if k.lower() not in DROP_HEADERS},
                "server_ms": (time.perf_counter() - start) * 1000}
    except Exception as exc:  # noqa: BLE001 -- the page gets the error as a failed response
        return {**base, "status": 500, "body": f'{{"detail": "{type(exc).__name__}"}}',
                "headers": {"content-type": "application/json"},
                "server_ms": (time.perf_counter() - start) * 1000}


def _on_batch() -> None:
    """Runs before the fragment reruns: answer the page's requests and keep them for the next mount."""
    state = st.session_state["bridge"]
    batch = state if FRAME.exists() else state.batch
    if not batch:
        return
    with ThreadPoolExecutor(BATCH_WORKERS) as pool:
        responses = list(pool.map(_answer, batch["requests"]))
    st.session_state["bridge_out"] = {"batch_id": batch["id"], "responses": responses}


def _inline_fonts(css: str) -> str:
    """The build's fonts are files on the local server. Here they travel inside the stylesheet."""
    def to_data(match: re.Match) -> str:
        data = base64.b64encode((DIST / match.group(1)).read_bytes()).decode("ascii")
        return f"url(data:font/woff2;base64,{data})"
    return re.sub(r"url\(/assets/([^)]+\.woff2)\)", to_data, css)


@st.cache_resource
def component_parts() -> tuple[str, str]:
    """The React build plus the bridge as one script; the build runs only when the bridge starts it."""
    bundle = next(DIST.glob("index-*.js")).read_text(encoding="utf-8")
    bridge = "\n".join((HERE / f).read_text(encoding="utf-8") for f in ("bridge_core.js", "bridge_container.js"))
    css = _inline_fonts(next(DIST.glob("index-*.css")).read_text(encoding="utf-8"))
    # Streamlit reads a one-line string as a file path; a newline inside marks it as inline content.
    return f"function __startReact() {{\n{bundle}\n}}\n{bridge}", f"{PAGE_CSS}\n{css}"


def _brand() -> str:
    from app.core import config
    try:
        return str((config.load_settings().get("brand") or {}).get("name") or "Crosshire")
    except Exception:  # noqa: BLE001 -- a broken settings file still shows the page
        return "Crosshire"


@st.fragment
def app_view(component) -> None:
    # A fragment, so answering a request reruns this and not the whole page.
    out, brand = st.session_state.get("bridge_out"), _brand()
    if FRAME.exists():
        component(out=out, brand=brand, key="bridge", default=None, on_change=_on_batch)
    else:
        component(key="bridge", data={"out": out, "brand": brand}, on_batch_change=_on_batch)


st.set_page_config(page_title="Snowflake audit", layout="wide")
checks_ok, checks = server_checks()
if not checks_ok:
    st.error("The app cannot start here. The failed lines below say why.")
    st.code(checks, language=None)
try:
    if FRAME.exists():
        st.markdown(f"<style>{PAGE_CSS}</style>", unsafe_allow_html=True)
        app_view(st.components.v1.declare_component("audit_app", path=str(FRAME)))
    else:
        js, css = component_parts()
        # Not isolated: the build looks up its root in the document, as it does on the local page.
        app_view(st.components.v2.component("audit_app", html=PAGE_HTML, css=css, js=js, isolate_styles=False))
except Exception as exc:  # noqa: BLE001 -- the checks stay on screen
    st.error(f"The page could not load: {type(exc).__name__}: {exc}")
if checks_ok:
    with st.expander("Server checks"):
        st.code(checks, language=None)
