"""Refresh from Snowflake: run the export, load it into a new db file, then point the app at it.

A new file each time because the running server holds the current one open; the old file stays
until the next refresh removes it. The credit and storage prices the last export used are passed
on again, so a refresh keeps the dollar figures it had.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

from app.core import datasource

ROOT = Path(__file__).resolve().parent.parent.parent
_lock = threading.Lock()
_state: dict = {"running": False, "step": None, "days": None, "started_at": None,
                "finished_at": None, "error": None}


def status() -> dict:
    s = dict(_state)
    s["elapsed_s"] = round(time.time() - s["started_at"]) if s["running"] and s["started_at"] else None
    return s


def start(days: int) -> dict:
    with _lock:
        if _state["running"]:
            return status()
        _state.update(running=True, step="export", days=days, started_at=time.time(),
                      finished_at=None, error=None)
    threading.Thread(target=_run, args=(days,), daemon=True).start()
    return status()


def _call(args: list[str]) -> None:
    proc = subprocess.run([sys.executable, *args], cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-3:]
        raise RuntimeError(" / ".join(tail) or f"exit code {proc.returncode}")


def _last_prices(base: Path) -> list[str]:
    """--credit-price / --storage-price from the newest results/<stamp>/manifest.json when that run
    took them from the command line, or [] -- a price read from the org billing view is left for the
    export to read again, so it never freezes at the first refresh's value."""
    for folder in datasource.results_folders(base):
        try:
            pricing = json.loads((folder / "manifest.json").read_text(encoding="utf-8")).get("pricing") or {}
        except (OSError, ValueError):
            continue
        args: list[str] = []
        if pricing.get("source") != "cli":
            return args
        if pricing.get("credit_price_usd") is not None:
            args += ["--credit-price", str(pricing["credit_price_usd"])]
        # A storage price read from the invoice is read again; only a typed-in one is passed on.
        if pricing.get("storage_price_usd_tb_month") is not None and pricing.get("storage_source", "cli") == "cli":
            args += ["--storage-price", str(pricing["storage_price_usd_tb_month"])]
        if pricing.get("ai_credit_price_usd") is not None and pricing.get("ai_source") == "cli":
            args += ["--ai-credit-price", str(pricing["ai_credit_price_usd"])]
        return args
    return []


def _run(days: int) -> None:
    stamp = datasource.results_stamp()
    base = datasource.data_dir()
    out = base / "results" / stamp
    db = base / f"audit-{stamp}.duckdb"
    try:
        # No --max-rows: the export's own default, so a Refresh and the CLI cap alike.
        _call(["tools/export_results.py", "--windows", str(days), "--out", str(out), *_last_prices(base)])
        _state["step"] = "load"
        _call(["tools/load_results.py", str(out), "--db", str(db)])
        previous = os.environ.get("AUDIT_DB")
        datasource.set_current_db(db)
        os.environ["AUDIT_DB"] = str(db)
        _remove_old_dbs(base, keep={str(db), previous or ""})
        _remove_old_results(base, keep={out})
        _state.update(running=False, step="done", finished_at=time.time())
    except Exception as exc:  # noqa: BLE001 -- any failure is shown on screen as-is
        _state.update(running=False, step="failed", error=str(exc), finished_at=time.time())


def _remove_old_dbs(base: Path, keep: set[str]) -> None:
    # Files from refreshes before the previous one; the previous is still open by the server.
    for f in base.glob("audit-*.duckdb"):
        if str(f) not in keep:
            try:
                f.unlink()
            except OSError:
                pass


def _remove_old_results(base: Path, keep: set[Path]) -> None:
    # Keep the newest two results/<stamp> folders (this one plus the previous refresh's).
    for p in datasource.results_folders(base)[2:]:
        if p not in keep:
            shutil.rmtree(p, ignore_errors=True)
