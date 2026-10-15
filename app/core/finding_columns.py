"""app/core/finding_columns.py

Which of a check's own columns is its headline money figure, and what KIND of money it is (the
screen rule: spend, change, possible waste, savings, context and balances are never added
together) -- and which entity it counts, for /api/findings' bulk `money`/`affected` fields.

A check names its own figures in its header (`-- money:` and `-- entity:`, read through the
registry). A check that names none falls back to the column-name maps below, so a table whose
columns match none of them simply has no money or affected figure.
"""
from __future__ import annotations

from app.core import pricing as app_pricing

# column name -> kind. Any OTHER money-shaped column (app.core.pricing.is_money) reads "spend".
#   waste        possible waste in the window                      counted on flagged rows
#   saving       a saving in the window                            counted on flagged rows
#   saving_month a saving per month (storage)                      counted on flagged rows, never added to window $
#   spend_month  a storage run-rate per month                      counted on all rows, never added to window $
#   context      a share of something counted elsewhere (idle $)   counted on all rows, never waste
#   change       a change against the previous period              counted on all rows
#   gap          a gap against a target or an invoice              counted on flagged rows
#   balance      a contract or prepaid balance                     counted on all rows
#   spend        spend in the window (the rest)                    counted on all rows
MONEY_COLUMN_KIND: dict[str, str] = {
    "est_wasted_usd_list": "waste",
    "total_est_wasted_usd_list": "waste",
    "wasted_usd": "waste",
    "est_idle_usd_list": "waste",
    "est_idle_context_usd_list": "context",
    "est_within_usd_list": "context",
    "est_change_usd_list": "change",
    "change_usd_list": "change",
    "change_amount": "change",
    "excess_amount": "change",
    "est_saving_usd_list": "saving",
    "est_saving_60s_usd_list": "saving",
    "est_saving_300s_usd_list": "saving",
    "saving_usd": "saving",
    "est_saving_usd_month": "saving_month",
    "est_saving_usd_month_if_1_day": "saving_month",
    "est_storage_usd_month": "spend_month",
    "est_history_usd_month": "spend_month",
    "est_failsafe_usd_month": "spend_month",
    "projected_usd_month_in_30d": "spend_month",
    "projected_added_usd_month": "spend_month",
    "gap_usd_list": "gap",
    "prepaid_balance": "balance",
    "on_demand_balance": "balance",
    "projected_unused": "balance",
}

# Which kinds are counted on the flagged (WARN or CRITICAL) rows only; every other kind is the sum
# over every row the table lists, so a tile and the chart under it read the same figure.
FLAGGED_KINDS = frozenset({"waste", "saving", "saving_month", "gap"})
MONEY_KINDS = frozenset(MONEY_COLUMN_KIND.values()) | {"spend"}

# A prior-period column is never a headline figure by itself.
_PRIOR_PREFIXES = ("prev_", "previous_", "est_prev_", "est_previous_")

# A row that ties out its own parts (a total, "ALL CREDITS", a reconciliation line): never summed
# with the rows it totals and never counted as an entity. Set by the check in this column.
TOTAL_ROW_COLUMN = "is_total_row"

# A row that shows the same credits under a second allocation basis (user vs warehouse tag, object
# types that overlap): kept in the table and in entity counts, left out of the money sum so the
# tile never reads twice the bill. Set by the check in this column.
ALT_BASIS_COLUMN = "is_alt_basis"

# id column -> (noun, the dims.dim_<x> table it counts every object of that kind from, or None
# when no dim holds that kind). job_id is what the ported task checks call a task's full name.
ENTITY_COLUMNS: dict[str, tuple[str, str | None]] = {
    "task_full_name": ("tasks", "dim_task"),
    "job_id": ("tasks", "dim_task"),
    "warehouse_id": ("warehouses", "dim_warehouse"),
    "warehouse_name": ("warehouses", None),
    "pipe_name": ("pipes", None),
    "dynamic_table_name": ("dynamic tables", None),
    "table_name": ("tables", None),
    "schema_name": ("schemas", None),
    "database_name": ("databases", "dim_database"),
    "role_name": ("roles", None),
    "user_name": ("users", "dim_user"),
}
# The dim's own key column where it differs from the check's column name.
DIM_KEY_COLUMN: dict[str, str] = {"job_id": "task_full_name"}
# Nouns a dim can count every object of (the column a single-column entity must be to use it).
DIM_NOUNS: dict[str, tuple[str, str]] = {
    "tasks": ("dim_task", "task_full_name"),
    "warehouses": ("dim_warehouse", "warehouse_id"),
    "users": ("dim_user", "user_name"),
    "databases": ("dim_database", "database_name"),
}

