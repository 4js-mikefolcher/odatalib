################################################################################
# ODataQuery.4gl
#
# Parses the OData v4 system query options supported in v0 into the normalised
# T_ODataQuery model:
#
#   $select   - comma separated property list
#   $top      - integer
#   $skip     - integer
#   $count    - true|false
#   $orderby  - "prop [asc|desc][, prop [asc|desc]]..."
#   $expand   - comma separated navigation list (captured, shallow)
#   $filter   - comparison and string-function predicates joined by and / or
#
# $filter grammar supported in v0 (flat, no parentheses, no `not`):
#     filter      := predicate ( ('and'|'or') predicate )*
#     predicate   := comparison | function
#     comparison  := property compOp literal           compOp = eq|ne|gt|lt|ge|le
#     function    := fn '(' property ',' string ')'     fn = contains|startswith|endswith
#     literal     := 'quoted string' | number | true | false | null
#
# Unsupported constructs (parentheses grouping, `not`, lambda any/all) set
# ok=FALSE with errorCode "NotImplemented" so the service can answer 501.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT FGL com.fourjs.odatalib.ODataTypes

# Scratch token buffer for the $filter tokeniser (module-private).
PRIVATE DEFINE m_tokens DYNAMIC ARRAY OF STRING

#+ Parse the supported query options into a normalised T_ODataQuery.
#+ Any argument may be NULL (option absent).
PUBLIC FUNCTION parse(
    selectStr STRING,
    filterStr STRING,
    topStr STRING,
    skipStr STRING,
    countStr STRING,
    orderbyStr STRING,
    expandStr STRING)
    RETURNS ODataTypes.T_ODataQuery

    DEFINE q ODataTypes.T_ODataQuery

    LET q.ok = TRUE
    LET q.skip = 0
    LET q.top = 0
    LET q.hasTop = FALSE
    LET q.wantCount = FALSE

    CALL splitList(selectStr) RETURNING q.selectList
    CALL splitList(expandStr) RETURNING q.expand

    IF topStr IS NOT NULL AND topStr.getLength() > 0 THEN
        IF isUnsignedInt(topStr) THEN
            LET q.top = topStr
            LET q.hasTop = TRUE
        ELSE
            CALL setErr(q, "BadRequest", "Invalid $top value") RETURNING q
            RETURN q
        END IF
    END IF

    IF skipStr IS NOT NULL AND skipStr.getLength() > 0 THEN
        IF isUnsignedInt(skipStr) THEN
            LET q.skip = skipStr
        ELSE
            CALL setErr(q, "BadRequest", "Invalid $skip value") RETURNING q
            RETURN q
        END IF
    END IF

    IF countStr IS NOT NULL AND countStr.getLength() > 0 THEN
        IF countStr.toLowerCase() == "true" THEN
            LET q.wantCount = TRUE
        ELSE
            IF countStr.toLowerCase() != "false" THEN
                CALL setErr(q, "BadRequest", "Invalid $count value") RETURNING q
                RETURN q
            END IF
        END IF
    END IF

    IF orderbyStr IS NOT NULL AND orderbyStr.getLength() > 0 THEN
        CALL parseOrderBy(orderbyStr, q) RETURNING q
        IF NOT q.ok THEN RETURN q END IF
    END IF

    IF filterStr IS NOT NULL AND filterStr.getLength() > 0 THEN
        CALL parseFilter(filterStr, q) RETURNING q
        IF NOT q.ok THEN RETURN q END IF
    END IF

    RETURN q
END FUNCTION

