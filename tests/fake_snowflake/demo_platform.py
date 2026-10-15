"""Demo platform area: AI, serverless features, containers, data transfer, cloud services, org billing and sharing.

Every credit added here goes into METERING_HISTORY; demo_billing rolls it into METERING_DAILY_HISTORY and this
account's ORGANIZATION_USAGE rows, so the org pages agree with the account.
Other accounts in the org are made up here, each with its own story (dormant, new, cross-cloud, DR, VPS, dropped).
Usage by a person only falls on days the person was signed in to the account (catalog last_login_days).
"""
from __future__ import annotations

import collections
import datetime as dt

from tests.fake_snowflake import data, demo_ai_perf, demo_billing, demo_storage, schema
from tests.fake_snowflake import demo_gov_fit, demo_review_fit

ORG, LOC, ACCT, REGION = data.ORG_NAME, data.ACCOUNT_LOCATOR, data.ACCOUNT_NAME, data.REGION
PRICE = data.CREDIT_PRICE
TB = 1024 ** 4
GB = 1024 ** 3
DAYS = 185                     # history the demo serverless and AI rows cover: 90 days and the 90 before

# cloud services share of a serverless feature's compute (metadata work around the feature)
CS_SHARE = {"SERVERLESS_TASK": 0.02, "PIPE": 0.03, "AUTO_CLUSTERING": 0.02, "MATERIALIZED_VIEW": 0.02,
            "REPLICATION": 0.015, "SEARCH_OPTIMIZATION": 0.02, "DATA_QUALITY_MONITORING": 0.02,
            "WAREHOUSE_METERING_READER": 0.05, "BACKUP": 0.01}
INTERFACES = ["agent_admin_ui", "sql_function", "microsoft_teams", "external"]
VPS_FEE = 4_800.0              # USD a month for the Virtual Private Snowflake deployment


def add(b) -> None:
    p = _P(b)
    p.ai()
    p.ai_reserved()
    p.cortex_code()
    p.serverless()
    p.replication()
    p.observability()
    p.other_services()
    p.containers()
    p.cloud_services_storm()
    p.transfer()
    p.backfill_short_views()
    p.sharing()
    p.databases()
    p.org_own_account()
    p.org_other_accounts()
    p.org_stub_accounts()
    demo_ai_perf.add_platform(p)                   # own random streams: Cortex access, failed AI, endpoints, lifecycle
    demo_storage._Store(b).reconcile_levels()      # again, now that the pipelines added their tables
    # its own random stream: DQ expectations, AI agents' reads, policy owners, table grants
    demo_gov_fit.add(b)
    # its own random stream: the edge cases a real account has (compute and storage)
    demo_review_fit.add(b)


def _day(v) -> dt.date:
    return v.date() if isinstance(v, dt.datetime) else v


