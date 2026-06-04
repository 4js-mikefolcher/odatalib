# `$expand` — Technical Design (v1)

**Status:** Design pass for review — 2026-06-03
**Author:** Drafted with Mike Folcher.
**Scope target:** odatalib `0.3.0` (additive; read-only).
**Companion to:** [`genero-odata-framework-spec.md`](genero-odata-framework-spec.md),
which scoped `$expand` as "one-level navigation property expansion (shallow only)".

---

## 1. Summary

`$expand` inlines related entities into a response:

```
GET /Orders(10248)?$expand=Customer
  -> the order, with a nested "Customer": { … } object

GET /Customers('ALFKI')?$expand=Orders
  -> the customer, with a nested "Orders": [ … ] array

GET /Orders?$expand=Customer($select=CompanyName,Country)&$top=20
  -> a page of orders, each with a projected nested Customer
```

This is the first feature to introduce **relationships** into a framework whose
entities are currently independent. The v1 decisions (locked 2026-06-03):

| Decision | Choice |
|---|---|
| Depth | **One level**, to-one and to-many, with optional nested `$select` |
| Fetch strategy | **Batched** via a new `in` operator (one query per expanded nav prop) |
| Providers | **Generic** — expand any target via a synthesized filter; SQL always, function providers when their callback honours the filter |
| Relationship declaration | **Explicit** `navigation` block in the `.odata` config |

### Out of scope for v1 (return `501 NotImplemented`)
- Nested `$filter`, `$top`, `$skip`, `$orderby`, `$count` inside an expand.
- Multi-level / nested `$expand` (`$expand=Orders($expand=OrderDetails)`).
- `$expand=*`.
- Composite (multi-column) join navigation properties (single-column joins only
  in v1; this covers all of Northwind). 

`400 BadRequest` for an unknown navigation property name; malformed nested
options.

---

## 2. The key architectural property

**Expansion is orchestrated *above* the providers.** A parent result is a
`util.JSONArray` of row objects that already carry their join-key values. So a
new `ODataExpand` module can, for each requested nav prop:

1. Collect the distinct **local join-key** values from the parent rows.
2. Fetch the related rows by calling **the target entity's existing provider**
   with a *synthesized* `$filter` of the form `targetKey in (v1, v2, …)`.
3. **Stitch by join key**: index the related rows by their join value, then
   `parent.put(navName, relatedObjectOrArray)`.

Consequences:

- **No provider refactor.** The target provider just sees a query with a filter;
  it does not know it is being expanded. `ODataProvider.fetch` is reused as-is.
- **Correctness is independent of the target honouring the filter.** Because we
  match by key during stitch, a function-provider callback that ignores the
  synthesized filter and returns a superset still yields a correct result — it is
  merely less efficient. The `in` filter is a performance hint, not a correctness
  requirement. (A safety cap bounds the blow-up; see §8.)
- **Blast radius:** one new module + metadata + config + an `in` operator in the
  SQL/filter layer. The dispatch seam ([`ODataProvider`](../com/fourjs/odatalib/ODataProvider.4gl))
  is already in the right place.

---

## 3. Relationship declaration (config)

A new optional `navigation` array per entity:

```json
{
  "name": "Orders",
  "entityType": "Order",
  "provider": "sql",
  "source": "orders",
  "key": "OrderID",
  "properties": [ … ],
  "navigation": [
    { "name": "Customer",     "target": "Customers",    "kind": "one",
      "on": [ { "from": "CustomerID", "to": "CustomerID" } ] },
    { "name": "OrderDetails", "target": "OrderDetails",  "kind": "many",
      "on": [ { "from": "OrderID", "to": "OrderID" } ] }
  ]
}
```

- `name` — the `$expand` token and the JSON key of the inlined data.
- `target` — the target **entity set** name (resolved via `ODataConfig.findEntity`).
- `kind` — `"one"` (inline object, nullable) or `"many"` (inline array).
- `on` — list of `{from, to}` property pairs: `from` is a property on **this**
  entity, `to` a property on the **target**. v1 materialises **single-pair**
  joins; a multi-pair `on` parses and appears in metadata but returns `501` if
  expanded.

`from`/`to` are OData property names (the framework maps them to columns via the
existing `columnFor`), so the join is engine-agnostic and works across the
SQL/function boundary.

### New TYPEs (`ODataTypes`)
```4gl
PUBLIC TYPE T_ODataJoinPair RECORD
    fromProp STRING ATTRIBUTES(json_name = "from"),
    toProp   STRING ATTRIBUTES(json_name = "to")
END RECORD

PUBLIC TYPE T_ODataNavigation RECORD
    name   STRING,
    target STRING,
    kind   STRING,                       # "one" | "many"
    on     DYNAMIC ARRAY OF T_ODataJoinPair
END RECORD
```
`T_ODataEntity` gains `navigation DYNAMIC ARRAY OF T_ODataNavigation`.

---

## 4. CSDL metadata — `<NavigationProperty>`

