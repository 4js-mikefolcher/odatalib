################################################################################
# ODataExpand.4gl
#
# Materialises $expand. Expansion is orchestrated ABOVE the providers: a parent
# result is a util.JSONArray whose row objects already carry their join-key
# values, so for each requested navigation property this module
#
#   1. collects the distinct local join-key values from the parent rows,
#   2. fetches the related rows by calling the TARGET entity's provider with a
#      synthesized "targetKey in (…)" filter (one batched query, no N+1) — to
#      which a nested $filter/$orderby is added — and
#   3. stitches the related data back onto each parent by join key, applying any
#      per-parent nested $skip/$top/$count during the stitch.
#
# Multi-level $expand is handled by recursion: after a node's related rows are
# stitched, the node's child expands run against the TARGET entity over those
# related rows (which are shared JSON references, so expanding them in place
# updates the already-nested data). Depth is bounded by getExpandMaxDepth().
#
# Because stitching is BY KEY, correctness of the BATCHING never depends on the
# target provider honouring the synthesized `in` filter — a filter-ignoring
# function callback that returns a superset is merely less efficient. A NESTED
# $filter, however, is a semantic filter: SQL providers apply it via the WHERE
# tree; a function provider must honour the filter it is handed for the nested
# result to be correct. A per-service row cap (getExpandMaxRows) bounds the
# related fetch.
#
# Scope: to-one and to-many; nested $select/$filter/$orderby/$top/$skip/$count;
# multi-level (depth-capped). Composite-column joins are reported NotImplemented.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataProvider

# ---------------------------------------------------------------------------
# Parent projection: ensure join keys are fetched
# ---------------------------------------------------------------------------

#+ When the parent request uses $select, make sure each top-level navigation
#+ property's local join key is in the projection (so the rows carry the value
#+ needed to stitch). When $select is absent every property is returned already,
#+ so the list is returned unchanged. The added key is kept in the output.
PUBLIC FUNCTION ensureJoinKeys(
    entity ODataTypes.T_ODataEntity,
    q ODataTypes.T_ODataQuery,
    selectList DYNAMIC ARRAY OF STRING)
    RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE i INTEGER
    DEFINE node ODataTypes.T_ODataExpandNode
    DEFINE nav ODataTypes.T_ODataNavigation
    DEFINE found BOOLEAN

    FOR i = 1 TO selectList.getLength()
        LET out[i] = selectList[i]
    END FOR
    # No $select -> all properties (keys included) are already returned.
    IF selectList.getLength() == 0 THEN
        RETURN out
    END IF

    FOR i = 1 TO q.expandRoots.getLength()
        LET node.* = q.expandNodes[q.expandRoots[i]].*
        CALL ODataConfig.findNavigation(entity, node.path) RETURNING nav.*, found
        IF NOT found OR nav.on.getLength() != 1 THEN
            CONTINUE FOR
        END IF
        CALL addIfMissing(out, nav.on[1].fromProp) RETURNING out
    END FOR
    RETURN out
END FUNCTION

# ---------------------------------------------------------------------------
# Apply expansion
# ---------------------------------------------------------------------------

#+ Expand every top-level navigation property into the parent rows in place.
#+ Returns (ok, errorCode, errorMessage); on failure the caller raises the error.
PUBLIC FUNCTION apply(
    entity ODataTypes.T_ODataEntity,
    q ODataTypes.T_ODataQuery,
    rows util.JSONArray)
    RETURNS (BOOLEAN, STRING, STRING)
    DEFINE ok BOOLEAN
    DEFINE code, msg STRING
    IF rows IS NULL OR rows.getLength() == 0 THEN
        RETURN TRUE, NULL, NULL
    END IF
    # (multi-value returns can't be forwarded via RETURN; capture then return)
    CALL expandForest(entity, q, q.expandRoots, rows, 1) RETURNING ok, code, msg
    RETURN ok, code, msg
END FUNCTION

