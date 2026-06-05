# Lambda operators (`any` / `all`) — Technical Design

**Status:** Design pass for review — 2026-06-05
**Author:** Drafted with Mike Folcher.
**Scope target:** odatalib `0.5.0` (additive; read-only).
**Builds on:** the `$filter` recursive-descent parser + expression tree
([`ODataQuery`](../com/fourjs/odatalib/ODataQuery.4gl)) and the SQL WHERE-tree
builder ([`ODataSqlProvider`](../com/fourjs/odatalib/ODataSqlProvider.4gl)), and
the declared `navigation` relationships used by `$expand`.

---

## 1. Summary

Lambda operators let a `$filter` test a **collection-valued navigation property**:

```
GET /Customers?$filter=Orders/any(o: o/Freight gt 100)
  -> customers having at least one order with Freight > 100

GET /Orders?$filter=OrderDetails/all(d: d/Quantity ge 10)
  -> orders whose every detail line has Quantity >= 10 (incl. orders with none)

GET /Categories?$filter=Products/any()
  -> categories that have at least one product
```

Each lambda compiles to a **correlated subquery** against the navigation
target's table:

| OData | SQL |
|---|---|
| `nav/any(v: P)` | `EXISTS (SELECT 1 FROM tgt v WHERE v.toCol = outer.fromCol AND (P))` |
| `nav/any()` | `EXISTS (SELECT 1 FROM tgt v WHERE v.toCol = outer.fromCol)` |
| `nav/all(v: P)` | `NOT EXISTS (SELECT 1 FROM tgt v WHERE v.toCol = outer.fromCol AND NOT (P))` |

`all` is the De Morgan dual: *every* related row satisfies `P` ⇔ *no* related
row violates `P`. This correctly makes `all` **true for a parent with no related
rows** (vacuous truth), matching OData semantics.

### In scope (v1)
- `any`/`all` over a declared **single-pair** collection navigation property.
- Lambda predicate `P` = the **full existing `$filter` grammar** over the target
  entity's properties (`eq/ne/gt/lt/ge/le`, `contains/startswith/endswith`,
  `in`, `eq null`, `and/or/not`, parentheses), referenced as `v/Prop`.
- Lambdas compose with the rest of `$filter` via `and`/`or`/`not` and may appear
  more than once (`A/any(...) and B/any(...)`), each with its own subquery alias.
- `any()` with an empty body (pure existence test).

### Out of scope (return `501 NotImplemented`)
- **Nested lambda** — a lambda inside another lambda's predicate.
- **Single-valued navigation-path comparison** outside a lambda
  (`Customer/Country eq 'x'`) — a separate feature.
- Lambda whose **navigation target is a function provider**, or used in a
  `$filter` **against a function-provider entity** (no table to correlate to).
- Composite (multi-pair) join navigation properties (as elsewhere).

### `400 BadRequest`
- Unknown navigation property before `any`/`all`; a property in `P` not declared
  on the target entity (via the existing `columnFor` 400); `all()` with an empty
  body (the predicate is mandatory); malformed lambda syntax.

---

## 2. Tokenizer changes

The `$filter` tokenizer currently emits `( ) ,` as single-character tokens and
keeps quoted strings whole. Lambda syntax adds two delimiters:

- Treat **`:`** as a single-character token (separates the lambda variable from
  its predicate). It never appears unquoted elsewhere in the supported grammar
  (no time/`DateTimeOffset` literals — those are quoted).
- **Keep `/` inside identifier tokens** (do *not* split on it). So
  `Orders/any` is one token and `o/Freight` is one token — the parser splits
  them. This avoids disturbing the comparison/function token layout.

Example: `Orders/any(o: o/Freight gt 100)` →
`Orders/any` `(` `o` `:` `o/Freight` `gt` `100` `)`.

---

## 3. Parser changes

A lambda is a **primary** (a leaf at the comparison level). Detection happens at
the top of `parsePredicate`:

```
token t = m_tokens[m_tpos]
if t contains '/' and tail-after-'/' in (any, all) and m_tokens[m_tpos+1] == '(':
    -> parseLambda()
```

