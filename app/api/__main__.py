"""python -m app.api -- runs the FastAPI app with uvicorn on 127.0.0.1:8000 (override with
AUDIT_API_HOST / AUDIT_API_PORT). Requires AUDIT_DB to point at a built DuckDB, e.g.
AUDIT_DB=tests/db_audit_test.duckdb for the test fixture."""
from __future__ import annotations

import os
import threading

import uvicorn

from app.core import data as app_core_data


def _warm() -> None:
    """Build the findings list for each window once at start, so the first page doesn't wait for it."""
    try:
        from app.api import service
        from app.core import config as app_config
        info = app_core_data.direct_export_info() or {}
        default = app_config.load_settings()["default_window"]
        for w in [default] + [w for w in (info.get("windows") or []) if w != default]:
            service.list_findings(int(w))
    except Exception:  # noqa: BLE001 -- a warm-up miss only means the first page is slower
        pass


def main() -> None:
    host = os.environ.get("AUDIT_API_HOST", "127.0.0.1")
    port = int(os.environ.get("AUDIT_API_PORT", "8000"))
    print(f"database: {app_core_data._db_path()}")
    # "localhost" tries IPv6 first on Windows and waits ~0.2 s per connection before falling back.
    print(f"open http://{'127.0.0.1' if host in ('127.0.0.1', 'localhost') else host}:{port}")
    app_core_data.share_connection = True
    threading.Thread(target=_warm, daemon=True).start()
    uvicorn.run("app.api.app:app", host=host, port=port, reload=False)


if __name__ == "__main__":
    main()
