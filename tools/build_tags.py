"""Build the tags.* tables the app's Tag and cost-center filters and tag rollup read.

tools/load_results.py calls build() with the tag sources the export wrote (app/queries/tag_sources,
loaded into the tags_src schema) and the export's price. Everything is derived in DuckDB from small
aggregates: object tags (TAG_REFERENCES), query tags (parsed here) with their attributed credits and
statement counts, what each warehouse billed, and the billed credits per service.

Tag order, most specific first: query tag, object tag (task, table, schema, database), warehouse tag,
user or role tag, account tag. app/core/tags.py applies it per finding table; app/core/rollup.py walks it
per cost unit.

Tables (schema tags): tag_entity, tag_index, tag_account, cost_unit, cost_unit_tag, cost_reconciliation,
perf_unit, perf_unit_tag. No query text is read: a query tag is a label the user set, not a statement.
"""
from __future__ import annotations

import json
import re

import duckdb

from app.core import tag_keys

# A query-tag key with more values than this is an identifier (an invocation or node id), not something
# to allocate cost by: it is left out of the tag tables.
MAX_VALUES_PER_KEY = 500
_KEY_RE = re.compile(r"^[A-Za-z][\w .-]{0,63}$")
_COLON_RE = re.compile(r"^([A-Za-z][\w.-]{0,63}):(\S.*)$", re.S)

SOURCE_NAMES = ("tag_refs", "query_tag_credits", "query_tag_perf", "warehouse_cost", "service_cost")
# The object-tag domains and what each is called in tag_entity (and so in the chain of app/core/tags.py).
_DOMAIN_TYPE = {"WAREHOUSE": ("warehouse", "warehouse_tags"), "TASK": ("task", "object_tags"),
                "TABLE": ("table", "object_tags"), "SCHEMA": ("schema", "object_tags"),
                "DATABASE": ("database", "object_tags"), "USER": ("user", "user_tags"),
                "ROLE": ("role", "role_tags"), "ACCOUNT": ("account", "account_tags")}


def parse_query_tag(text) -> list[tuple[str, str]]:
    """The (key, value) pairs a query tag carries: a JSON object, `k=v` pairs split on , or ;, or one
    `key:value`. Anything else is free text with no key, so it carries none."""
    s = (text or "").strip()
    if not s:
        return []
    pairs: list[tuple[str, str]] = []
    if s.startswith("{"):
        try:
            obj = json.loads(s)
        except ValueError:
            return []
        if isinstance(obj, dict):
            for k, v in obj.items():
                if not isinstance(k, str) or not _KEY_RE.match(k) or v is None or isinstance(v, (dict, list)):
                    continue
                pairs.append((k, "true" if v is True else "false" if v is False else str(v)))
        return pairs
    if "=" in s:
        for part in re.split(r"[;,]", s):
            key, sep, value = part.partition("=")
            key = key.strip()
            if sep and _KEY_RE.match(key):
                pairs.append((key, value.strip()))
        return pairs
    m = _COLON_RE.match(s)
    if m and not s.startswith(("http:", "https:")):
        return [(m.group(1), m.group(2).strip())]
    return []


def _exists(con, schema: str, table: str) -> bool:
    return bool(con.execute("SELECT count(*) FROM information_schema.tables WHERE table_catalog = current_database() "
                            "AND table_schema = ? AND table_name = ?", [schema, table]).fetchone()[0])


def _windows(con, aliases: dict[int, int]) -> dict[int, int]:
    """{window label: source label}: every label the sources hold, plus each alias of one."""
    have: set[int] = set()
    for name in ("query_tag_credits", "query_tag_perf", "warehouse_cost", "service_cost"):
        if _exists(con, "tags_src", name):
            have |= {r[0] for r in con.execute(f"SELECT DISTINCT window_days FROM tags_src.{name}").fetchall() if r[0]}
    out = {w: w for w in have}
    for alias, source in aliases.items():
        if source in have and alias not in have:
            out[alias] = source
    return out


def _norm_sql(col: str) -> str:
    return f"regexp_replace(lower({col}), '[ _-]+', '', 'g')"


