"""Demo area: objects in every last-active band and use pattern, and a full year of ACCESS_HISTORY.

Tables get each band crossed with each pattern (read and written, read only, written only, neither);
views, stages, functions, procedures, pipes and tasks get each band as used and as not used.
"""
from __future__ import annotations

import datetime as dt

GB = 1024 ** 3
BANDS = (("NEW", 5), ("STG", 55), ("OLD", 130), ("ARCHIVE", 270), ("LEGACY", 362))
PATTERNS = (("RW", True, True), ("RO", True, False), ("WO", False, True), ("IDLE", False, False))
STEMS = ("ORDERS", "INVOICES", "EVENTS", "SESSIONS", "LEDGER", "CLICKS", "SCORES", "RETURNS")
HOMES = (("FINANCE_PROD_DB", "STAGING", "FINANCE_ADMIN"), ("OPS_PROD_DB", "RAW", "OPS_ADMIN"),
         ("MARKETING_PROD_DB", "RAW", "MARKETING_ADMIN"), ("SALES_PROD_DB", "MARTS", "SALES_ADMIN"),
         ("PRODUCT_PROD_DB", "STAGING", "PRODUCT_ADMIN"))
FIRST_ID = 9_100_000


class _Grid:
    def __init__(self, b):
        self.b, self.w, self.rng = b, b.w, b.rng
        self.homes = [h for h in HOMES if (h[0], h[1]) in self.w.schema_id]
        self.users = [u["name"] for u in b.cat["users"] if not u.get("disabled")] or ["SYSTEM"]
        self.next_id = FIRST_ID
        self.n = 0

    def id(self) -> int:
        self.next_id += 1
        return self.next_id

    def home(self) -> tuple:
        self.n += 1
        return self.homes[self.n % len(self.homes)]

    def event(self, k: int, *, read=(), direct=(), written=()) -> None:
        self.n += 1
        when = self.b.ts(k, 8 + self.n % 10, self.n % 60)
        self.b.au("ACCESS_HISTORY", query_id=f"01lc-{self.n:07d}", query_start_time=when,
                  user_name=self.users[self.n % len(self.users)], direct_objects_accessed=list(direct or read),
                  base_objects_accessed=list(read), objects_modified=list(written), object_modified_by_ddl=None,
                  policies_referenced=[])

    def depends(self, target: tuple, kind: str, on: tuple) -> None:
        """`on` (a view here) is built on `target`, so the target shows a dependent."""
        self.b.au("OBJECT_DEPENDENCIES", referenced_database=target[0], referenced_schema=target[1],
                  referenced_object_name=target[2], referenced_object_id=target[3], referenced_object_domain=kind,
                  referencing_database=on[0], referencing_schema=on[1], referencing_object_name=on[2],
                  referencing_object_id=on[3], referencing_object_domain="VIEW", dependency_type="BY_NAME")


def _obj(domain: str, oid, db: str, sch: str, name: str) -> dict:
    return {"objectDomain": domain, "objectId": oid, "objectName": f"{db}.{sch}.{name}", "columns": []}


