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

# Scratch state for the $filter tokeniser + recursive-descent parser (module-
# private; one request is parsed at a time).
PRIVATE DEFINE m_tokens DYNAMIC ARRAY OF STRING
PRIVATE DEFINE m_tpos INTEGER                                  # parser cursor
PRIVATE DEFINE m_nodes DYNAMIC ARRAY OF ODataTypes.T_ODataFilterNode
PRIVATE DEFINE m_perr STRING                                   # parse error (NULL = ok)
PRIVATE DEFINE m_pcode STRING                                  # error code for m_perr (default BadRequest)
PRIVATE DEFINE m_lambdaVar STRING                              # active lambda variable (strip "var/" in P)
PRIVATE DEFINE m_inLambda BOOLEAN                              # inside a lambda body (reject nesting)

# Scratch state for the $expand forest parser. Nodes (all nesting levels) are
# appended to m_expandNodes and referenced by 1-based index; parseExpand commits
# the pool into the query. m_expandErr/m_expandCode carry a parse failure.
PRIVATE DEFINE m_expandNodes DYNAMIC ARRAY OF ODataTypes.T_ODataExpandNode
PRIVATE DEFINE m_expandErr STRING                             # parse error (NULL = ok)
PRIVATE DEFINE m_expandCode STRING                           # BadRequest | NotImplemented

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

    IF expandStr IS NOT NULL AND expandStr.getLength() > 0 THEN
        CALL parseExpand(expandStr, q) RETURNING q
        IF NOT q.ok THEN RETURN q END IF
    END IF

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
# $expand
#
# Grammar:
#     $expand = item ( ',' item )*
#     item    = NAME [ '(' option ( ';' option )* ')' ]
#     option  = '$select'  '=' proplist
#             | '$filter'  '=' <$filter grammar, target-relative>
#             | '$orderby' '=' <$orderby grammar>
#             | '$top'     '=' uint
#             | '$skip'    '=' uint
#             | '$count'   '=' true|false
#             | '$expand'  '=' item ( ',' item )*          (recursive; depth-capped)
#
# The forest is flattened into the module pool m_expandNodes; each item becomes a
# node and nested items are referenced by their pool index (childRoots). $select
# lives on the node; $filter/$orderby are parsed via the existing top-level
# parsers into a throwaway query and lifted onto the node. Any other option (or
# '*') => 501; a malformed option => 400.
# ---------------------------------------------------------------------------
PRIVATE FUNCTION parseExpand(
    s STRING, q ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataQuery
    DEFINE roots DYNAMIC ARRAY OF INTEGER
    DEFINE i INTEGER

    CALL m_expandNodes.clear()
    LET m_expandErr = NULL
    LET m_expandCode = NULL

    CALL parseExpandList(s) RETURNING roots
    IF m_expandErr IS NOT NULL THEN
        CALL setErr(q, m_expandCode, m_expandErr) RETURNING q
        RETURN q
    END IF

    FOR i = 1 TO m_expandNodes.getLength()
        LET q.expandNodes[i].* = m_expandNodes[i].*
    END FOR
    FOR i = 1 TO roots.getLength()
        LET q.expandRoots[i] = roots[i]
    END FOR
    RETURN q
END FUNCTION

# Parse a comma-separated list of $expand items into the pool; return their node
# indices. On error sets m_expandErr/m_expandCode and returns what parsed so far.
PRIVATE FUNCTION parseExpandList(s STRING) RETURNS DYNAMIC ARRAY OF INTEGER
    DEFINE items DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF INTEGER
    DEFINE i, idx INTEGER

    CALL splitExpandItems(s) RETURNING items
    FOR i = 1 TO items.getLength()
        LET idx = parseExpandItem(items[i])
        IF m_expandErr IS NOT NULL THEN RETURN out END IF
        IF idx > 0 THEN
            LET out[out.getLength() + 1] = idx
        END IF
    END FOR
    RETURN out
END FUNCTION

# Parse one $expand item ("NAME" or "NAME(opts)"), append its node to the pool,
# return the new node's index (0 when the item is empty/skipped or on error).
PRIVATE FUNCTION parseExpandItem(rawItem STRING) RETURNS INTEGER
    DEFINE node ODataTypes.T_ODataExpandNode
    DEFINE item, nm, inner STRING
    DEFINE lp, n INTEGER

    LET item = rawItem.trim()
    IF item.getLength() == 0 THEN RETURN 0 END IF
    IF item == "*" THEN
        LET m_expandCode = "NotImplemented"
        LET m_expandErr = "$expand=* is not supported"
        RETURN 0
    END IF

    LET lp = item.getIndexOf("(", 1)
    IF lp > 0 THEN
        IF item.getCharAt(item.getLength()) != ")" THEN
            LET m_expandCode = "BadRequest"
            LET m_expandErr = "Malformed $expand option (unbalanced parentheses)"
            RETURN 0
        END IF
        LET nm = item.subString(1, lp - 1).trim()
        LET inner = item.subString(lp + 1, item.getLength() - 1)
        CALL parseExpandOptions(inner, node) RETURNING node
        IF m_expandErr IS NOT NULL THEN RETURN 0 END IF
    ELSE
        LET nm = item
    END IF

    IF nm.getLength() == 0 THEN
        LET m_expandCode = "BadRequest"
        LET m_expandErr = "Missing navigation property in $expand"
        RETURN 0
    END IF
    LET node.path = nm
    LET n = m_expandNodes.getLength() + 1
    LET m_expandNodes[n].* = node.*
    RETURN n
END FUNCTION

# Parse the ';'-separated nested options of one $expand item into `node`. A
# nested $filter/$orderby is parsed by the existing top-level parsers into a
# throwaway query and lifted onto the node; a nested $expand recurses into the
# pool. Sets m_expandErr/m_expandCode on failure.
PRIVATE FUNCTION parseExpandOptions(
    inner STRING, node ODataTypes.T_ODataExpandNode)
    RETURNS ODataTypes.T_ODataExpandNode
    DEFINE opts DYNAMIC ARRAY OF STRING
    DEFINE childRoots DYNAMIC ARRAY OF INTEGER
    DEFINE tmp ODataTypes.T_ODataQuery
    DEFINE opt, key, val STRING
    DEFINE i, eq, j INTEGER

    CALL splitNestedOptions(inner) RETURNING opts
    FOR i = 1 TO opts.getLength()
        LET opt = opts[i].trim()
        IF opt.getLength() == 0 THEN CONTINUE FOR END IF
        LET eq = opt.getIndexOf("=", 1)
        IF eq <= 0 THEN
            LET m_expandCode = "BadRequest"
            LET m_expandErr = SFMT("Malformed $expand option '%1'", opt)
            RETURN node
        END IF
        LET key = opt.subString(1, eq - 1).trim().toLowerCase()
        LET val = opt.subString(eq + 1, opt.getLength())
        CASE key
            WHEN "$select"
                CALL splitList(val) RETURNING node.selectList
            WHEN "$orderby"
                INITIALIZE tmp.* TO NULL
                LET tmp.ok = TRUE
                CALL parseOrderBy(val, tmp) RETURNING tmp
                IF NOT tmp.ok THEN
                    LET m_expandCode = tmp.errorCode
                    LET m_expandErr = tmp.errorMessage
                    RETURN node
                END IF
                FOR j = 1 TO tmp.orderby.getLength()
                    LET node.orderby[j].* = tmp.orderby[j].*
                END FOR
            WHEN "$filter"
                INITIALIZE tmp.* TO NULL
                LET tmp.ok = TRUE
                CALL parseFilter(val, tmp) RETURNING tmp
                IF NOT tmp.ok THEN
                    LET m_expandCode = tmp.errorCode
                    LET m_expandErr = tmp.errorMessage
                    RETURN node
                END IF
                FOR j = 1 TO tmp.filterNodes.getLength()
                    LET node.filterNodes[j].* = tmp.filterNodes[j].*
                END FOR
                LET node.filterRoot = tmp.filterRoot
            WHEN "$top"
                IF isUnsignedInt(val.trim()) THEN
                    LET node.top = val.trim()
                    LET node.hasTop = TRUE
                ELSE
                    LET m_expandCode = "BadRequest"
                    LET m_expandErr = "Invalid $top value in $expand"
                    RETURN node
                END IF
            WHEN "$skip"
                IF isUnsignedInt(val.trim()) THEN
                    LET node.skip = val.trim()
                ELSE
                    LET m_expandCode = "BadRequest"
                    LET m_expandErr = "Invalid $skip value in $expand"
                    RETURN node
                END IF
            WHEN "$count"
                CASE val.trim().toLowerCase()
                    WHEN "true"  LET node.wantCount = TRUE
                    WHEN "false" LET node.wantCount = FALSE
                    OTHERWISE
                        LET m_expandCode = "BadRequest"
                        LET m_expandErr = "Invalid $count value in $expand"
                        RETURN node
                END CASE
            WHEN "$expand"
                CALL parseExpandList(val) RETURNING childRoots
                IF m_expandErr IS NOT NULL THEN RETURN node END IF
                FOR j = 1 TO childRoots.getLength()
                    LET node.childRoots[j] = childRoots[j]
                END FOR
            OTHERWISE
                LET m_expandCode = "NotImplemented"
                LET m_expandErr =
                    SFMT("The $expand option '%1' is not supported", key)
                RETURN node
        END CASE
    END FOR
    RETURN node
END FUNCTION

# Split a comma-separated $expand list, keeping commas inside parentheses (a
# nested option list) attached to their item.
PRIVATE FUNCTION splitExpandItems(s STRING) RETURNS DYNAMIC ARRAY OF STRING
    RETURN splitTopLevel(s, ",")
END FUNCTION

# Split an $expand item's nested-option string on ';' at paren-depth 0, so a
# nested $expand (which carries its own '(' ')' ';') stays attached to its option.
PRIVATE FUNCTION splitNestedOptions(s STRING) RETURNS DYNAMIC ARRAY OF STRING
    RETURN splitTopLevel(s, ";")
END FUNCTION

# Split `s` on `sep` only where parenthesis depth is 0. Single-character `sep`.
PRIVATE FUNCTION splitTopLevel(s STRING, sep STRING) RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE buf base.StringBuffer
    DEFINE i, depth INTEGER
    DEFINE c STRING

    LET buf = base.StringBuffer.create()
    FOR i = 1 TO s.getLength()
        LET c = s.getCharAt(i)
        CASE
            WHEN c == "("
                LET depth = depth + 1
                CALL buf.append(c)
            WHEN c == ")"
                LET depth = depth - 1
                CALL buf.append(c)
            WHEN c == sep AND depth == 0
                LET out[out.getLength() + 1] = buf.toString()
                CALL buf.clear()
            OTHERWISE
                CALL buf.append(c)
        END CASE
    END FOR
    LET out[out.getLength() + 1] = buf.toString()
    RETURN out
END FUNCTION

# ---------------------------------------------------------------------------
# $filter — recursive-descent parser building an expression tree.
#
# Grammar (lowest to highest precedence), matching OData v4:
#     orExpr   := andExpr ( 'or'  andExpr )*
#     andExpr  := notExpr ( 'and' notExpr )*
#     notExpr  := 'not' notExpr | primary
#     primary  := '(' orExpr ')' | comparison | function
#     comparison := property ('eq'|'ne'|'gt'|'lt'|'ge'|'le') literal
#     function   := ('contains'|'startswith'|'endswith') '(' property ',' literal ')'
#
# Output: q.filterNodes (flat node pool) + q.filterRoot (root index). The flat
# q.filters leaf list is also populated for legacy consumers (function providers).
# ---------------------------------------------------------------------------
PRIVATE FUNCTION parseFilter(
    s STRING, q ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataQuery
    DEFINE root, i INTEGER

    CALL tokenize(s)
    CALL m_nodes.clear()
    LET m_tpos = 1
    LET m_perr = NULL
    LET m_pcode = "BadRequest"
    LET m_lambdaVar = NULL
    LET m_inLambda = FALSE

    IF m_tokens.getLength() == 0 THEN
        RETURN q                               # empty / whitespace $filter: no-op
    END IF

    LET root = parseOr()
    IF m_perr IS NOT NULL THEN
        CALL setErr(q, m_pcode, m_perr) RETURNING q
        RETURN q
    END IF
    IF m_tpos <= m_tokens.getLength() THEN
        CALL setErr(q, "BadRequest",
            SFMT("Unexpected '%1' in $filter", m_tokens[m_tpos])) RETURNING q
        RETURN q
    END IF

    FOR i = 1 TO m_nodes.getLength()
        LET q.filterNodes[i].* = m_nodes[i].*
    END FOR
    LET q.filterRoot = root

    # Flat leaf list for function providers / key-lookup scanning. Pool order is
    # left-to-right parse order; grouping/precedence lives in the tree.
    FOR i = 1 TO m_nodes.getLength()
        IF m_nodes[i].kind == "pred" THEN
            LET q.filters[q.filters.getLength() + 1].* = m_nodes[i].pred.*
        END IF
    END FOR
    RETURN q
END FUNCTION

# Lower-cased current token, or NULL past the end. Guards the index: BDL `AND`
# does not short-circuit and indexing a DYNAMIC ARRAY past its length silently
# grows it, so the bound MUST be checked before subscripting m_tokens.
PRIVATE FUNCTION peekLower() RETURNS STRING
    IF m_tpos > m_tokens.getLength() THEN
        RETURN NULL
    END IF
    RETURN m_tokens[m_tpos].toLowerCase()
END FUNCTION

# orExpr := andExpr ( 'or' andExpr )*   (left-associative)
PRIVATE FUNCTION parseOr() RETURNS INTEGER
    DEFINE l, r INTEGER
    LET l = parseAnd()
    IF m_perr IS NOT NULL THEN RETURN 0 END IF
    WHILE peekLower() == "or"
        LET m_tpos = m_tpos + 1
        LET r = parseAnd()
        IF m_perr IS NOT NULL THEN RETURN 0 END IF
        LET l = addNode("or", l, r)
    END WHILE
    RETURN l
END FUNCTION

# andExpr := notExpr ( 'and' notExpr )*   (left-associative)
PRIVATE FUNCTION parseAnd() RETURNS INTEGER
    DEFINE l, r INTEGER
    LET l = parseNot()
    IF m_perr IS NOT NULL THEN RETURN 0 END IF
    WHILE peekLower() == "and"
        LET m_tpos = m_tpos + 1
        LET r = parseNot()
        IF m_perr IS NOT NULL THEN RETURN 0 END IF
        LET l = addNode("and", l, r)
    END WHILE
    RETURN l
END FUNCTION

# notExpr := 'not' notExpr | primary
PRIVATE FUNCTION parseNot() RETURNS INTEGER
    DEFINE c INTEGER
    IF peekLower() == "not" THEN
        LET m_tpos = m_tpos + 1
        LET c = parseNot()
        IF m_perr IS NOT NULL THEN RETURN 0 END IF
        RETURN addNode("not", c, 0)
    END IF
    RETURN parsePrimary()
END FUNCTION

# primary := '(' orExpr ')' | comparison | function
PRIVATE FUNCTION parsePrimary() RETURNS INTEGER
    DEFINE n INTEGER
    IF m_tpos > m_tokens.getLength() THEN
        LET m_perr = "Unexpected end of $filter"
        RETURN 0
    END IF
    IF m_tokens[m_tpos] == "(" THEN
        LET m_tpos = m_tpos + 1
        LET n = parseOr()
        IF m_perr IS NOT NULL THEN RETURN 0 END IF
        IF m_tpos > m_tokens.getLength() OR m_tokens[m_tpos] != ")" THEN
            LET m_perr = "Expected ')' in $filter"
            RETURN 0
        END IF
        LET m_tpos = m_tpos + 1
        RETURN n
    END IF
    RETURN parsePredicate()
END FUNCTION

# A single comparison or string-function predicate at the cursor; returns the
# index of the new "pred" node, advancing m_tpos. Sets m_perr on a malformed
# predicate.
PRIVATE FUNCTION parsePredicate() RETURNS INTEGER
    DEFINE f ODataTypes.T_ODataFilter
    DEFINE fn, op, rawLit STRING
    DEFINE pp INTEGER

    INITIALIZE f.* TO NULL

    # lambda form: nav/any(...) | nav/all(...)
    IF isLambdaHead(m_tokens[m_tpos]) THEN
        RETURN parseLambda()
    END IF

    LET fn = m_tokens[m_tpos].toLowerCase()

    # function form: fn ( property , 'value' )
    IF fn == "contains" OR fn == "startswith" OR fn == "endswith" THEN
        IF m_tpos + 5 > m_tokens.getLength() THEN
            LET m_perr = "Malformed string function in $filter"
            RETURN 0
        END IF
        IF m_tokens[m_tpos + 1] != "(" OR m_tokens[m_tpos + 3] != ","
            OR m_tokens[m_tpos + 5] != ")" THEN
            LET m_perr = "Malformed string function in $filter"
            RETURN 0
        END IF
        LET f.operator = fn
        LET f.property = normProperty(m_tokens[m_tpos + 2])
        LET f.value = stripQuotes(m_tokens[m_tpos + 4])
        LET m_tpos = m_tpos + 6
        RETURN addPred(f)
    END IF

    # comparison form: property compOp literal
    IF m_tpos + 2 > m_tokens.getLength() THEN
        LET m_perr = "Incomplete comparison in $filter"
        RETURN 0
    END IF
    LET op = m_tokens[m_tpos + 1].toLowerCase()

    # in-list form: property in ( lit, lit, ... )
    IF op == "in" THEN
        IF m_tokens[m_tpos + 2] != "(" THEN
            LET m_perr = "Expected '(' after 'in' in $filter"
            RETURN 0
        END IF
        LET f.property = normProperty(m_tokens[m_tpos])
        LET f.operator = "in"
        LET pp = m_tpos + 3
        WHILE pp <= m_tokens.getLength()
            IF m_tokens[pp] == ")" THEN EXIT WHILE END IF
            IF m_tokens[pp] == "," THEN
                LET pp = pp + 1
                CONTINUE WHILE
            END IF
            LET f.values[f.values.getLength() + 1] = stripQuotes(m_tokens[pp])
            LET pp = pp + 1
        END WHILE
        IF pp > m_tokens.getLength() THEN
            LET m_perr = "Expected ')' to close 'in' list in $filter"
            RETURN 0
        END IF
        LET m_tpos = pp + 1
        RETURN addPred(f)
    END IF

    CASE op
        WHEN "eq"
        WHEN "ne"
        WHEN "gt"
        WHEN "lt"
        WHEN "ge"
        WHEN "le"
        OTHERWISE
            LET m_perr = SFMT("Unsupported comparison operator '%1'", op)
            RETURN 0
    END CASE
    LET f.property = normProperty(m_tokens[m_tpos])
    LET f.operator = op
    # The bare keyword `null` (unquoted) is the OData null literal; the quoted
    # string 'null' is a normal text value. Both strip to "null", so flag the
    # unquoted form here for the SQL layer to translate to IS [NOT] NULL.
    LET rawLit = m_tokens[m_tpos + 2]
    IF rawLit.getCharAt(1) != "'" AND rawLit.toLowerCase() == "null" THEN
        LET f.isNull = TRUE
    END IF
    LET f.value = stripQuotes(rawLit)
    LET m_tpos = m_tpos + 3
    RETURN addPred(f)
END FUNCTION

#+ Append a logical node (and/or/not) to the pool and return its 1-based index.
PRIVATE FUNCTION addNode(kind STRING, left INTEGER, right INTEGER)
    RETURNS INTEGER
    DEFINE n INTEGER
    LET n = m_nodes.getLength() + 1
    LET m_nodes[n].kind = kind
    LET m_nodes[n].left = left
    LET m_nodes[n].right = right
    RETURN n
END FUNCTION

#+ Append a predicate (leaf) node to the pool and return its 1-based index.
PRIVATE FUNCTION addPred(f ODataTypes.T_ODataFilter) RETURNS INTEGER
    DEFINE n INTEGER
    LET n = m_nodes.getLength() + 1
    LET m_nodes[n].kind = "pred"
    LET m_nodes[n].pred.* = f.*
    RETURN n
END FUNCTION

# ---------------------------------------------------------------------------
# Lambda operators (any / all) over a collection navigation property.
#   nav/any(v: P) | nav/all(v: P) | nav/any()
# Stored as a "lambda" node overloading T_ODataFilterNode: pred.property = nav,
# pred.operator = quantifier, left = inner-predicate root (0 for empty any()).
# ---------------------------------------------------------------------------

#+ Index of the last '/' in s, or 0 if none. (STRING.getIndexOf finds the first
#+ occurrence only.) The lambda operator is always the final path segment, so the
#+ split must be on the last '/' — otherwise a var-qualified nested head like
#+ "o/OrderDetails/any" is misread (tail "OrderDetails/any") and falls through to
#+ a comparison instead of being recognised (and rejected) as a nested lambda.
PRIVATE FUNCTION lastSlash(s STRING) RETURNS INTEGER
    DEFINE i, last INTEGER
    IF s IS NULL THEN RETURN 0 END IF
    FOR i = 1 TO s.getLength()
        IF s.getCharAt(i) == "/" THEN LET last = i END IF
    END FOR
    RETURN last
END FUNCTION

#+ TRUE when the token at the cursor is "<nav>/any" or "<nav>/all" followed by
#+ '(' — i.e. a lambda operator head (as opposed to a scalar comparison).
PRIVATE FUNCTION isLambdaHead(t STRING) RETURNS BOOLEAN
    DEFINE sl INTEGER
    DEFINE tail STRING
    IF t IS NULL THEN RETURN FALSE END IF
    LET sl = lastSlash(t)
    IF sl <= 0 THEN RETURN FALSE END IF
    LET tail = t.subString(sl + 1, t.getLength()).toLowerCase()
    IF tail != "any" AND tail != "all" THEN RETURN FALSE END IF
    IF m_tpos + 1 > m_tokens.getLength() THEN RETURN FALSE END IF
    RETURN m_tokens[m_tpos + 1] == "("
END FUNCTION

#+ Parse a lambda expression at the cursor and return its node index.
PRIVATE FUNCTION parseLambda() RETURNS INTEGER
    DEFINE head, navName, quant, var STRING
    DEFINE sl, innerRoot INTEGER

    IF m_inLambda THEN
        LET m_pcode = "NotImplemented"
        LET m_perr = "Nested lambda expressions are not supported"
        RETURN 0
    END IF
    LET head = m_tokens[m_tpos]
    LET sl = lastSlash(head)
    LET navName = head.subString(1, sl - 1)
    LET quant = head.subString(sl + 1, head.getLength()).toLowerCase()
    LET m_tpos = m_tpos + 1                        # consume nav/quant head
    IF m_tpos > m_tokens.getLength() OR m_tokens[m_tpos] != "(" THEN
        LET m_perr = "Expected '(' after lambda operator"
        RETURN 0
    END IF
    LET m_tpos = m_tpos + 1                        # consume '('

    # Empty body: any() is a pure existence test; all() requires a predicate.
    IF m_tpos <= m_tokens.getLength() AND m_tokens[m_tpos] == ")" THEN
        IF quant == "all" THEN
            LET m_perr = "The 'all' lambda requires a predicate"
            RETURN 0
        END IF
        LET m_tpos = m_tpos + 1                    # consume ')'
        RETURN addLambda(navName, quant, 0)
    END IF

    # var ':' predicate
    IF m_tpos > m_tokens.getLength() THEN
        LET m_perr = "Expected lambda variable"
        RETURN 0
    END IF
    LET var = m_tokens[m_tpos]
    LET m_tpos = m_tpos + 1                        # consume variable
    IF m_tpos > m_tokens.getLength() OR m_tokens[m_tpos] != ":" THEN
        LET m_perr = "Expected ':' in lambda expression"
        RETURN 0
    END IF
    LET m_tpos = m_tpos + 1                        # consume ':'

    LET m_lambdaVar = var
    LET m_inLambda = TRUE
    LET innerRoot = parseOr()                      # P, into the shared node pool
    LET m_inLambda = FALSE
    LET m_lambdaVar = NULL
    IF m_perr IS NOT NULL THEN RETURN 0 END IF
    IF m_tpos > m_tokens.getLength() OR m_tokens[m_tpos] != ")" THEN
        LET m_perr = "Expected ')' to close lambda expression"
        RETURN 0
    END IF
    LET m_tpos = m_tpos + 1                        # consume ')'
    RETURN addLambda(navName, quant, innerRoot)
END FUNCTION

#+ Append a lambda node and return its 1-based index.
PRIVATE FUNCTION addLambda(navName STRING, quant STRING, innerRoot INTEGER)
    RETURNS INTEGER
    DEFINE n INTEGER
    LET n = m_nodes.getLength() + 1
    LET m_nodes[n].kind = "lambda"
    LET m_nodes[n].left = innerRoot
    LET m_nodes[n].right = 0
    LET m_nodes[n].pred.property = navName
    LET m_nodes[n].pred.operator = quant
    RETURN n
END FUNCTION

#+ Normalise a property token. Inside a lambda body the active "<var>/" prefix is
#+ stripped so the stored name is the bare target property; a remaining '/' (a
#+ deeper nav path) is unsupported. Outside a lambda, any '/' is a single-valued
#+ navigation-path comparison, also unsupported in this version. Both set a
#+ NotImplemented parse error.
PRIVATE FUNCTION normProperty(prop STRING) RETURNS STRING
    DEFINE pfx STRING
    IF prop IS NULL THEN RETURN prop END IF
    IF m_inLambda AND m_lambdaVar IS NOT NULL THEN
        LET pfx = SFMT("%1/", m_lambdaVar)
        IF prop.getLength() > pfx.getLength()
            AND prop.subString(1, pfx.getLength()) == pfx THEN
            LET prop = prop.subString(pfx.getLength() + 1, prop.getLength())
        END IF
    END IF
    IF prop.getIndexOf("/", 1) > 0 THEN
        LET m_pcode = "NotImplemented"
        IF m_inLambda THEN
            LET m_perr =
                SFMT("Navigation path '%1' inside a lambda is not supported", prop)
        ELSE
            LET m_perr =
                SFMT("Navigation-path filter '%1' is not supported", prop)
        END IF
    END IF
    RETURN prop
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
                WHEN c == "(" OR c == ")" OR c == "," OR c == ":"
                    # ':' separates a lambda variable from its predicate, e.g.
                    # Orders/any(o: …). '/' is deliberately NOT a delimiter — a
                    # nav path token (Orders/any, o/Freight) stays whole and the
                    # parser splits it.
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
