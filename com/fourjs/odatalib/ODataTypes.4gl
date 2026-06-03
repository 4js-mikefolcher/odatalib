################################################################################
# ODataTypes.4gl
#
# Shared public TYPE definitions for the odatalib framework:
#   - the in-memory schema model loaded from a .odata config file
#   - the normalised query model produced by the $-option parser
#
# These types are deliberately kept free of behaviour so every other module
# can import them without creating dependency cycles.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT util

# ---------------------------------------------------------------------------
# Schema model (mirrors the .odata JSON config; json_name maps wire keys)
# ---------------------------------------------------------------------------

# A single exposed property of an entity type.
PUBLIC TYPE T_ODataProperty RECORD
    name STRING,                                   # OData property name (wire)
    column STRING,                                 # backing DB column (sql provider)
    edmType STRING ATTRIBUTES(json_name = "type"), # Edm.String, Edm.Int32, ...
    isKey BOOLEAN ATTRIBUTES(json_name = "key")    # part of the entity key?
END RECORD

# A single entity set + its backing provider binding.
PUBLIC TYPE T_ODataEntity RECORD
    name STRING,                                   # entity set name, e.g. "Customers"
    entityType STRING,                             # entity type name, e.g. "Customer"
    provider STRING,                               # "sql" | "function"
    source STRING,                                 # table/view (sql) or function id
    keyName STRING ATTRIBUTES(json_name = "key"),  # property name of the single key
    pageSize INTEGER,                              # server page size (0 -> default)
    properties DYNAMIC ARRAY OF T_ODataProperty
END RECORD

# The whole service schema as declared in one .odata file.
PUBLIC TYPE T_ODataSchema RECORD
    service STRING,                                # OData service name
    namespace STRING,                              # CSDL namespace
    entities DYNAMIC ARRAY OF T_ODataEntity
END RECORD

# One component of a key predicate parsed from the request URL. `name` is the
# key property named in the URL (e.g. OrderDetails(OrderID=10248,ProductID=11));
# it is empty for the unnamed single-key form (e.g. Customers('ALFKI')), which
# the provider resolves to the entity's sole key property. An entity's key
# properties are the properties flagged isKey (or the single keyName shorthand).
PUBLIC TYPE T_ODataKeyPart RECORD
    name STRING,
    value STRING
END RECORD

# ---------------------------------------------------------------------------
# Normalised query model (output of ODataQuery.parse)
# ---------------------------------------------------------------------------

# One comparison/function predicate inside $filter.
# conjunction is the logical operator linking this predicate to the NEXT one
# ("and" / "or"); empty on the final predicate.
PUBLIC TYPE T_ODataFilter RECORD
    property STRING,
    operator STRING,        # eq ne gt lt ge le contains startswith endswith
    value STRING,
    isNull BOOLEAN,         # TRUE when the literal was the bare keyword null
    conjunction STRING      # and | or | "" (trailing)
END RECORD

# One $orderby term.
PUBLIC TYPE T_ODataOrderBy RECORD
    property STRING,
    descending BOOLEAN
END RECORD

# One node of the parsed $filter expression tree. Nodes live in a flat pool
# (T_ODataQuery.filterNodes) and reference their children by 1-based pool index,
# so the RECORD need not contain itself (BDL has no recursive types):
#   kind = "pred"        -> pred holds a comparison / string-function predicate
#   kind = "and" | "or"  -> left and right are child node indices
#   kind = "not"         -> left is the (single) child node index, right unused
# The tree carries operator precedence and parenthesised grouping that the flat
# `filters` list cannot represent.
PUBLIC TYPE T_ODataFilterNode RECORD
    kind STRING,
    pred T_ODataFilter,
    left INTEGER,
    right INTEGER
END RECORD

# The full parsed set of query options for a collection request.
PUBLIC TYPE T_ODataQuery RECORD
    selectList DYNAMIC ARRAY OF STRING,
    # Flat list of every predicate leaf, in parse order. Kept for function
    # providers (and the key-lookup path) that scan for a specific predicate;
    # it does NOT carry grouping/precedence — use filterNodes/filterRoot for that.
    filters DYNAMIC ARRAY OF T_ODataFilter,
    # The authoritative parsed $filter as an expression tree (pool + root index,
    # 0 when there is no $filter). Carries and/or precedence, parentheses, not.
    filterNodes DYNAMIC ARRAY OF T_ODataFilterNode,
    filterRoot INTEGER,
    orderby DYNAMIC ARRAY OF T_ODataOrderBy,
    expand DYNAMIC ARRAY OF STRING,
    top INTEGER,
    skip INTEGER,
    hasTop BOOLEAN,
    wantCount BOOLEAN,
    ok BOOLEAN,             # FALSE if a query option was malformed/unsupported
    errorCode STRING,       # OData error code when ok == FALSE
    errorMessage STRING
END RECORD

# ---------------------------------------------------------------------------
# Provider result (returned by every provider to the serializer layer)
# ---------------------------------------------------------------------------
PUBLIC TYPE T_ODataResult RECORD
    rows util.JSONArray,    # array of row objects keyed by OData property name
    count INTEGER,          # total matching rows (only set when $count=true)
    hasMore BOOLEAN,        # a further server page exists -> emit @odata.nextLink
    ok BOOLEAN,
    errorCode STRING,
    errorMessage STRING
END RECORD

# ---------------------------------------------------------------------------
# Authorization hook
#
# Because the OData endpoints are generic (one operation serves every entity),
# access control is enforced at runtime per request rather than with a static
# per-operation WSScope. GAS authenticates the caller; the framework builds a
# principal from the request context and hands it, with the target entity and
# operation, to a customer-registered authorizer that returns allow/deny.
# ---------------------------------------------------------------------------

# What the caller is trying to do + who they are (as seen after GAS auth).
PUBLIC TYPE T_ODataAuthContext RECORD
    entity STRING,              # target entity set
    operation STRING,          # read | create | update | delete
    key STRING,                # entity key for single-entity requests, else NULL
    scope STRING,              # scopes string (from GAS Scope ctx or a header)
    user STRING,               # authenticated user id (from a configured header)
    token STRING,              # Authorization header value
    headers DICTIONARY OF STRING  # forwarded request headers / claims
END RECORD

# Authorizer verdict. status is the HTTP code to use when denied (401/403).
PUBLIC TYPE T_ODataAuthResult RECORD
    allowed BOOLEAN,
    status INTEGER,
    message STRING
END RECORD

# Customer authorizer signature. Parameter name MUST be `auth` (function-
# reference types are name-sensitive):
#     FUNCTION name(auth T_ODataAuthContext) RETURNS T_ODataAuthResult
PUBLIC TYPE T_ODataAuthFunc FUNCTION(
    auth T_ODataAuthContext) RETURNS T_ODataAuthResult

# ---------------------------------------------------------------------------
# Function-provider callback type.
#
# A customer-authored BDL function registered for a "function" entity. It
# receives the entity-set name and the parsed query, applies business logic +
# access control, and returns the matching rows in result.rows (with ok / error
# set). The framework then applies $top/$skip paging, $count and @odata.nextLink
# over the returned rows.
#
# IMPORTANT: function-reference type compatibility includes PARAMETER NAMES.
# A registered function MUST have this exact signature, parameter names included:
#     FUNCTION name(entity STRING, query T_ODataQuery) RETURNS T_ODataResult
# ---------------------------------------------------------------------------
PUBLIC TYPE T_ODataProviderFunc FUNCTION(
    entity STRING, query T_ODataQuery) RETURNS T_ODataResult
