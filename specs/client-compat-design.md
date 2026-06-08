# Client compatibility — `$filter` functions, `/$count` path, navigation traversal

**Status:** Design pass for review — 2026-06-08
**Author:** Drafted with Mike Folcher.
**Scope target:** odatalib (additive; read-only).
**Builds on:** the `$filter` recursive-descent parser + SQL builders
([`ODataQuery`](../com/fourjs/odatalib/ODataQuery.4gl),
[`ODataSqlProvider`](../com/fourjs/odatalib/ODataSqlProvider.4gl)) and the request
dispatch core (`dispatchGet`) in [`ODataService`](../com/fourjs/odatalib/ODataService.4gl).

Three independent client-compatibility gaps, bundled because they're small and
share verification (parser + one new route):

---

## Part A — `$filter` value functions

OData lets a comparison wrap the property in a function:
`tolower(City) eq 'berlin'`, `length(CompanyName) gt 10`, `round(Freight) eq 100`.
Power BI query-folding emits these; without them folding falls back to
client-side (slower) or errors.

### Scope: the portable unary set only
The library's strength is **dialect-free ANSI-ish SQL** (one build serves
PostgreSQL / Informix / SQLite). Only functions that are portable across all
three are implemented in v1:

| OData fn | SQL | result type |
|---|---|---|
| `tolower(p)` | `LOWER(col)` | string |
| `toupper(p)` | `UPPER(col)` | string |
| `trim(p)` | `TRIM(col)` | string |
| `length(p)` | `LENGTH(col)` | integer |
| `round(p)` | `ROUND(col)` | number |

**Deferred → `501`** (they need engine-specific SQL, i.e. a future *dialect
layer*): date parts `year/month/day` (PG `EXTRACT` vs Informix `YEAR()` vs SQLite
`strftime` — not portable), `floor`/`ceiling` (absent in SQLite), multi-arg
`substring`/`indexof`/`concat`, and arithmetic operators (`add`/`sub`/`mul`/`div`/`mod`).

### Parser + model
- `T_ODataFilter` gains `func STRING` — the SQL function wrapping the column
  (empty = plain column). Grammar: a leading `name(` where `name` ∈ the set above
  and the form is `name ( property ) op literal`. The existing boolean string
  functions (`contains`/`startswith`/`endswith`) are unchanged.
- `appendPredicate` emits `<FUNC>(<col>) <op> ?` (prefix-qualified inside a lambda
  as today). The bound literal is validated/bound against the **function result
  type** (e.g. `length` → integer, `tolower` → string), not the column's Edm type.
- Works inside lambda predicates for free (same `parsePredicate`).

---

## Part B — `/$count` path segment

`GET /Orders/$count` → the bare match count as `text/plain` (e.g. `856`),
honouring `$filter`. (Distinct from `$count=true`, which annotates a collection.)

- Reuses the provider count: dispatch a query with `wantCount` and `top=0` (no
  rows fetched), return `result.count`.
- **Raw-text response:** returning a bare number as `text/plain` may need the same
  `WSAttachment`-stream trick as `$metadata` (a `STRING` return can get wrapped).
  **Spike the response mechanism** before finalising.

---

## Part C — navigation traversal `/{set}({key})/{navprop}`

`GET /Customers('ALFKI')/Orders` → the related set (to-many → collection;
to-one → single entity). Some clients navigate by path instead of `$expand`.

- Resolve `Customers('ALFKI')` → the parent's `fromProp` value; resolve the
  declared navigation → target entity + `toProp`. Build a query on the **target**
  with a synthesized `toProp eq <value>` filter **AND-ed with the client's query
  options** (`$filter`/`$select`/`$top`/`$skip`/`$count`/`$orderby`), then dispatch
  through the shared core. to-one → first row as `#target/$entity`; to-many →
  collection envelope `#target`.
- Single-pair joins only (composite → `501`); function-provider parent/target
  works through the provider abstraction (the synthesized `eq` filter is honoured
  by SQL; a function target relies on its callback, same caveat as `$expand`).

---

## Routing: one two-segment route (avoids literal-vs-placeholder precedence)

