#!/usr/bin/env python3
"""Run every check in app/queries/checks against fake Snowflake data in DuckDB.

The checks are rendered by tools/export_results.py (includes, placeholders, params, as-of), `pre:`
SHOW lines are answered from the fake SHOW tables, and the Snowflake SQL is transpiled to DuckDB with
sqlglot plus a few macros. A check that runs is `ok` (rows) or `empty`; anything else is `failed`.

    python tools/sql_smoke.py [--out data/sql_smoke.md] [--export DIR] [--only ID ...] [--windows 90]

--export writes the same folder tools/export_results.py writes (findings/, dims/, manifest.json).
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import re
import shutil
import sys
import tempfile
from pathlib import Path

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq
import sqlglot
from sqlglot import exp

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import datasource  # noqa: E402
from tests.fake_snowflake import data as fake_data  # noqa: E402
from tests.fake_snowflake import schema as fake_schema  # noqa: E402
from tools import export_results as ex  # noqa: E402

DEFAULT_OUT = ROOT / "data" / "sql_smoke.md"
_RESULT_SCAN_RE = re.compile(r"TABLE\(\s*RESULT_SCAN\(\s*LAST_QUERY_ID\(\s*(-?\d*)\s*\)\s*\)\s*\)", re.I)
_SHOW_RE = re.compile(r"^\s*SHOW\s+(.*?)\s*$", re.I | re.S)
_LIKE_RE = re.compile(r"\s+LIKE\s+'([^']*)'", re.I)

# Snowflake functions DuckDB lacks or gets wrong through sqlglot. Each is a plain macro.
MACROS = [
    # Account context: the fake account.
    f"CREATE OR REPLACE MACRO current_account() AS '{fake_data.ACCOUNT_LOCATOR}'",
    f"CREATE OR REPLACE MACRO current_region() AS '{fake_data.REGION}'",
    f"CREATE OR REPLACE MACRO current_account_name() AS '{fake_data.ACCOUNT_NAME}'",
    "CREATE OR REPLACE MACRO current_organization_name() AS 'FAKE_ORG'",
    # FLATTEN: an array gives its elements, an object its key/value pairs.
    """CREATE OR REPLACE MACRO sf_items(j) AS (
         CASE WHEN j IS NULL THEN []
              WHEN json_type(j) = 'ARRAY'
                THEN list_transform(from_json(j, '["JSON"]'), x -> {'key': NULL::VARCHAR, 'value': x})
              WHEN json_type(j) = 'OBJECT'
                THEN list_transform(json_keys(j), k -> {'key': k, 'value': json_extract(j, '$."' || k || '"')})
              ELSE [{'key': NULL::VARCHAR, 'value': j}] END)""",
    # OBJECT_CONSTRUCT(*): the row as JSON, leaving out NULL columns as Snowflake does (so o:COL IS NULL holds).
    """CREATE OR REPLACE MACRO sf_obj(r) AS (CAST(regexp_replace(regexp_replace(regexp_replace(
         CAST(to_json(r) AS VARCHAR), '"[^"]+":null,', '', 'g'), ',"[^"]+":null', '', 'g'),
         '"[^"]+":null', '', 'g') AS JSON))""",
    # Functions with no DuckDB name.
    # String input only, as in Snowflake: trim() does not bind on a non-text x.
    "CREATE OR REPLACE MACRO try_to_timestamp_ltz(x) AS TRY_CAST(trim(x, '\"') AS TIMESTAMP)",
    # What Snowflake reports about its drivers (JSON text, as the real function returns).
    """CREATE OR REPLACE MACRO "system$client_version_info"() AS (
         '[{"clientId":"JDBC","clientAppId":"JDBC","minimumSupportedVersion":"3.13.0",'
         || '"minimumNearingEndOfSupportVersion":"3.14.0","recommendedVersion":"3.20.0"},'
         || '{"clientId":"PythonConnector","clientAppId":"PythonConnector","minimumSupportedVersion":"3.0.0",'
         || '"minimumNearingEndOfSupportVersion":"3.4.0","recommendedVersion":"3.12.0"},'
         || '{"clientId":"ODBC","clientAppId":"ODBC","minimumSupportedVersion":"3.0.0",'
         || '"minimumNearingEndOfSupportVersion":"3.2.0","recommendedVersion":"3.5.0"},'
         || '{"clientId":"GO","clientAppId":"Go","minimumSupportedVersion":"1.8.0",'
         || '"minimumNearingEndOfSupportVersion":"1.11.0","recommendedVersion":"1.12.1"},'
         || '{"clientId":"JSDriver","clientAppId":"JavaScript","minimumSupportedVersion":"1.9.0",'
         || '"minimumNearingEndOfSupportVersion":"1.12.0","recommendedVersion":"1.15.0"},'
         || '{"clientId":"DOTNETDriver","clientAppId":".NET","minimumSupportedVersion":"2.1.5",'
         || '"minimumNearingEndOfSupportVersion":"2.2.0","recommendedVersion":"4.2.0"},'
         || '{"clientId":"SnowSQL","clientAppId":"SnowSQL","minimumSupportedVersion":"1.2.21",'
         || '"minimumNearingEndOfSupportVersion":"1.2.32","recommendedVersion":"1.3.3"},'
         || '{"clientId":"PHP_PDO","clientAppId":"PDO","minimumSupportedVersion":"2.0.0",'
         || '"minimumNearingEndOfSupportVersion":"2.0.1","recommendedVersion":"3.0.3"},'
         || '{"clientId":"SQLAPI","clientAppId":"SQLAPI","minimumSupportedVersion":"1.0.0",'
         || '"minimumNearingEndOfSupportVersion":"1.0.0","recommendedVersion":"1.0.0"}]')""",
    """CREATE OR REPLACE MACRO sf_flat(j) AS TABLE
         SELECT s.key AS key, s.value AS value, i - 1 AS "index", i - 1 AS seq, NULL::VARCHAR AS path,
                NULL::JSON AS this
         FROM (SELECT UNNEST(sf_items(j)) AS s, generate_subscripts(sf_items(j), 1) AS i)""",
    # FLATTEN(recursive => TRUE): every nested element below the input, not the input itself.
    """CREATE OR REPLACE MACRO sf_flat_rec(j) AS TABLE
         SELECT CASE WHEN p.type = 'ARRAY' THEN NULL ELSE t.key END AS key, t.value AS value,
                CASE WHEN p.type = 'ARRAY' THEN TRY_CAST(t.key AS BIGINT) END AS "index", 1 AS seq,
                regexp_replace(t.fullkey, '^[$][.]?', '') AS path, p.value AS this
         FROM json_tree(j) t JOIN json_tree(j) p ON p.id = t.parent""",
]


# ------------------------------------------------------------------------------------------
# Snowflake -> DuckDB
# ------------------------------------------------------------------------------------------

_SCALAR_TARGETS = {
    exp.DType.TEXT, exp.DType.VARCHAR, exp.DType.CHAR, exp.DType.DECIMAL, exp.DType.INT,
    exp.DType.BIGINT, exp.DType.DOUBLE, exp.DType.FLOAT, exp.DType.BOOLEAN, exp.DType.DATE,
    exp.DType.TIMESTAMP, exp.DType.TIMESTAMPTZ, exp.DType.TIMESTAMPLTZ, exp.DType.SMALLINT,
    exp.DType.TINYINT,
}
_JSON_TYPES = {exp.DType.VARIANT, exp.DType.OBJECT, exp.DType.ARRAY}


def _scalar_read(node: exp.Expression, flat_aliases: frozenset = frozenset()) -> exp.Expression | None:
    """col:path, GET(col, 'key'), a FLATTEN value and COALESCE of those as a scalar read (->>), or None."""
    if isinstance(node, exp.Coalesce):
        args = [node.this, *node.expressions]
        reads = [_scalar_read(a, flat_aliases) for a in args]
        if not any(r is not None for r in reads):
            return None
        return exp.Coalesce(this=reads[0] or args[0],
                            expressions=[r or a for r, a in zip(reads[1:], args[1:])])
    # f.value of a FLATTEN is a VARIANT: Snowflake's TO_VARCHAR gives a string without its JSON quotes.
    if (isinstance(node, exp.Column) and node.name.lower() == "value"
            and node.table and node.table.lower() in flat_aliases):
        return exp.JSONExtractScalar(this=node, expression=exp.Literal.string("$"))
    if isinstance(node, exp.JSONExtract):
        return exp.JSONExtractScalar(this=node.this, expression=node.expression)
    if isinstance(node, exp.GetExtract) and isinstance(node.expression, exp.Literal):
        return exp.JSONExtractScalar(this=node.this, expression=exp.Literal.string("$." + node.expression.name))
    return None


def _fix(node: exp.Expression, strict: bool = True,
         flat_aliases: frozenset = frozenset()) -> exp.Expression:
    """Per-node repairs of what sqlglot's Snowflake->DuckDB output gets wrong.

    strict keeps the Snowflake type errors DuckDB would let through (string-only TRY_*, COALESCE(n, '')).
    """
    # col:path::TYPE and TO_VARCHAR(col:path) read the scalar (->>), not the JSON text with its quotes.
    is_scalar_cast = isinstance(node, exp.Cast) and node.to.this in _SCALAR_TARGETS
    is_conversion = isinstance(node, (exp.ToChar, exp.ToNumber)) and not node.args.get("format")
    if is_scalar_cast or is_conversion:
        scalar = _scalar_read(node.this, flat_aliases)
        if scalar is not None:
            node.set("this", scalar)
    if isinstance(node, exp.DataType) and node.this in _JSON_TYPES:
        return exp.DataType.build("JSON")
    # TRY_TO_NUMBER must not raise on text; sqlglot emits a plain CAST.
    if isinstance(node, exp.ToNumber) and node.args.get("safe"):
        to = exp.DataType.build(f"DECIMAL({node.args['precision']}, {node.args['scale']})") \
            if node.args.get("precision") else exp.DataType.build("DECIMAL(38, 0)")
        # The argument is fixed here because the replacement's children are not visited again.
        return exp.TryCast(this=_string_only(_fix(node.this, strict, flat_aliases), strict), to=to)
    # Snowflake's TRY_TO_* take string input only; a NUMBER or TIMESTAMP argument is an error there.
    if isinstance(node, exp.ToDouble) and node.args.get("safe"):
        return exp.TryCast(this=_string_only(node.this, strict), to=exp.DataType.build("DOUBLE"))
    if isinstance(node, (exp.TsOrDsToDate, exp.ToBoolean)) and node.args.get("safe"):
        node.set("this", _string_only(node.this, strict))
    if isinstance(node, exp.RegexpExtract):
        return _regexp_substr(node, lambda n: n.transform(lambda m: _fix(m, strict, flat_aliases)))
    return node


def _regexp_substr(node: exp.RegexpExtract, fix) -> exp.Expression:
    """REGEXP_SUBSTR -> the n-th match of regexp_extract_all, so no match is NULL as in Snowflake, not ''."""
    params = node.args.get("parameters")
    flags = params.name if isinstance(params, exp.Literal) else ""
    group = node.args.get("group")
    gnum = int(group.name) if isinstance(group, exp.Literal) else 0
    # 'e' with no group number extracts group 1.
    if "e" in flags and gnum == 0:
        gnum = 1
    src = fix(node.this)
    pos = node.args.get("position")
    if pos is not None and not (isinstance(pos, exp.Literal) and pos.name == "1"):
        src = exp.Anonymous(this="substring", expressions=[src, fix(pos)])
    occ = node.args.get("occurrence")
    opts = "".join(c for c in flags if c in "icms")
    matches = exp.Anonymous(this="regexp_extract_all", expressions=[
        src, fix(node.expression), exp.Literal.number(gnum), exp.Literal.string(opts)])
    return exp.Anonymous(this="list_extract",
                         expressions=[matches, fix(occ) if occ is not None else exp.Literal.number(1)])


def _string_only(arg: exp.Expression, strict: bool) -> exp.Expression:
    """ltrim(x, ''): the value unchanged, but DuckDB's binder rejects a non-text x, as Snowflake does."""
    if not strict:
        return arg
    return exp.Anonymous(this="ltrim", expressions=[arg, exp.Literal.string("")])