def _tables(g: _Grid) -> dict:
    b, w = g.b, g.w
    first = {}
    for band, k in BANDS:
        for i, (pat, reads, writes) in enumerate(PATTERNS):
            for copy in range(1 + (band in ("ARCHIVE", "LEGACY"))):
                db, sch, owner = g.home()
                stem = STEMS[(g.n + i) % len(STEMS)]
                name = f"{band}_{stem}_{pat}" + (f"_{copy + 1}" if copy else "")
                tid, sid, dbid = g.id(), w.schema_id[(db, sch)], w.dbs[db]
                gb = round(g.rng.uniform(0.2, 3) * (1 + 12 * (band in ("ARCHIVE", "LEGACY")) * (not copy)), 2)
                # an idle new table was just created; an idle old one was last touched at k
                created = k if not (reads or writes) else k + g.rng.randint(30, 400)
                b.au("TABLES", table_id=tid, table_name=name, table_schema_id=sid, table_schema=sch,
                     table_catalog_id=dbid, table_catalog=db, table_owner=owner, table_type="BASE TABLE",
                     is_transient="NO", auto_clustering_on="NO", row_count=int(gb * 4e6), bytes=int(gb * GB),
                     retention_time=1, created=b.ts(created, 9), last_altered=b.ts(k, 9), last_ddl=b.ts(created, 9),
                     last_ddl_by=owner, deleted=None, is_iceberg="NO", is_dynamic="NO", is_hybrid="NO")
                b.au("TABLE_STORAGE_METRICS", id=tid, table_name=name, table_schema_id=sid, table_schema=sch,
                     table_catalog_id=dbid, table_catalog=db, clone_group_id=tid, is_transient="NO",
                     active_bytes=int(gb * GB), time_travel_bytes=int(gb * GB * .02), failsafe_bytes=int(gb * GB * .05),
                     retained_for_clone_bytes=0, deleted=False, table_created=b.ts(created, 9))
                ref = _obj("Table", tid, db, sch, name)
                if reads:
                    g.event(k, read=[ref])
                if writes:
                    g.event(k, written=[ref])
                    start = b.ts(k, 2, 15)
                    b.au("TABLE_DML_HISTORY", start_time=start, end_time=start + dt.timedelta(minutes=20), table_id=tid,
                         table_name=name, schema_id=sid, schema_name=sch, database_id=dbid, database_name=db,
                         rows_added=5000, rows_removed=0, rows_updated=120)
                first.setdefault((band, pat), (db, sch, name, tid))
    # changed but not read: maintenance moved last_altered on a table created long ago
    db, sch, owner = g.home()
    tid, sid, dbid = g.id(), w.schema_id[(db, sch)], w.dbs[db]
    b.au("TABLES", table_id=tid, table_name="OLD_LEDGER_CHANGED_ONLY", table_schema_id=sid, table_schema=sch,
         table_catalog_id=dbid, table_catalog=db, table_owner=owner, table_type="BASE TABLE", is_transient="NO",
         auto_clustering_on="NO", row_count=100000, bytes=int(2 * GB), retention_time=1, created=b.ts(500, 9),
         last_altered=b.ts(3, 9), last_ddl=b.ts(500, 9), last_ddl_by=owner, deleted=None, is_iceberg="NO",
         is_dynamic="NO", is_hybrid="NO")
    b.au("TABLE_STORAGE_METRICS", id=tid, table_name="OLD_LEDGER_CHANGED_ONLY", table_schema_id=sid, table_schema=sch,
         table_catalog_id=dbid, table_catalog=db, clone_group_id=tid, is_transient="NO", active_bytes=int(2 * GB),
         time_travel_bytes=0, failsafe_bytes=0, retained_for_clone_bytes=0, deleted=False, table_created=b.ts(500, 9))
    return first


