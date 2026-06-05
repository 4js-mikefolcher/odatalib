# Richer `$expand` — Nested Options + Multi-Level — Technical Design

**Status:** Design pass for review — 2026-06-05
**Author:** Drafted with Mike Folcher.
**Scope target:** odatalib `0.4.0` (additive; read-only).
**Builds on:** [`expand-design.md`](expand-design.md) (the shipped one-level `$expand`
+ nested `$select`). This iteration lifts the two `501` gaps that design left open.

---

## 1. Summary

Today `$expand` supports one level with an optional nested `$select`; every other
nested option and any multi-level expand returns `501 NotImplemented`. This
iteration closes both:

```
GET /Customers('ALFKI')?$expand=Orders($filter=Freight gt 50;$orderby=OrderDate desc;$top=3)
  -> ALFKI, with its 3 most-recent orders over 50 freight

GET /Customers('ALFKI')?$expand=Orders($select=OrderID;$count=true)
  -> ALFKI, with "Orders@odata.count": 6 alongside the nested array

GET /Orders(10248)?$expand=OrderDetails($expand=Product($select=ProductName))
  -> order 10248, each detail line carrying its nested Product   (multi-level)
```

### In scope (this iteration)
- **Nested options inside an `$expand` item:** `$filter`, `$orderby`, `$top`,
  `$skip`, `$count` — in addition to the already-supported `$select`.
- **Multi-level `$expand`:** `$expand=A($expand=B($expand=C))`, bounded by a
  configurable depth cap.
- Nested options compose: `Orders($filter=…;$orderby=…;$top=…;$expand=OrderDetails($select=…))`.

### Out of scope (still `501`)
- `$expand=*` (and `*` as a nested expand).
- `$compute`, `$search`, `$apply`, lambda (`any`/`all`) inside a nested `$filter`
  (the nested `$filter` accepts exactly the grammar the top-level `$filter`
  already supports — no navigation paths).
- `$levels` (the OData recursive-hierarchy shorthand).
- Composite (multi-pair) join navigation properties — unchanged from v1.

### `400 BadRequest`
- Unknown nav property; malformed nested option; a nested option that is itself
  invalid (e.g. bad `$orderby` direction, unknown property in nested `$filter`,
  non-integer `$top`). Errors surface with the same codes the top-level parser
  produces, prefixed so the client knows which expand they came from.

---

## 2. The core problem: representation without recursion

A nested expand item must carry a full set of sub-query options **including its
own child expands**. The obvious shape — a `T_ODataQuery` field on the expand
item — is illegal in BDL: `T_ODataQuery` already contains the expand list, so the
type would transitively contain itself. This is the same constraint that forced
the `$filter` tree into a flat node pool (`filterNodes` + `filterRoot`).

**Solution: flatten the expand forest into a pool, exactly like the filter tree.**

```4gl
# One node of the parsed $expand forest. Children are referenced by 1-based
# index into T_ODataQuery.expandNodes, so the record never contains itself.
PUBLIC TYPE T_ODataExpandNode RECORD
    path        STRING,                              # navigation property name
    selectList  DYNAMIC ARRAY OF STRING,             # nested $select  (empty = all)
    orderby     DYNAMIC ARRAY OF T_ODataOrderBy,     # nested $orderby
    filterNodes DYNAMIC ARRAY OF T_ODataFilterNode,  # nested $filter tree (target-relative)
    filterRoot  INTEGER,                             # 0 = no nested $filter
    top         INTEGER,
    skip        INTEGER,
    hasTop      BOOLEAN,
    wantCount   BOOLEAN,
    childRoots  DYNAMIC ARRAY OF INTEGER             # indices into expandNodes (child expands)
END RECORD
```

`T_ODataExpandNode` contains only scalars, `T_ODataOrderBy`, `T_ODataFilterNode`
(none of which reference an expand), and an INTEGER child list — so it does **not**
transitively contain itself. Legal in BDL.

`T_ODataQuery` changes:
```4gl
    # was: expand DYNAMIC ARRAY OF T_ODataExpandItem
    expandNodes DYNAMIC ARRAY OF T_ODataExpandNode,  # flat pool (all levels)
    expandRoots DYNAMIC ARRAY OF INTEGER,            # top-level expand items
```

`T_ODataExpandItem` is **removed** (superseded by `T_ODataExpandNode`). The only
consumers are the expand parser, `ODataExpand`, and `ODataService` — all updated
here. Nothing external depends on it.