#+ Expand a list of node indices (one nesting level) into `rows`, then recurse
#+ into each node's children against the node's target entity. `depth` is the
#+ 1-based level of `roots`; exceeding getExpandMaxDepth() returns 501.
PRIVATE FUNCTION expandForest(
    entity ODataTypes.T_ODataEntity,
    q ODataTypes.T_ODataQuery,
    roots DYNAMIC ARRAY OF INTEGER,
    rows util.JSONArray,
    depth INTEGER)
    RETURNS (BOOLEAN, STRING, STRING)
    DEFINE i, maxDepth INTEGER
    DEFINE ok BOOLEAN
    DEFINE code, msg STRING

    IF roots.getLength() == 0 THEN
        RETURN TRUE, NULL, NULL
    END IF
    LET maxDepth = ODataConfig.getExpandMaxDepth()
    IF depth > maxDepth THEN
        RETURN FALSE, "NotImplemented",
            SFMT("$expand nesting depth %1 exceeds the configured maximum (%2)",
                depth, maxDepth)
    END IF

    FOR i = 1 TO roots.getLength()
        CALL expandNode(entity, q, roots[i], rows, depth)
            RETURNING ok, code, msg
        IF NOT ok THEN
            RETURN FALSE, code, msg
        END IF
    END FOR
    RETURN TRUE, NULL, NULL
END FUNCTION

#+ Expand one node into `rows`: resolve the navigation, batch-fetch the related
#+ rows (in-filter + nested $filter/$orderby/$select), stitch them on (with
#+ per-parent $skip/$top/$count), then recurse into the node's children.
PRIVATE FUNCTION expandNode(
    entity ODataTypes.T_ODataEntity,
    q ODataTypes.T_ODataQuery,
    ri INTEGER,
    rows util.JSONArray,
    depth INTEGER)
    RETURNS (BOOLEAN, STRING, STRING)
    DEFINE node ODataTypes.T_ODataExpandNode
    DEFINE nav ODataTypes.T_ODataNavigation
    DEFINE tgt ODataTypes.T_ODataEntity
    DEFINE found, ok BOOLEAN
    DEFINE fromProp, toProp, code, msg STRING
    DEFINE keys DYNAMIC ARRAY OF STRING
    DEFINE synth ODataTypes.T_ODataQuery
    DEFINE rel ODataTypes.T_ODataResult
    DEFINE cap, j INTEGER

    LET node.* = q.expandNodes[ri].*

    CALL ODataConfig.findNavigation(entity, node.path) RETURNING nav.*, found
    IF NOT found THEN
        RETURN FALSE, "BadRequest",
            SFMT("Unknown navigation property '%1' in $expand", node.path)
    END IF
    IF nav.on.getLength() != 1 THEN
        RETURN FALSE, "NotImplemented",
            SFMT("Composite-key $expand of '%1' is not supported", node.path)
    END IF
    CALL ODataConfig.findEntity(nav.target) RETURNING tgt.*, found
    IF NOT found THEN
        RETURN FALSE, "InternalError",
            SFMT("Navigation target '%1' is not a declared entity", nav.target)
    END IF
    LET fromProp = nav.on[1].fromProp
    LET toProp = nav.on[1].toProp

    CALL distinctKeys(rows, fromProp) RETURNING keys

    # Synthesized batched query against the target.
    LET cap = ODataConfig.getExpandMaxRows()
    LET synth.ok = TRUE
    LET synth.skip = 0
    LET synth.maxRows = cap
    # WHERE = (toProp in keys) AND (nested $filter, if any).
    CALL buildExpandFilter(synth, toProp, keys, node) RETURNING synth
    # Nested $orderby (orders the whole batch; per-parent order is preserved at stitch).
    FOR j = 1 TO node.orderby.getLength()
        LET synth.orderby[j].* = node.orderby[j].*
    END FOR
    # Nested $select (+ toProp + child join keys).
    CALL targetSelect(q, node, tgt, toProp) RETURNING synth.selectList

    LET rel = ODataProvider.fetch(tgt, synth)
    IF NOT rel.ok THEN
        RETURN FALSE, rel.errorCode, rel.errorMessage
    END IF
    IF rel.rows.getLength() >= cap THEN
        RETURN FALSE, "BadRequest",
            SFMT("$expand of '%1' exceeds the row cap (%2); narrow the request with $top or a server-side aggregate",
                node.path, cap)
    END IF

    CALL stitch(rows, node, fromProp, toProp, nav.kind, rel.rows)

    # Multi-level: expand this node's children against the target entity, over the
    # related rows (shared JSON refs, so in-place expansion updates nested data).
    IF node.childRoots.getLength() > 0 THEN
        CALL expandForest(tgt, q, node.childRoots, rel.rows, depth + 1)
            RETURNING ok, code, msg
        IF NOT ok THEN
            RETURN FALSE, code, msg
        END IF
    END IF
    RETURN TRUE, NULL, NULL