def _others(g: _Grid, tables: dict) -> None:
    b, w = g.b, g.w
    wh = next((x["name"] for x in b.cat["warehouses"]), None)
    base = _obj("Table", tables[("NEW", "RW")][3], *tables[("NEW", "RW")][:3])
    for band, k in BANDS:
        for used in (True, False):
            tag = "USED" if used else "UNUSED"
            created = k if not used else k + 90
            # views
            db, sch, owner = g.home()
            vid, name = g.id(), f"V_{band}_{tag}"
            b.au("VIEWS", table_id=vid, table_name=name, table_schema_id=w.schema_id[(db, sch)], table_schema=sch,
                 table_catalog_id=w.dbs[db], table_catalog=db, table_owner=owner, is_secure="YES" if band == "OLD" else "NO",
                 created=b.ts(created, 9), last_altered=b.ts(k, 9), last_ddl=b.ts(created, 9), last_ddl_by=owner,
                 deleted=None, owner_role_type="ROLE")
            if used:
                g.event(k, read=[base], direct=[_obj("View", vid, db, sch, name)])
            # the oldest tables still have a view on them, so they read as "check before dropping"
            if band in ("ARCHIVE", "LEGACY"):
                g.depends(tables[(band, "IDLE")], "TABLE", (db, sch, name, vid))
            # stages
            db, sch, owner = g.home()
            sid, name = g.id(), f"ST_{band}_{tag}"
            b.au("STAGES", stage_id=sid, stage_name=name, stage_schema_id=w.schema_id[(db, sch)], stage_schema=sch,
                 stage_catalog_id=w.dbs[db], stage_catalog=db, stage_url=None, stage_region=None,
                 stage_type="Internal Named", stage_owner=owner, created=b.ts(created, 9), last_altered=b.ts(k, 9),
                 deleted=None, owner_role_type="ROLE")
            if used:
                g.event(k, read=[base], direct=[_obj("Stage", sid, db, sch, name)])
            # functions
            db, sch, owner = g.home()
            fid, name = g.id(), f"F_{band}_{tag}"
            b.au("FUNCTIONS", function_id=fid, function_name=name, function_schema_id=w.schema_id[(db, sch)],
                 function_schema=sch, function_catalog_id=w.dbs[db], function_catalog=db, function_owner=owner,
                 argument_signature="(X NUMBER)", data_type="NUMBER", function_language="SQL",
                 is_external="NO", is_memoizable="NO", is_data_metric="NO", is_aggregate="NO", created=b.ts(created, 9),
                 last_altered=b.ts(k, 9), deleted=None, owner_role_type="ROLE")
            if used:
                g.event(k, read=[base], direct=[_obj("Function", fid, db, sch, name + "(NUMBER)")])
            # procedures: no id in the view, so events match by name
            db, sch, owner = g.home()
            name = f"P_{band}_{tag}"
            b.au("PROCEDURES", procedure_catalog_id=w.dbs[db], procedure_catalog=db,
                 procedure_schema_id=w.schema_id[(db, sch)], procedure_schema=sch, procedure_name=name,
                 procedure_owner=owner, argument_signature="()", procedure_language="SQL", created=b.ts(created, 9),
                 last_altered=b.ts(k, 9), deleted=None)
            if used:
                g.event(k, read=[base], direct=[{"objectDomain": "Procedure", "objectName": f"{db}.{sch}.{name}()", "columns": []}])
            # pipes
            db, sch, owner = g.home()
            pid, name = g.id(), f"PIPE_{band}_{tag}"
            b.au("PIPES", pipe_id=pid, pipe_name=name, pipe_schema_id=w.schema_id[(db, sch)], pipe_schema=sch,
                 pipe_catalog_id=w.dbs[db], pipe_catalog=db, is_autoingest_enabled="NO", notification_channel_name=None,
                 pipe_owner=owner, definition=None, created=b.ts(created, 9), last_altered=b.ts(k, 9), comment=None,
                 pattern=None, deleted=None, owner_role_type="ROLE")
            if used:
                hr = b.ts(k, 4)
                end = hr + dt.timedelta(hours=1)
                b.au("PIPE_USAGE_HISTORY", pipe_id=pid, pipe_name=name, start_time=hr, end_time=end, credits_used=0.02,
                     bytes_inserted=float(GB), files_inserted=3, bytes_billed=GB)
                b.au("METERING_HISTORY", service_type="PIPE", start_time=hr, end_time=end, entity_id=pid, entity_type="PIPE",
                     name=name, database_id=w.dbs[db], database_name=db, schema_id=w.schema_id[(db, sch)], schema_name=sch,
                     credits_used_compute=0.02, credits_used_cloud_services=0.0, credits_used=0.02, bytes=GB, files=3)
            # tasks
            db, sch, owner = g.home()
            tid, name = g.id(), f"TASK_{band}_{tag}"
            when = b.ts(k, 3)
            b.au("TASKS", created=b.ts(created, 9), last_altered=b.ts(k, 9), deleted=None, id=str(tid), task_name=name,
                 task_database_id=w.dbs[db], task_database=db, task_schema_id=w.schema_id[(db, sch)], task_schema=sch,
                 task_owner=owner, comment=None, warehouse=wh, schedule="USING CRON 0 3 * * * UTC", predecessors=[],
                 state="started" if used and k < 30 else "suspended", definition=None, condition=None,
                 allow_overlapping_execution=False, error_integration=None, last_committed=b.ts(created, 9),
                 last_suspended=None if used and k < 30 else b.ts(k, 9), owner_role_type="ROLE",
                 task_relations='{"Predecessors":[]}', last_suspended_reason=None, execute_as_user_id=None,
                 overlap_policy="NO_OVERLAP")
            if used:
                b.au("TASK_HISTORY", name=name, query_text=None, condition_text=None, schema_name=sch,
                     task_schema_id=w.schema_id[(db, sch)], database_name=db, task_database_id=w.dbs[db],
                     scheduled_time=when, completed_time=when + dt.timedelta(minutes=2), query_start_time=when,
                     state="SUCCEEDED", return_value=None, query_id=f"01lct-{tid}", error_code=None, error_message=None,
                     graph_version=1, run_id=tid, root_task_id=str(tid), scheduled_from="SCHEDULE", attempt_number=1,
                     instance_id=1, graph_run_group_id=f"lc-{tid}")


def add(b) -> None:
    g = _Grid(b)
    tables = _tables(g)
    _others(g, tables)
    # the account's ACCESS_HISTORY reaches back the full year, so no band reads as beyond the history
    g.event(364, read=[_obj("Table", tables[("NEW", "RW")][3], *tables[("NEW", "RW")][:3])])
