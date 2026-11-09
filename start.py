#!/usr/bin/env python3
"""One command from an unzipped folder to the app in the browser.

    python start.py                 set up, sign in, export 7 days, load, open the app
    python start.py --windows 90    the same with 90 days
    python start.py --refresh       export again even when data is already loaded

First run: makes .venv, installs requirements.txt, and asks for the account, user, role, warehouse
and private key file (blank key = sign in through the browser), saved in the git-ignored .env.
The export reads what the role can see; the rest shows in the app as "the role can't see it".
Later runs open the data already loaded. Stdlib only, so the system Python can run it.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import os
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VENV = ROOT / ".venv"
VENV_PY = VENV / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
DOTENV = ROOT / ".env"
REQS = ROOT / "requirements.txt"
STAMP = VENV / "requirements.sha256"
INNER = "--_in-venv"
# Asked in this order; a blank answer leaves the key out of .env.
PROMPTS = (
    ("SNOWFLAKE_ACCOUNT", "Account (orgname-account_name, or locator.region)", True),
    ("SNOWFLAKE_USER", "User", True),
    ("SNOWFLAKE_ROLE", "Role (blank: the user's default role)", False),
    ("SNOWFLAKE_WAREHOUSE", "Warehouse (blank: the user's default warehouse)", False),
    ("SNOWFLAKE_PRIVATE_KEY_FILE", "Private key file, .p8 (blank: sign in through the browser)", False),
)


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="start.py", description=__doc__.splitlines()[0])
    ap.add_argument("--windows", type=int, default=7, metavar="DAYS", help="days of history to export (7, the fastest)")
    ap.add_argument("--refresh", action="store_true", help="export again even when data is already loaded")
    ap.add_argument("--port", type=int, default=None, help="app port (8000, or the next free one)")
    ap.add_argument("--no-browser", action="store_true", help="don't open the browser")
    ap.add_argument(INNER, action="store_true", help=argparse.SUPPRESS)
    return ap.parse_args(argv)


def setup_venv() -> None:
    """Make .venv and install requirements.txt, again only when requirements.txt changes."""
    if not VENV_PY.exists():
        print("Creating .venv ...", flush=True)
        subprocess.run([sys.executable, "-m", "venv", str(VENV)], check=True)
    want = hashlib.sha256(REQS.read_bytes()).hexdigest()
    if STAMP.exists() and STAMP.read_text(encoding="utf-8").strip() == want:
        return
    print("Installing packages (a few minutes the first time) ...", flush=True)
    subprocess.run([str(VENV_PY), "-m", "pip", "install", "-q", "--disable-pip-version-check", "-r", str(REQS)],
                   check=True, cwd=ROOT)
    STAMP.write_text(want, encoding="utf-8")


def read_env() -> dict[str, str]:
    env = {}
    if DOTENV.exists():
        for raw in DOTENV.read_text(encoding="utf-8-sig").splitlines():
            key, sep, value = raw.strip().removeprefix("export ").partition("=")
            if sep and not key.strip().startswith("#"):
                env[key.strip()] = value.strip().strip("'\"")
    return {**env, **{k: v for k, v in os.environ.items() if k.startswith("SNOWFLAKE_") and v}}


def ask_env() -> dict[str, str]:
    """Ask for the sign-in details .env lacks; never echoes a value back."""
    env = read_env()
    if env.get("SNOWFLAKE_ACCOUNT") and env.get("SNOWFLAKE_USER"):
        return env
    print("\nSign-in details (saved in .env in this folder; edit it any time):")
    new = {}
    for key, label, required in PROMPTS:
        while True:
            value = input(f"  {label}: ").strip().strip("'\"")
            if key == "SNOWFLAKE_PRIVATE_KEY_FILE" and value and not Path(value).expanduser().is_file():
                print("    No file there; try again, or leave blank for the browser.")
                continue
            if value or not required:
                break
        if value:
            new[key] = str(Path(value).expanduser().resolve()) if key == "SNOWFLAKE_PRIVATE_KEY_FILE" else value
    lines = DOTENV.read_text(encoding="utf-8-sig").splitlines() if DOTENV.exists() else []
    lines = [x for x in lines if x.partition("=")[0].strip() not in new]
    DOTENV.write_text("\n".join(lines + [f"{k}={v}" for k, v in new.items()]) + "\n", encoding="utf-8")
    return {**env, **new}


def key_passphrase(env: dict[str, str]) -> dict[str, str]:
    """An encrypted key needs its passphrase: asked each run and kept out of .env."""
    key = env.get("SNOWFLAKE_PRIVATE_KEY_FILE")
    if not key or env.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE"):
        return {}
    try:
        encrypted = "ENCRYPTED" in Path(key).read_text(encoding="utf-8", errors="ignore")[:200]
    except OSError:
        return {}
    return {"SNOWFLAKE_PRIVATE_KEY_PASSPHRASE": getpass.getpass("  Passphrase for the private key: ")} if encrypted else {}


def has_data() -> bool:
    from app.core import datasource
    return bool(os.environ.get("AUDIT_DB")) or datasource.current_db() is not None or datasource.db_path().exists()


def free_port(start: int) -> int:
    for port in range(start, start + 50):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)):
                return port
    raise SystemExit(f"no free port from {start} to {start + 49}; pass --port")


def open_when_up(port: int) -> None:
    for _ in range(120):
        with socket.socket() as s:
            if not s.connect_ex(("127.0.0.1", port)):
                webbrowser.open(f"http://127.0.0.1:{port}/")
                return
        time.sleep(0.5)


def run_inside(args: argparse.Namespace) -> int:
    sys.path.insert(0, str(ROOT))
    if args.refresh or not has_data():
        env = ask_env()
        extra = key_passphrase(env)
        browser = not env.get("SNOWFLAKE_PRIVATE_KEY_FILE") and not env.get("SNOWFLAKE_PASSWORD")
        if browser:
            print("\nBrowser sign-in: one session, so checks run one at a time.")
        cmd = [sys.executable, "tools/first_run.py", "--windows", str(args.windows)] + (["--workers", "1"] if browser else [])
        rc = subprocess.run(cmd, cwd=ROOT, env={**os.environ, **extra}).returncode
        if rc:
            print("\nThe export did not finish; the lines above say why. Fix it and run python start.py --refresh.",
                  file=sys.stderr)
            return rc
    port = args.port or int(os.environ.get("AUDIT_API_PORT") or 0) or free_port(8000)
    print(f"\nThe app is at http://127.0.0.1:{port}/  (Ctrl+C stops it)", flush=True)
    if not args.no_browser:
        threading.Thread(target=open_when_up, args=(port,), daemon=True).start()
    try:
        return subprocess.run([sys.executable, "-m", "app.api"], cwd=ROOT,
                              env={**os.environ, "AUDIT_API_PORT": str(port)}).returncode
    except KeyboardInterrupt:
        return 0


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    args = parse_args(argv)
    if args._in_venv:
        return run_inside(args)
    if sys.version_info < (3, 11):
        print(f"Python 3.11 or newer is needed; this is {sys.version.split()[0]}. "
              "On Windows: py -3.12 start.py", file=sys.stderr)
        return 2
    setup_venv()
    try:
        return subprocess.run([str(VENV_PY), str(Path(__file__).resolve()), INNER, *argv], cwd=ROOT).returncode
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
