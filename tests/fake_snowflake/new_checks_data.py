"""Fake rows for the second batch of checks (AI usage, org billing, performance, security, loading).

Each group adds only rows the older data does not have, with names of its own where a view is shared,
so the earlier checks read the same numbers. Every check gets at least one OK row and, where the check
has the levels, a WARN and a CRITICAL row. `add(world)` runs last in World.build.

Prices: 3 USD per credit. Windows: 30 days, the current window is the 30 days before the as-of date and
the previous window the 30 before that.
"""
from __future__ import annotations

import datetime as dt
import json


def _ts(day: dt.date, hour: int = 0, minute: int = 0) -> dt.datetime:
    return dt.datetime(day.year, day.month, day.day, hour, minute, 0)


class _B:
    """Helpers over the World: `back(k)` is the k-th day before the as-of date."""

    def __init__(self, w):
        self.w = w
        self.as_of = w.as_of

    def back(self, k: int) -> dt.date:
        return self.as_of - dt.timedelta(days=k)

    def au(self, view: str, **row) -> None:
        self.w.au(view, row)

    def ou(self, view: str, **row) -> None:
        self.w.ou(view, row)

    def show(self, view: str, **row) -> None:
        self.w.show(view, row)


# ---------------------------------------------------------------------------------------------------------------------------
# AI and Cortex
# ---------------------------------------------------------------------------------------------------------------------------
def ai(b: _B) -> None:
    n = 0

    def fn(back, hour, func, model, credits, user, role, qid=None, wh=1006, tag=None):
        nonlocal n
        n += 1
        b.au("CORTEX_AI_FUNCTIONS_USAGE_HISTORY",
             start_time=_ts(b.back(back), hour), end_time=_ts(b.back(back), hour + 1), function_name=func,
             model_name=model, query_id=qid or f"01ai-{n:06d}", warehouse_id=wh,
             role_names=[role] if role else None, query_tag=tag, user_id=user,
             metrics=[{"metric": "tokens", "value": 1000}], credits=credits, is_completed=True)

    # OK: small flat spend
    fn(5, 10, "COMPLETE", "llama3.1-70b", 1.0, "5003", "ANALYST_ROLE")
    fn(40, 10, "COMPLETE", "llama3.1-70b", 1.0, "5003", "ANALYST_ROLE")
    # WARN: new spend, no previous window
    for k in range(3, 15):
        fn(k, 11, "AI_CLASSIFY", "claude-3-5-sonnet", 1.0, "5004", "ANALYST_ROLE")
    # WARN: one query spread over three hourly rows, about 63 USD
    for h in (1, 2, 3):
        fn(8, h, "AI_COMPLETE", "openai-gpt-5", 7.0, "5008", "DEV_ROLE", qid="01ai-long-query", tag="nightly")
    for k in range(35, 41):
        fn(k, 5, "AI_COMPLETE", "openai-gpt-5", 20.0 / 6, "5008", "DEV_ROLE")
    # CRITICAL: 10 credits before, 40 now
    for k in range(3, 9):
        fn(k, 12, "AI_EXTRACT", "mistral-large2", 40 / 6, "5003", "ANALYST_ROLE")
    fn(45, 12, "AI_EXTRACT", "mistral-large2", 10.0, "5003", "ANALYST_ROLE")
    # a user with no USERS row, and a row with no role
    fn(6, 9, "AI_SENTIMENT", "snowflake-arctic", 2.0, "9999", None)
    # document parsing: left out of the AI-functions feature so pages are not counted twice
    fn(7, 9, "AI_PARSE_DOCUMENT", "document-ai", 5.0, "5004", "ANALYST_ROLE")

    # REST API usage, one row a day for the reserved model on the PTU-paid days
    for k in range(1, 11):
        b.au("CORTEX_REST_API_USAGE_HISTORY", start_time=_ts(b.back(k), 9), end_time=_ts(b.back(k), 10),
             request_id=f"rest-{k}", model_name="Claude-3-5-Sonnet", tokens=50000,
             tokens_granular={"input": 40000, "output": 10000}, user_id="5004", inference_region="us-east-1")

    # provisioned throughput: used on every paid day, idle on 4 of 10, idle on 9 of 10
    for pid, model, idle_from in (("PT-1", "claude-3-5-sonnet", None), ("PT-2", "mistral-large2", 7),
                                  ("PT-3", "llama3.1-70b", 2)):
        for k in range(1, 11):
            b.au("CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY",
                 provisioned_throughput_id=pid, interval_start_time=_ts(b.back(k), 0),
                 interval_end_time=_ts(b.back(k), 1), cloud_service_provider="AWS", model_name=model,
                 term_start_date=b.back(60), term_end_date=b.back(-30), ptu_count=25, ptu_credits=5.0)

    # agents
    r = 0

    def agent(back, agent_id, name, user_id, user, credits):
        nonlocal r
        r += 1
        b.au("CORTEX_AGENT_USAGE_HISTORY",
             start_time=_ts(b.back(back), 13), end_time=_ts(b.back(back), 14), user_id=user_id, user_name=user,
             request_id=f"req-{r:05d}", agent_database_id=102, agent_database_name="ANALYTICS_DB",
             agent_schema_id=205, agent_schema_name="MARTS", agent_id=agent_id, agent_name=name,
             token_credits=credits, tokens=int(credits * 100000),
             metadata={"role_id": 6001, "role_name": "ANALYST_ROLE", "interaction_interface": "SNOWSIGHT",
                       "ai_functions_credits": credits * 0.1, "sql_query_credits": credits * 0.2,
                       "sql_query_warehouses": ["WH_BI"], "inference_region": "us-east-1"})

    for k in (4, 20):
        agent(k, 7001, "REPORT_AGENT", 5004, "ANALYST_DAN", 1.0)
        agent(k + 35, 7001, "REPORT_AGENT", 5004, "ANALYST_DAN", 1.0)
    for k in range(3, 18):
        agent(k, 7002, "SALES_AGENT", 5003, "ANALYST_CARA", 1.0)
    for k in range(3, 9):
        agent(k, 7003, "SUPPORT_AGENT", 5008, "DEV_HUGO", 5.0)
    agent(40, 7003, "SUPPORT_AGENT", 5008, "DEV_HUGO", 8.0)

    # document processing and fine-tuning: small
    b.au("CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY", query_id="01doc-1", credits_used=3.0,
         start_time=_ts(b.back(9), 9), end_time=_ts(b.back(9), 10), function_name="AI_PARSE_DOCUMENT",
         model_name="document-ai", operation_name="inference", page_count=300, document_count=12,
         feature_count=1)
    b.au("CORTEX_FINE_TUNING_USAGE_HISTORY", start_time=_ts(b.back(12), 9), end_time=_ts(b.back(12), 10),
         model_name="llama3.1-8b", token_credits=0.5, tokens=250000)

    # Cortex Code: CLI users, Snowsight users, and billed totals (CLI ties out, Snowsight does not)
    def code(view, back, uid, user, credits):
        b.au(view, user_id=uid, user_name=user, request_id=f"code-{view[-5:]}-{uid}-{back}",
             usage_time=_ts(b.back(back), 15), token_credits=credits, tokens=int(credits * 90000),
             metadata={"model_name": "claude-sonnet"})

    for k in range(3, 18):
        code("CORTEX_CODE_CLI_USAGE_HISTORY", k, 5003, "ANALYST_CARA", 1.0)
    for k in range(3, 9):
        code("CORTEX_CODE_CLI_USAGE_HISTORY", k, 5008, "DEV_HUGO", 5.0)
    for k in (40, 41):
        code("CORTEX_CODE_CLI_USAGE_HISTORY", k, 5008, "DEV_HUGO", 5.0)
    for k in range(3, 7):
        code("CORTEX_CODE_CLI_USAGE_HISTORY", k, 5004, "ANALYST_DAN", 1.0)
        code("CORTEX_CODE_CLI_USAGE_HISTORY", k + 35, 5004, "ANALYST_DAN", 1.0)
    for k in range(3, 6):
        code("CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY", k, 5004, "ANALYST_DAN", 1.0)
        code("CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY", k + 35, 5004, "ANALYST_DAN", 1.0)
    for k in range(3, 13):
        code("CORTEX_CODE_DESKTOP_USAGE_HISTORY", k, 5008, "DEV_HUGO", 4.0)

    # CoWork: a steady user (OK), a new heavy user (WARN) and one that tripled (CRITICAL)
    def cowork(back, uid, user, credits, cid=8801, cname="COWORK_FINANCE"):
        b.au("SNOWFLAKE_COWORK_USAGE_HISTORY", start_time=_ts(b.back(back), 14), end_time=_ts(b.back(back), 14),
             user_id=uid, user_name=user, request_id=f"cw-{uid}-{back}", snowflake_cowork_id=cid,
             snowflake_cowork_name=cname, agent_id=8811, agent_name="FIN_AGENT", agent_database_name="AI_DB",
             agent_schema_name="AGENTS", token_credits=credits, tokens=int(credits * 80000))

    for k in list(range(3, 13)) + list(range(33, 43)):
        cowork(k, 5003, "ANALYST_CARA", 1.0)
    for k in range(3, 13):
        cowork(k, 5008, "DEV_HUGO", 6.0)
    for k in range(3, 13):
        cowork(k, 5004, "ANALYST_DAN", 3.0, 8802, "COWORK_OPS")
    for k in range(33, 38):
        cowork(k, 5004, "ANALYST_DAN", 2.0, 8802, "COWORK_OPS")

    days = list(range(3, 32))
    for service, total in (("CORTEX_CODE_CLI", 49.0), ("CORTEX_CODE_SNOWSIGHT", 100.0)):
        for k in days:
            v = total / len(days)
            b.au("METERING_DAILY_HISTORY", service_type=service, usage_date=b.back(k), credits_used_compute=v,
                 credits_used_cloud_services=0.0, credits_used=v, credits_adjustment_cloud_services=0.0,
                 credits_billed=v)


