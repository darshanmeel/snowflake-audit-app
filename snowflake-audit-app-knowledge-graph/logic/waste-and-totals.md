# Waste, spend and totals

How the backend computes each check's dollar figure, keeps spend / change / possible waste / savings apart, counts "checks that ran" once, applies one money cut-off, and tells "not assessed" from "nothing found".

## Money pipeline

```mermaid
flowchart TD
  T[findings.f_check table] --> MC{money_column<br/>finding_columns.py:135-152}
  MC -->|none| NOM[money = null]
  MC -->|column, kind| B{kind in FLAGGED_KINDS?<br/>finding_columns.py:55}
  B -->|waste, saving, saving_month, gap| F[SUM over rows whose EFFECTIVE status is CRITICAL or WARN]
  B -->|spend, change, context, balance, spend_month| A[SUM over every row listed]
  F --> X[minus is_total_row and is_alt_basis rows<br/>data.py:1114-1130]
  A --> X
  X --> P{any non-null value?}
  P -->|no, rows exist or no export price| U[usd = null, money_reason unpriced or no_amount<br/>data.py:1159-1169]
  P -->|no rows at all and a price exists| Z[usd = 0.0 real zero<br/>data.py:1170-1171]
  P -->|yes| D[usd = round(raw x (1 - effective discount), 2)<br/>data.py:1175]
  D --> L[/api/findings money/]
  U --> L
  Z --> L
```

## Rules

### 1. One column, one kind per check
- Plain words: a check's headline $ is one column; its kind comes from a fixed map, else "spend" (finding_columns.py:15-51, 128-152).
- Kind priority when several named columns exist: waste, saving, saving_month, gap, change, context, balance, spend, spend_month (finding_columns.py:132).
- Examples (tests/test_waste_contract.py:77-86):
  - `["usd_list"]` -> `("usd_list", "spend")`
  - `["change_usd_list", "usd_list"]` -> `("change_usd_list", "change")`
  - `["est_wasted_usd_list", "est_compute_usd_list"]` -> `("est_wasted_usd_list", "waste")`
  - `["est_idle_context_usd_list"]` -> `"context"` (idle $ already counted as waste elsewhere is never waste again)
  - `["warehouse_name", "status"]` -> None
- `cost_period_over_period` has current, previous and change columns; its headline is the change only, never change + current (tests/test_totals_agree.py:151-165).

### 2. Possible waste = flagged rows only
- Plain words: waste, saving and gap figures add the money column over rows that read CRITICAL or WARN after the materiality floor; every other kind adds every listed row (data.py:1110-1128).
- Example: `sf_wh_idle_minutes`, 30 days, test DB -> list `money.usd = 13827.6`, equal to `/aggregate?agg=sum&value=est_wasted_usd_list&status=WARN&status=CRITICAL` total 13,827.60 (flows/request.md; tests/test_waste_contract.py:103-119).
- Only these waste columns exist: `est_wasted_usd_list`, `total_est_wasted_usd_list`, `wasted_usd`, `est_idle_usd_list` (tests/test_waste_contract.py:58-61).
- `usd_flagged` (flagged share of an all-row figure) is filled only for basis "all" and non-currency units (data.py:1139-1140, 1176-1177).

### 3. Never added together
- No route returns a cross-kind total: `/api/findings` and `/api/meta` have no key with "total", "sum", "waste" or "spend" (tests/test_totals_agree.py:168-172; tests/test_waste_contract.py:137-147).

### 4. Storage tables counted once
- Plain words: five storage checks can price the same table; for each (account, table) the largest $ is kept and the others get `money.overlap_usd`/`overlap_tables` so a total can subtract them (service.py:809-856).
- Example (inferred from code): table T priced 40 by `sf_storage_unused_tables` and 25 by `sf_storage_failsafe_on_staging` -> the failsafe check gets `overlap_usd = 25 x (1 - discount)`, `overlap_tables = 1`.

### 5. Never $0 for something not priced
- Unpriced figure -> `usd: null` with `money_reason: "unpriced"` or `"no_amount"` (data.py:1159-1169).
- A currency amount with no or mixed currency column is never summed as dollars (data.py:1143-1153, 1172-1173).
- Aggregate: if every value is NULL, `total_value` is null, not 0 (data.py:1528-1530); `null_value_rows` says how many rows never entered the sum (data.py:1487-1492).
- `unpriced_rows` counts priced-basis rows with no figure; the checks list shows " · N without a figure" (data.py:1181; web/src/components/checks_list.tsx).
- `overview_spend_estimate` returns NULL total when any line with quantity has no rate (e.g. archive storage), so the Overview total reads "–", never a partial sum (app/queries/checks/overview_spend_estimate.sql).
- A failed check has `money: null`, `affected: null`, and its aggregate has no `total_value` key (tests/test_totals_agree.py:175-180; tests/test_waste_contract.py:150-154).

