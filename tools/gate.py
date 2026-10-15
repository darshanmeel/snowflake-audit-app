#!/usr/bin/env python3
"""The gate: everything that must pass before a change is done.

    python tools/gate.py

Runs, in order, and stops nothing early (every step reports):
    lint_headers, build_manifest --check, check_queries, check_registry_ids, web (tsc + vitest), pytest

web is skipped when npm is not on PATH or web/node_modules is missing (cd web && npm ci): the repo
ships app/web/dist pre-built, and pytest checks it matches the source, so a Python-only checkout
still runs the rest.

Stdlib only.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Line-buffer stdout so this script's own print() calls are flushed before a subprocess we spawn
# next writes to the same file descriptor.
try:
    sys.stdout.reconfigure(line_buffering=True)
except (AttributeError, ValueError):
    pass


def _run(cmd: list[str]) -> int:
    """Run a command from the repo root, streaming its output live, and return the exit code."""
    print(f"$ {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd, cwd=ROOT).returncode


def _python_step(name: str, *args: str) -> tuple[str, str]:
    return name, "ok" if _run([sys.executable, *args]) == 0 else "fail"


def _web() -> tuple[str, str]:
    npx = shutil.which("npx")
    if npx is None or not (ROOT / "web" / "node_modules").exists():
        print("skip: npm or web/node_modules missing")
        return "web", "skip"
    # Both run even when the first fails, so one gate run shows every problem.
    codes = [subprocess.run([npx, *cmd], cwd=ROOT / "web").returncode for cmd in (["tsc", "--noEmit"], ["vitest", "run"])]
    return "web", "ok" if not any(codes) else "fail"


def main() -> int:
    steps = [
        _python_step("lint_headers", "tools/lint_headers.py"),
        _python_step("build_manifest", "tools/build_manifest.py", "--check"),
        _python_step("check_queries", "tools/check_queries.py"),
        _python_step("check_registry_ids", "tools/check_registry_ids.py"),
        _web(),
        _python_step("pytest", "-m", "pytest", "-q"),
    ]
    print("gate summary: " + " ".join(f"{name}={status}" for name, status in steps))
    if all(status != "fail" for _, status in steps):
        print("GATE OK")
        return 0
    print("gate failed -- see the failing step's output above", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
