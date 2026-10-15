"""Demo storage: databases that grow, Time Travel and Fail-safe heavy tables, clones, stages and object types.

Four storage-only databases sit next to the catalog's sixteen:
  CLICKSTREAM_DB    grew sharply after a new event source (growth CRITICAL); clustered, churny and staging tables
  FEATURE_STORE_DB  steady 1% a day (growth WARN), 30-day retention, a CREATE OR REPLACE loop, experiments sprawl
  ARCHIVE_DB        flat, 90-day retention, large unread ledger tables and a schema of old exports
  LEGACY_DW_DB      dropped 20 days ago; its tables sit in Fail-safe and one is still pinned by a clone
They get TABLES, TABLE_STORAGE_METRICS, daily DATABASE_STORAGE_USAGE_HISTORY and reads attached to existing demo
queries, so the storage checks land in OK, WARN and CRITICAL. Serverless credits (clustering, search optimization,
materialized views, replication, hybrid tables) go into METERING_HISTORY; demo_billing rolls them up.
ARCHIVE_DB also has COOL and COLD archive tiers fed by a lifecycle policy, with retrievals.
Also: stages on three clouds, replication secondaries, external/Iceberg/hybrid/event/temporary tables, UDFs,
procedures, sequences, file formats, apps and views pointing at dropped tables.
"""
from __future__ import annotations

import datetime as dt

from tests.fake_snowflake import schema
from tests.fake_snowflake.data import ACCOUNT_LOCATOR, ACCOUNT_NAME, HISTORY_DAYS, ORG_NAME, REGION

GB = 1024 ** 3
TB = 1024 ** 4

DBS = [  # id, name, team, retention, created days, dropped days
    (431, "CLICKSTREAM_DB", "PLATFORM", 1, 400, None),
    (432, "FEATURE_STORE_DB", "DATA_SCIENCE", 30, 260, None),
    (433, "ARCHIVE_DB", "FINANCE", 90, 1100, None),
    (434, "LEGACY_DW_DB", "OPS", 14, 1500, 20),
]
SCHEMAS = [  # id, db, name
    (4301, "CLICKSTREAM_DB", "RAW"), (4302, "CLICKSTREAM_DB", "STAGING"), (4303, "CLICKSTREAM_DB", "CORE"),
    (4304, "CLICKSTREAM_DB", "BACKUP"), (4305, "FEATURE_STORE_DB", "FEATURES"), (4306, "FEATURE_STORE_DB", "EXPERIMENTS"),
    (4307, "ARCHIVE_DB", "LEDGER"), (4308, "ARCHIVE_DB", "EXPORTS"), (4309, "LEGACY_DW_DB", "MARTS"),
    (4310, "LEGACY_DW_DB", "PUBLIC"),
]
COLUMN_IDS = {"SESSION_ID": 3, "EVENT_DATE": 1, "EVENT_TS": 2, "PAGE_ID": 4, "ITEM_ID": 5, "CUSTOMER_ID": 6}
# Archive tiers on ARCHIVE_DB: a lifecycle policy set ARCH_START days ago moved old rows over ARCH_RAMP days.
ARCH_START, ARCH_RAMP = 190, 150
RETRIEVALS = (  # days back, table id, tier, GB: the ledger is pulled back from COOL often, invoices for audits
    [(k, 46051, "COOL", 8 + (k * 7) % 30) for k in (181, 170, 158, 149, 137, 126, 118, 104, 97, 85, 77, 66, 58, 49,
                                                  38, 31, 27, 21, 12, 4)]
    + [(172, 46052, "COLD", 180), (111, 46052, "COLD", 220), (64, 46052, "COLD", 140), (150, 46065, "COLD", 80),
       (40, 46072, "COOL", 60), (2, 46061, "COLD", 30)])
DROP_K = 20          # LEGACY_DW_DB dropped this many days ago; retention 14 days, so its tables entered Fail-safe at 6
FS_K = 6


def add(b) -> None:
    S = _Store(b)
    S.databases()
    S.tables()
    S.storage_history()
    S.archive()
    S.reads()
    S.pruning_and_clustering()
    S.search_and_mvs()
    S.stages()
    S.replication()
    S.object_types()
    S.code_and_apps()
    S.broken_views()
    S.reconcile_levels()