def build(con: duckdb.DuckDBPyConnection, *, credit_price: float | None, share_floor: float = 0.6,
          coverage_floor: float = 0.5, tag_key_filter: list[str] | None = None,
          aliases: dict[int, int] | None = None) -> dict:
    """Create the tags schema on con. Returns {"built": [...], "notes": [...]}; nothing is created
    when the export wrote no tag_refs (there is nothing to filter by)."""
    notes: list[str] = []
    if not _exists(con, "tags_src", "tag_refs"):
        return {"built": [], "notes": ["the export wrote no tag sources"]}
    keep = {tag_keys.normalize_tag_key(k) for k in (tag_key_filter or []) if tag_keys.normalize_tag_key(k)}
    con.execute("CREATE SCHEMA IF NOT EXISTS tags")
    for name in ("tag_entity", "tag_index", "tag_account", "cost_unit", "cost_unit_tag", "cost_reconciliation",
                 "perf_unit", "perf_unit_tag"):
        con.execute(f"DROP TABLE IF EXISTS tags.{name}")

    # ---- object tags -> tag_entity --------------------------------------------------------------------------------
    con.execute("CREATE OR REPLACE TEMP TABLE _refs AS SELECT * FROM tags_src.tag_refs")
    rows = con.execute("SELECT account_id, domain, object_database, object_schema, object_name, tag_name, tag_value "
                       "FROM _refs").fetchall()
    ent: list[tuple] = []
    for account_id, domain, odb, osch, oname, tname, tvalue in rows:
        kind = _DOMAIN_TYPE.get(str(domain).upper())
        if kind is None or not tname:
            continue
        etype, source = kind
        odb, osch, oname = (odb or ""), (osch or ""), (oname or "")
        if etype == "account":
            eid = str(account_id)
        elif etype in ("task", "table"):
            eid = f"{odb}.{osch}.{oname}".lower()
        elif etype == "schema":
            eid = f"{odb}.{osch or oname}".lower()
        elif etype == "database":
            eid = (oname or odb).lower()
        else:
            eid = oname.lower()
        key = tag_keys.normalize_tag_key(tname)
        if not key or (keep and key not in keep):
            continue
        ent.append((etype, str(account_id), eid, eid, key, tname, (tvalue or "").strip(), source))
    con.execute("CREATE OR REPLACE TEMP TABLE _ent(entity_type VARCHAR, account_id VARCHAR, entity_id VARCHAR, "
                "entity_label VARCHAR, tag_key VARCHAR, raw_key VARCHAR, tag_value VARCHAR, source VARCHAR)")
    if ent:
        con.executemany("INSERT INTO _ent VALUES (?, ?, ?, ?, ?, ?, ?, ?)", ent)
    # A warehouse is reached by its id or its name, whichever the finding table carries.
    if _exists(con, "dims", "dim_warehouse"):
        con.execute("""
            INSERT INTO _ent
            SELECT 'warehouse', e.account_id, d.warehouse_id, e.entity_label, e.tag_key, e.raw_key, e.tag_value, e.source
            FROM _ent e JOIN dims.dim_warehouse d ON lower(d.warehouse_name) = e.entity_id
            WHERE e.entity_type = 'warehouse' AND d.warehouse_id IS NOT NULL""")

    # ---- query tags -> tag_entity ----------------------------------------------------------------------------------
    strings: set[str] = set()
    for name in ("query_tag_credits", "query_tag_perf"):
        if _exists(con, "tags_src", name):
            strings |= {r[0] for r in con.execute(f"SELECT DISTINCT query_tag FROM tags_src.{name} "
                                                  "WHERE query_tag IS NOT NULL").fetchall()}
    qpairs: list[tuple] = []
    for text in strings:
        for k, v in parse_query_tag(text):
            key = tag_keys.normalize_tag_key(k)
            if key and (not keep or key in keep):
                qpairs.append((text, key, k, v))
    values_per_key: dict[str, set[str]] = {}
    for _t, key, _raw, v in qpairs:
        values_per_key.setdefault(key, set()).add(v)
    too_many = {k for k, vs in values_per_key.items() if len(vs) > MAX_VALUES_PER_KEY}
    if too_many:
        notes.append("query-tag keys left out for having more than %d values (identifiers): %s"
                     % (MAX_VALUES_PER_KEY, ", ".join(sorted(too_many))))
    qpairs = [p for p in qpairs if p[1] not in too_many]
    con.execute("CREATE OR REPLACE TEMP TABLE _qpairs(query_tag VARCHAR, tag_key VARCHAR, raw_key VARCHAR, tag_value VARCHAR)")
    if qpairs:
        con.executemany("INSERT INTO _qpairs VALUES (?, ?, ?, ?)", qpairs)
    acct = con.execute("SELECT any_value(account_id) FROM _refs").fetchone()[0]
    if acct is None and _exists(con, "dims", "dim_account"):
        row = con.execute("SELECT min(account_id) FROM dims.dim_account").fetchone()
        acct = row[0] if row else None
    con.execute("""
        INSERT INTO _ent
        SELECT 'query_tag', ?, query_tag, query_tag, tag_key, raw_key, tag_value, 'query_tags' FROM _qpairs""", [acct])

    con.execute("""
        CREATE TABLE tags.tag_entity AS
        SELECT entity_type, account_id, entity_id, entity_label, tag_key, raw_key, tag_value,
               TRUE AS is_allocating, source, CAST(NULL AS DOUBLE) AS share, CAST(NULL AS DOUBLE) AS coverage,
               CAST(NULL AS VARCHAR) AS reason
        FROM _ent""")

    # ---- what each unit cost, and how many statements it ran --------------------------------------------------------
    win = _windows(con, aliases or {})
    have_cost = _exists(con, "tags_src", "warehouse_cost") and _exists(con, "tags_src", "service_cost")
    priced = credit_price is not None
    price_sql = "CAST(? AS DOUBLE)" if priced else "CAST(NULL AS DOUBLE)"
    price_args = [credit_price] if priced else []

    def windowed(name: str) -> str:
        """The source table with each alias window's rows added under the alias label."""
        parts = [f"SELECT * FROM tags_src.{name}"]
        for alias, source in win.items():
            if alias != source:
                parts.append(f"SELECT * REPLACE ({alias} AS window_days) FROM tags_src.{name} WHERE window_days = {source}")
        return " UNION ALL ".join(parts)

    con.execute("CREATE TABLE tags.cost_unit (window_days INTEGER, unit_id VARCHAR, account_id VARCHAR, compute_kind VARCHAR, "
                "compute_id VARCHAR, work_kind VARCHAR, work_id VARCHAR, credits DOUBLE, usd DOUBLE)")
    con.execute("CREATE TABLE tags.cost_unit_tag (window_days INTEGER, unit_id VARCHAR, level VARCHAR, tag_key VARCHAR, "
                "raw_key VARCHAR, tag_value VARCHAR, source VARCHAR, credits DOUBLE, usd DOUBLE)")
    con.execute("CREATE TABLE tags.cost_reconciliation (window_days INTEGER, usage_unit VARCHAR, billing_usd DOUBLE, "
                "unit_usd DOUBLE, unit_unpriced_quantity DOUBLE, attributed_credits DOUBLE, "
                "attributed_unmatched_credits DOUBLE, scaled_warehouse_days BIGINT, warehouse_idle_usd DOUBLE, "
                "warehouse_unsplit_usd DOUBLE)")
    if have_cost:
        con.execute(f"CREATE OR REPLACE TEMP TABLE _wc AS {windowed('warehouse_cost')}")
        con.execute(f"CREATE OR REPLACE TEMP TABLE _sc AS {windowed('service_cost')}")
        con.execute("""
            CREATE OR REPLACE TEMP TABLE _units AS
            SELECT window_days, 'wh:' || warehouse_id || ':query' AS unit_id, ? AS account_id, 'warehouse' AS compute_kind,
                   warehouse_id AS compute_id, 'query' AS work_kind, CAST(NULL AS VARCHAR) AS work_id,
                   COALESCE(attributed_credits, 0) AS credits
            FROM _wc
            UNION ALL
            SELECT window_days, 'wh:' || warehouse_id || ':idle', ?, 'warehouse', warehouse_id, 'warehouse_idle', NULL,
                   COALESCE(idle_credits, 0)
            FROM _wc
            UNION ALL
            SELECT window_days, 'wh:' || warehouse_id || ':unsplit', ?, 'warehouse', warehouse_id, 'warehouse_unsplit', NULL,
                   GREATEST(COALESCE(billed_credits, 0) - COALESCE(attributed_credits, 0) - COALESCE(idle_credits, 0), 0)
            FROM _wc
            UNION ALL
            SELECT window_days, 'sv:' || service_type, ?, 'serverless', service_type, 'none', NULL,
                   COALESCE(credits_billed, 0)
            FROM _sc WHERE service_type <> 'WAREHOUSE_METERING'""", [acct, acct, acct, acct])
        if priced:
            con.execute(f"INSERT INTO tags.cost_unit SELECT *, credits * {price_sql} FROM _units", price_args)
            con.execute("""
                INSERT INTO tags.cost_unit_tag
                SELECT u.window_days, u.unit_id, 'compute', e.tag_key, e.raw_key, e.tag_value, e.source, u.credits, u.usd
                FROM tags.cost_unit u
                JOIN (SELECT DISTINCT tag_key, raw_key, tag_value, source, entity_id FROM tags.tag_entity
                      WHERE entity_type = 'warehouse') e ON e.entity_id = u.compute_id
                WHERE u.compute_kind = 'warehouse'""")
            if _exists(con, "tags_src", "query_tag_credits"):
                con.execute(f"""
                    INSERT INTO tags.cost_unit_tag
                    SELECT c.window_days, 'wh:' || c.warehouse_id || ':query', 'work', p.tag_key, min(p.raw_key), p.tag_value,
                           'query_tags', SUM(c.credits), SUM(c.credits) * {price_sql}
                    FROM ({windowed('query_tag_credits')}) c
                    JOIN _qpairs p ON p.query_tag = c.query_tag
                    JOIN tags.cost_unit u ON u.window_days = c.window_days AND u.unit_id = 'wh:' || c.warehouse_id || ':query'
                    GROUP BY c.window_days, c.warehouse_id, p.tag_key, p.tag_value""", price_args)
            con.execute(f"""
                INSERT INTO tags.cost_reconciliation
                SELECT b.window_days, 'CREDITS', b.credits * {price_sql}, COALESCE(u.credits, 0) * {price_sql}, 0,
                       COALESCE(u.attributed, 0), 0, 0,
                       COALESCE(u.idle, 0) * {price_sql}, COALESCE(u.unsplit, 0) * {price_sql}
                FROM (SELECT window_days, SUM(credits_billed) AS credits FROM _sc GROUP BY window_days) b
                LEFT JOIN (SELECT window_days, SUM(credits) AS credits,
                                  SUM(CASE WHEN work_kind = 'query' THEN credits ELSE 0 END) AS attributed,
                                  SUM(CASE WHEN work_kind = 'warehouse_idle' THEN credits ELSE 0 END) AS idle,
                                  SUM(CASE WHEN work_kind = 'warehouse_unsplit' THEN credits ELSE 0 END) AS unsplit
                           FROM tags.cost_unit GROUP BY window_days) u ON u.window_days = b.window_days""", price_args * 4)
        else:
            notes.append("no credit price: the cost rollup tables are empty rather than priced at zero")

    con.execute("CREATE TABLE tags.perf_unit (window_days INTEGER, unit_id VARCHAR, account_id VARCHAR, compute_kind VARCHAR, "
                "compute_id VARCHAR, statements BIGINT, failed_statements BIGINT, duration_ms DOUBLE, queue_ms DOUBLE, "
                "spill_bytes DOUBLE)")
    con.execute("CREATE TABLE tags.perf_unit_tag (window_days INTEGER, unit_id VARCHAR, level VARCHAR, tag_key VARCHAR, "
                "raw_key VARCHAR, tag_value VARCHAR, source VARCHAR, statements BIGINT, failed_statements BIGINT, duration_ms DOUBLE, "
                "queue_ms DOUBLE, spill_bytes DOUBLE)")
    if _exists(con, "tags_src", "query_tag_perf"):
        con.execute(f"CREATE OR REPLACE TEMP TABLE _qp AS {windowed('query_tag_perf')}")
        con.execute("""
            INSERT INTO tags.perf_unit
            SELECT window_days, 'wh:' || COALESCE(warehouse_id, 'none'), ?,
                   CASE WHEN warehouse_id IS NULL THEN 'serverless' ELSE 'warehouse' END, warehouse_id,
                   SUM(statements), SUM(failed_statements), SUM(duration_ms), SUM(queue_ms), SUM(spill_bytes)
            FROM _qp GROUP BY window_days, warehouse_id""", [acct])
        con.execute("""
            INSERT INTO tags.perf_unit_tag
            SELECT u.window_days, u.unit_id, 'compute', e.tag_key, e.raw_key, e.tag_value, e.source, NULL, NULL, NULL, NULL, NULL
            FROM tags.perf_unit u
            JOIN (SELECT DISTINCT tag_key, raw_key, tag_value, source, entity_id FROM tags.tag_entity
                  WHERE entity_type = 'warehouse') e ON e.entity_id = u.compute_id
            WHERE u.compute_kind = 'warehouse'""")
        con.execute("""
            INSERT INTO tags.perf_unit_tag
            SELECT q.window_days, 'wh:' || COALESCE(q.warehouse_id, 'none'), 'work', p.tag_key, min(p.raw_key), p.tag_value, 'query_tags',
                   SUM(q.statements), SUM(q.failed_statements), SUM(q.duration_ms), SUM(q.queue_ms), SUM(q.spill_bytes)
            FROM _qp q JOIN _qpairs p ON p.query_tag = q.query_tag
            GROUP BY q.window_days, q.warehouse_id, p.tag_key, p.tag_value""")

    # ---- the account level: a real account tag, else what the bill says ---------------------------------------------
    con.execute("""
        CREATE TABLE tags.tag_account (account_id VARCHAR, tag_key VARCHAR, display_key VARCHAR, tag_value VARCHAR,
                                       is_allocating BOOLEAN, top_value VARCHAR, share DOUBLE, coverage DOUBLE,
                                       credits_tagged DOUBLE, credits_total DOUBLE, source VARCHAR, reason VARCHAR)""")
    con.execute("""
        INSERT INTO tags.tag_account
        SELECT account_id, tag_key, any_value(raw_key), min(tag_value), TRUE, min(tag_value), 1.0, 1.0, NULL, NULL,
               'account_tags', 'set on the account itself'
        FROM tags.tag_entity WHERE entity_type = 'account' GROUP BY account_id, tag_key""")
    if have_cost and win:
        top = max(win)  # may be an alias label; tags_src holds only real ones, so read it as win[top]
        # Credits per (key, value), each credit counted once per key at its most specific level: a query
        # tag names its own slice, a warehouse tag names what is left of that warehouse.
        con.execute("""
            CREATE OR REPLACE TEMP TABLE _work AS
            SELECT c.warehouse_id, p.tag_key, p.tag_value, any_value(p.raw_key) AS raw_key, SUM(c.credits) AS credits
            FROM tags_src.query_tag_credits c JOIN _qpairs p ON p.query_tag = c.query_tag
            WHERE c.window_days = ? GROUP BY c.warehouse_id, p.tag_key, p.tag_value""", [win[top]])
        con.execute("""
            CREATE OR REPLACE TEMP TABLE _inferred AS
            WITH wh_total AS (SELECT compute_id AS warehouse_id, SUM(credits) AS credits FROM _units
                              WHERE window_days = ? AND compute_kind = 'warehouse' GROUP BY compute_id),
            wtag AS (SELECT DISTINCT entity_id AS warehouse_id, tag_key, tag_value, raw_key FROM tags.tag_entity
                     WHERE entity_type = 'warehouse'),
            comp AS (SELECT w.tag_key, w.tag_value, w.raw_key,
                            GREATEST(t.credits - COALESCE((SELECT SUM(k.credits) FROM _work k
                                                           WHERE k.warehouse_id = w.warehouse_id AND k.tag_key = w.tag_key), 0), 0) AS credits
                     FROM wtag w JOIN wh_total t ON t.warehouse_id = w.warehouse_id),
            allrows AS (SELECT tag_key, tag_value, raw_key, credits FROM comp
                        UNION ALL SELECT tag_key, tag_value, raw_key, credits FROM _work)
            SELECT tag_key, any_value(raw_key) AS display_key, tag_value, SUM(credits) AS credits
            FROM allrows GROUP BY tag_key, tag_value""", [top])
        total = con.execute("SELECT COALESCE(SUM(credits), 0) FROM _units WHERE window_days = ?", [top]).fetchone()[0] or 0
        con.execute("""
            INSERT INTO tags.tag_account
            SELECT ?, tag_key, any_value(display_key),
                   CASE WHEN ? = 0 OR SUM(credits) / ? < ? THEN '__untagged__'
                        WHEN max(credits) / NULLIF(SUM(credits), 0) >= ? THEN arg_max(tag_value, credits) ELSE '__mixed__' END,
                   (? > 0 AND SUM(credits) / ? >= ? AND max(credits) / NULLIF(SUM(credits), 0) >= ?),
                   arg_max(tag_value, credits), max(credits) / NULLIF(SUM(credits), 0), SUM(credits) / NULLIF(?, 0),
                   SUM(credits), ?, 'account_inferred',
                   CAST(ROUND(100 * SUM(credits) / NULLIF(?, 0), 1) AS VARCHAR)
                   || '% of the billed credits carry it; the top value is ' || arg_max(tag_value, credits)
            FROM _inferred
            WHERE tag_key NOT IN (SELECT tag_key FROM tags.tag_account WHERE account_id = ?)
            GROUP BY tag_key""", [acct, total, total, coverage_floor, share_floor, total, total, coverage_floor,
                                  share_floor, total, total, total, acct])
    # ---- the searchable index --------------------------------------------------------------------------------------
    con.execute("""
        CREATE TABLE tags.tag_index AS
        WITH k AS (SELECT tag_key, string_agg(DISTINCT raw_key, ',' ORDER BY raw_key) AS raw_keys,
                          arg_max(raw_key, 1) AS display_key FROM tags.tag_entity GROUP BY tag_key),
        v AS (SELECT tag_key, tag_value, source, count(DISTINCT entity_label) AS object_count,
                     count(DISTINCT account_id) AS account_count
              FROM tags.tag_entity GROUP BY tag_key, tag_value, source)
        SELECT v.tag_key, k.display_key, k.raw_keys, v.tag_value, v.source, v.object_count, v.account_count,
               CAST(NULL AS DOUBLE) AS credits, CAST(NULL AS TIMESTAMP) AS first_seen, CAST(NULL AS TIMESTAMP) AS last_seen
        FROM v JOIN k ON k.tag_key = v.tag_key""")
    if have_cost and win:
        top = max(win)
        con.execute("""
            UPDATE tags.tag_index i SET credits = s.credits FROM (
                SELECT e.tag_key, e.tag_value, 'warehouse_tags' AS source, SUM(u.credits) AS credits
                FROM (SELECT DISTINCT entity_id, tag_key, tag_value FROM tags.tag_entity WHERE entity_type = 'warehouse') e
                JOIN _units u ON u.window_days = ? AND u.compute_kind = 'warehouse' AND u.unit_id LIKE 'wh:' || e.entity_id || ':%'
                GROUP BY e.tag_key, e.tag_value
                UNION ALL
                SELECT p.tag_key, p.tag_value, 'query_tags', SUM(c.credits)
                FROM tags_src.query_tag_credits c JOIN _qpairs p ON p.query_tag = c.query_tag
                WHERE c.window_days = ? GROUP BY p.tag_key, p.tag_value) s
            WHERE i.tag_key = s.tag_key AND i.tag_value = s.tag_value AND i.source = s.source""", [top, win[top]])
    built = ["tag_entity", "tag_index", "tag_account", "cost_unit", "cost_unit_tag", "cost_reconciliation",
             "perf_unit", "perf_unit_tag"]
    return {"built": built, "notes": notes}