# ---------------------------------------------------------------------------
# $orderby
# ---------------------------------------------------------------------------
PRIVATE FUNCTION parseOrderBy(
    s STRING, q ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataQuery
    DEFINE terms DYNAMIC ARRAY OF STRING
    DEFINE i, sp, n INTEGER
    DEFINE term, prop, dir STRING
    DEFINE ob ODataTypes.T_ODataOrderBy

    CALL splitList(s) RETURNING terms
    FOR i = 1 TO terms.getLength()
        LET term = terms[i].trim()
        LET sp = term.getIndexOf(" ", 1)
        IF sp == 0 THEN
            LET prop = term
            LET dir = "asc"
        ELSE
            LET prop = term.subString(1, sp - 1)
            LET dir = term.subString(sp + 1, term.getLength()).trim().toLowerCase()
        END IF
        IF dir != "asc" AND dir != "desc" THEN
            CALL setErr(q, "BadRequest",
                SFMT("Invalid $orderby direction '%1'", dir)) RETURNING q
            RETURN q
        END IF
        LET ob.property = prop
        LET ob.descending = (dir == "desc")
        LET n = q.orderby.getLength() + 1
        LET q.orderby[n].* = ob.*
    END FOR
    RETURN q
END FUNCTION

# ---------------------------------------------------------------------------
# $filter
# ---------------------------------------------------------------------------
PRIVATE FUNCTION parseFilter(
    s STRING, q ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataQuery
    DEFINE pos, n INTEGER
    DEFINE f ODataTypes.T_ODataFilter
    DEFINE nextTok, low STRING

    CALL tokenize(s)

    # Reject grouping / negation we do not support yet.
    IF containsToken("(") AND NOT isFunctionForm() THEN
        CALL setErr(q, "NotImplemented",
            "Parenthesised $filter expressions are not supported in v0")
            RETURNING q
        RETURN q
    END IF
    IF containsToken("not") THEN
        CALL setErr(q, "NotImplemented",
            "The 'not' operator is not supported in $filter in v0")
            RETURNING q
        RETURN q
    END IF

    LET pos = 1
    WHILE pos <= m_tokens.getLength()
        INITIALIZE f.* TO NULL
        CALL readPredicate(pos, f) RETURNING pos, f.*, q.ok, q.errorMessage
        IF NOT q.ok THEN
            LET q.errorCode = "BadRequest"
            RETURN q
        END IF
        # logical operator joining to the next predicate?
        IF pos <= m_tokens.getLength() THEN
            LET nextTok = m_tokens[pos]
            LET low = nextTok.toLowerCase()
            IF low == "and" OR low == "or" THEN
                LET f.conjunction = low
                LET pos = pos + 1
            ELSE
                CALL setErr(q, "BadRequest",
                    SFMT("Expected 'and'/'or' in $filter, found '%1'", nextTok))
                    RETURNING q
                RETURN q
            END IF
        ELSE
            LET f.conjunction = ""
        END IF
        LET n = q.filters.getLength() + 1
        LET q.filters[n].* = f.*
    END WHILE
    RETURN q
END FUNCTION

# Read a single predicate starting at token position `pos`.
# Returns the new position, the filled filter, an ok flag and an error message.
PRIVATE FUNCTION readPredicate(
    pos INTEGER, f ODataTypes.T_ODataFilter)
    RETURNS (INTEGER, ODataTypes.T_ODataFilter, BOOLEAN, STRING)
    DEFINE fn, op STRING

    IF pos > m_tokens.getLength() THEN
        RETURN pos, f.*, FALSE, "Unexpected end of $filter"
    END IF

    LET fn = m_tokens[pos].toLowerCase()
    # function form: fn ( property , 'value' )
    IF fn == "contains" OR fn == "startswith" OR fn == "endswith" THEN
        IF pos + 5 > m_tokens.getLength() THEN
            RETURN pos, f.*, FALSE, "Malformed string function in $filter"
        END IF
        IF m_tokens[pos + 1] != "(" OR m_tokens[pos + 3] != ","
            OR m_tokens[pos + 5] != ")" THEN
            RETURN pos, f.*, FALSE, "Malformed string function in $filter"
        END IF
        LET f.operator = fn
        LET f.property = m_tokens[pos + 2]
        LET f.value = stripQuotes(m_tokens[pos + 4])
        RETURN pos + 6, f.*, TRUE, NULL
    END IF

    # comparison form: property compOp literal
    IF pos + 2 > m_tokens.getLength() THEN
        RETURN pos, f.*, FALSE, "Incomplete comparison in $filter"
    END IF
    LET op = m_tokens[pos + 1].toLowerCase()
    CASE op
        WHEN "eq"
        WHEN "ne"
        WHEN "gt"
        WHEN "lt"
        WHEN "ge"
        WHEN "le"
        OTHERWISE
            RETURN pos, f.*, FALSE,
                SFMT("Unsupported comparison operator '%1'", op)
    END CASE
    LET f.property = m_tokens[pos]
    LET f.operator = op
    # The bare keyword `null` (unquoted) is the OData null literal; the quoted
    # string 'null' is a normal text value. Both strip to "null", so flag the
    # unquoted form here for the SQL layer to translate to IS [NOT] NULL.
    IF m_tokens[pos + 2].getCharAt(1) != "'"
        AND m_tokens[pos + 2].toLowerCase() == "null" THEN
        LET f.isNull = TRUE
    END IF
    LET f.value = stripQuotes(m_tokens[pos + 2])
    RETURN pos + 3, f.*, TRUE, NULL
END FUNCTION

# ---------------------------------------------------------------------------
# Tokeniser for $filter — splits on whitespace, treats ( ) , as single tokens
# and keeps single-quoted strings (incl. spaces) as one token with quotes.
# ---------------------------------------------------------------------------
PRIVATE FUNCTION tokenize(s STRING)
    DEFINE i, n INTEGER
    DEFINE c STRING
    DEFINE cur base.StringBuffer
    DEFINE inStr BOOLEAN = FALSE

    CALL m_tokens.clear()
    LET cur = base.StringBuffer.create()
    LET n = s.getLength()
    LET i = 1
    WHILE i <= n
        LET c = s.getCharAt(i)
        IF inStr THEN
            CALL cur.append(c)
            IF c == "'" THEN
                # OData escapes a quote by doubling it ('')
                IF i < n AND s.getCharAt(i + 1) == "'" THEN
                    CALL cur.append("'")
                    LET i = i + 1
                ELSE
                    LET inStr = FALSE
                END IF
            END IF
        ELSE
            CASE
                WHEN c == "'"
                    CALL cur.append(c)
                    LET inStr = TRUE
                WHEN c == " " OR c == "\t"
                    CALL flushToken(cur)
                WHEN c == "(" OR c == ")" OR c == ","
                    CALL flushToken(cur)
                    LET m_tokens[m_tokens.getLength() + 1] = c
                OTHERWISE
                    CALL cur.append(c)
            END CASE
        END IF
        LET i = i + 1
    END WHILE
    CALL flushToken(cur)
END FUNCTION

PRIVATE FUNCTION flushToken(cur base.StringBuffer)
    DEFINE t STRING
    LET t = cur.toString()
    IF t IS NOT NULL AND t.getLength() > 0 THEN
        LET m_tokens[m_tokens.getLength() + 1] = t
    END IF
    CALL cur.clear()
END FUNCTION

PRIVATE FUNCTION containsToken(want STRING) RETURNS BOOLEAN
    DEFINE i INTEGER
    FOR i = 1 TO m_tokens.getLength()
        IF m_tokens[i].toLowerCase() == want THEN
            RETURN TRUE
        END IF
    END FOR
    RETURN FALSE
END FUNCTION

# TRUE when every "(" in the token stream is part of a supported string
# function call (so a bare "(" means unsupported grouping).
PRIVATE FUNCTION isFunctionForm() RETURNS BOOLEAN
    DEFINE i INTEGER
    DEFINE prev STRING
    FOR i = 1 TO m_tokens.getLength()
        IF m_tokens[i] == "(" THEN
            IF i == 1 THEN
                RETURN FALSE
            END IF
            LET prev = m_tokens[i - 1].toLowerCase()
            IF prev != "contains" AND prev != "startswith"
                AND prev != "endswith" THEN
                RETURN FALSE
            END IF
        END IF
    END FOR
    RETURN TRUE
END FUNCTION

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

#+ Split a comma separated option value into a trimmed dynamic array.
PRIVATE FUNCTION splitList(s STRING) RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE st base.StringTokenizer
    DEFINE part STRING
    IF s IS NULL OR s.getLength() == 0 THEN
        RETURN out
    END IF
    LET st = base.StringTokenizer.create(s, ",")
    WHILE st.hasMoreTokens()
        LET part = st.nextToken().trim()
        IF part.getLength() > 0 THEN
            LET out[out.getLength() + 1] = part
        END IF
    END WHILE
    RETURN out
END FUNCTION

#+ Remove the surrounding single quotes from an OData string literal and
#+ un-double any escaped quotes. Non-quoted literals are returned as-is.
PRIVATE FUNCTION stripQuotes(s STRING) RETURNS STRING
    DEFINE inner STRING
    IF s IS NULL OR s.getLength() < 2 THEN
        RETURN s
    END IF
    IF s.getCharAt(1) == "'" AND s.getCharAt(s.getLength()) == "'" THEN
        LET inner = s.subString(2, s.getLength() - 1)
        # un-double escaped quotes; "'" is not a regex metacharacter
        LET inner = inner.replaceAll("''", "'")
        RETURN inner
    END IF
    RETURN s
END FUNCTION

PRIVATE FUNCTION isUnsignedInt(s STRING) RETURNS BOOLEAN
    DEFINE i INTEGER
    DEFINE c STRING
    IF s IS NULL OR s.getLength() == 0 THEN
        RETURN FALSE
    END IF
    FOR i = 1 TO s.getLength()
        LET c = s.getCharAt(i)
        IF c < "0" OR c > "9" THEN
            RETURN FALSE
        END IF
    END FOR
    RETURN TRUE
END FUNCTION

PRIVATE FUNCTION setErr(
    q ODataTypes.T_ODataQuery, code STRING, msg STRING)
    RETURNS ODataTypes.T_ODataQuery
    LET q.ok = FALSE
    LET q.errorCode = code
    LET q.errorMessage = msg
    RETURN q
END FUNCTION
