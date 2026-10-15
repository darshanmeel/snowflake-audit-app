"""app/core/tag_compliance.py

Mandatory-tag compliance from tags.tag_entity (the tags every object carries, from TAG_REFERENCES) and
the priced units of tags.cost_unit / cost_unit_tag:

    compliance(window_days, keys=None, account_ids=None) -> dict

`keys` (else settings `required_tag_keys`) names the tags every object must carry. With none, the answer
is tag coverage: the most used keys and how many objects of each type carry them (zero config).

Per object type it lists how many objects exist, how many carry the key and which are missing (names,
never bare ids). The spend block prices the gap in $: total billed spend, the part a tag of this key
reaches (a warehouse tag covers its whole warehouse, a query tag its own slice, a real account tag
everything) and the untagged remainder. Warehouse and query tags are the only ones priced; a user, role
or object tag has no $ of its own here. Nothing is ever $0 for a figure that could not be priced.

Object universes: warehouses (dims.dim_warehouse and the priced units), tasks (dims.dim_task), accounts
(dims.dim_account), users and databases (dims.dim_user / dim_database when exported), and the rest of
databases, users and roles from findings.f_sf_chg_tag_coverage. A type with no
known universe reports its tagged objects only (`total` null).
"""
from __future__ import annotations

import duckdb

from app.core import config as app_config
from app.core import data as app_core_data
from app.core import identity as app_identity
from app.core import tag_keys

NOUNS = {"warehouse": "warehouses", "database": "databases", "schema": "schemas", "table": "tables",
         "task": "tasks", "user": "users", "role": "roles", "account": "accounts"}
TYPE_ORDER = ("account", "database", "schema", "table", "warehouse", "task", "user", "role")
EXAMPLES = 10
COVERAGE_KEYS = 10
_COVERAGE_TABLE = "f_sf_chg_tag_coverage"


def _exists(con, schema: str, table: str) -> bool:
    return bool(con.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema = ? AND table_name = ?",
                            [schema, table]).fetchone()[0])


def _display(con, key: str) -> str:
    row = con.execute("SELECT min(raw_key) FROM tags.tag_entity WHERE tag_key = ?", [key]).fetchone()
    return (row[0] if row and row[0] else key)


def _universes(con, window_days: int) -> dict[str, list[tuple[str, str, list[str]]]]:
    """{entity type: [(label, name key, [ids the tag table may know it by])]}."""
    out: dict[str, dict[str, tuple[str, list[str]]]] = {}

    def add(kind: str, name: str | None, label: str | None = None, ids: list[str] | None = None) -> None:
        if not name:
            return
        bucket = out.setdefault(kind, {})
        key = name.lower()
        old = bucket.get(key)
        merged = sorted(set((old[1] if old else []) + [i.lower() for i in (ids or [])] + [key]))
        bucket[key] = (old[0] if old else (label or name), merged)

    if _exists(con, "dims", "dim_warehouse"):
        for wid, name in con.execute("SELECT warehouse_id, warehouse_name FROM dims.dim_warehouse").fetchall():
            add("warehouse", name, f"{name} ({wid})" if wid else name, [str(wid)] if wid else [])
    if _exists(con, "dims", "dim_task"):
        for (name,) in con.execute("SELECT task_full_name FROM dims.dim_task").fetchall():
            add("task", name)
    if _exists(con, "dims", "dim_account"):
        for aid, name in con.execute("SELECT account_id, name FROM dims.dim_account").fetchall():
            add("account", str(aid), f"{name} ({aid})" if name else str(aid), [str(aid)])
    # The full inventories when the export has them; else the spending objects below.
    full = {kind for kind, table in (("user", "dim_user"), ("database", "dim_database")) if _exists(con, "dims", table)}
    if _exists(con, "dims", "dim_user"):
        for name, uid in con.execute("SELECT user_name, user_id FROM dims.dim_user").fetchall():
            add("user", name, None, [str(uid)] if uid else [])
    if _exists(con, "dims", "dim_database"):
        for name, did in con.execute("SELECT database_name, database_id FROM dims.dim_database").fetchall():
            add("database", name, f"{name} ({did})" if did else name, [str(did)] if did else [])
    if _exists(con, "findings", _COVERAGE_TABLE):
        try:
            rows = con.execute(
                f'SELECT DISTINCT lower(object_type), object_name FROM findings."{_COVERAGE_TABLE}" '
                "WHERE window_days = ? AND object_name IS NOT NULL", [window_days]).fetchall()
        except duckdb.Error:
            rows = []
        for kind, name in rows:
            if kind in NOUNS and kind not in ("account", "schema", "table") and kind not in full:
                add(kind, name)
    return {kind: [(label, key, ids) for key, (label, ids) in sorted(bucket.items())] for kind, bucket in out.items()}


