# `$apply` (aggregation) — Technical Design

**Status:** Design pass for review — 2026-06-05
**Author:** Drafted with Mike Folcher.
**Scope target:** odatalib `0.6.0` (additive; read-only).
**Builds on:** the SQL clause builders, type-aware binding, scroll-cursor paging
and `buildWhere` of [`ODataSqlProvider`](../com/fourjs/odatalib/ODataSqlProvider.4gl);
the option dispatch in [`ODataService`](../com/fourjs/odatalib/ODataService.4gl) /
[`ODataProvider`](../com/fourjs/odatalib/ODataProvider.4gl); and the collection
envelope in [`ODataSerializer`](../com/fourjs/odatalib/ODataSerializer.4gl).

---

## 1. Summary

`$apply` is OData's server-side aggregation pipeline — the option Power BI folds
`SUM`/`COUNT`/`AVG`/group-by into so it never pulls whole tables:

```
GET /Orders?$apply=aggregate($count as Orders, Freight with sum as TotalFreight)
  -> [ { "Orders": 830, "TotalFreight": 64942.69 } ]                 (one total row)

GET /Orders?$apply=groupby((ShipCountry), aggregate($count as Orders,
                                                    Freight with sum as Freight))
  -> [ { "ShipCountry":"France","Orders":77,"Freight":3868.8 }, … ]  (one row/group)

GET /Orders?$apply=filter(Freight gt 50)/groupby((ShipCountry), aggregate($count as N))
  -> groups computed only over orders with Freight > 50            (pre-agg filter)

GET /Customers?$apply=groupby((Country))
  -> [ { "Country":"Argentina" }, { "Country":"Austria" }, … ]      (distinct dims)
```

This is the first option whose **result is not entity rows** — the wire shape is
*dynamic columns* (group-by dimensions + named aggregate measures), not the
entity's declared properties. So it needs its own SELECT/`GROUP BY` builder and a
result whose row objects carry arbitrary keys. The collection envelope itself is
unchanged (`buildCollection` just wraps `result.rows`).

### In scope (v1)
- A pipeline of **at most**: an optional leading `filter(<pred>)`, then **one** of
  `groupby((dims)[, aggregate(...)])` or `aggregate(...)`.
- Aggregate methods: `sum`, `average`, `min`, `max`, `countdistinct`, and
  `$count as <alias>` (row count).
- Pre-aggregation `filter(<pred>)` reuses the **full `$filter` grammar** (incl.
  lambda — it is just a WHERE on the base table before grouping).
- `$orderby`, `$top`, `$skip`, `$count=true` apply to the **aggregated result**
  (order by a dimension or an aggregate alias; paging over the grouped rows;
  `$count` = number of groups).
- SQL providers only.

### Out of scope (return `501 NotImplemented`)
- Any other transformation (`compute`, `expand`, `topcount`, `concat`,
  `groupby` with a nested transformation other than `aggregate`, …) or a pipeline
  with more than the one-`filter`-then-one-aggregation shape.
- Top-level `$filter` / `$select` / `$expand` **combined with** `$apply` (use the
  in-pipeline `filter(...)`; post-aggregation filtering / projection is a
  follow-up). `$apply` on a **key request** (`Set(key)?$apply=…`).
- `$apply` against a **function-provider** entity.

### `400 BadRequest`
- Unknown dimension / measure property; an alias that is not a safe identifier;
  `sum`/`average` over a non-numeric measure; an unknown aggregate method;
  malformed `$apply` syntax; `$orderby` referencing neither a dimension nor an
  alias.

---

## 2. Parse model (new TYPEs + a dedicated parser)

`$apply` has its own grammar (not the `$filter` tokenizer). New types in
`ODataTypes`:

```4gl
PUBLIC TYPE T_ODataAggregate RECORD
    source STRING,        # measure property name; empty for the $count row-count
    method STRING,        # sum | average | min | max | countdistinct | count
    alias  STRING         # output JSON key (validated identifier)
END RECORD

PUBLIC TYPE T_ODataApply RECORD
    present    BOOLEAN,                              # a $apply was supplied
    hasGroupBy BOOLEAN,
    dims       DYNAMIC ARRAY OF STRING,              # groupby property names
    aggs       DYNAMIC ARRAY OF T_ODataAggregate     # measures (may be empty)
END RECORD
```

`T_ODataQuery` gains `apply T_ODataApply`. A leading `filter(<pred>)` is **not**
stored on the apply record — it is parsed straight into the existing
`q.filterNodes`/`q.filterRoot` (so `buildWhere` produces the pre-aggregation
WHERE with zero new SQL code, including lambda support).

