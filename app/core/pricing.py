"""app/core/pricing.py

apply(df, discount_pct) -- adds a "<col>_disc" column for every money column of `df` that is a
dollar figure at the list credit price (see _LIST_COL_RE), leaving every `*_share` / `*_pct` column
and every other column untouched. Every such figure a finding table carries is credits times the
account's effective USD per credit until this function multiplies it by (1 - discount_pct) to
produce a what-if estimate; the "what-if: ..." label text belongs to app/api/service.py.

The organization checks carry amounts in the invoice currency instead (`amount`, `invoice_amount`,
`est_cost`, `prepaid_balance`, ...): those are money too (is_money) but are never discounted and
never added across currencies, so they are labelled by what they are (own_basis_label).

app/core/data.py returns raw finding rows; pages call pricing.apply on the DataFrame they get
back -- data.py itself never calls this.

Stdlib + pandas only.
"""
from __future__ import annotations

import re

import pandas as pd

# A list-price dollar column: est_usd_list, est_compute_usd_list, est_storage_usd_month, est_usd_per_gb,
# net_list_cost(_usd), usd, cur_usd, usd_list, usd_per_tb, po_upkeep_usd_window,
# projected_usd_month_in_30d. Never a share or
# percentage (est_usd_list_share) and never a price or budget the account set (app_credit_price_usd,
# monthly_budget_usd), and never a plain credits column.
_LIST_COL_RE = re.compile(
    r"^(?!app_credit_price_usd$|monthly_budget_usd$)(?!.*_(?:share|pct)$)"
    r"(?:est_[a-z0-9_]*usd[a-z0-9_]*|(?:[a-z0-9_]+_)?usd(?:_list|_month(?:_in_[0-9]+d)?|_window|_per_[a-z0-9_]+)?"
    r"|net_list_cost(?:_usd)?)$"
)

# An amount in the invoice currency (organization billing views): amount, prev_amount, change_amount,
# invoice_amount, storage_amount, est_cost, est_billed_cs_amount, prepaid_balance, on_demand_balance,
# daily_burn, projected_unused, usage_in_currency. A rate (amount_per_credit, *_rate) is not one.
_CURRENCY_COL_RE = re.compile(
    r"^(?!.*_(?:share|pct|per_[a-z0-9]+|rate)$)"
    r"(?:(?:[a-z0-9]+_)*amount|(?:prev_)?est_cost|est_billed_cs_amount|prepaid_balance|on_demand_balance"
    r"|daily_burn|projected_unused|usage_in_currency)$"
)

# The columns that say which currency a row's amounts are in.
CURRENCY_COLUMNS = ("currency", "currency_code")

# Money whose basis is NOT the list price: never discounted, labelled by what it is instead.
NON_DISCOUNT_MONEY_LABELS: dict[str, str] = {}
CURRENCY_LABEL = "invoice currency (not discounted)"


def is_list_usd(col: str) -> bool:
    """A list-price dollar column (the ones apply() discounts)."""
    return bool(_LIST_COL_RE.match(col))


def is_currency_amount(col: str) -> bool:
    """An amount in the invoice currency (never discounted, never added across currencies)."""
    return bool(_CURRENCY_COL_RE.match(col))


def is_money(col: str) -> bool:
    return is_list_usd(col) or is_currency_amount(col) or col in NON_DISCOUNT_MONEY_LABELS


def own_basis_label(col: str) -> str | None:
    """The label of a money column that is not the list price, or None."""
    if col in NON_DISCOUNT_MONEY_LABELS:
        return NON_DISCOUNT_MONEY_LABELS[col]
    if is_currency_amount(col) and not is_list_usd(col):
        return CURRENCY_LABEL
    return None


def apply(df: pd.DataFrame, discount_pct: float) -> pd.DataFrame:
    """Return a copy of df with a "<col>_disc" column added for every list-price column
    (col * (1 - discount_pct); discount_pct is a fraction, e.g. 0.15
    for 15% off list). Every other column, including any `*_share` column and every invoice-currency
    amount, is copied through unchanged -- never duplicated, never scaled."""
    out = df.copy()
    for col in df.columns:
        if _LIST_COL_RE.match(col):
            out[f"{col}_disc"] = df[col] * (1 - discount_pct)
    return out