# ---------------------------------------------------------------------------------------------------------------------------
# Native apps and organization billing
# ---------------------------------------------------------------------------------------------------------------------------
def billing(b: _B) -> None:
    apps = [  # id, name, cur per day, prev per day, breakdown, storage
        (8801, "DATA_APP_A", 0.2, 0.2, True, 5e11),
        (8802, "DATA_APP_B", 0.6, 0.0, True, None),
        (8803, "DATA_APP_C", 1.2, 0.3, True, None),
        (8804, "DATA_APP_D", 0.1, 0.1, False, None),
    ]
    for app_id, name, cur, prev, breakdown, storage in apps:
        for k in range(1, 61):
            v = cur if k <= 30 else prev
            if v == 0:
                continue
            bd = ([{"credits": v * 0.7, "serviceType": "SERVERLESS_TASK"},
                   {"credits": v * 0.3, "serviceType": "WAREHOUSE_METERING"}] if breakdown else None)
            b.au("APPLICATION_DAILY_USAGE_HISTORY", application_name=name, application_id=app_id,
                 listing_global_name=f"GZ{app_id}", usage_date=b.back(k), credits_used=v,
                 credits_used_breakdown=bd, storage_bytes=storage,
                 storage_bytes_breakdown=[{"bytes": storage, "storageType": "DATABASE"}] if storage else None)

    # overage and adjustments: rows the older data does not have (it is all capacity)
    def uic(loc, name, service, back, usage, amount, source="overage", adj=False, contract=4001):
        b.ou("USAGE_IN_CURRENCY_DAILY", organization_name="FAKE_ORG", contract_number=contract,
             account_name=name, account_locator=loc, region="AWS_US_EAST_1", service_level="ENTERPRISE",
             usage_date=b.back(back), usage_type="compute", usage=usage, currency="USD", usage_in_currency=amount,
             balance_source=source, billing_type="consumption", rating_type="compute", service_type=service,
             is_adjustment=adj)

    for k in range(4, 11):                                   # CRITICAL: overage on every recent day
        uic("FAKE01", "FAKE_ACCOUNT", "AI_SERVICES", k, 40, 120.0)
    uic("FAKE02", "FAKE_DEV", "PIPE", 15, 50, 150.0)         # WARN: 150 over the threshold
    uic("FAKE01", "FAKE_ACCOUNT", "REPLICATION", 20, 40, 120.0, source="capacity", adj=True)   # WARN: adjustments
    uic("FAKE01", "FAKE_ACCOUNT", "SEARCH_OPTIMIZATION", 12, -20.0 / 3, -20.0, source="rebate")

    # cloud services billed by account: three accounts with no ACCOUNTS row of their own
    for loc, name, compute, cs, adj, rate in (("FAKE05", "FAKE_NORATE", 100.0, 20.0, -10.0, None),
                                              ("FAKE06", "FAKE_BIGCS", 500.0, 100.0, -50.0, 3.0),
                                              ("FAKE07", "FAKE_SMALLCS", 250.0, 30.0, -25.0, 3.0)):
        for k in range(3, 33):
            b.ou("METERING_DAILY_HISTORY", organization_name="FAKE_ORG", account_name=name, account_locator=loc,
                 region="AWS_US_EAST_1", service_type="WAREHOUSE_METERING", usage_date=b.back(k),
                 credits_used_compute=compute, credits_used_cloud_services=cs, credits_used=compute + cs,
                 credits_adjustment_cloud_services=adj, credits_billed=compute + cs + adj)
            if rate:
                b.ou("USAGE_IN_CURRENCY_DAILY", organization_name="FAKE_ORG", contract_number=4001,
                     account_name=name, account_locator=loc, region="AWS_US_EAST_1", service_level="ENTERPRISE",
                     usage_date=b.back(k), usage_type="compute", usage=compute, currency="USD",
                     usage_in_currency=compute * rate, balance_source="capacity", billing_type="consumption",
                     rating_type="compute", service_type="WAREHOUSE_METERING", is_adjustment=False)


