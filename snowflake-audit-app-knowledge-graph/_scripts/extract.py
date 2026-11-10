"""Mechanical extraction: files, Python functions/imports/calls, FastAPI routes, SQL checks and
includes, views read, TS imports/exports, config files, tests. Writes graph/nodes.jsonl, edges.jsonl, meta.json.
Run from the repo root: python snowflake-audit-app-knowledge-graph/_scripts/extract.py"""
import ast, hashlib, json, os, re, subprocess
from pathlib import Path

ROOT = Path.cwd()
OUT = ROOT / "snowflake-audit-app-knowledge-graph"
SKIP = ("app/web/dist/", "tools/export_kit/queries/", "web/src/styles/fonts/", "snowflake-audit-app-knowledge-graph/")
nodes, edges, seen = {}, [], set()


def node(id, type, name, path, line=1, line_end=None, summary="", **extra):
    if id not in nodes:
        nodes[id] = {"id": id, "type": type, "name": name, "path": path, "line": line,
                     "line_end": line_end or line, "summary": summary, "status": "extracted", **extra}
    return id


def edge(a, b, type, evidence, status="extracted"):
    k = (a, b, type)
    if k not in seen:
        seen.add(k)
        edges.append({"from": a, "to": b, "type": type, "evidence": evidence, "status": status})


files = [f for f in subprocess.check_output(["git", "ls-files"], text=True).splitlines()
         if not f.startswith(SKIP) and (ROOT / f).is_file()]
hashes = {}
for f in files:
    data = (ROOT / f).read_bytes()
    hashes[f] = hashlib.sha1(data).hexdigest()
    n = data.count(b"\n") + 1
    node(f"file:{f}", "file", Path(f).name, f, 1, n)
    parent = str(Path(f).parent).replace("\\", "/")
    if parent != ".":
        node(f"folder:{parent}", "folder", parent, parent)
        edge(f"folder:{parent}", f"file:{f}", "contains", f"{f}:1")
node("external_system:snowflake", "external_system", "Snowflake account", "README.md", 1,
     summary="Customer Snowflake account; read-only source of ACCOUNT_USAGE / ORGANIZATION_USAGE / SHOW data")

# ---- Python
py = [f for f in files if f.endswith(".py")]
mod_of = {f[:-3].replace("/", ".").removesuffix(".__init__"): f for f in py}
funcs_by_file = {}
for f in py:
    src = (ROOT / f).read_text(encoding="utf-8", errors="replace")
    try:
        tree = ast.parse(src)
    except SyntaxError:
        continue
    mid = f"module:{f}"
    doc = (ast.get_docstring(tree) or "").strip().split("\n")[0]
    node(mid, "module", f[:-3].replace("/", "."), f, 1, src.count("\n") + 1, doc)
    edge(f"file:{f}", mid, "contains", f"{f}:1")
    alias = {}  # local name -> (module file, symbol or None)
    for st in ast.walk(tree):
        if isinstance(st, ast.Import):
            for a in st.names:
                if a.name in mod_of:
                    alias[a.asname or a.name.split(".")[-1]] = (mod_of[a.name], None)
                    edge(mid, f"module:{mod_of[a.name]}", "imports", f"{f}:{st.lineno}")
        elif isinstance(st, ast.ImportFrom) and st.module:
            base = st.module
            if st.level:
                pkg = f.split("/")[:-st.level]
                base = ".".join(pkg + ([st.module] if st.module else []))
            for a in st.names:
                full = f"{base}.{a.name}"
                if full in mod_of:
                    alias[a.asname or a.name] = (mod_of[full], None)
                    edge(mid, f"module:{mod_of[full]}", "imports", f"{f}:{st.lineno}")
                elif base in mod_of:
                    alias[a.asname or a.name] = (mod_of[base], a.name)
                    edge(mid, f"module:{mod_of[base]}", "imports", f"{f}:{st.lineno}")
    local = {}
    defs = []
    for st in tree.body:
        items = [st]
        if isinstance(st, ast.ClassDef):
            cid = node(f"class:{f}:{st.name}", "class", st.name, f, st.lineno, st.end_lineno,
                       (ast.get_docstring(st) or "").split("\n")[0])
            edge(mid, cid, "contains", f"{f}:{st.lineno}")
            items = [s for s in st.body if isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef))]
        for fn in items:
            if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            name = fn.name if fn is st else f"{st.name}.{fn.name}"
            fid = f"function:{f}:{name}"
            args = [a.arg for a in fn.args.args + fn.args.kwonlyargs]
            ret = ast.unparse(fn.returns) if fn.returns else None
            node(fid, "function", name, f, fn.lineno, fn.end_lineno,
                 (ast.get_docstring(fn) or "").strip().split("\n")[0],
                 signature=f"{fn.name}({', '.join(args)})" + (f" -> {ret}" if ret else ""))
            edge(mid, fid, "contains", f"{f}:{fn.lineno}")
            local[fn.name] = fid
            defs.append((fid, fn))
            for d in fn.decorator_list:
                if isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute) and d.func.attr in (
                        "get", "post", "put", "delete", "patch") and d.args and isinstance(d.args[0], ast.Constant):
                    route = f"{d.func.attr.upper()} {d.args[0].value}"
                    eid = node(f"endpoint:{route}", "endpoint", route, f, d.lineno, fn.end_lineno,
                               f"FastAPI route handled by {fn.name}")
                    edge(eid, fid, "calls", f"{f}:{d.lineno}")
                    edge(mid, eid, "exposes", f"{f}:{d.lineno}")
    funcs_by_file[f] = local
    for fid, fn in defs:
        for c in ast.walk(fn):
            if not isinstance(c, ast.Call):
                continue
            tgt = None
            if isinstance(c.func, ast.Name):
                n = c.func.id
                if n in local:
                    tgt = local[n]
                elif n in alias and alias[n][1]:
                    tgt = f"function:{alias[n][0]}:{alias[n][1]}"
            elif isinstance(c.func, ast.Attribute) and isinstance(c.func.value, ast.Name):
                n = c.func.value.id
                if n in alias and alias[n][1] is None:
                    tgt = f"function:{alias[n][0]}:{c.func.attr}"
            if tgt and tgt != fid:
                edge(fid, tgt, "calls", f"{f}:{c.lineno}")