END FUNCTION

# ---------------------------------------------------------------------------
# Synthesized filter: (toProp IN keys) AND (nested $filter)
# ---------------------------------------------------------------------------

#+ Build the synthesized query's filter: an `in` predicate over the distinct
#+ parent keys, AND-ed with the node's nested $filter tree (if any). Populates
#+ both the expression tree (used by SQL providers) and the flat leaf list (a
#+ best-effort AND-joined view for function providers).
PRIVATE FUNCTION buildExpandFilter(
    synth ODataTypes.T_ODataQuery,
    toProp STRING,
    keys DYNAMIC ARRAY OF STRING,
    node ODataTypes.T_ODataExpandNode)
    RETURNS ODataTypes.T_ODataQuery
    DEFINE inPred ODataTypes.T_ODataFilter
    DEFINE nestedRoot, inIdx, andIdx, j, n INTEGER

    # The `in` predicate over the distinct parent join-key values.
    LET inPred.property = toProp
    LET inPred.operator = "in"
    LET inPred.conjunction = ""
    FOR j = 1 TO keys.getLength()
        LET inPred.values[j] = keys[j]
    END FOR

    # Flat leaf list (function providers / legacy scan): nested leaves then `in`.
    FOR j = 1 TO node.filterNodes.getLength()
        IF node.filterNodes[j].kind == "pred" THEN
            LET n = synth.filters.getLength() + 1
            LET synth.filters[n].* = node.filterNodes[j].pred.*
            LET synth.filters[n].conjunction = "and"
        END IF
    END FOR
    LET n = synth.filters.getLength() + 1
    LET synth.filters[n].* = inPred.*

    # Expression tree: copy the nested tree (rebased), append the `in` leaf, and
    # AND them together when a nested $filter was present.
    LET nestedRoot = 0
    IF node.filterRoot > 0 THEN
        CALL rebaseFilterNodes(synth, node.filterNodes, node.filterRoot)
            RETURNING synth, nestedRoot
    END IF
    LET inIdx = synth.filterNodes.getLength() + 1
    LET synth.filterNodes[inIdx].kind = "pred"
    LET synth.filterNodes[inIdx].pred.* = inPred.*
    LET synth.filterNodes[inIdx].left = 0
    LET synth.filterNodes[inIdx].right = 0
    IF nestedRoot > 0 THEN
        LET andIdx = synth.filterNodes.getLength() + 1
        LET synth.filterNodes[andIdx].kind = "and"
        LET synth.filterNodes[andIdx].left = inIdx
        LET synth.filterNodes[andIdx].right = nestedRoot
        LET synth.filterRoot = andIdx
    ELSE
        LET synth.filterRoot = inIdx
    END IF
    RETURN synth
END FUNCTION

#+ Append the source filter-node pool onto synth.filterNodes, adding the current
#+ pool size as an index offset to every non-zero child link, and return the
#+ rebased root index. Lets a nested $filter tree be spliced into the synthesized
#+ query's pool without index collisions.
PRIVATE FUNCTION rebaseFilterNodes(
    synth ODataTypes.T_ODataQuery,
    src DYNAMIC ARRAY OF ODataTypes.T_ODataFilterNode,
    srcRoot INTEGER)
    RETURNS (ODataTypes.T_ODataQuery, INTEGER)
    DEFINE i, base INTEGER
    DEFINE nd ODataTypes.T_ODataFilterNode

    LET base = synth.filterNodes.getLength()
    FOR i = 1 TO src.getLength()
        LET nd.* = src[i].*
        IF nd.left > 0 THEN LET nd.left = nd.left + base END IF
        IF nd.right > 0 THEN LET nd.right = nd.right + base END IF
        LET synth.filterNodes[base + i].* = nd.*
    END FOR
    RETURN synth, srcRoot + base
