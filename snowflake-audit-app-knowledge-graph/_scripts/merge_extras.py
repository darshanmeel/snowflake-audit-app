"""Merge graph/extra_*.jsonl into nodes.jsonl/edges.jsonl and recount meta.json. Run after extract.py."""
import json
from collections import Counter
from pathlib import Path

KG = Path(__file__).resolve().parent.parent
G = KG / "graph"


def read(p):
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]


nodes = read(G / "nodes.jsonl")
edges = read(G / "edges.jsonl")
ids = {n["id"] for n in nodes}
ekeys = {(e["from"], e["to"], e["type"]) for e in edges}

extra_n, extra_e = [], []
for p in sorted(G.glob("extra_*.jsonl")):
    for r in read(p):
        kind = r.pop("kind", None)
        (extra_n if kind == "node" else extra_e).append(r)

added_n = 0
for n in extra_n:
    if n["id"] not in ids:
        ids.add(n["id"]); nodes.append(n); added_n += 1

added_e = dropped = 0
for e in extra_e:
    k = (e["from"], e["to"], e["type"])
    if e["from"] not in ids or e["to"] not in ids:
        dropped += 1
    elif k not in ekeys:
        ekeys.add(k); edges.append(e); added_e += 1

# extractor edges can dangle too; count them, keep them out
bad = [e for e in edges if e["from"] not in ids or e["to"] not in ids]
edges = [e for e in edges if e["from"] in ids and e["to"] in ids]

with open(G / "nodes.jsonl", "w", encoding="utf-8") as fh:
    for n in nodes:
        fh.write(json.dumps(n, ensure_ascii=False) + "\n")
with open(G / "edges.jsonl", "w", encoding="utf-8") as fh:
    for e in edges:
        fh.write(json.dumps(e, ensure_ascii=False) + "\n")

meta = json.loads((KG / "meta.json").read_text(encoding="utf-8"))
meta["nodes_by_type"] = dict(Counter(n["type"] for n in nodes))
meta["edges_by_type"] = dict(Counter(e["type"] for e in edges))
meta["extras_merged"] = sorted(p.name for p in G.glob("extra_*.jsonl"))
(KG / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")

print(f"nodes +{added_n} = {len(nodes)}; edges +{added_e} = {len(edges)}; "
      f"dropped extra edges (missing endpoint) {dropped}; dropped extractor edges {len(bad)}")
