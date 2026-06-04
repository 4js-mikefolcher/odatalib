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

# A bound WHERE parameter: the literal value plus the Edm type it must be bound
# as. The ODI driver binds a parameter with the SQL type of the program variable
# passed to setParameter(); a STRING bind sends a varchar, which strict engines
# (Postgres) refuse to compare against numeric / date columns ("operator does not
# exist: real > character varying"). bindParam() converts the value to the right
# program type before binding. LIKE patterns are always bound as text.
PRIVATE TYPE t_bindParam RECORD
    value STRING,
    edmType STRING
END RECORD

# Scratch state for the WHERE-clause builders. A predicate appends its SQL to
# m_whereBuf and its bound value(s) to m_whereParams in the same order, so the
# recursive tree walk keeps the `?` placeholders and the parameters aligned.
# One request is built at a time (the web service engine is single-threaded per
# request), so module-level scratch is safe and avoids by-reference assumptions.
PRIVATE DEFINE m_whereBuf base.StringBuffer
PRIVATE DEFINE m_whereParams DYNAMIC ARRAY OF t_bindParam
PRIVATE DEFINE m_whereErr STRING

#+ Fetch a page of rows for the entity according to the parsed query.
PUBLIC FUNCTION fetch(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataResult

    DEFINE res ODataTypes.T_ODataResult
    DEFINE selProps DYNAMIC ARRAY OF STRING
    DEFINE selEdm DYNAMIC ARRAY OF STRING
    DEFINE params DYNAMIC ARRAY OF t_bindParam
    DEFINE selectClause, whereClause, orderClause, sql STRING
    DEFINE pageSize, effLimit, pos, i, fetched INTEGER
    DEFINE sqlObj base.SqlHandle
    DEFINE rowObj util.JSONObject
    DEFINE prop ODataTypes.T_ODataProperty
    DEFINE found BOOLEAN

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

    # Resolve the Edm type of each selected column once, so the row loop can
    # serialise type-sensitive values (Edm.Single) without a per-row lookup.
    FOR i = 1 TO selProps.getLength()
        CALL ODataConfig.findProperty(entity, selProps[i]) RETURNING prop.*, found
        LET selEdm[i] = prop.edmType
    END FOR

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
    # $expand's batched fetch needs all matching rows (up to a cap), not a server
    # page — maxRows overrides the page limit and suppresses the nextLink probe.
    IF query.maxRows > 0 THEN
        LET effLimit = query.maxRows
    END IF

    LET sql = SFMT("SELECT %1 FROM %2%3%4",
        selectClause, entity.source, whereClause, orderClause)

    TRY
        LET sqlObj = base.SqlHandle.create()
        CALL sqlObj.prepare(sql)
        FOR i = 1 TO params.getLength()
            CALL bindParam(sqlObj, i, params[i].edmType, params[i].value)
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
                IF selEdm[i] == "Edm.Single" THEN
                    # Re-narrow the widened float so the wire value keeps single
                    # precision (a stored 32.38 emits 32.38, not 32.380001…).
                    CALL rowObj.put(selProps[i],
                        singleValue(sqlObj.getResultValue(i)))
                ELSE
                    CALL rowObj.put(selProps[i], sqlObj.getResultValue(i))
                END IF
            END FOR
            CALL res.rows.put(res.rows.getLength() + 1, rowObj)
            LET fetched = fetched + 1
            LET pos = pos + 1
        END WHILE

        # A further server page exists only when we filled a full server page
        # (not when the client capped the result with a small $top, and never on
        # a maxRows expand fetch).
        IF query.maxRows == 0 AND fetched == effLimit AND effLimit == pageSize THEN
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

#+ Fetch a single entity by its key predicate (single or composite). Returns
#+ ok=FALSE / NotFound when absent, BadRequest when the key predicate is invalid.
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

    # Build an eq filter per key property (AND-ed). A bad key predicate is a 400.
    CALL ODataConfig.buildKeyFilters(entity, keyParts) RETURNING filters, ok, err
    IF NOT ok THEN
        LET res.ok = FALSE
        LET res.errorCode = "BadRequest"
        LET res.errorMessage = err
        RETURN res
    END IF

    LET q.ok = TRUE
    LET q.skip = 0
    LET q.top = 1
    LET q.hasTop = TRUE
    LET q.wantCount = FALSE
    FOR i = 1 TO filters.getLength()
        LET q.filters[i].* = filters[i].*
    END FOR

    CALL fetch(entity, q) RETURNING res.*
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
# Dispatches to the expression-tree builder when the parser produced one
# (any user $filter), else the flat builder (the key-lookup path, which sets
# query.filters directly without a tree).
PRIVATE FUNCTION buildWhere(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS (STRING, DYNAMIC ARRAY OF t_bindParam, BOOLEAN, STRING)
    DEFINE clause, err STRING
    DEFINE params DYNAMIC ARRAY OF t_bindParam
    DEFINE ok BOOLEAN
    IF query.filterRoot > 0 THEN
        CALL buildWhereTree(entity, query) RETURNING clause, params, ok, err
    ELSE
        CALL buildWhereFlat(entity, query) RETURNING clause, params, ok, err
    END IF
    RETURN clause, params, ok, err
END FUNCTION

# Tree builder: walk the parsed expression tree, emitting parenthesised SQL with
# AND / OR / NOT and binding parameters in placeholder order.
PRIVATE FUNCTION buildWhereTree(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS (STRING, DYNAMIC ARRAY OF t_bindParam, BOOLEAN, STRING)
    LET m_whereBuf = base.StringBuffer.create()
    CALL m_whereParams.clear()
    LET m_whereErr = NULL

    CALL m_whereBuf.append(" WHERE ")
    CALL buildNode(entity, query, query.filterRoot)
    IF m_whereErr IS NOT NULL THEN
        RETURN NULL, m_whereParams, FALSE, m_whereErr
    END IF
    RETURN m_whereBuf.toString(), m_whereParams, TRUE, NULL
END FUNCTION

# Recursively emit one node of the filter tree into m_whereBuf / m_whereParams.
# Stops descending once m_whereErr is set.
PRIVATE FUNCTION buildNode(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery,
    idx INTEGER)
    DEFINE node ODataTypes.T_ODataFilterNode
    IF m_whereErr IS NOT NULL THEN
        RETURN
    END IF
    LET node.* = query.filterNodes[idx].*
    CASE node.kind
        WHEN "pred"
            CALL appendPredicate(entity, node.pred.*)
        WHEN "not"
            CALL m_whereBuf.append("(NOT ")
            CALL buildNode(entity, query, node.left)
            CALL m_whereBuf.append(")")
        WHEN "and"
            CALL m_whereBuf.append("(")
            CALL buildNode(entity, query, node.left)
            CALL m_whereBuf.append(" AND ")
            CALL buildNode(entity, query, node.right)
            CALL m_whereBuf.append(")")
        WHEN "or"
            CALL m_whereBuf.append("(")
            CALL buildNode(entity, query, node.left)
            CALL m_whereBuf.append(" OR ")
            CALL buildNode(entity, query, node.right)
            CALL m_whereBuf.append(")")
        OTHERWISE
            LET m_whereErr = SFMT("Internal: unknown filter node kind '%1'",
                node.kind)
    END CASE
END FUNCTION

# Flat builder: predicates joined left-to-right by their conjunction field. Used
# by the key-lookup path (a single eq predicate, no tree).
PRIVATE FUNCTION buildWhereFlat(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS (STRING, DYNAMIC ARRAY OF t_bindParam, BOOLEAN, STRING)
    DEFINE i INTEGER
    DEFINE flt ODataTypes.T_ODataFilter

    LET m_whereBuf = base.StringBuffer.create()
    CALL m_whereParams.clear()
    LET m_whereErr = NULL

    IF query.filters.getLength() == 0 THEN
        RETURN "", m_whereParams, TRUE, NULL
    END IF

    CALL m_whereBuf.append(" WHERE ")
    FOR i = 1 TO query.filters.getLength()
        LET flt.* = query.filters[i].*
        CALL appendPredicate(entity, flt.*)
        IF m_whereErr IS NOT NULL THEN
            RETURN NULL, m_whereParams, FALSE, m_whereErr
        END IF
        IF flt.conjunction == "and" THEN
            CALL m_whereBuf.append(" AND ")
        ELSE
            IF flt.conjunction == "or" THEN
                CALL m_whereBuf.append(" OR ")
            END IF
        END IF
    END FOR
    RETURN m_whereBuf.toString(), m_whereParams, TRUE, NULL
END FUNCTION

# Emit a single predicate fragment "(col op ?)" / "(col IS [NOT] NULL)" / a LIKE
# clause into m_whereBuf, appending its bound parameter (if any) to m_whereParams.
# Sets m_whereErr on an unknown property / unsupported operator / bad literal.
PRIVATE FUNCTION appendPredicate(
    entity ODataTypes.T_ODataEntity, flt ODataTypes.T_ODataFilter)
    DEFINE col, sqlOp, boundVal, bindType, vmsg STRING
    DEFINE prop ODataTypes.T_ODataProperty
    DEFINE found, vok, isLike BOOLEAN
    DEFINE n INTEGER

    CALL ODataConfig.findProperty(entity, flt.property) RETURNING prop.*, found
    IF NOT found THEN
        LET m_whereErr = SFMT("Unknown property '%1' in $filter", flt.property)
        RETURN
    END IF
    LET col = prop.column
    IF col IS NULL OR col.getLength() == 0 THEN
        LET col = prop.name
    END IF

    IF flt.isNull THEN
        # The OData null literal maps to SQL IS [NOT] NULL with no bound
        # parameter. Relational operators against null are not meaningful, so
        # restrict it to eq / ne.
        CASE flt.operator
            WHEN "eq" CALL m_whereBuf.append(SFMT("(%1 IS NULL)", col))
            WHEN "ne" CALL m_whereBuf.append(SFMT("(%1 IS NOT NULL)", col))
            OTHERWISE
                LET m_whereErr =
                    SFMT("The null literal is only supported with eq/ne (got '%1')",
                        flt.operator)
        END CASE
        RETURN
    END IF

    # `in` (value list): (col IN (?,?,...)) with one type-aware bind per value.
    # An empty list can never match, so emit a guaranteed-false predicate.
    IF flt.operator == "in" THEN
        CALL appendInPredicate(col, prop.edmType, flt.values)
        RETURN
    END IF

    LET boundVal = flt.value
    # Comparisons bind as the column's declared Edm type so the driver sends a
    # correctly-typed SQL parameter; LIKE patterns are always textual. For the
    # string functions the user value is wildcard-escaped (%, _, \) so it is
    # matched literally — only the framework's own %/_ act as wildcards.
    LET bindType = prop.edmType
    LET isLike = FALSE
    CASE flt.operator
        WHEN "eq" LET sqlOp = "="
        WHEN "ne" LET sqlOp = "<>"
        WHEN "gt" LET sqlOp = ">"
        WHEN "lt" LET sqlOp = "<"
        WHEN "ge" LET sqlOp = ">="
        WHEN "le" LET sqlOp = "<="
        WHEN "contains"
            LET isLike = TRUE
            LET boundVal = SFMT("%%%1%%", escapeLike(flt.value))
            LET bindType = "Edm.String"
        WHEN "startswith"
            LET isLike = TRUE
            LET boundVal = SFMT("%1%%", escapeLike(flt.value))
            LET bindType = "Edm.String"
        WHEN "endswith"
            LET isLike = TRUE
            LET boundVal = SFMT("%%%1", escapeLike(flt.value))
            LET bindType = "Edm.String"
        OTHERWISE
            LET m_whereErr = SFMT("Unsupported operator '%1'", flt.operator)
            RETURN
    END CASE

    # Reject a literal that does not match its column type as a clean 400,
    # rather than letting the database raise a 500-level bind error.
    CALL validateLiteral(bindType, boundVal) RETURNING vok, vmsg
    IF NOT vok THEN
        LET m_whereErr = vmsg
        RETURN
    END IF

    IF isLike THEN
        # Backslash escape char (doubled in the BDL literal); standard SQL,
        # honoured by Postgres/Informix/Oracle/SQL Server/MySQL.
        CALL m_whereBuf.append(SFMT("(%1 LIKE ? ESCAPE '\\')", col))
    ELSE
        CALL m_whereBuf.append(SFMT("(%1 %2 ?)", col, sqlOp))
    END IF
    LET n = m_whereParams.getLength() + 1
    LET m_whereParams[n].value = boundVal
    LET m_whereParams[n].edmType = bindType
END FUNCTION

# Emit (col IN (?,?,...)) into m_whereBuf, binding each value type-aware against
# edmType. An empty list yields a guaranteed-false predicate (so an empty parent
# page expands to no related rows). Sets m_whereErr on a bad literal.
PRIVATE FUNCTION appendInPredicate(
    col STRING, edmType STRING, values DYNAMIC ARRAY OF STRING)
    DEFINE k, n INTEGER
    DEFINE vok BOOLEAN
    DEFINE vmsg STRING

    IF values.getLength() == 0 THEN
        CALL m_whereBuf.append("(1=0)")
        RETURN
    END IF
    CALL m_whereBuf.append(SFMT("(%1 IN (", col))
    FOR k = 1 TO values.getLength()
        CALL validateLiteral(edmType, values[k]) RETURNING vok, vmsg
        IF NOT vok THEN
            LET m_whereErr = vmsg
            RETURN
        END IF
        IF k > 1 THEN CALL m_whereBuf.append(",") END IF
        CALL m_whereBuf.append("?")
        LET n = m_whereParams.getLength() + 1
        LET m_whereParams[n].value = values[k]
        LET m_whereParams[n].edmType = edmType
    END FOR
    CALL m_whereBuf.append("))")
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
    DEFINE params DYNAMIC ARRAY OF t_bindParam
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
            CALL bindParam(sqlObj, i, params[i].edmType, params[i].value)
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

# ---------------------------------------------------------------------------
# Type-aware parameter binding
# ---------------------------------------------------------------------------

#+ Bind a WHERE parameter using the program-variable type implied by its Edm
#+ type, so the ODI driver sends a correctly-typed SQL parameter. Textual and
#+ unhandled Edm types fall back to a string bind (the prior behaviour). Values
#+ are assumed already validated by validateLiteral().
PRIVATE FUNCTION bindParam(
    sqlObj base.SqlHandle, idx INTEGER, edmType STRING, val STRING)
    DEFINE iv INTEGER
    DEFINE bv BIGINT
    DEFINE fv FLOAT
    DEFINE dv DECIMAL
    DEFINE dt DATE

    CASE edmType
        WHEN "Edm.Int16"
            LET iv = val
            CALL sqlObj.setParameter(idx, iv)
        WHEN "Edm.Int32"
            LET iv = val
            CALL sqlObj.setParameter(idx, iv)
        WHEN "Edm.Byte"
            LET iv = val
            CALL sqlObj.setParameter(idx, iv)
        WHEN "Edm.SByte"
            LET iv = val
            CALL sqlObj.setParameter(idx, iv)
        WHEN "Edm.Int64"
            LET bv = val
            CALL sqlObj.setParameter(idx, bv)
        WHEN "Edm.Single"
            LET fv = val
            CALL sqlObj.setParameter(idx, fv)
        WHEN "Edm.Double"
            LET fv = val
            CALL sqlObj.setParameter(idx, fv)
        WHEN "Edm.Decimal"
            LET dv = val
            CALL sqlObj.setParameter(idx, dv)
        WHEN "Edm.Date"
            LET dt = isoToDate(val)
            CALL sqlObj.setParameter(idx, dt)
        OTHERWISE
            # Edm.String, Edm.Boolean, Edm.Guid, Edm.DateTimeOffset, unknown
            CALL sqlObj.setParameter(idx, val)
    END CASE
END FUNCTION

#+ Validate an OData literal against the Edm type it will be bound as. Returns
#+ (TRUE, NULL) when acceptable, else (FALSE, <BadRequest message>).
PRIVATE FUNCTION validateLiteral(edmType STRING, val STRING)
    RETURNS (BOOLEAN, STRING)
    CASE edmType
        WHEN "Edm.Int16"
            IF NOT isIntLiteral(val) THEN RETURN FALSE, badLiteral(val, "integer") END IF
        WHEN "Edm.Int32"
            IF NOT isIntLiteral(val) THEN RETURN FALSE, badLiteral(val, "integer") END IF
        WHEN "Edm.Int64"
            IF NOT isIntLiteral(val) THEN RETURN FALSE, badLiteral(val, "integer") END IF
        WHEN "Edm.Byte"
            IF NOT isIntLiteral(val) THEN RETURN FALSE, badLiteral(val, "integer") END IF
        WHEN "Edm.SByte"
            IF NOT isIntLiteral(val) THEN RETURN FALSE, badLiteral(val, "integer") END IF
        WHEN "Edm.Single"
            IF NOT isDecimalLiteral(val) THEN RETURN FALSE, badLiteral(val, "number") END IF
        WHEN "Edm.Double"
            IF NOT isDecimalLiteral(val) THEN RETURN FALSE, badLiteral(val, "number") END IF
        WHEN "Edm.Decimal"
            IF NOT isDecimalLiteral(val) THEN RETURN FALSE, badLiteral(val, "number") END IF
        WHEN "Edm.Date"
            IF NOT isIsoDate(val) THEN RETURN FALSE, badLiteral(val, "date (yyyy-mm-dd)") END IF
        OTHERWISE
            # textual / unvalidated types pass through
    END CASE
    RETURN TRUE, NULL
END FUNCTION

PRIVATE FUNCTION badLiteral(val STRING, want STRING) RETURNS STRING
    RETURN SFMT("Invalid %1 value '%2' in $filter", want, val)
END FUNCTION

#+ TRUE for an optionally-signed run of decimal digits, e.g. "42" or "-7".
PRIVATE FUNCTION isIntLiteral(s STRING) RETURNS BOOLEAN
    DEFINE i, start INTEGER
    DEFINE c STRING
    IF s IS NULL OR s.getLength() == 0 THEN
        RETURN FALSE
    END IF
    LET start = 1
    IF s.getCharAt(1) == "-" OR s.getCharAt(1) == "+" THEN
        LET start = 2
    END IF
    IF start > s.getLength() THEN
        RETURN FALSE
    END IF
    FOR i = start TO s.getLength()
        LET c = s.getCharAt(i)
        IF c < "0" OR c > "9" THEN
            RETURN FALSE
        END IF
    END FOR
    RETURN TRUE
END FUNCTION

#+ TRUE for a decimal / floating literal: optional sign, digits, optional single
#+ '.', optional exponent (e/E with optional sign). Must hold at least one digit.
PRIVATE FUNCTION isDecimalLiteral(s STRING) RETURNS BOOLEAN
    DEFINE i, n, digits INTEGER
    DEFINE c STRING
    DEFINE seenDot, seenExp BOOLEAN

    IF s IS NULL OR s.getLength() == 0 THEN
        RETURN FALSE
    END IF
    LET n = s.getLength()
    LET i = 1
    IF s.getCharAt(1) == "-" OR s.getCharAt(1) == "+" THEN
        LET i = 2
    END IF
    LET digits = 0
    WHILE i <= n
        LET c = s.getCharAt(i)
        CASE
            WHEN c >= "0" AND c <= "9"
                LET digits = digits + 1
            WHEN c == "."
                IF seenDot OR seenExp THEN RETURN FALSE END IF
                LET seenDot = TRUE
            WHEN c == "e" OR c == "E"
                IF seenExp OR digits == 0 THEN RETURN FALSE END IF
                LET seenExp = TRUE
                LET digits = 0
                # an optional sign may immediately follow the exponent marker
                IF i < n AND (s.getCharAt(i + 1) == "-"
                    OR s.getCharAt(i + 1) == "+") THEN
                    LET i = i + 1
                END IF
            OTHERWISE
                RETURN FALSE
        END CASE
        LET i = i + 1
    END WHILE
    RETURN digits > 0
END FUNCTION

#+ TRUE for a strict ISO date literal "yyyy-mm-dd" (the OData Edm.Date form).
PRIVATE FUNCTION isIsoDate(s STRING) RETURNS BOOLEAN
    DEFINE i INTEGER
    DEFINE c STRING
    IF s IS NULL OR s.getLength() != 10 THEN
        RETURN FALSE
    END IF
    IF s.getCharAt(5) != "-" OR s.getCharAt(8) != "-" THEN
        RETURN FALSE
    END IF
    FOR i = 1 TO 10
        IF i == 5 OR i == 8 THEN CONTINUE FOR END IF
        LET c = s.getCharAt(i)
        IF c < "0" OR c > "9" THEN
            RETURN FALSE
        END IF
    END FOR
    RETURN TRUE
END FUNCTION

#+ Convert a validated "yyyy-mm-dd" literal to a DATE without depending on the
#+ runtime date format (MDY takes month, day, year).
PRIVATE FUNCTION isoToDate(s STRING) RETURNS DATE
    RETURN MDY(s.subString(6, 7), s.subString(9, 10), s.subString(1, 4))
END FUNCTION

#+ Narrow a value read from an Edm.Single (4-byte float) column back to single
#+ precision for serialisation. The driver widens float4 to float8, so a stored
#+ 32.38 reads as 32.380001068115234; assigning through SMALLFLOAT and its clean
#+ ~7-significant-digit text form recovers 32.38, and the DECIMAL result puts as
#+ an unquoted JSON number. NULL passes through as JSON null.
PRIVATE FUNCTION singleValue(raw SMALLFLOAT) RETURNS DECIMAL
    DEFINE s STRING
    IF raw IS NULL THEN
        RETURN NULL
    END IF
    LET s = raw
    RETURN s
END FUNCTION

#+ Escape the LIKE wildcard metacharacters (\, %, _) in a user-supplied
#+ contains/startswith/endswith value so they match literally. Paired with an
#+ ESCAPE '\' clause on the LIKE predicate. Done char-by-char (not replaceAll,
#+ which is regex-based and would mishandle the backslash).
PRIVATE FUNCTION escapeLike(s STRING) RETURNS STRING
    DEFINE buf base.StringBuffer
    DEFINE i INTEGER
    DEFINE c STRING
    IF s IS NULL THEN
        RETURN s
    END IF
    LET buf = base.StringBuffer.create()
    FOR i = 1 TO s.getLength()
        LET c = s.getCharAt(i)
        IF c == "\\" OR c == "%" OR c == "_" THEN
            CALL buf.append("\\")
        END IF
        CALL buf.append(c)
    END FOR
    RETURN buf.toString()
END FUNCTION
