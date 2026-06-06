################################################################################
# ODataService.4gl
#
# The GAS REST surface for an OData service. Register this module with the web
# service engine and start the processing loop:
#
#     CALL ODataConfig.loadConfigFromFile("northwind.odata")
#     CALL ODataService.register("northwind")
#     CALL ODataService.run()
#
# Endpoints (relative to the GAS service base URL):
#     GET  /                       -> service document (entity-set listing)
#     GET  /$metadata              -> CSDL metadata (application/xml)
#     GET  /{entitySet}            -> entity collection (+ $-query options)
#     GET  /{entitySet}({key})     -> single entity by key
#
# ROUTING (verified on GAS 6.00.01): the literal paths "/" and "/$metadata"
# take precedence over the "/{entitySet}" placeholder. The OData key predicate
# is NOT a separate route — "Customers" and "Customers('ALFKI')" are a single
# path segment, so getEntitySet inspects the captured segment for a "(key)"
# suffix (GAS REST cannot express a "/{set}({key})" template; see history).
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT com
IMPORT util
IMPORT os
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataQuery
IMPORT FGL com.fourjs.odatalib.ODataProvider
IMPORT FGL com.fourjs.odatalib.ODataExpand
IMPORT FGL com.fourjs.odatalib.ODataSerializer
IMPORT FGL com.fourjs.odatalib.ODataError
IMPORT FGL com.fourjs.odatalib.ODataAuth

# Request context (engine keys + headers). Must be PRIVATE modular with the
# plural ATTRIBUTES(WSContext).
PRIVATE DEFINE ctx DICTIONARY ATTRIBUTES(WSContext) OF STRING

# Cached temp path for the streamed $metadata document (written per request,
# read by the engine after getMetadata() returns).
PRIVATE DEFINE m_metadataFile STRING

# ---------------------------------------------------------------------------
# Registration + lifecycle
# ---------------------------------------------------------------------------

#+ Register this module's OData endpoints under the given GAS service name.
PUBLIC FUNCTION register(serviceName STRING)
    CALL com.WebServiceEngine.RegisterRestService(
        "com.fourjs.odatalib.ODataService", serviceName)
END FUNCTION

#+ Run the web service engine processing loop until disconnect / interrupt.
#+
#+ Only -2 (app server disconnected), -4 (Ctrl-C) and -10 (internal error)
#+ terminate the DVM. Per-request / per-connection codes such as -3 (client
#+ connection lost) and other transient values (e.g. the -32 the GAS proxy
#+ returns between requests) are NOT fatal: the DVM keeps serving so the GAS
#+ pool can reuse it. Returning on those churns the pool and starves the
#+ service under load.
PUBLIC FUNCTION run() RETURNS STRING
    DEFINE status INTEGER
    CALL com.WebServiceEngine.Start()
    LET int_flag = FALSE
    WHILE int_flag == FALSE
        LET status = com.WebServiceEngine.ProcessServices(-1)
        CASE status
            WHEN 0
                # request processed
            WHEN -1
                # timeout (not expected with the -1 blocking wait)
            WHEN -2
                RETURN "Disconnected from application server."
            WHEN -4
                RETURN "Server interrupted with Ctrl-C."
            WHEN -10
                RETURN "Internal server error."
            OTHERWISE
                # -3, -9 and other transient/per-connection codes: keep serving.
        END CASE
        IF int_flag THEN
            LET int_flag = FALSE
            EXIT WHILE
        END IF
    END WHILE
    RETURN "Server stopped."
END FUNCTION

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

#+ Service document: lists the available entity sets.
PUBLIC FUNCTION getServiceDocument()
    ATTRIBUTES(WSGet,
        WSPath = "/",
        WSDescription = "OData service document (entity set listing)")
    RETURNS util.JSONObject ATTRIBUTES(WSMedia = "application/json")
    RETURN ODataSerializer.buildServiceDocument(serviceBaseUrl())
END FUNCTION