_FORMAT_TOKENS = [("YYYY", "%Y"), ("HH24", "%H"), ("MON", "%b"), ("DY", "%a"), ("MM", "%m"),
                  ("DD", "%d"), ("MI", "%M"), ("SS", "%S")]


def _strftime_format(fmt: str) -> str:
    out = fmt
    for token, code in _FORMAT_TOKENS:
        out = re.sub(token, code, out, flags=re.I)
    return out


def _more_fixes(node: exp.Expression, strict: bool = True) -> exp.Expression:
    """Repairs that need the surrounding tree, so they run after _fix."""
    # TO_VARCHAR(ts, 'YYYY-MM-DD'): sqlglot cannot carry the format to DuckDB.
    if isinstance(node, exp.ToChar) and isinstance(node.args.get("format"), exp.Literal):
        fmt = _strftime_format(node.args["format"].name)
        return exp.Anonymous(this="strftime", expressions=[node.this, exp.Literal.string(fmt)])
    # ARRAY_CAT on VARIANT arrays; NULL in, NULL out. Inline, as a macro cannot nest inside sf_flat.
    if isinstance(node, exp.ArrayConcat):
        a, b = node.this, node.expressions[0]
        tpl = sqlglot.parse_one(
            "CASE WHEN __a IS NULL OR __b IS NULL THEN NULL ELSE TO_JSON(LIST_CONCAT("
            "FROM_JSON(__a, '[\"JSON\"]'), FROM_JSON(__b, '[\"JSON\"]'))) END", read="duckdb")
        for col in list(tpl.find_all(exp.Column)):
            col.replace((a if col.name == "__a" else b).copy())
        return tpl
    # COALESCE(x, ''): Snowflake casts '' to x's type, so a NUMBER or date x fails; DuckDB only fails
    # when x is NULL on some row. A typed '' makes DuckDB's binder refuse the mix every time.
    if strict and isinstance(node, exp.Coalesce):
        for arg in node.expressions:
            if isinstance(arg, exp.Literal) and arg.is_string:
                arg.replace(exp.Cast(this=arg.copy(), to=exp.DataType.build("VARCHAR")))
    # ARRAY_SIZE on a VARIANT array.
    if isinstance(node, exp.ArraySize):
        return exp.Anonymous(this="json_array_length", expressions=[node.this])
    # OBJECT_CONSTRUCT(*): the row as a JSON object with upper-case column keys.
    if isinstance(node, exp.StarMap):
        select = node.find_ancestor(exp.Select)
        src = select.args["from_"].this if select is not None and select.args.get("from_") else None
        if isinstance(src, exp.Table):
            return exp.Anonymous(this="sf_obj", expressions=[exp.column(src.alias_or_name)])
    # VALUES without an alias: Snowflake names the columns COLUMN1, COLUMN2, ...
    if isinstance(node, exp.Values) and not node.args.get("alias"):
        width = len(node.expressions[0].expressions)
        node.set("alias", exp.TableAlias(this=exp.to_identifier("_v"),
                                         columns=[exp.to_identifier(f"column{i + 1}") for i in range(width)]))
    return node