class _Store:
    def __init__(self, b):
        self.b, self.w, self.rng = b, b.w, b.rng
        self.cat = b.cat
        self.whs = {w["name"]: w for w in self.cat["warehouses"]}
        self.db_id = {d[1]: d[0] for d in DBS}
        self.sch_id = {(s[1], s[2]): s[0] for s in SCHEMAS}
        self.specs: list[dict] = []

    # ---- helpers ------------------------------------------------------------------------------------------------
    def au(self, view: str, **row) -> None:
        _check("account_usage", view, row)
        self.b.au(view, **row)

    def show(self, view: str, **row) -> None:
        _check("show", view, row)
        self.b.show(view, **row)

    def grant(self, privilege, on, name, grantee, deleted=False, schema_="", catalog="") -> None:
        back = self.rng.randint(30, 600)
        if not deleted:
            self.w.grant(privilege, on, name, grantee, days_back=back, schema_=schema_, catalog=catalog)
            return
        # dropped with LEGACY_DW_DB: the grant goes when the object does
        b = self.b
        self.au("GRANTS_TO_ROLES", created_on=b.ts(max(back, DROP_K + 30), 9), modified_on=b.ts(DROP_K, 14),
                deleted_on=b.ts(DROP_K, 14), privilege=privilege, granted_on=on, name=name,
                table_catalog=catalog or None, table_schema=schema_ or None, granted_to="ROLE", grantee_name=grantee,
                grant_option=False, granted_by="SYSADMIN", granted_by_role_type="ROLE", object_instance=None)

    def extend(self, db, k_from, nbytes, db_col="average_database_bytes", su_col="storage_bytes") -> None:
        """Add bytes(k) to a database's daily storage from k_from days back, and to the account total."""
        if not hasattr(self, "_dsuh"):
            self._dsuh = {}
            for r in self.w.rows.get(("account_usage", "DATABASE_STORAGE_USAGE_HISTORY"), []):
                self._dsuh[(r["database_name"], r["usage_date"])] = r
            self._su = {r["usage_date"]: r for r in self.w.rows.get(("account_usage", "STORAGE_USAGE"), [])}
        for k in range(min(k_from, HISTORY_DAYS), 0, -1):
            d = self.b.back(k)
            add = nbytes(k) if callable(nbytes) else nbytes
            row = self._dsuh.get((db, d))
            if row is not None:
                row[db_col] = (row.get(db_col) or 0) + add
            if su_col and d in self._su:
                self._su[d][su_col] = (self._su[d].get(su_col) or 0) + add

    def meter(self, service, start, credits, entity_id, name, entity_type, db=None, schema_=None) -> None:
        """One METERING_HISTORY hour; demo_billing rolls it into the daily and org views."""
        self.au("METERING_HISTORY", service_type=service, start_time=start, end_time=start + dt.timedelta(hours=1),
                entity_id=entity_id, entity_type=entity_type, name=name,
                database_id=self.db_id.get(db) or self.w.dbs.get(db) if db else None, database_name=db,
                schema_name=schema_, credits_used_compute=credits, credits_used_cloud_services=0.0, credits_used=credits)

    # ---- databases and schemas ----------------------------------------------------------------------------------
    def databases(self) -> None:
        b = self.b
        for dbid, name, team, ret, created, dropped in DBS:
            owner = f"{team}_ADMIN"
            self.w.dbs[name] = dbid
            self.au("DATABASES", database_id=dbid, database_name=name, database_owner=owner, is_transient="NO",
                    type="STANDARD", retention_time=ret, created=b.ts(created, 9),
                    last_altered=b.ts(dropped or self.rng.randint(2, 60), 9),
                    deleted=b.ts(dropped, 14) if dropped else None, owner_role_type="ROLE",
                    object_visibility="PRIVILEGED")
            if not dropped:
                self.show("databases", created_on=b.ts(created, 9), name=name, is_default="N", is_current="N",
                          origin="", owner=owner, comment="", options="", retention_time=str(ret), kind="STANDARD",
                          owner_role_type="ROLE")
            self.grant("OWNERSHIP", "DATABASE", name, owner, deleted=bool(dropped))
            self.grant("USAGE", "DATABASE", name, f"{team}_READ", deleted=bool(dropped))
        team_of = {d[1]: d[2] for d in DBS}
        ret_of = {d[1]: d[3] for d in DBS}
        drop_of = {d[1]: d[5] for d in DBS}
        created_of = {d[1]: d[4] for d in DBS}            # schemas come with their database, before any table
        for sid, db, name in SCHEMAS:
            team = team_of[db]
            owner = f"{team}_WRITE" if name in ("RAW", "STAGING") else f"{team}_ADMIN"
            self.w.schema_id[(db, name)] = sid
            self.au("SCHEMATA", schema_id=sid, schema_name=name, catalog_id=self.db_id[db], catalog_name=db,
                    schema_owner=owner, retention_time=ret_of[db], is_transient="NO", is_managed_access="NO",
                    created=b.ts(created_of[db] - self.rng.randint(0, 8), 9), last_altered=b.ts(self.rng.randint(1, 90), 9),
                    deleted=b.ts(drop_of[db], 14) if drop_of[db] else None, owner_role_type="ROLE")
            self.grant("OWNERSHIP", "SCHEMA", f"{db}.{name}", owner, schema_=name, catalog=db, deleted=bool(drop_of[db]))

    # ---- tables -------------------------------------------------------------------------------------------------
    def tables(self) -> None:
        r = self.rng
        T = []

        def t(tid, db, sch, name, team, active, tt, fs, rows, created, altered, retained=0, ck=None, clone_of=None,
              transient=False, dropped=None, entered_fs=None, live=True, **extra):
            T.append(dict(id=tid, db=db, schema=sch, name=name, team=team, active=active, tt=tt, fs=fs, rows=rows,
                          created=created, altered=altered, retained=retained, ck=ck, clone_of=clone_of,
                          transient=transient, dropped=dropped, entered_fs=entered_fs, live=live, **extra))

        # CLICKSTREAM_DB: a 9 TB event table clustered on a column queries rarely filter on, a 4 TB table without a
        # key, a snapshot rewritten 60% a day (12 TB of Fail-safe), staging tables loaded and truncated daily.
        t(46001, "CLICKSTREAM_DB", "RAW", "EVENTS_STREAM", "PLATFORM", 9000, 300, 2100, 60_000_000_000, 380, 0,
          ck="(EVENT_DATE)", dml=("append", 400_000_000))
        t(46002, "CLICKSTREAM_DB", "RAW", "PAGEVIEWS_RAW", "PLATFORM", 4000, 40, 280, 25_000_000_000, 300, 0,
          dml=("append", 150_000_000))
        t(46003, "CLICKSTREAM_DB", "CORE", "SESSION_STATE_SNAPSHOT", "PLATFORM", 3000, 1800, 12600, 2_000_000_000, 350,
          0, retained=5000, dml=("update", 1_200_000_000))
        t(46004, "CLICKSTREAM_DB", "STAGING", "STG_SESSIONS_LOAD", "PLATFORM", 600, 600, 1200, 400_000_000, 330, 0,
          dml=("reload", 400_000_000))
        t(46005, "CLICKSTREAM_DB", "STAGING", "STG_EVENTS_WORK", "PLATFORM", 800, 700, 5000, 4_000_000_000, 200, 0,
          dml=("reload", 4_000_000_000))
        t(46006, "CLICKSTREAM_DB", "STAGING", "STG_BOT_FILTER_TMP", "PLATFORM", 50, 50, 300, 200_000_000, 150, 0,
          dml=("reload", 200_000_000))
        t(46007, "CLICKSTREAM_DB", "BACKUP", "SESSION_STATE_BKP_0901", "PLATFORM", 40, 0, 0, 2_000_000_000, 34, 34,
          clone_of=46003)
        t(46008, "CLICKSTREAM_DB", "BACKUP", "SESSION_STATE_BKP_0915", "PLATFORM", 25, 0, 0, 2_000_000_000, 20, 20,
          clone_of=46003)
        # FEATURE_STORE_DB (30-day retention): Time Travel heavy features, a dev clone, a table rebuilt daily.
        t(46011, "FEATURE_STORE_DB", "FEATURES", "USER_FEATURES_DAILY", "DATA_SCIENCE", 2000, 2000, 450, 3_000_000_000,
          240, 0, retained=650, dml=("update", 100_000_000))
        t(46012, "FEATURE_STORE_DB", "FEATURES", "ITEM_EMBEDDINGS", "DATA_SCIENCE", 1200, 150, 60, 500_000_000, 200, 1,
          retained=120, dml=("append", 2_000_000))
        t(46013, "FEATURE_STORE_DB", "FEATURES", "TRAINING_SET", "DATA_SCIENCE", 30, 0, 0, 40_000_000, 1, 1)
        t(46014, "DATA_SCIENCE_DEV_DB", "SCRATCH", "USER_FEATURES_DEV", "DATA_SCIENCE", 15, 0, 0, 3_000_000_000, 60, 12,
          clone_of=46011, transient=True)
        stems = ["CHURN", "UPLIFT", "RANKER", "PRICING", "FRAUD", "LTV", "RECS", "SEARCH", "BASKET", "PROMO", "NPS"]
        for i in range(22):
            gb = round(r.uniform(2, 40), 1)
            t(46020 + i, "FEATURE_STORE_DB", "EXPERIMENTS", f"EXP_{stems[i % 11]}_V{i // 11 + 1}", "DATA_SCIENCE",
              gb, gb * r.choice([0, 0.1, 0.4]), gb * 0.05, int(gb * 4e6), r.randint(100, 250), r.randint(30, 100),
              read=i % 5 in (0, 3))
        # ARCHIVE_DB (90-day retention): a ledger restated 58 days ago, old invoices read 110 days ago, exports.
        t(46051, "ARCHIVE_DB", "LEDGER", "GL_HISTORY", "FINANCE", 9000, 12000, 1300, 40_000_000_000, 1000, 58,
          cool=2400)
        t(46052, "ARCHIVE_DB", "LEDGER", "INVOICES_2019", "FINANCE", 900, 0, 0, 2_000_000_000, 1000, 400,
          read_days=[110], cold=1700)
        t(46053, "ARCHIVE_DB", "LEDGER", "AP_AGING_SNAPSHOT", "FINANCE", 40, 2, 3, 90_000_000, 500, 41, read_days=[40])
        t(46054, "ARCHIVE_DB", "LEDGER", "TRIAL_BALANCE_MONTHLY", "FINANCE", 5, 0, 0, 2_000_000, 700, 95)
        for i in range(26):
            month = dt.date(2024, 1, 1) + dt.timedelta(days=31 * i)
            empty = i in (7, 19)
            gb = 0 if empty else round(r.uniform(3, 15), 1)
            tier = {} if empty or i >= 18 else ({"cold": round(gb * 4, 1)} if i < 10 else {"cool": round(gb * 3, 1)})
            t(46060 + i, "ARCHIVE_DB", "EXPORTS", f"EXPORT_{month:%Y%m}", "FINANCE", gb, 0, 0,
              0 if empty else int(gb * 3e6), 640 - 25 * i if i < 22 else 100 + i, 640 - 25 * i if i < 22 else 100 + i,
              read=i in (24, 25), **tier)
        # LEGACY_DW_DB, dropped: its tables wait out Fail-safe, and a dev snapshot clone still pins FACT_SALES.
        for tid, name, fs, ret in ((46091, "FACT_SALES", 3000, 1500), (46092, "AGG_MONTHLY", 600, 0),
                                   (46093, "DIM_STORES", 40, 0)):
            t(tid, "LEGACY_DW_DB", "MARTS", name, "OPS", 0, 0, fs, 0, 1400, DROP_K, retained=ret, live=False,
              dropped=DROP_K, entered_fs=FS_K)
        t(46094, "OPS_DEV_DB", "SCRATCH", "FACT_SALES_SNAPSHOT", "OPS", 30, 0, 0, 900_000_000, 300, 300,
          clone_of=46091, transient=True)
        self.specs = T

        b = self.b
        for s in T:
            fqn = f"{s['db']}.{s['schema']}.{s['name']}"
            s["fqn"] = fqn
            sid = self.sch_id.get((s["db"], s["schema"])) or self.w.schema_id[(s["db"], s["schema"])]
            dbid = self.db_id.get(s["db"]) or self.w.dbs[s["db"]]
            s["schema_id"], s["db_id"] = sid, dbid
            owner = f"{s['team']}_WRITE" if s["schema"] in ("RAW", "STAGING", "SCRATCH") else f"{s['team']}_ADMIN"
            s["owner"] = owner
            ret = 0 if s["transient"] else {d[1]: d[3] for d in DBS}.get(s["db"], 1)
            trans = "YES" if s["transient"] else "NO"
            nbytes = int(s["active"] * GB)
            dropped_at = b.ts(s["dropped"], 14) if s["dropped"] else None
            arch = dict(archive_storage_cool_bytes=int(s.get("cool", 0) * GB),
                        archive_storage_cold_bytes=int(s.get("cold", 0) * GB)) if s["db"] == "ARCHIVE_DB" else {}
            self.au("TABLES", table_id=s["id"], table_name=s["name"], table_schema_id=sid, table_schema=s["schema"],
                    table_catalog_id=dbid, table_catalog=s["db"], table_owner=owner, table_type="BASE TABLE",
                    is_transient=trans, clustering_key=s["ck"], auto_clustering_on="YES" if s["ck"] else "NO",
                    row_count=s["rows"], bytes=nbytes, retention_time=ret, created=b.ts(s["created"], 9),
                    last_altered=b.ts(s["altered"], 3 if s["altered"] < s["created"] else 10), last_ddl=b.ts(max(s["altered"], min(s["created"], 90)), 9),
                    last_ddl_by=owner, deleted=dropped_at, is_iceberg="NO", is_dynamic="NO", is_hybrid="NO", **arch)
            self.au("TABLE_STORAGE_METRICS", id=s["id"], table_name=s["name"], table_schema_id=sid,
                    table_schema=s["schema"], table_catalog_id=dbid, table_catalog=s["db"],
                    clone_group_id=s["clone_of"] or s["id"], is_transient=trans, active_bytes=nbytes,
                    time_travel_bytes=int(s["tt"] * GB), failsafe_bytes=0 if s["transient"] else int(s["fs"] * GB),
                    retained_for_clone_bytes=int(s["retained"] * GB), deleted=not s["live"],
                    table_created=b.ts(s["created"], 9), table_dropped=dropped_at,
                    table_entered_failsafe=b.ts(s["entered_fs"], 14) if s["entered_fs"] else None,
                    catalog_dropped=dropped_at if s["db"] == "LEGACY_DW_DB" else None,
                    schema_dropped=dropped_at if s["db"] == "LEGACY_DW_DB" else None,
                    **{k.replace("_bytes", "_active_bytes"): v for k, v in arch.items()})
            self.grant("OWNERSHIP", "TABLE", fqn, owner, schema_=s["schema"], catalog=s["db"], deleted=not s["live"])
            if s["live"]:
                self.w.tables.append(dict(
                    id=s["id"], db=s["db"], schema=s["schema"], name=s["name"], type="BASE TABLE", transient=trans,
                    rows=s["rows"], bytes=nbytes, clustering=s["ck"] or "", dynamic="NO", hybrid="NO", iceberg="NO",
                    owner=owner, fqn=fqn, demo=True, team=s["team"], last_altered_days=s["altered"]))

        # TRAINING_SET is rebuilt with CREATE OR REPLACE every night: each old copy stays in Time Travel 30 days.
        for k in range(1, 9):
            self.au("TABLE_STORAGE_METRICS", id=46100 + k, table_name="TRAINING_SET", table_schema_id=4305,
                    table_schema="FEATURES", table_catalog_id=432, table_catalog="FEATURE_STORE_DB",
                    clone_group_id=46100 + k, is_transient="NO", active_bytes=0, time_travel_bytes=int(30 * GB),
                    failsafe_bytes=0, retained_for_clone_bytes=0, deleted=True, table_created=b.ts(k + 1, 1),
                    table_dropped=b.ts(k, 1))
        # A Fail-safe copy with no names left, as Snowflake shows them.
        self.au("TABLE_STORAGE_METRICS", id=46099, table_name=None, table_schema_id=4302, table_schema=None,
                table_catalog_id=431, table_catalog=None, clone_group_id=46099, is_transient="NO", active_bytes=0,
                time_travel_bytes=0, failsafe_bytes=int(200 * GB), retained_for_clone_bytes=0, deleted=True,
                table_created=b.ts(90, 9), table_dropped=b.ts(5, 9), table_entered_failsafe=b.ts(4, 9))

        # DML: loads every night at 02:00 over the last 95 days.
        for k in range(1, 96):
            for s in T:
                if "dml" not in s:
                    continue
                kind, n = s["dml"]
                n = int(n * self.rng.uniform(0.8, 1.2))
                added, removed, updated = {"append": (n, 0, 0), "update": (n // 20, 0, n),
                                           "reload": (n, n, 0)}[kind]
                start = b.ts(k, 2, self.rng.randint(0, 40))
                self.au("TABLE_DML_HISTORY", start_time=start, end_time=start + dt.timedelta(minutes=50),
                        table_id=s["id"], table_name=s["name"], schema_id=s["schema_id"], schema_name=s["schema"],
                        database_id=s["db_id"], database_name=s["db"], rows_added=added, rows_removed=removed,
                        rows_updated=updated)

    # ---- daily storage per database, and the account totals ----------------------------------------------------
    def storage_history(self) -> None:
        b = self.b
        end = {}
        for s in self.specs:
            if s["db"] not in self.db_id:
                continue
            e = end.setdefault(s["db"], [0.0, 0.0])
            if s["live"]:
                e[0] += (s["active"] + s["tt"] + s["retained"]) * GB
                e[1] += s["fs"] * GB
        cool_tot = sum(s.get("cool", 0) for s in self.specs) * GB
        cold_tot = sum(s.get("cold", 0) for s in self.specs) * GB
        temp = {}                                         # COLD retrievals sit in standard storage until used (3 days)
        for k, _tid, tier, gb in RETRIEVALS:
            if tier == "COLD":
                for j in range(k, k - 3, -1):
                    temp[j] = temp.get(j, 0) + gb * GB
        legacy_live = 5140 * GB                           # before the drop: its tables plus the clone-pinned data

        def curve(db, k):
            if db == "CLICKSTREAM_DB":                    # a new event source from 45 days ago tripled it
                return 1.0 if k <= 1 else (0.33 if k >= 45 else 0.33 + 0.67 * (45 - k) / 44)
            if db == "FEATURE_STORE_DB":
                return 1.0075 ** (-k)
            return 1.0

        su = {r["usage_date"]: r for r in self.w.rows.get(("account_usage", "STORAGE_USAGE"), [])}
        for k in range(HISTORY_DAYS, 0, -1):
            d = b.back(k)
            add_db = add_fs = add_cool = add_cold = 0.0
            for dbid, name, team, ret, created, dropped in DBS:
                if k > created:
                    continue
                noise = 1 + self.rng.uniform(-0.004, 0.004)
                deleted = None
                if name == "LEGACY_DW_DB":
                    if k > DROP_K:
                        db_b, fs_b = legacy_live * noise, 0.05 * legacy_live
                    elif k > FS_K:                        # dropped: everything is in Time Travel for 14 days
                        db_b, fs_b, deleted = legacy_live, 0.05 * legacy_live, b.ts(DROP_K, 14)
                    else:                                 # then in Fail-safe, except what the clone pins
                        db_b, fs_b, deleted = 1500 * GB, 3640 * GB, b.ts(DROP_K, 14)
                elif name == "ARCHIVE_DB":
                    db_b, fs_b = end[name][0] * noise, end[name][1]
                    if k > 58:                            # before the restatement, Time Travel held 2 TB, not 12
                        db_b -= 10000 * GB
                    arch_k = _arch_ramp(k)
                    db_b += (cool_tot + cold_tot) * (1 - arch_k)   # not yet moved to the archive tiers
                else:
                    f = curve(name, k) * noise
                    db_b, fs_b = end[name][0] * f, end[name][1] * f
                cool = cool_tot * _arch_ramp(k) if name == "ARCHIVE_DB" else 0.0
                cold = cold_tot * _arch_ramp(k) if name == "ARCHIVE_DB" else 0.0
                self.au("DATABASE_STORAGE_USAGE_HISTORY", usage_date=d, database_id=dbid, database_name=name,
                        deleted=deleted, average_database_bytes=db_b, average_failsafe_bytes=fs_b,
                        average_hybrid_table_storage_bytes=0.0, average_archive_storage_cool_bytes=cool,
                        average_archive_storage_cold_bytes=cold)
                add_cool += cool
                add_cold += cold
                add_db += db_b
                add_fs += fs_b
            row = su.get(d)
            if row is not None:                           # the account total the Scale step built, extended
                row["storage_bytes"] += add_db
                row["failsafe_bytes"] += add_fs
                row["archive_storage_cool_bytes"] = (row.get("archive_storage_cool_bytes") or 0) + add_cool
                row["archive_storage_cold_bytes"] = (row.get("archive_storage_cold_bytes") or 0) + add_cold
                row["archive_storage_retrieval_temp_bytes"] = (
                    (row.get("archive_storage_retrieval_temp_bytes") or 0) + temp.get(k, 0))

    def reconcile_levels(self) -> None:
        """Each database's daily storage ends where its tables' storage is today, so the table and database
        levels agree; the account total moves by the same bytes each day."""
        tsm: dict = {}
        for r in self.w.rows.get(("account_usage", "TABLE_STORAGE_METRICS"), []):
            if r.get("catalog_dropped") is not None:
                continue
            e = tsm.setdefault(r["table_catalog"], [0.0, 0.0])
            e[0] += sum(r.get(c) or 0 for c in ("active_bytes", "time_travel_bytes", "retained_for_clone_bytes"))
            e[1] += r.get("failsafe_bytes") or 0
        rows: dict = {}
        for r in self.w.rows.get(("account_usage", "DATABASE_STORAGE_USAGE_HISTORY"), []):
            rows.setdefault(r["database_name"], []).append(r)
        su = {r["usage_date"]: r for r in self.w.rows.get(("account_usage", "STORAGE_USAGE"), [])}
        for db, (db_b, fs_b) in tsm.items():
            if db in ("LEGACY_DW_DB", "ARCHIVE_DB") or db not in rows or db_b < GB:
                continue
            last = max(rows[db], key=lambda r: r["usage_date"])
            for col, target, su_col in (("average_database_bytes", db_b, "storage_bytes"),
                                        ("average_failsafe_bytes", fs_b, "failsafe_bytes")):
                cur = last.get(col) or 0.0
                if cur <= 0 or abs(target - cur) <= 0.15 * max(target, cur):
                    continue
                f = target / cur
                for r in rows[db]:
                    old = r.get(col) or 0.0
                    r[col] = old * f
                    if r["usage_date"] in su:
                        su[r["usage_date"]][su_col] = (su[r["usage_date"]].get(su_col) or 0.0) + old * (f - 1)

    # ---- archive tiers: retrievals and the credits of writing, processing and running the policy ---------------
    def archive(self) -> None:
        b = self.b
        by_id = {s["id"]: s for s in self.specs}
        for k, tid, tier, gb in RETRIEVALS:
            s = by_id[tid]
            start = b.ts(k, 7, self.rng.randint(0, 50))
            self.au("ARCHIVE_STORAGE_DATA_RETRIEVAL_USAGE_HISTORY", start_time=start,
                    end_time=start + dt.timedelta(minutes=self.rng.randint(20, 90)), object_type="TABLE",
                    object_id=tid, object_name=s["name"], schema_id=s["schema_id"], schema_name=s["schema"],
                    database_id=s["db_id"], database_name=s["db"], bytes=int(gb * GB), archive_storage_tier=tier)
            self.meter("ARCHIVE_STORAGE_RETRIEVAL_FILE_PROCESSING", b.ts(k, 7), gb * 0.004 * self.rng.uniform(0.8, 1.2),
                       tid, s["name"], "TABLE", s["db"], s["schema"])
        for k in range(min(ARCH_START, HISTORY_DAYS), 0, -1):
            backfill = _arch_ramp(k) < 1                  # the first months move years of rows
            c = self.rng.uniform(1.2, 2.2) if backfill else self.rng.uniform(0.15, 0.4)
            self.meter("ARCHIVE_STORAGE_WRITE", b.ts(k, 1), c, 48401, "SLP_ARCHIVE_LEDGER", "STORAGE_LIFECYCLE_POLICY",
                       "ARCHIVE_DB")
            self.meter("STORAGE_LIFECYCLE_POLICY_EXECUTION", b.ts(k, 0), self.rng.uniform(0.04, 0.1), 48401,
                       "SLP_ARCHIVE_LEDGER", "STORAGE_LIFECYCLE_POLICY", "ARCHIVE_DB")

    # ---- reads: ACCESS_HISTORY rows for existing demo queries that have none yet --------------------------------
    def reads(self) -> None:
        b = self.b
        seen = {r["query_id"] for r in self.w.rows.get(("account_usage", "ACCESS_HISTORY"), [])}
        demo_wh = {w["name"]: w for w in self.cat["warehouses"]}
        pool = []
        for q in self.w.q_rows:
            w = demo_wh.get(q.get("warehouse_name"))
            if (w is None or q["query_id"] in seen or q["execution_status"] != "SUCCESS"
                    or q["query_type"] != "SELECT" or not q.get("partitions_total")):
                continue
            k = (b.as_of - q["start_time"].date()).days
            pool.append((k, q, w))
        self.rng.shuffle(pool)
        used: set = set()
        by_id = {s["id"]: s for s in self.specs}

        def take(n, ok):
            out = []
            for k, q, w in pool:
                if len(out) >= n:
                    break
                if q["query_id"] not in used and ok(k, q, w):
                    used.add(q["query_id"])
                    out.append(q)
            return out

        def poor(q):
            return q["partitions_scanned"] / q["partitions_total"] >= 0.85

        def good(q):
            return q["partitions_scanned"] / q["partitions_total"] < 0.4

        def emit(q, fqn, oid, domain="Table", cols=("ID",)):
            o = {"objectDomain": domain, "objectName": fqn, "objectId": oid,
                 "columns": [{"columnId": 2000 + i, "columnName": c} for i, c in enumerate(cols)]}
            self.au("ACCESS_HISTORY", query_id=q["query_id"], query_start_time=q["start_time"],
                    user_name=q["user_name"], direct_objects_accessed=[o], base_objects_accessed=[o],
                    objects_modified=[], policies_referenced=[], root_query_id=q["query_id"])

        heavy = ("WH_ETL", "WH_ML", "WH_ADHOC")
        analysts = ("PLATFORM", "PRODUCT", "MARKETING", "DATA_SCIENCE", "SALES")
        plan = [  # table, how many reads, which queries
            (46002, 400, lambda k, q, w: k <= 90 and w["like"] in heavy and w["team"] in analysts and poor(q),
             ("EVENT_TS", "PAGE_ID")),
            (46001, 300, lambda k, q, w: k <= 90 and w["team"] in analysts, ("EVENT_DATE", "SESSION_ID")),
            (46003, 150, lambda k, q, w: k <= 90 and w["team"] in ("PLATFORM", "PRODUCT"), ("SESSION_ID",)),
            (46012, 160, lambda k, q, w: k <= 90 and w["team"] == "DATA_SCIENCE" and good(q), ("ITEM_ID", "VECTOR")),
            (46011, 120, lambda k, q, w: k <= 90 and w["team"] in ("DATA_SCIENCE", "RISK"), ("USER_ID",)),
            (46004, 60, lambda k, q, w: k <= 60 and w["team"] == "PLATFORM", ("SESSION_ID",)),
            (46007, 3, lambda k, q, w: 20 <= k <= 34 and w["team"] == "PLATFORM", ("SESSION_ID",)),
        ]
        for s in self.specs:
            if s.get("read"):
                plan.append((s["id"], 3, lambda k, q, w, t=s["team"]: k <= 80 and w["team"] == t, ("ID",)))
            for day in s.get("read_days", []):
                plan.append((s["id"], 1, lambda k, q, w, d=day, t=s["team"]: abs(k - d) <= 3 and w["team"] == t,
                             ("ID", "AMOUNT")))
        for tid, n, ok, cols in plan:
            s = by_id[tid]
            for q in take(n, ok):
                emit(q, s["fqn"], tid, cols=cols)
        self.extra_reads = (take, emit)               # used by the external and Iceberg tables below

    # ---- column pruning and automatic clustering ---------------------------------------------------------------
    def pruning_and_clustering(self) -> None:
        b = self.b
        wh = self.whs

        def prune(tid, db, sch, name, col, k, queries, exec_ms, scanned, pruned, rows, matched, whn, sos=None):
            w = wh[whn]
            common = dict(interval_start_time=b.ts(k, 10), interval_end_time=b.ts(k, 11), table_id=tid,
                          table_name=name, schema_id=self.w.schema_id[(db, sch)], schema_name=sch,
                          database_id=self.w.dbs[db], database_name=db, warehouse_id=w["id"], warehouse_name=whn,
                          query_hash=f"hst{tid}{whn[-4:]}", query_parameterized_hash=f"hst{tid}{whn[-4:]}",
                          num_queries=queries, aggregate_query_elapsed_time=exec_ms + queries * 200,
                          aggregate_query_compilation_time=queries * 200, aggregate_query_execution_time=exec_ms,
                          partitions_scanned=scanned, partitions_pruned=pruned, rows_scanned=rows,
                          rows_pruned=max(rows - matched, 0), rows_matched=matched)
            if col:
                self.au("COLUMN_QUERY_PRUNING_HISTORY", column_id=COLUMN_IDS[col], column_name=col,
                        variant_path=None, access_type="WHERE", search_optimization_supported_expressions=sos,
                        **common)
            else:
                self.au("TABLE_QUERY_PRUNING_HISTORY", **common)

        for k in range(2, 97, 3):
            j = self.rng.uniform(0.7, 1.3)
            # EVENTS_STREAM: clustered on EVENT_DATE, but most query time filters on SESSION_ID.
            prune(46001, "CLICKSTREAM_DB", "RAW", "EVENTS_STREAM", "SESSION_ID", k, 40, int(9e6 * j), 90_000, 10_000,
                  int(4e9), int(2e6), "WH_PRODUCT_BI")
            prune(46001, "CLICKSTREAM_DB", "RAW", "EVENTS_STREAM", "EVENT_DATE", k, 25, int(2e6 * j), 8_000, 92_000,
                  int(5e8), int(4e8), "WH_PLATFORM_BI")
            prune(46001, "CLICKSTREAM_DB", "RAW", "EVENTS_STREAM", None, k, 65, int(1.2e7 * j), 98_000, 102_000,
                  int(4.5e9), int(4e8), "WH_PRODUCT_BI")
            # PAGEVIEWS_RAW: no key, every query scans nearly all of it.
            prune(46002, "CLICKSTREAM_DB", "RAW", "PAGEVIEWS_RAW", "EVENT_TS", k, 30, int(6e6 * j), 38_000, 2_000,
                  int(2e9), int(3e8), "WH_PLATFORM_ADHOC")
            prune(46002, "CLICKSTREAM_DB", "RAW", "PAGEVIEWS_RAW", "PAGE_ID", k, 12, int(2e6 * j), 39_000, 1_000,
                  int(1e9), int(1e7), "WH_MARKETING_ADHOC")
            prune(46002, "CLICKSTREAM_DB", "RAW", "PAGEVIEWS_RAW", None, k, 42, int(8e6 * j), 77_000, 3_000,
                  int(3e9), int(3.1e8), "WH_PLATFORM_ADHOC")
            # ITEM_EMBEDDINGS: point lookups by ITEM_ID, a search optimization candidate.
            prune(46012, "FEATURE_STORE_DB", "FEATURES", "ITEM_EMBEDDINGS", "ITEM_ID", k, 50, int(1.5e6 * j), 3_000,
                  9_000, int(4e8), int(8e5), "WH_DATA_SCIENCE_BI", sos=["EQUALITY"])
            prune(46012, "FEATURE_STORE_DB", "FEATURES", "ITEM_EMBEDDINGS", None, k, 50, int(1.5e6 * j), 3_000,
                  9_000, int(4e8), int(8e5), "WH_DATA_SCIENCE_BI")
            # catalog tables clustered on EVENT_DATE and filtered on it: the key matches.
            for tid, db, sch, name, whn in ((40116, "RISK_PROD_DB", "STAGING", "CLAIMS_116", "WH_RISK_BI"),
                                            (40108, "PRODUCT_PROD_DB", "MARTS", "SESSIONS_108", "WH_PRODUCT_BI"),
                                            (40136, "OPS_PROD_DB", "RAW", "SESSIONS_136", "WH_OPS_ETL")):
                prune(tid, db, sch, name, "EVENT_DATE", k, 20, int(8e5 * j), 400, 3_600, int(5e7), int(4e7), whn)
                prune(tid, db, sch, name, "CUSTOMER_ID", k, 6, int(2e5 * j), 2_000, 2_000, int(2e7), int(1e5), whn)
                prune(tid, db, sch, name, None, k, 26, int(1e6 * j), 2_400, 5_600, int(7e7), int(4e7), whn)

        # automatic clustering: EVENTS_STREAM reclusters ~25x its size a month; the catalog tables a little.
        tabs = [(46001, "CLICKSTREAM_DB", "RAW", "EVENTS_STREAM", (1, 9, 17), 3.5, 2.5 * TB),
                (40116, "RISK_PROD_DB", "STAGING", "CLAIMS_116", (4,), 1.2, 0.15 * TB),
                (40108, "PRODUCT_PROD_DB", "MARTS", "SESSIONS_108", (5,), 0.25, 0.02 * TB),
                (40136, "OPS_PROD_DB", "RAW", "SESSIONS_136", (6,), 0.5, 0.04 * TB)]
        for k in range(HISTORY_DAYS, 0, -1):
            for tid, db, sch, name, hours, credits, nbytes in tabs:
                if tid == 40136 and k % 2:
                    continue
                for h in hours:
                    c = credits * self.rng.uniform(0.6, 1.4)
                    start = b.ts(k, h)
                    self.au("AUTOMATIC_CLUSTERING_HISTORY", start_time=start, end_time=start + dt.timedelta(hours=1),
                            credits_used=c, num_bytes_reclustered=int(nbytes * c / credits),
                            num_rows_reclustered=int(nbytes * c / credits / 150), table_id=tid, table_name=name,
                            schema_id=self.w.schema_id[(db, sch)], schema_name=sch, database_id=self.w.dbs[db],
                            database_name=db, version="CLASSIC")
                    self.meter("AUTO_CLUSTERING", start, c, tid, name, "TABLE", db, sch)

    # ---- search optimization and materialized views -------------------------------------------------------------
    def search_and_mvs(self) -> None:
        b = self.b
        # GL_HISTORY keeps a search optimization index nobody benefits from: no one reads the table.
        for k in range(HISTORY_DAYS, 0, -1):
            if self.rng.random() < 0.7:
                c = 0.4 * self.rng.uniform(0.6, 1.4)
                start = b.ts(k, 5)
                self.au("SEARCH_OPTIMIZATION_HISTORY", start_time=start, end_time=start + dt.timedelta(hours=1),
                        credits_used=c, index_id=460510, index_name="SOS_GL_HISTORY",
                        index_type="Search Optimization Index", base_table_id=46051, base_table_name="GL_HISTORY",
                        schema_id=4307, schema_name="LEDGER", database_id=433, database_name="ARCHIVE_DB")
                self.meter("SEARCH_OPTIMIZATION", start, c, 46051, "GL_HISTORY", "TABLE", "ARCHIVE_DB", "LEDGER")
        # the catalog's materialized views refresh daily, from a few cents to a few credits
        mvs = [t for t in self.cat["tables"] if t["type"] == "MATERIALIZED VIEW"]
        per_day = {t["id"]: self.rng.choice([0.02, 0.1, 0.4, 1.0, 2.5]) for t in mvs}
        for k in range(185, 0, -1):
            for t in mvs:
                c = per_day[t["id"]] * self.rng.uniform(0.5, 1.5)
                start = b.ts(k, 4)
                self.au("MATERIALIZED_VIEW_REFRESH_HISTORY", start_time=start, end_time=start + dt.timedelta(hours=1),
                        credits_used=round(c, 6), table_id=t["id"], table_name=t["name"], schema_id=t["schema_id"],
                        schema_name=t["schema"], database_id=t["db_id"], database_name=t["db"])
                self.meter("MATERIALIZED_VIEW", start, c, t["id"], t["name"], "TABLE", t["db"], t["schema"])

    # ---- stages -------------------------------------------------------------------------------------------------
    def stages(self) -> None:
        b = self.b
        users = {u["name"]: u for u in self.cat["users"]}
        live_user = next(u for u in self.cat["users"] if u["team"] == "DATA_SCIENCE" and not u["disabled"]
                         and u["type"] == "PERSON")
        st = [  # kind, id, db, schema, name, GB, newest file age (days), created, last altered, extra
            ("Internal Named", 48101, "PLATFORM_PROD_DB", "RAW", "CLICKSTREAM_LANDING", 900, 0, 380, 3, {}),
            ("Internal Named", 48102, "FINANCE_PROD_DB", "RAW", "ERP_EXPORTS", 1200, 140, 700, 150, {}),
            ("Internal Named", 48103, "MARKETING_PROD_DB", "RAW", "AD_UPLOADS", 150, 75, 400, 120, {}),
            ("Internal Named", 48104, "DATA_SCIENCE_PROD_DB", "RAW", "MODEL_ARTIFACTS", 450, 10, 300, 10, {"directory": True}),
            ("Internal Named", 48105, "LEGACY_DW_DB", "PUBLIC", "NIGHTLY_EXPORT", 300, 25, 1400, 25,
             {"catalog_dropped": b.ts(DROP_K, 14), "schema_dropped": b.ts(DROP_K, 14)}),
            ("User", users["AMIR_QUILL"]["id"], None, None, "AMIR_QUILL", 350, 200, None, None, {}),
            ("User", users["HANA_IVES"]["id"], None, None, "HANA_IVES", 20, 120, None, None, {}),
            ("User", live_user["id"], None, None, live_user["name"], 60, 1, None, None, {}),
            ("Table", 46004, "CLICKSTREAM_DB", "STAGING", "STG_SESSIONS_LOAD", 40, 0, 330, None, {}),
        ]
        latest = b.back(2)                               # the details view lags up to 2 days
        for kind, sid, db, sch, name, gb, age, created, altered, extra in st:
            newest = dt.datetime.combine(latest, dt.time(3)) - dt.timedelta(days=age)
            for k in range(2, 97):
                if k > 2 and self.rng.random() < 0.06:
                    continue                             # best effort: some days are missing
                grow = 1.0 if age > 5 else 1 - 0.004 * (k - 2)
                self.au("STAGE_STORAGE_USAGE_DETAILS", usage_date=b.back(k), catalog_name=db,
                        catalog_id=self.w.dbs.get(db) if db else None, schema_name=sch,
                        schema_id=self.w.schema_id.get((db, sch)) if db else None, entity_name=name, stage_type=kind,
                        entity_id=sid, bytes=int(gb * GB * grow), file_count=max(1, int(gb * GB * grow) // (64 * 1024 ** 2)),
                        stage_created=b.ts(created, 9) if created else None, stage_dropped=None,
                        catalog_created=b.ts(500, 9) if db else None, catalog_dropped=extra.get("catalog_dropped"),
                        schema_created=b.ts(450, 9) if db else None, schema_dropped=extra.get("schema_dropped"),
                        max_last_modified=min(newest, dt.datetime.combine(b.back(k), dt.time(3))),
                        min_last_modified=newest - dt.timedelta(days=90))
            if kind == "Internal Named":
                dropped = extra.get("catalog_dropped")
                self.au("STAGES", stage_id=sid, stage_name=name, stage_schema_id=self.w.schema_id[(db, sch)],
                        stage_schema=sch, stage_catalog_id=self.w.dbs[db], stage_catalog=db, stage_url=None,
                        stage_region=None, stage_type="Internal Named", stage_owner=f"{_team(db)}_WRITE",
                        created=b.ts(created, 9), last_altered=b.ts(altered, 9), deleted=dropped,
                        owner_role_type="ROLE")
                if not dropped:
                    self.show("stages", created_on=b.ts(created, 9), name=name, database_name=db, schema_name=sch,
                              url="", has_credentials="N", has_encryption_key="N", owner="", comment="",
                              region=None, type="INTERNAL", cloud=None, storage_integration=None,
                              owner_role_type="ROLE", directory_enabled="Y" if extra.get("directory") else "N")
        # external stages on three clouds: integrations, keys, a client-side encrypted drop and an S3-compatible store
        ext = [  # id, db, schema, name, url, integration, cloud, region, encryption key, endpoint, directory
            (48111, "MARKETING_PROD_DB", "RAW", "S3_AD_PARTNER", "s3://demo-bucket/ad-partner/", "S3_DEMO_INT", "AWS",
             "us-east-1", False, None, False),
            (48112, "PLATFORM_PROD_DB", "RAW", "S3_EVENTS_EXPORT", "s3://demo-bucket/events/", "S3_DEMO_INT", "AWS",
             "us-east-1", False, None, False),
            (48113, "RISK_PROD_DB", "RAW", "S3_BUREAU_DROP", "s3://demo-bucket/bureau/", None, "AWS", "us-east-1",
             True, None, False),
            (48114, "PRODUCT_PROD_DB", "RAW", "AZ_APP_TELEMETRY",
             "azure://demoaccount.blob.core.windows.net/telemetry/", "AZURE_DEMO_INT", "AZURE", "westeurope", False,
             None, True),
            (48115, "OPS_PROD_DB", "RAW", "GCS_VENDOR_LOGS", "gcs://demo-vendor-logs/daily/", "GCS_INT_LEGACY", "GCP",
             "us-central1", False, None, False),
            (48116, "DATA_SCIENCE_PROD_DB", "RAW", "S3C_LAB_DATASETS", "s3compat://lab-datasets/curated/", None, None,
             None, False, "storage.lab.example.com", False),
        ]
        for sid, db, sch, name, url, integ, cloud, region, enc, endpoint, directory in ext:
            owner = f"{_team(db)}_WRITE"
            created = self.rng.randint(100, 500)
            self.au("STAGES", stage_id=sid, stage_name=name, stage_schema_id=self.w.schema_id[(db, sch)],
                    stage_schema=sch, stage_catalog_id=self.w.dbs[db], stage_catalog=db, stage_url=url,
                    stage_region=region, stage_type="External Named", stage_owner=owner,
                    created=b.ts(created, 9), last_altered=b.ts(self.rng.randint(5, min(200, created)), 9),
                    owner_role_type="ROLE", storage_integration=integ)
            self.show("stages", created_on=b.ts(created, 9), name=name, database_name=db, schema_name=sch, url=url,
                      has_credentials="N" if integ else "Y", has_encryption_key="Y" if enc else "N", owner=owner,
                      comment="", region=region, type="EXTERNAL", cloud=cloud, storage_integration=integ,
                      endpoint=endpoint, owner_role_type="ROLE", directory_enabled="Y" if directory else "N")
        # the integrations these stages use that the security area does not define
        for integ, role, age in (("AZURE_DEMO_INT", "PRODUCT_WRITE", 520), ("S3_DEMO_INT", "PLATFORM_WRITE", 560)):
            self.show("integrations", name=integ, type="EXTERNAL_STAGE", category="STORAGE", enabled="true",
                      comment="", created_on=b.ts(age, 11))
            self.w.grant("USAGE", "INTEGRATION", integ, role, days_back=self.rng.randint(30, age - 10))
        # the account's stage history and total carry these bytes too (landing grew; the rest is flat)
        total = sum(s[5] for s in st) * GB
        landing = 900 * GB
        hist = {r["usage_date"]: r for r in self.w.rows.get(("account_usage", "STAGE_STORAGE_USAGE_HISTORY"), [])}
        su = {r["usage_date"]: r for r in self.w.rows.get(("account_usage", "STORAGE_USAGE"), [])}
        for k in range(HISTORY_DAYS, 0, -1):
            d = b.back(k)
            extra_b = total - landing * min(0.8, 0.004 * k)
            if d in hist:
                hist[d]["average_stage_bytes"] += extra_b
            if d in su:
                su[d]["stage_bytes"] += extra_b

    # ---- replication: three secondaries held in this account ---------------------------------------------------
    def replication(self) -> None:
        b = self.b
        groups = [  # name, type, every hours, credits per refresh, failing from (days back), primary account
            ("RG_MKT_SECONDARY", "REPLICATION", 12, 0.15, None, "FAKE_EU"),
            ("RG_REFDATA_SECONDARY", "REPLICATION", 6, 0.9, None, "FAKE_EU"),
            ("RG_EU_FAILOVER", "FAILOVER", 4, 0.4, 2, "FAKE_DR"),
        ]
        for gi, (name, typ, every, credits, failing, prim) in enumerate(groups):
            gid = 7201 + gi
            objs = "DATABASES" if typ == "REPLICATION" else "DATABASES, ROLES, WAREHOUSES"
            sched = f"{every * 60} MINUTE"
            self.au("REPLICATION_GROUPS", created=b.ts(200, 9), name=name, type=typ, comment="", object_types=objs,
                    replication_schedule=sched, owner="ACCOUNTADMIN", is_listing_auto_fulfillment_group=False,
                    is_optimized_refresh_enabled=False)
            self.show("replication_groups", snowflake_region=REGION, created_on=b.ts(200, 9), account_name=ACCOUNT_NAME,
                      name=name, type=typ, comment="", is_primary="false", primary=f"{ORG_NAME}.{prim}.{name}",
                      object_types=objs, allowed_accounts=f"{ORG_NAME}.{prim},{ORG_NAME}.{ACCOUNT_NAME}",
                      organization_name=ORG_NAME, account_locator=ACCOUNT_LOCATOR, replication_schedule=sched,
                      secondary_state="STARTED", next_scheduled_refresh=b.ts(0, 23), owner="ACCOUNTADMIN")
            for k in range(185, 0, -1):
                for h in range(0, 24, every):
                    start = b.ts(k, h, 5)
                    fail = failing is not None and k <= failing
                    mins = self.rng.uniform(4, 25) * (3 if fail else 1)
                    self.au("REPLICATION_GROUP_REFRESH_HISTORY", replication_group_name=name, replication_group_id=gid,
                            phase_name="FAILED" if fail else "COMPLETED", start_time=start,
                            end_time=start + dt.timedelta(minutes=mins), job_uuid=f"rj-{gid}-{k}-{h}",
                            total_bytes={"totalBytesToReplicate": {"estimate": int(credits * 3e10)}},
                            object_count={"tableCount": 20 + gi * 15},
                            primary_snapshot_timestamp=start - dt.timedelta(minutes=2),
                            error={"message": "Replication refresh failed: network timeout"} if fail else None)
                    if fail:
                        continue
                    c = credits * self.rng.uniform(0.7, 1.3)
                    self.au("REPLICATION_GROUP_USAGE_HISTORY", start_time=b.ts(k, h),
                            end_time=b.ts(k, h) + dt.timedelta(hours=1), replication_group_name=name,
                            replication_group_id=str(gid), credits_used=c, bytes_transferred=int(c * 3e10))
                    self.meter("REPLICATION", b.ts(k, h), c, gid, name, "REPLICATION_GROUP")

    # ---- external, Iceberg and hybrid tables -------------------------------------------------------------------
    def object_types(self) -> None:
        b = self.b
        take, emit = self.extra_reads

        def table_row(tid, db, sch, name, typ, owner, created, gb, iceberg="NO", hybrid="NO", transient="NO",
                      retention=1, hour=9, deleted=None, altered=None):
            altered = b.ts(self.rng.randint(0, min(10, created)), 9) if altered is None else altered
            self.au("TABLES", table_id=tid, table_name=name, table_schema_id=self.w.schema_id[(db, sch)],
                    table_schema=sch, table_catalog_id=self.w.dbs[db], table_catalog=db, table_owner=owner,
                    table_type=typ, is_transient=transient, auto_clustering_on="NO", row_count=int(gb * 4e6),
                    bytes=int(gb * GB), retention_time=retention, created=b.ts(created, hour),
                    last_altered=altered, last_ddl=b.ts(created, hour), last_ddl_by=owner, deleted=deleted,
                    is_iceberg=iceberg, is_dynamic="NO", is_hybrid=hybrid)
            self.grant("OWNERSHIP", "TABLE", f"{db}.{sch}.{name}", owner, schema_=sch, catalog=db)

        def tsm(tid, db, sch, name, created, active, tt=0, fs=0):
            self.au("TABLE_STORAGE_METRICS", id=tid, table_name=name, table_schema_id=self.w.schema_id[(db, sch)],
                    table_schema=sch, table_catalog_id=self.w.dbs[db], table_catalog=db, clone_group_id=tid,
                    is_transient="NO", active_bytes=int(active), time_travel_bytes=int(tt), failsafe_bytes=int(fs),
                    retained_for_clone_bytes=0, deleted=False, table_created=b.ts(created, 9))

        ext = [  # id, db, schema, name, stage, auto refresh, invalid reason, reads, format type, named format
            (46201, "MARKETING_PROD_DB", "RAW", "EXT_AD_SPEND", "S3_AD_PARTNER", True, None, 30, "PARQUET",
             "MARKETING_PROD_DB.RAW.FF_PARQUET_PARTNER"),
            (46202, "RISK_PROD_DB", "RAW", "EXT_BUREAU_FEED", "S3_BUREAU_DROP", False,
             "Storage integration or stage credentials are no longer valid", 4, "ORC", "RISK_PROD_DB.RAW.FF_ORC_BUREAU"),
            (46203, "OPS_PROD_DB", "RAW", "EXT_LOG_ARCHIVE", "S3_EVENTS_EXPORT", False, None, 0, "PARQUET", None),
        ]
        for tid, db, sch, name, stage, auto, invalid, n, fmt, ff in ext:
            owner = f"{_team(db)}_WRITE"
            table_row(tid, db, sch, name, "EXTERNAL TABLE", owner, 200, 0)
            self.show("external_tables", created_on=b.ts(200, 9), name=name, database_name=db, schema_name=sch,
                      invalid="true" if invalid else "false", invalid_reason=invalid, owner=owner, stage=stage,
                      location=f"@{stage}/data/", file_format_name=ff, file_format_type=fmt, cloud="aws",
                      region="us-east-1",
                      notification_channel="arn:aws:sqs:us-east-1:000000000000:demo-auto-ingest" if auto else None,
                      last_refreshed_on=b.ts(0 if auto else 30, 6), table_format=None, owner_role_type="ROLE")
            fqn = f"{db}.{sch}.{name}"
            for q in take(n, lambda k, q, w, t=_team(db): k <= 30 and w["team"] == t):
                emit(q, fqn, tid)

        ice = [  # id, db, schema, name, catalog, external volume, refresh state, reads, compaction credits a day
            (46211, "DATA_SCIENCE_PROD_DB", "MARTS", "ICE_TRAINING_EVENTS", "SNOWFLAKE", "DEMO_EXT_VOL", None, 40, 0.15),
            (46212, "PLATFORM_PROD_DB", "RAW", "ICE_CDC_ORDERS", "GLUE_DEMO_INT", "DEMO_EXT_VOL", "RUNNING", 20, 0),
            (46213, "PLATFORM_PROD_DB", "RAW", "ICE_PARTNER_FEED", "POLARIS_DEMO_INT", "DEMO_EXT_VOL", "STALLED", 6, 0),
            (46214, "MARKETING_PROD_DB", "MARTS", "ICE_CLICK_ARCHIVE", "SNOWFLAKE", "SNOWFLAKE_MANAGED", None, 0, 1.2),
        ]
        for tid, db, sch, name, catalog, vol, state, n, comp in ice:
            owner = f"{_team(db)}_ADMIN"
            gb = 300 if comp else 120
            table_row(tid, db, sch, name, "BASE TABLE", owner, 180, gb, iceberg="YES")
            managed = catalog == "SNOWFLAKE"
            # Snowflake tracks the bytes of tables it writes; it bills them only on Snowflake storage
            tsm(tid, db, sch, name, 180, gb * GB if managed else 0, tt=gb * GB * 0.02 if managed else 0)
            if vol == "SNOWFLAKE_MANAGED":
                self.extend(db, 180, lambda k, g=gb: g * GB * (0.4 + 0.6 * (180 - k) / 180))
            self.show("iceberg_tables", created_on=b.ts(180, 9), name=name, database_name=db, schema_name=sch,
                      owner=owner, external_volume_name=vol, catalog_name=catalog,
                      iceberg_table_type="MANAGED" if managed else "UNMANAGED", catalog_table_name=name.lower(),
                      catalog_namespace=None if managed else "analytics", base_location=f"{name.lower()}/",
                      can_write_metadata="Y" if managed else "N", owner_role_type="ROLE",
                      auto_refresh_status=None if state is None else
                      '{"executionState":"%s","pendingSnapshotCount":%d}' % (state, 0 if state == "RUNNING" else 14))
            fqn = f"{db}.{sch}.{name}"
            for q in take(n, lambda k, q, w, t=_team(db): k <= 30 and w["team"] == t):
                emit(q, fqn, tid)
            for k in range(185, 0, -1):
                if comp:
                    c = comp * self.rng.uniform(0.6, 1.4)
                    self.au("ICEBERG_STORAGE_OPTIMIZATION_HISTORY", start_time=b.ts(k, 2), end_time=b.ts(k, 3),
                            credits_used=c, num_bytes_scanned=int(c * 40 * GB), num_rows_written=int(c * 2e7),
                            table_id=tid, table_name=name, iceberg_table_uuid=f"demo-uuid-{tid}",
                            schema_id=str(self.w.schema_id[(db, sch)]), schema_name=sch,
                            database_id=self.w.dbs[db], database_name=db, instance_id=1)

        # hybrid tables: one serving lookups every day, one nobody has touched since spring. Their bytes are in
        # the hybrid storage columns, not in TABLE_STORAGE_METRICS.
        table_row(46221, "PRODUCT_PROD_DB", "MARTS", "SESSION_CACHE_HT", "BASE TABLE", "PRODUCT_ADMIN", 160, 40,
                  hybrid="YES")
        table_row(46222, "SALES_PROD_DB", "MARTS", "QUOTE_LOOKUP_HT", "BASE TABLE", "SALES_ADMIN", 150, 12,
                  hybrid="YES")
        hyb = dict(db_col="average_hybrid_table_storage_bytes", su_col="hybrid_table_storage_bytes")
        self.extend("PRODUCT_PROD_DB", 160, lambda k: 40 * GB * (0.3 + 0.7 * (160 - k) / 160), **hyb)
        self.extend("SALES_PROD_DB", 150, lambda k: 12 * GB * min(1.0, (150 - k) / 10 + 0.1), **hyb)
        # the base account's 0.2 GB of hybrid storage belongs to ANALYTICS_DB (already in the account total)
        self.extend("ANALYTICS_DB", HISTORY_DAYS, 0.2 * GB, db_col="average_hybrid_table_storage_bytes", su_col=None)
        for k in range(185, 0, -1):
            c = 0.3 * self.rng.uniform(0.6, 1.4)
            self.au("HYBRID_TABLE_USAGE_HISTORY", object_type="TABLE", object_id=46221, object_name="SESSION_CACHE_HT",
                    start_time=b.ts(k, 12), end_time=b.ts(k, 13), credits_used=c)
            self.meter("HYBRID_TABLE_REQUESTS", b.ts(k, 12), c, 46221, "SESSION_CACHE_HT", "TABLE", "PRODUCT_PROD_DB",
                       "MARTS")
        for q in take(25, lambda k, q, w: k <= 30 and w["team"] == "PRODUCT"):
            emit(q, "PRODUCT_PROD_DB.MARTS.SESSION_CACHE_HT", 46221)

        # the event table that telemetry ingestion (EVENT_USAGE_HISTORY) writes to: its size is what was ingested
        daily: dict = {}
        for r in self.w.rows.get(("account_usage", "EVENT_USAGE_HISTORY"), []):
            day = r["start_time"].date()
            daily[day] = daily.get(day, 0) + (r["bytes_ingested"] or 0)
        first = (b.as_of - min(daily)).days if daily else 1

        def ingested(k):                                  # bytes ingested before the end of day k back
            return sum(v for d, v in daily.items() if d <= b.back(k))

        ev_bytes = ingested(1)
        table_row(46231, "PLATFORM_PROD_DB", "RAW", "APP_EVENTS", "EVENT TABLE", "PLATFORM_ADMIN", first + 30,
                  ev_bytes / GB, altered=b.ts(1, 1))
        tsm(46231, "PLATFORM_PROD_DB", "RAW", "APP_EVENTS", first + 30, ev_bytes, fs=ev_bytes * 0.05)
        self.extend("PLATFORM_PROD_DB", first, ingested)

        # temporary tables from ETL sessions and ad-hoc work: most go when the session ends, one is still open
        temps = [  # id, db, schema, name, owner, created days back, hour, lifetime hours (None = live), GB
            (46301, "PLATFORM_PROD_DB", "STAGING", "TMP_SESSIONS_DEDUP", "PLATFORM_WRITE", 1, 2, 1, 18.0),
            (46302, "PLATFORM_PROD_DB", "STAGING", "TMP_EVENTS_LATE", "PLATFORM_WRITE", 2, 2, 1, 6.5),
            (46303, "MARKETING_PROD_DB", "STAGING", "TMP_CAMPAIGN_MATCH", "MARKETING_WRITE", 3, 14, 5, 0.8),
            (46304, "FINANCE_PROD_DB", "STAGING", "TMP_CLOSE_RECON", "FINANCE_WRITE", 4, 18, 3, 0.3),
            (46305, "DATA_SCIENCE_DEV_DB", "SCRATCH", "TMP_FEATURE_SAMPLE", "DATA_SCIENCE_WRITE", 1, 16, None, 2.4),
            (46306, "RISK_PROD_DB", "STAGING", "TMP_SCORE_BATCH", "RISK_WRITE", 6, 3, 2, 1.1),
        ]
        for tid, db, sch, name, owner, k, h, life, gb in temps:
            gone = b.ts(k, h) + dt.timedelta(hours=life, minutes=self.rng.randint(0, 50)) if life else None
            table_row(tid, db, sch, name, "TEMPORARY TABLE", owner, k, gb, transient="YES", retention=0, hour=h,
                      deleted=gone, altered=b.ts(k, h, 20))

        # the catalog's materialized views store their results: no Time Travel or Fail-safe, bytes as in TABLES
        for t in self.cat["tables"]:
            if t["type"] != "MATERIALIZED VIEW":
                continue
            nbytes = int(t["gb"] * GB)
            self.au("TABLE_STORAGE_METRICS", id=t["id"], table_name=t["name"], table_schema_id=t["schema_id"],
                    table_schema=t["schema"], table_catalog_id=t["db_id"], table_catalog=t["db"],
                    clone_group_id=t["id"], is_transient="YES" if t["transient"] else "NO", active_bytes=nbytes,
                    time_travel_bytes=0, failsafe_bytes=0, retained_for_clone_bytes=0, deleted=False,
                    table_created=b.ts(t["created_days"], 9))
            self.extend(t["db"], t["created_days"], nbytes)

    # ---- UDFs, procedures, Streamlit apps and notebooks ---------------------------------------------------------
    def code_and_apps(self) -> None:
        b = self.b
        funcs = [  # id, db, schema, name, language, runtime, external access, other columns
            (48201, "FINANCE_PROD_DB", "MARTS", "F_FX_CONVERT", "SQL", None, None, {}),
            (48202, "MARKETING_PROD_DB", "MARTS", "F_UTM_PARSE", "SQL", None, None, {}),
            (48203, "DATA_SCIENCE_PROD_DB", "MARTS", "F_SCORE_CHURN", "PYTHON", "3.9", None,
             {"packages": "['scikit-learn','pandas']"}),
            (48204, "RISK_PROD_DB", "MARTS", "F_BUREAU_LOOKUP", "PYTHON", "3.11", "[BUREAU_API_INT]",
             {"packages": "['requests']"}),
            (48205, "PLATFORM_PROD_DB", "MARTS", "F_LEGACY_HASH", "PYTHON", "3.8", None, {}),
            (48206, "SALES_PROD_DB", "MARTS", "F_TERRITORY", "JAVASCRIPT", None, None, {}),
            (48207, "FINANCE_PROD_DB", "MARTS", "F_IBAN_VALIDATE", "JAVA", "11", None,
             {"packages": "['com.snowflake:snowpark:latest']"}),
            (48208, "PRODUCT_PROD_DB", "MARTS", "F_GEO_DISTANCE", "SCALA", "2.12", None,
             {"packages": "['com.snowflake:snowpark:latest']", "data_type": "FLOAT",
              "argument_signature": "(LAT1 FLOAT, LON1 FLOAT, LAT2 FLOAT, LON2 FLOAT)"}),
            (48209, "RISK_PROD_DB", "MARTS", "F_BUREAU_SCORE_EXT", "EXTERNAL", None, None,
             {"is_external": "YES", "api_integration": "API_INT_GATEWAY", "data_type": "VARIANT"}),
            (48210, "FINANCE_PROD_DB", "MARTS", "F_FX_RATE_TABLE", "SQL", None, None,
             {"is_memoizable": "YES", "data_type": "ARRAY", "argument_signature": "()"}),
            (48211, "DATA_SCIENCE_PROD_DB", "MARTS", "F_WEIGHTED_MEDIAN", "PYTHON", "3.11", None,
             {"is_aggregate": "YES", "data_type": "FLOAT", "argument_signature": "(V FLOAT, W FLOAT)",
              "packages": "['numpy']"}),
            # the data metric functions the tables billed for data quality monitoring run
            (48212, "FINANCE_PROD_DB", "MARTS", "DMF_LEDGER_UNBALANCED", "SQL", None, None,
             {"is_data_metric": "YES", "data_type": "NUMBER", "argument_signature": "(ARG_T TABLE(ARG_C1 NUMBER))"}),
            (48213, "RISK_PROD_DB", "MARTS", "DMF_CLAIMS_DUPLICATES", "SQL", None, None,
             {"is_data_metric": "YES", "data_type": "NUMBER", "argument_signature": "(ARG_T TABLE(ARG_C1 VARCHAR))"}),
            (48214, "SALES_PROD_DB", "MARTS", "DMF_CLICKS_FRESHNESS", "SQL", None, None,
             {"is_data_metric": "YES", "data_type": "NUMBER",
              "argument_signature": "(ARG_T TABLE(ARG_C1 TIMESTAMP_LTZ))"}),
        ]
        for fid, db, sch, name, lang, rt, eai, more in funcs:
            row = dict(argument_signature="(V VARCHAR)", data_type="VARCHAR", is_external="NO", is_memoizable="NO",
                       is_data_metric="NO", is_aggregate="NO", packages=None, api_integration=None)
            row.update(more)
            self.au("FUNCTIONS", function_id=fid, function_name=name, function_schema_id=self.w.schema_id[(db, sch)],
                    function_schema=sch, function_catalog_id=self.w.dbs[db], function_catalog=db,
                    function_owner=f"{_team(db)}_ADMIN", function_language=lang, runtime_version=rt,
                    external_access_integrations=eai, created=b.ts(self.rng.randint(60, 600), 9),
                    last_altered=b.ts(self.rng.randint(5, 60), 9), owner_role_type="ROLE", **row)
        procs = [  # db, schema, name, language, runtime, owner, other columns
            ("FINANCE_PROD_DB", "STAGING", "P_CLOSE_MONTH", "SQL", None, "FINANCE_ADMIN", {}),
            ("PLATFORM_PROD_DB", "STAGING", "P_PURGE_STAGES", "PYTHON", "3.11", "ACCOUNTADMIN",
             {"packages": "['snowflake-snowpark-python']"}),
            ("OPS_PROD_DB", "STAGING", "P_REBUILD_DW", "SQL", None, "OPS_ADMIN", {}),
            ("MARKETING_PROD_DB", "STAGING", "P_ROTATE_PARTITIONS", "JAVASCRIPT", None, "MARKETING_ADMIN", {}),
            ("FINANCE_PROD_DB", "STAGING", "P_IBAN_BATCH", "JAVA", "11", "FINANCE_ADMIN",
             {"packages": "['com.snowflake:snowpark:latest']"}),
            ("PRODUCT_PROD_DB", "STAGING", "P_GEO_ENRICH", "SCALA", "2.12", "PRODUCT_ADMIN",
             {"packages": "['com.snowflake:snowpark:latest']"}),
            # an admin-owned procedure that calls a payments API with a stored key
            ("FINANCE_PROD_DB", "STAGING", "P_SYNC_PAYMENT_STATUS", "PYTHON", "3.11", "SECURITYADMIN",
             {"packages": "['snowflake-snowpark-python','requests']", "external_access_integrations":
              "[EAI_PAYMENTS_API]", "secrets": '{"api_key":"FINANCE_PROD_DB.RAW.SEC_PAYMENTS_API_KEY"}'}),
        ]
        for db, sch, name, lang, rt, owner, more in procs:
            self.au("PROCEDURES", procedure_catalog_id=self.w.dbs[db], procedure_catalog=db,
                    procedure_schema_id=self.w.schema_id[(db, sch)], procedure_schema=sch, procedure_name=name,
                    procedure_owner=owner, argument_signature="()", procedure_language=lang, runtime_version=rt,
                    created=b.ts(self.rng.randint(90, 700), 9), last_altered=b.ts(self.rng.randint(10, 80), 9),
                    **more)
        seqs = [  # id, db, schema, name, data type, start, increment, ordered, next value, deleted days back
            (48501, "FINANCE_PROD_DB", "MARTS", "SEQ_INVOICE_NO", 1_000_000, 1, "YES", 4_812_337, None),
            (48502, "SALES_PROD_DB", "MARTS", "SEQ_QUOTE_ID", 1, 1, "NO", 920_441, None),
            (48503, "MARKETING_PROD_DB", "STAGING", "SEQ_CAMPAIGN_BATCH", 100, 10, "NO", 58_310, None),
            (48504, "PLATFORM_PROD_DB", "RAW", "SEQ_EVENT_LOAD_ID", 1, 1, "NO", 61_207_554_219, None),
            (48505, "OPS_PROD_DB", "MARTS", "SEQ_TICKET_NO", 50_000, 1, "YES", 187_022, None),
            (48506, "RISK_PROD_DB", "STAGING", "SEQ_SCORE_RUN", 1, 100, "NO", 1_440_101, None),
            (48507, "PRODUCT_PROD_DB", "MARTS", "SEQ_RELEASE", 1000, -1, "YES", 742, None),
            (48508, "OPS_PROD_DB", "STAGING", "SEQ_LEGACY_LOAD", 1, 1, "NO", 33_904, 45),
        ]
        for sid, db, sch, name, start, inc, ordered, nxt, gone in seqs:
            created = self.rng.randint(120, 900)
            self.au("SEQUENCES", sequence_id=sid, sequence_name=name, sequence_schema_id=self.w.schema_id[(db, sch)],
                    sequence_schema=sch, sequence_catalog_id=self.w.dbs[db], sequence_catalog=db,
                    sequence_owner=f"{_team(db)}_ADMIN", data_type="NUMBER", start_value=start, next_value=nxt,
                    increment=str(inc), ordered=ordered, created=b.ts(created, 9),
                    last_altered=b.ts(gone or self.rng.randint(1, 60), 9), deleted=b.ts(gone, 11) if gone else None)
        ffs = [  # id, db, schema, name, type, trim space, deleted days back
            (48601, "MARKETING_PROD_DB", "RAW", "FF_PARQUET_PARTNER", "PARQUET", None, None),
            (48602, "PLATFORM_PROD_DB", "RAW", "FF_PARQUET_EVENTS", "PARQUET", None, None),
            (48603, "PLATFORM_PROD_DB", "RAW", "FF_AVRO_CDC", "AVRO", None, None),
            (48604, "RISK_PROD_DB", "RAW", "FF_ORC_BUREAU", "ORC", None, None),
            (48605, "FINANCE_PROD_DB", "RAW", "FF_XML_EINVOICE", "XML", None, None),
            (48606, "FINANCE_PROD_DB", "RAW", "FF_CSV_ERP", "CSV", "true", None),
            (48607, "SALES_PROD_DB", "RAW", "FF_JSON_CRM", "JSON", None, None),
            (48608, "OPS_PROD_DB", "RAW", "FF_CSV_PIPE_OLD", "CSV", "false", 70),
        ]
        for fid, db, sch, name, typ, trim, gone in ffs:
            created = self.rng.randint(150, 800)
            self.au("FILE_FORMATS", file_format_id=fid, file_format_name=name,
                    file_format_schema_id=self.w.schema_id[(db, sch)], file_format_schema=sch,
                    file_format_catalog_id=self.w.dbs[db], file_format_catalog=db, file_format_type=typ,
                    file_format_owner=f"{_team(db)}_WRITE", created=b.ts(created, 9),
                    last_altered=b.ts(gone or self.rng.randint(5, 120), 9), deleted=b.ts(gone, 10) if gone else None,
                    trim_space=trim)
        apps = [  # kind, db, schema, name, owner, warehouse, public
            ("streamlits", "PRODUCT_PROD_DB", "MARTS", "APP_FUNNEL", "PRODUCT_ADMIN", "WH_STREAMLIT_APPS", True),
            ("streamlits", "SALES_PROD_DB", "MARTS", "APP_PIPELINE", "SYSADMIN", "WH_STREAMLIT_APPS", False),
            ("streamlits", "FINANCE_PROD_DB", "MARTS", "APP_CLOSE_TRACKER", "FINANCE_ADMIN", "WH_STREAMLIT_APPS", False),
            ("notebooks", "DATA_SCIENCE_PROD_DB", "MARTS", "NB_FEATURE_DRIFT", "DATA_SCIENCE_ADMIN", "WH_DS_FEATURES",
             False),
        ]
        for kind, db, sch, name, owner, whn, public in apps:
            row = dict(created_on=b.ts(self.rng.randint(30, 200), 9), name=name, database_name=db, schema_name=sch,
                       owner=owner, comment="", query_warehouse=whn)
            if kind == "streamlits":
                row.update(title=name.replace("APP_", "").replace("_", " ").title(), owner_role_type="ROLE")
            else:
                row.update(code_warehouse=whn)
            self.show(kind, **row)
            on = "STREAMLIT" if kind == "streamlits" else "NOTEBOOK"
            team = _team(db)
            self.grant("USAGE", on, name, f"{team}_READ", schema_=sch, catalog=db)
            if public:
                self.grant("USAGE", on, name, "PUBLIC", schema_=sch, catalog=db)

    # ---- views that point at dropped objects --------------------------------------------------------------------
    def broken_views(self) -> None:
        edges = [  # referencing (db, schema, name, id, domain) -> referenced (db, schema, name, id, domain)
            (("OPS_PROD_DB", "MARTS", "ORDERS_148", 40148, "VIEW"), ("LEGACY_DW_DB", "MARTS", "FACT_SALES", 46091, "TABLE")),
            (("OPS_PROD_DB", "MARTS", "ORDERS_150", 40150, "VIEW"), ("OPS_PROD_DB", "MARTS", "ORDERS_148", 40148, "VIEW")),
            (("RISK_PROD_DB", "STAGING", "ORDERS_122", 40122, "VIEW"), ("RISK_PROD_DB", "STAGING", "CUSTOMERS_OLD", 46098, "TABLE")),
            (("RISK_PROD_DB", "STAGING", "ORDERS_123", 40123, "VIEW"), ("RISK_PROD_DB", "STAGING", "CLAIMS_116", 40116, "TABLE")),
            (("OPS_PROD_DB", "MARTS", "ACCOUNTS_143", 40143, "VIEW"), ("OPS_PROD_DB", "RAW", "SESSIONS_136", 40136, "TABLE")),
        ]
        for (rdb, rsch, rname, rid, rdom), (tdb, tsch, tname, tid, tdom) in edges:
            self.au("OBJECT_DEPENDENCIES", referenced_database=tdb, referenced_schema=tsch,
                    referenced_object_name=tname, referenced_object_id=tid, referenced_object_domain=tdom,
                    referencing_database=rdb, referencing_schema=rsch, referencing_object_name=rname,
                    referencing_object_id=rid, referencing_object_domain=rdom, dependency_type="BY_NAME")


def _arch_ramp(k: int) -> float:
    """Share of the archived bytes already moved, k days back."""
    return max(0.0, min(1.0, (ARCH_START - k) / ARCH_RAMP))


def _team(db: str) -> str:
    owner = {d[1]: d[2] for d in DBS}
    return owner.get(db) or db.replace("_PROD_DB", "").replace("_DEV_DB", "")


_COLS: dict = {}


def _check(schema_name: str, view: str, row: dict) -> None:
    """Rows must use the fake schema's columns; the loader only checks the first rows of a view."""
    key = (schema_name, view)
    if key not in _COLS:
        cols = schema.VIEWS[schema_name][view] if schema_name in schema.VIEWS else schema.SHOW_TABLES[view]
        _COLS[key] = {c.lower() for c, _ in cols}
    bad = set(row) - _COLS[key]
    if bad:
        raise KeyError(f"{schema_name}.{view}: unknown column(s) {sorted(bad)}")