#+ CSDL $metadata document.
#+ Streamed raw via WSAttachment (the engine sends the file content verbatim
#+ with Content-Type application/xml). Returning a STRING or BYTE with an XML
#+ media type instead XML-serialises the value, wrapping it in <rv0> (and
#+ base64-encoding a BYTE) — not valid CSDL.
PUBLIC FUNCTION getMetadata()
    ATTRIBUTES(WSGet,
        WSPath = "/$metadata",
        WSDescription = "OData CSDL metadata document")
    RETURNS STRING ATTRIBUTES(WSAttachment, WSMedia = "application/xml")
    DEFINE xml STRING
    DEFINE ch base.Channel

    # NOTE: GAS streams the attachment with Content-Type text/xml (derived from
    # the .xml extension). text/xml is a valid XML media type (RFC 7303) accepted
    # by OData clients incl. Power BI; the body is raw, well-formed CSDL.
    LET xml = ODataSerializer.buildMetadata()
    IF m_metadataFile IS NULL THEN
        LET m_metadataFile = os.Path.makeTempName() || ".xml"
    END IF
    LET ch = base.Channel.create()
    CALL ch.openFile(m_metadataFile, "w")
    CALL ch.writeNoNL(xml)
    CALL ch.close()
    RETURN m_metadataFile
END FUNCTION

#+ Entity collection with the supported $-query options.
PUBLIC FUNCTION getEntitySet(
    entitySet STRING ATTRIBUTES(WSParam),
    pSelect STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$select"),
    pFilter STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$filter"),
    pTop STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$top"),
    pSkip STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$skip"),
    pCount STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$count"),
    pOrderby STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$orderby"),
    pExpand STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$expand"),
    pApply STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$apply"),
    hScopes STRING ATTRIBUTES(WSHeader, WSOptional, WSName = "X-OData-Scopes"),
    hUser STRING ATTRIBUTES(WSHeader, WSOptional, WSName = "X-OData-User"))
    ATTRIBUTES(WSGet,
        WSPath = "/{entitySet}",
        WSDescription = "OData entity collection")
    RETURNS util.JSONObject ATTRIBUTES(WSMedia = "application/json")

    DEFINE ent ODataTypes.T_ODataEntity
    DEFINE found, isKeyReq BOOLEAN
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE result ODataTypes.T_ODataResult
    DEFINE authRes ODataTypes.T_ODataAuthResult
    DEFINE authCtx ODataTypes.T_ODataAuthContext
    DEFINE baseUrl, nextLink, name, keyVal STRING
    DEFINE keyParts DYNAMIC ARRAY OF ODataTypes.T_ODataKeyPart
    DEFINE resp util.JSONObject
    DEFINE eok BOOLEAN
    DEFINE ecode, emsg STRING

    LET baseUrl = serviceBaseUrl()

    # Defensive guard if a literal path leaked into the placeholder route.
    IF entitySet == "$metadata" THEN
        CALL ODataError.raiseCode("BadRequest",
            "Use GET /$metadata with an XML accept header")
        RETURN NULL
    END IF

    # A single OData segment is either "Set" (collection) or "Set(key)" (entity).
    # keyVal is the raw predicate inside the parentheses (parsed below once the
    # request is authorised and the entity is known).
    CALL splitEntityKey(entitySet) RETURNING name, keyVal, isKeyReq

    # Authorization hook (no-op when no authorizer is registered). Checked on the
    # requested name before existence is confirmed, so denial does not reveal
    # which entity sets exist.
    LET authCtx = buildAuthContext(name, "read", keyVal, hScopes, hUser)
    LET authRes = ODataAuth.authorize(authCtx)
    IF NOT authRes.allowed THEN
        IF authRes.status == 401 THEN
            CALL ODataError.raise(401, "Unauthorized",
                NVL(authRes.message, "Authentication required"))
        ELSE
            CALL ODataError.raise(403, "Forbidden",
                NVL(authRes.message, "Access denied"))
        END IF
        RETURN NULL
    END IF

    CALL ODataConfig.findEntity(name) RETURNING ent.*, found
    IF NOT found THEN
        CALL ODataError.raiseCode("NotFound",
            SFMT("Entity set '%1' not found", name))
        RETURN NULL
    END IF

    # --- single entity by key -------------------------------------------------
    IF isKeyReq THEN
        IF pApply IS NOT NULL AND pApply.getLength() > 0 THEN
            CALL ODataError.raiseCode("BadRequest",
                "$apply is not applicable to a single-entity (key) request")
            RETURN NULL
        END IF
        CALL parseKeyPredicate(keyVal) RETURNING keyParts
        LET result = ODataProvider.fetchByKeys(ent, keyParts)
        IF NOT result.ok THEN
            CALL ODataError.raiseCode(result.errorCode, result.errorMessage)
            RETURN NULL
        END IF
        # $expand on a single entity (other options are not applied to a key get).
        IF pExpand IS NOT NULL AND pExpand.getLength() > 0 THEN
            LET q = ODataQuery.parse(NULL, NULL, NULL, NULL, NULL, NULL, pExpand, NULL)
            IF NOT q.ok THEN
                CALL ODataError.raiseCode(q.errorCode, q.errorMessage)
                RETURN NULL
            END IF
            CALL ODataExpand.apply(ent, q, result.rows)
                RETURNING eok, ecode, emsg
            IF NOT eok THEN
                CALL ODataError.raiseCode(ecode, emsg)
                RETURN NULL
            END IF
        END IF
        LET resp = ODataSerializer.buildEntity(baseUrl, name, result)
        IF resp IS NULL THEN
            CALL ODataError.raiseCode("NotFound",
                SFMT("No %1 with key '%2'", name, keyVal))
            RETURN NULL
        END IF
        RETURN resp
    END IF

    # --- entity collection ----------------------------------------------------
    # $apply (aggregation) reshapes the result, so it cannot be combined with
    # $select/$expand/top-level $filter; pre-aggregation filtering uses the
    # in-pipeline filter(...) instead.
    IF pApply IS NOT NULL AND pApply.getLength() > 0 THEN
        IF (pSelect IS NOT NULL AND pSelect.getLength() > 0)
            OR (pExpand IS NOT NULL AND pExpand.getLength() > 0)
            OR (pFilter IS NOT NULL AND pFilter.getLength() > 0) THEN
            CALL ODataError.raiseCode("NotImplemented",
                "$apply cannot be combined with $select, $expand or $filter; use the in-pipeline filter(...) transformation")
            RETURN NULL
        END IF
    END IF

    LET q = ODataQuery.parse(
        pSelect, pFilter, pTop, pSkip, pCount, pOrderby, pExpand, pApply)
    IF NOT q.ok THEN
        CALL ODataError.raiseCode(q.errorCode, q.errorMessage)
        RETURN NULL
    END IF

    # Make sure the navigation join keys are fetched even under a narrow $select.
    IF q.expandRoots.getLength() > 0 THEN
        LET q.selectList = ODataExpand.ensureJoinKeys(ent, q, q.selectList)
    END IF

    LET result = ODataProvider.fetch(ent, q)
    IF NOT result.ok THEN
        CALL ODataError.raiseCode(result.errorCode, result.errorMessage)
        RETURN NULL
    END IF

    IF q.expandRoots.getLength() > 0 THEN
        CALL ODataExpand.apply(ent, q, result.rows)
            RETURNING eok, ecode, emsg
        IF NOT eok THEN
            CALL ODataError.raiseCode(ecode, emsg)
            RETURN NULL
        END IF
    END IF

    IF result.hasMore THEN
        LET nextLink = buildNextLink(baseUrl, name,
            q.skip + result.rows.getLength(),
            pSelect, pFilter, pOrderby, pCount, pExpand)
    END IF

    RETURN ODataSerializer.buildCollection(
        baseUrl, name, result, q.wantCount, nextLink)