END FUNCTION

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

#+ Distinct, non-null values of a property across the parent rows (as strings,
#+ which is how the SQL layer binds them type-aware against the target column).
PRIVATE FUNCTION distinctKeys(rows util.JSONArray, prop STRING)
    RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE seen DICTIONARY OF INTEGER
    DEFINE i INTEGER
    DEFINE obj util.JSONObject
    DEFINE v STRING

    FOR i = 1 TO rows.getLength()
        LET obj = rows.get(i)
        IF NOT obj.has(prop) THEN CONTINUE FOR END IF
        IF obj.getType(prop) == "NULL" THEN CONTINUE FOR END IF
        LET v = normalizeKeyValue(obj.get(prop))
        IF v IS NULL OR v.getLength() == 0 THEN CONTINUE FOR END IF
        IF NOT seen.contains(v) THEN
            LET seen[v] = 1
            LET out[out.getLength() + 1] = v
        END IF
    END FOR
    RETURN out
END FUNCTION

#+ Normalise a key value read from JSON for use as a bound `in` literal.
#+ util.JSONObject.get() returns NUMBER values space-padded and with a trailing
#+ ".0" for whole numbers (e.g. "        10248.0"); the IN list needs the clean
#+ integer literal "10248". String keys are already returned trimmed.
PRIVATE FUNCTION normalizeKeyValue(s STRING) RETURNS STRING
    DEFINE t, frac STRING
    DEFINE dot, i INTEGER
    DEFINE allZero BOOLEAN
    IF s IS NULL THEN
        RETURN s
    END IF
    LET t = s.trim()
    LET dot = t.getIndexOf(".", 1)
    IF dot > 0 THEN
        LET frac = t.subString(dot + 1, t.getLength())
        LET allZero = (frac.getLength() > 0)
        FOR i = 1 TO frac.getLength()
            IF frac.getCharAt(i) != "0" THEN
                LET allZero = FALSE
                EXIT FOR
            END IF
        END FOR
        IF allZero THEN
            LET t = t.subString(1, dot - 1)
        END IF
    END IF
    RETURN t
END FUNCTION

#+ The target projection: the nested $select (if any), guaranteeing the join key
#+ (toProp) and each child expand's local join key are present so the related
#+ rows can be indexed at this level and the next. Empty -> all target properties.
PRIVATE FUNCTION targetSelect(
    q ODataTypes.T_ODataQuery,
    node ODataTypes.T_ODataExpandNode,
    tgt ODataTypes.T_ODataEntity,
    toProp STRING)
    RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE i INTEGER
    DEFINE child ODataTypes.T_ODataExpandNode
    DEFINE nav ODataTypes.T_ODataNavigation
    DEFINE found BOOLEAN

    # No nested $select -> all target properties (keys already included).
    IF node.selectList.getLength() == 0 THEN
        RETURN out
    END IF
    FOR i = 1 TO node.selectList.getLength()
        LET out[i] = node.selectList[i]
    END FOR
    CALL addIfMissing(out, toProp) RETURNING out
    # Each child expand needs its local join key fetched on these rows.
    FOR i = 1 TO node.childRoots.getLength()
        LET child.* = q.expandNodes[node.childRoots[i]].*
        CALL ODataConfig.findNavigation(tgt, child.path) RETURNING nav.*, found
        IF found AND nav.on.getLength() == 1 THEN
            CALL addIfMissing(out, nav.on[1].fromProp) RETURNING out
        END IF
    END FOR
    RETURN out
END FUNCTION

#+ Append val to arr if not already present (case-sensitive property match).
PRIVATE FUNCTION addIfMissing(arr DYNAMIC ARRAY OF STRING, val STRING)
    RETURNS DYNAMIC ARRAY OF STRING
    DEFINE i INTEGER
    FOR i = 1 TO arr.getLength()
        IF arr[i] == val THEN
            RETURN arr
        END IF
    END FOR
    LET arr[arr.getLength() + 1] = val
    RETURN arr