`ODataQuery.parse` gains a `pApply` argument. Parsing:
```
parseApply(s, q):
    segs = splitTopLevel(s, '/')                 # paren-aware, reused from $expand
    i = 0
    if segs[1] starts with "filter(":
        parseFilter(inner-of-filter, q)          # -> q.filterNodes/filterRoot
        i = 1
    next = segs[i+1]
    if next starts with "groupby(":  parseGroupby(inner, q.apply)
    elif next starts with "aggregate(": parse aggregate list -> q.apply.aggs
    else: 501
    any further segment -> 501
    q.apply.present = TRUE
```
- `groupby( ( d1,d2 ) [, aggregate(a1,a2) ] )` — the dims are the
  parenthesised list; an optional second argument is the nested `aggregate(...)`.
- aggregate item grammar: `Measure with (sum|average|min|max|countdistinct) as Alias`
  | `$count as Alias`. Parsed by splitting the inner list on depth-0 commas, then
  on the `with`/`as` keywords (whitespace-delimited).
- Alias must match `[A-Za-z_][A-Za-z0-9_]*` (rejects injection via the `AS`
  clause, since aliases are emitted into SQL).

---

## 3. SQL generation (`ODataSqlProvider.applyFetch`, new path)

A dedicated `applyFetch(entity, query)` mirrors `fetch` but builds an aggregation
query. It reuses `buildWhere` (pre-agg filter), `bindParam`, the scroll-cursor
paging loop, and `validateLiteral`.

```
SELECT  <dimCol1> AS "<dimProp1>", … ,  <aggExpr1> AS "<alias1>", …
FROM    <entity.source>
[WHERE  <pre-aggregation filter>]            -- from filter(...) via buildWhere
[GROUP BY <dimCol1>, …]                      -- when hasGroupBy and dims non-empty
[ORDER BY <dim col | alias> [DESC], …]       -- from top-level $orderby
```

Aggregate expression per method:

| OData | SQL |
|---|---|
| `M with sum as A` | `SUM(<col(M)>) AS "A"` |
| `M with average as A` | `AVG(<col(M)>) AS "A"` |
| `M with min as A` | `MIN(<col(M)>) AS "A"` |
| `M with max as A` | `MAX(<col(M)>) AS "A"` |
| `M with countdistinct as A` | `COUNT(DISTINCT <col(M)>) AS "A"` |
| `$count as A` | `COUNT(*) AS "A"` |

- **`groupby((dims))` with no aggregate** → `SELECT <dims> … GROUP BY <dims>`
  (distinct groups).
- **`aggregate(...)` with no groupby** → no `GROUP BY`; one result row.
- Column resolution via the existing `columnFor` (unknown → 400). `sum`/`average`
  require a numeric measure Edm type (`Edm.Int*`/`Single`/`Double`/`Decimal`),
  else 400; `min`/`max`/`countdistinct` accept any.

