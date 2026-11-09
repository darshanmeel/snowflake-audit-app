#!/usr/bin/env python3
"""One command from an unzipped folder to the app in the browser.

    python start.py                 set up, sign in, export 7 days, load, open the app
    python start.py --windows 90    the same with 90 days
    python start.py --refresh       export again even when data is already loaded

First run: makes .venv, installs requirements.txt, and asks for the account, user, role, warehouse
and private key file (blank key = sign in through the browser), saved in the git-ignored .env.
It checks the sign-in before the export, so a typo costs seconds and is asked again.
The export reads what the role can see; the rest shows in the app as "the role can't see it".
Later runs open the data already loaded. Stdlib only, so the system Python can run it.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import os
import re
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


class Stop(Exception):
    """A problem the user can fix: print the message and exit, no traceback."""


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="start.py", description=__doc__.splitlines()[0])
    ap.add_argument("--windows", type=int, default=7, metavar="DAYS", help="days of history to export (7, the fastest)")
    ap.add_argument("--refresh", action="store_true", help="export again even when data is already loaded")
    ap.add_argument("--port", type=int, default=None, help="app port (8000, or the next free one)")
    ap.add_argument("--no-browser", action="store_true", help="don't open the browser")
    ap.add_argument(INNER, action="store_true", help=argparse.SUPPRESS)
    return ap.parse_args(argv)


# ---- stage 1, system Python: the virtual environment ----

def venv_ok() -> bool:
    """A half-made or old .venv (no pip, Python below 3.11, base Python gone) is rebuilt, not reused."""
    if not VENV_PY.exists():
        return False
    probe = subprocess.run([str(VENV_PY), "-c", "import sys, pip; sys.exit(sys.version_info < (3, 11))"],
                           capture_output=True)
    return probe.returncode == 0


def setup_venv() -> None:
    """Make .venv and install requirements.txt, again only when requirements.txt changes."""
    if not venv_ok():
        print("Creating .venv ...", flush=True)
        if subprocess.run([sys.executable, "-m", "venv", "--clear", str(VENV)]).returncode or not venv_ok():
            hint = " On Debian or Ubuntu, install python3-venv first." if sys.platform.startswith("linux") else ""
            raise Stop(f"Could not create .venv with this Python (see above).{hint}")
    want = hashlib.sha256(REQS.read_bytes()).hexdigest()
    if STAMP.exists() and STAMP.read_text(encoding="utf-8").strip() == want:
        return
    print("Installing packages (a few minutes the first time) ...", flush=True)
    if subprocess.run([str(VENV_PY), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(REQS)],
                      cwd=ROOT).returncode:
        raise Stop("pip could not install the packages (see above). Check the network or proxy, then run this again.")
    STAMP.write_text(want, encoding="utf-8")


# ---- stage 2, .venv Python: sign in, export, open ----

def env_lines() -> list[str]:
    if not DOTENV.exists():
        return []
    try:
        return DOTENV.read_text(encoding="utf-8-sig").splitlines()
    except UnicodeDecodeError:
        raise Stop(f"{DOTENV} is not UTF-8. Save it as UTF-8, or delete it to be asked again.") from None


def env_key(line: str) -> str:
    return line.strip().removeprefix("export ").partition("=")[0].strip()


def read_env() -> dict[str, str]:
    """The same reading as the export: the environment first, then the first line of .env per key."""
    env = {k: v for k, v in os.environ.items() if k.startswith("SNOWFLAKE_") and v}
    for raw in env_lines():
        key, sep, value = raw.strip().removeprefix("export ").partition("=")
        key = key.strip()
        if sep and not key.startswith("#") and not env.get(key):
            env[key] = value.strip().strip("'\"")
    return env


def clean_account(value: str) -> str:
    """People paste the URL; the connector wants orgname-account_name or locator.region."""
    value = re.sub(r"^https?://", "", value.strip(), flags=re.I).split("/")[0]
    return re.sub(r"\.snowflakecomputing\.com$", "", value, flags=re.I)


def ask_env(force: bool = False) -> dict[str, str]:
    """Ask for the sign-in details (all of them when force) and save them in .env; never echoes a value."""
    env = read_env()
    if not force and env.get("SNOWFLAKE_ACCOUNT") and env.get("SNOWFLAKE_USER"):
        return env
    print(f"\nSign-in details (saved in {DOTENV}):")
    new = {}
    for key, label, required in PROMPTS:
        while True:
            value = input(f"  {label}: ").strip().strip("'\"")
            if key == "SNOWFLAKE_PRIVATE_KEY_FILE" and value and not Path(value).expanduser().is_file():
                print("    No file there; try again, or leave blank for the browser.")
                continue
            if value or not required:
                break
        if key == "SNOWFLAKE_ACCOUNT":
            value = clean_account(value)
        if key == "SNOWFLAKE_PRIVATE_KEY_FILE" and value:
            value = str(Path(value).expanduser().resolve())
        if value:
            new[key] = value
    # Every asked key is replaced, so a blank answer drops an old or placeholder line too.
    asked = {k for k, _, _ in PROMPTS}
    lines = [x for x in env_lines() if env_key(x) not in asked]
    DOTENV.write_text("\n".join(lines + [f"{k}={v}" for k, v in new.items()]) + "\n", encoding="utf-8")
    for k in asked:
        os.environ.pop(k, None)
    return read_env()


def key_passphrase(env: dict[str, str]) -> None:
    """An encrypted key needs its passphrase: asked each run, kept in memory for the export and Refresh."""
    key = env.get("SNOWFLAKE_PRIVATE_KEY_FILE")
    if not key or env.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE"):
        return
    try:
        encrypted = "ENCRYPTED" in Path(key).read_text(encoding="utf-8", errors="ignore")[:200]
    except OSError:
        return
    if encrypted:
        os.environ["SNOWFLAKE_PRIVATE_KEY_PASSPHRASE"] = getpass.getpass("  Passphrase for the private key: ")


def check_sign_in(env: dict[str, str]) -> str | None:
    """None when the sign-in works and a warehouse is in use, else what went wrong and how to fix it."""
    from tools import export_results as ex
    try:
        conn = ex.connect({**env, **{k: v for k, v in os.environ.items() if k.startswith("SNOWFLAKE_") and v}})
    except Exception as exc:  # noqa: BLE001 - any sign-in failure is reported the same way
        return ex.explain_connection_error(exc)
    try:
        role, warehouse = conn.cursor().execute("SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE()").fetchone()
    finally:
        conn.close()
    if not warehouse:
        return "No warehouse: the user has no default warehouse, or the role can't use the one given. Give a warehouse."
    print(f"Signed in: role {role}, warehouse {warehouse}.", flush=True)
    return None


def db_in_use() -> bool:
    """On Windows the load cannot replace the database while an app still has it open."""
    from app.core import datasource
    path = datasource.db_path()
    if not path.exists():
        return False
    import duckdb
    try:
        duckdb.connect(str(path)).close()
    except Exception:  # noqa: BLE001 - a lock shows up as different error types by version
        return True
    return False


def has_data() -> bool:
    from app.core import datasource
    return bool(os.environ.get("AUDIT_DB")) or datasource.current_db() is not None or datasource.db_path().exists()


def free_port(start: int) -> int:
    """Binding is instant and also refuses ports Windows has reserved, which look free to a connect."""
    for port in range(start, start + 50):
        with socket.socket() as s:
            try:
                s.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise Stop(f"No free port from {start} to {start + 49}; pass --port.")


def open_when_up(port: int) -> None:
    for _ in range(240):
        with socket.socket() as s:
            s.settimeout(0.5)
            if not s.connect_ex(("127.0.0.1", port)):
                webbrowser.open(f"http://127.0.0.1:{port}/")
                return
        time.sleep(0.5)


def export(args: argparse.Namespace) -> int:
    if db_in_use():
        raise Stop("The app is still open on the loaded data. Stop it first (Ctrl+C in its terminal), "
                   "or use Refresh in the app's top bar.")
    env = ask_env()
    while True:
        key_passphrase(env)
        if not env.get("SNOWFLAKE_PRIVATE_KEY_FILE") and not env.get("SNOWFLAKE_PASSWORD"):
            print("\nBrowser sign-in: a browser tab opens to sign in. The checks then run one at a time.", flush=True)
        problem = check_sign_in(env)
        if not problem:
            break
        print(f"\nSign-in failed: {problem}", file=sys.stderr)
        if input("Enter the sign-in details again? [Y/n]: ").strip().lower() in ("n", "no"):
            raise Stop(f"Edit {DOTENV}, or delete it to be asked again, then run python start.py.")
        env = ask_env(force=True)
    cmd = [sys.executable, "tools/first_run.py", "--windows", str(args.windows)]
    rc = subprocess.run(cmd, cwd=ROOT, env={**os.environ, "AUDIT_FROM_START": "1"}).returncode
    if rc:
        old = " The data loaded before is still there: python start.py opens it." if has_data() else ""
        print(f"\nThe export did not finish; the lines above say why. The sign-in details are in {DOTENV}. "
              f"Fix it and run python start.py --refresh.{old}", file=sys.stderr)
    return rc


def run_inside(args: argparse.Namespace) -> int:
    sys.path.insert(0, str(ROOT))
    if args.refresh or not has_data():
        rc = export(args)
        if rc:
            return rc
    else:
        key_passphrase(read_env())  # so Refresh in the app can sign in with an encrypted key
    port = args.port or int(os.environ.get("AUDIT_API_PORT") or 0) or free_port(8000)
    print(f"\nThe app is at http://127.0.0.1:{port}/  (Ctrl+C stops it)", flush=True)
    if not args.no_browser:
        threading.Thread(target=open_when_up, args=(port,), daemon=True).start()
    return subprocess.run([sys.executable, "-m", "app.api"], cwd=ROOT,
                          env={**os.environ, "AUDIT_API_PORT": str(port)}).returncode


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    args = parse_args(argv)
    try:
        if args._in_venv:
            return run_inside(args)
        if sys.version_info < (3, 11):
            raise Stop(f"Python 3.11 or newer is needed; this is {sys.version.split()[0]}. "
                       "Windows: py -3.12 start.py; macOS and Linux: python3.12 start.py")
        setup_venv()
        return subprocess.run([str(VENV_PY), str(Path(__file__).resolve()), INNER, *argv], cwd=ROOT).returncode
    except Stop as exc:
        print(f"\n{exc}", file=sys.stderr)
        return 2
    except (KeyboardInterrupt, EOFError):
        print("\nStopped.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
