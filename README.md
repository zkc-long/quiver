[![CI](https://github.com/zkc-long/quiver/actions/workflows/ci.yml/badge.svg)](https://github.com/zkc-long/quiver/actions/workflows/ci.yml)

# Quiver

A property-graph database with a Cypher subset engine, written in **pure
MoonBit** with zero third-party dependencies.

Quiver stores nodes and relationships with typed properties, indexes them,
and answers `MATCH ... WHERE ... RETURN` queries — with `CREATE`, `MERGE`,
`SET` and `DELETE` for the write side.

```moonbit
let g = Graph::new()
let ada = g.add_node(["Person"], { "name": VStr("Ada") })
let bob = g.add_node(["Person"], { "name": VStr("Bob") })
ignore(g.add_edge("KNOWS", ada, bob, {}))
let result = @cypher.run(g, "MATCH (a:Person)-[:KNOWS]->(b) RETURN a.name, b.name")
```

## Why not just the registry website

mooncakes.io already lists a module's direct **Dependencies** and **Dependents**, and
that covers the one-hop questions. Quiver is for the multi-hop ones: who is affected
three hops downstream of a yank, the shortest path between two packages, whether the
graph has cycles, which packages rank highest by *transitive* dependents. Those are
questions about the shape of the graph rather than about one package, so they need a
query language and an engine behind it, not a per-package page.

## What is implemented

* dense-id node/edge store with forward and reverse adjacency lists
* label index and property equality index used by the planner
* a hand written Cypher lexer and recursive-descent parser
* a Volcano-style executor: scan, expand, filter, project, aggregate, sort
* `MATCH` (multi-hop, typed relationships, directed and undirected),
  variable-length paths (`*1..3`), `WHERE`, `RETURN` with `DISTINCT`,
  aggregations (`count`, `sum`, `avg`, `min`, `max`, `collect`),
  `ORDER BY`, `SKIP`, `LIMIT`
* `WITH`: projection/aggregation stage, optional `WHERE`, then a further `MATCH`
* writes: `CREATE`, `MERGE`, `SET`, `DELETE` and `DETACH DELETE`, with
  tombstoned deletes so ids stay stable
* JSON Lines / CSV import, JSON snapshot save/load, Graphviz DOT export
* a standalone HTML visualisation (`html` subcommand: embedded JSON + force layout, no server)
* path values: `MATCH p = (a)-[:R*1..3]->(b)` binds a canonical path, `length(p)` gives hops
* list concatenation, indexing, slicing and comprehensions `[x IN xs WHERE p | e]`
* label predicates `(n:Label)`, map projection `n {.name, alias: expr}`, aggregates inside expressions
* relationship uniqueness inside a pattern (a pattern cannot traverse the same edge twice)
* `shortestPath((a)-[:T*]-(b))` pattern form, plus the `shortestPath(a, b)` scalar
* a CLI (`quiver query|info|import|registry|dot|html|bench`) that runs natively
* an openCypher TCK subset runner (`cmd/tck`) with an explicit skip taxonomy

## What is deliberately out of scope

`OPTIONAL MATCH`, `UNION`, `CALL`, `FOREACH`, `LOAD CSV`, `UNWIND`, `REMOVE`,
parameters, `nodes(p)` / `relationships(p)`, map literals in `RETURN`, and
multi-statement transactions. The engine is single-threaded by design; see
`docs/design.md` for the rationale and `conformance/README.md` for the TCK
status.

## Quick start

```bash
moon build --target native

# a hand written sample
./_build/native/debug/build/cmd/main/main.exe \
  query examples/people.jsonl \
  "MATCH (p:Person)-[:WORKS_AT]->(c:Company) RETURN c.name AS company, count(p) AS staff"

# the mooncakes dependency graph
node scripts/fetch_registry.js 120 > examples/mooncakes.registry.jsonl
./_build/native/debug/build/cmd/main/main.exe registry examples/mooncakes.registry.jsonl > examples/mooncakes.jsonl
./_build/native/debug/build/cmd/main/main.exe query examples/mooncakes.jsonl \
  "MATCH (d:Package)-[:DEPENDS_ON]->(p:Package) RETURN p.name AS package, count(d) AS dependents ORDER BY dependents DESC LIMIT 5"
```

Rendering the graph:

```bash
./_build/native/debug/build/cmd/main/main.exe dot examples/mooncakes.jsonl | dot -Tsvg > graph.svg
```

## What it looks like

Dependency analysis over the real mooncakes registry (178 nodes / 76 edges):

```
$ quiver query examples/mooncakes.jsonl \
  "MATCH (d:Package)-[:DEPENDS_ON]->(p:Package)
   RETURN p.name AS package, count(d) AS dependents
   ORDER BY dependents DESC LIMIT 5"

+-----------------------+------------+
| package               | dependents |
+-----------------------+------------+
| bobzhang/toml         | 10         |
| moonrockz/expect      | 9          |
| moonbitstack/moonjson | 6          |
| totto2727/lens        | 4          |
| kawaz/grapheme        | 4          |
+-----------------------+------------+
5 row(s)
```

Blast radius of a yank (variable-length reachability):

```
$ quiver query examples/mooncakes.jsonl \
  "MATCH (v:Package {name:'mizchi/json'})<-[:DEPENDS_ON*1..3]-(b:Package)
   RETURN DISTINCT b.name AS affected ORDER BY affected"

+--------------------------+
| affected                 |
+--------------------------+
| yuzhiblue/moon-watermark |
+--------------------------+
1 row(s)
```

Path values carry their hop count:

```
$ quiver query examples/people.jsonl \
  "MATCH p = (a:Person {name:'Ada'})-[:KNOWS*1..2]->(b)
   RETURN b.name AS reachable, length(p) AS hops ORDER BY hops"

+-----------+------+
| reachable | hops |
+-----------+------+
| Bob       | 1    |
| Cy        | 2    |
+-----------+------+
2 row(s)
```
## Tests

```bash
moon test            # 92 unit and end-to-end tests
```

## Conformance

```bash
moon run cmd/tck -- conformance/features/Match1.feature
```

See `conformance/README.md` for the current numbers and what they do and do not
claim.

## License

Apache-2.0.
