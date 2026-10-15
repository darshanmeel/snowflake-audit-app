"""Tests for app/core/registry.py: the Snowflake checks, what they read, and where the docs link goes."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.core import registry
from app.core import snowflake_docs

ROOT = Path(__file__).resolve().parent.parent
CHECKS_DIR = ROOT / "app" / "queries" / "checks"
EXPECTED_CHECKS = 279


def test_registry_holds_unique_checks():
    specs = registry.load_registry()
    assert len(specs) == EXPECTED_CHECKS
    assert len({s.query_id for s in specs}) == EXPECTED_CHECKS
    assert {s.origin for s in specs} == {"checks"}


def test_registry_matches_the_sql_files_and_the_manifest():
    ids = {s.query_id for s in registry.load_registry()}
    assert ids == {p.stem for p in CHECKS_DIR.glob("*.sql")}
    manifest = json.loads(registry.MANIFEST_PATH.read_text(encoding="utf-8"))
    assert ids == {e["query_id"] for entries in manifest.values() for e in entries}


def test_every_check_is_runnable_and_executable():
    assert all(s.runnable and s.executable for s in registry.load_registry())


def test_every_read_is_in_the_source_contract():
    checked = 0
    for s in registry.load_registry():
        assert s.reads and len(s.sources) == len(s.reads), s.query_id
        for read, (schema, name) in zip(s.reads, s.sources):
            assert registry.parse_source(read) == (schema, name), s.query_id
            assert schema in registry.SOURCE_CONTRACT, f"{s.query_id}: unknown schema {schema!r}"
            assert name in registry.SOURCE_CONTRACT[schema], f"{s.query_id}: {schema}.{name} not in SOURCE_CONTRACT"
            checked += 1
    assert checked >= EXPECTED_CHECKS


@pytest.mark.parametrize("bad", [
    "SNOWFLAKE.ACCOUNT_USAGE.NOT_A_VIEW",          # a view outside the contract
    "SNOWFLAKE.SOMEWHERE_ELSE.QUERY_HISTORY",      # a schema outside the contract
    "SHOW SOMETHING",                              # a SHOW command outside the contract
    "system.billing.usage",                        # the Databricks spelling
])
def test_a_read_outside_the_contract_is_refused(bad):
    with pytest.raises(registry.RegistryError):
        registry.parse_source(bad)


@pytest.mark.parametrize("read,pair", [
    ("SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY", ("ACCOUNT_USAGE", "QUERY_HISTORY")),
    ("SHOW WAREHOUSES", ("SHOW", "WAREHOUSES")),
    ("SHOW PARAMETERS LIKE 'X' IN ACCOUNT", ("SHOW", "PARAMETERS")),
    ("SYSTEM$CLIENT_VERSION_INFO()", ("FUNCTION", "SYSTEM$CLIENT_VERSION_INFO")),
])
def test_parse_source_shapes(read, pair):
    assert registry.parse_source(read) == pair


def test_every_learn_url_is_a_snowflake_docs_page():
    for s in registry.load_registry():
        assert s.learn_url.startswith("https://docs.snowflake.com/"), (s.query_id, s.learn_url)


def test_every_docs_entry_is_a_snowflake_docs_page_for_a_contract_source():
    docs = snowflake_docs.load_docs()
    assert docs
    for key, doc in docs.items():
        schema, name = key.split(".", 1)
        assert name in registry.SOURCE_CONTRACT.get(schema, set()), key
        assert doc.url.startswith("https://docs.snowflake.com/"), key


def test_every_next_token_resolves():
    # No check names a follow-up yet; the registry refuses a dangling one at load time.
    ids = {s.query_id for s in registry.load_registry()}
    for s in registry.load_registry():
        for n in s.next:
            assert n["query_id"] in ids, f"{s.query_id}: next target {n['query_id']!r} unresolved"


def test_is_finding_needs_a_status_column_and_a_healthy_line():
    specs = registry.load_registry()
    findings = {s.query_id for s in specs if s.is_finding}
    inventories = {s.query_id for s in specs if s.healthy.strip().lower().startswith("n/a -")}
    assert findings and inventories and findings.isdisjoint(inventories)
    for s in specs:
        if s.is_finding:
            assert "AS status" in s.body or "as status" in s.body.lower(), s.query_id
    # Every check that is neither is one whose SQL has no status column (nothing to band).
    for s in specs:
        if s.query_id not in findings and s.query_id not in inventories:
            assert "as status" not in s.body.lower(), s.query_id


def test_a_known_finding_and_a_known_inventory():
    assert registry.by_id("sf_wh_idle_minutes").is_finding is True
    assert registry.by_id("access_grants_inventory").is_finding is False


def test_by_id_raises_keyerror_for_unknown_id():
    with pytest.raises(KeyError):
        registry.by_id("this_query_id_does_not_exist")


def test_body_strips_header_and_trailing_semicolon():
    for s in registry.load_registry():
        assert s.body and not s.body.startswith("--"), s.query_id
        assert not s.body.rstrip().endswith(";"), s.query_id


def test_windowed_true_iff_period_days_param_present():
    for s in registry.load_registry():
        assert s.windowed == any(p["name"] == "period_days" for p in s.params), s.query_id


def test_path_shape():
    spec = registry.by_id("cost_chargeback_by_warehouse")
    assert spec.path == "app/queries/checks/cost_chargeback_by_warehouse.sql"
    assert (ROOT / spec.path).exists()


def test_caveats_parsed_from_the_sql_file():
    spec = registry.by_id("cost_chargeback_by_warehouse")
    assert spec.caveats
    text = (ROOT / spec.path).read_text(encoding="utf-8")
    assert any(line.startswith("-- caveats:") for line in text.splitlines())


def test_pre_statements_are_show_statements_the_contract_allows():
    with_pre = [s for s in registry.load_registry() if s.pre]
    assert with_pre
    for s in with_pre:
        for stmt in s.pre:
            assert stmt.upper().startswith("SHOW "), (s.query_id, stmt)
            registry.parse_source(stmt)


def test_not_assessed_reasons_are_code_to_words():
    have = [s for s in registry.load_registry() if s.not_assessed_reasons]
    assert have
    for s in have:
        for code, words in s.not_assessed_reasons.items():
            assert code and words, s.query_id