# drop call edges to functions that don't exist (e.g. re-exports)
edges[:] = [e for e in edges if e["type"] != "calls" or e["to"] in nodes]

# ---- SQL checks and includes
VIEW = re.compile(r"\bSNOWFLAKE\.([A-Z_]+)\.([A-Z_]+)\b")
INC = re.compile(r"__INCLUDE_([a-z0-9_]+)__")
manifest = json.loads((ROOT / "app/queries/manifest.json").read_text(encoding="utf-8"))
meta_by_id = {c["query_id"]: c for dom in manifest.values() for c in dom}
for f in [f for f in files if f.startswith("app/queries/") and f.endswith(".sql")]:
    kind = f.split("/")[2]
    stem = Path(f).stem
    src = (ROOT / f).read_text(encoding="utf-8", errors="replace")
    ntype = {"checks": "query", "fallback": "query", "common": "sql_include", "dims": "table",
             "shims": "view", "tag_sources": "query", "verify": "document"}.get(kind, "query")
    m = meta_by_id.get(stem, {}) if kind == "checks" else {}
    title = re.search(r"^-- title: (.+)$", src, re.M)
    nid = f"{kind}:{stem}"
    node(nid, ntype, stem, f, 1, src.count("\n") + 1, (m.get("title") or (title.group(1) if title else "")),
         domain=m.get("domain"), money=m.get("money"), windowed=m.get("windowed"), tier=m.get("tier"),
         requires=m.get("requires"), confidence=m.get("confidence"))
    edge(f"file:{f}", nid, "contains", f"{f}:1")
    if kind == "fallback":
        edge(nid, f"checks:{stem}", "implements", f"{f}:1", "inferred")
    for i, line in enumerate(src.splitlines(), 1):
        for sch, v in VIEW.findall(line):
            vid = node(f"table:SNOWFLAKE.{sch}.{v}", "table", f"SNOWFLAKE.{sch}.{v}", f, i,
                       summary=f"Snowflake system view {sch}.{v}", source="snowflake")
            edge(vid, "external_system:snowflake", "part_of", f"{f}:{i}")
            edge(nid, vid, "reads", f"{f}:{i}")
        for inc in INC.findall(line):
            edge(nid, f"common:{inc}", "depends_on", f"{f}:{i}")
        if line.startswith("-- show:") or re.match(r"\s*SHOW ", line):
            pass
    if kind == "checks":
        edge(nid, f"table:findings.f_{stem}", "writes", f"{f}:1", "inferred")
        node(f"table:findings.f_{stem}", "table", f"findings.f_{stem}", "tools/load_results.py", 567,
             summary=f"DuckDB result table of check {stem}", source="duckdb")
    if kind == "dims":
        node(f"table:dims.{stem}", "table", f"dims.{stem}", "tools/load_results.py", 603, source="duckdb")
        edge(nid, f"table:dims.{stem}", "writes", f"{f}:1", "inferred")