def _recursive_ctes(tree: exp.Expression) -> exp.Expression:
    """Snowflake accepts a self-referencing CTE without RECURSIVE; DuckDB wants the keyword."""
    for with_ in tree.find_all(exp.With):
        for cte in with_.expressions:
            if any(t.name == cte.alias and not t.db for t in cte.this.find_all(exp.Table)):
                with_.set("recursive", True)
    return tree


def _flatten(tree: exp.Expression) -> exp.Expression:
    """LATERAL FLATTEN(input => x [, outer => TRUE] [, recursive => TRUE]) f -> the sf_flat(_rec) table macro."""
    for join in list(tree.find_all(exp.Join)):
        lateral = join.this
        if not isinstance(lateral, exp.Lateral) or not isinstance(lateral.this, exp.Explode):
            continue
        explode = lateral.this
        kwargs = {}
        for kw in [explode.this, *explode.expressions]:
            if isinstance(kw, exp.Kwarg):
                kwargs[kw.this.name.lower()] = kw.expression
        outer = isinstance(kwargs.get("outer"), exp.Boolean) and kwargs["outer"].this
        recursive = isinstance(kwargs.get("recursive"), exp.Boolean) and kwargs["recursive"].this
        alias = lateral.args.get("alias")
        fn = "sf_flat_rec" if recursive else "sf_flat"
        table = exp.Table(this=exp.Anonymous(this=fn, expressions=[kwargs["input"]]),
                          alias=exp.TableAlias(this=alias.this) if alias else None)
        join.set("this", table)
        if outer:
            join.set("side", "LEFT")
            join.set("on", exp.Boolean(this=True))
        else:
            join.set("kind", "CROSS")
    return tree