END FUNCTION

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

#+ Build the authorization principal for the current request.
#+ Identity is resolved in priority order:
#+   1. Genero Identity Provider via GeneroAccessService delegation, which
#+      injects OIDC_SUB + SCOPES (all granted scopes) into the context after
#+      validating the OAuth2 bearer token  -- the production path.
#+   2. The X-OData-Scopes / X-OData-User WSHeaders -- a dev/testing convenience.
#+   3. The GAS-granted Scope context entry.
#+ The bearer token (if any) comes from Authorization or the forwarded
#+ OIDC_ACCESS_TOKEN.
PRIVATE FUNCTION buildAuthContext(
    entity STRING, operation STRING, key STRING,
    hScopes STRING, hUser STRING)
    RETURNS ODataTypes.T_ODataAuthContext
    DEFINE a ODataTypes.T_ODataAuthContext
    DEFINE gipScopes STRING

    LET a.entity = entity
    LET a.operation = operation
    LET a.key = key

    LET a.token = ctx["Authorization"]
    IF a.token IS NULL THEN
        LET a.token = ctx["OIDC_ACCESS_TOKEN"]
    END IF

    LET a.user = ctx["OIDC_SUB"]
    IF a.user IS NULL THEN
        LET a.user = hUser
    END IF

    # Scopes: GIP SCOPES (comma list) > X-OData-Scopes header > GAS Scope.
    LET gipScopes = ctx["SCOPES"]
    IF gipScopes IS NOT NULL AND gipScopes.getLength() > 0 THEN
        LET a.scope = gipScopes
    ELSE
        IF hScopes IS NOT NULL AND hScopes.getLength() > 0 THEN
            LET a.scope = hScopes
        ELSE
            LET a.scope = ctx["Scope"]
        END IF
    END IF

    RETURN a