`parseLambda`:
```
split t at the last '/'  -> navName, quant         ; consume t
expect '('                                          ; consume '('
if next == ')':                                     # any() / all() empty body
    innerRoot = 0
    (all() empty body -> m_perr BadRequest "all requires a predicate")
else:
    var = next token                                ; consume var
    expect ':'                                       ; consume ':'
    m_lambdaVar = var                                # scratch: strip "var/" in P
    m_inLambda  = TRUE                               # scratch: reject nesting
    innerRoot = parseOr()                            # P, into the SAME node pool
    m_inLambda = FALSE ; m_lambdaVar = NULL
    expect ')'                                       ; consume ')'
node = addLambda(navName, quant, var, innerRoot)     # new node kind, see §4
```

Inside `P`, property tokens are written `v/Prop`. `parsePredicate` strips the
`m_lambdaVar & "/"` prefix so the stored property is the bare target property
`Prop`; a remaining `/` (a deeper nav path) sets `501`. Re-entering `parseLambda`
while `m_inLambda` is TRUE sets `501` (nested lambda).

The lambda variable is purely lexical — it is consumed at parse time and never
needs to reach SQL (there is only one correlation level), so it is not stored
beyond `m_lambdaVar`.

---

## 4. Node representation (no new TYPE fields)

A lambda reuses `T_ODataFilterNode` without schema changes, by overloading the
existing fields under a new `kind`:

```
kind  = "lambda"
left  = inner predicate root index in filterNodes  (0 for an empty any())
pred.property = navigation property name            (e.g. "Orders")
pred.operator = quantifier                          ("any" | "all")
```

`right` is unused. The inner predicate subtree lives in the same `filterNodes`
pool, so it splices/rebases like any other subtree (important: the `$expand`
nested-`$filter` `rebaseFilterNodes` already copies arbitrary nodes, so a lambda
inside a nested `$expand` `$filter` carries over unchanged).

> The flat `q.filters` leaf list (for function providers) is **not** populated
> from inside a lambda — those predicates belong to the subquery, not the outer
> scan. A function-provider host with a lambda is rejected (§6), so the flat list
> staying lambda-free is correct.

---

## 5. SQL generation (`buildNode` gains a `"lambda"` case)

The outer WHERE scan emits unqualified columns today and keeps doing so (they
resolve against the outer FROM). Inside the correlated subquery two tables are in
scope, so columns there **must be qualified**. Mechanism: a module scratch
`m_colPrefix` (default `""`) that `appendPredicate`/`appendInPredicate` prepend to
every column they emit. Outer predicates run with `m_colPrefix = ""`; the inner
subtree runs with `m_colPrefix = "<alias>."`.

```
WHEN "lambda":
    resolve navigation on the OUTER entity:
        nav = findNavigation(entity, node.pred.property)     # 400 if absent
        single-pair only                                     # else 501
        target = findEntity(nav.target)
        target.provider == "sql"                             # else 501
    fromCol = columnFor(entity, nav.on[1].fromProp)
    toCol   = columnFor(target, nav.on[1].toProp)
    alias   = "_l" || (++m_lambdaAlias)                      # unique per lambda
    quant   = node.pred.operator

    IF quant == "any":
        emit "EXISTS (SELECT 1 FROM <target.source> <alias>
              WHERE <alias>.<toCol> = <entity.source>.<fromCol>"
        IF node.left > 0:
            emit " AND ("
            push m_colPrefix = "<alias>."
            buildNode(target, query, node.left)              # P against target
            pop  m_colPrefix
            emit ")"
        emit ")"

    IF quant == "all":
        emit "NOT EXISTS (SELECT 1 FROM <target.source> <alias>
              WHERE <alias>.<toCol> = <entity.source>.<fromCol> AND NOT ("
        push m_colPrefix = "<alias>." ; buildNode(target, query, node.left) ; pop
        emit "))"
```

- `buildNode` is already recursive and pool-based, and `appendPredicate` already
  takes the entity to resolve against — so building `P` against the **target**
  entity is just passing `target` down for the inner subtree. Parameter binding
  stays aligned because the subquery SQL and its `?` parameters are emitted inline
  in `m_whereBuf` / `m_whereParams` in order.
- `m_lambdaAlias` is a module counter reset at the start of each `buildWhere`
  (alongside `m_whereBuf`), so multiple lambdas in one filter get distinct
  aliases. Nesting is disallowed, so a single counter suffices.