def to_duckdb(sql: str, shows: list[str | None], strict: bool = True) -> str:
    """Snowflake SQL -> DuckDB SQL. `shows` is the session's query history in order: the SHOW source
    for a SHOW, None for any other statement (so RESULT_SCAN of a SELECT fails, as it would mislead)."""
    def scan(m):
        k = int(m.group(1)) if m.group(1) else -1
        # LAST_QUERY_ID(-1) is the latest query; a positive n counts from the session's first (1-based).
        idx = k if k < 0 else k - 1
        src = shows[idx] if k != 0 and -len(shows) <= idx < len(shows) else None
        if src is None:
            raise ValueError(f"RESULT_SCAN(LAST_QUERY_ID({k})) does not point at a SHOW")
        return f"({src})"

    sql = _RESULT_SCAN_RE.sub(scan, sql)
    tree = sqlglot.parse_one(sql, read="snowflake")
    flat_aliases = frozenset(
        lat.args["alias"].name.lower() for lat in tree.find_all(exp.Lateral)
        if isinstance(lat.this, exp.Explode) and lat.args.get("alias"))
    tree = tree.transform(lambda n: _fix(n, strict, flat_aliases)).transform(lambda n: _more_fixes(n, strict))
    tree = _recursive_ctes(_flatten(tree))
    return tree.sql(dialect="duckdb", comments=False)


