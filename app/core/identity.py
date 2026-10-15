"""app/core/identity.py -- the identity display format for user names and emails.

Masking is optional (off by default): masking_enabled() reads config/settings.yml's
privacy.mask_user_identities; app/core/data.py's readers and tools/common.py's export masking call
format_identity below. Only person columns are masked here, on screen. Other kinds of names are
masked in the export, before any file is written (app/core/masking.py, privacy.mask_fields).

    "<id> <first 2 chars>***"   where <id> is real_id when given, else the first 8 hex characters
                                of sha256(lower(trim(value)))

Only ASCII space is trimmed, so the same identity always hashes to the same code. A value already
in the masked shape is returned unchanged (masking twice would hash the mask itself).
"""
from __future__ import annotations

import hashlib
import re

from app.core import config as app_config

# Person columns: a user name or an email, or a list of them. Never a resource name (warehouse,
# database, schema, table, role, task, account), an owner role, an id or a user type.
_PERSON_COLUMN_RE = re.compile(
    r"^(?:(?:[a-z0-9]+_)*user_name|login_name|executed_by|actor|email|top_user|requester|identity_run_as"
    r"|principal|resized_by|created_by|users|sample_users|blocked_users)$",
    re.IGNORECASE,
)
_LIST_COLUMN_RE = re.compile(r"^(?:users|sample_users|blocked_users)$", re.IGNORECASE)

# A value already in this shape (e.g. read back out of a dim the export masked) is never re-hashed.
_MASKED_RE = re.compile(r"^\S+ .{0,2}\*\*\*$")


# "(warehouse idle)", "(unknown user)", "(untagged)": a placeholder, not a person, is never hashed.
_PLACEHOLDER_RE = re.compile(r"^\(.*\)$")


def masking_enabled() -> bool:
    """config/settings.yml's `privacy.mask_user_identities`; off by default."""
    return bool(app_config.load_settings().get("privacy", {}).get("mask_user_identities", False))


def format_identity(value, real_id=None):
    """Mask one identity string to "<id> <first 2 chars>***".

    None (or NaN) stays None; a value already in the masked shape is returned unchanged;
    otherwise <id> is real_id when given (an empty string counts as a value), else the first 8 hex
    characters of sha256(lower(trim(value)))."""
    if value is None:
        return None
    if isinstance(value, float) and value != value:  # NaN != NaN
        return None
    text = value if isinstance(value, str) else str(value)
    if _MASKED_RE.match(text) or _PLACEHOLDER_RE.match(text):
        return text
    if real_id is not None:
        id_part = str(real_id)
    else:
        id_part = hashlib.sha256(text.strip(" ").lower().encode("utf-8")).hexdigest()[:8]
    return f"{id_part} {text[:2]}***"


def is_person_column(name: str) -> bool:
    """True for a column that holds user names or emails (masked when masking is on)."""
    return bool(_PERSON_COLUMN_RE.match(name or ""))


def mask_value(column: str, value):
    """One cell of a person column masked; a list column ("a, b, c") is masked name by name.
    A column that is not a person column is returned unchanged."""
    if not is_person_column(column) or value is None or (isinstance(value, float) and value != value):
        return value
    if isinstance(value, str) and _LIST_COLUMN_RE.match(column):
        return ", ".join(format_identity(part) for part in value.split(", ") if part != "")
    return format_identity(value)


def mask_dataframe(df):
    """A copy of df with every person column masked (and `grantee` where grantee_type is USER); the
    frame is returned untouched when masking is off or no column is a person column."""
    if not masking_enabled():
        return df
    person = [c for c in df.columns if is_person_column(c)]
    user_grantee = [c for c in df.columns if str(c).lower() == "grantee"] if "grantee_type" in df.columns else []
    if not person and not user_grantee:
        return df
    out = df.copy()
    for col in person:
        out[col] = [mask_value(col, v) for v in df[col]]
    for col in user_grantee:
        is_user = df["grantee_type"].astype(str).str.upper() == "USER"
        out[col] = [format_identity(v) if u and v is not None else v for v, u in zip(df[col], is_user)]
    return out


def mask_group_key(group_cols, key):
    """An aggregate group key (one value per group column) with person columns masked."""
    if key is None or not masking_enabled():
        return key
    return [mask_value(col, val) for col, val in zip(group_cols, key)]