edges[:] = [e for e in edges if e["to"] in nodes or e["type"] != "depends_on"]

# ---- TS / TSX
ts = [f for f in files if f.startswith("web/") and f.endswith((".ts", ".tsx"))]
IMP = re.compile(r"""^import (?:[^;'"]*? from )?['"](\.[^'"]+)['"]""", re.M | re.S)  # multi-line and side-effect imports
EXP = re.compile(r"^export (?:default )?(?:async )?(?:function|const|class) ([A-Za-z0-9_]+)", re.M)
API = re.compile(r"""['"`](/api/[a-z0-9_\-/]+)""")
tsset = set(ts)
for f in ts:
    src = (ROOT / f).read_text(encoding="utf-8", errors="replace")
    mid = node(f"module:{f}", "ui_screen" if "/tabs/" in f else "module", Path(f).stem, f, 1, src.count("\n") + 1)
    edge(f"file:{f}", mid, "contains", f"{f}:1")
    for m in IMP.finditer(src):
        ln = src[:m.start()].count("\n") + 1
        base = os.path.normpath(str(Path(f).parent / m.group(1))).replace("\\", "/")
        for ext in (".tsx", ".ts", "/index.ts", ""):
            if base + ext in tsset:
                edge(mid, f"module:{base + ext}", "imports", f"{f}:{ln}")
                break
    for m in EXP.finditer(src):
        ln = src[:m.start()].count("\n") + 1
        fid = node(f"function:{f}:{m.group(1)}", "function", m.group(1), f, ln)
        edge(mid, fid, "contains", f"{f}:{ln}")
    for m in API.finditer(src):
        ln = src[:m.start()].count("\n") + 1
        route = m.group(1).rstrip("/")
        for nid in [n for n in nodes if n.startswith("endpoint:") and n.split(" ", 1)[1].split("{")[0].rstrip("/") == route]:
            edge(mid, nid, "calls", f"{f}:{ln}")

# ---- config, docs, tests
for f in files:
    if f.startswith("config/"):
        cid = node(f"config:{f}", "config", Path(f).name, f, 1)
        edge(cid, f"file:{f}", "documents", f"{f}:1")
    if f.endswith(".md"):
        node(f"document:{f}", "document", Path(f).name, f, 1)
    if f.startswith("tests/") and f.endswith(".py") and Path(f).name.startswith("test_"):
        for n in [n for n in nodes.values() if n["type"] == "function" and n["path"] == f and n["name"].split(".")[-1].startswith("test_")]:
            tid = node(f"test_case:{f}:{n['name']}", "test_case", n["name"], f, n["line"], n["line_end"], n["summary"])
            for e in [e for e in edges if e["from"] == n["id"] and e["type"] == "calls"]:
                edge(tid, e["to"], "illustrates", e["evidence"])
        for e in [e for e in edges if e["from"] == f"module:{f}" and e["type"] == "imports"]:
            edge(f"module:{f}", e["to"], "illustrates", e["evidence"], "inferred")
    if f.startswith("tests/fake_snowflake/"):
        node(f"example_data:{f}", "example_data", Path(f).name, f, 1, summary="Fake Snowflake data for tests/demo")

edges[:] = [e for e in edges if e["from"] in nodes and e["to"] in nodes]
(OUT / "graph").mkdir(parents=True, exist_ok=True)
with open(OUT / "graph/nodes.jsonl", "w", encoding="utf-8") as fh:
    for n in nodes.values():
        fh.write(json.dumps(n) + "\n")
with open(OUT / "graph/edges.jsonl", "w", encoding="utf-8") as fh:
    for e in edges:
        fh.write(json.dumps(e) + "\n")
from collections import Counter
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
meta = {"git_commit": commit, "files_mapped": len(files), "skipped_prefixes": list(SKIP),
        "nodes_by_type": dict(Counter(n["type"] for n in nodes.values())),
        "edges_by_type": dict(Counter(e["type"] for e in edges)), "file_hashes": hashes,
        "generated_by_model": ["flows/", "logic/", "processes/", "documents/", "modules/", "data/", "index.md", "README.md"]}
(OUT / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
print(len(nodes), "nodes", len(edges), "edges"); print(meta["nodes_by_type"]); print(meta["edges_by_type"])