def show_source(stmt: str) -> str:
    """A `SHOW ...` statement -> the SELECT over the matching fake SHOW table."""
    body = _SHOW_RE.match(stmt).group(1)
    like = _LIKE_RE.search(body)
    body = _LIKE_RE.sub("", body)
    body = re.sub(r"\s+(?:IN|ON)\s+ACCOUNT\s*$", "", body, flags=re.I).strip()
    table = fake_schema.SHOW_TABLE_FOR_PRE.get("SHOW " + body.upper())
    if table is None:
        raise ValueError(f"no fake SHOW output for: {stmt}")
    sel = f"SELECT * FROM {fake_schema.SNOWFLAKE_DB}.{fake_schema.SHOW_SCHEMA}.{table}"
    if like:
        col = "key" if table == "parameters" else "name"
        sel += f" WHERE \"{col}\" ILIKE '{like.group(1)}'"
    return sel


# ------------------------------------------------------------------------------------------
# A connector stand-in for tools/export_results.py
# ------------------------------------------------------------------------------------------


class FakeCursor:
    """Just enough of a snowflake.connector cursor: SHOW is remembered, anything else runs in DuckDB.

    `shows` is the whole session history (None for a non-SHOW), so LAST_QUERY_ID(n) counts as it does
    in Snowflake and cannot reach a SHOW run before a later SELECT.
    """

    def __init__(self, con, strict: bool = True):
        self.con = con
        self.strict = strict
        self.shows: list[str | None] = []
        self.description = None
        self._result = None
        self._last_was_show = False
        self._cache: dict[tuple, str] = {}

    def execute(self, sql: str):
        body = ex._COMMENT_RE.sub("", sql).strip()
        if _SHOW_RE.match(body):
            self._last_was_show = True
            self.shows.append(show_source(body))
            self._result = self.con.execute(self.shows[-1])
            self.description = self._result.description
            return self
        self._last_was_show = False
        key = (sql, tuple(self.shows[-4:]))
        duck = self._cache.get(key)
        self.shows.append(None)
        if duck is None:
            duck = self._cache[key] = to_duckdb(sql, self.shows[:-1], self.strict)
        self._result = self.con.execute(duck)
        self.description = self._result.description
        return self

    def fetch_arrow_all(self) -> pa.Table:
        if self._last_was_show:
            # The real connector refuses this on SHOW output; a check reads it through RESULT_SCAN.
            raise RuntimeError("fetch_arrow_all is not supported for SHOW results")
        table = self._result.to_arrow_table()
        # JSON comes back as an extension type; parquet and the app want plain text.
        cols = [c.cast(pa.string()) if isinstance(c.type, pa.ExtensionType) else c for c in table.columns]
        return pa.Table.from_arrays(cols, names=table.column_names)