### 6. Discount what-if
- `effective_discount_pct` = configured `discount_pct`, except 0 when the credit price came from the invoice/rate sheet (already discounted) (data.py:2221-2226).
- Examples (tests/test_api_features.py:239-251): source `usage_in_currency_daily`, configured 0.2 -> effective 0.0, `ignored: true`; source `cli` -> 0.2.
- `/api/findings` money is discounted; `/aggregate` returns raw `total_value` plus `discount_pct` for the caller (app.py:1177-1179). Example: discount 0.25 on a CLI price -> list usd = round(raw x 0.75, 2), aggregate total unchanged (tests/test_totals_agree.py:131-148).

### 7. The same $ on every page
- Five cuts of total spend must be the same number at 7/30/90 days: chargeback by account, by service, period-over-period current, daily spikes (tests/test_totals_agree.py:21-55).
- Account filter partitions the total: filtered total + `excluded_no_account.value` = unfiltered total (tests/test_totals_agree.py:90-98; data.py:1464-1485).

### 8. One "checks that ran" count
- Plain words: a check RAN when the export ran it and at least one row is assessed; independent of window and filters (data.py:2245-2266).
- Same object in `/api/meta.checks_ran`, `/api/findings.checks_ran`, `/api/coverage.checks_ran`, and unchanged at window 7 (tests/test_api_features.py:279-293).
- Example (test DB): 298 checks, `ran = 290`, `not_ran = {build_failed: 2, all_rows_not_assessed: 6}`.

### 9. One money cut-off, today partial
- `cost_cutoff` data.py:2149-2183: `as_of_date` is the first day left out; without today the last complete day is `as_of_date - 1` (capped by `last_complete_day`); with `includes_today`, that day is `partial_day`, and `data_through` is the day before it (also capped by `last_complete_day`), `partial_from` = `data_through + 1`.
- Example (test DB, no today): `as_of 2026-09-21T12:00:00Z` -> `{"data_through": "2026-09-20", "partial_day": null, ...}` (tests/test_totals_agree.py:85-87; tests/test_api.py:306-311).
- Example (inferred from code): `as_of_date 2026-11-11`, `includes_today`, `as_of 2026-11-10T09:30Z`, `last_complete_day 2026-11-08` -> `data_through 2026-11-08`, `partial_from 2026-11-09`, `partial_day 2026-11-10`, `partial_until "09:30"`.
- Served once in `/api/meta.cost_cutoff` (app.py:543-545).

### 10. Windows the export could not fill
- `window_status` per 7/30/90: `available`, `covered_days`, `partial` (data.py:1720-1735); a window never exported reads NOT_ASSESSED `not_exported`, never "nothing in this window" (service.py:212-220, 329-338).
- Example (test DB, 30-day export): 90d -> `{"days": 90, "available": true, "covered_days": 30, "partial": true}`; the 90d total equals the 30d total (tests/test_totals_agree.py:71-82).
- Header `:period_days` reads `30 (the export covered 30 of the 90 days you picked)` at 90d (service.py:185-193; tests/test_api.py:581-586).

## NOT_ASSESSED vs empty

| Outcome | When (service.load_outcome order) | Body extra | Screen |
|---|---|---|---|
| `not_assessed` | run results say failed (service.py:326-327); window not exported (329-338); table missing (343-346); tag tables missing under a tag filter (369-374) | `status_info` with reason | "–" with why |
| `error` | other DuckDB/OS failure (service.py:347-350, 379-382) | `error` | error |
| `ok_empty_window` | the window alone has 0 rows (service.py:354-362) | `window_coverage` | "No data for this in <range>" |
| `ok_empty_filters` | rows exist, filters exclude all (service.py:391-403) | `rows_in_window`, `row_cap`, `excluded_no_account`, `scope.none_flagged` | "No data (filtered)" |
| `ok_rows` | otherwise (service.py:413-425) | rows page, `window_coverage`, `floor`, `truncated` | table |

- `not_built` in run results alone is not treated as bad; the missing table is the evidence (service.py:322-325).
- Fixture examples: `sf_org_dormant_accounts` (no_access) and `sf_obj_iceberg_tables` (view missing) are `not_assessed` at every window (tests/fixtures/build_fixtures.py:46-51; tests/test_api.py:477-488).

## Issues seen

- Rollup tree discount differs from its total: `_build_tree` reads the configured `discount_pct` itself (rollup.py:874-874) while `rollup()` uses `effective_discount_pct` for `total` (rollup.py:545-551, 605). With an invoice-derived price and a non-zero what-if, every tree node's `usd_disc` applies the what-if on top of an already-discounted rate; `total.usd_disc` does not, so the tree and its total disagree.
- On the test DB the rollup's `reconciliation.spend_usd` (26,708.15) is lower than `billing_usd` (27,577.18): `spend_gap_usd = -869.03` (observed via GET /api/rollup?tag_key=cost_center&window=30; fields at rollup.py:682-721). The page text "spend = split + outside_split" does not hold there; cause unclear.
- `/api/meta.checks` carries both `ok` (296 from run results) and `ran` (290) (app.py:548-560). The comment says use `ran` everywhere; a UI reading `ok` would show a second count (no `checks.ok` use found in web/src by grep).