# The more specific "thing flagged" first: a task or pipe before the warehouse it runs on, a
# table before its schema and database.
ENTITY_PRIORITY = (
    "task_full_name", "job_id", "pipe_name", "dynamic_table_name", "table_name", "schema_name",
    "database_name", "warehouse_id", "warehouse_name", "role_name", "user_name",
)
# What else names the same object as the entity column (a table is database + schema + table).
_QUALIFIERS: dict[str, tuple[str, ...]] = {
    "table_name": ("database_name", "schema_name"),
    "schema_name": ("database_name",),
}

# A table with no entity id counts its own rows; these column shapes say what one row is.
ROW_NOUNS: tuple[tuple[frozenset[str], str], ...] = (
    (frozenset({"granted_on", "privilege"}), "grants"),
    (frozenset({"securable", "privilege_type"}), "grants"),
    (frozenset({"run_by", "run_as"}), "run-as pairs"),
    (frozenset({"actor", "action_name"}), "actor-action pairs"),
    (frozenset({"principal", "source_ip_address"}), "sign-in patterns"),
    (frozenset({"source_column_name", "target_column_name"}), "column copies"),
    (frozenset({"table_schema", "table_name"}), "tables"),
)


def row_noun(columns) -> str:
    """What one row of a table with no entity id is, or "rows"."""
    cols = set(columns or [])
    for needed, noun in ROW_NOUNS:
        if needed <= cols:
            return noun
    return "rows"


def _kind_of(name: str) -> str:
    return MONEY_COLUMN_KIND.get(name, "spend")


_KIND_PRIORITY = ("waste", "saving", "saving_month", "gap", "change", "context", "balance", "spend", "spend_month")


def money_column(columns, declared: str | None = None) -> tuple[str, str] | None:
    """(column, kind) for this table's headline money figure, or None.

    The column the check declares (`-- money:`) wins when the table has it. Else a column
    MONEY_COLUMN_KIND names explicitly wins; else the highest-priority kind wins; else the first money-shaped column (a list-price dollar
    or an invoice-currency amount, never a prior-period one) reads "spend"."""
    cols = list(columns or [])
    if declared and declared in cols:
        return declared, _kind_of(declared)
    named = [n for n in cols if n in MONEY_COLUMN_KIND]
    if named:
        # By kind, not table order: a storage run-rate never outranks a saving.
        best = min(named, key=lambda n: (_KIND_PRIORITY.index(MONEY_COLUMN_KIND[n]), cols.index(n)))
        return best, MONEY_COLUMN_KIND[best]
    for name in cols:
        if app_pricing.is_money(name) and not name.startswith(_PRIOR_PREFIXES):
            return name, "spend"
    return None


def money_unit(column: str) -> str:
    """"usd" for a list-price dollar column, "currency" for an invoice-currency amount."""
    return "currency" if app_pricing.is_currency_amount(column) and not app_pricing.is_list_usd(column) else "usd"


def currency_column(columns) -> str | None:
    """The column that names the currency of a table's amounts, or None."""
    cols = set(columns or [])
    for name in app_pricing.CURRENCY_COLUMNS:
        if name in cols:
            return name
    return None


def entity_spec(columns, declared: dict | None = None) -> dict | None:
    """The entity a table counts: {"noun", "columns", "dim_table", "dim_key"}, or None.

    `declared` is the check's own `-- entity:` ({"noun", "columns"}) and wins when every column is in
    the table. Else the most specific ENTITY_COLUMNS column, qualified by its database and schema."""
    cols = list(columns or [])
    have = set(cols)
    if declared and declared.get("columns") and set(declared["columns"]) <= have:
        ent_cols = list(declared["columns"])
        noun = declared["noun"]
    else:
        base = next((name for name in ENTITY_PRIORITY if name in have), None)
        if base is None:
            return None
        noun = ENTITY_COLUMNS[base][0]
        ent_cols = [q for q in _QUALIFIERS.get(base, ()) if q in have] + [base]
    dim_table = dim_key = None
    if noun in DIM_NOUNS and len(ent_cols) == 1:
        wanted_table, key = DIM_NOUNS[noun]
        if DIM_KEY_COLUMN.get(ent_cols[0], ent_cols[0]) == key:
            dim_table, dim_key = wanted_table, key
    return {"noun": noun, "columns": ent_cols, "dim_table": dim_table, "dim_key": dim_key}


def entity_column(columns) -> tuple[str, str, str | None] | None:
    """(column, noun, dim_table) of the automatic entity, kept for callers that want one column."""
    spec = entity_spec(columns)
    if spec is None:
        return None
    return spec["columns"][-1], spec["noun"], spec["dim_table"]