class FakeConnection:
    def __init__(self, con, strict: bool = True):
        self.con = con
        self.strict = strict

    def cursor(self):
        return FakeCursor(self.con, self.strict)

    def close(self):
        pass


def build_fake_db(as_of: dt.date, lenient: bool = False, demo: bool = False) -> duckdb.DuckDBPyConnection:
    """DuckDB with SNOWFLAKE.ACCOUNT_USAGE etc. attached and filled, and the macros installed."""
    con = duckdb.connect(":memory:")
    fake_schema.create_all(con)
    for ddl in MACROS:
        con.execute(ddl)
    fake_data.load(con, as_of, demo)
    if lenient:
        fake_schema.apply_lenient(con)
    return con


# ------------------------------------------------------------------------------------------
# Running and reporting
# ------------------------------------------------------------------------------------------


def _status_counts(path: Path) -> dict[str, int]:
    table = pq.read_table(path, columns=["status"]) if "status" in pq.read_schema(path).names else None
    if table is None:
        return {}
    return dict(collections.Counter(str(v) for v in table.column("status").to_pylist()))


def hint(error: str) -> str:
    """A first guess at the failure class; a human decides."""
    e = error.lower()
    if "table with name" in e and "does not exist" in e:
        return "missing view"
    if "referenced column" in e or ("column" in e and "not found" in e):
        return "missing column"
    if "ambiguous" in e:
        return "ambiguous column"
    if "scalar function" in e or "aggregate function" in e or "table function" in e or \
            "no function matches" in e:
        return "function or type"
    if "conversion error" in e or "cannot cast" in e or "could not convert" in e:
        return "type"
    return "other"


