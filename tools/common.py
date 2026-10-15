"""Helpers shared by tools/export_results.py and tools/load_results.py."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pyarrow as pa

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import registry as app_registry  # noqa: E402
from app.core.identity import format_identity, is_person_column, mask_value  # noqa: E402

DEFAULT_MAX_ROWS = 50_000
WINDOW_LABELS = (7, 30, 90)

_ALREADY_MASKED_RE = re.compile(r"^\S+ .{0,2}\*\*\*$")


def window_plan(days: int) -> list[tuple[int, int]]:
    """Every window label with the days of history it can use, e.g. 30 -> [(7,7),(30,30),(90,30)]."""
    return [(w, min(w, days)) for w in WINDOW_LABELS]


def window_sources(plan: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """One (label, days) per distinct days value, at the smallest label that has it."""
    first: dict[int, int] = {}
    for label, days in plan:
        first.setdefault(days, label)
    return [(label, days) for days, label in first.items()]


def window_aliases_map(plan: list[tuple[int, int]]) -> dict[int, int]:
    """{alias label: source label} for a label whose rows a smaller label already covers."""
    source = {days: label for label, days in window_sources(plan)}
    return {label: source[days] for label, days in plan if source[days] != label}


def is_windowed(query_id: str) -> bool:
    try:
        return bool(app_registry.by_id(query_id).windowed)
    except KeyError:
        return False


def apply_masking(table: pa.Table) -> pa.Table:
    """Mask user names and emails in person columns (app.core.identity); every other value passes
    through. `grantee` is masked where the row's grantee_type is USER."""
    names = table.column_names
    columns = []
    for field in table.schema:
        col = table.column(field.name)
        is_text = pa.types.is_string(field.type) or pa.types.is_large_string(field.type)
        if is_text and is_person_column(field.name):
            col = pa.array([mask_value(field.name, v) for v in col.to_pylist()], type=field.type)
        elif is_text and field.name.lower() == "grantee" and "grantee_type" in names:
            kinds = table.column("grantee_type").to_pylist()
            col = pa.array([format_identity(v) if v is not None and str(k).upper() == "USER" else v
                            for v, k in zip(col.to_pylist(), kinds)], type=field.type)
        columns.append(col)
    return pa.Table.from_arrays(columns, schema=table.schema)


# Waste and saving columns: a row that is not flagged carries no such $, so a sum over rows never
# counts an OK or NOT_ASSESSED row. A check whose waste-shaped column must keep every row is exempt.
_WASTE_COLUMN_RE = re.compile(r"^(est_)?(wasted|saving)|^(total_)?est_(wasted|saving)|^est_idle_usd", re.I)
KEEPS_UNFLAGGED_WASTE: set[str] = set()


def blank_unflagged_waste(qid: str, table: pa.Table) -> pa.Table:
    """NULL the waste and saving columns on rows whose status is not WARN or CRITICAL."""
    if qid in KEEPS_UNFLAGGED_WASTE or "status" not in table.column_names:
        return table
    flagged = [str(v or "").upper() in ("WARN", "CRITICAL") for v in table.column("status").to_pylist()]
    for name in table.column_names:
        if not _WASTE_COLUMN_RE.search(name):
            continue
        idx = table.column_names.index(name)
        values = [v if keep else None for v, keep in zip(table.column(name).to_pylist(), flagged)]
        table = table.set_column(idx, name, pa.array(values, type=table.schema.field(name).type))
    return table


def git_commit() -> str | None:
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, timeout=5)
    except Exception:  # noqa: BLE001 -- git missing is not fatal, just unrecorded
        return None
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None