- The join references the outer table by its source name (`<entity.source>`),
  which is the unaliased outer FROM — unambiguous because the subquery's own
  columns are alias-qualified.

`countRows` reuses `buildWhere`, so `$count=true` with a lambda works unchanged;
paging is unaffected (a lambda is just another WHERE term).

---

## 6. Provider boundaries

- **Host = SQL provider:** full support (above).
- **Host = function provider:** a lambda cannot be expressed against a callback
  result set. The function provider scans `q.filters` (flat leaves), which never
  contains a lambda; to avoid silently ignoring it, the function provider (or the
  dispatch) rejects any query whose `filterNodes` contains a `"lambda"` node with
  `501 NotImplemented`. (Helper: `ODataConfig`/a small scan in
  `ODataFunctionProvider`.)
- **Lambda target = function provider:** `501` (no table to correlate to), raised
  in the SQL builder when `target.provider != "sql"`.

---

## 7. Error handling summary

| Condition | Status | Code |
|---|---|---|
| Unknown navigation property before `any`/`all` | 400 | BadRequest |
| Unknown property inside `P` | 400 | BadRequest (via `columnFor`) |
| `all()` with empty body | 400 | BadRequest |
| Malformed lambda syntax (missing `(`/`:`/`)`) | 400 | BadRequest |
| Nested lambda | 501 | NotImplemented |
| Single-valued nav-path comparison outside a lambda | 501 | NotImplemented |
| Lambda target/host is a function provider | 501 | NotImplemented |
| Composite (multi-pair) join | 501 | NotImplemented |

---

## 8. Implementation map (files)

| File | Change |
|---|---|
| `ODataQuery` | tokenizer: `:` token + keep `/` in identifiers; `parsePredicate` lambda detection; `parseLambda`; `addLambda`; scratch `m_lambdaVar`/`m_inLambda`; strip `var/` prefix; nested-lambda / deeper-path → 501 |
| `ODataSqlProvider` | `buildNode` `"lambda"` case → correlated `EXISTS`/`NOT EXISTS`; `m_colPrefix` scratch prepended in `appendPredicate`/`appendInPredicate`; `m_lambdaAlias` counter reset in `buildWhere`; target-must-be-sql guard |
| `ODataFunctionProvider` | reject a query whose `filterNodes` contains a `"lambda"` node (`501`) |
| `README` | move lambda from roadmap to supported; examples |
| `examples/PgSmokeTest.4gl` | in-process `any`/`all`/`any()` + error cases |

No `ODataTypes` change (lambda overloads existing `T_ODataFilterNode` fields).

---

## 9. Test plan (PG Northwind: psql baselines → in-process → live GAS)

- `Customers?$filter=Orders/any(o: o/Freight gt 100)` → customers with a heavy order; psql-verified set.
- `Orders?$filter=OrderDetails/all(d: d/Quantity ge 10)&$count=true` → count of orders whose every line ≥ 10 (and orders with no details count as true — verify against psql `NOT EXISTS`).
- `Categories?$filter=Products/any()` → categories having products (all 8).
- compose: `Customers?$filter=Country eq 'Germany' and Orders/any(o: o/Freight gt 50)`.
- `in` inside P: `Customers?$filter=Orders/any(o: o/ShipCountry in ('France','Spain'))`.
- errors: `Orders/any(o: o/Bogus eq 1)` → 400; `Foo/any()` → 400; nested lambda → 501; `OrderDetails/all()` → 400.
- regression: every existing `$filter`, `$expand` (incl. nested `$filter`), composite keys, SQLite smoke — unchanged.
- curl: percent-encode spaces (`%20`); `/`, `:`, `(`, `)` are URL-safe in a query string but encode `'` as `%27`.

---

## 10. Locked decisions (2026-06-05)

1. **`all()` empty body → 400** — `all` requires a predicate; only `any()` is a
   valid empty existence test.
2. **Function-provider host with a lambda → 501** — reject rather than silently
   ignore a term that can't be evaluated against a callback result set.
3. **Single-valued nav-path comparison (`Customer/Country eq 'x'`) → 501** — out
   of this iteration (a distinct join-based feature).
```
