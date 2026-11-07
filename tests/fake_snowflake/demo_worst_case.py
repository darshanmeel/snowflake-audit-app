"""An account in trouble: the demo account pushed over the thresholds no other scenario reaches.

Each row is a clone of an existing fake row with a few columns changed, so it always fits the schema.
Thresholds come from the checks' default params.
"""
from __future__ import annotations

import datetime as dt

from tests.fake_snowflake import schema as fake_schema

AU = f"{fake_schema.SNOWFLAKE_DB}.account_usage"
OU = f"{fake_schema.SNOWFLAKE_DB}.organization_usage"
SHOW = f"{fake_schema.SNOWFLAKE_DB}.{fake_schema.SHOW_SCHEMA}"
BAD_IP = "'203.0.113.77'"
SPIKE_CREDITS = 20000


def _clone(con, table: str, where: str, n: int = 1, **sets) -> None:
    """n copies of one row of `table`, with columns set to SQL expressions that can use i, the copy's number."""
    replace = ", ".join(f"{expr} AS {col}" for col, expr in sets.items())
    con.execute(f"INSERT INTO {table} BY NAME SELECT * EXCLUDE (i) REPLACE ({replace}) "
                f"FROM (SELECT * FROM {table} WHERE {where} LIMIT 1) CROSS JOIN range({n}) r(i)")


def _day(as_of: dt.date, ago: int, hour: int = 3) -> str:
    return f"TIMESTAMP '{as_of - dt.timedelta(days=ago)} {hour:02d}:00:00'"


def _admin(con) -> str:
    return con.execute(f"""SELECT u.name FROM {AU}.USERS u JOIN {AU}.GRANTS_TO_USERS g ON g.grantee_name = u.name
        WHERE g.role = 'ACCOUNTADMIN' AND g.deleted_on IS NULL AND u.deleted_on IS NULL AND NOT COALESCE(u.disabled, FALSE)
        AND COALESCE(UPPER(u.type), 'PERSON') = 'PERSON' ORDER BY 1 LIMIT 1""").fetchone()[0]


def _sign_ins(con, admin: str, as_of: dt.date) -> None:
    who = f"user_name = '{admin}'"
    _clone(con, f"{AU}.LOGIN_HISTORY", who, 30, is_success="'NO'", client_ip=BAD_IP, event_type="'LOGIN'",
           error_code="390100", error_message="'INCORRECT_USERNAME_PASSWORD'", event_timestamp=_day(as_of, 2),
           first_authentication_factor="'PASSWORD'", second_authentication_factor="NULL")
    _clone(con, f"{AU}.LOGIN_HISTORY", who, is_success="'YES'", client_ip=BAD_IP, event_type="'LOGIN'",
           error_code="NULL", error_message="NULL", event_timestamp=_day(as_of, 1),
           first_authentication_factor="'PASSWORD'", second_authentication_factor="NULL")
    con.execute(f"DELETE FROM {AU}.SESSION_POLICIES")
    _clone(con, f"{OU}.LOGIN_HISTORY", "TRUE", 60, is_success="'NO'", event_timestamp=_day(as_of, 2))


def _users(con, admin: str, as_of: dt.date) -> None:
    con.execute(f"UPDATE {AU}.USERS SET bypass_mfa_until = ? WHERE name = ?", [as_of + dt.timedelta(days=5), admin])
    _clone(con, f"{AU}.USERS", f"name = '{admin}'", name="'LEFT_THE_COMPANY'", login_name="'LEFT_THE_COMPANY'",
           user_id="990001", disabled="TRUE", bypass_mfa_until="NULL")
    creds = f"{AU}.CREDENTIALS"
    _clone(con, creds, "TRUE", credential_id="990001", user_name=f"'{admin}'", type="'KEYPAIR'", domain="'KEYPAIR'",
           status="'ACTIVE'", created_on=_day(as_of, 400), last_used_on=_day(as_of, 2), name="'OLD_KEY'")
    _clone(con, creds, "TRUE", credential_id="990002", user_name=f"'{admin}'", domain="'PROGRAMMATIC_ACCESS_TOKEN'",
           status="'ACTIVE'", created_on=_day(as_of, 30), last_used_on=_day(as_of, 2), name="'ADMIN_TOKEN'",
           additional_details="""'{"MINS_TO_BYPASS_NETWORK_POLICY_REQUIREMENT": 60}'""")
    ingress = f"{AU}.INGRESS_NETWORK_ACCESS_HISTORY"
    con.execute(f"UPDATE {ingress} SET is_success = TRUE, client_private_link_id = 'vpce-demo'")
    _clone(con, ingress, "TRUE", user_name=f"'{admin}'", client_private_link_id="NULL", client_ip=BAD_IP,
           is_success="TRUE", event_timestamp=_day(as_of, 2))


