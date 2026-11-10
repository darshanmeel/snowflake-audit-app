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

- Commit `556a877dce2996a469e136eaf15dcc64be6bcdc2` (`meta.json` `git_commit`).
- `meta.json` `file_hashes` lets an update find changed files.

## Counts (recomputed from graph/*.jsonl)

5,431 nodes, 10,410 edges.

| Node type | n | Node type | n |
|---|---|---|---|
| function | 2666 | ui_screen | 102 |
| file | 726 | business_rule | 99 |
| table | 470 | class | 68 |
| test_case | 426 | document | 55 |
| query | 388 | view | 52 |
| module | 169 | cli_command | 32 |
| endpoint | 31 | folder | 28 |
| example_data | 28 | sql_include | 21 |
| role | 19 | config | 17 |
| process | 17 | flow | 8 |
| secret_ref (names only) | 8 | external_system | 1 |

| Edge type | n | Edge type | n |
|---|---|---|---|
| contains | 4101 | part_of | 306 |
| calls | 2262 | depends_on | 170 |
| reads | 1267 | documents | 99 |
| imports | 608 | triggers | 43 |
| illustrates | 587 | exposes | 31 |
| implements | 545 | configures | 30 |
| writes | 321 | grants | 15 |
| derived_from | 15 | fk | 6 |
| deploys | 4 | | |

## Coverage

- Files: 726 of 1,202 tracked files mapped. The other 476 are generated or binary and skipped on purpose: `app/web/dist/`, `tools/export_kit/queries/` (copies of `app/queries`), `web/src/styles/fonts/`.
- Nodes without `path:line`: 0. Edges without evidence: 0.
- Citation check: 46 extracted and model-written nodes/edges sampled and opened; 44 matched, 2 were wrong (4 edges citing them) and were fixed. Every cited line range in the extras (1,715) and pages (1,841) was checked against the file's length; 7 out-of-range citations (5 in pages, 2 in extras) were fixed.
- No absolute local paths, secrets or real account names in any page; names shown come from the repo's own placeholders and fake data (`tests/fake_snowflake/`, `.env.example`).
