################################################################################
# ODataExpand.4gl
#
# Materialises $expand. Expansion is orchestrated ABOVE the providers: a parent
# result is a util.JSONArray whose row objects already carry their join-key
# values, so for each requested navigation property this module
#
#   1. collects the distinct local join-key values from the parent rows,
#   2. fetches the related rows by calling the TARGET entity's provider with a
#      synthesized "targetKey in (…)" filter (one batched query, no N+1), and
#   3. stitches the related data back onto each parent by join key.
#
# Because stitching is BY KEY, correctness never depends on the target provider
# honouring the synthesized filter — a filter-ignoring function callback that
# returns a superset is merely less efficient. A per-service row cap
# (ODataConfig.getExpandMaxRows) bounds the related fetch.
#
# v1 scope: one level; to-one and to-many; optional nested $select; single-pair
# joins. Composite-column joins are reported NotImplemented by the caller path.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataProvider

# ---------------------------------------------------------------------------
# Parent projection: ensure join keys are fetched
# ---------------------------------------------------------------------------

#+ When the parent request uses $select, make sure each requested navigation
#+ property's local join key is in the projection (so the rows carry the value
#+ needed to stitch). When $select is absent every property is returned already,
#+ so the list is returned unchanged. The added key is kept in the output.
PUBLIC FUNCTION ensureJoinKeys(
    entity ODataTypes.T_ODataEntity,
    expand DYNAMIC ARRAY OF ODataTypes.T_ODataExpandItem,
    selectList DYNAMIC ARRAY OF STRING)
    RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE i, j INTEGER
    DEFINE nav ODataTypes.T_ODataNavigation
    DEFINE found, present BOOLEAN
    DEFINE fp STRING

    FOR i = 1 TO selectList.getLength()
        LET out[i] = selectList[i]
    END FOR
    # No $select -> all properties (keys included) are already returned.
    IF selectList.getLength() == 0 THEN
        RETURN out
    END IF

    FOR i = 1 TO expand.getLength()
        CALL ODataConfig.findNavigation(entity, expand[i].path)
            RETURNING nav.*, found
        IF NOT found OR nav.on.getLength() != 1 THEN
            CONTINUE FOR
        END IF
        LET fp = nav.on[1].fromProp
        LET present = FALSE
        FOR j = 1 TO out.getLength()
            IF out[j] == fp THEN
                LET present = TRUE
                EXIT FOR
            END IF
        END FOR
        IF NOT present THEN
            LET out[out.getLength() + 1] = fp
        END IF
    END FOR
    RETURN out
END FUNCTION

# ---------------------------------------------------------------------------
# Apply expansion
# ---------------------------------------------------------------------------

#+ Expand every requested navigation property into the parent rows in place.
#+ Returns (ok, errorCode, errorMessage); on failure the caller raises the error.
PUBLIC FUNCTION apply(
    entity ODataTypes.T_ODataEntity,
    expand DYNAMIC ARRAY OF ODataTypes.T_ODataExpandItem,
    rows util.JSONArray)
    RETURNS (BOOLEAN, STRING, STRING)
    DEFINE i INTEGER
    DEFINE ok BOOLEAN
    DEFINE code, msg STRING

    IF rows IS NULL OR rows.getLength() == 0 THEN
        RETURN TRUE, NULL, NULL
    END IF
    FOR i = 1 TO expand.getLength()
        CALL expandOne(entity, expand[i].*, rows) RETURNING ok, code, msg
        IF NOT ok THEN
            RETURN FALSE, code, msg
        END IF
    END FOR
    RETURN TRUE, NULL, NULL
END FUNCTION