def _network(con) -> None:
    # No policy on the account or any user, and unloading to an inline URL allowed.
    con.execute(f"""UPDATE {SHOW}.parameters SET "value" = '' WHERE "key" = 'NETWORK_POLICY'""")
    con.execute(f"""UPDATE {SHOW}.parameters SET "value" = 'false' WHERE "key" = 'PREVENT_UNLOAD_TO_INLINE_URL'""")
    con.execute(f"""UPDATE {SHOW}.parameters SET "value" = '0'
        WHERE "key" IN ('STATEMENT_TIMEOUT_IN_SECONDS', 'STATEMENT_QUEUED_TIMEOUT_IN_SECONDS')""")
    con.execute(f"DELETE FROM {AU}.POLICY_REFERENCES WHERE policy_kind = 'NETWORK_POLICY'")


def _grants(con) -> None:
    grants = f"{AU}.GRANTS_TO_ROLES"
    on_table = "granted_on = 'TABLE' AND deleted_on IS NULL"
    _clone(con, grants, on_table, grantee_name="'PUBLIC'", privilege="'INSERT'", name="'OPEN_TO_ALL'")
    _clone(con, grants, on_table, 110, grantee_name="'ACCOUNTADMIN'", privilege="'OWNERSHIP'", name="'ADMIN_OWNED_' || i")
    _clone(con, grants, on_table, grantee_name="'SYSADMIN'", privilege="'SELECT'", grant_option="TRUE", name="'ADMIN_GRANTABLE'")
    # The admin role granted to the role most users hold.
    role = con.execute(f"""SELECT role FROM {AU}.GRANTS_TO_USERS WHERE deleted_on IS NULL AND role NOT IN
        ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'SYSADMIN', 'ORGADMIN', 'PUBLIC', 'GLOBALORGADMIN')
        GROUP BY role ORDER BY COUNT(*) DESC, role LIMIT 1""").fetchone()[0]
    _clone(con, grants, "granted_on = 'ROLE' AND deleted_on IS NULL", grantee_name=f"'{role}'", privilege="'USAGE'", name="'ACCOUNTADMIN'")
    con.execute(f"""INSERT INTO {SHOW}.tasks BY NAME SELECT * EXCLUDE (i) REPLACE ('DROPPED_ROLE' AS "owner", 'ORPHAN_' || i AS "name")
        FROM (SELECT * FROM {SHOW}.tasks LIMIT 1) CROSS JOIN range(25) r(i)""")
    con.execute(f"""UPDATE {SHOW}.streamlits SET "owner" = 'ACCOUNTADMIN'""")


def _spend(con, as_of: dt.date) -> None:
    day = as_of - dt.timedelta(days=2)
    when = _day(as_of, 2)
    _clone(con, f"{AU}.WAREHOUSE_METERING_HISTORY", "TRUE", start_time=when, end_time=f"{when} + INTERVAL 1 HOUR",
           credits_used=str(SPIKE_CREDITS), credits_used_compute=str(SPIKE_CREDITS), credits_used_cloud_services="0",
           credits_attributed_compute_queries="1")
    _clone(con, f"{AU}.METERING_HISTORY", "service_type = 'WAREHOUSE_METERING'", start_time=when,
           end_time=f"{when} + INTERVAL 1 HOUR", credits_used=str(SPIKE_CREDITS), credits_used_compute=str(SPIKE_CREDITS))
    _clone(con, f"{AU}.METERING_DAILY_HISTORY", "service_type = 'WAREHOUSE_METERING'", usage_date=f"DATE '{day}'",
           credits_used=str(SPIKE_CREDITS), credits_used_compute=str(SPIKE_CREDITS), credits_billed=str(SPIKE_CREDITS))
    con.execute(f"DELETE FROM {SHOW}.budget_instances")
    _clone(con, f"{AU}.AUTOMATIC_CLUSTERING_HISTORY", "TRUE", start_time=when, end_time=f"{when} + INTERVAL 1 HOUR", credits_used=str(SPIKE_CREDITS))
    _clone(con, f"{AU}.HYBRID_TABLE_USAGE_HISTORY", "TRUE", start_time=when, end_time=f"{when} + INTERVAL 1 HOUR", credits_used="500")
    _clone(con, f"{AU}.SNOWFLAKE_COWORK_USAGE_HISTORY", "TRUE", start_time=when, end_time=f"{when} + INTERVAL 1 HOUR", token_credits="5000")
    # Billing feeds behind: one by days, one by a day and a bit.
    con.execute(f"DELETE FROM {AU}.DATABASE_STORAGE_USAGE_HISTORY WHERE usage_date > ?", [as_of - dt.timedelta(days=5)])
    con.execute(f"DELETE FROM {AU}.STORAGE_USAGE WHERE usage_date > ?", [as_of - dt.timedelta(days=2)])