def _warehouse_usd(con, window_days: int) -> dict[str, float]:
    if not _exists(con, "tags", "cost_unit"):
        return {}
    return {cid: float(usd or 0) for cid, usd in con.execute(
        "SELECT compute_id, SUM(usd) FROM tags.cost_unit WHERE window_days = ? AND compute_kind = 'warehouse' "
        "GROUP BY compute_id", [window_days]).fetchall()}


def _spend(con, window_days: int, keys: list[str]) -> dict:
    """The $ block: total billed spend and, per key, what a tag of that key reaches."""
    basis = app_core_data.price_basis()
    empty = {"unit": "usd", "total_usd": None, "per_key": [], "reason": None, "price_basis": basis["source_short"],
             "note": None}
    if not _exists(con, "tags", "cost_unit"):
        return {**empty, "reason": "no_cost_data"}
    total, units = con.execute("SELECT SUM(usd), count(*) FROM tags.cost_unit WHERE window_days = ?",
                               [window_days]).fetchone()
    if not units or total is None:
        return {**empty, "reason": "unpriced" if basis["credit_price_usd"] is None else "no_cost_data"}
    discount = app_core_data.effective_discount_pct()
    factor = 1 - discount
    account_tagged = {r[0] for r in con.execute(
        "SELECT tag_key FROM tags.tag_account WHERE source = 'account_tags'").fetchall()} \
        if _exists(con, "tags", "tag_account") else set()
    covered: dict[str, float] = {}
    if keys and _exists(con, "tags", "cost_unit_tag"):
        marks = ", ".join("?" for _ in keys)
        for key, usd in con.execute(f"""
            WITH u AS (SELECT unit_id, usd FROM tags.cost_unit WHERE window_days = ?),
            c AS (SELECT unit_id, tag_key,
                         MAX(CASE WHEN level = 'compute' THEN 1 ELSE 0 END) AS has_compute,
                         SUM(CASE WHEN level = 'work' THEN usd END) AS work_usd
                  FROM tags.cost_unit_tag WHERE window_days = ? AND tag_key IN ({marks}) GROUP BY unit_id, tag_key)
            SELECT c.tag_key, SUM(CASE WHEN c.has_compute = 1 THEN u.usd ELSE LEAST(COALESCE(c.work_usd, 0), u.usd) END)
            FROM c JOIN u ON u.unit_id = c.unit_id GROUP BY c.tag_key""", [window_days, window_days, *keys]).fetchall():
            covered[key] = float(usd or 0)
    per_key = []
    for key in keys:
        whole = key in account_tagged
        cov = float(total) if whole else covered.get(key, 0.0)
        per_key.append({
            "tag_key": key, "display_key": _display(con, key),
            "covered_usd": round(cov * factor, 2), "untagged_usd": round((float(total) - cov) * factor, 2),
            "untagged_pct": round(100 * (float(total) - cov) / float(total), 1) if total else None,
            "covered_by": "account tag" if whole else ("warehouse and query tags" if cov else None),
        })
    return {"unit": "usd", "total_usd": round(float(total) * factor, 2), "per_key": per_key, "reason": None,
            "price_basis": basis["source_short"],
            "note": "Priced spend only: a warehouse tag covers the whole warehouse, a query tag its own slice, an "
                    "account tag everything. User, role and object tags have no $ of their own here."}


