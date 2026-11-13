"""Builds docs/technical.html. Run from anywhere: python build_technical.py"""
import json
import re
from html import escape as esc
from pathlib import Path

from mapkit import Map

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
OUT = REPO / "docs" / "technical.html"

# ---------------------------------------------------------------- helpers
SQL_KW = r"\b(SELECT|FROM|WHERE|WITH|AS|AND|OR|GROUP BY|ORDER BY|LIMIT|UNION ALL|JOIN|LEFT JOIN|ON|CASE|WHEN|THEN|ELSE|END|DATEADD|CAST|GRANT|ON|TO|ROLE|SHOW|USE|CREATE|IF NOT EXISTS|DATABASE|WAREHOUSE|USER|ACCOUNT|NULL|DESC)\b"


def hl(text, kind="sql"):
    out = []
    for line in text.split("\n"):
        e = esc(line)
        if kind == "sql" and e.lstrip().startswith("--") or kind == "sh" and e.lstrip().startswith("#"):
            out.append(f'<span class="tc">{e}</span>')
            continue
        if kind == "json":
            e = re.sub(r'(&quot;[^&]*?&quot;)(\s*:)', r'<span class="tk">\1</span>\2', e)
            e = re.sub(r':\s*(&quot;[^&]*?&quot;)', lambda m: ': <span class="ts">' + m.group(1) + '</span>', e)
            e = re.sub(r'(?<![\w">])(-?\d+\.?\d*)(?![\w"])', r'<span class="tn">\1</span>', e)
        elif kind == "sql":
            e = re.sub(r"(&#x27;[^&]*?&#x27;)", r'<span class="ts">\1</span>', e)
            e = re.sub(SQL_KW, r'<span class="tk">\1</span>', e)
            e = re.sub(r"(?<![\w.])(\d+\.?\d*)(?![\w])", r'<span class="tn">\1</span>', e)
        elif kind == "sh":
            e = re.sub(r"(?<=\s)(--[\w-]+)", r'<span class="tb">\1</span>', e)
            e = re.sub(r"^(python|cd|npx|npm|git)\b", r'<span class="tk">\1</span>', e)
        out.append(e)
    return "\n".join(out)


def payload(direction, title, text, kind="sql"):
    cls = "in" if direction == "IN" else "out"
    return (f'<div class="payload"><div class="h"><span class="dir {cls}">{direction}</span><span>{esc(title)}</span></div>'
            f'<pre>{hl(text, kind)}</pre></div>')


def pair(*ps):
    return '<div class="payloads">' + "".join(ps) + "</div>"


def table(head, rows, cls="", raw=False):
    th = "".join(f"<th>{h}</th>" for h in head)
    body = "".join("<tr>" + "".join(f"<td>{c if raw else c}</td>" for c in r) + "</tr>" for r in rows)
    return f'<div class="table-wrap"><table class="{cls}"><tr>{th}</tr>{body}</table></div>'


def steps(rows):
    body = "".join(f'<tr><td><span class="n">{i}</span></td><td>{s}</td><td class="v">{a}</td><td class="v">{b}</td></tr>'
                   for i, (s, a, b) in enumerate(rows, 1))
    return f'<div class="table-wrap"><table class="steps"><tr><th>#</th><th>Step</th><th>In</th><th>Out</th></tr>{body}</table></div>'


def c(t):
    return f"<code>{esc(t)}</code>"


def cite(t):
    return f'<span class="cite">{esc(t)}</span>'


def card(kind, title, rows, res, src=""):
    r = "".join(f"<tr><td>{a}</td><td>{b}</td></tr>" for a, b in rows)
    verdict = {"ok": "TYPICAL", "edge": "EDGE CASE", "bad": "REJECTED / FAILS"}[kind]
    s = f'<div class="res cite">{esc(src)}</div>' if src else ""
    return (f'<div class="ex {kind}"><div class="h"><span class="verdict">{verdict}</span><b>{title}</b></div>'
            f'<div class="lbl2">IN</div><table>{r}</table><div class="lbl2">OUT</div><div class="res">{res}</div>{s}</div>')


def exset(*cards):
    return '<div class="exset">' + "".join(cards) + "</div>"


def ul(items):
    return "<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>"


def section(sid, title, body):
    return f'<section id="{sid}"><h2>{title}</h2>{body}</section>'


def key(t):
    return f'<p class="key">Key: {t}</p>'


def cap(t):
    return f'<p class="cap">Notice: {t}</p>'


def sub(t):
    return f'<h3>{t}</h3>'


# ---------------------------------------------------------------- data
manifest = json.loads((REPO / "app/queries/manifest.json").read_text(encoding="utf-8"))
DOMAINS = {k: len(v) for k, v in manifest.items()}
TOTAL = sum(DOMAINS.values())
assert TOTAL == 302, TOTAL

