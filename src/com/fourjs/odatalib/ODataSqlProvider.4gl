################################################################################
# ODataSqlProvider.4gl
#
# Provider implementation that backs an OData entity set with a database table
# or view. Translates the normalised T_ODataQuery into parameterised dynamic
# SQL run through base.SqlHandle, then materialises rows into a util.JSONArray
# keyed by OData property name.
#
# Design notes:
#   * Only declared properties are ever selected (never SELECT *), so the wire
#     shape is fully controlled by the .odata config.
#   * JSON keys are taken from the config property names by SELECT position,
#     not from getResultName(), so they are stable across database engines.
#   * Paging uses a scroll cursor + fetchAbsolute(), which is database-agnostic
#     (no dialect-specific LIMIT/OFFSET / TOP/SKIP).
#   * Filter values are bound as parameters (?), never concatenated into SQL.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig

CONSTANT DEFAULT_PAGE_SIZE = 200
CONSTANT MAX_PAGE_SIZE = 1000

#+ Fetch a page of rows for the entity according to the parsed query.
PUBLIC FUNCTION fetch(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataResult

    DEFINE res ODataTypes.T_ODataResult
    DEFINE selProps DYNAMIC ARRAY OF STRING
    DEFINE params DYNAMIC ARRAY OF STRING
    DEFINE selectClause, whereClause, orderClause, sql STRING
    DEFINE pageSize, effLimit, pos, i, fetched INTEGER
    DEFINE sqlObj base.SqlHandle
    DEFINE rowObj util.JSONObject

    LET res.ok = TRUE
    LET res.rows = util.JSONArray.create()
    LET res.count = 0
    LET res.hasMore = FALSE

    CALL buildSelect(entity, query)
        RETURNING selectClause, selProps, res.ok, res.errorMessage
    IF NOT res.ok THEN
        LET res.errorCode = "BadRequest"
        RETURN res
    END IF

    CALL buildWhere(entity, query)
        RETURNING whereClause, params, res.ok, res.errorMessage
    IF NOT res.ok THEN
        LET res.errorCode = "BadRequest"
        RETURN res
    END IF

    CALL buildOrderBy(entity, query)
        RETURNING orderClause, res.ok, res.errorMessage
    IF NOT res.ok THEN
        LET res.errorCode = "BadRequest"
        RETURN res
    END IF

    LET pageSize = entity.pageSize
    IF pageSize <= 0 THEN LET pageSize = DEFAULT_PAGE_SIZE END IF
    IF pageSize > MAX_PAGE_SIZE THEN LET pageSize = MAX_PAGE_SIZE END IF
    LET effLimit = pageSize
    IF query.hasTop AND query.top < pageSize THEN
        LET effLimit = query.top
    END IF

    LET sql = SFMT("SELECT %1 FROM %2%3%4",
        selectClause, entity.source, whereClause, orderClause)

    TRY
        LET sqlObj = base.SqlHandle.create()
        CALL sqlObj.prepare(sql)
        FOR i = 1 TO params.getLength()
            CALL sqlObj.setParameter(i, params[i])
        END FOR
        CALL sqlObj.openScrollCursor()

        LET pos = query.skip + 1
        LET fetched = 0
        WHILE fetched < effLimit
            CALL sqlObj.fetchAbsolute(pos)
            IF sqlca.sqlcode == NOTFOUND THEN
                EXIT WHILE
            END IF
            LET rowObj = util.JSONObject.create()
            FOR i = 1 TO selProps.getLength()
                CALL rowObj.put(selProps[i], sqlObj.getResultValue(i))
            END FOR
            CALL res.rows.put(res.rows.getLength() + 1, rowObj)
            LET fetched = fetched + 1
            LET pos = pos + 1
        END WHILE

        # A further server page exists only when we filled a full server page
        # (not when the client capped the result with a small $top).
        IF fetched == effLimit AND effLimit == pageSize THEN
            CALL sqlObj.fetchAbsolute(pos)
            IF sqlca.sqlcode != NOTFOUND THEN
                LET res.hasMore = TRUE
            END IF
        END IF

        CALL sqlObj.close()
    CATCH
        LET res.ok = FALSE
        LET res.errorCode = "InternalError"
        LET res.errorMessage = SFMT("Database error (SQLCODE %1)", sqlca.sqlcode)
        RETURN res
    END TRY

    IF query.wantCount THEN
        CALL countRows(entity, query)
            RETURNING res.count, res.ok, res.errorMessage
        IF NOT res.ok THEN
            LET res.errorCode = "InternalError"
            RETURN res
        END IF
    END IF

    RETURN res
END FUNCTION

#+ Fetch a single entity by key value. Returns ok=FALSE / NotFound when absent.
PUBLIC FUNCTION fetchByKey(
    entity ODataTypes.T_ODataEntity, keyValue STRING)
    RETURNS ODataTypes.T_ODataResult
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE f ODataTypes.T_ODataFilter
    DEFINE res ODataTypes.T_ODataResult

    # Build a query that filters on the key property.
    LET q.ok = TRUE
    LET q.skip = 0
    LET q.top = 1
    LET q.hasTop = TRUE
    LET q.wantCount = FALSE
    LET f.property = entity.keyName
    LET f.operator = "eq"
    LET f.value = keyValue
    LET f.conjunction = ""
    LET q.filters[1].* = f.*

    CALL fetch(entity, q) RETURNING res.*
    IF res.ok AND res.rows.getLength() == 0 THEN
        LET res.ok = FALSE
        LET res.errorCode = "NotFound"
        LET res.errorMessage =
            SFMT("No %1 with key '%2'", entity.name, keyValue)
    END IF
    RETURN res
END FUNCTION

# ---------------------------------------------------------------------------
# Clause builders
# ---------------------------------------------------------------------------

# Returns: select-list SQL, the ordered property-name list, ok, error message.
PRIVATE FUNCTION buildSelect(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS (STRING, DYNAMIC ARRAY OF STRING, BOOLEAN, STRING)
    DEFINE selProps DYNAMIC ARRAY OF STRING
    DEFINE buf base.StringBuffer
    DEFINE i INTEGER
    DEFINE col, prop STRING

    LET buf = base.StringBuffer.create()

    IF query.selectList.getLength() > 0 THEN
        FOR i = 1 TO query.selectList.getLength()
            LET prop = query.selectList[i]
            LET col = ODataConfig.columnFor(entity, prop)
            IF col IS NULL THEN
                RETURN NULL, selProps,
                    FALSE, SFMT("Unknown property '%1' in $select", prop)
            END IF
            IF i > 1 THEN CALL buf.append(", ") END IF
            CALL buf.append(col)
            LET selProps[i] = prop
        END FOR
    ELSE
        FOR i = 1 TO entity.properties.getLength()
            LET prop = entity.properties[i].name
            LET col = ODataConfig.columnFor(entity, prop)
            IF i > 1 THEN CALL buf.append(", ") END IF
            CALL buf.append(col)
            LET selProps[i] = prop
        END FOR
    END IF

    RETURN buf.toString(), selProps, TRUE, NULL
END FUNCTION

# Returns: " WHERE ..." clause (or ""), bound parameter values, ok, error.
PRIVATE FUNCTION buildWhere(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS (STRING, DYNAMIC ARRAY OF STRING, BOOLEAN, STRING)
    DEFINE params DYNAMIC ARRAY OF STRING
    DEFINE buf base.StringBuffer
    DEFINE i INTEGER
    DEFINE col, sqlOp, boundVal STRING
    DEFINE flt ODataTypes.T_ODataFilter

    IF query.filters.getLength() == 0 THEN
        RETURN "", params, TRUE, NULL
    END IF

    LET buf = base.StringBuffer.create()
    CALL buf.append(" WHERE ")

    FOR i = 1 TO query.filters.getLength()
        LET flt.* = query.filters[i].*
        LET col = ODataConfig.columnFor(entity, flt.property)
        IF col IS NULL THEN
            RETURN NULL, params,
                FALSE, SFMT("Unknown property '%1' in $filter", flt.property)
        END IF

        LET boundVal = flt.value
        CASE flt.operator
            WHEN "eq" LET sqlOp = "="
            WHEN "ne" LET sqlOp = "<>"
            WHEN "gt" LET sqlOp = ">"
            WHEN "lt" LET sqlOp = "<"
            WHEN "ge" LET sqlOp = ">="
            WHEN "le" LET sqlOp = "<="
            WHEN "contains"
                LET sqlOp = "LIKE"
                LET boundVal = SFMT("%%%1%%", flt.value)
            WHEN "startswith"
                LET sqlOp = "LIKE"
                LET boundVal = SFMT("%1%%", flt.value)
            WHEN "endswith"
                LET sqlOp = "LIKE"
                LET boundVal = SFMT("%%%1", flt.value)
            OTHERWISE
                RETURN NULL, params,
                    FALSE, SFMT("Unsupported operator '%1'", flt.operator)
        END CASE

        CALL buf.append(SFMT("(%1 %2 ?)", col, sqlOp))
        LET params[params.getLength() + 1] = boundVal

        IF flt.conjunction == "and" THEN
            CALL buf.append(" AND ")
        ELSE
            IF flt.conjunction == "or" THEN
                CALL buf.append(" OR ")
            END IF
        END IF
    END FOR

    RETURN buf.toString(), params, TRUE, NULL
END FUNCTION

# Returns: " ORDER BY ..." clause (or ""), ok, error.
PRIVATE FUNCTION buildOrderBy(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS (STRING, BOOLEAN, STRING)
    DEFINE buf base.StringBuffer
    DEFINE i INTEGER
    DEFINE col STRING

    IF query.orderby.getLength() == 0 THEN
        RETURN "", TRUE, NULL
    END IF

    LET buf = base.StringBuffer.create()
    CALL buf.append(" ORDER BY ")
    FOR i = 1 TO query.orderby.getLength()
        LET col = ODataConfig.columnFor(entity, query.orderby[i].property)
        IF col IS NULL THEN
            RETURN NULL, FALSE,
                SFMT("Unknown property '%1' in $orderby",
                    query.orderby[i].property)
        END IF
        IF i > 1 THEN CALL buf.append(", ") END IF
        CALL buf.append(col)
        IF query.orderby[i].descending THEN
            CALL buf.append(" DESC")
        END IF
    END FOR

    RETURN buf.toString(), TRUE, NULL
END FUNCTION

# Returns: total matching count, ok, error.
PRIVATE FUNCTION countRows(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS (INTEGER, BOOLEAN, STRING)
    DEFINE params DYNAMIC ARRAY OF STRING
    DEFINE whereClause, sql, dummy STRING
    DEFINE ok BOOLEAN
    DEFINE i, cnt INTEGER
    DEFINE sqlObj base.SqlHandle

    CALL buildWhere(entity, query) RETURNING whereClause, params, ok, dummy
    IF NOT ok THEN
        RETURN 0, FALSE, dummy
    END IF

    LET sql = SFMT("SELECT COUNT(*) FROM %1%2", entity.source, whereClause)
    TRY
        LET sqlObj = base.SqlHandle.create()
        CALL sqlObj.prepare(sql)
        FOR i = 1 TO params.getLength()
            CALL sqlObj.setParameter(i, params[i])
        END FOR
        CALL sqlObj.open()
        CALL sqlObj.fetch()
        IF sqlca.sqlcode == NOTFOUND THEN
            LET cnt = 0
        ELSE
            LET cnt = sqlObj.getResultValue(1)
        END IF
        CALL sqlObj.close()
    CATCH
        RETURN 0, FALSE, SFMT("Count failed (SQLCODE %1)", sqlca.sqlcode)
    END TRY

    RETURN cnt, TRUE, NULL
END FUNCTION