def _org(con, as_of: dt.date) -> None:
    day = as_of - dt.timedelta(days=5)
    usage = f"{OU}.USAGE_IN_CURRENCY_DAILY"
    _clone(con, usage, "rating_type = 'cloud_services'", usage_date=f"DATE '{day}'", usage_in_currency="5000")
    _clone(con, usage, "rating_type = 'data_transfer'", usage_date=f"DATE '{day}'", usage_in_currency="500000")
    _clone(con, f"{OU}.METERING_DAILY_HISTORY", "service_type = 'WAREHOUSE_METERING'", usage_date=f"DATE '{day}'",
           credits_used_cloud_services="1000", credits_adjustment_cloud_services="0")
    # The account with the least compute also pays for a lot of storage: dormant, and costing money.
    quiet = con.execute(f"""SELECT a.account_locator FROM {OU}.ACCOUNTS a LEFT JOIN {OU}.METERING_DAILY_HISTORY m
        ON m.account_locator = a.account_locator AND m.service_type = 'WAREHOUSE_METERING' AND m.usage_date >= ?
        WHERE a.created_on < ? GROUP BY 1 ORDER BY COALESCE(SUM(m.credits_used), 0), 1 LIMIT 1""",
                        [as_of - dt.timedelta(days=33), as_of - dt.timedelta(days=60)]).fetchone()[0]
    _clone(con, usage, "TRUE", account_locator=f"'{quiet}'", usage_date=f"DATE '{day}'", usage_type="'storage'", usage_in_currency="5000")
    # One other service priced 10% over the list price.
    _clone(con, f"{OU}.RATE_SHEET_DAILY", "service_type = 'WAREHOUSE_METERING'", **{'"DATE"': f"DATE '{day}'"},
           usage_type="'automatic-clustering'", service_type="'AUTO_CLUSTERING'", effective_rate="effective_rate * 1.1")
    con.execute(f"UPDATE {OU}.REMAINING_BALANCE_DAILY SET capacity_balance = 0, free_usage_balance = 0, rollover_balance = 0")


def _storage_and_ai(con, as_of: dt.date) -> None:
    con.execute(f"UPDATE {AU}.STAGE_STORAGE_USAGE_HISTORY SET average_stage_bytes = {2 * 1024 ** 4}")
    search = f"{AU}.CORTEX_SEARCH_DAILY_USAGE_HISTORY"
    for kind, ago, credits in (("EMBED_TEXT_TOKENS", 12, 1), ("SERVING", 2, 50)):
        _clone(con, search, "TRUE", service_id="990001", service_name="'STALE_INDEX'", consumption_type=f"'{kind}'",
               usage_date=f"DATE '{as_of - dt.timedelta(days=ago)}'", credits=str(credits))
    # An external stage with no storage integration and no stored key.
    con.execute(f"""INSERT INTO {SHOW}.stages BY NAME SELECT * REPLACE ('RAW_DROP' AS "name", 'EXTERNAL' AS "type", 'N' AS "has_credentials", NULL AS "storage_integration")
        FROM {SHOW}.stages LIMIT 1""")


def _warehouses(con, as_of: dt.date) -> None:
    _clone(con, f"{AU}.WAREHOUSE_EVENTS_HISTORY", "event_name = 'RESUME_WAREHOUSE'", 13000,
           event_name="CASE WHEN i % 2 = 0 THEN 'RESUME_WAREHOUSE' ELSE 'SUSPEND_WAREHOUSE' END", event_state="'COMPLETED'",
           timestamp=f"{_day(as_of, 3)} + i * INTERVAL 5 SECOND")
    con.execute(f"""INSERT INTO {SHOW}.warehouses BY NAME SELECT * REPLACE ('FORGOTTEN_WH' AS "name", ? AS "created_on")
        FROM {SHOW}.warehouses LIMIT 1""", [as_of - dt.timedelta(days=200)])
    _clone(con, f"{AU}.QUERY_HISTORY", "query_type = 'COPY' AND warehouse_name IS NOT NULL", 20, start_time=f"{_day(as_of, 4)} + i * INTERVAL 1 MINUTE",
           end_time=f"{_day(as_of, 4)} + i * INTERVAL 1 MINUTE + INTERVAL 3 MINUTE", warehouse_name="'COPY_LISTING_WH'",
           query_id="'wc-copy-' || i", list_external_files_time="60000", total_elapsed_time="180000", execution_time="120000")


def apply(con, as_of: dt.date) -> None:
    admin = _admin(con)
    _sign_ins(con, admin, as_of)
    _users(con, admin, as_of)
    _network(con)
    _grants(con)
    _spend(con, as_of)
    _org(con, as_of)
    _storage_and_ai(con, as_of)
    _warehouses(con, as_of)