#+ Expand one navigation property into all parent rows.
PRIVATE FUNCTION expandOne(
    entity ODataTypes.T_ODataEntity,
    item ODataTypes.T_ODataExpandItem,
    rows util.JSONArray)
    RETURNS (BOOLEAN, STRING, STRING)
    DEFINE nav ODataTypes.T_ODataNavigation
    DEFINE tgt ODataTypes.T_ODataEntity
    DEFINE found BOOLEAN
    DEFINE fromProp, toProp STRING
    DEFINE keys DYNAMIC ARRAY OF STRING
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE rel ODataTypes.T_ODataResult
    DEFINE cap, k INTEGER

    CALL ODataConfig.findNavigation(entity, item.path) RETURNING nav.*, found
    IF NOT found THEN
        RETURN FALSE, "BadRequest",
            SFMT("Unknown navigation property '%1' in $expand", item.path)
    END IF
    IF nav.on.getLength() != 1 THEN
        RETURN FALSE, "NotImplemented",
            SFMT("Composite-key $expand of '%1' is not supported in v0", item.path)
    END IF
    CALL ODataConfig.findEntity(nav.target) RETURNING tgt.*, found
    IF NOT found THEN
        RETURN FALSE, "InternalError",
            SFMT("Navigation target '%1' is not a declared entity", nav.target)
    END IF
    LET fromProp = nav.on[1].fromProp
    LET toProp = nav.on[1].toProp

    CALL distinctKeys(rows, fromProp) RETURNING keys

    # Synthesized batched query against the target: toProp in (distinct keys).
    LET cap = ODataConfig.getExpandMaxRows()
    LET q.ok = TRUE
    LET q.skip = 0
    LET q.maxRows = cap
    LET q.filters[1].property = toProp
    LET q.filters[1].operator = "in"
    LET q.filters[1].conjunction = ""
    FOR k = 1 TO keys.getLength()
        LET q.filters[1].values[k] = keys[k]
    END FOR
    CALL targetSelect(item.selectList, toProp) RETURNING q.selectList

    LET rel = ODataProvider.fetch(tgt, q)
    IF NOT rel.ok THEN
        RETURN FALSE, rel.errorCode, rel.errorMessage
    END IF
    IF rel.rows.getLength() >= cap THEN
        RETURN FALSE, "BadRequest",
            SFMT("$expand of '%1' exceeds the row cap (%2); narrow the request with $top or a server-side aggregate",
                item.path, cap)
    END IF

    CALL stitch(rows, item.path, fromProp, toProp, nav.kind, rel.rows)
    RETURN TRUE, NULL, NULL
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
#+ is present so the related rows can be indexed. Empty -> all target properties.
PRIVATE FUNCTION targetSelect(nestedSel DYNAMIC ARRAY OF STRING, toProp STRING)
    RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE i INTEGER
    DEFINE hasTo BOOLEAN

    IF nestedSel.getLength() == 0 THEN
        RETURN out
    END IF
    FOR i = 1 TO nestedSel.getLength()
        LET out[i] = nestedSel[i]
        IF nestedSel[i] == toProp THEN LET hasTo = TRUE END IF
    END FOR
    IF NOT hasTo THEN
        LET out[out.getLength() + 1] = toProp
    END IF
    RETURN out
END FUNCTION

#+ Attach related rows to each parent under navName, keyed by fromProp=toProp.
#+ to-one: the matching object or JSON null; to-many: the matching array or [].
PRIVATE FUNCTION stitch(
    rows util.JSONArray, navName STRING, fromProp STRING, toProp STRING,
    kind STRING, relRows util.JSONArray)
    DEFINE i INTEGER
    DEFINE parent, robj util.JSONObject
    DEFINE arr util.JSONArray
    DEFINE idxOne DICTIONARY OF util.JSONObject
    DEFINE idxMany DICTIONARY OF util.JSONArray
    DEFINE v, kv, nullStr STRING

    IF kind == "many" THEN
        FOR i = 1 TO relRows.getLength()
            LET robj = relRows.get(i)
            LET kv = robj.get(toProp)
            IF kv IS NULL THEN CONTINUE FOR END IF
            IF NOT idxMany.contains(kv) THEN
                LET idxMany[kv] = util.JSONArray.create()
            END IF
            LET arr = idxMany[kv]
            CALL arr.put(arr.getLength() + 1, robj)
        END FOR
        FOR i = 1 TO rows.getLength()
            LET parent = rows.get(i)
            LET v = parent.get(fromProp)
            IF v IS NOT NULL AND idxMany.contains(v) THEN
                CALL parent.put(navName, idxMany[v])
            ELSE
                CALL parent.put(navName, util.JSONArray.create())
            END IF
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