# ================================================================= 1. architecture
def l0():
    m = Map("l0", 1000, 250)
    w, h, g = 138, 92, 34
    xs = [i * (w + g) for i in range(6)]
    m.box("sf", xs[0], 40, w, h, "Snowflake account", "usage views", "data", "DATA", "read-only: SELECT, WITH, SHOW")
    m.box("ex", xs[1], 40, w, h, "Export", "export_results.py", "routine", "", "302 checks, 3 windows")
    m.box("fo", xs[2], 40, w, h, "Results folder", "parquet + manifest.json", "data", "DATA", "outside the repo")
    m.box("ld", xs[3], 40, w, h, "Loader", "load_results.py", "routine", "", "atomic swap")
    m.box("db", xs[4], 40, w, h, "DuckDB file", "findings dims summary tags", "data", "DATA", "audit.duckdb")
    m.box("ap", xs[5], 40, w, h, "FastAPI + React", "app/api, app/web", "entry", "ENTRY", "127.0.0.1:8000")
    m.box("st", xs[5], 160, w, 80, "Streamlit app", "same API and build", "", "OPTIONAL", "not run in Snowflake yet")
    for i, (a, b) in enumerate([("sf", "ex"), ("ex", "fo"), ("fo", "ld"), ("ld", "db"), ("db", "ap")]):
        x0 = xs[i] + w
        m.arrow([(x0, 86), (x0 + g, 86)], a, b, dashed=(a != "sf" and a != "db"))
        m.num(x0 + g // 2, 66, i + 1)
    m.arrow([(xs[5] + w // 2, 160), (xs[5] + w // 2, 132)], "st", "ap", dashed=True)
    m.lbl(xs[2] + w // 2, 160, "findings/*.parquet, dims/, tags_src/", False)
    m.lbl(xs[4] + w // 2, 160, "one table per check", False)
    return m.render()


def l2():
    m = Map("l2", 1000, 470)
    m.grp(0, 0, 215, 440, "SNOWFLAKE")
    m.grp(235, 0, 255, 440, "EXPORT (tools/)")
    m.grp(510, 0, 205, 440, "DISK (outside repo)")
    m.grp(735, 0, 265, 440, "APP (local process)")
    m.box("au", 15, 40, 165, 80, "ACCOUNT_USAGE ORGANIZATION_USAGE", "views, 302 checks", "data", "DATA", "SELECT / WITH / SHOW only")
    m.box("is", 15, 160, 165, 80, "INFORMATION_SCHEMA SHOW", "fallback source", "data", "DATA", "used when ACCOUNT_USAGE is unreadable")
    m.box("q", 250, 40, 225, 80, "app/queries/", "checks fallback shims common dims", "routine", "", "headers drive everything")
    m.box("ex", 250, 160, 225, 80, "export_results.py", "probe, render, run, mask", "routine entry", "ENTRY", "run_export: tools/export_results.py:1146")
    m.box("cfg", 250, 280, 225, 80, "config/", "settings thresholds materiality", "data", "DATA", "yml; settings.local.yml overrides")
    m.box("res", 525, 40, 175, 80, "results/STAMP/", "findings dims tags_src manifest", "data", "DATA", "kept: newest 2 folders")
    m.box("ld", 525, 160, 175, 80, "load_results.py", "build_tags.py", "routine", "", "builds into audit.duckdb.tmp")
    m.box("db", 525, 280, 175, 80, "audit.duckdb", "findings dims summary tags", "data", "DATA", "read-only in the app")
    m.box("api", 750, 40, 235, 80, "app/api/app.py", "37 routes, service.py, explorer, access log", "routine entry", "ENTRY", "FastAPI app: app/api/app.py:124")
    m.box("core", 750, 160, 235, 80, "app/core/data.py", "money, status, filters", "routine", "", "one cut-off, one price basis")
    m.box("ui", 750, 280, 235, 80, "React UI", "web/src built to app/web/dist", "", "", "mounted last at /")
    m.arrow([(180, 80), (250, 80)], "au", "q")
    m.arrow([(180, 200), (250, 200)], "is", "ex", dashed=True)
    m.arrow([(362, 120), (362, 160)], "q", "ex")
    m.arrow([(362, 280), (362, 240)], "cfg", "ex")
    m.arrow([(475, 200), (500, 200), (500, 80), (525, 80)], "ex", "res", dashed=True)
    m.arrow([(612, 120), (612, 160)], "res", "ld", dashed=True)
    m.arrow([(612, 240), (612, 280)], "ld", "db", dashed=True)
    m.arrow([(700, 320), (725, 320), (725, 200), (750, 200)], "db", "core", dashed=True)
    m.arrow([(867, 160), (867, 120)], "core", "api")
    m.arrow([(867, 280), (867, 240)], "ui", "api")
    m.lbl(215, 66, "reads", False)
    m.lbl(215, 184, "SHOW", False)
    m.lbl(500, 244, "exports", False)
    m.lbl(640, 142, "load", False)
    m.lbl(790, 140, "SQL", False)
    m.lbl(910, 258, "GET /api/*", False)
    m.box("hint", 250, 400, 450, 36, inner='<span class="sub" style="font-size:12px">The export is the only step that talks to Snowflake. The app never does.</span>', cls="")
    return m.render()


def sec_arch():
    b = sub("L0 · big picture") + l0()
    b += key("grey = data · teal = code · bold border = what the user starts · dashed = data moves · solid = calls · numbers = order")
    b += cap("one direction only: Snowflake → export → folder → loader → DuckDB → API → UI. Nothing flows back.")
    b += ul([
        "Read-only guard on every statement: one <code>SELECT</code>, <code>WITH</code> or <code>SHOW</code>, nothing else " + cite("tools/export_results.py:660-665, 724-732"),
        "Data never sits in the repo: <code>AUDIT_DATA_DIR</code> or the OS data folder; an output inside the repo is refused " + cite("app/core/datasource.py:16-38"),
        "The app opens <code>AUDIT_DB</code>, else the <code>current_db.txt</code> pointer, else <code>audit.duckdb</code> " + cite("app/core/data.py:103-112"),
    ])
    b += sub("L2 · components") + l2()
    b += key("frames = where it runs · grey = data · teal = code · dashed = data moves · solid = calls")
    b += cap("only the export crosses the Snowflake boundary; everything right of it reads files.")
    b += table(["Component", "Does", "Entry"], [
        [c("start.py"), "venv, sign-in prompt, 7-day export, load, opens the app", cite("start.py:275")],
        [c("tools/export_results.py"), "probe, render, run, mask, write the results folder", cite("tools/export_results.py:1576")],
        [c("tools/load_results.py"), "folder or zip to DuckDB file plus sidecar", cite("tools/load_results.py:732")],
        [c("app/api/app.py"), "FastAPI routes, response cache, static UI mount", cite("app/api/app.py:124")],
        [c("app/core/data.py"), "every DuckDB read: filters, money, status, cut-off", cite("app/core/data.py:1-40")],
        [c("web/src/main.tsx"), "React 18 + TypeScript root, built by Vite", cite("web/src/main.tsx:30")],
        [c("tools/streamlit_deploy/"), "ships the same build plus a DuckDB file to a stage", cite("tools/streamlit_deploy/deploy.py:162")],
        [c("tools/make_export_kit.py"), "zip a customer can run themselves, SQL pasted flat; copies <code>app/core/masking.py</code> and <code>tools/export_shared.py</code> into the kit script between marker lines", cite("tools/make_export_kit.py:133-165")],
        [c("tools/export_shared.py"), "helpers the export and the kit share: SQL literals, the SHOW runner, shim and fallback helpers; standard library and pyarrow only", cite("tools/export_shared.py:1-5")],
    ])
    b += "<p class=\"key\">Other helpers: <code>tools/gate.py</code> (pre-commit runner), <code>tools/build_manifest.py</code>, <code>tools/lint_headers.py</code>, <code>tools/build_demo_db.py</code>.</p>"
    return section("arch", "1 · Architecture", b)


# ================================================================= 2. export
def export_map():
    m = Map("exp", 1000, 700)
    for i, lab in enumerate(["EXPORT PROCESS (run_export)", "SNOWFLAKE SESSION", "RESULTS FOLDER"]):
        m.lane(i * 232, 232, lab)
    W, H = 205, 186
    X = [0, 265, 530, 795]
    Y = [32, 264, 496]
    m.step("s1", X[0], Y[0], W, H, 1, "plan", ["cut-off, checks, window plan", "creates <code>OUT.tmp</code>"],
           "<code>--windows 30</code>", "<code>as_of 2026-09-22</code> plan <code>[(7,7),(30,30),(90,30)]</code>")
    m.step("s2", X[1], Y[0], W, H, 2, "connect + prices", ["key file, else password, else browser", "price: CLI, rate sheet, invoice, settings"],
           "<code>.env</code> + 8 SNOWFLAKE_* keys", "UTC session, <code>credit 3.0</code>", cls="routine")
    m.step("s3", X[1], Y[1], W, H, 3, "probe + edition", ["<code>SELECT 1 ... LIMIT 0</code> per view", "edition from the org ACCOUNTS view"],
           "every view in <code>reads:</code>", "readable set, edition", cls="")
    m.step("s4", X[2], Y[0], W, H, 4, "decide per check", ["edition too low: not_assessed", "unreadable: fallback or not_assessed", "else run"],
           "check + probe result", "one of 4 statuses", cls="routine")
    m.step("s5", X[2], Y[1], W, H, 5, "run SQL per window", ["<code>assert_read_only</code>, render", "<code>LIMIT max_rows+1</code> (50,000)"],
           "SQL for 7, 30 (90 = 30)", "rows, lower-case cols")
    m.step("s6", X[2], Y[2], W, H, 6, "write findings", ["<code>blank_unflagged_waste</code>", "<code>window_days</code> = label"],
           "rows", "<code>findings/QID.parquet</code>", cls="data")
    m.step("s7", X[3], Y[0], W, H, 7, "finish", ["mask names if asked", "manifest.json, report.md", "rename <code>OUT.tmp</code> to <code>OUT</code>"],
           "all checks done", "<code>wrote OUT: N ok, ...</code>", cls="routine")
    m.box("tmp", X[0], Y[2] + 30, W, 100, "OUT.tmp/", "findings/ dims/ then manifest", "data", "DATA", "a failed run never leaves a half folder under the final name")
    m.box("out", X[3], Y[2] + 30, W, 100, "OUT/ (final)", "loaded by load_results.py", "data", "DATA", "")
    m.arrow([(X[0] + W, 125), (X[1], 125)], "s1", "s2")
    m.arrow([(X[1] + W // 2, Y[0] + H), (X[1] + W // 2, Y[1])], "s2", "s3")
    m.arrow([(X[1] + W, Y[1] + 60), (X[1] + W + 30, Y[1] + 60), (X[1] + W + 30, 90), (X[2], 90)], "s3", "s4")
    m.arrow([(X[2] + W // 2, Y[0] + H), (X[2] + W // 2, Y[1])], "s4", "s5")
    m.arrow([(X[2] + W // 2, Y[1] + H), (X[2] + W // 2, Y[2])], "s5", "s6", dashed=True)
    m.arrow([(X[2] + W, 125), (X[3], 125)], "s4", "s7")
    m.arrow([(X[2], Y[2] + 93), (X[0] + W, Y[2] + 93)], "s6", "tmp", dashed=True)
    m.arrow([(X[3] + W // 2, Y[0] + H), (X[3] + W // 2, Y[2] + 30)], "s7", "out", dashed=True)
    m.arrow([(X[0] + W // 2, Y[0] + H), (X[0] + W // 2, Y[2] + 30)], "s1", "tmp")
    for n, (x, y) in enumerate([(X[0] + W + 20, 108), (X[1] + W // 2, 235), (X[2] - 12, 75), (X[2] + W // 2, 250), (X[2] + W // 2, 482), (X[2] + W + 20, 108), (X[0] + W // 2, 250)], 1):
        pass
    m.lbl(X[1] + W // 2 + 40, 252, "view list", False)
    m.lbl(X[2] + W // 2 + 38, 252, "to run", False)
    m.lbl(X[2] + W // 2 + 35, 482, "rows", False)
    m.lbl(X[0] + W // 2 + 36, 480, "creates", False)
    m.lbl(X[3] + W // 2 + 30, 480, "rename", False)
    m.lbl(X[2] - 130, Y[2] + 76, "parquet", False)
    return m.render()


def sec_export():
    b = export_map()
    b += key("grey bands = where it runs · white = step · teal = code decision · grey = data · IN / OUT = what enters and leaves · dashed = data moves")
    b += cap("the folder is built as <code>OUT.tmp</code> and renamed only at the end, so a half-finished export never has the final name.")
    b += sub("Steps with example values")
    b += steps([
        ("Pick the money cut-off <code>_cutoff</code>", "now 2026-09-21 03:00 UTC, <code>include_today</code> true", "<code>as_of_date 2026-09-22</code> (first day left out)"),
        ("Refuse an output inside the repo", "<code>--out</code> under the repo", "exit 2: choose a folder outside it"),
        ("Load checks, thresholds, windows", "<code>--windows 30</code>", "plan <code>[(7,7),(30,30),(90,30)]</code>, alias <code>90 -&gt; 30</code>"),
        ("Connect: key file, else password, else browser", "<code>SNOWFLAKE_PRIVATE_KEY_FILE</code> set", "session <code>TIMEZONE=UTC</code>, <code>QUERY_TAG</code>, timeout 900 s"),
        ("Fix three prices once", "no CLI price, invoice readable", "credit <code>3.0</code> source <code>usage_in_currency_daily</code>; storage <code>0.75 x 30.4 = 22.8</code>"),
        ("Probe every view", "<code>SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.V LIMIT 0</code>", "set of unreadable views + warehouse gap count"),
        ("Detect edition", "<code>ORGANIZATION_USAGE.ACCOUNTS</code> readable?", "edition, or &quot;ENTERPRISE&quot; meaning at least, or unknown"),
        ("Shared fallback inputs (only if needed)", "unreadable sources + fallbacks", "28 six-hour <code>QUERY_HISTORY</code> slices, shim results"),
        ("Run each check <code>run_one</code>", "check + probe + edition", "<code>ok</code> / <code>empty</code> / <code>not_assessed</code> / <code>failed</code>"),
        ("Per window <code>_run_check</code>", "render, <code>LIMIT 50001</code>", "rows cut to 50,000, window marked truncated"),
        ("Tag sources and dims", "main session, after all checks", "<code>tags_src/*.parquet</code>, <code>dims/*.parquet</code>"),
        ("Mask, manifest, report, rename", "<code>--mask</code> or <code>privacy.mask_fields</code>", "<code>manifest.json</code>, <code>report.md</code>, <code>OUT</code>"),
    ])
    b += cite("tools/export_results.py:1050-1057, 1129-1366, 821-873, 924-975, 989-1003, 1211-1288; tools/common.py:24-40")
    b += sub("Command and expected output")
    b += pair(
        payload("IN", "export one window set", "python tools/export_results.py --out <folder outside the repo> --windows 30", "sh"),
        payload("OUT", "console (README.md:343, tools/export_results.py:1616-1623)",
                "[12/302] <check_id>: ok, 34 rows, 1.2s\n...\nwrote <folder>: N empty, N ok, ...\nnext: python tools/load_results.py <folder> --db PATH", "sh"))
    b += sub("Per-check decision order")
    b += table(["Condition", "Status written", "Where"], [
        ["edition below Enterprise and the check needs it", f"{c('not_assessed')} / {c('edition_too_low')}, not run", cite("tools/export_results.py:1235-1245")],
        ["a source is unreadable and a fallback exists (or <code>--use-fallbacks</code>)", "fallback runs; any failure reads <code>not_assessed</code> / <code>role_cannot_see</code>, never empty", cite("tools/export_results.py:1246-1281")],
        ["a source is unreadable, no fallback", f"{c('not_assessed')} naming each view and its error", cite("tools/export_results.py:1282-1291")],
        ["SQL error, timeout, view missing", f"{c('failed')} with <code>error_code</code> and <code>cause</code>", cite("tools/export_results.py:1292-1308")],
        ["ran", f"{c('ok')} (rows) or {c('empty')}", cite("tools/export_results.py:1298-1301")],
    ])
    b += sub("Examples")
    b += exset(
        card("ok", "Cut-off at noon, today off", [("now (UTC)", "2026-09-21 12:00"), ("include_today", "false")],
             "<code>as_of_date 2026-09-21</code>", "tests/test_export_show.py:136-142"),
        card("edge", "Cut-off at 03:00, today off", [("now (UTC)", "2026-09-21 03:00"), ("include_today", "false")],
             "<code>2026-09-20</code>: yesterday is not complete yet (now minus 8 h)", "tests/test_export_show.py:136-142"),
        card("ok", "Cut-off at 03:00, today on (default)", [("now (UTC)", "2026-09-21 03:00"), ("include_today", "true")],
             "<code>2026-09-22</code>: tomorrow, so today is included and shown partial", "tests/test_export_show.py:136-142"),
        card("bad", "Statement that writes", [("SQL", "<code>SELECT 1; SELECT 2</code> or <code>DROP TABLE x</code>")],
             "refused: <em>not a single SELECT, WITH or SHOW</em>", "run on this repo: tools/export_results.py:660-665"),
    )
    b += ul([
        "<code>--workers N</code>: default 4, or 1 with browser sign-in; each thread has its own session because a <code>SHOW</code> and its <code>RESULT_SCAN</code> must share one " + cite("tools/export_results.py:766-773, 1200-1209"),
        "Exit codes: 0 done, 1 connection error, 2 config error " + cite("tools/export_results.py:1611-1625"),
        "<code>--validate</code> runs every statement with <code>LIMIT 0</code>, writes <code>validate.md</code>, exports nothing " + cite("tools/export_results.py:1407-1521"),
        "No zip step in <code>export_results.py</code>; only the export kit zips its output " + cite("tools/export_kit/run_export.py:1525-1527"),
    ])
    return section("export", "2 · Export flow", b)


# ================================================================= 3. SQL checks
def checks_map():
    m = Map("chk", 1000, 250)
    w, h = 150, 90
    xs = [0, 190, 380, 570, 760]
    m.box("h", xs[0], 20, w, h, "checks/QID.sql", "14 header fields + SQL", "data", "DATA")
    m.box("bm", xs[1], 20, w, h, "build_manifest.py", "header to manifest.json", "routine")
    m.box("rg", xs[2], 20, w, h, "registry.py", "QuerySpec per check", "routine")
    m.box("rn", xs[3], 20, w, h, "render()", "includes, :params, __X__", "routine")
    m.box("ro", xs[4], 20, 240, h, "assert_read_only", "then run per window", "routine entry", "GUARD")
    m.box("fb", xs[3], 150, w, 80, "fallback + shims", "from info schema", "data", "DATA")
    m.box("na", xs[4], 150, 240, 80, "not_assessed", "never empty, never $0", "fail")
    for i in range(4):
        a = ["h", "bm", "rg", "rn"][i]
        b = ["bm", "rg", "rn", "ro"][i]
        m.arrow([(xs[i] + w, 65), (xs[i + 1], 65)], a, b, dashed=(i == 0))
    m.arrow([(xs[3] + w // 2, 110), (xs[3] + w // 2, 150)], "rn", "fb", dashed=True)
    m.arrow([(xs[3] + w, 190), (xs[4], 190)], "fb", "na")
    m.lbl(xs[3] + w // 2 + 55, 130, "unreadable", False)
    m.lbl(xs[3] + w + 20, 175, "fails", False)
    return m.render()


def sec_checks():
    ex_hdr = """-- query_id: cost_daily_by_resource
-- title: Daily credits and dollars per warehouse, serverless task and Snowpipe
-- domain: cost   tier: standard
-- entity: resources = resource_key
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, ...
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- empty_if: role_cannot_see, no_activity
-- params: :period_days (default 30) ...; :top_n (default 100) ...
-- confidence: needs_confirmation
-- read_this: One row = one day's credits for one resource ...
-- healthy: n/a - inventory
-- next: cost_chargeback_by_warehouse
WITH __INCLUDE_sf_cs_billed_ratio__,
..."""
    render_in = "SELECT DATEADD(day, -:period_days, __AS_OF_DATE__) AS d,\n       __CREDIT_PRICE__ AS p,\n       __STORAGE_PRICE_TB_MONTH__ AS s,\n       :top_n AS n"
    render_out = "SELECT DATEADD(day, -30, CAST('2026-09-22' AS DATE)) AS d,\n       3.0 AS p,\n       CAST(NULL AS DOUBLE) AS s,\n       100 AS n"
    b = checks_map()
    b += key("grey = file · teal = code · bold border = the guard every statement passes · dashed = generated · red dashed = failure branch")
    b += cap("the header is the single source of truth; the manifest, the registry and the lint all derive from it.")
    b += sub("Folder layout (app/queries)")
    b += table(["Folder", "Holds", "Count"], [
        [c("checks/QID.sql"), "one check; file name = <code>query_id</code> (export refuses a mismatch). <code>sf_*</code> = Snowflake-only", "302"],
        [c("common/"), "shared CTEs pasted in with <code>__INCLUDE_name__</code> (e.g. <code>cost_lines</code>, <code>sf_cs_billed_ratio</code>)", "21"],
        [c("dims/"), "name lookups: account, warehouse, task, user, database", "5"],
        [c("fallback/QID.sql"), "same check from INFORMATION_SCHEMA; 80 are <code>-- shim: yes</code> stubs, 5 hand-written", "85"],
        [c("shims/VIEW.sql"), "an ACCOUNT_USAGE view rebuilt from table functions, views or SHOW (15 with <code>each:</code>)", "52"],
        [c("tag_sources/"), "aggregates written to <code>tags_src/</code> for the tag filters", "5"],
        [c("verify/*.sql"), "paste-into-worksheet queries that recompute app figures by hand", "7 files"],
        [c("manifest.json"), "generated catalog; never hand-edited (<code>build_manifest.py --check</code>)", "1"],
    ])
    b += cite("app/queries/README.md:7-23; tools/build_manifest.py:82-123")
    b += sub("Header format (real example)")
    b += pair(payload("IN", "app/queries/checks/cost_daily_by_resource.sql:1-34 (abridged)", ex_hdr, "sql"),
              payload("OUT", "what the header becomes", json.dumps({
                  "query_id": "cost_daily_by_resource", "domain": "cost", "tier": "standard", "windowed": True,
                  "entity": {"noun": "resources", "columns": ["resource_key"]},
                  "params": [{"name": "period_days", "default": 30}, {"name": "top_n", "default": 100}],
                  "next": [{"query_id": "cost_chargeback_by_warehouse"}]}, indent=2), "json"))
    b += ul([
        "14 required fields, 7 optional; <code>tier</code> rides on the domain line (<code>lite|standard|deep</code>) " + cite("tools/header_schema.py:15-46, 61-71"),
        "<code>lint_headers.py</code>: <code>reads</code> must list every view the SQL touches, includes too; no hard-coded windows; <code>status</code> labels only OK, WARN, CRITICAL, NOT_ASSESSED " + cite("tools/lint_headers.py:41-183"),
        "<code>is_finding</code> = <code>healthy</code> not starting &quot;n/a -&quot; and the body has <code>AS status</code> " + cite("app/core/registry.py:202-204, 265-268"),
    ])
    b += sub("Includes, params, windows")
    b += ul([
        "Render order: includes pasted first, then <code>:params</code>, then <code>__PLACEHOLDERS__</code>; a leftover <code>:name</code> raises " + cite("tools/export_results.py:614-657"),
        "Param values: header default, overridden by <code>config/thresholds.yml</code> " + cite("tools/export_results.py:270-277"),
        "Windows 7, 30, 90: <code>:period_days</code> is the window; the loader accepts only 0, 7, 30, 90 " + cite("tools/load_results.py:171-178"),
        "<code>--windows 30</code> runs 7 and 30 only; the 90 label reuses the 30-day rows (alias), shown as partial in the UI " + cite("tools/common.py:24-40"),
    ])
    b += pair(payload("IN", "check text with placeholders", render_in, "sql"),
              payload("OUT", "render(days=30, as_of 2026-09-22, price 3.0, no storage price)", render_out, "sql"))
    b += cite("run on this repo: tools.export_results.render; unset storage price renders NULL, never 0")
    b += exset(
        card("ok", "Typical", [("check", "<code>:period_days</code> in body"), ("days", "30")], "<code>-30</code> pasted, as-of date cast", "tools/export_results.py:614-657"),
        card("bad", "Unknown parameter", [("check", "<code>SELECT :nope</code>"), ("params", "none")],
             "<code>ExportConfigError: unresolved parameter(s): ['nope']</code>", "run on this repo"),
        card("edge", "Missing price", [("storage price", "not set anywhere")], "<code>CAST(NULL AS DOUBLE)</code>: the $ column reads unpriced", "run on this repo"),
    )
    b += sub("Domains and counts")
    ex_ids = {k: [e["query_id"] for e in v[:3]] for k, v in manifest.items()}
    b += table(["Domain", "Checks", "First three (sorted by id)"],
               [[c(k), str(v), ", ".join(c(i) for i in ex_ids[k])] for k, v in sorted(DOMAINS.items())]
               + [["<b>total</b>", f"<b>{TOTAL}</b>", cite("app/queries/manifest.json")]])
    det = ""
    for k in sorted(manifest):
        rows = "".join(f"<tr><td><code>{esc(e['query_id'])}</code></td><td>{esc(e['title'])}</td></tr>" for e in manifest[k])
        det += f'<details><summary>{esc(k)} ({len(manifest[k])})</summary><table><tr><th>query_id</th><th>Title</th></tr>{rows}</table></details>'
    b += "<p class=\"key\">Full check list per domain (collapsed):</p>" + det
    b += sub("Fallbacks and shims")
    b += ul([
        "A fallback runs when a source is unreadable, and only if an INFORMATION_SCHEMA database is found: the session's current one, else the first non-<code>SNOWFLAKE</code> from <code>SHOW TERSE DATABASES</code> " + cite("tools/export_results.py:197-212, 1227"),
        "Shim stub: each <code>SNOWFLAKE.ACCOUNT_USAGE.V</code> is swapped for <code>__SHIM_V__</code>; a view with no shim stops the run " + cite("tools/export_results.py:120-180"),
        "Gates keep a partial answer honest: <code>MONITOR USAGE</code>, <code>MANAGE GRANTS</code>, <code>APPLY ... POLICY</code>; missing one reads <code>not_assessed</code> " + cite("tools/export_results.py:215-257"),
        "Query feed: 28 six-hour slices of <code>INFORMATION_SCHEMA.QUERY_HISTORY</code>, read once for all query fallbacks; a slice at the 10,000-row limit is not flagged " + cite("tools/export_results.py:423-454; README.md:452-453"),
        "Not covered by a fallback: 22 coverable checks left out on purpose, plus views with no equivalent (access history, tag references, org views) " + cite("README.md:426-442"),
        "Result: 85 of 302 checks have a fallback, built on 52 rebuilt views " + cite("STATUS.md:17"),
    ])
    b += exset(
        card("ok", "Shim per database", [("view", "<code>COPY_HISTORY</code>, <code>each: database</code>"), ("databases", "3")],
             "3 <code>LOAD_HISTORY</code> statements, one UNION join, one result id the checks read", "app/queries/shims/COPY_HISTORY.sql:1-5"),
        card("edge", "One database fails", [("databases", "3"), ("db 2", "error")],
             "note on the check: <em>1 of 3 (database) could not be read</em>", "tools/export_results.py:554-564"),
        card("bad", "Role lacks MONITOR USAGE", [("check", "fallback reads the METERING_DAILY_HISTORY shim"), ("privilege", "missing")],
             "<code>not_assessed</code>, never $0", "app/queries/shims/METERING_DAILY_HISTORY.sql:3"),
    )
    b += sub("Verify queries")
    b += ul([
        "7 files (<code>ai, cost, governance, pipelines, queries, storage, warehouses</code>) recompute app figures straight from <code>ACCOUNT_USAGE</code>; read-only; paste one at a time " + cite("app/queries/verify/cost.sql:1-5"),
        "Example: <code>cost.sql</code> item 1 sums <code>credits_billed</code> from <code>METERING_DAILY_HISTORY</code> plus storage TB-days and data transfer, the same total every page uses " + cite("app/queries/verify/cost.sql:7-30"),
    ])
    return section("checks", "3 · SQL checks", b)


# ================================================================= 4. loading and data model
def er_map():
    m = Map("er", 1000, 640)
    # dims row
    dims = [
        ("acc", "dim_account", "1 row per account", [("account_id", "PK"), ("name", ""), ("env", "")], 0),
        ("wh", "dim_warehouse", "1 row per warehouse", [("warehouse_id", "PK"), ("account_id", ""), ("warehouse_name", "")], 205),
        ("tk", "dim_task", "1 row per task", [("task_full_name", "PK"), ("task_id", ""), ("root_task_id", ""), ("owner_role", "")], 410),
        ("us", "dim_user", "1 row per user", [("user_name", "PK"), ("user_id", "")], 615),
        ("db", "dim_database", "1 row per database", [("database_name", "PK"), ("database_id", "")], 820),
    ]
    W = 180
    for bid, name, grain, cols, x in dims:
        rows = "".join(f'<tr><td>{n}</td><td>{"<span class=kpk>PK</span>" if k == "PK" else ""}</td></tr>' for n, k in cols)
        hgt = 52 + 22 * len(cols)
        inner = f'<div class="eh"><b>{name}</b><small>{grain}</small></div><table>{rows}</table>'
        m.box(bid, x, 0, W, hgt, inner=inner, cls="ent")
    fcols = [("window_days", "0 / 7 / 30 / 90, required"), ("account_id", "FK to dim_account"), ("warehouse_id", "FK to dim_warehouse"),
             ("task_full_name / job_id", "FK to dim_task"), ("user_name, database_name", "count bases, no id"), ("status", "OK WARN CRITICAL NOT_ASSESSED"),
             ("money column", "one headline $ (column name differs per check)"), ("is_total_row, is_alt_basis", "excluded from sums")]
    half = 4
    l = "".join(f'<tr><td>{n}</td><td style="font-family:inherit;color:#5B6068;font-size:11px">{d}</td></tr>' for n, d in fcols[:half])
    r = "".join(f'<tr><td>{n}</td><td style="font-family:inherit;color:#5B6068;font-size:11px">{d}</td></tr>' for n, d in fcols[half:])
    inner = (f'<div class="eh"><b>findings.f_&lt;query_id&gt; <span class="kfk" style="font-size:10px;border:1px solid #1F5FA8;color:#1F5FA8;padding:0 4px;border-radius:3px">296 tables</span></b>'
             f'<small>1 row per entity per window; columns differ per check (+ business columns)</small></div>'
             f'<div style="display:grid;grid-template-columns:1fr 1fr"><table>{l}</table><table>{r}</table></div>')
    m.box("f", 0, 235, 1000, 48 + 22 * half + 4, inner=inner, cls="ent")
    # keys row (bottom)
    bot = [
        ("ft", "summary.finding_tables", "1 row per findings table", [("query_id", "PK"), ("n_rows", "")], 0, 225),
        ("fc", "summary.finding_counts", "query_id x window x status", [("query_id", "PK"), ("window_days", "PK"), ("status", "PK"), ("n", "")], 258, 225),
        ("fm", "main.direct_export_findings_meta", "1 row per loaded check", [("query_id", "PK"), ("truncated", ""), ("source", "")], 516, 225),
        ("rr", "run_results.json (sidecar)", "1 entry per check", [("query_id", "PK"), ("status", "ok | failed"), ("reason", "")], 774, 226),
    ]
    for bid, name, grain, cols, x, w in bot:
        rows = "".join(f'<tr><td>{n}</td><td>{"<span class=kpk>PK</span>" if k == "PK" else k}</td></tr>' for n, k in cols)
        inner = f'<div class="eh"><b style="font-size:11.5px">{name}</b><small>{grain}</small></div><table>{rows}</table>'
        m.box(bid, x, 450, w, 52 + 22 * len(cols), inner=inner, cls="ent")
    top_bottom = 235
    for bid, name, grain, cols, x in dims:
        cx = x + W // 2
        hgt = 52 + 22 * len(cols)
        m.arrow([(cx, hgt), (cx, top_bottom)], bid, "f", dashed=True, plain_end=True, start="one", end="many")
    fb = 235 + 48 + 22 * half + 4
    for bid, name, grain, cols, x, w in bot:
        cx = x + w // 2
        m.arrow([(cx, fb), (cx, 450)], "f", bid, dashed=True, plain_end=True, start="one", end="many" if bid == "fc" else "one")
    lab = {"acc": "account_id", "wh": "warehouse_id", "tk": "task_full_name", "us": "user_name", "db": "database_name"}
    for bid, name, grain, cols, x in dims:
        m.lbl(x + W // 2, 205, lab[bid], True)
    for bid, name, grain, cols, x, w in bot:
        m.lbl(x + w // 2, 395, "query_id", True)
    return m.render()


def sec_model():
    b = sub("Load: folder to DuckDB")
    b += steps([
        ("Pick source and target", "no SRC: newest <code>results/STAMP</code>; no <code>--db</code>", "<code>&lt;data dir&gt;/audit.duckdb</code>"),
        ("Refuse unsafe input", "db inside repo, zip entry with <code>..</code> or <code>:</code>", "exit 2 / entry refused"),
        ("Read manifest.json (the run record)", "findings, <code>max_rows</code>, <code>dims.available</code>, <code>window_aliases</code>", "no manifest: import mode, every parquet is <code>ok</code>"),
        ("Build into <code>audit.duckdb.tmp</code>", "per check: <code>ok</code> or <code>empty</code>", "<code>findings.f_QID</code>; ids must match <code>[a-z][a-z0-9_]*</code>"),
        ("Validate window_days", "column present, value in 0, 7, 30, 90", "else that check is failed (45: &quot;window_days must be 0, 7, 30 or 90&quot;)"),
        ("Alias windows", "30-day export", "90 rows = copy of the 30 rows"),
        ("summary, dims, tags, meta", "row counts cross-checked", "mismatch aborts the whole load"),
        ("Swap", "close, delete <code>.wal</code>", "<code>os.replace(tmp, db)</code>; sidecar + <code>current_db.txt</code>"),
    ])
    b += cite("tools/load_results.py:457-708, 171-178, 426-453, 671-683; tests/test_load_results.py:270-281, 318-328")
    b += sub("Data model (DuckDB, app side)")
    b += er_map()
    b += key("card = table · subtitle = grain · <b>PK</b> primary key · dashed line = logical key, not enforced (no foreign key is declared) · ‖ = one · crow's foot = many · chip = key column")
    b += cap("findings carry ids, never names; the dims turn ids into <code>name (id)</code> at read time.")
    b += ul([
        "No foreign key is declared; every join is logical " + cite("tools/load_results.py:531-532, 567, 603, 614"),
        "Standalone: <code>tags.*</code> (8 tables: <code>tag_account</code>, <code>tag_entity</code>, <code>tag_index</code>, <code>cost_unit</code>, <code>cost_unit_tag</code>, <code>cost_reconciliation</code>, <code>perf_unit</code>, <code>perf_unit_tag</code>) are built by <code>tools/build_tags.py</code>; tag columns are copied into <code>dim_account</code>",
        "Grain changes per check: one row per warehouse, per task, per day and so on; read each check's <code>entity:</code> header line",
        "A missing dim becomes an empty stub, so the id shows instead of the name " + cite("tools/load_results.py:42-58, 613-614"),
    ])
    b += sub("Object | Grain | Key | Written by")
    b += table(["Object", "Grain", "Key", "Written by"], [
        [c("findings.f_<qid>"), "one row per entity per window (0 / 7 / 30 / 90)", "<code>window_days</code> + entity ids", "load_results.py " + cite(":548-579")],
        [c("dims.dim_account"), "1 row per account", "<code>account_id</code>", "load_results.py + env + tag columns " + cite(":353-380, 599-600")],
        [c("dims.dim_warehouse"), "per warehouse id, 400 days of metering", "<code>warehouse_id</code>", "export dim " + cite("dims/dim_warehouse.sql:1-6")],
        [c("dims.dim_task"), "per task, latest version", "<code>task_full_name</code>", "export dim " + cite("dims/dim_task.sql:1-11")],
        [c("dims.dim_user"), "per user (live)", "<code>user_name</code>", "export dim " + cite("dims/dim_user.sql:1-4")],
        [c("dims.dim_database"), "per database (live)", "<code>database_name</code>", "export dim " + cite("dims/dim_database.sql:1-4")],
        [c("main.direct_export_meta"), "1 row per load", "none", "load_results.py " + cite(":632-656")],
        [c("main.direct_export_findings_meta"), "1 row per loaded check", "<code>query_id</code>", "load_results.py " + cite(":658-670")],
        [c("<stem>.run_results.json"), "1 entry per check: ok / failed + reason", "<code>query_id</code>", "load_results.py " + cite(":282-303")],
    ])
    b += sub("View | Built from | Rows")
    b += table(["View (derived)", "Built from", "Rows (test DB)"], [
        [c("summary.finding_counts"), "GROUP BY over every findings table " + cite("tools/load_results.py:442-445"), "1,401 (query x window x status)"],
        [c("summary.finding_tables"), "count(*) per findings table " + cite("tools/load_results.py:446-447"), "296"],
        [c("tags.*"), "<code>tags_src/*.parquet</code> via <code>build_tags.build</code>; <code>tags_src</code> dropped after " + cite("tools/build_tags.py:96-362"), "8 tables"],
    ])
    b += exset(
        card("ok", "Join id to name", [("finding", "<code>warehouse_id '1001'</code> CRITICAL, 30 d"), ("dim", "<code>('1001', 'WH_ETL')</code>")],
             "cell <code>WH_ETL (1001)</code>; top row <code>est_wasted_usd_list 9046.8</code>", "run on tests/db_audit_test.duckdb (fake data, tests/fake_snowflake/data.py:168)"),
        card("edge", "Dim missing", [("finding", "<code>warehouse_id '1001'</code>"), ("dim", "not exported: empty stub")],
             "cell shows the id only", "tools/load_results.py:788-791"),
        card("bad", "Bad check id", [("file", "<code>x&quot;; DROP TABLE y; --.parquet</code>")], "recorded as missing file, never spliced into SQL", "tests/test_load_results.py:337-341"),
    )
    return section("model", "4 · Loading and data model", b)


# ================================================================= 5. backend
def req_map():
    m = Map("req", 1000, 150)
    w, h, g = 130, 90, 44
    xs = [i * (w + g) for i in range(6)]
    labels = [("rq", "Browser", "web/src/api.ts", "actor"), ("mw", "Middleware", "_cache_read_only", "routine"),
              ("rt", "Route", "get_finding app.py:926", "routine entry"), ("sv", "service.py", "load_outcome", "routine"),
              ("da", "data.py", "read_finding", "routine"), ("fx", "DuckDB", "findings.f_QID", "data")]
    for (bid, t, s, cl), x in zip(labels, xs):
        m.box(bid, x, 25, w, h, t, s, cl)
    for i in range(5):
        m.arrow([(xs[i] + w, 70), (xs[i + 1], 70)], labels[i][0], labels[i + 1][0], dashed=(i == 4))
        m.num(xs[i] + w + g // 2, 52, i + 1)
    return m.render()


def sec_backend():
    b = req_map()
    b += key("pill = browser · teal = code · grey = data · numbers = order · dashed = data moves")
    b += cap("routes hold no logic of their own; the outcome and every number come from <code>service.py</code> and <code>data.py</code>.")
    b += steps([
        ("Browser calls the API", "<code>GET /api/finding/sf_wh_idle_minutes?window=30</code>", "request"),
        ("Cache middleware", "path under <code>/api/finding/</code>, <code>/api/rollup</code>, <code>/api/tags/</code>", "hit: body by <code>(data_stamp, path, query)</code>"),
        ("Route validates", "<code>window=45</code>", "422 (window must be 7, 30 or 90)"),
        ("service.load_outcome", "id, window, filters", "one of <code>not_assessed, error, ok_empty_window, ok_empty_filters, ok_rows</code>"),
        ("data.read_finding", "WHERE built from bound params; effective status", "rows page, <code>rows_total</code>, <code>floor</code>"),
        ("DuckDB read-only connection", "one shared connection per file identity", "rows from <code>findings.f_sf_wh_idle_minutes</code>"),
    ])
    b += cite("app/api/app.py:126-200, 1003-1148; app/api/service.py:277-425; app/core/data.py:120-164, 688-793")
    b += sub("Important endpoints (37 routes: 29 in app.py, 2 in explorer.py, 5 in access_log.py, 1 in guide.py)")
    b += table(["Method", "Path", "Returns", "Where"], [
        ["GET", c("/api/status"), "<code>{state, settings_error, database, brand}</code>; state = settings_invalid, no_database, build_incomplete, ready. Never raises", cite("app.py:445-472")],
        ["GET", c("/api/meta"), "as_of, windows, discount, price_basis, edition, <code>cost_cutoff</code>, <code>checks_ran</code>", cite("app.py:494-557")],
        ["GET", c("/api/findings"), "one row per check: outcome, status_counts, money, affected, not_assessed, floor", cite("app.py:870-908")],
        ["GET", c("/api/finding/{query_id}"), "outcome-specific body: rows page, empty-window, empty-filters, status_info or error", cite("app.py:926-1071")],
        ["GET", c("/api/finding/{id}/aggregate"), "server-side sum / count over every matching row, grouped; raw <code>total_value</code>", cite("app.py:1082-1214")],
        ["GET", c("/api/finding/{id}/rows.csv"), "every row (cap 1,000,000); 409 when not assessed", cite("app.py:1252-1298")],
        ["GET", c("/api/coverage"), "per-source state, <code>checks_not_ok</code>, visibility, edition", cite("app.py:680-719")],
        ["GET", c("/api/rollup"), "nested cost/perf tree for one tag key, with reconciliation", cite("app.py:744-774")],
        ["GET", c("/api/access/explore"), "grants with every path, roles reached, holders", cite("explorer.py:209-245")],
        ["GET", c("/api/access/log"), "one object: queries per day or hour, and who used it (user, role, client, statement types, off-hours); <code>truncated</code> when the export cut the log", cite("access_log.py:105-124")],
        ["GET", c("/api/access/tag"), "one tag value: its objects, who can read each (grant paths) and who queried it, from one grouped scan", cite("access_log.py:157-198")],
        ["GET", c("/api/guide"), "Guide feed: every check's prose, params, columns, grants, traps", cite("guide.py:506-564")],
        ["GET/PUT", c("/api/settings/{cost-center,privacy,required-tags}"), "PUT writes <code>config/settings.local.yml</code>", cite("app.py:349-436")],
        ["POST", c("/api/refresh"), "one background export + load into a new db file; second call returns the running state", cite("app.py:485-488; refresh.py:32-39")],
    ])
    b += "<p class=\"key\">Other routes: <code>/api/accounts</code>, <code>/api/dims</code>, <code>/api/warehouses</code>, <code>/api/databases</code>, <code>/api/tags</code>, <code>/api/tags/compliance</code>, <code>/api/guide/sql/{id}</code>, <code>/api/access/names</code>, <code>/api/access/log/objects</code>, <code>/api/access/log/offhours</code>, <code>/api/access/tags</code>, <code>/api/rollup/keys</code>.</p>"
    b += sub("Access log, off-hours use and the tag explorer")
    b += ul([
        "<code>sf_use_access_log</code> runs once over 90 days of <code>ACCESS_HISTORY</code> and keeps one row per object x user x role x client x day (hour with <code>grain: hour</code> in config/thresholds.yml), with read, write and DDL query counts, statement types and DDL operations. No query text " + cite("app/queries/checks/sf_use_access_log.sql"),
        "The aggregation runs in Snowflake; the API only slices the DuckDB table to the window (<code>[as_of - window, as_of)</code>) and one object, so a page never loads the log whole " + cite("app/api/access_log.py:38-56"),
        "A check may declare <code>:row_cap</code>; the log keeps up to 1,000,000 rows, newest first, and the page says from when counts are complete when the cap was reached " + cite("tools/export_results.py; app/api/access_log.py:45-56"),
        "Off hours: outside <code>business_start_hour</code>–<code>business_end_hour</code> in <code>business_tz</code>, or at weekends; only users whose TYPE is PERSON are flagged",
        "The tag explorer joins <code>sf_gov_tag_objects</code> (direct tags on databases, schemas, tables, columns) with the grant walk of explorer.py (who can read) and the log (who did), in one grouped scan " + cite("app/api/access_log.py:157-198"),
        "<code>sf_gov_sensitive_suggestions</code> matches column names (never values) to Snowflake's semantic categories; <code>sf_gov_file_downloads</code> lists GET and unloads per user and stage. Result downloads from Snowsight or drivers are not logged by Snowflake",
    ])
    b += sub("Core modules")
    b += table(["Name", "Does", "Example"], [
        [c("data.py"), "every DuckDB read: filters pushed into SQL as bound params, money, cut-off, checks-ran", "<code>sf_wh_idle_minutes</code>, 30 d: <code>money.usd 13827.6</code>"],
        [c("service.py"), "the five outcomes, findings list, storage overlap", "unknown id: <code>QueryNotFoundError</code>, 404"],
        [c("materiality.py"), "floors and the report severity cap, one SQL expression for every status read", "WARN of $5 under a $50 floor reads OK"],
        [c("finding_columns.py"), "which column is the money, which kind", "<code>[&quot;est_wasted_usd_list&quot;, &quot;est_compute_usd_list&quot;]</code> gives waste"],
        [c("reasons.py"), "error text to reason code to GRANT line", "&quot;no such view&quot; gives <code>view_missing</code>"],
        [c("pricing.py"), "discount what-if on list-price columns only", "<code>est_usd_list 100</code> at 15% gives <code>est_usd_list_disc 85.0</code>"],
        [c("identity.py / masking.py"), "on-screen and export-time masking", "<code>person@example.com</code> gives <code>542d2401 pe***</code>"],
        [c("registry.py"), "manifest to <code>QuerySpec</code>; checks every <code>reads</code> view is known", "view not in <code>SOURCE_CONTRACT</code>: <code>RegistryError</code>"],
        [c("rollup.py / tags.py / tag_compliance.py"), "nested tag rollup, tag filters, required-tag coverage", "work tag, then compute tag, then account tag: first real value wins"],
        [c("datasource.py / config.py"), "data folder, pointer file, settings with line-numbered errors", "bad key <code>default_windw</code>: state <code>settings_invalid</code>, line 2"],
    ])
    b += "<p class=\"key\">Other helpers: <code>explorer.py</code>, <code>access_log.py</code> (the access log and the tag explorer, read through the API, never whole), <code>guide.py</code>, <code>refresh.py</code>, <code>app/core/envmap.py</code>, <code>cost_center.py</code>, <code>tag_keys.py</code>. Examples run on this repo or from tests/test_materiality.py:172-218, tests/test_api.py:228-273.</p>"
    b += cite("modules/core.md in the knowledge graph; app/core/*.py")
    return section("backend", "5 · Backend", b)


# ================================================================= 6. money and number rules
def price_map():
    m = Map("px", 1000, 150)
    ws = [130, 165, 215, 140, 130]
    g = 55
    xs = [sum(ws[:i]) + g * i for i in range(5)]
    h = 100
    spec = [("c1", "CLI flag", "--credit-price 4.0", "entry", "ENTRY"), ("c2", "RATE_SHEET_DAILY", "latest effective_rate", "data", "DATA"),
            ("c3", "USAGE_IN_CURRENCY_DAILY", "90-day usage / credits", "data", "DATA"), ("c4", "settings.yml", "3.0 credit, 2.0 AI", "data", "DATA"),
            ("c5", "NULL = unpriced", "never $0", "fail", "")]
    for (bid, t, s, cl, tg), x, w in zip(spec, xs, ws):
        m.box(bid, x, 30, w, h, t, s, cl, tg)
    labs = ["unset", "no row", "denied", "empty"]
    for i in range(4):
        m.arrow([(xs[i] + ws[i], 80), (xs[i + 1], 80)], spec[i][0], spec[i + 1][0])
        m.lbl(xs[i] + ws[i] + g // 2, 62, labs[i], False)
    return m.render()


def sec_money():
    b = price_map()
    b += key("each price (credit, AI credit, storage) walks this chain on its own · first source with a value wins · red dashed = no price")
    b += cap("storage skips the rate sheet; a missing price shows as unpriced, never $0.")
    b += ul([
        "Data transfer $/TB (same cloud, other cloud) comes from the <code>sf_cost_data_transfer_egress</code> params, default 20 and 90 " + cite("tools/export_results.py:280-283, 631-632"),
        "The Overview total reads – when any line with usage has no rate (e.g. archive storage), never a partial sum " + cite("app/queries/checks/overview_spend_estimate.sql"),
        "Prices are fixed once per export and pasted as literals (<code>__CREDIT_PRICE__</code>), so a price is never joined and never counted twice " + cite("tools/export_results.py:614-628, 821-873"),
        "Settings defaults: credit $3.00, AI credit $2.00, storage empty " + cite("config/settings.yml:20-22"),
        "Invoice storage rate is per TB-day, multiplied by 30.4 " + cite("tools/export_results.py:53, 860-862"),
        "Prices from the rate sheet or invoice are <code>invoice_derived</code>: the discount what-if does not apply to them " + cite("app/core/data.py:2197-2226"),
    ])
    b += sub("1 · Pricing order")
    b += exset(
        card("ok", "Invoice readable", [("CLI price", "none"), ("compute", "3.0 per credit"), ("storage", "0.75 per TB-day")],
             "credit <code>3.0</code> (usage_in_currency_daily); storage <code>0.75 x 30.4 = 22.8</code>", "tests/test_export_more.py:104-110"),
        card("edge", "CLI price wins, per price", [("--credit-price", "4.0")], "credit <code>4.0</code> (cli); storage still from invoice", "tests/test_export_more.py:113-118"),
        card("edge", "Invoice denied", [("settings", "credit 2.5, storage 21.0"), ("org view", "error 2003")], "<code>2.5</code> and <code>21.0</code> source <code>settings</code>", "tests/test_export_more.py:128-130"),
        card("bad", "Nothing anywhere", [("CLI, invoice, settings", "all empty")], "<code>credit_price_usd = None</code>; $ columns empty, export warns", "tests/test_export_more.py:133-139"),
    )
    b += sub("2 · Cloud-services adjustment")
    b += ul([
        "Each day, cloud services up to 10% of that day's warehouse compute are free; the rest is billed " + cite("app/queries/common/sf_cs_billed_ratio.sql:1-11"),
        "Billed = compute + cloud services x <code>billed_ratio</code>, ratio per day = <code>max(cs + adj, 0) / cs</code>; a day with no row reads 1",
        "Every money check reads <code>common/cost_lines.sql</code>, so totals agree across pages " + cite("app/queries/common/cost_lines.sql:1-20"),
    ])
    b += exset(
        card("ok", "Typical day", [("compute", "100 credits"), ("cloud services", "15"), ("adjustment", "-10")],
             "billed <code>105</code> credits; ratio <code>(15-10)/15 = 0.333</code>; at $3.00 cloud part = $15", "rule as in tests/fake_snowflake/data.py:938-942"),
        card("edge", "Cloud services under 10%", [("compute", "100"), ("cloud services", "8"), ("adjustment", "-8")],
             "billed <code>100</code>; ratio <code>0</code>; derived from <code>-LEAST(day_cloud, 0.1 x day_compute)</code>", "app/queries/shims/METERING_DAILY_HISTORY.sql:6-10"),
        card("edge", "Day with no daily row", [("METERING_DAILY_HISTORY", "no row that day")], "ratio reads <code>1</code>: nothing taken off", "app/queries/common/sf_cs_billed_ratio.sql:3"),
    )
    b += sub("3 · Spend, change and waste are never added")
    b += ul([
        "A check's headline $ is one column with one kind: spend, change, context, balance (all rows) or waste, saving, gap (flagged rows only) " + cite("app/core/finding_columns.py:15-152"),
        "Waste counts only rows that still read WARN or CRITICAL after the materiality floor " + cite("app/core/data.py:1110-1187"),
        "<code>blank_unflagged_waste</code> nulls waste columns on rows that are not WARN or CRITICAL, in the export itself " + cite("tools/common.py:68-85"),
        "No route returns a cross-kind total: each check's money carries its own kind " + cite("app/core/data.py:1178-1182"),
        "<code>unpriced_rows</code> counts rows with no figure; the checks list shows \"N without a figure\" " + cite("app/core/data.py:1181")
    ])
    b += exset(
        card("ok", "Waste on a real check", [("check", "<code>sf_wh_idle_minutes</code>, 30 d"), ("rows", "4 CRITICAL, 1 WARN, 7 NOT_ASSESSED")],
             "<code>money {kind: waste, basis: flagged, usd: 13827.6}</code>", "run on tests/db_audit_test.duckdb through GET /api/findings"),
        card("edge", "Unflagged rows blanked", [("status", "[OK, WARN, NOT_ASSESSED, CRITICAL]"), ("est_saving_usd_list", "[5, 6, 7, 8]")],
             "<code>[None, 6, None, 8]</code>; <code>est_compute_usd_list</code> untouched (spend is not waste)", "tests/test_export_show.py:152-157"),
        card("edge", "Change only", [("columns", "change_usd_list, usd_list")], "headline = <code>change_usd_list</code>, kind change; never change + current", "tests/test_waste_contract.py:77-86"),
        card("bad", "Unpriced", [("credit price", "none")], "<code>usd: null</code>, <code>money_reason: unpriced</code>; never 0.0", "app/core/data.py:1159-1169"),
    )
    b += sub("4 · NOT_ASSESSED versus empty")
    b += table(["Outcome", "When (checked in this order)", "Screen"], [
        [c("not_assessed"), "run results say failed; window never exported; table missing; tag tables missing under a tag filter", "&quot;–&quot; and why"],
        [c("error"), "other DuckDB or OS failure", "error card"],
        [c("ok_empty_window"), "the window alone has 0 rows", "&quot;No data for this in &lt;range&gt;&quot;"],
        [c("ok_empty_filters"), "rows exist, filters exclude all", "&quot;No data (filtered)&quot;"],
        [c("ok_rows"), "otherwise", "table"],
    ])
    b += cite("app/api/service.py:277-425")
    b += exset(
        card("ok", "Edition too low", [("export error", "&quot;SQL compilation error: no such view 'ACCOUNT_USAGE.ICEBERG_TABLES' in this account&quot;")],
             "<code>view_missing</code>; on a known Standard account for an Enterprise check: <code>edition_too_low</code>", "run: reasons.classify_error; app/core/data.py:1872-1881"),
        card("edge", "Access denied", [("export error", "&quot;SQL access control error: Insufficient privileges to operate on view 'ORGANIZATION_USAGE.ACCOUNTS'&quot;")],
             "<code>no_access</code>; fix: <code>GRANT DATABASE ROLE SNOWFLAKE.ORGANIZATION_USAGE_VIEWER TO ROLE &lt;audit_role&gt;</code>", "tests/fixtures/build_fixtures.py:46-48"),
        card("edge", "Timeout", [("export error", "&quot;Statement reached its statement or warehouse timeout&quot;")], "<code>timeout</code>: re-run with a shorter window", "run: reasons.classify_error"),
        card("edge", "Half the warehouses unseen", [("role sees", "6 of 12 billed warehouses")], "7 rows NOT_ASSESSED in <code>sf_wh_idle_minutes</code>, not zero", "app/core/data.py:2274-2300"),
    )
    b += sub("5 · One cut-off, today partial, one count")
    b += ul([
        "<code>as_of_date</code> is the first day left out; the last complete day is the day before, capped by <code>last_complete_day</code> " + cite("app/core/data.py:2149-2183"),
        "Today is shown as partial (<code>partial_day</code>, <code>partial_until</code>), never as a full day",
        "One &quot;checks that ran&quot; count, the same object in <code>/api/meta</code>, <code>/api/findings</code>, <code>/api/coverage</code> " + cite("app/core/data.py:2245-2266"),
        "A 90-day pick on a 30-day export reads &quot;30 (the export covered 30 of the 90 days you picked)&quot;, and the 90 total equals the 30 total " + cite("tests/test_totals_agree.py:71-82")
    ])
    b += exset(
        card("ok", "Test DB, today off", [("as_of", "2026-09-21T12:00:00Z")], "<code>data_through 2026-09-20</code>, <code>partial_day null</code>", "run via GET /api/meta; tests/test_totals_agree.py:85-87"),
        card("edge", "Today on (illustrative)", [("as_of_date", "2026-11-11"), ("as_of", "2026-11-10T09:30Z"), ("last_complete_day", "2026-11-08")],
             "<code>data_through 2026-11-08</code>, <code>partial_day 2026-11-10</code>, <code>partial_until 09:30</code> (traced by hand)", "derived from app/core/data.py:2149-2183"),
        card("ok", "Checks that ran", [("test DB", "302 checks")], "<code>ran 293</code>, <code>not_ran {build_failed: 2, all_rows_not_assessed: 7}</code>", "run via GET /api/meta"),
    )
    b += sub("6 · Materiality floor and discount")
    b += exset(
        card("ok", "Above the floor", [("floor", "est_wasted_usd_list &lt; 10"), ("row", "CRITICAL, $264")], "stays <code>CRITICAL</code>, <code>below_floor false</code>", "tests/test_materiality.py:172-218"),
        card("edge", "Below the floor", [("row", "CRITICAL, $5")], "reads <code>OK</code>, <code>below_floor true</code>; exported <code>status</code> never rewritten", "tests/test_materiality.py:172-218"),
        card("edge", "USD floor is per 30 days", [("floor", "$50"), ("row", "$30")], "30 d: <code>OK</code>; 7 d: still <code>CRITICAL</code> (30 &gt; 50 x 7/30 = 11.67)", "tests/test_materiality.py:132-151"),
        card("edge", "Discount on invoice price", [("discount_pct", "0.2"), ("price source", "usage_in_currency_daily")], "effective discount <code>0.0</code>, <code>ignored: true</code>; with source <code>cli</code>: 0.2", "tests/test_api_features.py:239-251"),
    )
    return section("money", "6 · Money and number rules", b)


# ================================================================= 7. UI
TABS = [
    ("Overview", []), ("Actions", []),
    ("Cost", ["trend", "service", "who", "chargeback", "before", "contract", "budgets"]),
    ("Waste & savings", ["priced", "unpriced", "method"]),
    ("Warehouses", ["idle", "sizing", "load"]), ("Serverless", ["feature", "clustering", "mvso"]),
    ("Queries", ["heavy", "efficiency", "failures", "waiting", "team", "trend"]),
    ("Tasks & pipelines", ["failures", "cost", "hygiene", "dynamic"]), ("Data loading", ["pipes", "copy"]),
    ("AI & apps", ["cortex", "apps", "serving"]),
    ("Access", ["roles", "users", "perimeter", "explorer"]), ("PII & policies", ["sensitive", "policies", "reads", "tags", "quality"]),
    ("Lineage", ["dependencies", "explorer"]), ("Activity", ["databases", "schemas", "tables", "lastactive", "accesslog", "users", "objects"]),
    ("Audit", ["admins", "changes"]), ("Sharing & org", ["shares", "accounts", "spend", "replication"]),
    ("Storage", ["growth", "unused", "retention", "backups"]), ("All findings", []), ("Coverage & gaps", ["sources", "couldnt", "limits"]),
]


def sec_ui():
    n_sub = sum(len(s) for _, s in TABS)
    grid = '<div class="tabmap">' + "".join(
        f'<div class="tab"><b>{esc(t)}</b><span>{" · ".join(esc(x) for x in s) if s else "no sub-tabs"}</span></div>' for t, s in TABS) + "</div>"
    b = grid
    b += key(f"{len(TABS)} top-level tabs, {n_sub} sub-tabs counted from <code>key:</code> entries in tab_registry.tsx")
    b += cap("the registry decides which checks each sub-tab owns; a check has one home.")
    b += ul([
        f"{len(TABS)} tabs and {n_sub} sub-tabs " + cite("web/src/components/tab_registry.tsx:470-502"),
        "<code>AREA_REGISTRY</code> maps each area to sub-tabs and their check ids; <code>QUERY_HOME</code> sends a cross-area jump to a check's home " + cite("tab_registry.tsx:561-575"),
        "State lives in the URL hash as plain <code>key=value</code> pairs: <code>tab</code>, <code>subtab</code>, <code>focus</code>, <code>role</code>, window, filters. Writes use <code>replaceState</code>, so no history entries " + cite("web/src/components/hash_state.tsx:9-45"),
        "Org sub-tabs hide when none of their checks ran " + cite("tab_registry.tsx:544-556"),
        "Every area page: overview with charts first, then <code>ChecksList</code>; a row opens the drawer, which pages through every row and downloads CSV " + cite("web/src/components/drawer.tsx:86"),
    ])
    b += sub("View as: five lenses")
    b += table(["Lens", "Home", "Rail groups"], [
        ["CFO", c("money"), "Explore: cost, chargeback &amp; tags, contract, budgets, waste"],
        ["FinOps", c("overview"), "Spend, Waste, Reference"],
        ["Data engineer", c("overview"), "Pipelines, Queries &amp; compute, Cost"],
        ["Governance", c("overview"), "Access, Data, Trail"],
        ["CTO", c("overview"), "Cost, Reliability, Performance, Security"],
    ])
    b += "<p class=\"key\">A lens is a persona, never a permission: every lens reads the same data " + cite("web/src/App.tsx:111-148; web/src/components/lens_nav.ts:20-57") + "</p>"
    b += sub("Build into app/web/dist")
    b += ul([
        "Vite builds <code>web/</code> into <code>app/web/dist</code>, committed so users need no Node " + cite("web/vite.config.ts:41-47"),
        "<code>dist/source-hash.txt</code> = sha256 over every tracked file under <code>web/</code>; a test fails when the build is stale " + cite("tests/test_build_web.py:33-38"),
        "Order: commit <code>web/</code> source, then <code>npm run build</code>, then commit <code>app/web/dist</code> " + cite("CLAUDE.md; web/vite.config.ts:11-38"),
        "FastAPI mounts <code>dist</code> last at <code>/</code>, so it never shadows <code>/api/*</code>; no build gives a 404 text with the fix " + cite("app/api/app.py:1418-1466"),
    ])
    b += sub("Number rules the UI enforces")
    b += table(["Rule", "Example"], [
        ["A check that did not run shows &quot;–&quot; and why, never $0", "<code>sf_org_dormant_accounts</code>: &quot;the role can't see it&quot; + the GRANT line"],
        ["Counts name their unit", "&quot;12 of 48 warehouses&quot;, &quot;293 of 302 checks&quot;"],
        ["Loading shows &quot;…&quot;, never interim values", "all tiles wait for the findings call"],
        ["Empty window", "&quot;No data for this in 16–22 Sep 2026&quot;"],
    ])
    b += cite("CLAUDE.md (Numbers on screen); web/src/components/format.tsx:43-44 (see risks)")
    return section("ui", "7 · UI", b)


# ================================================================= 8. masking
def sec_masking():
    b = table(["Switch", "Where", "Default", "Takes effect"], [
        [c("privacy.mask_user_identities"), "on screen: user names and emails at API output time (<code>identity.py</code>)", "false", "next page refresh"],
        [c("privacy.mask_fields / --mask"), "in the export: chosen kinds of names to salted tokens before any file is written (<code>masking.py</code>)", "[] (nothing)", "next export or Refresh"],
    ])
    b += cite("config/settings.yml:43-48; app/core/identity.py:38-40; app/core/masking.py:1-22")
    b += ul([
        "Kinds: user, warehouse, database, schema, object, role, task, account, or <code>all</code> " + cite("masking.py:33, 111-122"),
        "Token = prefix + 8 hex of <code>sha256(salt|kind|lower(name))</code>; the same name gets the same token in every file; the salt is random per export and never written " + cite("masking.py:168-184"),
        "System names (<code>SNOWFLAKE</code>, <code>PUBLIC</code>, <code>ACCOUNTADMIN</code>, ...), ids and numbers are never masked " + cite("masking.py:98-106"),
        "Never masked by default: names are the product's value " + cite("CLAUDE.md"),
        "Anyone with the Streamlit app sees all data in the file whatever their role; export with <code>--mask</code> " + cite("README.md:534-535"),
    ])
    b += exset(
        card("ok", "On-screen user", [("value", "<code>person@example.com</code>")], "<code>542d2401 pe***</code> (8 hex + first 2 chars); masking it again returns the same string", "run: identity.format_identity; tests/test_identity_masking.py:43-48"),
        card("ok", "Export, kinds all", [("warehouse_name", "<code>ETL_WH</code>"), ("grantee (ROLE)", "<code>LOADER</code>")], "<code>wh_xxxxxxxx</code>, <code>role_xxxxxxxx</code>; same token across files", "tests/test_masking.py:41-72"),
        card("edge", "Free text", [("reasons", "<code>ETL_WH idle for role LOADER on SALES</code>")], "<code>&lt;wh&gt; idle for role &lt;role&gt; on &lt;db&gt;</code>", "tests/test_masking.py:41-72"),
        card("bad", "Unknown kind", [("--mask", "<code>warehouse,colour</code>")], "<code>ValueError: unknown mask kind</code>", "tests/test_masking.py:28-33"),
    )
    b += ul([
        "Privacy of the data at rest: query text, SQL literals, secrets and policy bodies are never stored " + cite("CLAUDE.md"),
        "Repo rule: no customer, account, user or warehouse names in the repo; the fake account is <code>FAKE01</code> " + cite("tests/fake_snowflake/data.py:25-28"),
    ])
    return section("masking", "8 · Masking and privacy", b)


# ================================================================= 9. traps
def sec_traps():
    rows = [
        ["Price joined twice", "price is a pasted literal; org checks reduce the rate to one row per account first", "tools/export_results.py:614-628; sf_org_warehouse_spend_across_accounts.sql:62-77"],
        ["Units added together", "credits, TB, $ in separate columns; money kinds never summed", "common/cost_lines.sql:4-9; app/core/finding_columns.py:15-56"],
        ["Days with zero usage skipped", "GENERATOR day spine in 9 checks (partly)", "checks/cost_daily_spikes.sql:47-65"],
        ["Two &quot;todays&quot;", "one as-of date pasted as <code>__AS_OF_DATE__</code>", "tools/export_results.py:614-623, 1037-1041"],
        ["Cloud services 10% adjustment", "billed ratio per day from METERING_DAILY_HISTORY", "common/sf_cs_billed_ratio.sql:1-12"],
        ["Attribution is not a total", "idle time and sub-100 ms queries accounted separately; NULL on adaptive warehouses", "checks/sf_cost_warehouse_idle_credits_daily.sql:28-65; common/sf_chg_query_credits.sql:1-30"],
        ["Role sees only part", "probe every view; NOT_ASSESSED with the GRANT; billed vs SHOW-listed warehouse count", "tools/export_results.py:955-1002, 1211-1266"],
        ["Fail-safe tables have NULL names", "live-table include filters them; dropped-not-purged reads them on purpose", "common/sf_storage_live_tables.sql:25-28; checks/sf_storage_dropped_not_purged.sql:41-68"],
        ["POLICY_REFERENCES misses session, password, auth policies", "use SHOW AUTHENTICATION / PASSWORD POLICIES (needs APPLY grants)", "checks/sf_secx_session_policy_coverage.sql:13-14; sf_secx_password_policy_posture.sql:6-22"],
        ["TABLE_ID vs BASE_TABLE_ID rename", "read both while the rename rolls out", "checks/sf_storage_search_optimization_value.sql:38-46"],
        ["Org billing lag up to 72 h", "<code>:settle_days</code> on org checks; not applied in the export's own price lookup", "checks/sf_org_warehouse_spend_across_accounts.sql:41-69"],
        ["View missing / edition too low", "NOT_ASSESSED with reason, never &quot;nothing found&quot;", "tools/export_results.py:1235-1308; app/core/reasons.py:36-122"],
    ]
    b = table(["Trap", "How handled", "Where"], [[a, b_, cite(c_)] for a, b_, c_ in rows])
    b += "<p class=\"key\">Handling status is the knowledge graph's reading of the code; the zero-usage-days defence is partial (9 checks).</p>"
    return section("traps", "9 · Snowflake traps handled", b)


# ================================================================= 10-11
def sec_decisions():
    b = table(["Decision", "Why"], [
        ["Read-only on Snowflake: one SELECT, WITH or SHOW per statement, checked before every call", "an audit tool must not be able to change the account"],
        ["Probe every view with <code>LIMIT 0</code> before running checks", "an unreadable view must read NOT_ASSESSED, not empty"],
        ["Export to a folder, load to DuckDB, serve from the file", "the app never needs a Snowflake connection; the folder can be moved as a zip"],
        ["Build into <code>.tmp</code>, swap with <code>os.replace</code>", "a failed export or load never leaves a half result under the final name"],
        ["Findings store ids; names come from dims at read time", "names can change or be masked without rewriting findings"],
        ["Prices fixed once per export as literals", "one rate per line, so the same $ appears on every page"],
        ["Status and waste computed at read time with floors and caps", "exported <code>status</code> stays raw; thresholds change without a re-export"],
        ["One shared read-only DuckDB connection per file", "fast reads; a Refresh writes a new file instead of replacing the open one"],
        ["URL hash holds all view state", "any view is a pasteable link"],
        ["<code>app/web/dist</code> and <code>tools/export_kit</code> are committed and test-checked", "users run from a GitHub zip with no Node"],
        ["Fallbacks via INFORMATION_SCHEMA shims behind privilege gates", "a limited role still gets answers, never a silent partial one"],
    ])
    return section("decisions", "10 · Key design decisions", b)


def sec_risks():
    b = table(["#", "Risk or limitation", "Impact", "Where"], [
        ["1", "The test DB fills a check whose SQL fails on the fake account with placeholder rows", "tests can pass on a broken check; read <code>smoke_failed</code> or run <code>tools/sql_smoke.py</code> and expect 0 failed", cite("tests/fixtures/build_fixtures.py:160-171")],
        ["2", "Admin MFA reads <code>USERS</code> only, not <code>CREDENTIALS</code> (passkey, TOTP)", "an admin with only a passkey or TOTP can read as no MFA; the fallback has no CREDENTIALS stand-in", cite("app/queries/checks/sf_sec_admin_role_holders.sql")],
        ["3", "Streamlit in Snowflake has never run in Snowflake", "packages, DuckDB, the security policy and warehouse-runtime custom components may be disallowed", cite("STATUS.md:22")],
        ["4", "No role sees everything: SHOW lists only what the role can monitor", "billed warehouses missing from SHOW read NOT_ASSESSED; grant MONITOR per warehouse", cite("README.md:250-253")],
        ["5", "Query attribution lags up to 8 h and omits idle time", "idle and per-query credits never equal the billed total", cite("CLAUDE.md; sf_chg_query_credits.sql")],
        ["6", "Query-history fallback slice at the 10,000-row limit is not flagged", "busy accounts can undercount in fallback mode", cite("README.md:452-453")],
        ["7", "Full test suite takes about 25 minutes and several GB", "tests run at the end of a batch, not per change", cite("README.md:883")],
        ["8", "No test covers <code>start.py</code> or <code>tools/streamlit_deploy/</code>; fallback helpers are tested only through smoke runs", "deploy and sign-in regressions are found by hand", cite("tests/ (grep)")],
        ["9", "Anyone granted the Streamlit app sees all data in the file", "use <code>--mask</code> at export", cite("README.md:534-535")],
    ])
    return section("risks", "11 · Major risks and limitations", b)


# ================================================================= 12. deploy
def deploy_map():
    m = Map("dep", 1000, 420)
    m.grp(0, 0, 480, 400, "LOCAL MACHINE (default)")
    m.grp(520, 0, 200, 400, "AUDITED ACCOUNT")
    m.grp(760, 0, 240, 400, "STREAMLIT IN SNOWFLAKE (optional)")
    m.box("st", 20, 40, 190, 76, "python start.py", ".venv, sign-in, export, load", "routine entry", "ENTRY", "start.py:275")
    m.box("ex", 270, 40, 190, 76, "export_results.py", "key-pair sign-in", "routine", "", "tools/export_results.py")
    m.box("du", 270, 170, 190, 76, "audit.duckdb", "OS data folder", "data", "DATA", "AUDIT_DATA_DIR overrides")
    m.box("ap", 20, 170, 190, 76, "python -m app.api", "127.0.0.1:8000", "routine entry", "ENTRY", "AUDIT_API_HOST / PORT")
    m.box("br", 20, 295, 190, 60, "Browser", "reads the React build", "actor")
    m.box("dp", 270, 295, 190, 76, "deploy.py --run", "bundle + PUT to stage", "routine", "", "refuses FAKE% data")
    m.box("sf", 535, 60, 170, 110, "ACCOUNT_USAGE ORGANIZATION_USAGE", "AUDIT_ROLE, AUDIT_WH", "data", "DATA", "read-only grants")
    m.box("vw", 775, 40, 210, 50, "Viewer in Snowsight", "", "actor")
    m.box("sa", 775, 120, 210, 90, "Streamlit app", "TestClient + bridge, no port", "routine", "", "tools/streamlit_deploy/streamlit_app.py")
    m.box("sg", 775, 240, 210, 90, "AUDIT_APP_STAGE", "app_src/ + audit.duckdb", "data", "DATA", "AUDIT_APP.PUBLIC")
    m.arrow([(210, 78), (270, 78)], "st", "ex")
    m.arrow([(460, 78), (535, 78)], "ex", "sf")
    m.arrow([(365, 116), (365, 170)], "ex", "du", dashed=True)
    m.arrow([(270, 208), (210, 208)], "du", "ap", dashed=True)
    m.arrow([(115, 295), (115, 246)], "br", "ap")
    m.arrow([(365, 246), (365, 295)], "du", "dp", dashed=True)
    m.arrow([(460, 333), (775, 333)], "dp", "sg", dashed=True)
    m.arrow([(880, 240), (880, 210)], "sg", "sa", dashed=True)
    m.arrow([(880, 90), (880, 120)], "vw", "sa")
    m.lbl(497, 62, "SELECT", False)
    m.lbl(318, 146, "load", False)
    m.lbl(240, 192, "read", False)
    m.lbl(560, 316, "PUT", False)
    return m.render()


def sec_deploy():
    b = deploy_map()
    b += key("frames = where it runs · teal = code · bold border = what a person starts · grey = data · dashed = data moves · solid = calls")
    b += cap("local is the default and proven; Streamlit in Snowflake ships a finished DuckDB file and has not run live.")
    b += sub("Environments")
    b += table(["Environment", "Status", "What it is", "Source"], [
        ["Local machine", "default, in use", "<code>python -m app.api</code> on 127.0.0.1; data in the OS data folder", cite("README.md:502-506; app/api/__main__.py:27-35")],
        ["Streamlit in Snowflake, warehouse runtime", "built, never run in Snowflake", "v1 component, <code>environment.yml</code>, no compute pool", cite("tools/streamlit_deploy/deploy.py:81-83, 129-131")],
        ["Streamlit in Snowflake, container runtime", "fallback, never run", "v2 component, <code>requirements.txt</code>, needs a compute pool", cite("tools/streamlit_deploy/deploy.py:84-87")],
        ["Dev / test / prod accounts, CI, Docker, hosted server", "Not defined in source — confirm with owner", "no pipeline, no Dockerfile, no environment config", cite("repo has none")],
    ])
    b += sub("Prerequisites")
    b += table(["Need", "Version / detail", "Source"], [
        ["Python", "3.11+ (tested on 3.12); <code>start.py</code> exits 2 below 3.11", cite("README.md:62; start.py:292-299")],
        ["Node", "20+, only to change the UI; built UI is committed", cite("README.md:77")],
        ["Packages", "duckdb 1.5.1, <code>snowflake-connector-python</code> &gt;=3.12,&lt;5, sqlglot, pyarrow, pyyaml, pandas 3.0.3, fastapi, uvicorn, httpx", cite("requirements.txt:1-9")],
        ["Sign-in", "key-pair (PKCS8 <code>.p8</code>) for a service user; password or browser also work", cite("tools/export_results.py:690-713")],
        ["Role", "read-only role with grants below", cite("README.md:148-205")],
    ])
    b += sub("Secrets and config (names only)")
    b += table(["Name", "Used for", "Required"], [
        [c("SNOWFLAKE_ACCOUNT"), "account identifier", "yes"], [c("SNOWFLAKE_USER"), "sign-in user", "yes"],
        [c("SNOWFLAKE_PRIVATE_KEY_FILE"), "path to the <code>.p8</code> key", "for key-pair"],
        [c("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE"), "only for an encrypted key", "no"], [c("SNOWFLAKE_PASSWORD"), "password sign-in", "no"],
        [c("SNOWFLAKE_AUTHENTICATOR"), "defaults to <code>externalbrowser</code> when no key or password", "no (undocumented in .env.example)"],
        [c("SNOWFLAKE_ROLE / SNOWFLAKE_WAREHOUSE"), "role and warehouse for the session", "no"],
        [c("AUDIT_DATA_DIR / AUDIT_DB"), "data folder; pick one db file", "no"], [c("AUDIT_API_HOST / AUDIT_API_PORT"), "bind address (127.0.0.1:8000)", "no"],
    ])
    b += "<p class=\"key\">Values live in <code>.env</code> (git-ignored) or the environment; no password or token flag exists on any command " + cite("tools/first_run.py:15-19; .env.example") + "</p>"
    b += sub("Roles and the grant script")
    b += ul([
        "One script, in README &quot;The grant script&quot;, copied by <code>make_export_kit.py</code> to <code>tools/export_kit/grants.sql</code> " + cite("README.md:148-205; tools/make_export_kit.py:112-132"),
        "Creates <code>AUDIT_ROLE</code>, service user <code>AUDIT_USER</code> (<code>TYPE = SERVICE</code>, RSA key), warehouse <code>AUDIT_WH</code> (XSMALL, auto-suspend 60 s)",
        "<code>GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE</code>, or the four viewer roles (USAGE, OBJECT, GOVERNANCE, SECURITY): 253 of 302 checks, 273 with an org role",
        "Plus <code>MONITOR USAGE</code>, <code>MONITOR EXECUTION</code> on the account (<code>APPLY AUTHENTICATION|PASSWORD POLICY</code> optional, commented out: they let the role change those policies); app roles <code>TRUST_CENTER_VIEWER</code>, <code>BUDGET_VIEWER</code>, <code>DATA_QUALITY_MONITORING_VIEWER</code>",
        "<code>MONITOR</code> per warehouse and per resource monitor, repeated for new ones",
        "Optional org billing: <code>ORGANIZATION_BILLING_VIEWER</code>, <code>ORGANIZATION_USAGE_VIEWER</code>",
        "Streamlit deploy needs a separate deploy role (never the audit role): <code>CREATE STREAMLIT</code> on the schema, READ+WRITE on the stage " + cite("tools/streamlit_deploy/README.md:31-48"),
    ])
    b += sub("Commands")
    cmds = [
        ("Check a role before a run", "USE ROLE AUDIT_ROLE;\nUSE WAREHOUSE AUDIT_WH;\nSELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY;", "sql",
         "a count; an error means the role cannot read ACCOUNT_USAGE", "README.md:135-139"),
        ("Everything in one command (7 days)", "python start.py", "sh",
         "Signed in: role R, warehouse W.  then the export lines, then the app opens on the first free port from 8000", "start.py:163-177, 232-275"),
        ("Dry run, nothing exported", "python tools/export_results.py --out <folder outside the repo> --windows 7 --validate", "sh",
         "validated N statements: A ok, B not readable by this role or account, C SQL errors  (+ validate.md with one GRANT per cause)", "tools/export_results.py:1593-1598"),
        ("Export and load by hand", "python tools/first_run.py --windows 30 --credit-price 3.0 --storage-price 23", "sh",
         "step 1 export, step 2 load; stops at the first failure and names it", "README.md:321-333, 389-391"),
        ("Load an existing export", "python tools/load_results.py <folder or .zip> --db <file>.duckdb", "sh",
         "loaded N finding(s) into <db>  then  Run the app against this data:  python -m app.api", "tools/load_results.py:762-800"),
        ("Run the app", "python -m app.api", "sh",
         "database: <path>  then  open http://127.0.0.1:8000", "app/api/__main__.py:14-35"),
        ("Build the UI (only after editing web/)", "cd web\nnpm ci\nnpm run build", "sh",
         "writes app/web/dist and dist/source-hash.txt; commit it", "README.md:914-922; web/vite.config.ts:41-47"),
        ("Deploy to Streamlit (dry build, then real)", "python tools/streamlit_deploy/deploy.py --warehouse MY_WH\npython tools/streamlit_deploy/deploy.py --warehouse MY_WH --run", "sh",
         "dry: prints the db it will ship and the bundle size; --run: REMOVE + PUT to the stage, CREATE OR REPLACE STREAMLIT, ADD LIVE VERSION. Never run live yet", "tools/streamlit_deploy/README.md:11-15; deploy.py:190-194"),
    ]
    for t, cmd, kind, outp, src in cmds:
        b += f'<p class="key"><b>{esc(t)}</b> {cite(src)}</p>' + pair(payload("IN", "command", cmd, kind), payload("OUT", "expected", outp, "sh"))
    b += sub("Roll back")
    b += ul([
        "App code: take the previous GitHub zip or <code>git pull</code> an older commit; keep <code>.env</code> and <code>config/settings.local.yml</code> " + cite("README.md:543-550"),
        "Data: the export folder is kept for the newest two runs; reload an older one with <code>python tools/load_results.py &lt;older folder&gt; --db &lt;file&gt;</code> " + cite("start.py:221-229; app/api/refresh.py:99-103"),
        "Refresh deletes older db files, so keep a copy of a <code>.duckdb</code> you may want " + cite("app/api/refresh.py:80-83"),
        "Streamlit: new data = export, load, deploy again, repeat the GRANT " + cite("tools/streamlit_deploy/README.md:117-119"),
        "Versioned release, tags, changelog: Not defined in source — confirm with owner " + cite("web/package.json version 0.0.0; no CHANGELOG"),
    ])
    b += sub("Health checks")
    b += pair(payload("IN", "is the API up and the db loaded?", "GET /api/status", "sh"),
              payload("OUT", "run on the test DB", json.dumps({"state": "ready", "settings_error": None, "database": "<path>", "brand": {"name": "...", "url": "..."}}, indent=2), "json"))
    b += table(["Check", "Command", "Healthy result"], [
        ["Backend imports", c('python -c "import app.api.app"'), "no output, exit 0"],
        ["UI types", c("cd web && npx tsc --noEmit"), "no output, exit 0"],
        ["All checks pass", c("python tools/gate.py"), "ends <code>GATE OK</code> (about 25 min)"],
        ["Check headers vs manifest", c("python tools/build_manifest.py --check"), "exit 0; fails when the manifest is stale"],
        ["States of /api/status", "no_database, build_incomplete, settings_invalid, ready", "<code>ready</code>"],
        ["Cut-off and count", c("GET /api/meta"), "<code>checks_ran {ran 293, total 302}</code> on the test DB"],
        ["Coverage gaps", c("GET /api/coverage"), "<code>checks_not_ok</code> names each gap and its GRANT"],
    ])
    b += cite("tools/gate.py:52-66; tests/test_api.py:228-273; app/api/app.py:445-472")
    b += ul([
        "Logs: the console of <code>python -m app.api</code> and the export; Streamlit shows a &quot;Browser checks&quot; panel and <code>server_checks()</code> on top of the page " + cite("tools/streamlit_deploy/streamlit_app.py:106-120, 204-221"),
        "Access: local URL <code>http://127.0.0.1:8000/</code>; Streamlit via Snowsight, then <code>GRANT USAGE ON STREAMLIT ... TO ROLE ...</code> and USAGE on its db and schema " + cite("tools/streamlit_deploy/README.md:109-115"),
        "Request access to Snowflake: ask the account's admins to run the grant script for the audit role (ACCOUNTADMIN for the viewer roles) " + cite("README.md:113-118"),
    ])
    return section("deploy", "12 · Deploy and access", b)


def sec_other():
    b = ul([
        "<b>Missing-value text differs</b> · formatters return ASCII <code>-</code> instead of <code>–</code> and a few places show &quot;Loading...&quot; instead of &quot;…&quot; · fixing keeps the number rules uniform, skipping leaves a visible inconsistency " + cite("web/src/components/format.tsx:43-44"),
        "<b>Stale docs and comments</b> · the <code>GET /api/warehouses</code> docstring names the wrong source and <code>app/api/__main__.py:1-3</code> still says <code>AUDIT_DB</code> is required · fixing saves a reader a wrong turn, skipping costs little",
        "<b>Export kit drift</b> · the kit manifest's <code>git_commit</code> is always null and <code>include_snowflake_tasks</code> is always false · fixing makes a kit traceable to a commit, skipping means a returned zip cannot be tied to a version",
    ])
    return section("other", "13 · Other findings", b)


# ================================================================= page
CSS_EXTRA = """
h3 { font-size:15px; font-weight:600; margin:22px 0 6px; }
.cite { font-family:"IBM Plex Mono",Consolas,monospace; font-size:11px; color:var(--muted); white-space:normal; word-break:break-word; }
p.key .cite, li .cite { margin-left:2px; }
.toc { columns:2; column-gap:32px; margin:10px 0 0; padding:0; list-style:none; font-size:14px; }
.toc li { margin:2px 0; } .toc a { color:var(--ink); text-decoration:none; border-bottom:1px solid var(--line); }
.facts { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; margin:12px 0 0; }
.fact { border:1px solid var(--line); border-radius:8px; padding:8px 12px; background:var(--card); }
.fact b { display:block; font:600 20px "IBM Plex Mono",Consolas,monospace; } .fact span { font-size:12px; color:var(--muted); }
.tabmap { display:grid; grid-template-columns:repeat(auto-fill,minmax(210px,1fr)); gap:8px; margin:10px 0; }
.tabmap .tab { border:1px solid var(--line); border-radius:8px; padding:8px 10px; background:var(--card); }
.tabmap .tab b { display:block; font-size:13px; } .tabmap .tab span { font:11px/1.4 "IBM Plex Mono",Consolas,monospace; color:var(--muted); }
details { border:1px solid var(--line); border-radius:8px; margin:8px 0; padding:0 12px; background:var(--card); }
details summary { cursor:pointer; padding:8px 0; font:500 13px "IBM Plex Mono",Consolas,monospace; }
details[open] summary { border-bottom:1px solid var(--line); margin-bottom:6px; }
.table-wrap { overflow-x:auto; }
.payloads { grid-template-columns:repeat(auto-fit,minmax(min(320px,100%),1fr)); }
.payload pre { white-space:pre-wrap; overflow-wrap:anywhere; }
.steps td.v { white-space:normal; }
@media (max-width:700px) { section { padding:14px 14px; } main { padding:20px 10px 40px; } }
code { white-space:normal; overflow-wrap:anywhere; }
td code { white-space:normal; word-break:break-word; }
table { table-layout:auto; }
.ex .res code { white-space:normal; word-break:break-word; }
.ex td { white-space:normal; word-break:break-word; }
.ex td:first-child { white-space:nowrap; word-break:normal; }
.exset { grid-template-columns:repeat(auto-fit,minmax(min(250px,100%),1fr)); }
.ex td:last-child { font-family:"IBM Plex Mono",Consolas,monospace; font-size:11.5px; }
.ex .res.cite { font-size:10.5px; padding-top:0; }
.map .b.c .t { word-break:break-word; }
.map .b.ent .eh b { word-break:break-word; }
section { overflow-wrap:anywhere; }
.map-wrap { overflow-x:auto; }
@media print { details { display:block; } details > * { display:block; } details summary { font-weight:600; } .map-wrap { overflow:visible; } }
@media (max-width:700px) { .toc { columns:1; } }
"""

SECTIONS = [("arch", "Architecture"), ("export", "Export flow"), ("checks", "SQL checks"), ("model", "Loading and data model"),
            ("backend", "Backend"), ("money", "Money and number rules"), ("ui", "UI"), ("masking", "Masking and privacy"),
            ("traps", "Snowflake traps handled"), ("decisions", "Key design decisions"), ("risks", "Major risks and limitations"),
            ("deploy", "Deploy and access"), ("other", "Other findings")]


def main():
    base = (HERE / "base.css").read_text(encoding="utf-8")
    head = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Snowflake audit app, technical</title><style>
{base}
{CSS_EXTRA}
</style></head><body><main>
<div class="eyebrow">Technical view · for engineers</div><h1>Snowflake audit app</h1>
<section id="top"><h2>What it is</h2>
{ul([
    f"A read-only audit of one Snowflake account: {TOTAL} SQL checks in 7 domains read <code>ACCOUNT_USAGE</code> and <code>ORGANIZATION_USAGE</code>.",
    "Pipeline: export, results folder, loader, DuckDB file, FastAPI, React. The app itself never connects to Snowflake.",
    "Runs on the user's machine; an optional Streamlit in Snowflake build ships the same API and UI.",
])}
<div class="facts"><div class="fact"><b>{TOTAL}</b><span>checks, 7 domains</span></div><div class="fact"><b>85</b><span>INFORMATION_SCHEMA fallbacks</span></div>
<div class="fact"><b>37</b><span>HTTP routes</span></div><div class="fact"><b>{len(TABS)} / {sum(len(x) for _, x in TABS)}</b><span>tabs / sub-tabs</span></div><div class="fact"><b>300</b><span>findings tables (test DB)</span></div></div>
<p class="key">Built from the knowledge graph, last updated with the access log (commit 6180c11), key steps checked in the code. Examples marked &quot;run&quot; were executed on this repo; the rest cite a test or a code line.</p>
<ul class="toc">{"".join(f'<li><a href="#{i}">{n}</a></li>' for i, n in SECTIONS)}</ul></section>
"""
    body = "".join([sec_arch(), sec_export(), sec_checks(), sec_model(), sec_backend(), sec_money(), sec_ui(),
                    sec_masking(), sec_traps(), sec_decisions(), sec_risks(), sec_deploy(), sec_other()])
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(head + body + "</main></body></html>", encoding="utf-8")
    print("wrote", OUT, OUT.stat().st_size)


if __name__ == "__main__":
    main()