class _P:
    def __init__(self, b):
        self.b, self.rng, self.cat = b, b.rng, b.cat
        self.users = collections.defaultdict(list)
        fallback = collections.defaultdict(list)
        for u in self.cat["users"]:
            if u["disabled"]:
                continue
            key = (u["team"], u["type"] == "PERSON")
            fallback[key].append(u)
            if u["last_login_days"] is not None and u["last_login_days"] <= 7:
                self.users[key].append(u)          # people who still sign in run the AI and sharing usage
        for key, us in fallback.items():
            if not self.users[key]:
                self.users[key] = sorted(us, key=lambda u: (u["last_login_days"] is None, u["last_login_days"] or 0))[:1]
        self.user_by_name = {u["name"]: u for u in self.cat["users"]}
        self.wh = {w["name"]: w for w in self.cat["warehouses"]}
        self.tbl = {(t["db"], t["name"]): t for t in self.cat["tables"]}
        self.db_id = {d["name"]: d["id"] for d in self.cat["databases"]}
        self.schema_id = {(s["db"], s["name"]): s["id"] for s in self.cat["schemas"]}
        self.qn = 0

    # ---- helpers ----------------------------------------------------------------------------------------
    def person(self, team, i=0):
        return self.users[(team, True)][i % len(self.users[(team, True)])]

    def svc(self, name):
        return self.user_by_name[name]

    @staticmethod
    def on(user, k) -> bool:
        """The user existed and had signed in by day k back (no usage after the last sign-in day)."""
        last = user.get("last_login_days")
        return last is not None and last <= k < user.get("created_days", 10 ** 6)

    def jitter(self, lo=0.75, hi=1.25):
        return self.rng.uniform(lo, hi)

    def level(self, k, base, mult=1.0, start=DAYS, weekdays=False, end=0):
        """Daily amount on day k back: `base` before the 30-day window, `base * mult` inside it, 0 outside [end, start)."""
        if k >= start or k < end:
            return 0.0
        if weekdays and self.b.back(k).weekday() >= 5:
            return base * 0.1
        return base * (mult if k <= 30 else 1.0) * self.jitter()

    def meter(self, k, hour, service, credits, entity_id=None, name=None, entity_type=None, db=None, schema_=None,
              cs=None):
        start = self.b.ts(k, hour)
        if cs is None:
            cs = credits * CS_SHARE.get(service, 0.0) * self.jitter(0.6, 1.4)
        self.b.au("METERING_HISTORY", service_type=service, start_time=start, end_time=start + dt.timedelta(hours=1),
                  entity_id=entity_id, entity_type=entity_type, name=name,
                  database_id=self.db_id.get(db) if db else None, database_name=db, schema_name=schema_,
                  schema_id=self.schema_id.get((db, schema_)) if db else None, credits_used_compute=credits,
                  credits_used_cloud_services=cs, credits_used=credits + cs)

    def org_common(self):
        return dict(organization_name=ORG, account_name=ACCT, account_locator=LOC, region=REGION)

    # ---- AI ---------------------------------------------------------------------------------------------
    def ai(self) -> None:
        b, ai_day = self.b, collections.defaultdict(float)

        def metrics(credits, fn):
            if fn == "AI_PARSE_DOCUMENT":
                return [{"key": {"metric": "pages", "unit": "pages"}, "value": int(credits * 300)}]
            tokens = int(credits * 1.2e6)
            return [{"key": {"metric": "input", "unit": "tokens"}, "value": int(tokens * 0.8)},
                    {"key": {"metric": "output", "unit": "tokens"}, "value": tokens - int(tokens * 0.8)}]

        # AI functions: (user, role, function, model, warehouse, base credits/day, window multiplier, start, tag)
        ds_label = self.person("DATA_SCIENCE", 0)
        fns = [
            (self.person("MARKETING", 0), "AI_SENTIMENT", None, "WH_MARKETING_ETL", 0.6, 1.0, DAYS, "job=review_sentiment"),
            (self.person("MARKETING", 1), "AI_CLASSIFY", None, "WH_MARKETING_ADHOC", 0.8, 1.0, 20, "job=lead_triage"),
            (self.svc("SVC_SALES_INGEST"), "AI_EXTRACT", "arctic-extract", "WH_SALES_ETL", 1.2, 1.7, DAYS, "job=contract_fields"),
            (ds_label, "AI_COMPLETE", "claude-4-sonnet", "WH_DS_TRAIN", 1.5, 1.0, DAYS, "job=label_gen"),
            (self.person("DATA_SCIENCE", 1), "AI_EMBED", "snowflake-arctic-embed-l-v2.0", "WH_DATA_SCIENCE_ETL", 0.9, 3.0, DAYS, "job=embed_docs"),
            (self.person("PRODUCT", 0), "AI_SUMMARIZE_AGG", None, "WH_PRODUCT_BI", 0.3, 1.1, DAYS, "app=feedback_digest"),
            (self.person("FINANCE", 0), "AI_COMPLETE", "llama3.3-70b", "WH_FINANCE_ADHOC", 0.5, 0.6, DAYS, None),
            (self.person("RISK", 0), "AI_COMPLETE", "deepseek-r1", "WH_RISK_MODELS", 0.7, 1.3, DAYS, "job=claim_notes"),
            (self.person("PLATFORM", 0), "AI_TRANSLATE", None, "WH_PLATFORM_ADHOC", 0.05, 1.0, DAYS, None),
            (self.person("OPS", 0), "AI_COMPLETE", "snowflake-arctic", "WH_OPS_ETL", 0.2, 1.0, DAYS, None),
            (self.person("SALES", 0), "AI_COMPLETE", "claude-4-sonnet", "WH_SALES_BI", 0.8, 2.0, DAYS, "app=deal_notes"),
            (self.svc("SVC_MARKETING_INGEST"), "AI_COMPLETE", "llama3.1-8b", "WH_REVERSE_ETL", 0.4, 1.0, 60, "job=copy_variants"),
        ]
        for user, fn, model, wh, base, mult, start, tag in fns:
            w = self.wh[wh]
            for k in range(1, DAYS):
                credits = self.level(k, base, mult, start, weekdays=user["type"] == "PERSON")
                if credits <= 0 or not self.on(user, k):
                    continue
                n = self.rng.randint(1, 3)
                for i in range(n):
                    self.qn += 1
                    hour = self.rng.randint(8, 18)
                    c = credits / n
                    b.au("CORTEX_AI_FUNCTIONS_USAGE_HISTORY",
                         start_time=b.ts(k, hour), end_time=b.ts(k, hour + 1), function_name=fn, model_name=model,
                         query_id=f"01dai-{self.qn:07d}", warehouse_id=w["id"], role_names=[user["default_role"]],
                         query_tag=tag, user_id=str(user["id"]), metrics=metrics(c, fn), credits=c, is_completed=True)
                ai_day[k] += credits

        # Cortex Analyst: (user, requests/day, window multiplier, start); about 0.067 credits per request
        analyst = [(self.person("SALES", 1), 20, 1.0, DAYS), (self.person("FINANCE", 1), 10, 1.8, DAYS),
                   (self.svc("SVC_SALES_REPORTING"), 40, 3.0, DAYS), (self.person("PRODUCT", 1), 25, 1.0, 15),
                   (self.person("MARKETING", 2), 3, 1.0, DAYS)]
        for user, req, mult, start in analyst:
            for k in range(1, DAYS):
                n = int(self.level(k, req, mult, start, weekdays=True))
                if n <= 0 or not self.on(user, k):
                    continue
                for hour, share in ((10, 0.6), (15, 0.4)):
                    r = max(1, int(n * share))
                    b.au("CORTEX_ANALYST_USAGE_HISTORY", start_time=b.ts(k, hour), end_time=b.ts(k, hour + 1),
                         request_count=r, credits=r * 0.067, username=user["name"])
                    ai_day[k] += r * 0.067

        # Cortex Search: (db, service, id, serving/day, embed/day, window multiplier, start)
        search = [("PRODUCT_PROD_DB", "SUPPORT_TICKET_SEARCH", 99101, 0.8, 0.5, 1.0, DAYS),
                  ("RISK_PROD_DB", "POLICY_DOC_SEARCH", 99102, 1.5, 0.05, 1.0, DAYS),
                  ("FINANCE_PROD_DB", "CONTRACT_SEARCH", 99103, 0.6, 0.6, 1.0, 22),
                  ("DATA_SCIENCE_PROD_DB", "RESEARCH_NOTES_SEARCH", 99104, 0.3, 0.1, 3.5, DAYS),
                  ("OPS_PROD_DB", "RUNBOOK_SEARCH", 99105, 0.08, 0.02, 1.0, DAYS)]
        for db, svc, sid, serving, embed, mult, start in search:
            for k in range(1, DAYS):
                s, e = self.level(k, serving, mult, start), self.level(k, embed, mult, start, weekdays=True)
                if svc == demo_ai_perf.SEARCH_STALE[0] and k <= demo_ai_perf.SEARCH_STALE[1]:
                    e = 0.0                                  # its source moved: the index has taken no rows since
                if s > 0:
                    b.au("CORTEX_SEARCH_DAILY_USAGE_HISTORY", usage_date=b.ts(k), database_name=db, schema_name="MARTS",
                         service_name=svc, service_id=sid, consumption_type="SERVING", credits=s)
                if e > 0:
                    b.au("CORTEX_SEARCH_DAILY_USAGE_HISTORY", usage_date=b.ts(k), database_name=db, schema_name="MARTS",
                         service_name=svc, service_id=sid, consumption_type="EMBED_TEXT_TOKENS", credits=e,
                         model_name="snowflake-arctic-embed-m-v1.5", tokens=str(int(e * 2.5e7)))
                bt = 0.0
                if svc == "SUPPORT_TICKET_SEARCH" and b.back(k).weekday() == 6:
                    bt = 0.6 * self.jitter()                     # the weekly re-index of the ticket archive
                    b.au("CORTEX_SEARCH_DAILY_USAGE_HISTORY", usage_date=b.ts(k), database_name=db,
                         schema_name="MARTS", service_name=svc, service_id=sid, consumption_type="BATCH", credits=bt)
                ai_day[k] += s + e + bt

        # Cortex Agents: (db, agent, id, user, credits/day, window multiplier, start)
        agents = [("SALES_PROD_DB", "DEAL_DESK_AGENT", 99201, self.person("SALES", 0), 0.4, 1.0, DAYS),
                  ("SALES_PROD_DB", "DEAL_DESK_AGENT", 99201, self.person("SALES", 2), 0.3, 1.4, DAYS),
                  ("FINANCE_PROD_DB", "CLOSE_COPILOT", 99202, self.person("FINANCE", 0), 1.0, 1.0, 12),
                  ("OPS_PROD_DB", "RUNBOOK_AGENT", 99203, self.person("OPS", 1), 0.1, 1.0, DAYS)]
        for db, agent, aid, user, base, mult, start in agents:
            for k in range(1, DAYS):
                c = self.level(k, base, mult, start, weekdays=True)
                if c <= 0 or not self.on(user, k):
                    continue
                self.qn += 1
                tok = int(c * 100000)
                gran_t = [{"service_type": "cortex_agents", "model": "claude-4-sonnet", "input": int(tok * 0.55),
                           "cache_read_input": int(tok * 0.2), "cache_write_input": int(tok * 0.05),
                           "output": int(tok * 0.12)},
                          {"service_type": "cortex_analyst", "model": "claude-4-sonnet", "input": int(tok * 0.06),
                           "output": tok - int(tok * 0.98)}]
                gran_c = [{"service_type": "cortex_agents", "model": "claude-4-sonnet", "credits": round(c * 0.85, 6)},
                          {"service_type": "cortex_analyst", "model": "claude-4-sonnet", "credits": round(c * 0.15, 6)}]
                b.au("CORTEX_AGENT_USAGE_HISTORY", start_time=b.ts(k, 11), end_time=b.ts(k, 12), user_id=user["id"],
                     user_name=user["name"], request_id=f"dreq-{self.qn:07d}", agent_database_id=self.db_id[db],
                     agent_database_name=db, agent_schema_id=self.schema_id[(db, "MARTS")], agent_schema_name="MARTS",
                     agent_id=aid, agent_name=agent, token_credits=c, tokens=tok, tokens_granular=gran_t,
                     credits_granular=gran_c,
                     metadata={"role_name": user["default_role"], "interaction_interface": self.rng.choice(INTERFACES),
                               "ai_functions_credits": round(c * 0.1, 4), "sql_query_credits": round(c * 0.3, 4),
                               "sql_query_warehouses": [f"WH_{user['team']}_BI"],
                               "inference_region": self.rng.choice(["global", "regional", "regional"])})
                ai_day[k] += c

        # Document processing: invoices parsed every weekday, three times as many at month end
        for k in range(1, DAYS):
            d = b.back(k)
            if d.weekday() >= 5:
                continue
            peak = 3.0 if d.day >= 27 or d.day <= 2 else 1.0
            for fn, model, per_page in (("AI_PARSE_DOCUMENT", "document-ai", 0.0033), ("AI_EXTRACT", "arctic-extract", 0.005)):
                pages = int(self.rng.randint(80, 200) * peak)
                self.qn += 1
                b.au("CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY", query_id=f"01ddoc-{self.qn:07d}",
                     credits_used=pages * per_page, start_time=b.ts(k, 7), end_time=b.ts(k, 8), function_name=fn,
                     model_name=model, operation_name="inference", page_count=pages, document_count=max(1, pages // 4),
                     feature_count=1 if fn == "AI_PARSE_DOCUMENT" else 6)
                ai_day[k] += pages * per_page
        # a Document AI model build in each 30-day period: the invoice model retrained on new layouts
        for k, credits in ((150, 4.5), (110, 3.8), (72, 5.2), (41, 4.1), (13, 6.0)):
            self.qn += 1
            b.au("CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY", query_id=f"01ddoc-{self.qn:07d}", credits_used=credits,
                 start_time=b.ts(k, 20), end_time=b.ts(k, 22), function_name="DOCUMENT_AI", model_name="invoice_model",
                 operation_name="train", page_count=int(credits * 120), document_count=int(credits * 30),
                 feature_count=8)
            ai_day[k] += credits

        # Fine-tuning: two jobs
        for k, model, credits in ((45, "mistral-7b", 4.0), (15, "llama3.1-8b", 6.5)):
            b.au("CORTEX_FINE_TUNING_USAGE_HISTORY", start_time=b.ts(k, 20), end_time=b.ts(k, 23), model_name=model,
                 token_credits=credits, tokens=int(credits * 4e5))
            ai_day[k] += credits

        for k, credits in ai_day.items():
            self.meter(k, 14, "AI_SERVICES", credits, None, "CORTEX_DEMO", None)

        # the AI spike: a label backfill run over a whole table on the two days the account billed far more AI
        # credits than usual. Those credits are already metered, so the usage rows explain them and are not
        # metered again.
        base_daily = collections.defaultdict(float)
        for r in b.w.rows.get(("account_usage", "METERING_DAILY_HISTORY"), []):
            if r["service_type"] == "AI_SERVICES":
                base_daily[r["usage_date"]] += r["credits_used_compute"] or 0.0
        wh = self.wh["WH_DS_TRAIN"]
        for k in (8, 15):
            spike = max(0.0, base_daily.get(b.back(k), 0.0) - ai_day[k]) * 0.96
            if spike <= 0:
                continue
            self.qn += 1
            qid = f"01dai-{self.qn:07d}"
            for i, (hour, share) in enumerate(((1, 0.3), (2, 0.4), (3, 0.3))):
                c = spike * share
                b.au("CORTEX_AI_FUNCTIONS_USAGE_HISTORY", start_time=b.ts(k, hour), end_time=b.ts(k, hour + 1),
                     function_name="AI_COMPLETE", model_name="claude-4-sonnet", query_id=qid,
                     warehouse_id=wh["id"], role_names=[ds_label["default_role"]], query_tag="job=backfill_labels",
                     user_id=str(ds_label["id"]), metrics=metrics(c, "AI_COMPLETE"), credits=c,
                     is_completed=i == 2)                        # one long query: its hours close when it ends

    def ai_reserved(self) -> None:
        """Provisioned throughput reservations (metered as AI_SERVICES by demo_billing) and Cortex REST API calls."""
        b = self.b
        # (id, model, PTUs, term start days back, term end days back (negative: still running))
        reservations = [("PT-DEMO-SONNET", "claude-4-sonnet", 6, 120, -60),
                        ("PT-DEMO-LLAMA", "llama3.3-70b", 6, 200, 20),
                        ("PT-DEMO-NEW", "mistral-large2", 5, 12, -78)]
        for pid, model, ptu, start, end in reservations:
            for k in range(max(end, 0) + 1, min(start, DAYS)):
                b.au("CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY", provisioned_throughput_id=pid,
                     interval_start_time=b.ts(k, 0), interval_end_time=b.ts(k, 1), cloud_service_provider="AWS",
                     model_name=model, term_start_date=b.back(start), term_end_date=b.back(end), ptu_count=ptu,
                     ptu_credits=round(ptu * 0.16, 4))
        # REST API: a support bot and a sales tool call models directly
        callers = [(self.svc("SVC_PRODUCT_INGEST") if "SVC_PRODUCT_INGEST" in self.user_by_name else self.person("PRODUCT", 0),
                    "claude-4-sonnet", 60, DAYS, "us-east-1"),
                   (self.person("SALES", 1), "llama3.3-70b", 15, 70, "us-west-2"),
                   (self.person("DATA_SCIENCE", 2), "mistral-large2", 8, DAYS, "us-east-1")]
        for user, model, per_day, start, region in callers:
            for k in range(1, min(start, DAYS)):
                n = int(self.level(k, per_day, 1.6, start, weekdays=True))
                if n <= 0 or not self.on(user, k):
                    continue
                for h in (10, 15):
                    self.qn += 1
                    tok = int(n / 2 * self.rng.randint(1500, 4000))
                    b.au("CORTEX_REST_API_USAGE_HISTORY", start_time=b.ts(k, h), end_time=b.ts(k, h) + dt.timedelta(hours=1),
                         request_id=f"drest-{self.qn:07d}", model_name=model, tokens=tok,
                         tokens_granular={"input": int(tok * 0.75), "output": tok - int(tok * 0.75)},
                         user_id=str(user["id"]), inference_region=region)

    def cortex_code(self) -> None:
        b = self.b
        users = [(self.person("PLATFORM", 1), 0.8, 1.0, DAYS), (self.person("PLATFORM", 2), 3.0, 1.0, 8),
                 (self.person("DATA_SCIENCE", 2), 0.5, 2.5, 60)]
        for user, base, mult, start in users:
            for k in range(1, DAYS):
                c = self.level(k, base, mult, start, weekdays=True)
                if c <= 0 or not self.on(user, k):
                    continue
                b.au("CORTEX_CODE_CLI_USAGE_HISTORY", user_id=user["id"], user_name=user["name"],
                     request_id=f"dcode-{user['id']}-{k}", usage_time=b.ts(k, 16), token_credits=c,
                     tokens=int(c * 90000), metadata={"model_name": "claude-sonnet"})
                self.meter(k, 16, "CORTEX_CODE_CLI", c, None, user["name"], "USER")

    # ---- serverless features -------------------------------------------------------------------------------
    def serverless(self) -> None:
        b = self.b

        def tbl(db, name):
            t = self.tbl[(db, name)]
            return t, t["schema"], t["schema_id"], t["db_id"]

        # automatic clustering on the catalog's clustered tables: (db, table, credits/day, multiplier, start, Optima from)
        # CLAIMS_116 moved to Optima clustering 50 days ago and costs less per day since; SESSIONS_108 started on it
        for db, name, base, mult, start, optima in (("RISK_PROD_DB", "CLAIMS_116", 6.0, 3.2, DAYS, 50),
                                                    ("PRODUCT_PROD_DB", "SESSIONS_108", 2.0, 1.0, DAYS, DAYS),
                                                    ("OPS_PROD_DB", "SESSIONS_136", 1.5, 1.0, 18, 0)):
            t, sch, sid, dbid = tbl(db, name)
            for k in range(1, DAYS):
                c = self.level(k, base, mult, start)
                if c <= 0:
                    continue
                version = "OPTIMA" if k < optima else "CLASSIC"
                if version == "OPTIMA" and name == "CLAIMS_116":
                    c *= 0.6
                for hour in (2, 14):
                    start_t = b.ts(k, hour)
                    b.au("AUTOMATIC_CLUSTERING_HISTORY", start_time=start_t, end_time=start_t + dt.timedelta(hours=1),
                         credits_used=c / 2, num_bytes_reclustered=int(c / 2 * 2e10), num_rows_reclustered=int(c / 2 * 5e7),
                         table_id=t["id"], table_name=name, schema_id=sid, schema_name=sch, database_id=dbid,
                         database_name=db, version=version)
                    self.meter(k, hour, "AUTO_CLUSTERING", c / 2, t["id"], name, "TABLE", db, sch)

        # materialized view refreshes
        for db, name, base, mult in (("FINANCE_PROD_DB", "SESSIONS_014", 4.0, 1.8), ("MARKETING_PROD_DB", "LEADS_027", 0.6, 1.0),
                                     ("DATA_SCIENCE_PROD_DB", "CUSTOMERS_088", 0.8, 3.2), ("SALES_PROD_DB", "CLICKS_045", 0.3, 1.0),
                                     ("DATA_SCIENCE_PROD_DB", "RETURNS_087", 0.4, 0.8), ("PLATFORM_PROD_DB", "EVENTS_061", 0.2, 1.0),
                                     ("RISK_PROD_DB", "INVENTORY_113", 0.15, 1.0)):
            t, sch, sid, dbid = tbl(db, name)
            for k in range(1, DAYS):
                c = self.level(k, base, mult)
                start_t = b.ts(k, 16)                     # an afternoon refresh; the morning one is the storage area's
                b.au("MATERIALIZED_VIEW_REFRESH_HISTORY", start_time=start_t, end_time=start_t + dt.timedelta(hours=1),
                     credits_used=round(c, 6), table_id=t["id"], table_name=name, schema_id=sid, schema_name=sch,
                     database_id=dbid, database_name=db)
                self.meter(k, 16, "MATERIALIZED_VIEW", c, t["id"], name, "TABLE", db, sch)

        # search optimization
        for db, name, base, mult, start in (("RISK_PROD_DB", "ACCOUNTS_127", 1.2, 1.0, DAYS),
                                            ("PLATFORM_PROD_DB", "CUSTOMERS_062", 0.6, 1.0, 25),
                                            ("PRODUCT_PROD_DB", "LEADS_095", 0.3, 2.8, DAYS)):
            t, sch, sid, dbid = tbl(db, name)
            for k in range(1, DAYS):
                c = self.level(k, base, mult, start)
                if c <= 0:
                    continue
                start_t = b.ts(k, 5)
                b.au("SEARCH_OPTIMIZATION_HISTORY", start_time=start_t, end_time=start_t + dt.timedelta(hours=1),
                     credits_used=c, index_id=t["id"] * 10, index_name=f"SOS_{name}",
                     index_type="Search Optimization Index", base_table_id=t["id"], base_table_name=name,
                     schema_id=sid, schema_name=sch, database_id=dbid, database_name=db)
                self.meter(k, 5, "SEARCH_OPTIMIZATION", c, t["id"], name, "TABLE", db, sch)

    def replication(self) -> None:
        """This account holds secondaries refreshed daily from two other accounts in the org, so it pays. Each billed
        day has its refresh; RG_PARTNER_FEEDS fails twice and once lags a day behind its primary."""
        b = self.b
        for rg, rgid, db_name, db_id, base, start, src_cloud, src_region, tb, primary in (
                ("RG_EU_REFERENCE", 7204, "EU_REFERENCE_DB", 4881, 4.0, DAYS, "AZURE", "AZURE_WESTEUROPE", 0.05, "FAKE_EU"),
                ("RG_PARTNER_FEEDS", 7205, "PARTNER_FEEDS_DB", 4882, 7.0, 18, "GCP", "GCP_US_CENTRAL1", 0.12,
                 "FAKE_PARTNER_APPS")):
            created = min(start, 200)
            b.au("REPLICATION_GROUPS", created=b.ts(created, 9), name=rg, type="REPLICATION", comment="",
                 object_types="DATABASES", replication_schedule="1440 MINUTE", owner="ACCOUNTADMIN",
                 is_listing_auto_fulfillment_group=False, is_optimized_refresh_enabled=False)
            b.show("replication_groups", snowflake_region=REGION, created_on=b.ts(created, 9), account_name=ACCT,
                   name=rg, type="REPLICATION", comment="", is_primary="false", primary=f"{ORG}.{primary}.{rg}",
                   object_types="DATABASES", allowed_accounts=f"{ORG}.{primary},{ORG}.{ACCT}", organization_name=ORG,
                   account_locator=LOC, replication_schedule="1440 MINUTE", secondary_state="STARTED",
                   next_scheduled_refresh=b.ts(0, 6), owner="ACCOUNTADMIN")
            # the secondary database, as both database views list it
            b.au("DATABASES", database_id=db_id, database_name=db_name, database_owner="ACCOUNTADMIN", is_transient="NO",
                 type="STANDARD", retention_time=1, created=b.ts(created, 9), last_altered=b.ts(1, 6), deleted=None,
                 owner_role_type="ROLE", object_visibility=None)
            b.show("databases", created_on=b.ts(created, 9), name=db_name, is_default="N", is_current="N",
                   origin=f"{ORG}.{primary}.{db_name}", owner="ACCOUNTADMIN", comment="", options="",
                   retention_time="1", kind="STANDARD", owner_role_type="ROLE")
            for k in range(1, DAYS):
                c = self.level(k, base, 1.0, start)
                if c <= 0:
                    continue
                start_t = b.ts(k, 6)
                bytes_ = int(tb * TB * self.jitter())
                b.au("REPLICATION_GROUP_USAGE_HISTORY", start_time=start_t, end_time=start_t + dt.timedelta(hours=1),
                     replication_group_name=rg, replication_group_id=str(rgid), credits_used=c,
                     bytes_transferred=bytes_)
                self.meter(k, 6, "REPLICATION", c, rgid, rg, "REPLICATION_GROUP")
                b.au("DATA_TRANSFER_HISTORY", start_time=start_t, end_time=start_t + dt.timedelta(hours=1),
                     source_cloud=src_cloud, source_region=src_region, target_cloud="AWS", target_region=REGION,
                     bytes_transferred=bytes_, transfer_type="REPLICATION")
                b.ou("REPLICATION_USAGE_HISTORY", **self.org_common(), usage_date=b.back(k), database_id=db_id,
                     database_name=db_name, credits_used=c, bytes_transferred=int(bytes_))
                failed = rg == "RG_PARTNER_FEEDS" and k in (9, 4)
                late = rg == "RG_PARTNER_FEEDS" and k == 3                     # the primary's snapshot was a day old
                mins = self.rng.randint(18, 42)
                snap = start_t - dt.timedelta(hours=26 if late else 1)
                b.au("REPLICATION_GROUP_REFRESH_HISTORY", replication_group_name=rg, replication_group_id=rgid,
                     phase_name="FAILED" if failed else "COMPLETED", start_time=start_t,
                     end_time=start_t + dt.timedelta(minutes=mins), job_uuid=f"djob-{rgid}-{k}",
                     total_bytes={"totalBytesToReplicate": {"estimate": bytes_}},
                     object_count={"tableCount": 40 if rg == "RG_EU_REFERENCE" else 12},
                     primary_snapshot_timestamp=snap,
                     error={"message": "Secondary refresh failed: the primary is not reachable."} if failed else None)
        # a legacy database replicated on its own (not in a group), refreshed daily
        for k in range(1, DAYS):
            c = self.level(k, 0.6, 1.0)
            b.au("DATABASE_REPLICATION_USAGE_HISTORY", start_time=b.ts(k, 4), end_time=b.ts(k, 5), database_id=433,
                 database_name="ARCHIVE_DB", credits_used=c, bytes_transferred=int(c * 4e10))
            self.meter(k, 4, "REPLICATION", c, 433, "ARCHIVE_DB", "DATABASE")
            b.ou("REPLICATION_USAGE_HISTORY", **self.org_common(), usage_date=b.back(k), database_id=433,
                 database_name="ARCHIVE_DB", credits_used=c, bytes_transferred=int(c * 4e10))

    def observability(self) -> None:
        """Data metric functions on a few tables: steady, new and one whose schedule went to every 5 minutes."""
        b = self.b
        for db, name, base, mult, start in (("FINANCE_PROD_DB", "LEDGER_011", 0.4, 1.0, DAYS),
                                            ("RISK_PROD_DB", "CLAIMS_116", 1.0, 1.0, 20),
                                            ("SALES_PROD_DB", "CLICKS_045", 0.3, 10.0, DAYS)):
            t = self.tbl.get((db, name)) or next(x for x in self.cat["tables"] if x["db"] == db and x["type"] == "BASE TABLE")
            for k in range(1, DAYS):
                c = self.level(k, base, mult, start)
                if c <= 0:
                    continue
                start_t = b.ts(k, 7)
                b.au("DATA_QUALITY_MONITORING_USAGE_HISTORY", start_time=start_t, end_time=start_t + dt.timedelta(hours=1),
                     credits_used=c, table_id=t["id"], table_name=t["name"], schema_id=t["schema_id"],
                     schema_name=t["schema"], database_id=t["db_id"], database_name=t["db"])
                self.meter(k, 7, "DATA_QUALITY_MONITORING", c, t["id"], t["name"], "TABLE", t["db"], t["schema"])
        # where the metric functions sit: finance and risk cover most tables, sales and data science some
        metrics = [("NULL_COUNT", "(ARG_T TABLE(ARG_C1 VARCHAR))"), ("DUPLICATE_COUNT", "(ARG_T TABLE(ARG_C1 NUMBER))"),
                   ("FRESHNESS", "(ARG_T TABLE(ARG_C1 TIMESTAMP_LTZ))"), ("ROW_COUNT", "(ARG_T TABLE())")]
        billed = {"LEDGER_011", "CLAIMS_116", "CLICKS_045"}
        for db, share in (("FINANCE_PROD_DB", 0.8), ("RISK_PROD_DB", 0.7), ("SALES_PROD_DB", 0.45),
                          ("DATA_SCIENCE_PROD_DB", 0.3)):
            tbls = sorted((t for t in self.cat["tables"] if t["db"] == db and t["type"] == "BASE TABLE"),
                          key=lambda t: (t["name"] not in billed, t["id"]))
            for i, t in enumerate(tbls[:round(len(tbls) * share)]):
                status = "SUSPENDED_TABLE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED" if i == 5 else "STARTED"
                sched = "5 MINUTE" if t["name"] == "CLICKS_045" else self.rng.choice(
                    ["60 MINUTE", "TRIGGER_ON_CHANGES", "USING CRON 0 6 * * * UTC"])
                for name, sig in self.rng.sample(metrics, self.rng.randint(1, 3)):
                    b.au("DATA_METRIC_FUNCTION_REFERENCES", metric_database_name="SNOWFLAKE", metric_schema_name="CORE",
                         metric_name=name, argument_signature=sig, data_type="NUMBER", ref_database_name=db,
                         ref_schema_name=t["schema"], ref_entity_name=t["name"], ref_entity_domain="TABLE",
                         ref_id=f"{t['id']}-{name}", schedule=sched, schedule_status=status, level="TABLE")

    def other_services(self) -> None:
        """The smaller billed services: backups, Trust Center scans, sensitive data classification, file copies,
        one Fail-safe recovery and a short Postgres trial."""
        b, w = self.b, self.b.w
        for k in range(1, DAYS):
            # backups of CLICKSTREAM_DB: a nightly backup set
            self.meter(k, 1, "BACKUP", 0.35 * self.jitter(0.8, 1.3), 431, "CLICKSTREAM_DB", "DATABASE")
            if b.back(k).weekday() == 0:
                self.meter(k, 3, "TRUST_CENTER", 0.8 * self.jitter(), None, "TRUST_CENTER_SCANNERS", None)
        # classification runs: credits on the days the latest results were produced
        runs = collections.Counter((b.as_of - _day(r["last_classification_attempt"])).days
                                   for r in w.rows.get(("account_usage", "DATA_CLASSIFICATION_LATEST"), [])
                                   if r.get("last_classification_attempt") is not None)
        for k, n in runs.items():
            if 1 <= k < DAYS:
                self.meter(k, 3, "SENSITIVE_DATA_CLASSIFICATION", 0.06 * n * self.jitter(), None, "AUTO_CLASSIFICATION",
                           None)
        for k in (95, 67, 39, 11):
            self.meter(k, 20, "COPY_FILES", 1.5 * self.jitter(), None, "COPY_FILES", None)
        self.meter(52, 15, "FAILSAFE_RECOVERY", 4.2, 434, "LEGACY_DW_DB", "DATABASE")
        for k in range(50, 71):                      # a three-week Postgres trial, primary and its standby
            self.meter(k, 12, "POSTGRES_COMPUTE", 1.8 * self.jitter(), None, "PG_TRIAL", "POSTGRES_INSTANCE")
            self.meter(k, 12, "POSTGRES_COMPUTE_HA", 1.8 * self.jitter(0.95, 1.05), None, "PG_TRIAL",
                       "POSTGRES_INSTANCE")

    # ---- containers ---------------------------------------------------------------------------------------------
    POOLS = [
        # id, name, team, family, min, max, hours (weekday), credits/node-hour, nodes, start, end, suspended, app
        (9811, "POOL_DS_TRAIN", "DATA_SCIENCE", "GPU_NV_M", 1, 4, (1, 2, 3), 2.7, 2, DAYS, 0, False, None),
        (9812, "POOL_PRODUCT_SERVING", "PRODUCT", "CPU_X64_M", 1, 3, tuple(range(24)), 0.22, 1, DAYS, 0, False, None),
        (9813, "POOL_PLATFORM_TOOLS", "PLATFORM", "CPU_X64_XS", 1, 1, tuple(range(8, 18)), 0.06, 1, DAYS, 25, True, None),
        (9814, "POOL_MKT_EXPERIMENTS", "MARKETING", "HIGHMEM_X64_S", 1, 2, tuple(range(9, 15)), 0.28, 1, 20, 0, False, None),
        (9815, "POOL_APP_SEARCH", "PRODUCT", "CPU_X64_S", 1, 1, tuple(range(24)), 0.11, 1, 150, 0, False,
         ("DATA_APP_A", 8801)),
        (9816, "SYSTEM_COMPUTE_POOL_GPU", "DATA_SCIENCE", "GPU_NV_S", 1, 2, (), 0.57, 1, DAYS, 0, False, None),
    ]
    NOTEBOOKS = [
        # id, name, team, pool, pool id, hours, credits/hour, nightly (no user), start, mult in the window
        (7811, "NB_CHURN_EXPLORE", "DATA_SCIENCE", "SYSTEM_COMPUTE_POOL_CPU", 9002, (10, 11, 14, 15), 0.11, False, DAYS, 1.0),
        (7812, "NB_WEEKLY_KPI", "FINANCE", "SYSTEM_COMPUTE_POOL_CPU", 9002, (6,), 0.11, True, DAYS, 1.0),
        (7813, "NB_FEATURE_DRIFT", "DATA_SCIENCE", "SYSTEM_COMPUTE_POOL_GPU", 9816, (2, 3), 0.57, True, 160, 2.2),
        (7814, "NB_ATTRIBUTION_MODEL", "MARKETING", "SYSTEM_COMPUTE_POOL_CPU", 9002, (13, 14), 0.11, False, 45, 1.0),
    ]

    def containers(self) -> None:
        """Compute pools per team (training, serving, a suspended tools pool, a new one, an app's own pool),
        their services, notebooks on the system pools and a model served from the serving pool."""
        b, w = self.b, self.b.w
        for pid, name, team, fam, mn, mx, hours, rate, nodes, start, end, susp, app in self.POOLS:
            created = min(start, DAYS) + 5
            b.au("COMPUTE_POOLS", name=name, id=pid, is_suspended=susp, min_nodes=mn, max_nodes=mx,
                 instance_family=fam, auto_suspend_secs=0 if name == "POOL_PRODUCT_SERVING" else 3600,
                 auto_resume=True, created=b.ts(created, 9), last_resumed=b.ts(max(end, 1), 8),
                 last_altered=b.ts(min(created, 30), 9), deleted=None,
                 owner="ACCOUNTADMIN" if name.startswith("SYSTEM") else f"{team}_ADMIN", owner_role_type="ROLE",
                 is_exclusive=app is not None, application_name=app[0] if app else None,
                 application_id=app[1] if app else None, comment=None)
            for k in range(max(end, 1), min(start, DAYS)):
                weekday = b.back(k).weekday() < 5
                if name in ("POOL_DS_TRAIN", "POOL_PLATFORM_TOOLS", "POOL_MKT_EXPERIMENTS") and not weekday:
                    continue
                n_nodes = nodes + (1 if name == "POOL_DS_TRAIN" and k <= 30 else 0)    # training grew a node
                for h in hours:
                    c = rate * n_nodes * self.jitter(0.9, 1.1)
                    b.au("SNOWPARK_CONTAINER_SERVICES_HISTORY", start_time=b.ts(k, h), end_time=b.ts(k, h) + dt.timedelta(hours=1),
                         compute_pool_name=name, compute_pool_id=pid, is_exclusive=app is not None,
                         application_name=app[0] if app else None, application_id=app[1] if app else None,
                         credits_used=c)
                    self.meter(k, h, "SNOWPARK_CONTAINER_SERVICES", c, pid, name, "COMPUTE_POOL")
        services = [  # id, name, pool, pool id, team, job, min instances, auto suspend
            (9831, "FEATURE_TRAIN_JOB", "POOL_DS_TRAIN", 9811, "DATA_SCIENCE", True, 1, 0),
            (9832, "RECO_API", "POOL_PRODUCT_SERVING", 9812, "PRODUCT", False, 2, 0),
            (9833, "DBT_DOCS_SITE", "POOL_PLATFORM_TOOLS", 9813, "PLATFORM", False, 1, 1800),
            (9834, "UPLIFT_EXPERIMENT", "POOL_MKT_EXPERIMENTS", 9814, "MARKETING", False, 1, 3600),
            (9835, "SEARCH_BACKEND", "POOL_APP_SEARCH", 9815, "PRODUCT", False, 1, 0),
        ]
        for sid, name, pool, pid, team, job, mn, susp in services:
            db = f"{team}_PROD_DB"
            b.au("SERVICES", service_id=sid, service_name=name, service_catalog_id=self.db_id.get(db), service_catalog=db,
                 service_schema_id=self.schema_id.get((db, "MARTS")), service_schema="MARTS",
                 service_owner=f"{team}_ADMIN", service_owner_role_type="ROLE", compute_pool_id=pid,
                 compute_pool_name=pool, dns_name=f"{name.lower().replace('_', '-')}.svc.spcs.internal",
                 min_ready_instances=mn, min_instances=mn, max_instances=mn + 1, auto_resume=True,
                 query_warehouse=f"WH_{team}_ADHOC", created=b.ts(140, 9), last_altered=b.ts(12, 9),
                 last_resumed=b.ts(1, 8), last_suspended=b.ts(25, 18) if pool == "POOL_PLATFORM_TOOLS" else None,
                 auto_suspend_secs=susp, deleted=None, comment=None, is_job=job, is_async_job=job)
            status = "SUSPENDED" if pool == "POOL_PLATFORM_TOOLS" else ("DONE" if job else "RUNNING")
            b.show("services", name=name, status=status, database_name=db, schema_name="MARTS", owner=f"{team}_ADMIN",
                   compute_pool=pool, current_instances=0 if status != "RUNNING" else mn, target_instances=mn,
                   min_instances=mn, max_instances=mn + 1, auto_resume="true", created_on=b.ts(140, 9),
                   is_job="true" if job else "false", is_async_job="true" if job else "false", owner_role_type="ROLE")
        # notebooks: the SHOW rows and their runtime, on the system pools
        listed = {r["name"] for r in w.rows.get(("show", "notebooks"), [])}
        for nid, name, team, pool, pid, hours, rate, nightly, start, mult in self.NOTEBOOKS:
            user = self.person(team, 1)
            if name not in listed:
                b.show("notebooks", created_on=b.ts(min(start, DAYS) + 2, 9), name=name, database_name=f"{team}_PROD_DB",
                       schema_name="MARTS", owner=f"{team}_ADMIN", comment="", query_warehouse=f"WH_{team}_ADHOC",
                       code_warehouse=f"WH_{team}_ADHOC")
            for k in range(1, min(start, DAYS)):
                if not nightly and (b.back(k).weekday() >= 5 or not self.on(user, k)):
                    continue
                for h in hours:
                    c = rate * (mult if k <= 30 else 1.0) * self.jitter(0.8, 1.2)
                    b.au("NOTEBOOKS_CONTAINER_RUNTIME_HISTORY", start_time=b.ts(k, h), end_time=b.ts(k, h) + dt.timedelta(hours=1),
                         notebook_name=name, notebook_id=nid, user_name=None if nightly else user["name"],
                         user_id=None if nightly else user["id"], compute_pool_name=pool, compute_pool_id=pid,
                         service_name=f"NB_SVC_{nid}", service_id=nid + 1000,
                         notebook_execution_time_secs=int(3000 * self.jitter(0.6, 1.1)), credits=c)
                    b.au("SNOWPARK_CONTAINER_SERVICES_HISTORY", start_time=b.ts(k, h), end_time=b.ts(k, h) + dt.timedelta(hours=1),
                         compute_pool_name=pool, compute_pool_id=pid, is_exclusive=False, application_name=None,
                         application_id=None, credits_used=c)
                    self.meter(k, h, "SNOWPARK_CONTAINER_SERVICES", c, pid, pool, "COMPUTE_POOL")
        # the base fixture's notebooks have runtime but no SHOW row: list them, so the two views name the same ones
        listed = {r["name"] for r in w.rows.get(("show", "notebooks"), [])}
        for name in sorted({r["notebook_name"] for r in w.rows.get(("account_usage", "NOTEBOOKS_CONTAINER_RUNTIME_HISTORY"), [])}
                           - listed):
            b.show("notebooks", created_on=b.ts(DAYS + 5, 9), name=name, database_name="ANALYTICS_DB", schema_name="MARTS",
                   owner="DEV_ROLE", comment="", query_warehouse="WH_ML", code_warehouse="WH_ML")
        # a recommendation model served from the serving pool, and scored in batch on a warehouse
        db = "PRODUCT_PROD_DB"
        for k in range(1, DAYS):
            for h in (9, 13, 17):
                b.au("MODEL_SERVING_USAGE_HISTORY", invocation_type="SPCS", start_time=b.ts(k, h),
                     end_time=b.ts(k, h) + dt.timedelta(hours=1), database_id=self.db_id[db], database_name=db,
                     schema_id=self.schema_id[(db, "MARTS")], schema_name="MARTS", model_id=7811, model_name="RECO_MODEL",
                     model_version_id=7812, model_version_name="V3" if k <= 40 else "V2", user_name=None,
                     credits=0.05 * self.jitter(), compute_pool_id=9812, compute_pool_name="POOL_PRODUCT_SERVING",
                     service_id=9832, service_name="RECO_API", workload_type="SERVICE")
            if b.back(k).weekday() < 5:
                self.qn += 1
                b.au("MODEL_SERVING_USAGE_HISTORY", invocation_type="WAREHOUSE", start_time=b.ts(k, 4),
                     end_time=b.ts(k, 5), database_id=self.db_id[db], database_name=db,
                     schema_id=self.schema_id[(db, "MARTS")], schema_name="MARTS", model_id=7811, model_name="RECO_MODEL",
                     model_version_id=7812, model_version_name="V3" if k <= 40 else "V2", user_name="SVC_PRODUCT_INGEST",
                     credits=0.3 * self.jitter(), function_name="PREDICT", query_id=f"01dms-{self.qn:07d}",
                     warehouse_id=self.wh["WH_PRODUCT_ETL"]["id"] if "WH_PRODUCT_ETL" in self.wh else None,
                     query_tag="job=nightly_scoring", workload_type="WAREHOUSE_INFERENCE")
        # base fixture fixes: POOL_APP belongs to its app (exclusive), POOL_ML is a user pool
        for r in w.rows.get(("account_usage", "COMPUTE_POOLS"), []):
            if r["name"] == "POOL_APP":
                r["is_exclusive"] = True
        for r in w.rows.get(("account_usage", "SNOWPARK_CONTAINER_SERVICES_HISTORY"), []):
            if r.get("compute_pool_name") == "POOL_ML":
                r["is_exclusive"] = False
            elif r.get("compute_pool_name") == "POOL_APP":
                r.update(is_exclusive=True, application_name="APP_SEARCH", application_id=77)

    # ---- cloud services -----------------------------------------------------------------------------------
    def cloud_services_storm(self) -> None:
        """A BI tool's metadata crawler: SHOW and DESCRIBE with no warehouse, heavy in the last two weeks.

        Snowflake reports such cloud services under the CLOUD_SERVICES_ONLY warehouse (id 0). Above the daily
        10% of compute they are billed, so this is what makes cloud services billed on those days.
        """
        b = self.b
        user = self.svc("SVC_MARKETING_REPORTING")
        role = user["default_role"]
        db = "MARKETING_PROD_DB"
        ctype, app_id, app = b.w.DEMO_CLIENTS["tableau"]
        for k in range(1, 95):
            per_q, n = (0.15, 400) if k <= 14 else ((0.08, 100) if k <= 44 else (0.05, 60))
            if b.back(k).weekday() >= 5:
                n //= 4
            sid = 880000 + k
            # the crawler's daily key-pair sign-in and its session
            when = b.ts(k, 0, 1)
            b.au("LOGIN_HISTORY", event_id=sid, event_timestamp=when, event_type="LOGIN", user_name=user["name"],
                 client_ip="203.0.113.240", reported_client_type=ctype, reported_client_version=app_id.split(" ")[-1],
                 first_authentication_factor="RSA_KEYPAIR", second_authentication_factor=None, is_success="YES",
                 error_code=None, error_message=None, connection=None, login_details=None)
            b.au("SESSIONS", session_id=sid, created_on=when, user_name=user["name"], authentication_method="RSA_KEYPAIR",
                 login_event_id=sid, client_application_id=app_id,
                 client_environment='{"APPLICATION": "%s", "OS": "Linux", "OS_VERSION": "5.15"}' % app,
                 is_open="NO", closed_reason="LOGOUT")
            total = 0.0
            for i in range(n):
                self.qn += 1
                qtype = "SHOW" if i % 3 else "DESCRIBE"
                start = b.ts(k, (i * 24) // n, (i * 7) % 60, i % 60)
                cs = per_q * self.jitter(0.6, 1.4)
                total += cs
                b.au("QUERY_HISTORY", query_id=f"01dcs-{self.qn:08d}",
                     query_text="SHOW COLUMNS IN ACCOUNT" if qtype == "SHOW" else "DESCRIBE TABLE <table>",
                     database_id=self.db_id[db], database_name=db, schema_id=self.schema_id[(db, "MARTS")],
                     schema_name="MARTS", query_type=qtype, session_id=sid, user_name=user["name"],
                     role_name=role, warehouse_id=None, warehouse_name=None, warehouse_size=None, warehouse_type=None,
                     cluster_number=None, query_tag="tool=bi_catalog_sync", execution_status="SUCCESS",
                     start_time=start, end_time=start + dt.timedelta(seconds=4), total_elapsed_time=4000,
                     compilation_time=3900, execution_time=0, queued_provisioning_time=0, queued_repair_time=0,
                     queued_overload_time=0, transaction_blocked_time=0, bytes_scanned=0, rows_produced=500,
                     credits_used_cloud_services=cs, query_hash="hcs01" if qtype == "SHOW" else "hcs02",
                     query_hash_version=2, query_parameterized_hash="hcs01" if qtype == "SHOW" else "hcs02",
                     query_parameterized_hash_version=1, role_type="ROLE", user_type=user["type"],
                     is_client_generated_statement=False)
            for h in range(24):
                start = b.ts(k, h)
                self.b.au("WAREHOUSE_METERING_HISTORY", start_time=start, end_time=start + dt.timedelta(hours=1),
                          warehouse_id=0, warehouse_name="CLOUD_SERVICES_ONLY", credits_used=total / 24,
                          credits_used_compute=0.0, credits_used_cloud_services=total / 24,
                          credits_attributed_compute_queries=None)
                self.b.au("METERING_HISTORY", service_type="WAREHOUSE_METERING", start_time=start,
                          end_time=start + dt.timedelta(hours=1), entity_id=0, entity_type="WAREHOUSE",
                          name="CLOUD_SERVICES_ONLY", credits_used_compute=0.0, credits_used_cloud_services=total / 24,
                          credits_used=total / 24)

    # ---- data transfer ------------------------------------------------------------------------------------
    def transfer(self) -> None:
        """Egress billed to this account: same-cloud copies, an unload to another cloud that grew, container egress,
        a lake unload, file copies, internal traffic and the Postgres trial."""
        b = self.b
        routes = [("COPY", "AWS", "AWS_US_WEST_2", 0.25, 1.0, DAYS, 0),
                  ("COPY", "GCP", "GCP_US_CENTRAL1", 0.1, 2.5, DAYS, 0),
                  ("EXTERNAL_ACCESS", None, None, 0.01, 1.0, 40, 0),
                  ("SNOWPARK_CONTAINER_SERVICES", None, None, 0.02, 1.4, DAYS, 0),
                  ("DATA_LAKE", "AWS", "AWS_US_WEST_2", 0.04, 2.0, 120, 0),
                  ("INTERNAL", "AWS", REGION, 0.03, 1.0, DAYS, 0),
                  ("POSTGRES", "AWS", REGION, 0.005, 1.0, 71, 50)]
        for tt, tcloud, tregion, tb, mult, start, end in routes:
            for k in range(1, DAYS):
                v = self.level(k, tb, mult, start, end=end)
                if v <= 0:
                    continue
                start_t = b.ts(k, 2)
                b.au("DATA_TRANSFER_HISTORY", start_time=start_t, end_time=start_t + dt.timedelta(hours=1),
                     source_cloud="AWS", source_region=REGION, target_cloud=tcloud, target_region=tregion,
                     bytes_transferred=int(v * TB), transfer_type=tt)
        for k in (95, 67, 39, 11):                  # the file copies metered as COPY_FILES
            b.au("DATA_TRANSFER_HISTORY", start_time=b.ts(k, 20), end_time=b.ts(k, 21), source_cloud="AWS",
                 source_region=REGION, target_cloud="AZURE", target_region="AZURE_WESTEUROPE",
                 bytes_transferred=int(0.08 * TB * self.jitter()), transfer_type="COPY_FILES")

    # ---- views the base account fills for a few weeks only ---------------------------------------------------------
    def backfill_short_views(self) -> None:
        """Views the base account fills for 10-60 days get the rest of the demo history: their earliest weeks
        replayed further back at a slowly lower level, so the 90-day window has a period before it."""
        rf = self._replay
        rf("account_usage", "OPENFLOW_USAGE_HISTORY", "start_time", ("start_time", "end_time"),
           ("runtime_credits_used",))
        rf("account_usage", "METERING_HISTORY", "start_time", ("start_time", "end_time"),
           ("credits_used_compute", "credits_used_cloud_services", "credits_used"),
           keep=lambda r: r["service_type"] in ("OPENFLOW_COMPUTE_BYOC", "OPENFLOW_COMPUTE_SNOWFLAKE"))
        rf("account_usage", "SNOWFLAKE_COWORK_USAGE_HISTORY", "start_time", ("start_time", "end_time"),
           ("token_credits", "tokens"), cycle=10)
        rf("account_usage", "CORTEX_CODE_DESKTOP_USAGE_HISTORY", "usage_time", ("usage_time",),
           ("token_credits", "tokens"))
        rf("account_usage", "APPLICATION_DAILY_USAGE_HISTORY", "usage_date", ("usage_date",), ("credits_used",))
        rf("account_usage", "BLOCK_STORAGE_HISTORY", "usage_date", ("usage_date",), ("bytes",))
        rf("account_usage", "MODEL_SERVING_USAGE_HISTORY", "start_time", ("start_time", "end_time"), ("credits",),
           keep=lambda r: (r.get("model_id") or 0) < 7800)
        rf("account_usage", "CATALOG_LINKED_DATABASE_USAGE_HISTORY", "start_time", ("start_time", "end_time"),
           ("credits_used_compute", "credits_used_cloud_services", "credits_used"))
        rf("account_usage", "NOTEBOOKS_CONTAINER_RUNTIME_HISTORY", "start_time", ("start_time", "end_time"), ("credits",),
           keep=lambda r: r["notebook_id"] < 7800)
        rf("data_sharing_usage", "LISTING_AUTO_FULFILLMENT_REFRESH_DAILY", "usage_date", ("usage_date",),
           ("credits_used", "bytes_transferred"))
        rf("organization_usage", "LISTING_AUTO_FULFILLMENT_USAGE_HISTORY", "usage_date", ("usage_date",),
           ("estimated_usage", "estimated_usage_in_currency"))
        # paid listings bill once a month: the base week of charges repeats a month apart
        rows = self.b.w.rows.get(("data_sharing_usage", "MARKETPLACE_PAID_USAGE_DAILY"), [])
        for r in list(rows):
            for j in range(1, 6):
                d = dt.timedelta(days=30 * j)
                rows.append(dict(r, report_date=r["report_date"] - d, usage_date=r["usage_date"] - d))

    def _replay(self, sch, view, when, moved, scaled, keep=None, cycle=28) -> None:
        b = self.b
        rows = b.w.rows.get((sch, view), [])
        back = lambda r: (b.as_of - _day(r[when])).days                      # noqa: E731
        mine = [r for r in rows if keep is None or keep(r)]
        if not mine:
            return
        oldest = max(back(r) for r in mine)
        if oldest >= DAYS - 1:
            return
        cycle = min(cycle, oldest)
        first = oldest - cycle + 1
        tmpl = collections.defaultdict(list)
        for r in mine:
            if back(r) >= first:
                tmpl[back(r)].append(r)
        for k in range(oldest + 1, DAYS):
            src = first + (k - oldest - 1) % cycle
            f = (1.0 - 0.3 * (k - oldest) / (DAYS - oldest)) * self.rng.uniform(0.9, 1.1)
            delta = dt.timedelta(days=k - src)
            for r in tmpl.get(src, []):
                out = dict(r)
                for c in moved:
                    if out.get(c) is not None:
                        out[c] = out[c] - delta
                for c in scaled:
                    x = out.get(c)
                    if isinstance(x, (int, float)) and not isinstance(x, bool):
                        out[c] = int(x * f) if isinstance(x, int) else x * f
                for c in ("request_id", "query_id", "query_token"):
                    if out.get(c):
                        out[c] = f"{out[c]}-d{k}"
                rows.append(out)

    # ---- databases the other views name ------------------------------------------------------------------------
    def databases(self) -> None:
        """Every database SHOW DATABASES lists is in DATABASES too: imported shares, installed apps, the
        catalog-linked databases and a personal database."""
        b, w = self.b, self.b.w
        listed = {r["database_name"] for r in w.rows.get(("account_usage", "DATABASES"), [])}
        shown = {r["name"] for r in w.rows.get(("show", "databases"), [])}

        def both(db_id, name, typ, kind, owner, created, origin="", retention=1):
            if name not in listed:
                b.au("DATABASES", database_id=db_id, database_name=name, database_owner=owner, is_transient="NO",
                     type=typ, retention_time=retention, created=created, last_altered=created, deleted=None,
                     owner_role_type="ROLE", object_visibility=None)
            if name not in shown:
                b.show("databases", created_on=created, name=name, is_default="N", is_current="N", origin=origin,
                       owner=owner, comment="", options="", retention_time=str(retention), kind=kind,
                       owner_role_type="ROLE")

        for i, r in enumerate(sorted(w.rows.get(("show", "databases"), []), key=lambda r: r["name"])):
            if r.get("kind") == "IMPORTED DATABASE" and r["name"] not in listed:
                both(4801 + i, r["name"], "IMPORTED DATABASE", "IMPORTED DATABASE", r.get("owner") or "ACCOUNTADMIN",
                     r["created_on"], r.get("origin") or "", 0)
        for i, r in enumerate(sorted(w.rows.get(("show", "applications"), []), key=lambda r: r["name"])):
            both(4851 + i, r["name"], "APPLICATION", "APPLICATION", r.get("owner") or "ACCOUNTADMIN", r["created_on"],
                 r.get("source") or "", 1)
        for db_id, name, days_back in ((6001, "CLDB_ACTIVE", 170), (6002, "CLDB_IDLE", 160), (6003, "CLDB_SMALL", 90)):
            both(db_id, name, "STANDARD", "CATALOG-LINKED DATABASE", "PLATFORM_ADMIN", b.ts(days_back, 9),
                 "GLUE_DEMO_INT", 0)
        both(4871, "USER$TEO_HOLM", "PERSONAL DATABASE", "PERSONAL DATABASE", "TEO_HOLM", b.ts(240, 9), "", 1)

    # ---- organization: this account ---------------------------------------------------------------------
    def org_own_account(self) -> None:
        """The org views of this account mirror its own sign-ins, users and rates (billing: demo_billing)."""
        b, w = self.b, self.b.w
        common = self.org_common()
        # the base fixture's org rows for this account go: the org copy is exactly the account's own views
        for view in ("USERS", "LOGIN_HISTORY"):
            rows = w.rows.get(("organization_usage", view), [])
            rows[:] = [r for r in rows if r.get("account_locator") != LOC]
        login_cols = {c.lower() for c, _ in schema.VIEWS["organization_usage"]["LOGIN_HISTORY"]}
        since = b.ts(60)
        for r in w.rows[("account_usage", "LOGIN_HISTORY")]:
            if r["event_timestamp"] >= since:
                b.ou("LOGIN_HISTORY", organization_name=ORG, account_name=ACCT, account_locator=LOC,
                     **{k: v for k, v in r.items() if k in login_cols})
        user_cols = {c.lower() for c, _ in schema.VIEWS["organization_usage"]["USERS"]}
        for r in w.rows[("account_usage", "USERS")]:
            b.ou("USERS", organization_name=ORG, account_name=ACCT, account_locator=LOC,
                 **{k: v for k, v in r.items() if k in user_cols})
        # a few days billed as on-demand overage, at the higher overage rate
        for k in (5, 6, 7):
            b.ou("USAGE_IN_CURRENCY_DAILY", **common, contract_number=4001, service_level="ENTERPRISE",
                 usage_date=b.back(k), usage_type="overage-compute", usage=12.0, currency="USD",
                 usage_in_currency=12.0 * 3.9, balance_source="overage", billing_type="consumption",
                 rating_type="compute", service_type="WAREHOUSE_METERING", is_adjustment=False)
        # restatements: compute re-rated after the month closed, and one inside the open month
        for k, usd in ((33, -64.0), (35, 18.5), (4, -22.0)):
            b.ou("USAGE_IN_CURRENCY_DAILY", **common, contract_number=4001, service_level="ENTERPRISE",
                 usage_date=b.back(k), usage_type="compute", usage=usd / PRICE, currency="USD", usage_in_currency=usd,
                 balance_source="capacity", billing_type="consumption", rating_type="compute",
                 service_type="WAREHOUSE_METERING", is_adjustment=True)
        # Support reversed part of a month's priority support fee after an incident: a credit note
        b.ou("USAGE_IN_CURRENCY_DAILY", **common, contract_number=4001, service_level="ENTERPRISE",
             usage_date=b.back(36), usage_type="support credit", usage=1.0, currency="USD", usage_in_currency=-750.0,
             balance_source="capacity", billing_type="support_credit", rating_type="other", service_type=None,
             is_adjustment=True)
        # rate sheet: a row per usage type the account is billed for, at the contract price, plus overage,
        # transfer, storage and the monthly support fee
        rated = {}
        services = {r["service_type"] for r in w.rows.get(("account_usage", "METERING_HISTORY"), [])}
        for service in sorted(services | set(demo_billing.USAGE_TYPE)):
            usage_type = demo_billing.USAGE_TYPE.get(service, service.lower().replace("_", " "))
            rated.setdefault(usage_type, service)
        rated["cloud services"] = "CLOUD_SERVICES"
        for k in range(1, DAYS):
            rows = [(u, s, "compute", PRICE, "consumption", False) for u, s in sorted(rated.items())]
            rows += [("overage-compute", "COMPUTE", "compute", 3.9, "consumption", False),
                     ("data transfer", "DATA_TRANSFER", "data_transfer", 90.0, "consumption", False),
                     ("storage", "STORAGE", "storage", data.STORAGE_PRICE_TB_DAY, "consumption", False),
                     ("priority support", None, "other", demo_billing.SUPPORT_FEE, "priority support", False)]
            if k == 33:
                rows.append(("compute", "WAREHOUSE_METERING", "compute", PRICE, "consumption", True))   # the re-rated month
            for usage_type, service, rating, rate, billing, adj in rows:
                b.ou("RATE_SHEET_DAILY", date=b.back(k), **common, contract_number=4001, service_level="ENTERPRISE",
                     usage_type=usage_type, currency="USD", effective_rate=rate, service_type=service,
                     rating_type=rating, billing_type=billing, is_adjustment=adj)

    # ---- organization: other accounts ---------------------------------------------------------------------
    def org_other_accounts(self) -> None:
        b = self.b
        accounts = [
            dict(loc="FAKE11", name="FAKE_EU", edition="ENTERPRISE", region="AZURE_WESTEUROPE", created=420,
                 comment="EU analytics and reporting", rate=3.3, contract=4001, spike=(5,),
                 whs=[(2001, "WH_EU_ETL", 45), (2002, "WH_EU_BI", 30), (2003, "WH_EU_ADHOC", 8)],
                 features={"MATERIALIZED_VIEW": 1.5, "SEARCH_OPTIMIZATION": 0.8, "AUTO_CLUSTERING": 3.0},
                 storage=(2.0, 2.6), transfer=[("COPY", "AZURE", "AZURE_NORTHEUROPE", 0.02)], trend=1.1,
                 users=[("PERSON", True, True)] * 10 + [("SERVICE", False, False)] * 2, logins=(12, 0.02, True),
                 support_credit=(40, -420.0)),
            dict(loc="FAKE12", name="FAKE_DR", edition="BUSINESS_CRITICAL", region="AWS_US_WEST_2", created=300,
                 comment="DR site: failover primary, and a secondary of the main account", rate=4.0, contract=4001,
                 whs=[(2101, "WH_DR_VALIDATE", 2)], features={"REPLICATION": 5.0},
                 storage=(1.5, 1.5), transfer=[], trend=1.0,
                 users=[("PERSON", True, True)] * 2 + [("SERVICE", True, False)], logins=(3, 0.45, True)),
            dict(loc="FAKE13", name="FAKE_PARTNER_APPS", edition="ENTERPRISE", region="GCP_US_CENTRAL1", created=250,
                 comment=None, rate=3.0, contract=4001,
                 whs=[(2201, "WH_APP_SERVING", 35), (2202, "WH_APP_ETL", 20)], features={},
                 storage=(0.8, 0.9), transfer=[("COPY", "AWS", "AWS_US_EAST_1", 0.5)], trend=1.9, spike=(9,),
                 users=[("PERSON", True, False)] * 3 + [("PERSON", True, True)] * 3 + [("SERVICE", True, False)],
                 logins=(6, 0.05, False)),
            dict(loc="FAKE14", name="FAKE_SANDBOX_OLD", edition="STANDARD", region="AWS_US_EAST_1", created=700,
                 comment="Old sandbox, owner left", rate=2.0, contract=4001, active_until=75,
                 whs=[(2301, "WH_SANDBOX", 3)], features={}, storage=(14.0, 14.0), transfer=[], trend=1.0,
                 users=[("PERSON", True, False)] * 4, logins=(0, 0.0, False)),
            dict(loc="FAKE15", name="FAKE_ML_LAB", edition="ENTERPRISE", region="AWS_US_WEST_2", created=18,
                 comment="ML experiments", rate=3.0, contract=4001,
                 whs=[(2401, "WH_ML_GPU", 25)], features={"AI_SERVICES": 15.0, "SNOWPARK_CONTAINER_SERVICES": 10.0},
                 storage=(0.3, 0.3), transfer=[], trend=1.0,
                 users=[("PERSON", True, True)] * 4, logins=(4, 0.0, True)),
            dict(loc="FAKE16", name="FAKE_PAYMENTS_VPS", edition="VIRTUAL_PRIVATE_SNOWFLAKE", region="AWS_US_EAST_1",
                 region_group="FAKE_VPS_GROUP", created=380, comment="Card data, isolated deployment", rate=4.6,
                 contract=4001, whs=[(2501, "WH_PCI_ETL", 22), (2502, "WH_PCI_BI", 6)], features={},
                 storage=(1.1, 1.2), transfer=[], trend=1.05,
                 users=[("PERSON", False, True)] * 3 + [("SERVICE", False, False)], logins=(3, 0.0, True)),
            dict(loc="FAKE17", name="FAKE_TRAINING", edition="STANDARD", region="AWS_US_EAST_1", created=500,
                 comment="Training account, locked after the course ended", rate=2.0, contract=4001, locked=True,
                 active_until=DAYS, whs=[], features={}, storage=(0.05, 0.05), transfer=[], trend=1.0,
                 users=[("PERSON", True, False)] * 3, logins=(0, 0.0, False)),
            dict(loc="FAKE18", name="FAKE_POC_2026", edition="ENTERPRISE", region="AWS_EU_CENTRAL_1", created=140,
                 comment="Vendor proof of concept", rate=3.0, contract=4001, dropped=20,
                 whs=[(2601, "WH_POC", 12)], features={}, storage=(0.4, 0.4), transfer=[], trend=1.0,
                 users=[("PERSON", True, True)] * 2, logins=(2, 0.0, True)),
        ]
        usage_type = {"MATERIALIZED_VIEW": "materialized views", "SEARCH_OPTIMIZATION": "search optimization",
                      "AUTO_CLUSTERING": "automatic clustering", "REPLICATION": "replication",
                      "AI_SERVICES": "ai services", "SNOWPARK_CONTAINER_SERVICES": "snowpark container services"}
        for a in accounts:
            common = dict(organization_name=ORG, account_name=a["name"], account_locator=a["loc"], region=a["region"])
            dropped = a.get("dropped")
            b.ou("ACCOUNTS", organization_name=ORG, account_name=a["name"], account_locator=a["loc"],
                 account_url=f"https://{a['name'].lower()}.example.com", edition=a["edition"], region=a["region"],
                 region_group=a.get("region_group", "PUBLIC"), is_org_admin=False, is_locked=bool(a.get("locked")),
                 is_managed=False, managed_accounts=0, contract_number=a["contract"],
                 created_on=b.ts(a["created"], 9), altered_on=b.ts(min(a["created"], dropped or 40), 9),
                 scheduled_deletion_time=b.ts(dropped, 9) if dropped else None,
                 deleted_on=b.ts(dropped, 9) if dropped else None, is_events_account=False, comment=a["comment"])
            bill = dict(contract_number=a["contract"], service_level=a["edition"], currency="USD",
                        balance_source="capacity", billing_type="consumption", is_adjustment=False)
            last_ok: dict = {}
            for k in range(max(1, dropped or 1), min(a["created"], data.HISTORY_DAYS)):
                d = b.back(k)
                grow = a["trend"] if k <= 33 else 1.0
                factor = grow * (5.0 if k in a.get("spike", ()) else 1.0) * (0.4 if d.weekday() >= 5 else 1.0)
                active = k >= a.get("active_until", 0)
                compute = cs = 0.0
                for wid, wname, per_day in a["whs"] if active else []:
                    credits = per_day * factor * self.jitter()
                    for hour in (2, 8, 13, 18):
                        start = b.ts(k, hour)
                        b.ou("WAREHOUSE_METERING_HISTORY", **common, service_type="WAREHOUSE_METERING",
                             start_time=start, end_time=start + dt.timedelta(hours=1), warehouse_id=wid,
                             warehouse_name=wname, credits_used_compute=credits / 4,
                             credits_used_cloud_services=credits / 4 * 0.04, credits_used=credits / 4 * 1.04)
                    compute += credits
                    cs += credits * 0.04
                services = [("WAREHOUSE_METERING", compute, cs)] if compute else []
                services += [(s, v * factor * self.jitter(), 0.0) for s, v in a["features"].items()]
                for service, comp, c in services:
                    adj = -min(c, 0.1 * comp)
                    b.ou("METERING_DAILY_HISTORY", **common, service_type=service, usage_date=d,
                         credits_used_compute=comp, credits_used_cloud_services=c, credits_used=comp + c,
                         credits_adjustment_cloud_services=adj, credits_billed=comp + c + adj)
                    b.ou("USAGE_IN_CURRENCY_DAILY", **common, **bill, usage_date=d,
                         usage_type=usage_type.get(service, "compute"), usage=comp + c + adj,
                         usage_in_currency=(comp + c + adj) * a["rate"], rating_type="compute", service_type=service)
                    if service == "REPLICATION":
                        b.ou("REPLICATION_USAGE_HISTORY", **common, usage_date=d, database_id=None,
                             database_name="FINANCE_PROD_DB", credits_used=comp, bytes_transferred=int(comp * 3e10))
                lo, hi = a["storage"]
                tb = lo + (hi - lo) * max(0.0, 1 - k / 33)          # growth over the last month
                b.ou("STORAGE_DAILY_HISTORY", **common, service_type="STORAGE", usage_date=d,
                     average_bytes=tb * TB, credits=None)
                b.ou("USAGE_IN_CURRENCY_DAILY", **common, **bill, usage_date=d, usage_type="storage", usage=tb,
                     usage_in_currency=tb * data.STORAGE_PRICE_TB_DAY, rating_type="storage", service_type="STORAGE")
                for tt, tcloud, tregion, tbs in a["transfer"]:
                    v = tbs * factor * self.jitter()
                    src_cloud = a["region"].split("_")[0]
                    b.ou("DATA_TRANSFER_HISTORY", **common, usage_date=d, source_cloud=src_cloud,
                         source_region=a["region"], target_cloud=tcloud, target_region=tregion,
                         bytes_transferred=int(v * TB), transfer_type=tt)
                    rate = 20.0 if tcloud == src_cloud else 90.0
                    b.ou("USAGE_IN_CURRENCY_DAILY", **common, **bill, usage_date=d, usage_type="data transfer",
                         usage=v, usage_in_currency=v * rate, rating_type="data_transfer", service_type="DATA_TRANSFER")
                rates = [("compute", "COMPUTE", "compute", a["rate"], "consumption"),
                         ("storage", "STORAGE", "storage", data.STORAGE_PRICE_TB_DAY, "consumption")]
                if a["edition"] == "VIRTUAL_PRIVATE_SNOWFLAKE":
                    rates.append(("vps deployment fee", None, "other", VPS_FEE, "vps_deployment_fee"))
                    if d.day == 1:                               # the deployment's own monthly fee
                        b.ou("USAGE_IN_CURRENCY_DAILY", **common, **dict(bill, billing_type="vps_deployment_fee"),
                             usage_date=d, usage_type="vps deployment fee", usage=1.0, usage_in_currency=VPS_FEE,
                             rating_type="other", service_type=None)
                for usage, svc_type, rating, rate, billing in rates:
                    b.ou("RATE_SHEET_DAILY", date=d, **common, contract_number=a["contract"],
                         service_level=a["edition"], usage_type=usage, currency="USD", effective_rate=rate,
                         service_type=svc_type, rating_type=rating, billing_type=billing, is_adjustment=False)
                n, fail, mfa = a["logins"]
                for i in range(n if d.weekday() < 5 else 0):
                    ok = self.rng.random() >= fail
                    user = f"{a['name'][5:]}_USER_{i % len(a['users']) + 1:02d}"
                    when = b.ts(k, 8 + i % 10, i * 3 % 60)
                    if ok:
                        last_ok[user] = max(last_ok.get(user, when), when)
                    b.ou("LOGIN_HISTORY", organization_name=ORG, account_name=a["name"], account_locator=a["loc"],
                         event_id=int(a["loc"][-2:]) * 10**7 + k * 100 + i, event_timestamp=when,
                         event_type="LOGIN", user_name=user, client_ip=f"198.51.100.{10 + i}",
                         reported_client_type="SNOWFLAKE_UI", first_authentication_factor="PASSWORD",
                         second_authentication_factor="TOTP" if mfa and ok else None,
                         is_success="YES" if ok else "NO", error_code=None if ok else 390100,
                         error_message=None if ok else "Incorrect username or password was specified.")
            for i, (typ, pw, mfa) in enumerate(a["users"]):
                name = f"{a['name'][5:]}_USER_{i + 1:02d}" if typ == "PERSON" else f"{a['name'][5:]}_SVC_{i + 1:02d}"
                last = last_ok.get(name)
                if last is None and not a["logins"][0]:
                    last = b.ts(min(80 + i, a["created"] - 1), 9)
                b.ou("USERS", organization_name=ORG, account_locator=a["loc"], account_name=a["name"],
                     user_id=int(a["loc"][-2:]) * 1000 + i, name=name, login_name=name, email=None, type=typ,
                     disabled=False, snowflake_lock=bool(a.get("locked")), has_password=pw,
                     has_mfa=mfa if typ == "PERSON" else None, ext_authn_duo=False, has_rsa_public_key=typ != "PERSON",
                     has_pat=False, last_success_login=last, created_on=b.ts(a["created"], 10), default_role="PUBLIC",
                     deleted_on=b.ts(dropped, 9) if dropped else None)
            if a.get("support_credit"):                          # Support reversed charges after an incident
                k, usd = a["support_credit"]
                b.ou("USAGE_IN_CURRENCY_DAILY", **common, **dict(bill, billing_type="support_credit"),
                     usage_date=b.back(k), usage_type="support credit", usage=1.0, usage_in_currency=usd,
                     rating_type="other", service_type=None)
            sev = {"FAKE13": ("CRITICAL", "OPEN"), "FAKE14": ("HIGH", "OPEN"), "FAKE11": ("MEDIUM", "RESOLVED")}
            if a["loc"] in sev:
                b.ou("TRUST_CENTER_FINDINGS", organization_name=ORG, account_locator=a["loc"], account_name=a["name"],
                     id=1, provider_id="SNOWFLAKE", scanner_package_id="SECURITY_ESSENTIALS", scanner_id="MFA_PERSON_USERS",
                     severity=sev[a["loc"]][0], state=sev[a["loc"]][1], created_on=b.ts(20), updated_on=b.ts(4))

        rows = b.w.rows.get(("organization_usage", "ACCOUNTS"), [])
        for r in rows:
            if r.get("region_group") is None:
                r["region_group"] = "PUBLIC"
            if r["account_locator"] == LOC:
                r["managed_accounts"] = 4                          # READER_PARTNER and the three demo readers
        # the reader accounts this account manages
        for name, loc, created in (("READER_DISTRIBUTOR_A", "RDR02", 260), ("READER_AGENCY_B", "RDR03", 180),
                                   ("READER_PILOT_C", "RDR04", 150)):
            b.ou("ACCOUNTS", organization_name=ORG, account_name=name, account_locator=loc,
                 account_url=f"https://{loc.lower()}.example.com", edition="ENTERPRISE", region=REGION,
                 region_group="PUBLIC", is_org_admin=False, is_locked=False, is_managed=True, parent_account=ACCT,
                 managed_accounts=0, contract_number=4001, created_on=b.ts(created, 9), altered_on=b.ts(created, 9),
                 is_events_account=False, comment="Reader account")
        # FAKE_DORMANT: nobody uses it, but it still stores 3 TB every day
        dorm = dict(organization_name=ORG, account_name="FAKE_DORMANT", account_locator="FAKE03",
                    region="AZURE_WESTEUROPE")
        for k in range(1, data.HISTORY_DAYS):
            tb = 3.0 * (1 - 0.0004 * k)
            b.ou("STORAGE_DAILY_HISTORY", **dorm, service_type="STORAGE", usage_date=b.back(k), average_bytes=tb * TB,
                 credits=None)
            b.ou("USAGE_IN_CURRENCY_DAILY", **dorm, contract_number=4001, service_level="BUSINESS_CRITICAL",
                 currency="USD", balance_source="capacity", billing_type="consumption", is_adjustment=False,
                 usage_date=b.back(k), usage_type="storage", usage=tb, usage_in_currency=tb * data.STORAGE_PRICE_TB_DAY,
                 rating_type="storage", service_type="STORAGE")

    def org_stub_accounts(self) -> None:
        """The base account's three cloud-services fixtures (no ACCOUNTS row) are sized like small accounts and
        get the same history as the rest of the org, so they do not swell the org's spend."""
        ou = self.b.w.rows
        stubs = {"FAKE05", "FAKE06", "FAKE07"}
        scale = 0.06
        for view, cols in (("METERING_DAILY_HISTORY", ("credits_used_compute", "credits_used_cloud_services",
                                                       "credits_used", "credits_adjustment_cloud_services",
                                                       "credits_billed")),
                           ("USAGE_IN_CURRENCY_DAILY", ("usage", "usage_in_currency"))):
            rows = ou.get(("organization_usage", view), [])
            mine = [r for r in rows if r.get("account_locator") in stubs]
            for r in mine:
                for c in cols:
                    if isinstance(r.get(c), (int, float)):
                        r[c] = r[c] * scale
            if not mine:
                continue
            oldest = max((self.b.as_of - r["usage_date"]).days for r in mine)
            tmpl = collections.defaultdict(list)
            for r in mine:
                tmpl[(self.b.as_of - r["usage_date"]).days].append(r)
            span = sorted(tmpl)
            for k in range(oldest + 1, data.HISTORY_DAYS):
                src = span[(k - oldest - 1) % len(span)]
                f = self.rng.uniform(0.85, 1.05)
                for r in tmpl[src]:
                    out = dict(r, usage_date=self.b.back(k))
                    for c in cols:
                        if isinstance(out.get(c), (int, float)):
                            out[c] = out[c] * f
                    rows.append(out)

    # ---- sharing ------------------------------------------------------------------------------------------
    def sharing(self) -> None:
        b, w = self.b, self.b.w
        # inbound shares: read every day, read by one team, never read since it was mounted, open to PUBLIC
        inbound = [("MARKETPLACE_WEATHER", "WXPROV.WX01.WEATHER_DAILY", 300, "MARKETING", ["DAILY_FORECAST", "HISTORY"], 6),
                   ("FX_RATES_FEED", "FXVENDOR.FX01.FX_SHARE", 400, "FINANCE", ["RATES_DAILY"], 3),
                   ("POI_TRIAL_DATA", "GEOPROV.GEO01.POI_TRIAL", 150, None, [], 0),
                   ("DEMOGRAPHICS_SAMPLE", "CENSUSPROV.CEN01.DEMO_SHARE", 220, "PRODUCT", ["REGIONS"], 1)]
        n = 0
        for name, origin, created, team, objects, per_day in inbound:
            b.show("databases", created_on=b.ts(created, 9), name=name, is_default="N", is_current="N", origin=origin,
                   owner="ACCOUNTADMIN", comment="", options="", retention_time="0", kind="IMPORTED DATABASE",
                   owner_role_type="ROLE")
            prov, _acct, share = origin.split(".")
            b.show("shares", created_on=b.ts(created, 9), kind="INBOUND", owner_account=f"{prov}.{_acct}",
                   name=f"{prov}.{_acct}.{share}", database_name=name, to=None, owner=None, comment="",
                   listing_global_name=None)
            grantees = [f"{team}_READ"] if team else ["SYSADMIN"]
            if name == "DEMOGRAPHICS_SAMPLE":
                grantees.append("PUBLIC")
            for g in grantees:
                w.grant("IMPORTED PRIVILEGES", "DATABASE", name, g, granted_by="ACCOUNTADMIN", days_back=created - 1)
            for k in range(1, 96):
                for _ in range(per_day if b.back(k).weekday() < 5 else 0):
                    n += 1
                    user = self.person(team, n)
                    if not self.on(user, k):
                        continue
                    obj = f"{name}.PUBLIC.{self.rng.choice(objects)}"
                    b.au("ACCESS_HISTORY", query_id=f"01dsh-{n:07d}", query_start_time=b.ts(k, 9 + n % 8, n % 60),
                         user_name=user["name"],
                         direct_objects_accessed=[{"objectDomain": "Table", "objectName": obj, "objectId": 990000 + len(obj),
                                                   "columns": [{"columnId": 1, "columnName": "ID"}]}],
                         base_objects_accessed=[{"objectDomain": "Table", "objectName": obj, "objectId": 990000 + len(obj),
                                                 "columns": [{"columnId": 1, "columnName": "ID"}]}],
                         objects_modified=[], policies_referenced=[], root_query_id=f"01dsh-{n:07d}")
        # the base imported database has its inbound share too
        b.show("shares", created_on=b.ts(500, 9), kind="INBOUND", owner_account="PARTNER1.ACCT1",
               name="PARTNER1.ACCT1.SHARE_X", database_name="PARTNER_DATA", to=None, owner=None, comment="",
               listing_global_name=None)

        # outbound shares: one wide share that allows non-secure views, a stale one, a listing with consumers,
        # and one dropped in the window
        outbound = [  # name, database, consumers, secure only, listing, created, deleted, objects
            ("SHARE_SALES_PARTNERS", "SALES_PROD_DB", [f"PARTNER{i:02d}.ACCT" for i in range(2, 14)], False, None, 260,
             None, ["MARTS.PIPELINE_SUMMARY", "MARTS.TERRITORIES"]),
            ("SHARE_OPS_VENDOR", "OPS_PROD_DB", [], True, None, 400, None, ["MARTS.SLA_DAILY"]),
            ("SHARE_FINANCE_AUDITOR", "FINANCE_PROD_DB", ["AUDITCO.MAIN"], True, None, 180, None,
             ["MARTS.LEDGER_SUMMARY"]),
            ("SHARE_PRODUCT_INSIGHTS", "PRODUCT_PROD_DB", [], True, "GZDEMO1.PRODUCT_INSIGHTS", 200, None,
             ["MARTS.USAGE_TRENDS", "MARTS.FEATURE_ADOPTION"]),
            ("SHARE_MKT_OLD", "MARKETING_PROD_DB", ["AGENCY9.MAIN"], True, None, 500, 14, ["MARTS.CAMPAIGNS"]),
            # the shares the base fixture's GRANTS_TO_SHARES rows already name (object grants exist)
            ("SHARE_ORDERS", "ANALYTICS_DB", ["PARTNER1.ACCT1", "VENDORX.MAIN"], False, None, 150, None, []),
            ("SHARE_VIEW", "ANALYTICS_DB", ["PARTNER1.ACCT1"], True, None, 150, None, []),
            ("SHARE_CLEAN", "SANDBOX_DB", ["PARTNER1.ACCT1"], False, None, 90, None, []),
        ]
        for name, db, consumers, secure, listing, created, deleted, objs in outbound:
            owner = f"{db[:-len('_PROD_DB')]}_ADMIN" if db.endswith("_PROD_DB") else "ACCOUNTADMIN"
            b.au("SHARES", created_on=b.ts(created, 9), modified_on=b.ts(min(created, 30), 9),
                 deleted_on=b.ts(deleted, 10) if deleted else None, name=name, owner=owner,
                 comment=None, database_name=db, secure_objects_only="YES" if secure else "NO",
                 target_accounts=",".join(consumers) or None, listing_global_name=listing)
            if not deleted:
                b.show("shares", created_on=b.ts(created, 9), kind="OUTBOUND", owner_account=LOC, name=name,
                       database_name=db, to=",".join(consumers), owner=owner, comment="",
                       listing_global_name=listing)
            b.au("GRANTS_TO_SHARES", created_on=b.ts(created, 9), modified_on=b.ts(created, 9),
                 deleted_on=b.ts(deleted, 10) if deleted else None, privilege="USAGE", granted_on="DATABASE",
                 object_name=db, object_database=db, object_schema=None, share_name=name, granted_by="ACCOUNTADMIN",
                 granted_by_role_type="ROLE")
            for obj in objs:
                sch, view = obj.split(".")
                b.au("GRANTS_TO_SHARES", created_on=b.ts(created - 1, 9), modified_on=b.ts(created - 1, 9),
                     deleted_on=b.ts(deleted, 10) if deleted else None, privilege="SELECT",
                     granted_on="VIEW" if secure else "TABLE", object_name=view, object_database=db,
                     object_schema=sch, share_name=name, granted_by="ACCOUNTADMIN", granted_by_role_type="ROLE")
        # the listing's consumers: three accounts query it, a fourth stopped two months ago
        q = 0
        for consumer, loc, start, stop, per_week in (("RETAILCO_MAIN", "RC0001", DAYS, 0, 5), ("BANKX_DATA", "BX0042", 120, 0, 3),
                                                     ("LOGIFLOW", "LF0007", 45, 0, 2), ("OLDPARTNER", "OP0003", DAYS, 60, 2)):
            for k in range(max(stop, 1), min(start, DAYS)):
                if b.back(k).weekday() >= per_week:
                    continue
                q += 1
                b.w.add("data_sharing_usage", "LISTING_ACCESS_HISTORY", dict(
                    query_token=f"dqt-{q:06d}", query_date=b.back(k), exchange_name="SNOWFLAKE_DATA_MARKETPLACE",
                    snowflake_region=REGION, listing_global_name="GZDEMO1.PRODUCT_INSIGHTS",
                    provider_account_locator=LOC, provider_account_name=ACCT, share_name="SHARE_PRODUCT_INSIGHTS",
                    consumer_account_locator=loc, consumer_account_name=consumer,
                    consumer_account_organization=f"{consumer}_ORG", region_group="PUBLIC", consumer_name=consumer,
                    is_share=True, is_application=False,
                    share_objects_accessed=[{"objectName": "PRODUCT_PROD_DB.MARTS.USAGE_TRENDS", "objectDomain": "View"}]))
        # listing auto-fulfillment groups are replication groups too
        groups = sorted({r["fulfillment_group_name"] for r in w.rows.get(
            ("data_sharing_usage", "LISTING_AUTO_FULFILLMENT_REFRESH_DAILY"), [])})
        for g in groups:
            b.au("REPLICATION_GROUPS", created=b.ts(DAYS + 10, 9), name=g, type="REPLICATION",
                 comment="Listing auto-fulfillment", object_types="DATABASES", replication_schedule="1440 MINUTE",
                 owner="ACCOUNTADMIN", is_listing_auto_fulfillment_group=True, is_optimized_refresh_enabled=False)

        # reader accounts: a heavy one without a monitor, a small monitored one, one nobody signs in to.
        # Their storage is billed to this account's contract under the reader's own name (STORAGE_READER).
        for name, loc, created, per_day, monitor, logins, store in (
                ("READER_DISTRIBUTOR_A", "RDR02", 260, 12.0, False, 4, 0.4),
                ("READER_AGENCY_B", "RDR03", 180, 0.5, True, 1, 0.05),
                ("READER_PILOT_C", "RDR04", 150, 0.0, False, 0, 0.02)):
            b.show("managed_accounts", account_name=name, cloud="aws", region="us-east-1", account_locator=loc,
                   created_on=b.ts(created, 9), account_url=f"https://{loc.lower()}.example.com", is_reader="true", comment="")
            if monitor:
                b.w.add("reader_account_usage", "RESOURCE_MONITORS", dict(
                    reader_account_name=name, name=f"RM_{name}", created=b.ts(created - 1, 9), credit_quota=30,
                    used_credits=8, remaining_credits=22.0, owner="ACCOUNTADMIN", level="ACCOUNT", notify=80, suspend=100))
            reader = dict(organization_name=ORG, account_name=name, account_locator=loc, region=REGION)
            for k in range(1, min(created, DAYS)):
                tb = store * (1 + 0.1 * max(0, 30 - k) / 30)          # grew a tenth over the last month
                b.ou("STORAGE_DAILY_HISTORY", **reader, service_type="STORAGE_READER", usage_date=b.back(k),
                     average_bytes=tb * TB, credits=None)
                b.ou("USAGE_IN_CURRENCY_DAILY", **reader, contract_number=4001, service_level="ENTERPRISE",
                     currency="USD", balance_source="capacity", billing_type="consumption", is_adjustment=False,
                     usage_date=b.back(k), usage_type="storage", usage=tb, usage_in_currency=tb * data.STORAGE_PRICE_TB_DAY,
                     rating_type="storage", service_type="STORAGE")
                if per_day and b.back(k).weekday() < 5:
                    c = per_day * self.jitter()
                    b.w.add("reader_account_usage", "WAREHOUSE_METERING_HISTORY", dict(
                        reader_account_name=name, start_time=b.ts(k, 10), end_time=b.ts(k, 11), warehouse_id=1,
                        warehouse_name=f"{name}_WH", credits_used=c * 1.05, credits_used_compute=c,
                        credits_used_cloud_services=c * 0.05))
                    # the provider pays for its reader accounts' warehouses
                    self.meter(k, 10, "WAREHOUSE_METERING_READER", c, None, f"{name}_WH", "WAREHOUSE", cs=c * 0.05)
                for i in range(logins if b.back(k).weekday() < 5 and k < 96 else 0):
                    b.w.add("reader_account_usage", "LOGIN_HISTORY", dict(
                        reader_account_name=name, event_timestamp=b.ts(k, 9, i * 5), event_type="LOGIN",
                        user_name=f"{name[7:]}_U{i + 1}", is_success="YES"))