END FUNCTION

#+ Attach related rows to each parent under node.path, keyed by fromProp=toProp.
#+ to-one: the matching object or JSON null (nested $top/$skip/$count ignored).
#+ to-many: the matching array (ordered as fetched), with the nested $count
#+ annotation emitted BEFORE per-parent $skip/$top slicing.
PRIVATE FUNCTION stitch(
    rows util.JSONArray,
    node ODataTypes.T_ODataExpandNode,
    fromProp STRING, toProp STRING, kind STRING,
    relRows util.JSONArray)
    DEFINE i INTEGER
    DEFINE parent, robj util.JSONObject
    DEFINE full, sliced util.JSONArray
    DEFINE idxOne DICTIONARY OF util.JSONObject
    DEFINE idxMany DICTIONARY OF util.JSONArray
    DEFINE navName, countKey, v, kv, nullStr STRING

    LET navName = node.path
    LET countKey = SFMT("%1@odata.count", navName)

    IF kind == "many" THEN
        FOR i = 1 TO relRows.getLength()
            LET robj = relRows.get(i)
            LET kv = robj.get(toProp)
            IF kv IS NULL THEN CONTINUE FOR END IF
            IF NOT idxMany.contains(kv) THEN
                LET idxMany[kv] = util.JSONArray.create()
            END IF
            LET full = idxMany[kv]
            CALL full.put(full.getLength() + 1, robj)
        END FOR
        FOR i = 1 TO rows.getLength()
            LET parent = rows.get(i)
            LET v = parent.get(fromProp)
            IF v IS NOT NULL AND idxMany.contains(v) THEN
                LET full = idxMany[v]
            ELSE
                LET full = util.JSONArray.create()
            END IF
            IF node.wantCount THEN
                CALL parent.put(countKey, full.getLength())
            END IF
            LET sliced = sliceArray(full, node.skip, node.hasTop, node.top)
            CALL parent.put(navName, sliced)
        END FOR
    ELSE
        FOR i = 1 TO relRows.getLength()
            LET robj = relRows.get(i)
            LET kv = robj.get(toProp)
            IF kv IS NULL THEN CONTINUE FOR END IF
            IF NOT idxOne.contains(kv) THEN
                LET idxOne[kv] = robj            # first match wins
            END IF
        END FOR
        FOR i = 1 TO rows.getLength()
            LET parent = rows.get(i)
            LET v = parent.get(fromProp)
            IF v IS NOT NULL AND idxOne.contains(v) THEN
                CALL parent.put(navName, idxOne[v])
            ELSE
                LET nullStr = NULL               # emit "navName": null
                CALL parent.put(navName, nullStr)
            END IF
        END FOR
    END IF
END FUNCTION

#+ Per-parent slice of a to-many array by nested $skip/$top. Returns `full`
#+ unchanged when no paging applies; otherwise a new array of the same (shared)
#+ object references, so multi-level expansion of the elements still propagates.
PRIVATE FUNCTION sliceArray(
    full util.JSONArray, skip INTEGER, hasTop BOOLEAN, top INTEGER)
    RETURNS util.JSONArray
    DEFINE out util.JSONArray
    DEFINE startIdx, endIdx, i INTEGER
    DEFINE obj util.JSONObject

    IF (skip <= 0) AND (NOT hasTop) THEN
        RETURN full
    END IF
    LET out = util.JSONArray.create()
    LET startIdx = skip + 1
    IF startIdx < 1 THEN LET startIdx = 1 END IF
    IF hasTop THEN
        LET endIdx = skip + top
        IF endIdx > full.getLength() THEN LET endIdx = full.getLength() END IF
    ELSE
        LET endIdx = full.getLength()
    END IF
    FOR i = startIdx TO endIdx
        LET obj = full.get(i)
        CALL out.put(out.getLength() + 1, obj)
    END FOR
    RETURN out
END FUNCTION
