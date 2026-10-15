"""tests/test_guide.py: the Guide feed (app/api/guide.py, GET /api/guide) on the fake Snowflake DB.

Every check has a guide page with docs.snowflake.com links, and no Databricks words reach the reader.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.api import guide
from app.api.app import app
from app.core import registry, snowflake_docs
from tools import header_schema

client = TestClient(app)

DOCS_HOST = "https://docs.snowflake.com/"

# Words that mean the text was ported from the Databricks app. Snake_case tokens (check and column
# names) are dropped first: a few check ids are still named after the Databricks check they came from.
DATABRICKS_WORDS = re.compile(
    r"databricks|unity[ -]catalog|\bdbus?\b|\bdbsql\b|\bphoton\b|lakeflow|lakehouse|delta (?:lake|live|table)"
    r"|mlflow|hive metastore|\bsystem\.(?:billing|compute|query|access|lakeflow|storage|serving|marketplace"
    r"|mlflow|information_schema)\b|\bsql warehouses?\b|serverless sql|\bDESCRIBE DETAIL\b",
    re.IGNORECASE,
)
_SNAKE = re.compile(r"\b[a-z0-9]+(?:_[a-z0-9]+)+\b")
PROSE_FIELDS = (
    "title", "summary", "read_this", "healthy", "investigate_if", "actions", "not_assessed_reasons",
    "caveats", "confidence_note", "requires", "first_step", "empty_if_words",
)

# Check headers that still carry Databricks wording. Exact set: a new leak fails, and a fixed header
# must be dropped from here.
KNOWN_DATABRICKS_WORDS: dict[str, str] = {}

# summary_line() problems, measured: the header text does not reduce to one clean "Each row is ..." line.
# Exact set, so a new check that needs a `summary:` header, or a fixed one, is noticed.
KNOWN_SUMMARY_GAPS = frozenset({
    "access_views_inventory",
    "cost_chargeback_by_service",
    "cost_chargeback_by_warehouse", "cost_daily_spikes",
    "cost_period_over_period", "query_costly_statements_grouped", "query_provenance_by_source",
    "sf_acct_budgets", "sf_acct_object_counts", "sf_acct_observability_cost",
    "sf_acct_parameters_posture", "sf_ai_services_spend_trend", "sf_chg_by_warehouse_and_user_daily",
    "sf_chg_dbt_models", "sf_gov_ownership_concentration",
    "sf_gov_sensitive_columns_unprotected", "sf_gov_sensitive_data_access", "sf_govx_admin_role_daily_use",
    "sf_obj_broken_views", "sf_org_daily_spikes_by_account", "sf_org_serverless_by_account",
    "sf_org_spend_by_account_and_service", "sf_query_by_client_application", "sf_query_full_scans",
    "sf_query_large_result_sets", "sf_repl_group_health",
    "sf_sec_admin_role_holders", "sf_sec_network_policy_coverage", "sf_sec_password_service_users",
    "sf_sec_privileged_grant_changes", "sf_sec_security_config_changes", "sf_sec_trust_center_findings",
    "sf_secx_secrets_hygiene", "sf_secx_sso_oauth_integrations", "sf_share_inbound_databases",
    "sf_storage_clone_retained_bytes", "sf_storage_failsafe_on_staging", "sf_use_unused_clones",
})

# First-action ladders whose tier word is not free/config/spend.
KNOWN_FIRST_STEP_NO_TIER = {"sf_secx_login_client_versions": "first action is tagged (engineering)"}


@pytest.fixture(scope="module")
def guide_body() -> dict:
    resp = client.get("/api/guide")
    assert resp.status_code == 200
    return resp.json()


@pytest.fixture(scope="module")
def pages(guide_body) -> dict[str, dict]:
    return {f["query_id"]: f for f in guide_body["findings"]}


def _executable_ids() -> set[str]:
    return {s.query_id for s in registry.load_registry() if s.executable}


# ------------------------------------------------------------------------------------------
# Every check has a page, with docs.snowflake.com links
# ------------------------------------------------------------------------------------------


def test_every_check_has_a_guide_page(pages):
    assert set(pages) == _executable_ids()
    assert len(pages) == sum(1 for s in registry.load_registry() if s.executable)
    for qid, page in pages.items():
        for field in ("title", "domain", "summary", "read_this", "healthy", "investigate_if"):
            assert page[field], f"{qid}.{field} is empty"
        if page["is_finding"]:
            assert page["actions"], qid


def test_every_page_links_to_docs_snowflake_com(pages, guide_body):
    docs = guide_body["docs"]
    for qid, page in pages.items():
        assert page["learn_url"].startswith(DOCS_HOST), (qid, page["learn_url"])
        assert page["reads"], qid
        assert page["docs"], f"{qid} has no docs entry for anything it reads"
        for key in page["docs"]:
            assert docs[key]["url"].startswith(DOCS_HOST), (qid, key)
        # the docs entries are exactly the reads the docs map knows
        expected = [f"{s}.{n}" for s, n in registry.by_id(qid).sources if f"{s}.{n}" in docs]
        assert page["docs"] == expected, qid


def test_guide_docs_map_is_all_docs_snowflake_com(guide_body):
    docs = guide_body["docs"]
    assert docs and set(docs) == set(snowflake_docs.load_docs())
    assert all(d["url"].startswith(DOCS_HOST) and d["title"] for d in docs.values())
    assert not any("databricks" in d["url"].lower() or "microsoft.com" in d["url"].lower() for d in docs.values())


def test_every_read_of_every_check_has_a_docs_entry():
    docs = snowflake_docs.load_docs()
    for s in registry.load_registry():
        for schema, name in s.sources:
            assert f"{schema}.{name}" in docs, f"{s.query_id} reads {schema}.{name}, which has no docs entry"


# ------------------------------------------------------------------------------------------
# No Databricks words
# ------------------------------------------------------------------------------------------


def _databricks_hits(page: dict) -> list[str]:
    blob = _SNAKE.sub(" ", json.dumps({k: page[k] for k in PROSE_FIELDS}))
    return sorted({m.group(0).lower() for m in DATABRICKS_WORDS.finditer(blob)})


def test_guide_prose_has_no_databricks_words_beyond_the_known_headers(pages):
    leaking = {qid for qid, page in pages.items() if _databricks_hits(page)}
    assert leaking == set(KNOWN_DATABRICKS_WORDS)


def test_guide_docs_and_app_section_have_no_databricks_words(guide_body):
    blob = json.dumps({"docs": guide_body["docs"], "app": guide_body["app"]})
    assert not DATABRICKS_WORDS.search(blob)
    assert "databricks" not in blob.lower()


def test_no_check_learn_url_or_reads_names_databricks(pages):
    for qid, page in pages.items():
        assert "databricks" not in (page["learn_url"] + " ".join(page["reads"])).lower(), qid
        assert all(r.startswith(("ACCOUNT_USAGE.", "ORGANIZATION_USAGE.", "READER_ACCOUNT_USAGE.",
                                 "DATA_SHARING_USAGE.", "TRUST_CENTER.", "LOCAL.", "SHOW ", "SYSTEM$")) for r in page["reads"]), qid


# ------------------------------------------------------------------------------------------
# Shape of the feed
# ------------------------------------------------------------------------------------------


def test_guide_app_section(guide_body):
    app_section = guide_body["app"]
    assert app_section["window_options"] == [7, 30, 90]
    assert app_section["columns_available"] is True
    assert app_section["docs_error"] is None
    assert app_section["as_of"] == "2026-09-21T12:00:00Z"
    assert app_section["direct_export"]["account"]["cloud"] == "AWS"
    assert app_section["direct_export"]["window_aliases"] == {"90": "30"}
    assert isinstance(app_section["materiality_floors_configured"], int)
    assert app_section["materiality_floors_configured"] > 0


def test_guide_columns_present_for_loaded_checks(pages):
    for qid, page in pages.items():
        if qid in ("sf_org_dormant_accounts", "sf_obj_iceberg_tables"):  # failed in the export on purpose
            assert page["columns"] is None, qid
            continue
        assert page["columns"], qid
        assert all({"name", "kind"} == set(c) for c in page["columns"]), qid
        assert "window_days" in {c["name"] for c in page["columns"]}, qid


def test_guide_route_matches_build_guide(guide_body):
    direct = guide.build_guide()
    assert [f["query_id"] for f in guide_body["findings"]] == [f["query_id"] for f in direct["findings"]]


def test_build_guide_survives_a_missing_database(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIT_DB", str(tmp_path / "no_such_file.duckdb"))
    data = guide.build_guide()
    assert data["app"]["columns_available"] is False
    assert all(f["columns"] is None for f in data["findings"])
    assert {f["query_id"] for f in data["findings"]} == _executable_ids()


def test_get_guide_survives_a_broken_docs_file(tmp_path, monkeypatch):
    bad = tmp_path / "bad_docs.yml"
    bad.write_text("version: [1, 2\nthis is not valid yaml: [", encoding="utf-8")
    monkeypatch.setattr(snowflake_docs, "_PATH", bad)
    snowflake_docs._CACHE = None
    try:
        body = client.get("/api/guide").json()
        assert body["docs"] == {}
        assert body["app"]["docs_error"]
        assert {f["query_id"] for f in body["findings"]} == _executable_ids()
    finally:
        snowflake_docs._CACHE = None


def test_finding_prose_carries_no_internal_id_or_shouted_bool(pages):
    id_re = re.compile(r"\b(?:DEC|T|P4)-\d+\b")
    for qid, page in pages.items():
        for field in ("read_this", "healthy", "investigate_if", "caveats", "confidence_note"):
            text = page[field] or ""
            assert not id_re.search(text), f"{qid}.{field} carries an id"
            assert "TRUE" not in text and "FALSE" not in text, f"{qid}.{field} shouts TRUE/FALSE"


def test_empty_if_words_match_the_header_vocabulary():
    assert set(guide.EMPTY_IF_WORDS) == header_schema.EMPTY_IF_VOCAB


# ------------------------------------------------------------------------------------------
# summary_line, first_step, period_kind
# ------------------------------------------------------------------------------------------


def test_summary_line_passes_or_is_on_the_known_list():
    failing = set()
    for spec in registry.load_registry():
        result = guide.summary_line(spec)
        assert result["text"], f"{spec.query_id} has an empty summary"
        if result["problems"]:
            failing.add(spec.query_id)
    assert failing == KNOWN_SUMMARY_GAPS


def test_clean_summaries_are_short_and_start_right():
    for spec in registry.load_registry():
        if spec.query_id in KNOWN_SUMMARY_GAPS:
            continue
        result = guide.summary_line(spec)
        assert result["text"].startswith("Each row is"), spec.query_id
        assert len(result["text"]) <= 140, spec.query_id


def test_first_step_shape_for_every_finding():
    for spec in registry.load_registry():
        if not spec.is_finding:
            continue
        step = guide.first_step(guide._substituted(spec)["actions"])
        assert step is not None, f"{spec.query_id} is a finding with no first step"
        assert step["text"] and len(step["text"]) <= 103, spec.query_id
        if spec.query_id in KNOWN_FIRST_STEP_NO_TIER:
            assert step["tier"] is None
        else:
            assert step["tier"] in ("free", "config", "spend"), spec.query_id


def test_first_step_strips_a_trailing_tier_bracket():
    step = guide.first_step(["drop the unused table in the staging schema: it costs storage every day (spend)", "second"])
    assert step["tier"] == "spend"
    assert step["text"] == "drop the unused table in the staging schema"
    assert guide.first_step([]) is None
    assert guide.first_step(["n/a - nothing to do"]) is None


def test_header_params_are_substituted_in_the_guide_text(pages):
    for qid, page in pages.items():
        for field in ("read_this", "healthy", "investigate_if"):
            assert not re.search(r"(?<![\w:]):[a-z_]{3,}\b", page[field]), f"{qid}.{field} shows a :param token"


def test_period_kind_days_for_every_windowed_check_and_fixed_for_the_known_ones():
    specs = [s for s in registry.load_registry() if s.executable]
    assert all(guide.period_kind(s) == "days" for s in specs if s.windowed)
    fixed = {s.query_id for s in specs if not s.windowed and guide.period_kind(s) == "fixed"}
    assert fixed == guide.FIXED_PERIOD_QUERY_IDS


# ------------------------------------------------------------------------------------------
# _clean_prose
# ------------------------------------------------------------------------------------------


def test_clean_prose_drops_lone_parenthetical_id():
    assert guide._clean_prose("Reuses the same join (DEC-66.1) and price_basis CASE.") == (
        "Reuses the same join and price_basis CASE."
    )


def test_clean_prose_drops_inline_id_and_capitalizes():
    out = guide._clean_prose("DEC-66.1 - the effective list price only. rule T-71 established.")
    assert "DEC-66.1" not in out and "T-71" not in out
    assert out == "The effective list price only. Rule established."


def test_clean_prose_double_dash_becomes_em_dash():
    assert guide._clean_prose("it's a snapshot -- not a period") == "It's a snapshot — not a period"


def test_clean_prose_lowers_shouted_bool_but_keeps_column_name_case():
    assert guide._clean_prose("is_partial_month is TRUE only -- never compare.") == (
        "is_partial_month is true only — never compare."
    )


def test_clean_prose_empty_and_none_are_safe():
    assert guide._clean_prose(None) == ""
    assert guide._clean_prose("") == ""


# ------------------------------------------------------------------------------------------
# Concepts, traps, grants, the SQL route, docs links
# ------------------------------------------------------------------------------------------

GUIDE_JSX = (Path(__file__).resolve().parent.parent / "web" / "src" / "components" / "guide.tsx").read_text(encoding="utf-8")


def _block(name: str, opener: str) -> str:
    """The body of `const NAME[: type] = [` (or `{`) in guide.tsx, up to the first `];` (or `};`)."""
    m = re.search(rf"const {name}(?::[^=]+)? = " + re.escape(opener), GUIDE_JSX)
    assert m, name
    return GUIDE_JSX[m.end():].split("];" if opener == "[" else "};", 1)[0]


def _jsx_topic_slugs() -> set[str]:
    block = _block("GUIDE_SECTIONS", "[")
    return set(re.findall(r'slug: "([a-z0-9-]+)"', block))


def test_concept_docs_are_docs_snowflake_com(guide_body):
    concept = guide_body["concept_docs"]
    assert len(concept) >= 20
    assert all(d["url"].startswith(DOCS_HOST) and d["title"] for d in concept.values())


def test_every_concept_key_the_jsx_names_has_a_docs_link(guide_body):
    block = _block("TOPIC_CONCEPT_KEYS", "{")
    used = set(re.findall(r'"([a-z_]+)"', block))
    assert used and used <= set(guide_body["concept_docs"]), used - set(guide_body["concept_docs"])
    assert set(re.findall(r'^\s+"?([a-z-]+)"?:', block, re.M)) <= _jsx_topic_slugs()


def test_every_trap_points_at_a_topic_page(pages):
    slugs = _jsx_topic_slugs()
    alias = {"editions": "visibility", "backups": "upper-bound"}
    for qid, page in pages.items():
        assert "latency" in [tr["concept"] for tr in page["traps"]], qid
        for trap in page["traps"]:
            assert alias.get(trap["concept"], trap["concept"]) in slugs, (qid, trap["concept"])
            assert trap["text"]


def test_required_concept_pages_exist():
    need = {"cloud-services", "attribution", "latency", "failsafe", "pricing", "money-kinds", "visibility", "floors",
            "pressure", "upper-bound", "adaptive", "freshness", "links", "screens"}
    assert need <= _jsx_topic_slugs()


def test_traps_follow_the_source_they_read(pages):
    assert any(t["concept"] == "backups" for t in pages["sf_storage_backup_snapshot"]["traps"])
    assert any(t["concept"] == "adaptive" for t in pages["sf_wh_adaptive_attribution"]["traps"])
    assert any(t["concept"] == "visibility" for t in pages["sf_wh_config_current"]["traps"])
    assert any(t["concept"] == "attribution" for t in pages["sf_cost_query_attribution_by_user"]["traps"])


def test_grants_and_enterprise_flag(pages):
    for qid, page in pages.items():
        assert page["grants"], qid
        assert isinstance(page["needs_enterprise"], bool)
    assert pages["sf_wh_adaptive_attribution"]["needs_enterprise"] is True


def test_dead_docs_links_are_fixed():
    docs = snowflake_docs.load_docs()
    urls = {d.url for d in docs.values()}
    assert not any("/reader-account-usage/" in u or "show-security-integrations" in u or "listing_access_history" in u for u in urls)
    assert docs["DATA_SHARING_USAGE.LISTING_ACCESS_HISTORY"].url.endswith("/listing-access-history")


def test_guide_jsx_reads_the_one_ran_count():
    assert "ranCountsText(meta)" in GUIDE_JSX
    assert "checkRan(findingsById[id])).length" not in GUIDE_JSX


@pytest.fixture(scope="module")
def sql_client() -> TestClient:
    from fastapi import FastAPI
    mini = FastAPI()
    mini.include_router(guide.router)
    return TestClient(mini)


def test_guide_sql_route_returns_every_check_with_params_filled(sql_client):
    bad = []
    for qid in sorted(_executable_ids()):
        body = sql_client.get(f"/api/guide/sql/{qid}").json()
        text = "\n".join([*body["pre"], body["sql"]])
        code = re.sub(r"--[^\n]*", "", text)
        if re.search(r"(?<![:\w]):[a-z_][a-z0-9_]*", code) or "__INCLUDE_" in text or re.search(r"__[A-Z_]+__", code):
            bad.append(qid)
        assert body["sql"].lstrip().upper().startswith(("WITH", "SELECT", "SHOW")), qid
    assert not bad, bad


def test_guide_sql_route_fills_defaults_and_404s(sql_client):
    ok = sql_client.get("/api/guide/sql/cost_daily_spikes").json()
    assert ok["params"]["period_days"] == 30 and ok["params"]["spike_ratio"] == 2.0
    assert "2.0" in ok["sql"]
    assert sql_client.get("/api/guide/sql/no_such_check").status_code == 404



def test_guide_sql_route_is_mounted_on_the_app():
    import app.api.app as api_app
    from app.api import guide as guide_api
    assert any(getattr(r, "original_router", None) is guide_api.router for r in api_app.app.routes)


# ------------------------------------------------------------------------------------------
# UI contracts: the Guide covers every screen, links go through the hash helpers, docs come from data
# ------------------------------------------------------------------------------------------

WEB_SRC = Path(__file__).resolve().parent.parent / "web" / "src"
WEB_FILES = [p for p in WEB_SRC.rglob("*") if p.suffix in (".ts", ".tsx") and "test" not in p.parts]


def test_guide_tabs_cover_every_screen():
    # Every area in the sidebar order but All findings, plus Money (CFO overview) and Tags (own page).
    registry_src = (WEB_SRC / "components" / "tab_registry.tsx").read_text(encoding="utf-8")
    order = re.search(r"export const AREA_ORDER = \[(.*?)\];", registry_src, re.DOTALL)
    assert order, "AREA_ORDER not found"
    expected = (set(re.findall(r'"([a-z]+)"', order.group(1))) - {"findings"}) | {"money", "tags"}
    keys = set(re.findall(r"^  ([a-z_]+):\s*\{", _block("GUIDE_TABS", "{"), re.MULTILINE))
    assert keys == expected


def test_no_raw_hash_tab_href_in_the_ui():
    # A literal href="#tab=..." skips the hash helpers, so it drops the role, window and filters.
    for path in WEB_FILES:
        assert 'href="#tab=' not in path.read_text(encoding="utf-8"), path


def test_no_hard_coded_docs_urls_in_the_ui():
    # Docs links live in config/snowflake_docs.yml and reach the UI through the API.
    for path in WEB_FILES:
        assert "https://docs.snowflake.com" not in path.read_text(encoding="utf-8"), path
