"""The demo account: a larger, more varied fake account on top of the base one, for looking at the app.

`add(world)` runs last in World.build when the world is built with demo=True. Each area lives in its
own demo_<area>.py with an `add(b)` that takes a demo_data.B. Names and ids come from
demo_entities.catalog(). The tests never build this; tools/build_demo_db.py does.

demo_billing.add(world) runs after the areas: attribution, daily and org rollups, anomalies.

DEMO_ONLY=compute,security limits the run to those areas while one is being worked on.
"""
from __future__ import annotations

import datetime as dt
import importlib
import os
import random

from tests.fake_snowflake import demo_entities

AREAS = ["compute", "tags", "security", "storage", "pipelines", "queries", "platform"]


class B:
    """Helpers over the World for the demo modules; `rng` is the demo's own generator."""

    def __init__(self, w, area: str):
        self.w = w
        self.as_of = w.as_of
        self.cat = demo_entities.catalog()
        self.rng = random.Random(f"{demo_entities.DEMO_SEED}:{area}")

    def back(self, k: int) -> dt.date:
        return self.as_of - dt.timedelta(days=k)

    def ts(self, k: int, hour: int = 0, minute: int = 0, second: int = 0) -> dt.datetime:
        d = self.back(k)
        return dt.datetime(d.year, d.month, d.day, hour, minute, second)

    def au(self, view: str, **row) -> None:
        self.w.au(view, row)

    def ou(self, view: str, **row) -> None:
        self.w.ou(view, row)

    def show(self, view: str, **row) -> None:
        self.w.show(view, row)


def areas() -> list[str]:
    only = [a.strip() for a in os.environ.get("DEMO_ONLY", "").split(",") if a.strip()]
    return [a for a in AREAS if not only or a in only]


def add(w) -> None:
    for area in areas():
        try:
            mod = importlib.import_module(f"tests.fake_snowflake.demo_{area}")
        except ModuleNotFoundError as exc:
            if exc.name == f"tests.fake_snowflake.demo_{area}":
                continue                     # an area not written yet
            raise
        mod.add(B(w, area))
    shape_columns(w)
    from tests.fake_snowflake import demo_billing
    demo_billing.add(w)                      # last: rollups over everything the areas added


def shape_columns(w) -> None:
    """WHERE and JOIN columns per real query shape and table read, so a shape's lineage lists them."""
    qh = {r["query_id"]: r for r in w.rows.get(("account_usage", "QUERY_HISTORY"), [])}
    used: dict = {}                          # (shape, table id) -> [runs, scanned, pruned, ms, query row, object, joins]
    for a in w.rows.get(("account_usage", "ACCESS_HISTORY"), []):
        q = qh.get(a["query_id"])
        if not q or not q.get("query_parameterized_hash") or not q.get("partitions_total"):
            continue
        objs = [o for o in (a.get("base_objects_accessed") or []) if o.get("objectDomain") in ("Table", "Dynamic table")]
        for o in objs:
            u = used.setdefault((q["query_parameterized_hash"], o["objectId"]), [0, 0, 0, 0, q, o, len(objs) > 1])
            u[0] += 1
            u[1] += q.get("partitions_scanned") or 0
            u[2] += max(0, q["partitions_total"] - (q.get("partitions_scanned") or 0))
            u[3] += q.get("execution_time") or 0
    for (ph, tid), (n, ps, pp, ms, q, o, joins) in used.items():
        db, sch, name = (o["objectName"].split(".") + ["", "", ""])[:3]
        ix = sum(map(ord, ph))
        cols = [("CREATED_AT", "WHERE")] + ([("STATUS", "WHERE")] if ix % 4 == 0 else []) +                ([("REGION", "WHERE")] if ix % 5 == 1 else []) + ([("ID", "JOIN")] if joins else [])
        st = q["start_time"].replace(minute=0, second=0, microsecond=0)
        for i, (col, access) in enumerate(cols):
            w.au("COLUMN_QUERY_PRUNING_HISTORY", dict(
                interval_start_time=st, interval_end_time=st + dt.timedelta(hours=1), table_id=tid, table_name=name,
                schema_id=w.schema_id.get((db, sch), 0), schema_name=sch, database_id=w.dbs.get(db, 0), database_name=db,
                warehouse_id=q.get("warehouse_id"), warehouse_name=q.get("warehouse_name"), query_hash=q.get("query_hash"),
                query_parameterized_hash=ph, column_id=tid * 10 + 5 + i, column_name=col, variant_path=None,
                access_type=access, search_optimization_supported_expressions=None, num_queries=n,
                aggregate_query_elapsed_time=ms, aggregate_query_compilation_time=0, aggregate_query_execution_time=ms,
                partitions_scanned=ps, partitions_pruned=pp, rows_scanned=ps * 1000, rows_pruned=pp * 1000,
                rows_matched=ps * 20))
