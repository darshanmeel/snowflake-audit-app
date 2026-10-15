"""app/core/reasons.py

Why a check could not run, in one vocabulary shared by the export, --validate and the API:

    classify_error(message, code)  -> "no_access" | "view_missing" | "timeout" | "edition_too_low" | "sql_error"
    grant_for(source)              the one GRANT (or note) that opens a source: "ACCOUNT_USAGE.QUERY_HISTORY",
                                   "SHOW WAREHOUSES", "TRUST_CENTER.FINDINGS"
    grants_for(sources)            the distinct GRANT lines for a list of sources
    needs_enterprise(requires, empty_if)
    EDITION_RANK / edition_at_least(edition, minimum)

A grant line names `<audit_role>`; the README uses AUDIT_ROLE for the same role. Stdlib only.
"""
from __future__ import annotations

import re

ROLE = "<audit_role>"

# Snowflake error numbers: 2003 object does not exist or not authorized, 3001 insufficient privileges,
# 2043 object does not exist or operation cannot be performed.
NO_ACCESS_CODES = {"2003", "3001", "2043", "2014"}
# 630: statement reached its timeout.
TIMEOUT_CODES = {"630"}

_NO_ACCESS_RE = re.compile(
    r"does not exist or not authorized|insufficient privileges|not authorized|access denied"
    r"|permission|forbidden|not allowed to",
    re.I,
)
_VIEW_MISSING_RE = re.compile(r"does not exist|no such (view|table)|unknown (table|view)|not found", re.I)
_TIMEOUT_RE = re.compile(r"timed?\s?out|timeout|statement reached its", re.I)
_EDITION_RE = re.compile(r"edition|enterprise|not supported (for|in) (this|your) account", re.I)


def classify_error(message: str | None, code: str | int | None = None) -> str:
    """One export or validate error -> the cause a reader can act on. `sql_error` is a real fault in the
    statement (or an unrecognised one); every other value means the source could not be read."""
    text = message or ""
    code = str(code) if code else ""
    if code in TIMEOUT_CODES or _TIMEOUT_RE.search(text):
        return "timeout"
    if _EDITION_RE.search(text) and not _NO_ACCESS_RE.search(text):
        return "edition_too_low"
    if code in NO_ACCESS_CODES or _NO_ACCESS_RE.search(text):
        return "no_access"
    if _VIEW_MISSING_RE.search(text):
        return "view_missing"
    return "sql_error"


EDITION_RANK = {"STANDARD": 1, "ENTERPRISE": 2, "BUSINESS_CRITICAL": 3, "VIRTUAL_PRIVATE_SNOWFLAKE": 4}


def normalise_edition(value: str | None) -> str | None:
    """'Business Critical' / 'BUSINESS_CRITICAL' -> 'BUSINESS_CRITICAL'; None when it names no edition."""
    text = re.sub(r"[\s-]+", "_", str(value or "").strip().upper())
    if text in ("VPS", "VIRTUAL_PRIVATE_SNOWFLAKE"):
        return "VIRTUAL_PRIVATE_SNOWFLAKE"
    return text if text in EDITION_RANK else None


def edition_at_least(edition: str | None, minimum: str) -> bool | None:
    """True/False when the edition is known, None when it is not."""
    known = normalise_edition(edition)
    if known is None:
        return None
    return EDITION_RANK[known] >= EDITION_RANK[minimum]


def needs_enterprise(requires: str | None, empty_if: list | None = None) -> bool:
    """A check whose header says it needs Enterprise Edition (in `requires`) or lists edition_too_low."""
    if "edition_too_low" in (empty_if or []):
        return True
    return bool(re.search(r"enterprise", requires or "", re.I))


_ORG_BILLING = {"RATE_SHEET_DAILY", "USAGE_IN_CURRENCY_DAILY", "REMAINING_BALANCE_DAILY", "CONTRACT_ITEMS"}

_SHOW_GRANTS = {
    "WAREHOUSES": f"GRANT MONITOR ON WAREHOUSE <warehouse> TO ROLE {ROLE};  -- one per warehouse; SHOW lists only those",
    "RESOURCE MONITORS": f"GRANT MONITOR ON RESOURCE MONITOR <monitor> TO ROLE {ROLE};  -- one per monitor",
    "TASKS": f"GRANT MONITOR EXECUTION ON ACCOUNT TO ROLE {ROLE};",
    "AUTHENTICATION POLICIES": f"GRANT APPLY AUTHENTICATION POLICY ON ACCOUNT TO ROLE {ROLE};",
    "PASSWORD POLICIES": f"GRANT APPLY PASSWORD POLICY ON ACCOUNT TO ROLE {ROLE};",
    "SNOWFLAKE.CORE.BUDGET INSTANCES": f"GRANT APPLICATION ROLE SNOWFLAKE.BUDGET_VIEWER TO ROLE {ROLE};",
    "SECURITY INTEGRATIONS": f"GRANT USAGE ON INTEGRATION <integration> TO ROLE {ROLE};  -- SHOW lists only integrations the role owns or can use",
    "INTEGRATIONS": f"GRANT USAGE ON INTEGRATION <integration> TO ROLE {ROLE};  -- SHOW lists only integrations the role owns or can use",
}
_IMPORTED = f"GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE {ROLE};"


def grant_for(source: str) -> str | None:
    """The single statement (with a short note where it repeats) that opens `source`, or None when none is known."""
    key = (source or "").strip().upper()
    if key.startswith("SHOW "):
        name = key[5:]
        return _SHOW_GRANTS.get(name, f"Use a role that owns or can MONITOR the objects {key} lists.")
    schema, _, name = key.partition(".")
    if schema == "TRUST_CENTER":
        return f"GRANT APPLICATION ROLE SNOWFLAKE.TRUST_CENTER_VIEWER TO ROLE {ROLE};"
    if schema == "LOCAL":
        return f"GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE {ROLE};"
    if schema == "ORGANIZATION_USAGE":
        role = "ORGANIZATION_BILLING_VIEWER" if name in _ORG_BILLING else "ORGANIZATION_USAGE_VIEWER"
        return (f"GRANT DATABASE ROLE SNOWFLAKE.{role} TO ROLE {ROLE};  "
                f"-- in the organization account: GRANT APPLICATION ROLE SNOWFLAKE.{role} TO ROLE {ROLE};")
    if schema in ("ACCOUNT_USAGE", "READER_ACCOUNT_USAGE", "DATA_SHARING_USAGE"):
        return _IMPORTED
    if schema == "FUNCTION":
        return None
    return _IMPORTED


def grants_for(sources: list[str]) -> list[str]:
    """Distinct grant lines for these sources, in order."""
    out: list[str] = []
    for source in sources:
        line = grant_for(source)
        if line and line not in out:
            out.append(line)
    return out