> **Note for `ensureJoinKeys`:** the old `apply(entity, expand DYNAMIC ARRAY OF
> T_ODataExpandItem, …)` signature becomes `apply(entity, q, …)` (the node pool
> lives on the query). See §6.

---

## 3. Parsing nested options

The nested-option string inside `Name(...)` is `;`-separated, and each option's
value can itself contain `(`, `)`, `,`, and `;` (a nested `$expand`). So the
splitter must be **depth-aware**: split on `;` only at paren-depth 0. This mirrors
the existing `splitExpandItems` (which splits on `,` at depth 0); add a sibling
`splitNestedOptions(inner)` splitting on `;` at depth 0.

### Reuse, don't reimplement
A nested expand's options **are** a sub-query, so the cleanest implementation
parses them with the *existing* top-level parsers into a throwaway `T_ODataQuery`,
then lifts the fields into the node:

```
parseExpandOptions(inner, node, q):          # q owns the shared expandNodes pool
    opts = splitNestedOptions(inner)         # depth-0 ';' split
    tmp  = new T_ODataQuery
    FOR each opt "key=value":
        CASE key.toLowerCase():
            "$select"  -> splitList(value)            -> node.selectList
            "$orderby" -> parseOrderBy(value, tmp)    -> lift tmp.orderby -> node.orderby
            "$filter"  -> parseFilter(value, tmp)     -> lift tmp.filterNodes/filterRoot -> node
            "$top"     -> isUnsignedInt -> node.top, node.hasTop = TRUE   (else 400)
            "$skip"    -> isUnsignedInt -> node.skip                       (else 400)
            "$count"   -> true/false   -> node.wantCount                   (else 400)
            "$expand"  -> parseExpandInto(value, q) -> append child indices -> node.childRoots
            otherwise  -> 501 NotImplemented   (e.g. $compute/$search/$apply/$levels)
        propagate tmp.ok/errorCode/errorMessage on failure (prefix with the nav path)
```

`parseExpand` is refactored into `parseExpandInto(s, q) RETURNS roots[]` that
appends nodes to `q.expandNodes` and returns the indices of the items it parsed;
the top-level call stores those in `q.expandRoots`, a nested `$expand` stores them
in the parent node's `childRoots`. A single function builds the whole forest.

The nested `$filter` is parsed **target-relative** (its property names belong to
the expand target entity, validated when `ODataExpand` resolves the target). The
parser does not need the target schema; property validation already happens in the
SQL layer's `columnFor`, which raises a clean `400`.

> **Tokenizer note:** the existing `$filter` tokenizer treats `( ) ,` as tokens
> and is reused unchanged. The nested-option splitter runs *before* it, so the
> `$filter` substring handed to `parseFilter` is already isolated.

---

## 4. Materialisation: nested options (`ODataExpand`)

The shipped algorithm — collect distinct parent join keys → one batched
`toProp IN (…)` query against the target provider → stitch by key — is preserved.
Nested options modify the synthesized target query and the stitch:

### 4.1 Nested `$select`
Unchanged: project the target, auto-include `toProp`. For multi-level, also
auto-include each child node's `fromProp` (so the next level can stitch). §6.

### 4.2 Nested `$filter` — merge with the `in` predicate
The synthesized target query's WHERE becomes `(toProp IN keys) AND (nestedFilter)`.
Built directly into the synthesized query's `filterNodes` pool:

```
copy node.filterNodes into the synthesized query's pool with an index offset
    -> remember the rebased nested root R   (R = 0 if no nested $filter)
append an "in" predicate leaf node              -> index P
IF R > 0: append an "and" node {left=P, right=R}; filterRoot = that node
ELSE:     filterRoot = P
```

A small `rebaseFilterNodes(src, dstPool, offset)` helper copies nodes and adds
`offset` to each non-zero `left`/`right`. The SQL provider's existing
`buildWhereTree` then emits `(col IN (?,…)) AND (…)` with every value bound
type-aware. (Function providers: the `in` half is still a hint; the nested
`$filter` is passed through in `q.filters`/tree for providers that honour it —
correctness is preserved by the key-stitch regardless. Documented in §7.)

### 4.3 Nested `$orderby` — order the batch, stitch in order
Apply `node.orderby` to the synthesized target query. The batched fetch returns
all parents' related rows globally ordered; stitching appends to each parent's
array **in iteration order**, so within every parent the order matches the
requested `$orderby` (grouping by key does not reorder within a key). No
per-parent sort needed.