END FUNCTION

PRIVATE FUNCTION serviceBaseUrl() RETURNS STRING
    DEFINE u STRING
    LET u = ctx["BaseURL"]
    IF u IS NULL THEN
        RETURN ""
    END IF
    # strip a single trailing slash for clean concatenation
    IF u.getCharAt(u.getLength()) == "/" THEN
        LET u = u.subString(1, u.getLength() - 1)
    END IF
    RETURN u
END FUNCTION

#+ Split a single OData path segment into entity-set name + the raw key
#+ predicate (the text between the parentheses, NOT unquoted/parsed here).
#+ "Customers"                 -> ("Customers", NULL, FALSE)
#+ "Customers('ALFKI')"        -> ("Customers", "'ALFKI'", TRUE)
#+ "Orders(10248)"             -> ("Orders", "10248", TRUE)
#+ "OrderDetails(OrderID=10248,ProductID=11)"
#+                             -> ("OrderDetails", "OrderID=10248,ProductID=11", TRUE)
PRIVATE FUNCTION splitEntityKey(seg STRING)
    RETURNS (STRING, STRING, BOOLEAN)
    DEFINE lp INTEGER
    IF seg IS NULL OR seg.getLength() == 0 THEN
        RETURN seg, NULL, FALSE
    END IF
    LET lp = seg.getIndexOf("(", 1)
    IF lp > 1 AND seg.getCharAt(seg.getLength()) == ")" THEN
        RETURN seg.subString(1, lp - 1),
            seg.subString(lp + 1, seg.getLength() - 1),
            TRUE
    END IF
    RETURN seg, NULL, FALSE
END FUNCTION

#+ Parse the raw key predicate into ordered key parts. Each comma-separated
#+ segment is either "Name=value" (named, required for composite keys) or a bare
#+ "value" (the unnamed single-key form). Values are unquoted. Commas and '='
#+ inside single-quoted values are respected.
PRIVATE FUNCTION parseKeyPredicate(inner STRING)
    RETURNS DYNAMIC ARRAY OF ODataTypes.T_ODataKeyPart
    DEFINE parts DYNAMIC ARRAY OF ODataTypes.T_ODataKeyPart
    DEFINE segs DYNAMIC ARRAY OF STRING
    DEFINE i, eq, n INTEGER
    DEFINE seg STRING
    IF inner IS NULL OR inner.getLength() == 0 THEN
        RETURN parts
    END IF
    CALL splitTopLevel(inner) RETURNING segs
    FOR i = 1 TO segs.getLength()
        LET seg = segs[i].trim()
        LET eq = indexOfUnquoted(seg, "=")
        LET n = parts.getLength() + 1
        IF eq > 0 THEN
            LET parts[n].name = seg.subString(1, eq - 1).trim()
            LET parts[n].value =
                unquoteKey(seg.subString(eq + 1, seg.getLength()).trim())
        ELSE
            LET parts[n].name = ""
            LET parts[n].value = unquoteKey(seg)
        END IF
    END FOR
    RETURN parts
END FUNCTION

#+ Split on top-level commas, treating single-quoted runs (with '' escaping) as
#+ opaque so a comma inside a quoted key value is not a separator.
PRIVATE FUNCTION splitTopLevel(s STRING) RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE buf base.StringBuffer
    DEFINE i, n INTEGER
    DEFINE c STRING
    DEFINE inStr BOOLEAN = FALSE
    LET buf = base.StringBuffer.create()
    LET n = s.getLength()
    LET i = 1
    WHILE i <= n
        LET c = s.getCharAt(i)
        IF inStr THEN
            CALL buf.append(c)
            IF c == "'" THEN
                IF i < n AND s.getCharAt(i + 1) == "'" THEN
                    CALL buf.append("'")
                    LET i = i + 1
                ELSE
                    LET inStr = FALSE
                END IF
            END IF
        ELSE
            CASE
                WHEN c == "'"
                    CALL buf.append(c)
                    LET inStr = TRUE
                WHEN c == ","
                    LET out[out.getLength() + 1] = buf.toString()
                    CALL buf.clear()
                OTHERWISE
                    CALL buf.append(c)
            END CASE
        END IF
        LET i = i + 1
    END WHILE
    LET out[out.getLength() + 1] = buf.toString()
    RETURN out