Power BI (and Tableau/Excel) read navigation properties from `$metadata` to build
their relationship model, so emitting these is arguably the highest-value half of
the feature for the BI use case.

Inside each `<EntityType>`, after the scalar `<Property>` elements:
```xml
<NavigationProperty Name="Customer" Type="Northwind.Customer">
  <ReferentialConstraint Property="CustomerID" ReferencedProperty="CustomerID"/>
</NavigationProperty>
<NavigationProperty Name="OrderDetails" Type="Collection(Northwind.OrderDetail)"/>
```
- to-one → `Type="<ns>.<targetEntityType>"`.
- to-many → `Type="Collection(<ns>.<targetEntityType>)"`.
- `<ReferentialConstraint>` emitted for single-pair to-one joins (optional but
  helps clients infer the FK).

Change is localised to `ODataSerializer.buildMetadata`, which already iterates
entities and properties.

---

## 5. The `in` operator (filter model + SQL)

To fetch the related set in one query we need `col IN (v1, v2, …)`. This is added
to the predicate model and SQL builder, and is reusable as a `$filter` feature.

- `T_ODataFilter` gains `values DYNAMIC ARRAY OF STRING` (populated when
  `operator == "in"`; `value` stays empty).
- `appendPredicate` (in [`ODataSqlProvider`](../com/fourjs/odatalib/ODataSqlProvider.4gl))
  handles `"in"`: emit `(col IN (?,?,…))` with one placeholder per value, each
  **bound type-aware** via the existing `bindParam`/`validateLiteral` against the
  property's `Edm` type (so an `in` over `Edm.Int32` binds integers — same path
  that fixed the original type gap). An empty `values` list emits a guaranteed-
  false predicate (`(1=0)`) so an empty parent page yields no related rows.
- **`$filter` exposure (bonus):** the recursive-descent parser accepts
  `Prop in (lit, lit, …)` as a primary, producing the same predicate. Low extra
  surface; the tokenizer already treats `( ) ,` as tokens.

Expansion itself does **not** parse anything — it constructs the `in` predicate
directly into the synthesized `T_ODataQuery`.

---

## 6. Parsing `$expand`

`q.expand` changes from `DYNAMIC ARRAY OF STRING` to a structured list (nothing
consumes the old form yet, so this is safe):

```4gl
PUBLIC TYPE T_ODataExpandItem RECORD
    path       STRING,                    # navigation property name
    selectList DYNAMIC ARRAY OF STRING    # nested $select (empty = all target props)
END RECORD
```

Grammar accepted in v1:
```
$expand = item ( ',' item )*
item    = NAME [ '(' '$select' '=' proplist ')' ]
```
- A bare `NAME` → expand all target properties.
- `NAME($select=A,B)` → project the target.
- Any other nested option (`$filter`/`$top`/`$orderby`/`$expand`/…) or `*`
  → `501 NotImplemented`.