def run_smoke(*, windows: int = 90, only: list[str] | None = None,
              export_to: Path | None = None, lenient: bool = False, demo: bool = False) -> dict:
    """Run the checks and dims through export_results.run_export on the fake account.

    Returns {"manifest", "status_counts": {qid: {status: n}}, "export_dir"}.
    """
    now = fake_data.NOW
    con = build_fake_db(now.date(), lenient, demo)
    work = Path(tempfile.mkdtemp(prefix="sql_smoke_"))
    out = work / "export"
    try:
        manifest = ex.run_export(out, windows=windows, only=only, connect_fn=lambda: FakeConnection(con, not lenient),
                                 include_today=False, now=now)
        counts = {qid: _status_counts(out / "findings" / f"{qid}.parquet")
                  for qid, f in manifest["findings"].items() if f["status"] != "failed"}
        if export_to is not None:
            data_dir = (ROOT / "data").resolve()
            target = export_to.resolve()
            if datasource.inside_repo(target) and target != data_dir and data_dir not in target.parents:
                raise ex.ExportConfigError(f"{export_to} is inside the repository; use data/ or outside it")
            if export_to.exists():
                shutil.rmtree(export_to)
            export_to.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(out, export_to)
        return {"manifest": manifest, "status_counts": counts, "export_dir": export_to}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def render_markdown(result: dict) -> str:
    manifest, counts = result["manifest"], result["status_counts"]
    findings = manifest["findings"]
    by = collections.Counter(f["status"] for f in findings.values())
    lines = [
        "# SQL smoke on fake Snowflake data", "",
        f"as of {manifest['as_of']} (as_of_date {manifest['as_of_date']}), windows {manifest['windows']}", "",
        f"**{len(findings)} checks**: " + ", ".join(f"{n} {s}" for s, n in sorted(by.items())), "",
    ]
    failed = {q: f for q, f in findings.items() if f["status"] == "failed"}
    if failed:
        lines += ["## Failed", "", "| check | hint | error |", "|---|---|---|"]
        for q, f in sorted(failed.items()):
            lines.append(f"| {q} | {hint(f['error'] or '')} | {ex._md_cell(f['error'], 300)} |")
        lines.append("")
    empty = sorted(q for q, f in findings.items() if f["status"] == "empty")
    if empty:
        lines += ["## Empty", "", ", ".join(empty), ""]
    lines += ["## Ok", "", "| check | rows | status counts |", "|---|---|---|"]
    for q, f in sorted(findings.items()):
        if f["status"] == "ok":
            sc = ", ".join(f"{k} {v}" for k, v in sorted(counts.get(q, {}).items()))
            lines.append(f"| {q} | {f['exported_rows']} | {sc} |")
    return "\n".join(lines) + "\n"


def show_sql(qid: str, days: int = 30) -> str:
    """The check as rendered by export_results and as sent to DuckDB, for reading an error."""
    from app.core import config as app_config
    from app.core import registry as app_registry

    ctx = {"as_of_date": fake_data.NOW.date().isoformat(), "account_id": fake_data.ACCOUNT_LOCATOR,
           "cloud": "AWS", "credit_price_usd": fake_data.CREDIT_PRICE,
           "ai_credit_price_usd": fake_data.CREDIT_PRICE, "storage_price_usd_tb_month": 23.0}
    text = ex.load_checks()[qid]
    sql = ex.render(text, days=days, params=ex.params_for(qid, app_config.load_thresholds()), ctx=ctx)
    shows = [show_source(stmt) for stmt in app_registry.by_id(qid).pre]
    return "\n".join(["-- Snowflake", sql, "", "-- DuckDB", to_duckdb(sql, shows)])


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", type=Path, default=DEFAULT_OUT, help="markdown report (default data/sql_smoke.md)")
    p.add_argument("--export", type=Path, help="also write the export folder (findings/, dims/, manifest.json)")
    p.add_argument("--only", nargs="+", help="run just these check ids")
    p.add_argument("--lenient", action="store_true",
                   help="give the fake the columns and types the catalog says are absent, and let DuckDB coerce types Snowflake rejects, "
                        "so a check gets past its first error")
    p.add_argument("--show", metavar="ID", help="print one check's rendered Snowflake and DuckDB SQL, then exit")
    p.add_argument("--windows", type=int, default=90, help="days of history (default 90 fills every window)")
    args = p.parse_args(argv)
    if args.show:
        print(show_sql(args.show))
        return 0
    result = run_smoke(windows=args.windows, only=args.only, export_to=args.export, lenient=args.lenient)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render_markdown(result), encoding="utf-8")
    findings = result["manifest"]["findings"]
    by = collections.Counter(f["status"] for f in findings.values())
    print(f"{len(findings)} checks: " + ", ".join(f"{n} {s}" for s, n in sorted(by.items())))
    for q, f in sorted(findings.items()):
        if f["status"] == "failed":
            print(f"FAILED {q} [{hint(f['error'] or '')}]: {ex._md_cell(f['error'], 200)}")
    print(f"report: {args.out}")
    return 1 if by.get("failed") else 0


if __name__ == "__main__":
    sys.exit(main())
