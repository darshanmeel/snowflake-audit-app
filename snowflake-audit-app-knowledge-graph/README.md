# snowflake-audit-app knowledge graph

A git-ignored map of the repo: Markdown pages for flows, rules, modules, data, processes and documents, plus a JSONL graph where every node and edge cites `path:line`.

## Use it

- Start at [index.md](index.md): big picture, entry points, and a "where to look" table for every page.
- Look things up in the graph by id with grep, for example:
  - `grep '"id": "checks:sf_wh_idle_minutes"' graph/nodes.jsonl`
  - `grep '"to": "table:SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY"' graph/edges.jsonl` (who reads a view)
  - `grep '"from": "endpoint:GET /api/findings"' graph/edges.jsonl`
- Id shapes: `file:<path>`, `module:<path>`, `function:<path>:<name>`, `endpoint:GET /api/...`, `checks:<query_id>`, `common:<name>`, `table:SNOWFLAKE.ACCOUNT_USAGE.X`, `ui_screen:<tab>/<subtab>`, `business_rule:<name>`, `flow:<name>`, `process:<name>`.
- `status`: `extracted` (parsed from code), `verified` (opened and checked by a reader), `documented` (taken from a doc), `inferred` (not traced line by line), `logical` / `optional` (data-model joins).

## Rebuild

```
python snowflake-audit-app-knowledge-graph/_scripts/extract.py        # code -> nodes.jsonl, edges.jsonl, meta.json
python snowflake-audit-app-knowledge-graph/_scripts/merge_extras.py   # + graph/extra_*.jsonl, recounts meta.json
```

- `nodes.jsonl`, `edges.jsonl` and `meta.json` are not in git; run both scripts after a clone or pull.
- Always run both, in that order: the merge appends to what `extract.py` just wrote, so it is repeatable.
- The merge dedupes nodes by id and edges by (from, to, type) and drops edges whose endpoints don't exist. Last run dropped 0.
- `_scripts/gen_queries_tables.py` and `_scripts/gen_extra_queries.py` rebuild the tables in `modules/queries.md` / `data/snowflake-views.md` and `graph/extra_queries.jsonl`.

## Built at

- Commit `5ad444cdb79abe4a7480baf41c199802914d59c8` (`meta.json` `git_commit`).
- `meta.json` `file_hashes` lets an update find changed files.

## Counts (recomputed from graph/*.jsonl)

5,429 nodes, 10,702 edges.

| Node type | n | Node type | n |
|---|---|---|---|
| function | 2665 | endpoint | 31 |
| file | 726 | cli_command | 31 |
| table | 470 | folder | 29 |
| test_case | 426 | example_data | 28 |
| query | 388 | sql_include | 21 |
| module | 168 | role | 19 |
| ui_screen | 102 | config | 17 |
| business_rule | 99 | process | 17 |
| class | 68 | flow | 8 |
| document | 55 | secret_ref | 8 |
| view | 52 | external_system | 1 |

| Edge type | n | Edge type | n |
|---|---|---|---|
| contains | 4099 | documents | 98 |
| calls | 2262 | triggers | 43 |
| reads | 1267 | exposes | 31 |
| imports | 903 | configures | 30 |
| illustrates | 587 | grants | 15 |
| implements | 545 | derived_from | 15 |
| writes | 321 | fk | 6 |
| part_of | 306 | deploys | 4 |
| depends_on | 170 |  |  |

## Coverage

- Files: 726 of 1,257 tracked files mapped. The other 531 are generated or binary and skipped on purpose: `app/web/dist/`, `tools/export_kit/queries/` (copies of `app/queries`), `web/src/styles/fonts/`, and this graph folder itself.
- Nodes without `path:line`: 0. Edges without evidence: 0.
- Citation check: 46 extracted and model-written nodes/edges sampled and opened; 44 matched, 2 were wrong (4 edges citing them) and were fixed. Every cited line range in the extras (1,715) and pages (1,841) was checked against the file's length; 7 out-of-range citations (5 in pages, 2 in extras) were fixed.
- No absolute local paths, secrets or real account names in any page; names shown come from the repo's own placeholders and fake data (`tests/fake_snowflake/`, `.env.example`).