### Result rows
The select list position → output key mapping is built alongside the SQL:
position *k* is either a dimension (key = dim property name, Edm type = the
property's, so `Edm.Single` dims are re-narrowed with the existing `singleValue`)
or an aggregate (key = alias). Each fetched row becomes a `util.JSONObject` with
those keys; `result.rows` is the `JSONArray`. Aggregate values are put as the
driver returns them (numbers serialise unquoted); `$count`/`countdistinct` are
integers. Single-precision re-narrowing is applied to dimension columns only.

### Paging / count / order
- `$top`/`$skip` page the grouped rows via the same `fetchAbsolute` loop as
  `fetch` (a grouped query is just another scrollable cursor).
- `$count=true` → number of groups:
  `SELECT COUNT(*) FROM (SELECT 1 FROM <source> [WHERE …] GROUP BY <dims>) t`
  (or `COUNT(*)` of the whole table when there is no groupby — i.e. 1).
- `$orderby` term resolves to a **dimension column** or an **aggregate alias**
  (quoted); neither → 400. (Ordering by an alias is widely supported; if a target
  engine rejects it we fall back to the aggregate expression — noted as a
  follow-up, not needed for Postgres/Informix.)

---

## 4. Dispatch & boundaries

- `ODataProvider.fetch`: when `query.apply.present`, route to
  `ODataSqlProvider.applyFetch` for a `sql` entity; a `function` entity returns
  `501` ("`$apply` is not supported on function-backed entities").
- `ODataService.getEntitySet`: add `pApply` (`WSQuery WSName="$apply"`). On a
  **collection** request, pass it to `ODataQuery.parse`. Reject `$apply` combined
  with `$select`/`$expand`/top-level `$filter` (`501`), and `$apply` on a **key**
  request (`400`). The aggregated `result` flows through the unchanged
  `buildCollection` (with `$count` → `@odata.count` = group count).
- `@odata.context`: v1 emits the existing `#<entitySet>` form. The strict O
  projected-type context (`#<entitySet>(<dims>,<aliases>)`) is a cosmetic
  follow-up; Power BI consumes the `value` array regardless.

---

## 5. Error handling summary

| Condition | Status | Code |
|---|---|---|
| Unknown dimension / measure property | 400 | BadRequest |
| `sum`/`average` over a non-numeric measure | 400 | BadRequest |
| Unknown aggregate method; malformed `$apply` | 400 | BadRequest |
| Alias not a safe identifier | 400 | BadRequest |
| `$orderby` term not a dimension or alias | 400 | BadRequest |
| Unsupported transformation / pipeline shape | 501 | NotImplemented |
| `$apply` + `$select`/`$expand`/top-level `$filter` | 501 | NotImplemented |
| `$apply` against a function provider | 501 | NotImplemented |
| `$apply` on a key request | 400 | BadRequest |

---

## 6. Implementation map (files)

| File | Change |
|---|---|
| `ODataTypes` | `T_ODataAggregate`, `T_ODataApply`; `apply` on `T_ODataQuery` |
| `ODataQuery` | `pApply` arg on `parse`; `parseApply` + `parseGroupby` + aggregate-item parser; reuse `splitTopLevel('/')`, `parseFilter` for the `filter(...)` segment; alias-identifier validation |
| `ODataSqlProvider` | `applyFetch` + `buildApplySelect` (dims + agg exprs → SQL, output keys, output Edm types), `buildApplyGroupBy`, `buildApplyOrderBy`, `applyCount`; numeric-measure validation |
| `ODataProvider` | route `query.apply.present` → `applyFetch` (sql) / `501` (function) |
| `ODataService` | `pApply` WSQuery param; pass through on collection; reject with `$select`/`$expand`/`$filter` and on key requests |
| `examples/PgSmokeTest.4gl` | in-process aggregate / groupby / filter-pipeline / errors |
| `README` | move `$apply` from roadmap to supported; examples |

No serializer change (dynamic rows flow through `buildCollection`).

---

## 7. Test plan (PG Northwind: psql baselines → in-process → live GAS)

- `Orders?$apply=aggregate($count as N, Freight with sum as F)` → one row; N=830, F = psql `sum(freight)`.
- `Orders?$apply=groupby((ShipCountry), aggregate($count as N))&$orderby=N desc&$top=5` → top 5 countries by order count; psql-verified.
- `Orders?$apply=filter(Freight gt 50)/groupby((ShipCountry), aggregate($count as N))` → groups over heavy orders only.
- `Products?$apply=groupby((CategoryID), aggregate(UnitPrice with average as AvgPrice, UnitPrice with max as MaxPrice))` → per-category price stats.
- `Customers?$apply=groupby((Country))&$count=true` → distinct countries; `@odata.count` = number of groups.
- `countdistinct`: `Orders?$apply=groupby((ShipCountry), aggregate(CustomerID with countdistinct as Custs))`.
- errors: `aggregate(CompanyName with sum as X)` → 400 (non-numeric sum); `groupby((Bogus))` → 400; `$apply=topcount(…)` → 501; `$apply=…&$select=…` → 501; `Orders(10248)?$apply=…` → 400; `CountrySummary?$apply=aggregate($count as N)` → 501.
- regression: all existing options, lambda, `$expand`, composite keys, SQLite smoke — unchanged.
- curl: percent-encode spaces (`%20`); `(` `)` `,` `/` are query-safe; encode `'` as `%27`.

---

## 8. Locked decisions (2026-06-05)

1. **Aggregate methods = the OData v4 standard set**: `sum`, `average`, `min`,
   `max`, `countdistinct`, and `$count` (row count).
2. **`$apply` + `$select`/`$expand`/top-level `$filter` → 501** — pre-aggregation
   filtering is done with the in-pipeline `filter(...)` segment.
3. **`@odata.context` stays `#<entitySet>`** for v1 (strict projected-type
   context is a cosmetic follow-up).
4. **Pipeline shape = optional `filter(...)` then one `groupby`/`aggregate`** —
   anything longer, or any other transform, returns `501`.