# ---------------------------------------------------------------------------------------------------------------------------
# Performance
# ---------------------------------------------------------------------------------------------------------------------------
def performance(b: _B) -> None:
    n = 0

    def attr(query_id, wh_id, wh_name, qhash, credits, back, root=None):
        b.au("QUERY_ATTRIBUTION_HISTORY", query_id=query_id, parent_query_id=None, root_query_id=root,
             warehouse_id=wh_id, warehouse_name=wh_name, query_hash=qhash, query_parameterized_hash=qhash,
             query_tag=None, user_name="ANALYST_DAN", start_time=_ts(b.back(back), 10),
             end_time=_ts(b.back(back), 11), credits_attributed_compute=credits,
             credits_used_query_acceleration=None)

    # query insights: OK / WARN / CRITICAL by attributed dollars, one with no attribution, one not an opportunity
    for i, (wh, credits, itype) in enumerate((("A", 2.0, "QUERY_INSIGHT_SPILL"),
                                              ("B", 30.0, "QUERY_INSIGHT_ROW_EXPLOSION"),
                                              ("C", 100.0, "QUERY_INSIGHT_NO_FILTER"))):
        wid, name = 1301 + i, f"WH_INS_{wh}"
        for k in range(3, 6):
            qid = f"01ins-{wh}-{k}"
            n += 1
            b.au("QUERY_INSIGHTS", start_time=_ts(b.back(k), 10), end_time=_ts(b.back(k), 11),
                 total_elapsed_time=600000, query_id=qid, query_hash=f"hins{wh}",
                 query_parameterized_hash=f"hins{wh}", warehouse_id=str(wid), warehouse_name=name,
                 insight_instance_id=n, insight_type_id=itype, message=["a message"], suggestions=["a suggestion"],
                 is_opportunity=True, insight_topic="performance")
            attr(qid, wid, name, f"hins{wh}", credits / 3, k)
    b.au("QUERY_INSIGHTS", start_time=_ts(b.back(4), 10), end_time=_ts(b.back(4), 11), total_elapsed_time=1000,
         query_id="01ins-none", query_hash="hnone", query_parameterized_hash="hnone", warehouse_id="1304",
         warehouse_name="WH_INS_D", insight_instance_id=90, insight_type_id="QUERY_INSIGHT_SPILL",
         message=["m"], suggestions=["s"], is_opportunity=True, insight_topic="performance")
    b.au("QUERY_INSIGHTS", start_time=_ts(b.back(4), 10), end_time=_ts(b.back(4), 11), total_elapsed_time=1000,
         query_id="01ins-A-3", query_hash="hinsA", query_parameterized_hash="hinsA", warehouse_id="1301",
         warehouse_name="WH_INS_A", insight_instance_id=91, insight_type_id="QUERY_INSIGHT_REMOTE_SPILL",
         message=["m"], suggestions=["s"], is_opportunity=True, insight_topic="performance")   # two types, one query
    b.au("QUERY_INSIGHTS", start_time=_ts(b.back(4), 10), end_time=_ts(b.back(4), 11), total_elapsed_time=1000,
         query_id="01ins-B-3", query_hash="hinsB", query_parameterized_hash="hinsB", warehouse_id="1302",
         warehouse_name="WH_INS_B", insight_instance_id=92, insight_type_id="QUERY_INSIGHT_INFO",
         message=["m"], suggestions=["s"], is_opportunity=False, insight_topic="performance")

    # table scan selectivity: (table, db, schema, name, warehouse, hash, queries, rows scanned, matched %, exec ms, credits)
    G = 1_000_000_000
    scans = [
        (5007, "ANALYTICS_DB", "CORE", "ORDERS", 1401, "WH_SCAN_A", "hscanA", 40, G // 5, 50.0, 3_600_000, 5.0),
        (5008, "ANALYTICS_DB", "CORE", "CUSTOMERS", 1401, "WH_SCAN_A", "hscanB", 40, 1_000_000, 0.5, 60_000, 1.0),
        (5001, "RAW_DB", "LANDING", "ORDERS_RAW", 1402, "WH_SCAN_B", "hscanC", 40, G // 2, 0.5, 7_200_000, 5.0),
        (5003, "RAW_DB", "LANDING", "EVENTS_RAW", 1403, "WH_SCAN_C", "hscanD", 40, G, 0.01, 10_800_000, 30.0),
        (5010, "ANALYTICS_DB", "CORE", "ORDERS_CLONE", 1404, "WH_SCAN_D", "hscanE", 40, 0, 0.0, 1_000, 1.0),
        (5001, "RAW_DB", "LANDING", "ORDERS_RAW", 1405, "WH_SCAN_E", "hscanF", 40, G // 2, 0.5, 3_600_000, 4.0),
        (5010, "ANALYTICS_DB", "CORE", "ORDERS_CLONE", 1405, "WH_SCAN_E", "hscanF", 40, G // 2, 0.5, 3_600_000, 0.0),
    ]
    for tid, db, sch, tname, wid, wname, qh, queries, scanned, matched_pct, exec_ms, credits in scans:
        b.au("TABLE_QUERY_PRUNING_HISTORY", interval_start_time=_ts(b.back(6), 10),
             interval_end_time=_ts(b.back(6), 11), table_id=tid, table_name=tname, schema_id=205, schema_name=sch,
             database_id=102, database_name=db, warehouse_id=wid, warehouse_name=wname, query_hash=qh,
             query_parameterized_hash=qh, num_queries=queries, aggregate_query_elapsed_time=exec_ms + 1000,
             aggregate_query_compilation_time=1000, aggregate_query_execution_time=exec_ms,
             partitions_scanned=1000, partitions_pruned=9000, rows_scanned=scanned, rows_pruned=0,
             rows_matched=int(scanned * matched_pct / 100))
        if credits:
            attr(f"01scan-{qh}-{tid}", wid, wname, qh, credits, 6)

    # clustering: column and table pruning, over the 90 days so every window has rows
    def prune(tid, db, sch, tname, col, access, back, queries, exec_ms, scanned, pruned, rows, matched, sos=None):
        common = dict(interval_start_time=_ts(b.back(back), 9), interval_end_time=_ts(b.back(back), 10),
                      table_id=tid, table_name=tname, schema_id=205, schema_name=sch, database_id=102,
                      database_name=db, warehouse_id=1006, warehouse_name="WH_ML", query_hash=f"hcl{tid}",
                      query_parameterized_hash=f"hcl{tid}", num_queries=queries,
                      aggregate_query_elapsed_time=exec_ms, aggregate_query_compilation_time=0,
                      aggregate_query_execution_time=exec_ms, partitions_scanned=scanned, partitions_pruned=pruned,
                      rows_scanned=rows, rows_pruned=rows - matched, rows_matched=matched)
        if col:
            b.au("COLUMN_QUERY_PRUNING_HISTORY", column_id=1, column_name=col, variant_path=None,
                 access_type=access, search_optimization_supported_expressions=sos, **common)
        else:
            b.au("TABLE_QUERY_PRUNING_HISTORY", **common)

    for back in (3, 10, 17, 24, 40, 55, 70, 85):
        # key mismatch: the clustered table filters on a column outside its key, or inside it
        prune(5007, "ANALYTICS_DB", "CORE", "ORDERS", "ORDER_DATE", "WHERE", back, 20, 800_000, 100, 900, 10_000, 5_000)
        prune(5007, "ANALYTICS_DB", "CORE", "ORDERS", None, None, back, 20, 1_000_000, 100, 900, 10_000, 5_000)
        prune(5003, "RAW_DB", "LANDING", "EVENTS_RAW", "DEVICE_ID", "WHERE", back, 20, 20_000_000, 100, 900, 10_000, 5_000)
        prune(5003, "RAW_DB", "LANDING", "EVENTS_RAW", "EVENT_DATE", "WHERE", back, 20, 1_000_000, 100, 900, 10_000, 5_000)
        prune(5003, "RAW_DB", "LANDING", "EVENTS_RAW", None, None, back, 20, 25_000_000, 100, 900, 10_000, 5_000)
    for back in (3, 10, 17, 24):
        # candidates: a big unclustered table whose filters scan most partitions, a lookup table, a small user
        prune(5001, "RAW_DB", "LANDING", "ORDERS_RAW", "CUSTOMER_ID", "WHERE", back, 20, 5_400_000, 900, 100,
              100_000_000, 50_000_000)
        prune(5010, "ANALYTICS_DB", "CORE", "ORDERS_CLONE", "DEVICE_ID", "WHERE", back, 20, 54_000_000, 900, 100,
              100_000_000, 1_000_000, sos=['EQUALITY("DEVICE_ID")'])
        prune(5020, "ANALYTICS_DB", "PUBLIC", "T_UNUSED_1", "ORDER_ID", "WHERE", back, 20, 1_800_000, 900, 100,
              100_000_000, 50_000_000)

    # search optimization: a costly index with no benefit, and a useful one
    for back in (3, 8, 13, 18, 23):
        b.au("SEARCH_OPTIMIZATION_HISTORY", start_time=_ts(b.back(back), 4), end_time=_ts(b.back(back), 5),
             credits_used=20.0, index_id=1, index_name="SO_EVENTS", index_type="Search Optimization Index",
             base_table_id=5003, base_table_name="EVENTS_RAW", schema_id=205, schema_name="LANDING",
             database_id=101, database_name="RAW_DB")
        b.au("SEARCH_OPTIMIZATION_HISTORY", start_time=_ts(b.back(back), 4), end_time=_ts(b.back(back), 5),
             credits_used=4.0, index_id=2, index_name="SO_ORDERS", index_type="Search Optimization Index",
             base_table_id=5007, base_table_name="ORDERS", schema_id=205, schema_name="CORE",
             database_id=102, database_name="ANALYTICS_DB")
        b.au("SEARCH_OPTIMIZATION_HISTORY", start_time=_ts(b.back(back), 4), end_time=_ts(b.back(back), 5),
             credits_used=50.0, index_id=3, index_name="SO_SECONDARY", index_type="Secondary Index",
             base_table_id=5001, base_table_name="ORDERS_RAW", schema_id=205, schema_name="LANDING",
             database_id=101, database_name="RAW_DB")
    b.au("SEARCH_OPTIMIZATION_BENEFITS", start_time=_ts(b.back(5), 4), end_time=_ts(b.back(5), 5), table_id=5007,
         table_name="ORDERS", schema_id=205, schema_name="CORE", database_id=102, database_name="ANALYTICS_DB",
         num_scans=5000, partitions_scanned=100, partitions_pruned_default=10, partitions_pruned_additional=900)

    # pruning regression: 8 blocks of 7 days, 20000 partitions a day
    def tpr(tid, tname, db, sch, back, ratio, total=20000):
        b.au("TABLE_PRUNING_HISTORY", start_time=_ts(b.back(back), 12), end_time=_ts(b.back(back), 13),
             table_id=tid, table_name=tname, schema_id=205, schema_name=sch, database_id=102, database_name=db,
             num_scans=200, partitions_scanned=int(total * (1 - ratio)), partitions_pruned=int(total * ratio),
             rows_scanned=10_000_000, rows_pruned=8_000_000)

    for back in range(1, 57):
        blk = (back - 1) // 7
        tpr(5007, "ORDERS", "ANALYTICS_DB", "CORE", back, 0.8)
        tpr(5001, "ORDERS_RAW", "RAW_DB", "LANDING", back, 0.6 if blk == 0 else 0.8)
        tpr(5003, "EVENTS_RAW", "RAW_DB", "LANDING", back, 0.4 if blk == 0 else 0.8)
        if blk <= 2:
            tpr(5008, "CUSTOMERS", "ANALYTICS_DB", "CORE", back, 0.8)
        tpr(5010, "ORDERS_CLONE", "ANALYTICS_DB", "CORE", back, 0.8, total=20000 if blk else 100)

    # tail latency: 14000 calls in 7 days per shape
    def agg(wid, wname, qh, per_day, p99, avg, queued_share, throttled, errors=None):
        for back in range(1, 8):
            elapsed = per_day * avg
            b.au("AGGREGATE_QUERY_HISTORY", calls=per_day, interval_start_time=_ts(b.back(back), 10),
                 interval_end_time=_ts(b.back(back), 11), query_parameterized_hash=qh, database_id=102,
                 database_name="ANALYTICS_DB", schema_id=205, schema_name="MARTS", query_type="SELECT",
                 warehouse_id=wid, warehouse_name=wname, warehouse_size="X-Small", warehouse_type="STANDARD",
                 is_client_generated_statement=False, errors=errors,
                 total_elapsed_time={"sum": elapsed, "avg": avg, "p99": p99},
                 queued_overload_time={"sum": elapsed * queued_share},
                 credits_used_cloud_services={"sum": 0.01},
                 hybrid_table_requests_throttled_count=throttled)

    agg(1501, "WH_HF_A", "hhfA", 2000, 800, 200, 0.0, 0)
    agg(1502, "WH_HF_B", "hhfB", 2000, 6000, 300, 0.0, 0, errors=[{"code": "1", "message": "x", "count": 3}])
    agg(1503, "WH_HF_C", "hhfC", 2000, 40000, 500, 0.0, 0)
    agg(1504, "WH_HF_D", "hhfD", 2000, 900, 200, 0.4, 0)
    agg(1505, "WH_HF_E", "hhfE", 2000, 900, 200, 0.0, 20)

    # retries: memory retries on the ETL warehouse and other retries on BI (the older rows, with retry time set)
    for r in b.w.rows.get(("account_usage", "QUERY_HISTORY"), []):
        if r.get("start_time") is None or r["start_time"].date() < b.back(30) or r["start_time"].date() >= b.as_of:
            continue
        if r.get("warehouse_id") == 1001:
            r["query_retry_time"] = int((r.get("execution_time") or 0) * 0.25)
            r["query_retry_cause"] = "Out of memory"
        elif r.get("warehouse_id") == 1002:
            r["query_retry_time"] = int((r.get("execution_time") or 0) * 0.08)
            r["query_retry_cause"] = "Node failure"

    # resize: consistency events (size) and one resize by a named user
    def size_ev(wid, wname, back, size):
        b.au("WAREHOUSE_EVENTS_HISTORY", timestamp=_ts(b.back(back), 0, 5), warehouse_id=wid, warehouse_name=wname,
             cluster_number=1, event_name="WAREHOUSE_CONSISTENT", event_state="COMPLETED", size=size,
             cluster_count="1", warehouse_type="STANDARD")

    def resize(wid, wname, back, size):
        b.au("WAREHOUSE_EVENTS_HISTORY", timestamp=_ts(b.back(back), 0, 1), warehouse_id=wid, warehouse_name=wname,
             cluster_number=1, event_name="RESIZE_WAREHOUSE", event_state="COMPLETED", user_name="ADMIN_BOB",
             role_name="ACCOUNTADMIN", size=size, cluster_count="1", warehouse_type="STANDARD")

    for back in (89, 70, 50):
        size_ev(1001, "WH_ETL", back, "X-Small")
    for back in (20, 10, 2):
        size_ev(1001, "WH_ETL", back, "Large")
    resize(1001, "WH_ETL", 20, "Large")
    for back in (89, 60, 30):
        size_ev(1002, "WH_BI", back, "Medium")
    for back in (89, 60, 40):
        size_ev(1003, "WH_ADHOC", back, "X-Small")
    for back in (8, 4, 1):
        size_ev(1003, "WH_ADHOC", back, "Small")
    resize(1003, "WH_ADHOC", 8, "Small")
    for back in (89, 60):
        size_ev(1006, "WH_ML", back, "Large")
    for back in (30, 5):
        size_ev(1006, "WH_ML", back, "Medium")
    for back in (89, 60, 30):
        size_ev(1005, "WH_ADAPTIVE", back, "Small")
    for back in (3, 1):
        size_ev(1005, "WH_ADAPTIVE", back, "Medium")


# ---------------------------------------------------------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------------------------------------------------------
def security(b: _B) -> None:
    # personal access tokens: OK, WARN (long-lived, never used), CRITICAL (admin, no role limit, may skip network policy)
    def pat(cid, name, user, created_back, life_days, used_back, details):
        created = _ts(b.back(created_back), 9)
        b.au("CREDENTIALS", credential_id=cid, name=name, user_name=user, type="PROGRAMMATIC_ACCESS_TOKEN",
             domain="PROGRAMMATIC_ACCESS_TOKEN", status="ACTIVE", additional_details=details, created_by=user,
             last_altered_by=user, created_on=created, last_used_on=_ts(b.back(used_back), 8) if used_back else None,
             last_altered=created, expiration_date=created + dt.timedelta(days=life_days))

    pat(7001, "PAT_HUGO_OK", "DEV_HUGO", 10, 30, 1, {"ROLE_RESTRICTION": "DEV_ROLE"})
    pat(7002, "PAT_CARA_LONG", "ANALYST_CARA", 200, 300, 2, {"ROLE_RESTRICTION": "ANALYST_ROLE"})
    pat(7003, "PAT_DAN_UNUSED", "ANALYST_DAN", 60, 80, None, {"ROLE_RESTRICTION": "ANALYST_ROLE"})
    pat(7004, "PAT_BOB_ADMIN", "ADMIN_BOB", 20, 60, 1,
        {"MINS_TO_BYPASS_NETWORK_POLICY_REQUIREMENT": 60})
    for cid, user in ((7001, "DEV_HUGO"), (7004, "ADMIN_BOB")):
        for k in (2, 3):
            b.au("LOGIN_HISTORY", event_id=9_000_000 + cid * 10 + k, event_timestamp=_ts(b.back(k), 8),
                 event_type="LOGIN", user_name=user, client_ip="198.51.100.7", reported_client_type="PYTHON_DRIVER",
                 first_authentication_factor="PROGRAMMATIC_ACCESS_TOKEN", is_success="YES",
                 first_authentication_factor_id=str(cid))

    # network rules: any-IP allowed by a policy (CRITICAL), wide range and wildcard egress (WARN), plain ones (OK)
    rules = [(9101, "RULE_OFFICE", "INGRESS", "IPV4", '["10.1.2.3/32"]'),
             (9102, "RULE_INTERNAL", "INGRESS", "IPV4", '["10.0.0.0/8"]'),
             (9103, "RULE_EGRESS_WILD", "EGRESS", "HOST_PORT", '["*.example.com:443"]'),
             (9104, "RULE_ANY", "INGRESS", "IPV4", '["0.0.0.0/0"]'),
             (9105, "RULE_ANY_UNUSED", "INGRESS", "IPV4", '["0.0.0.0/0"]')]
    for rid, name, mode, typ, values in rules:
        b.au("NETWORK_RULES", id=rid, name=name, schema_id=205, schema="NETWORK", database_id=102,
             database="ANALYTICS_DB", owner="SECURITYADMIN", owner_role_type="ROLE", created=_ts(b.back(300), 9),
             last_altered=_ts(b.back(30), 9), mode=mode, type=typ, value_list=values)
    for rid, name, mode, typ, ctype, cname, action in (
            (9101, "RULE_OFFICE", "INGRESS", "IPV4", "NETWORK_POLICY", "NP_CORP", "ALLOW"),
            (9102, "RULE_INTERNAL", "INGRESS", "IPV4", "NETWORK_POLICY", "NP_CORP", "ALLOW"),
            (9103, "RULE_EGRESS_WILD", "EGRESS", "HOST_PORT", "INTEGRATION", "EXT_INT", "ALLOW"),
            (9104, "RULE_ANY", "INGRESS", "IPV4", "NETWORK_POLICY", "NP_OPEN", "ALLOW")):
        b.au("NETWORK_RULE_REFERENCES", network_rule_db="ANALYTICS_DB", network_rule_schema="NETWORK",
             network_rule_id=rid, network_rule_name=name, network_rule_mode=mode, network_rule_type=typ,
             container_id=rid + 100, container_name=cname, container_type=ctype, action_type=action)

    # authentication policies (SHOW output): strict, permissive, long PAT expiry, options not readable
    strict = ('{"MFA_ENROLLMENT":"REQUIRED","AUTHENTICATION_METHODS":["SAML"],'
              '"PAT_POLICY":{"MAX_EXPIRY_IN_DAYS":30,"NETWORK_POLICY_EVALUATION":"ENFORCED_REQUIRED"}}')
    longpat = strict.replace('"MAX_EXPIRY_IN_DAYS":30', '"MAX_EXPIRY_IN_DAYS":365')
    for name, options in (("AP_STRICT", strict), ("AP_OPEN", "MFA_ENROLLMENT=OPTIONAL, AUTHENTICATION_METHODS=(ALL)"),
                          ("AP_LONG_PAT", longpat), ("AP_HIDDEN", None)):
        b.show("authentication_policies", created_on=_ts(b.back(200), 9), name=name, database_name="ANALYTICS_DB",
               schema_name="NETWORK", kind="AUTHENTICATION_POLICY", owner="SECURITYADMIN", comment=None,
               owner_role_type="ROLE", options=options, set_on="ACCOUNT" if name == "AP_STRICT" else None)

    # external access: callers by user, role and host list
    def call(qid, user, role, back, host, status, sent, ip="203.0.113.10"):
        b.w.au("QUERY_HISTORY", dict(
            query_id=qid, query_type="SELECT", user_name=user, role_name=role, execution_status="SUCCESS",
            start_time=_ts(b.back(back), 9), end_time=_ts(b.back(back), 9, 1), total_elapsed_time=60000,
            execution_time=60000))
        b.au("EXTERNAL_ACCESS_HISTORY", query_id=qid, hostnames=host, status=status, ip=ip, source_cloud="AWS",
             source_region="us-east-1", target_cloud="AWS", target_region="us-west-2", sent_bytes=sent,
             received_bytes=1000)

    call("01ea-ok", "ANALYST_DAN", "ANALYST_ROLE", 5, "api.example.com", "Success", 1_000_000)
    call("01ea-deny", "ANALYST_CARA", "ANALYST_ROLE", 6, "blocked.example.com", "Deny", 0)
    call("01ea-sent-warn", "DEV_HUGO", "DEV_ROLE", 7, "upload.example.com", "Success", 150_000_000)
    call("01ea-sent-crit", "SVC_ETL", "ETL_ROLE", 8, "bulk.example.com", "Success", 20_000_000_000)
    for i in range(22):
        call(f"01ea-many-{i}", "SVC_BI", "BI_ROLE", 9, "deny.example.com", "Deny", 0, ip=f"203.0.113.{20 + i}")
    b.au("EXTERNAL_ACCESS_HISTORY", query_id="01ea-gone", hostnames="old.example.com", status="Success",
         ip="203.0.113.99", sent_bytes=10, received_bytes=10)
    b.au("DATA_TRANSFER_HISTORY", start_time=_ts(b.back(8), 0), end_time=_ts(b.back(8), 1), source_cloud="AWS",
         source_region="AWS_US_EAST_1", target_cloud="AWS", target_region="AWS_US_WEST_2",
         bytes_transferred=20_000_000_000, transfer_type="EXTERNAL_ACCESS")

    # lineage of sensitive columns: tagged source to untagged target (WARN), masked source (CRITICAL), tagged target (OK)
    def tag(table, col, category):
        b.au("TAG_REFERENCES", tag_database="SNOWFLAKE", tag_schema="CORE", tag_id=1, tag_name="SEMANTIC_CATEGORY",
             tag_value=category, object_database="ANALYTICS_DB", object_schema="LINEAGE", object_id=1,
             object_name=table, object_deleted=None, domain="COLUMN", column_id=1, column_name=col,
             apply_method="MANUAL")

    tag("SRC_TAGGED", "EMAIL", "EMAIL")
    tag("SRC_MASKED", "SSN", "US_SSN")
    tag("TGT_TAGGED", "EMAIL", "EMAIL")
    b.au("POLICY_REFERENCES", policy_db="ANALYTICS_DB", policy_schema="PUBLIC", policy_id=9301,
         policy_name="MASK_SSN", policy_kind="MASKING_POLICY", ref_database_name="ANALYTICS_DB",
         ref_schema_name="LINEAGE", ref_entity_name="SRC_MASKED", ref_entity_domain="TABLE", ref_column_name="SSN",
         policy_status="ACTIVE")

    def lineage(qid, target, tcol, source, scol, back):
        b.au("ACCESS_HISTORY", query_id=qid, query_start_time=_ts(b.back(back), 11), user_name="SVC_ETL",
             direct_objects_accessed=[], base_objects_accessed=[],
             objects_modified=[{"objectName": f"ANALYTICS_DB.LINEAGE.{target}", "objectDomain": "Table",
                                "columns": [{"columnName": tcol, "baseSources": [
                                    {"objectName": f"ANALYTICS_DB.LINEAGE.{source}", "columnName": scol}]}]}])

    lineage("01lin-warn", "TGT_UNTAGGED", "EMAIL", "SRC_TAGGED", "EMAIL", 3)
    lineage("01lin-crit", "TGT_UNMASKED", "SSN", "SRC_MASKED", "SSN", 4)
    lineage("01lin-ok", "TGT_TAGGED", "EMAIL", "SRC_TAGGED", "EMAIL", 5)

    # user state: a locked user, an expired but enabled user, an admin with MFA bypassed
    for r in b.w.rows.get(("account_usage", "USERS"), []):
        if r["name"] == "DEV_HUGO":
            r["locked_until_time"] = _ts(b.back(-2))
        elif r["name"] == "ANALYST_FRANK":
            r["expires_at"] = _ts(b.back(10))
        elif r["name"] == "ADMIN_BOB":
            r["bypass_mfa_until"] = _ts(b.back(-3))


# ---------------------------------------------------------------------------------------------------------------------------
# Loading, dynamic tables, Iceberg
# ---------------------------------------------------------------------------------------------------------------------------
def loading(b: _B) -> None:
    # Snowpipe latency: p95 of 40 s, 10 min, 1 h, 25 files each
    for pipe, lag in (("PIPE_FAST", 40), ("PIPE_SLOW", 600), ("PIPE_STALLED", 3600)):
        b.au("PIPES", pipe_id=9401 + len(pipe), pipe_name=pipe, pipe_schema_id=205, pipe_schema="LANDING",
             pipe_catalog_id=101, pipe_catalog="RAW_DB", is_autoingest_enabled="YES", pipe_owner="ETL_ROLE",
             created=_ts(b.back(200), 9))
        if pipe == "PIPE_SLOW":       # a deleted twin of the same name
            b.au("PIPES", pipe_id=9499, pipe_name=pipe, pipe_schema_id=205, pipe_schema="LANDING",
                 pipe_catalog_id=101, pipe_catalog="RAW_DB", is_autoingest_enabled="YES", pipe_owner="ETL_ROLE",
                 created=_ts(b.back(300), 9), deleted=_ts(b.back(210), 9))
        for k in range(2, 27):
            received = _ts(b.back(k), 6)
            b.au("COPY_HISTORY", file_name=f"{pipe.lower()}/{k}.json", stage_location="@RAW_DB.LANDING.S3_LANDING",
                 last_load_time=received + dt.timedelta(seconds=lag + 5), row_count=1000, row_parsed=1000,
                 file_size=2 * 1024 * 1024, error_count=0, status="Loaded", table_id=5001, table_name="ORDERS_RAW",
                 table_schema_id=205, table_schema_name="LANDING", table_catalog_id=101,
                 table_catalog_name="RAW_DB", pipe_catalog_name="RAW_DB", pipe_schema_name="LANDING",
                 pipe_name=pipe, pipe_received_time=received, first_commit_time=received + dt.timedelta(seconds=lag))

    # streaming channels: two snapshots each, cumulative counters
    def channel(cid, name, errors, latency_ms, last_back_hours=2):
        for i, (parsed, err) in enumerate(((1000, 0), (11000, errors))):
            when = _ts(b.back(5), 12) if i == 0 else _ts(b.back(1), 24 - last_back_hours) - dt.timedelta(days=0)
            b.au("SNOWPIPE_STREAMING_CHANNEL_HISTORY", account_id=1, created_on=when, channel_id=cid,
                 channel_name=name, pipe_id=9501, pipe_name="EVENTS_PIPE", pipe_schema_id=205,
                 pipe_schema_name="LANDING", pipe_database_id=101, pipe_database_name="RAW_DB", end_offset=str(parsed),
                 table_id=5001, table_name="ORDERS_RAW", table_schema_id=205, table_schema_name="LANDING",
                 table_database_id=101, table_database_name="RAW_DB",
                 last_error_offset_upper_bound="5" if err else None,
                 last_error_message="parse error" if err else None, snowflake_processing_latency_ms=latency_ms,
                 rows_inserted=parsed - err, rows_parsed=parsed, row_error_count=err)

    channel(9601, "CH_OK", 0, 5_000)
    channel(9602, "CH_SLOW", 5, 90_000)
    channel(9603, "CH_ERRORS", 50, 5_000)
    channel(9604, "CH_BROKEN", 200, 5_000)
    for i, (parsed, err) in enumerate(((1000, 0), (11000, 0))):     # last snapshot four days ago
        b.au("SNOWPIPE_STREAMING_CHANNEL_HISTORY", account_id=1, created_on=_ts(b.back(6 - 2 * i), 12),
             channel_id=9605, channel_name="CH_QUIET", pipe_id=9501, pipe_name="EVENTS_PIPE", pipe_schema_id=205,
             pipe_schema_name="LANDING", pipe_database_id=101, pipe_database_name="RAW_DB", end_offset=str(parsed),
             table_id=5001, table_name="ORDERS_RAW", table_schema_id=205, table_schema_name="LANDING",
             table_database_id=101, table_database_name="RAW_DB", snowflake_processing_latency_ms=1000,
             rows_inserted=parsed, rows_parsed=parsed, row_error_count=err)

    # dynamic tables nobody reads: about 12 and 120 USD of refresh compute
    for tid, name, credits in ((5101, "DT_UNREAD_SMALL", 4.0), (5102, "DT_UNREAD_BIG", 40.0)):
        b.au("TABLES", table_id=tid, table_name=name, table_schema_id=205, table_schema="MARTS",
             table_catalog_id=102, table_catalog="ANALYTICS_DB", table_owner="DATA_ADMIN", table_type="BASE TABLE",
             is_transient="NO", row_count=1000, bytes=10 * 1024 ** 2, retention_time=1,
             created=_ts(b.back(100), 9), last_altered=_ts(b.back(1), 9), last_ddl=_ts(b.back(1), 9),
             last_ddl_by="DATA_ADMIN", is_iceberg="NO", is_dynamic="YES", is_hybrid="NO")
        for k in range(2, 12):
            qid = f"01dtu-{tid}-{k}"
            b.au("DYNAMIC_TABLE_REFRESH_HISTORY", name=name, schema_name="MARTS", database_name="ANALYTICS_DB", id=tid,
                 schema_id=205, database_id=102, qualified_name=f"ANALYTICS_DB.MARTS.{name}", state="SUCCEEDED",
                 query_id=qid, data_timestamp=_ts(b.back(k), 3), refresh_start_time=_ts(b.back(k), 3),
                 refresh_end_time=_ts(b.back(k), 3, 5), completion_target=_ts(b.back(k), 4),
                 statistics={"numInsertedRows": 10}, refresh_action="INCREMENTAL", refresh_trigger="SCHEDULED",
                 target_lag_sec=3600)
            b.au("QUERY_ATTRIBUTION_HISTORY", query_id=qid, root_query_id=None, warehouse_id=1601,
                 warehouse_name="WH_NC_DT", query_hash="hdt", query_parameterized_hash="hdt", user_name="SYSTEM",
                 start_time=_ts(b.back(k), 3), end_time=_ts(b.back(k), 3, 5),
                 credits_attributed_compute=credits / 10)

    # Iceberg compaction: a read table, a table with one read, a table nobody reads
    for tid, name, per_day, reads in ((5014, "ICE_EVENTS", 0.2, 0), (6001, "ICE_LOGS", 1.0, 1), (6002, "ICE_STAGE", 10.0, 0)):
        for k in range(2, 12):
            b.au("ICEBERG_STORAGE_OPTIMIZATION_HISTORY", start_time=_ts(b.back(k), 2), end_time=_ts(b.back(k), 3),
                 credits_used=per_day, num_bytes_scanned=10 * 1024 ** 3, num_rows_written=1_000_000, table_id=tid,
                 table_name=name, iceberg_table_uuid=f"uuid-{tid}", schema_id="205", schema_name="MARTS",
                 database_id=102, database_name="ANALYTICS_DB", instance_id=1)
        for i in range(reads):
            b.au("ACCESS_HISTORY", query_id=f"01ice-{tid}-{i}", query_start_time=_ts(b.back(4), 10),
                 user_name="ANALYST_DAN", direct_objects_accessed=[{"objectId": tid, "objectName": name,
                                                                    "objectDomain": "Table"}],
                 base_objects_accessed=[])
    for k in range(2, 12):    # 100000 reads would be heavy: 100 reads of the small table make it cheap per read
        for i in range(10):
            b.au("ACCESS_HISTORY", query_id=f"01ice-5014-{k}-{i}", query_start_time=_ts(b.back(k), 10),
                 user_name="ANALYST_DAN", direct_objects_accessed=[{"objectId": 5014, "objectName": "ICE_EVENTS",
                                                                    "objectDomain": "Table"}],
                 base_objects_accessed=[])


# ---------------------------------------------------------------------------------------------------------------------------
# Lineage and audit
# ---------------------------------------------------------------------------------------------------------------------------
def lineage_audit(b: _B) -> None:
    tab = {(t["db"], t["schema"], t["name"]): t for t in b.w.tables}
    orders = tab[("ANALYTICS_DB", "CORE", "ORDERS")]
    customers = tab[("ANALYTICS_DB", "CORE", "CUSTOMERS")]

    # blast radius: ORDERS gets 12 more views (WARN, one database); CUSTOMERS 9 in its own database and 2 in
    # SANDBOX_DB (CRITICAL, two databases); the older small dependencies stay OK
    def dep(src, name, n, db="ANALYTICS_DB"):
        b.au("OBJECT_DEPENDENCIES", referenced_database=src["db"], referenced_schema=src["schema"],
             referenced_object_name=src["name"], referenced_object_id=src["id"], referenced_object_domain="TABLE",
             referencing_database=db, referencing_schema="MARTS", referencing_object_name=f"{name}_{n}",
             referencing_object_id=9_100_000 + len(b.w.rows.get(("account_usage", "OBJECT_DEPENDENCIES"), [])),
             referencing_object_domain="VIEW", dependency_type="BY_ID")

    for n in range(12):
        dep(orders, "V_LIN_ORD", n)
    for n in range(9):
        dep(customers, "V_LIN_CUS", n)
    for n in range(2):
        dep(customers, "V_LIN_CUS_SBX", n, db="SANDBOX_DB")

    # table flows: one hub feeds 15 tables (CRITICAL), one feeds 5 (WARN), one feeds 1 (OK); a target built
    # from 10 sources reads WARN on fan-in
    def flow(qid, target, source, back, user="SVC_ETL", cols=("ID", "AMOUNT")):
        b.au("ACCESS_HISTORY", query_id=qid, query_start_time=_ts(b.back(back), 3), user_name=user,
             direct_objects_accessed=[], base_objects_accessed=[],
             objects_modified=[{"objectName": f"ANALYTICS_DB.LINEAGE.{target}", "objectDomain": "Table",
                                "columns": [{"columnName": c, "baseSources": [
                                    {"objectName": f"ANALYTICS_DB.LINEAGE.{source}", "columnName": c}]} for c in cols]}])

    for i in range(15):
        flow(f"01flow-crit-{i}", f"FLOW_C{i:02d}", "FLOW_HUB_CRIT", 2 + i % 5)
    for i in range(5):
        flow(f"01flow-warn-{i}", f"FLOW_W{i}", "FLOW_HUB_WARN", 3)
    flow("01flow-ok-0", "FLOW_OK_T", "FLOW_HUB_OK", 4)
    for i in range(10):
        flow(f"01flow-in-{i}", "FLOW_WIDE_TARGET", f"FLOW_SRC_{i}", 5, user="DEV_HUGO", cols=("ID",))

    # unused views: an old plain view (WARN) and an old secure view (CRITICAL), no readers, no dependents
    for vid, name, secure, created_back in ((9_200_001, "V_LIN_UNUSED", "NO", 200),
                                            (9_200_002, "V_LIN_SECURE_UNUSED", "YES", 260)):
        b.au("VIEWS", table_id=vid, table_name=name, table_schema_id=b.w.schema_id[("ANALYTICS_DB", "MARTS")],
             table_schema="MARTS", table_catalog_id=b.w.dbs["ANALYTICS_DB"], table_catalog="ANALYTICS_DB",
             table_owner="SYSADMIN", view_definition="select 1", is_updatable="NO", insertable_into="NO",
             is_secure=secure, created=_ts(b.back(created_back), 9), last_altered=_ts(b.back(created_back - 20), 9),
             last_ddl=_ts(b.back(created_back - 20), 9), last_ddl_by="SYSADMIN", deleted=None, owner_role_type="ROLE")

    # DDL timeline: the role of each statement comes from QUERY_HISTORY (no warehouse: metadata work)
    n = 0

    def ddl(user, role, back, op, domain, name, qtype):
        nonlocal n
        n += 1
        qid = f"01ddl-{n:04d}"
        ts = _ts(b.back(back), 10, n % 50)
        b.au("QUERY_HISTORY", query_id=qid, query_text="ddl", start_time=ts, end_time=ts, user_name=user,
             role_name=role, query_type=qtype, execution_status="SUCCESS", warehouse_id=None, warehouse_name=None,
             total_elapsed_time=50, compilation_time=50, execution_time=0, query_tag=None,
             credits_used_cloud_services=0.0)
        b.au("ACCESS_HISTORY", query_id=qid, query_start_time=ts, user_name=user, direct_objects_accessed=[],
             base_objects_accessed=[], objects_modified=[],
             object_modified_by_ddl={"objectDomain": domain, "objectName": name, "objectId": 9_300_000 + n,
                                     "operationType": op, "properties": []})

    ddl("SVC_ETL", "SYSADMIN", 3, "CREATE", "Table", "ANALYTICS_DB.CORE.NEW_T1", "CREATE_TABLE")          # OK
    ddl("SVC_ETL", "SYSADMIN", 3, "ALTER", "Table", "ANALYTICS_DB.CORE.NEW_T1", "ALTER_TABLE_ADD_COLUMN")  # OK
    ddl("ADMIN_BOB", "ACCOUNTADMIN", 4, "ALTER", "View", "ANALYTICS_DB.MARTS.V_ORDERS", "ALTER_VIEW")       # WARN, admin role
    for k in range(12):                                                                                    # WARN, 12 drops
        ddl("DEV_HUGO", "DEV_ROLE", 6, "DROP", "Table", f"DEV_DB.SCRATCH.TMP_{k}", "DROP")
    ddl("DEV_HUGO", "DEV_ROLE", 6, "DROP", "Table", "DEV_DB.SCRATCH.ONE_OFF", "DROP")                      # OK, one drop
    ddl("ADMIN_ALICE", "SYSADMIN", 7, "DROP", "Schema", "DEV_DB.OLD_SCHEMA", "DROP")                       # CRITICAL
    ddl("ADMIN_ALICE", "SYSADMIN", 8, "DROP", "Database", "SANDBOX_OLD", "DROP")                           # CRITICAL
    ddl("SVC_ETL", "SYSADMIN", 9, "UNDROP", "Table", "ANALYTICS_DB.CORE.NEW_T1", "UNDROP_TABLE")           # OK

    # grant activity: OK, WARN (PUBLIC, grant option) and CRITICAL (PUBLIC write) grants, and a revoke
    def grant(back, privilege, granted_on, name, grantee, by, option=False, revoked=False):
        b.au("GRANTS_TO_ROLES", created_on=_ts(b.back(back + 20), 9) if revoked else _ts(b.back(back), 9),
             modified_on=_ts(b.back(back), 9), deleted_on=_ts(b.back(back), 9) if revoked else None,
             privilege=privilege, granted_on=granted_on, name=name, table_catalog="ANALYTICS_DB",
             table_schema="LINEAGE", granted_to="ROLE", grantee_name=grantee, grant_option=option, granted_by=by,
             granted_by_role_type="ROLE", object_instance="")

    grant(3, "SELECT", "TABLE", "ANALYTICS_DB.LINEAGE.GRANT_T1", "ANALYST_ROLE", "SYSADMIN")
    grant(3, "SELECT", "TABLE", "ANALYTICS_DB.LINEAGE.GRANT_T2", "ANALYST_ROLE", "SYSADMIN")
    grant(4, "USAGE", "SCHEMA", "ANALYTICS_DB.LINEAGE", "PUBLIC", "SECURITYADMIN")                           # WARN
    grant(5, "SELECT", "TABLE", "ANALYTICS_DB.LINEAGE.GRANT_T3", "BI_ROLE", "DEV_ROLE", option=True)         # WARN
    grant(6, "INSERT", "TABLE", "ANALYTICS_DB.LINEAGE.GRANT_T4", "PUBLIC", "DEV_ROLE")                       # CRITICAL
    grant(7, "SELECT", "TABLE", "ANALYTICS_DB.LINEAGE.GRANT_T5", "ANALYST_ROLE", "SYSADMIN", revoked=True)   # OK
    grant(7, "OWNERSHIP", "TABLE", "ANALYTICS_DB.LINEAGE.GRANT_T6", "DEV_ROLE", "SYSADMIN")                  # left out

    # admin sign-ins: ADMIN_BOB signs in with a password only (WARN); 25 failures make it CRITICAL,
    # ADMIN_ALICE uses MFA (OK)
    for k in range(25):
        b.au("LOGIN_HISTORY", event_id=9_500_000 + k, event_timestamp=_ts(b.back(1 + k % 5), 2, k),
             event_type="LOGIN", user_name="ADMIN_BOB", client_ip="192.0.2.99", reported_client_type="SNOWFLAKE_UI",
             reported_client_version="1.0", first_authentication_factor="PASSWORD", is_success="NO",
             error_code=390100, error_message="Incorrect username or password was specified.")

    # admin sessions: an old open session (CRITICAL), a three-day one (WARN), a fresh one (OK)
    def session(sid, user, method, open_back, is_open, hour=10):
        b.au("SESSIONS", session_id=sid, created_on=_ts(b.back(open_back), hour), user_name=user,
             authentication_method=method, login_event_id=sid, client_application_id="PythonConnector 3.4.0",
             client_environment="{}", is_open="YES" if is_open else "NO", closed_reason=None if is_open else "LOGOUT")

    session(9_600_001, "ADMIN_BOB", "PASSWORD", 10, True)
    session(9_600_002, "ADMIN_BOB", "OAUTH_ACCESS_TOKEN", 3, True)
    session(9_600_003, "ADMIN_BOB", "SAML2_ASSERTION", 1, True, hour=23)
    session(9_600_004, "ADMIN_ALICE", "KEYPAIR", 2, False)


def add(w) -> None:
    b = _B(w)
    ai(b)
    billing(b)
    security(b)
    performance(b)
    loading(b)
    lineage_audit(b)