def compliance(window_days: int, keys: list[str] | None = None, account_ids: list[str] | None = None) -> dict:
    """See the module docstring. `keys` are raw tag names; matching ignores case, spaces, _ and -."""
    configured = list(keys) if keys else list(app_config.load_settings().get("required_tag_keys") or [])
    base = {"window_days": window_days, "configured_keys": configured,
            "mode": "required" if configured else "coverage", "available": True, "reason": None}
    try:
        con = app_core_data._connect()
    except duckdb.Error as exc:
        return {**base, "available": False, "reason": f"the data file could not be read: {exc}"}
    try:
        if not _exists(con, "tags", "tag_entity"):
            return {**base, "available": False,
                    "reason": "the tag tables were not built: the export needs access to ACCOUNT_USAGE.TAG_REFERENCES "
                              "(Enterprise Edition) and a load after it"}
        where, params = "", []
        if account_ids:
            where = f" AND account_id IN ({', '.join('?' for _ in account_ids)})"
            params = list(account_ids)
        # Which keys are on which objects: {tag_key: {entity type: {entity ids}}}
        seen: dict[str, dict[str, set[str]]] = {}
        raw_names: dict[str, str] = {}
        for etype, key, raw, eid in con.execute(
                f"SELECT entity_type, tag_key, raw_key, lower(entity_id) FROM tags.tag_entity "
                f"WHERE entity_type <> 'query_tag'{where}", params).fetchall():
            seen.setdefault(key, {}).setdefault(etype, set()).add(eid)
            raw_names.setdefault(key, raw)
        query_keys = sorted({r[0] for r in con.execute(
            "SELECT DISTINCT tag_key FROM tags.tag_entity WHERE entity_type = 'query_tag'").fetchall()})
        universes = _universes(con, window_days)
        # Types whose universe is a full inventory, not just the objects that spent.
        complete = {t for t, table in (("warehouse", "dim_warehouse"), ("task", "dim_task"), ("account", "dim_account"),
                                       ("user", "dim_user"), ("database", "dim_database")) if _exists(con, "dims", table)}

        def _carrying(etype: str, ids: set[str]) -> int:
            # Count objects, not tag rows: one object can be known by its id and its name, and a
            # dropped object is not in the universe, so a key never covers more objects than exist.
            members = universes.get(etype)
            if members is None or etype not in complete:
                return len(ids)
            return sum(1 for m in members if ids & set(m[2]))

        keys_seen = []
        for k, by in seen.items():
            by_type = {t: _carrying(t, v) for t, v in sorted(by.items())}
            by_type = {t: n for t, n in by_type.items() if n}
            if by_type:
                keys_seen.append({"tag_key": k, "display_key": raw_names[k], "objects": sum(by_type.values()),
                                  "by_type": by_type})
        keys_seen.sort(key=lambda r: (-r["objects"], r["tag_key"]))
        if configured:
            wanted = []
            for name in configured:
                nk = tag_keys.normalize_tag_key(name)
                if nk and nk not in [w[0] for w in wanted]:
                    wanted.append((nk, raw_names.get(nk, name)))
        else:
            wanted = [(r["tag_key"], r["display_key"]) for r in keys_seen[:COVERAGE_KEYS]]
        wh_usd = _warehouse_usd(con, window_days)
        priced = bool(wh_usd)
        factor = 1 - app_core_data.effective_discount_pct()
        types = [t for t in TYPE_ORDER
                 if t in universes or any(t in by for by in seen.values())]
        object_types = []
        for etype in types:
            members = universes.get(etype)
            entry = {"entity_type": etype, "noun": NOUNS[etype], "total": len(members) if members is not None else None,
                     "universe": None if members is None else "listed", "per_key": []}
            for nk, display in wanted:
                have = seen.get(nk, {}).get(etype, set())
                if members is not None:
                    tagged = [m for m in members if have & set(m[2])]
                    missing = [m for m in members if not (have & set(m[2]))]
                    examples = [app_identity.format_identity(m[0]) if etype == "user" and app_identity.masking_enabled()
                                else m[0] for m in missing[:EXAMPLES]]
                    item = {"tag_key": nk, "display_key": display, "tagged": len(tagged), "missing": len(missing),
                            "coverage_pct": round(100 * len(tagged) / len(members), 1) if members else None,
                            "missing_examples": examples, "missing_usd": None}
                    if etype == "warehouse" and priced:
                        item["missing_usd"] = round(sum(
                            wh_usd.get(next((i for i in m[2] if i in wh_usd), ""), 0.0) for m in missing) * factor, 2)
                else:
                    item = {"tag_key": nk, "display_key": display, "tagged": len(have), "missing": None,
                            "coverage_pct": None, "missing_examples": [], "missing_usd": None}
                entry["per_key"].append(item)
            object_types.append(entry)
        return {
            **base,
            "keys": [{"tag_key": k, "display_key": d} for k, d in wanted],
            "object_types": object_types,
            "keys_seen": keys_seen,
            "query_tag_keys": query_keys,
            "spend": _spend(con, window_days, [k for k, _ in wanted]),
            "notes": ["Where the total shows –, only tagged objects of that type are listed.",
                      "$ is compute plus billed cloud services; the $ missing a tag is the warehouse's own spend."],
        }
    finally:
        con.close()