### 4.4 Nested `$top` / `$skip` — per parent, applied at stitch
`$top`/`$skip` inside an expand are **per-parent** ("3 orders *each*"), which a
single global `LIMIT` cannot express. Decision: **do not push `$top`/`$skip` to
SQL**; fetch the (ordered, filtered) related set for the whole batch up to
`expandMaxRows`, then during stitch apply `skip`/`top` to **each parent's** array:

```
for each parent: slice = relatedForKey[skip+1 .. skip+top]   (1-based, clamped)
```

Correct and stays inside the one-batched-query model. The cost is fetching more
related rows than strictly needed, bounded by `expandMaxRows` (§7).

### 4.5 Nested `$count`
`$expand=Orders($count=true)` emits an inline count annotation on the parent:
`"Orders@odata.count": N`, where **N is the per-parent total *before* `$top`/`$skip`**
(but after the nested `$filter`). Since §4.4 already materialises the full
per-parent set before slicing, N is just that set's length. For to-one navs
`$count` is ignored (no array). Emitted as a sibling key next to the nav array,
matching OData's inline-count convention.

---

## 5. Materialisation: multi-level (`ODataExpand`)

After a node's related rows are fetched and stitched onto the parents, recurse
into the node's `childRoots`, treating the **related rows as the new parent set**
against the **target entity**:

```
FUNCTION expandForest(entity, roots[], rows, depth) RETURNS (ok, code, msg)
    IF depth > getExpandMaxDepth(): return 501 "exceeds max $expand depth"
    FOR each ri in roots:
        node = q.expandNodes[ri]
        nav  = findNavigation(entity, node.path)        # 400 if absent
        tgt  = findEntity(nav.target)
        ... build synthesized query (in-filter + nested $filter/$orderby/$select) ...
        rel  = ODataProvider.fetch(tgt, synth)
        stitch rel.rows onto rows (per-parent $top/$skip/$count from §4)
        IF node.childRoots not empty:
            childRows = flatten(all rel.rows actually stitched)   # JSONArray
            expandForest(tgt, node.childRoots, childRows, depth + 1)   # recurse
    RETURN ok
```

**Why in-place recursion works:** the stitched related objects are the *same*
`util.JSONObject` references held in the parents (the index dictionaries store the
fetched objects, and `parent.put(nav, obj)` stores the reference). Expanding those
objects in place mutates the already-nested data, so the grandchild appears under
the child with no re-stitching of the parent. `childRows` is the flat union of all
related rows across parents — one batched grandchild query, not per-parent.

`apply` becomes a thin entry point: `expandForest(entity, q.expandRoots, rows, 1)`.

---

## 6. Join-key projection across levels

Stitching at level *n+1* needs the level-*n* rows to carry the child nav's
`fromProp`. Generalise the existing `ensureJoinKeys`:

- **Parent (level 0):** when the top-level request has `$select`, add each
  top-level expand root's `fromProp` (unchanged behaviour, now driven by
  `expandRoots`).
- **Each expanded node with a nested `$select` AND children:** the synthesized
  target `selectList` must include (a) the node's own `toProp` (so it stitches to
  its parent) and (b) each child's `fromProp` (so children stitch to it). Both are
  auto-included and kept, consistent with the v1 "include-and-keep" decision.

No new public surface — `targetSelect` is extended to take the child fromProps.

---

## 7. Performance & safety

- **Query count = number of expand nodes**, not rows and not parents. A 3-level
  expand with one nav per level = 3 batched queries total. No N+1.
- **`expandMaxRows`** (existing, per-service, default 10 000) bounds **each node's**
  related fetch. With per-parent `$top` (§4.4) the batch can exceed the sum of the
  `$top`s (we slice after fetching), so the cap still matters; exceeding it is the
  existing `400` with the "narrow with $top / use an aggregate" message.