- Unknown `NAME` (not in the entity's `navigation`) → `400 BadRequest`.

This is a small dedicated parser (separate from the `$filter` tokenizer), aware
of the `;`-separated nested-option syntax so it can reject unsupported options
explicitly rather than mis-parse them.

---

## 7. Materialisation algorithm (`ODataExpand`, new module)

```
FUNCTION apply(entity, expandItems, result) RETURNS (ok, errorCode, errorMessage)
  FOR each item in expandItems:
    nav   = findNavigation(entity, item.path)            # 400 if absent
    tgt   = ODataConfig.findEntity(nav.target)           # 500 config error if absent
    if nav.on has >1 pair: return 501                     # composite join (v1)
    fromProp = nav.on[1].fromProp ; toProp = nav.on[1].toProp

    keys = distinct non-null values of fromProp across result.rows
    q'   = synthesized query on tgt:
             filters = [ toProp in keys ]                 # the 'in' predicate
             selectList = item.selectList (+ toProp if missing, see §7.1)
             no paging; safety cap (§8)
    rel  = ODataProvider.fetch(tgt, q')                   # any provider
    if not rel.ok: return rel error

    index rel.rows by their toProp value:
        kind "one"  -> map value -> first object
        kind "many" -> map value -> array of objects

    FOR each parent in result.rows:
        v = parent[fromProp]
        kind "one"  -> parent.put(item.path, index[v] or JSON null)
        kind "many" -> parent.put(item.path, index[v] or empty array)
  RETURN ok
```

Applies identically to a **collection** result and a **single-entity** result
(the single entity is just a one-row array at this layer).

### 7.1 Join-key projection wrinkle
Stitching needs the parent's `fromProp` and the related rows' `toProp` in their
respective JSON. Decision: **auto-include and keep.**
- Before the **parent** fetch, `ODataService` adds each requested nav prop's
  `fromProp` to `q.selectList` when `$select` is present (so the join key is
  fetched). It remains in the output.
- The synthesized target query adds `toProp` to its `selectList` if a nested
  `$select` omitted it; it remains in the nested output.

This is simple and predictable; it can over-include a key the client did not ask
for. A strict include-then-strip variant is a documented follow-up.

---

## 8. Performance & safety
- **One extra query per expanded nav prop** (batched `in`), not per row — no N+1.
- **Distinct-key bound:** the `in` list size is bounded by the parent page
  (≤ `pageSize`, default 200, cap 1000).
- **Related-row cap:** a to-many expand can still fan out (page of customers ×
  their orders). A configurable cap (`expandMaxRows`, default e.g. 10 000) bounds
  the related fetch; exceeding it returns `400` with a message advising a smaller
  `$top` or a server-side aggregate. This also caps a filter-ignoring function
  provider (§2).
- Import-mode BI (the recommended consumption pattern) tolerates the extra query
  per nav prop well.

---

## 9. Error handling summary
| Condition | Status | Code |
|---|---|---|
| Unknown navigation property in `$expand` | 400 | BadRequest |
| Nested `$filter`/`$top`/`$orderby`/`$count`/nested `$expand`/`*` | 501 | NotImplemented |
| Composite (multi-pair) join expanded | 501 | NotImplemented |
| Related fetch exceeds `expandMaxRows` | 400 | BadRequest |
| Target provider error during related fetch | propagated | (target's code) |

---

## 10. Implementation map (files)
| File | Change |
|---|---|
| `ODataTypes` | `T_ODataJoinPair`, `T_ODataNavigation`, `T_ODataExpandItem`; `navigation` on `T_ODataEntity`; `values` on `T_ODataFilter`; `expand` element type → `T_ODataExpandItem` |
| `ODataConfig` | `findNavigation(entity, name)`; (navigation loads via existing JSON parse) |
| `ODataQuery` | parse `$expand` into items (+ nested `$select`); optional `in` primary in `$filter` |
| `ODataSqlProvider` | `appendPredicate` handles `operator = "in"` → `col IN (?,…)`, type-aware bind per value |
| `ODataSerializer` | emit `<NavigationProperty>` (+ `<ReferentialConstraint>`) |
| `ODataExpand` (new) | orchestration + stitching (§7) |
| `ODataService` | augment parent `selectList` with join keys; call `ODataExpand.apply` after the collection and single-entity fetches |
| `examples/northwind-pg.odata` | `navigation` blocks: Orders↔Customer/OrderDetails, Customers→Orders, OrderDetails→Order/Product, Products→Category/Supplier |
| `README` | document `$expand`; move from roadmap to supported surface |

---

## 11. Test plan (PG Northwind, psql-verified baselines, then live GAS)
- to-one: `Orders(10248)?$expand=Customer` → nested Customer = VINET.
- to-many: `Customers('ALFKI')?$expand=Orders` → nested Orders array (6 orders).
- collection + projection: `Orders?$top=20&$expand=Customer($select=CompanyName,Country)`
  → one batched customers query; correct stitch; only projected props nested.
- composite-key target: `Orders(10248)?$expand=OrderDetails` → 3 detail rows.
- function provider target (contract): expand a nav prop whose target is
  `CountrySummary`-style; confirm correct stitch even if the callback returns a
  superset.
- `in` operator standalone: `Products?$filter=CategoryID in (1,2)&$count=true`.
- errors: unknown nav prop → 400; `$expand=Orders($top=5)` → 501; `$expand=*` → 501.
- regression: existing non-expand requests, type-aware filters, composite keys,
  SQLite smoke — all unchanged.

---

## 12. Resolved decisions (2026-06-03/04)
1. **`expandMaxRows`** — default 10 000, configured **per service** (top-level
   `"expandMaxRows"` in the `.odata` file; `ODataConfig.getExpandMaxRows()`).
2. **Null to-one** — emit explicit `"Customer": null`.
3. **`$filter` `in` value typing** — type-aware bind per value (same path as
   `eq`); a `null` member is not supported (use `eq null`).
4. **`<ReferentialConstraint>`** — emitted for single-pair to-one navigation.
5. Auto-added join keys are **kept** in the output (include-then-strip is a
   follow-up).

## 13. Implementation notes (as built)
- A `maxRows` field was added to `T_ODataQuery`: both providers cap a normal
  response at the entity `pageSize`, but the batched expand fetch must return all
  matching related rows up to `expandMaxRows`, so it sets `maxRows` to bypass
  server paging (and suppress the `nextLink` probe).
- `util.JSONObject.get()` returns NUMBER values space-padded with a trailing
  `.0` (e.g. `"        10248.0"`); `ODataExpand` normalises the extracted join
  key before binding it into the `in` list. Stitching uses the raw `get()` value
  on both sides, so parent/related still match.
- Verified comprehensively in-process against PostgreSQL Northwind (to-one,
  to-many, nested `$select`, composite-key target, multi-nav, the `in` operator,
  and the 400/501 error paths), and the core cases live on GAS. Multi-option
  query strings are also exercised in-process by `PgSmokeTest`.