END FUNCTION

#+ Index (1-based) of the first occurrence of ch outside single quotes, else 0.
PRIVATE FUNCTION indexOfUnquoted(s STRING, ch STRING) RETURNS INTEGER
    DEFINE i, n INTEGER
    DEFINE c STRING
    DEFINE inStr BOOLEAN = FALSE
    LET n = s.getLength()
    FOR i = 1 TO n
        LET c = s.getCharAt(i)
        IF c == "'" THEN
            LET inStr = NOT inStr
        ELSE
            IF (NOT inStr) AND c == ch THEN
                RETURN i
            END IF
        END IF
    END FOR
    RETURN 0
END FUNCTION

#+ Strip the surrounding single quotes from a string key predicate.
PRIVATE FUNCTION unquoteKey(k STRING) RETURNS STRING
    IF k IS NULL OR k.getLength() < 2 THEN
        RETURN k
    END IF
    IF k.getCharAt(1) == "'" AND k.getCharAt(k.getLength()) == "'" THEN
        RETURN k.subString(2, k.getLength() - 1)
    END IF
    RETURN k
END FUNCTION

#+ Build the next-page link, preserving the active query options. newSkip is
#+ the absolute $skip for the following page (current skip + rows returned).
PRIVATE FUNCTION buildNextLink(
    baseUrl STRING,
    entitySet STRING,
    newSkip INTEGER,
    pSelect STRING,
    pFilter STRING,
    pOrderby STRING,
    pCount STRING,
    pExpand STRING)
    RETURNS STRING
    DEFINE buf base.StringBuffer

    LET buf = base.StringBuffer.create()
    CALL buf.append(SFMT("%1/%2?$skip=%3", baseUrl, entitySet, newSkip))
    IF pFilter IS NOT NULL AND pFilter.getLength() > 0 THEN
        CALL buf.append(SFMT("&$filter=%1", urlEncode(pFilter)))
    END IF
    IF pSelect IS NOT NULL AND pSelect.getLength() > 0 THEN
        CALL buf.append(SFMT("&$select=%1", urlEncode(pSelect)))
    END IF
    IF pOrderby IS NOT NULL AND pOrderby.getLength() > 0 THEN
        CALL buf.append(SFMT("&$orderby=%1", urlEncode(pOrderby)))
    END IF
    IF pCount IS NOT NULL AND pCount.getLength() > 0 THEN
        CALL buf.append(SFMT("&$count=%1", urlEncode(pCount)))
    END IF
    IF pExpand IS NOT NULL AND pExpand.getLength() > 0 THEN
        CALL buf.append(SFMT("&$expand=%1", urlEncode(pExpand)))
    END IF
    RETURN buf.toString()
END FUNCTION

#+ Percent-encode a query-option value (unreserved chars pass through).
PRIVATE FUNCTION urlEncode(s STRING) RETURNS STRING
    DEFINE buf base.StringBuffer
    DEFINE i INTEGER
    DEFINE c STRING
    IF s IS NULL THEN
        RETURN s
    END IF
    LET buf = base.StringBuffer.create()
    FOR i = 1 TO s.getLength()
        LET c = s.getCharAt(i)
        CASE
            WHEN (c >= "A" AND c <= "Z") OR (c >= "a" AND c <= "z")
                OR (c >= "0" AND c <= "9")
                CALL buf.append(c)
            WHEN c == "-" OR c == "_" OR c == "." OR c == "~"
                CALL buf.append(c)
            WHEN c == " "  CALL buf.append("%20")
            WHEN c == "'"  CALL buf.append("%27")
            WHEN c == "("  CALL buf.append("%28")
            WHEN c == ")"  CALL buf.append("%29")
            WHEN c == ","  CALL buf.append("%2C")
            WHEN c == "/"  CALL buf.append("%2F")
            WHEN c == ":"  CALL buf.append("%3A")
            OTHERWISE
                CALL buf.append(c)
        END CASE
    END FOR
    RETURN buf.toString()
END FUNCTION