- **`expandMaxDepth`** (new, per-service, default **3**) bounds recursion depth.
  Exceeding it → `501 NotImplemented` ("$expand depth N exceeds the configured
  maximum"). Prevents a hand-crafted deep `$expand` from fanning out unbounded.
- **Distinct-key dedup** across the batch is unchanged; multi-level dedups at each
  level, so shared children are fetched once.
- Function-provider targets: the `in` predicate and nested `$filter` are *hints*;
  correctness is guaranteed by the key-stitch + per-parent slice, so a
  filter-ignoring callback yields correct (if larger, cap-bounded) results.

---

## 8. Error handling summary

| Condition | Status | Code |
|---|---|---|
| Unknown nav property (any level) | 400 | BadRequest |
| Malformed nested option / bad `$top`/`$skip`/`$count`/`$orderby` value | 400 | BadRequest |
| Unknown property in a nested `$filter` | 400 | BadRequest (from `columnFor`) |
| `$compute`/`$search`/`$apply`/`$levels`/lambda in a nested option, or `*` | 501 | NotImplemented |
| Composite (multi-pair) join expanded | 501 | NotImplemented |
| `$expand` depth exceeds `expandMaxDepth` | 501 | NotImplemented |
| Node's related fetch exceeds `expandMaxRows` | 400 | BadRequest |
| Target provider error | propagated | (target's code) |

---

## 9. Implementation map (files)

| File | Change |
|---|---|
| `ODataTypes` | Add `T_ODataExpandNode`; remove `T_ODataExpandItem`; `T_ODataQuery`: `expand` → `expandNodes` + `expandRoots`; add `expandMaxDepth` to `T_ODataSchema` |
| `ODataConfig` | `getExpandMaxDepth()` (default 3); load top-level `expandMaxDepth` from `.odata` |
| `ODataQuery` | `splitNestedOptions` (depth-0 `;` split); `parseExpandInto(s,q)->roots`; `parseExpandOptions` handles `$filter`/`$orderby`/`$top`/`$skip`/`$count`/`$expand` via temp-query lift; nested `$expand` recursion |
| `ODataExpand` | `apply` → `expandForest(entity, roots, rows, depth)`; merge nested `$filter` with `in` (`rebaseFilterNodes`); per-parent `$top`/`$skip`/`$count` at stitch; multi-level in-place recursion; generalise `ensureJoinKeys`/`targetSelect` for child fromProps |
| `ODataService` | call sites use `q.expandRoots`/`expandNodes`; `ensureJoinKeys` takes the query |
| `examples/northwind-pg.odata` | add `expandMaxDepth` (optional; rely on default otherwise) |
| `README` | move nested options + multi-level from roadmap to supported; document `expandMaxDepth`; nested-option examples |
| `examples/PgSmokeTest.4gl` | in-process cases for nested `$filter`/`$orderby`/`$top`/`$count` + 2-level expand |

---

## 10. Test plan (PG Northwind: psql baselines → in-process → live GAS)

Nested options (single level):
- `Customers('ALFKI')?$expand=Orders($orderby=OrderDate desc;$top=3)` → 3 newest orders, descending.
- `Customers('ALFKI')?$expand=Orders($filter=Freight gt 50)` → only orders with Freight > 50; psql-verified count.
- `Customers('ALFKI')?$expand=Orders($count=true;$top=2)` → `Orders@odata.count` = full 6, array length 2.
- `Customers('ALFKI')?$expand=Orders($filter=Freight gt 50;$orderby=Freight desc;$top=2;$select=OrderID,Freight)` → all four compose.
- per-parent `$top` over a collection: `Customers?$top=5&$expand=Orders($top=2)` → each of 5 customers ≤ 2 orders.

Multi-level:
- `Orders(10248)?$expand=OrderDetails($expand=Product($select=ProductName))` → 3 details, each with nested Product.
- `Customers('ALFKI')?$expand=Orders($top=2;$expand=OrderDetails($select=ProductID,Quantity))` → 2 orders, each with detail lines.
- depth cap: `$expand=A($expand=B($expand=C($expand=D)))` with `expandMaxDepth=3` → 501.

Errors / regression:
- `$expand=Orders($search=foo)` → 501; `$expand=Orders($top=-1)` → 400; unknown nav → 400; unknown prop in nested `$filter` → 400.
- All shipped one-level cases, type-aware filters, composite keys, SQLite smoke — unchanged.
- **curl reminder:** percent-encode spaces (`%20`) and `;` in nested options.

---

## 11. Locked decisions (2026-06-05)

1. **`expandMaxDepth` default = 3** — covers Order→OrderDetails→Product and
   similar; configurable per service via top-level `"expandMaxDepth"` in `.odata`,
   read by `ODataConfig.getExpandMaxDepth()`. Deeper → `501`.
2. **Nested `$count` = `"<nav>@odata.count"` sibling** of the nav array (OData v4
   inline-count convention); N is the per-parent total **after** the nested
   `$filter`, **before** `$top`/`$skip`. Ignored for to-one navs.
3. **Per-parent `$top`/`$skip` = fetch-all-then-slice** (§4.4): one batched query
   per node (cap-bounded by `expandMaxRows`), `$skip`/`$top` applied per parent at
   stitch. No N+1; bounded over-fetch accepted.
```
