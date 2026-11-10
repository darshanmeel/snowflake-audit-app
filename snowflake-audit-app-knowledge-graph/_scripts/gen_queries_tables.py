"""Generate the per-domain check tables (modules/queries.md) and the view catalog (data/snowflake-views.md)
from app/queries/manifest.json, the check SQL (includes expanded) and the skill's references/views.md.

    python snowflake-audit-app-knowledge-graph/_scripts/gen_queries_tables.py

Each output file keeps everything above its "<!-- generated below -->" marker and rewrites the rest.
"""
import collections
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KG = ROOT / "snowflake-audit-app-knowledge-graph"
Q = ROOT / "app" / "queries"
VIEWS_MD = ROOT / ".claude" / "skills" / "snowflake-account-usage" / "references" / "views.md"
MARK = "<!-- generated below -->"
SHORT = {"ACCOUNT_USAGE": "AU", "ORGANIZATION_USAGE": "OU", "DATA_SHARING_USAGE": "DSU",
         "READER_ACCOUNT_USAGE": "RAU", "TRUST_CENTER": "TC", "LOCAL": "LOCAL"}
VIEW_RE = re.compile(r"SNOWFLAKE\.(ACCOUNT_USAGE|ORGANIZATION_USAGE|DATA_SHARING_USAGE|READER_ACCOUNT_USAGE|TRUST_CENTER|LOCAL)\.([A-Z0-9_]+)", re.I)
INCLUDE_RE = re.compile(r"__INCLUDE_([a-z0-9_]+)__")
HEADER_RE = re.compile(r"^--.*$", re.M)


def short(name: str) -> str:
    m = VIEW_RE.fullmatch(name.strip())
    return f"{SHORT[m.group(1).upper()]}.{m.group(2).upper()}" if m else name.strip()


def body_views(qid: str) -> set[str]:
    """Views the check's SQL actually names, includes expanded, header comments left out."""
    text = (Q / "checks" / f"{qid}.sql").read_text(encoding="utf-8")
    text = INCLUDE_RE.sub(lambda m: (Q / "common" / f"{m.group(1)}.sql").read_text(encoding="utf-8"), text)
    text = HEADER_RE.sub("", text)
    return {f"SNOWFLAKE.{m.group(1).upper()}.{m.group(2).upper()}" for m in VIEW_RE.finditer(text)}


def catalog() -> dict[str, dict]:
    """{"AU.VIEW": {edition, visibility, latency, status}} from views.md table rows."""
    out = {}
    for line in VIEWS_MD.read_text(encoding="utf-8").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 10 or cells[0] in ("View", "---") or cells[0].startswith("-"):
            continue
        schema = cells[1].split()[0]
        if schema in ("AU", "OU", "DSU"):
            for name in re.split(r"\s*,\s*|\s*/\s*", cells[0]):
                out[f"{schema}.{name.strip().upper()}"] = {"latency": cells[3], "edition": cells[5],
                                                          "visibility": cells[7], "status": cells[8]}
    return out


def esc(s: str) -> str:
    return str(s).replace("|", "\\|").replace("\n", " ")


def replace_after_marker(path: Path, generated: str) -> None:
    text = path.read_text(encoding="utf-8")
    head = text.split(MARK)[0]
    path.write_text(head + MARK + "\n\n" + generated, encoding="utf-8", newline="\n")


def main() -> None:
    m = json.loads((Q / "manifest.json").read_text(encoding="utf-8"))
    # Tables per domain.
    lines = []
    for domain, entries in m.items():
        money_n = sum(1 for e in entries if e.get("money"))
        lines += [f"### {domain} ({len(entries)} checks, {money_n} with a `money:` column)", "",
                  "| query_id | title | money | windowed | main views read |", "|---|---|---|---|---|"]
        for e in entries:
            reads = [short(r) for r in e["reads"]]
            lines.append(f"| `{e['query_id']}` | {esc(e['title'])} | {('`' + e['money'] + '`') if e.get('money') else '-'} "
                         f"| {'yes' if e['windowed'] else 'no'} | {esc(', '.join(reads))} |")
        lines.append("")
    replace_after_marker(KG / "modules" / "queries.md", "\n".join(lines))

    # View catalog.
    declared = collections.defaultdict(set)
    actual = collections.defaultdict(set)
    shows = collections.Counter()
    gaps = []
    for entries in m.values():
        for e in entries:
            qid = e["query_id"]
            decl = {r.strip().upper() for r in e["reads"] if r.strip().upper().startswith("SNOWFLAKE.")}
            for r in e["reads"]:
                if not r.strip().upper().startswith("SNOWFLAKE."):
                    shows[r.strip()] += 1
            body = body_views(qid)
            for v in decl:
                declared[v].add(qid)
            for v in body:
                actual[v].add(qid)
            missing = sorted(short(v) for v in body - decl)
            extra = sorted(short(v) for v in decl - body)
            if missing or extra:
                gaps.append((qid, missing, extra))
    cat = catalog()
    views = sorted(set(declared) | set(actual), key=lambda v: (short(v).split(".")[0], -len(actual[v] | declared[v]), v))
    out = ["| view | checks reading it (SQL) | in `reads:` | edition | visibility | latency |",
           "|---|---|---|---|---|---|"]
    for v in views:
        c = cat.get(short(v), {})
        out.append(f"| {short(v)} | {len(actual[v])} | {len(declared[v])} | {esc(c.get('edition', 'not in catalog'))} "
                   f"| {esc(c.get('visibility', '-'))} | {esc(c.get('latency', '-'))} |")
    out += ["", f"{len(views)} SNOWFLAKE.* views in total.", "", "### SHOW commands and functions named in `reads:`", "",
            "| source | checks |", "|---|---|"]
    out += [f"| {esc(s)} | {n} |" for s, n in shows.most_common()]
    out += ["", "### `reads:` header vs the SQL body", "",
            "A view the SQL reads (includes expanded) but the header omits, or the other way round. "
            "Header-only rows are often views a check reads only through a SHOW stand-in or an `OBJECT_CONSTRUCT(*)` wrapper.", "",
            f"{len(gaps)} checks differ.", "", "| query_id | in SQL, not in reads | in reads, not in SQL |", "|---|---|---|"]
    out += [f"| `{q}` | {', '.join(a) or '-'} | {', '.join(b) or '-'} |" for q, a, b in gaps]
    replace_after_marker(KG / "data" / "snowflake-views.md", "\n".join(out) + "\n")
    print(f"{sum(len(v) for v in m.values())} checks, {len(views)} views, {len(gaps)} header gaps")


if __name__ == "__main__":
    main()
