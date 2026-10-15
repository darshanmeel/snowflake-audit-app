#!/usr/bin/env python3
"""tools/first_run.py -- the one wrapper that turns "get the data" into a single command.

    python tools/first_run.py [--windows 90] [--credit-price 3.0] [--storage-price 23.0]

Runs, in order:

    1. python tools/export_results.py --out <data folder>/results/<stamp> [--windows N]
    2. python tools/load_results.py <data folder>/results/<stamp>

streaming each step's own output live and stopping at the first step that fails, with a message
naming the step. On success it ends by printing the command to open the app (python -m app.api)
and the URL, http://127.0.0.1:8000/.

Credentials: this script never accepts a credential argument, never prints one and never reads
one. tools/export_results.py alone loads them (the SNOWFLAKE_* environment variables, or the
git-ignored .env at the repo root); this script only spawns it and reads its exit code. On exit 2
(its configuration-error code, e.g. a missing credential) it adds one line pointing at
.env.example without repeating the message the exporter already printed.

Exit code: the first failing step's own exit code (2 = configuration error, 1 = connector or load
failure, 130 = interrupted); 0 only when both steps succeeded.

Every path this script touches is resolved from its own file location, and every subprocess runs
with cwd=ROOT, so it works the same from an unpacked zip opened anywhere on disk.

Stdlib only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import datasource  # noqa: E402

try:
    sys.stdout.reconfigure(line_buffering=True)
except (AttributeError, ValueError):
    pass

APP_CMD = "python -m app.api"
APP_URL = "http://127.0.0.1:8000/"

# Any option string containing one of these substrings would let a credential be passed on the
# command line (and end up in shell history or a CI log). Checked at parser-construction time.
_FORBIDDEN_FLAG_SUBSTRINGS = ("token", "password", "secret", "credential")

RunFn = Callable[..., "subprocess.CompletedProcess"]


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="first_run.py",
        description=(
            "Run the first-run pipeline end to end: tools/export_results.py (run the checks on "
            "the account's SNOWFLAKE views) -> tools/load_results.py (build the local DuckDB "
            "file the app reads), stopping at the first step that fails. On success, prints the "
            "command and URL to open the app."
        ),
    )
    ap.add_argument(
        "--windows", type=int, default=None, metavar="DAYS",
        help="days of history to export, passed to tools/export_results.py's own --windows "
             "(default: that tool's own default)",
    )
    ap.add_argument(
        "--credit-price", type=float, default=None, metavar="USD",
        help="USD per credit, for an account whose role cannot read the organization billing view "
             "(or set credit_price_usd in config/settings.yml)",
    )
    ap.add_argument(
        "--ai-credit-price", type=float, default=None, metavar="USD",
        help="USD per AI credit (or set ai_credit_price_usd in config/settings.yml)",
    )
    ap.add_argument(
        "--storage-price", type=float, default=None, metavar="USD",
        help="USD per TB-month of storage (or set storage_price_usd_tb_month in config/settings.yml)",
    )
    for action in ap._actions:  # noqa: SLF001 - a deliberate, tested self-check, not runtime logic
        for opt in action.option_strings:
            lname = opt.lstrip("-").lower()
            if any(bad in lname for bad in _FORBIDDEN_FLAG_SUBSTRINGS):
                raise AssertionError(
                    f"first_run.py must never accept a credential-shaped flag: {opt}"
                )
    return ap


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    return build_parser().parse_args(argv)


def _stamp(now: dt.datetime) -> str:
    return datasource.results_stamp(now)  # the same name Refresh uses, so "newest" is never ambiguous


def export_out_dir(now: dt.datetime) -> Path:
    """A fresh, timestamped folder per run, so an interrupted or superseded export never mixes its
    files with an earlier one under the same path."""
    return datasource.data_dir() / "results" / _stamp(now)


# -------------------------------------------------------------------------------------------
# The two steps' argv
# -------------------------------------------------------------------------------------------
def export_argv(out_dir: Path, args: argparse.Namespace) -> list[str]:
    cmd = [sys.executable, "tools/export_results.py", "--out", str(out_dir)]
    if args.windows is not None:
        cmd += ["--windows", str(args.windows)]
    if args.credit_price is not None:
        cmd += ["--credit-price", str(args.credit_price)]
    if args.ai_credit_price is not None:
        cmd += ["--ai-credit-price", str(args.ai_credit_price)]
    if args.storage_price is not None:
        cmd += ["--storage-price", str(args.storage_price)]
    return cmd


def load_argv(out_dir: Path) -> list[str]:
    return [sys.executable, "tools/load_results.py", str(out_dir)]


# -------------------------------------------------------------------------------------------
# Running and reporting one step
# -------------------------------------------------------------------------------------------
def _stream(cmd: list[str], run: RunFn) -> int:
    print(f"$ {' '.join(cmd)}", flush=True)
    result = run(cmd, cwd=ROOT)
    return result.returncode


def _advise_export_failure(rc: int) -> str:
    if rc == 2:
        return (
            "tools/export_results.py exited 2 (configuration error) -- see its message above. "
            "If it names a missing credential, set SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, "
            "SNOWFLAKE_PRIVATE_KEY_FILE, SNOWFLAKE_ROLE and SNOWFLAKE_WAREHOUSE in your shell, "
            "or copy .env.example to .env at the repo root and fill them in (.env is "
            "git-ignored; never commit or share it)."
        )
    if rc == 130:
        return "tools/export_results.py was interrupted. Re-run this command to start over."
    if rc == 1:
        return (
            "tools/export_results.py exited 1 -- the line above names the error code and the fix "
            "(sign-in, key, role or warehouse). An ImportError or \"DLL load failed\" instead means a "
            f"broken install: re-run \"{sys.executable}\" -m pip install -r requirements.txt."
        )
    return (
        f"tools/export_results.py exited {rc} -- see the error line above (already scrubbed of "
        "secrets). Usually a connector failure: authentication, network, or a warehouse the role "
        "cannot use. An ImportError or \"DLL load failed\" there means a broken install "
        f"instead: re-run \"{sys.executable}\" -m pip install -r requirements.txt."
    )


def _advise_load_failure(rc: int, out_dir: Path) -> str:
    return (
        f"tools/load_results.py exited {rc} -- see the message above. The export at "
        f"{out_dir} is untouched; re-run just the load once the problem is fixed: "
        f"python tools/load_results.py {out_dir}"
    )


# -------------------------------------------------------------------------------------------
# Entry point
# -------------------------------------------------------------------------------------------
def main(
    argv: Sequence[str] | None = None, run: RunFn = subprocess.run, now: dt.datetime | None = None,
) -> int:
    args = parse_args(argv)
    out_dir = export_out_dir(now if now is not None else dt.datetime.now(dt.timezone.utc))

    print(
        "== step 1/2: tools/export_results.py (runs the checks on the account's SNOWFLAKE "
        "views; read-only, can take minutes) ==",
        flush=True,
    )
    rc = _stream(export_argv(out_dir, args), run)
    if rc != 0:
        print(f"\nfirst_run.py: step 1 (tools/export_results.py) failed, exit {rc}.", file=sys.stderr)
        print(_advise_export_failure(rc), file=sys.stderr)
        return rc

    print(
        "\n== step 2/2: tools/load_results.py (builds the local DuckDB file the app reads) ==",
        flush=True,
    )
    rc = _stream(load_argv(out_dir), run)
    if rc != 0:
        print(f"\nfirst_run.py: step 2 (tools/load_results.py) failed, exit {rc}.", file=sys.stderr)
        print(_advise_load_failure(rc, out_dir), file=sys.stderr)
        return rc

    print("\nDone -- open the app:\n", flush=True)
    print(APP_CMD, flush=True)
    print(f"then open {APP_URL} in a browser", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
