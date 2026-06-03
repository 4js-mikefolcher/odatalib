################################################################################
# ODataFunctionProvider.4gl
#
# Provider implementation backing an OData entity with a customer-authored BDL
# function. This is how "BDL business logic" (joins, derived fields, aggregates)
# and the customer's existing access control are exposed over OData, honouring
# the spec's "BDL is the gatekeeper" invariant.
#
# The customer registers a function REFERENCE for an entity set at startup:
#
#     IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider
#     ...
#     CALL ODataFunctionProvider.register(
#         "CountrySummary", FUNCTION MyModule.provideCountrySummary)
#
# The registered function must match T_ODataProviderFunc exactly (including
# parameter names):
#
#     FUNCTION provideCountrySummary(entity STRING, query ODataTypes.T_ODataQuery)
#         RETURNS ODataTypes.T_ODataResult
#
# It returns the matching rows (already filtered / access-controlled) in
# result.rows; THIS module then applies $top/$skip paging, $count and the
# next-page flag uniformly, so simple providers can ignore paging entirely.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig

CONSTANT DEFAULT_PAGE_SIZE = 200
CONSTANT MAX_PAGE_SIZE = 1000

# entity-set name -> customer callback reference
PRIVATE DEFINE m_registry DICTIONARY OF ODataTypes.T_ODataProviderFunc

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

#+ Register a customer callback for a function-backed entity set.
PUBLIC FUNCTION register(
    entityName STRING, fn ODataTypes.T_ODataProviderFunc)
    LET m_registry[entityName] = fn
END FUNCTION

#+ TRUE when a callback has been registered for the entity set.
PUBLIC FUNCTION isRegistered(entityName STRING) RETURNS BOOLEAN
    RETURN m_registry.contains(entityName)
END FUNCTION

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------

#+ Invoke the registered callback, then apply OData paging / count over the
#+ rows it returned.
PUBLIC FUNCTION fetch(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataResult
    DEFINE fn ODataTypes.T_ODataProviderFunc
    DEFINE custRes, res ODataTypes.T_ODataResult
    DEFINE full util.JSONArray
    DEFINE total, pageSize, effLimit, start, i, added INTEGER

    IF NOT m_registry.contains(entity.name) THEN
        RETURN errorResult("NotImplemented",
            SFMT("No function provider registered for '%1'", entity.name))
    END IF

    LET fn = m_registry[entity.name]
    CALL fn(entity.name, query) RETURNING custRes.*
    IF NOT custRes.ok THEN
        # default the error code if the callback left it blank
        IF custRes.errorCode IS NULL THEN
            LET custRes.errorCode = "InternalError"
        END IF
        RETURN custRes
    END IF

    LET full = custRes.rows
    IF full IS NULL THEN
        LET full = util.JSONArray.create()
    END IF
    LET total = full.getLength()

    LET pageSize = entity.pageSize
    IF pageSize <= 0 THEN LET pageSize = DEFAULT_PAGE_SIZE END IF
    IF pageSize > MAX_PAGE_SIZE THEN LET pageSize = MAX_PAGE_SIZE END IF
    LET effLimit = pageSize
    IF query.hasTop AND query.top < pageSize THEN
        LET effLimit = query.top
    END IF

    LET res.ok = TRUE
    LET res.rows = util.JSONArray.create()
    LET start = query.skip + 1
    LET added = 0
    FOR i = start TO total
        IF added >= effLimit THEN EXIT FOR END IF
        CALL res.rows.put(res.rows.getLength() + 1, full.get(i))
        LET added = added + 1
    END FOR

    IF added == effLimit AND effLimit == pageSize
        AND (start + added - 1) < total THEN
        LET res.hasMore = TRUE
    END IF
    IF query.wantCount THEN
        LET res.count = total
    END IF

    RETURN res
END FUNCTION

#+ Single entity by key predicate (single or composite): hand the callback a
#+ query carrying an eq filter per key property and let it filter / access-control.
PUBLIC FUNCTION fetchByKeys(
    entity ODataTypes.T_ODataEntity,
    keyParts DYNAMIC ARRAY OF ODataTypes.T_ODataKeyPart)
    RETURNS ODataTypes.T_ODataResult
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE filters DYNAMIC ARRAY OF ODataTypes.T_ODataFilter
    DEFINE res ODataTypes.T_ODataResult
    DEFINE ok BOOLEAN
    DEFINE err STRING
    DEFINE i INTEGER

    CALL ODataConfig.buildKeyFilters(entity, keyParts) RETURNING filters, ok, err
    IF NOT ok THEN
        RETURN errorResult("BadRequest", err)
    END IF

    LET q.ok = TRUE
    LET q.skip = 0
    LET q.top = 1
    LET q.hasTop = TRUE
    LET q.wantCount = FALSE
    FOR i = 1 TO filters.getLength()
        LET q.filters[i].* = filters[i].*
    END FOR

    LET res = fetch(entity, q)
    IF res.ok AND res.rows.getLength() == 0 THEN
        LET res.ok = FALSE
        LET res.errorCode = "NotFound"
        LET res.errorMessage =
            SFMT("No %1 with key %2",
                entity.name, ODataConfig.keyDescription(keyParts))
    END IF
    RETURN res
END FUNCTION

# ---------------------------------------------------------------------------
# Helpers for callback authors
# ---------------------------------------------------------------------------

#+ A success result with an empty, ready-to-fill row array.
PUBLIC FUNCTION newResult() RETURNS ODataTypes.T_ODataResult
    DEFINE res ODataTypes.T_ODataResult
    LET res.ok = TRUE
    LET res.rows = util.JSONArray.create()
    RETURN res
END FUNCTION

#+ A failure result carrying an OData error code + message.
PUBLIC FUNCTION errorResult(code STRING, msg STRING)
    RETURNS ODataTypes.T_ODataResult
    DEFINE res ODataTypes.T_ODataResult
    LET res.ok = FALSE
    LET res.errorCode = code
    LET res.errorMessage = msg
    RETURN res
END FUNCTION