Both Part B and Part C are **two-segment** GETs (`/{a}/{b}`). Rather than register
a literal `/{entitySet}/$count` and a placeholder `/{entitySet}/{navProp}` and
depend on GAS literal-wins precedence (flagged-uncertain), use **one** route:

```4gl
PUBLIC FUNCTION getEntityChild(
    entitySet STRING ATTRIBUTES(WSParam),
    child STRING ATTRIBUTES(WSParam),
    pSelect/pFilter/pTop/pSkip/pCount/pOrderby/pExpand STRING ATTRIBUTES(WSQuery,…),
    hScopes/hUser STRING ATTRIBUTES(WSHeader,…))
    ATTRIBUTES(WSGet, WSPath = "/{entitySet}/{child}")
    RETURNS util.JSONObject ATTRIBUTES(WSMedia = "application/json")
```
Inside: `child == "$count"` → count path (Part B); otherwise → navigation
traversal (Part C). The single-segment `/{entitySet}`, literal `/$metadata`,
`/$batch`, and `/` routes are unaffected (different segment count / literal).
**Verify on GAS** that the 2-segment route registers and doesn't shadow the
1-segment one.

> `/$count` returns `text/plain`, but this route's `RETURNS` is a JSON object.
> If a single function can't vary the response media cleanly, split `/$count` into
> its own literal route `"/{entitySet}/$count"` (RETURNS STRING/attachment) and
> keep `"/{entitySet}/{child}"` for navigation only — decided after the Part B
> response-mechanism spike.

---

## Error handling

| Condition | Status |
|---|---|
| Unknown `$filter` function (deferred set) | `501` |
| Deferred: date-part / floor / ceiling / multi-arg / arithmetic | `501` |
| Unknown navigation property in a path | `404`/`400` |
| Composite-join navigation traversal | `501` |
| `length`/`round` literal not numeric | `400` |

---

## Implementation map

| File | Change |
|---|---|
| `ODataTypes` | `func STRING` on `T_ODataFilter` |
| `ODataQuery` | parse `FUNC(prop) op literal` (portable set); deferred funcs/arith → 501 |
| `ODataSqlProvider` | `appendPredicate` wraps the column in `FUNC(...)`; bind literal by function result type; `validateLiteral` per result type |
| `ODataService` | `getEntityChild` route → `/$count` (count text) + navigation traversal; reuse `dispatchGet` with a synthesized nav filter; raw-text `/$count` mechanism |
| `examples/PgSmokeTest.4gl` | function filters, `/$count` (in-process count), nav traversal |
| `README` | document the function set + `/$count` + navigation paths; note deferred (dialect) functions |

---

## Test plan (PG Northwind: in-process → live GAS)

- `Customers?$filter=tolower(Country) eq 'germany'` → the German customers.
- `Customers?$filter=length(CompanyName) gt 18` → psql-verified set.
- `Orders?$filter=round(Freight) eq 32` (or similar) → psql-verified.
- deferred: `$filter=year(OrderDate) eq 1997` → `501`; `$filter=Freight add 1 gt 2` → `501`.
- `GET /Orders/$count` → `856`; `GET /Orders/$count?$filter=ShipCountry eq 'France'` → `77`.
- `GET /Customers('ALFKI')/Orders` → ALFKI's 7 orders; `…/Orders?$top=2&$orderby=OrderDate desc`.
- `GET /Orders(10248)/Customer` → the single related customer (`/$entity`).
- routing regression: `/`, `/$metadata`, `/$batch`, `/{set}`, `/{set}(key)` unchanged.

---

## Locked decisions (2026-06-08)

1. **`$filter` function set = the portable unary five** (`tolower`/`toupper`/
   `trim`/`length`/`round`). Date-parts/`floor`/`ceiling`/multi-arg/arithmetic →
   `501`, deferred to a future dialect layer (keeps the single-build simplicity).
2. **Navigation traversal carries the full query-option set** on the related set.
3. **One `/{entitySet}/{child}` route** branching on `$count` vs navigation — may
   split `/$count` into its own route if the Part B raw-text response needs it.
