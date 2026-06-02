################################################################################
# ODataAuth.4gl
#
# Authorization layer for the (generic) OData endpoints. GAS handles
# authentication (Basic / OIDC / etc.) and passes the caller's identity through
# to the DVM via the request context and headers. This module turns that into a
# per-request allow/deny decision keyed by entity + operation, honouring the
# spec's "BDL is the gatekeeper" invariant.
#
# Two ways to use it:
#
#   1. Register a custom authorizer (full control):
#        CALL ODataAuth.setAuthorizer(FUNCTION MyModule.authorize)
#
#   2. Use the built-in scope authorizer (convention over configuration):
#        CALL ODataAuth.configureScopes("", ".")   -- requires "Customers.read"
#        CALL ODataAuth.useScopeAuthorizer()
#
# The caller's scopes are taken from the X-OData-Scopes request header (declared
# as a WSHeader on the service so GAS forwards it) or, after token validation,
# the GAS-granted Scope context entry. If no authorizer is registered the
# service is OPEN (every request allowed).
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT FGL com.fourjs.odatalib.ODataTypes

PRIVATE DEFINE m_authorizer ODataTypes.T_ODataAuthFunc
PRIVATE DEFINE m_hasAuthorizer BOOLEAN = FALSE

# Built-in scope authorizer configuration.
PRIVATE DEFINE m_scopePrefix STRING = ""
PRIVATE DEFINE m_scopeSeparator STRING = "."

# ---------------------------------------------------------------------------
# Registration / configuration
# ---------------------------------------------------------------------------

#+ Register a custom authorizer callback (function reference).
PUBLIC FUNCTION setAuthorizer(fn ODataTypes.T_ODataAuthFunc)
    LET m_authorizer = fn
    LET m_hasAuthorizer = TRUE
END FUNCTION

#+ Install the built-in scope authorizer as the active authorizer.
PUBLIC FUNCTION useScopeAuthorizer()
    LET m_authorizer = FUNCTION scopeAuthorizer
    LET m_hasAuthorizer = TRUE
END FUNCTION

#+ TRUE if any authorizer is active (service is gated).
PUBLIC FUNCTION isEnabled() RETURNS BOOLEAN
    RETURN m_hasAuthorizer
END FUNCTION

#+ Set the required-scope naming for the built-in scope authorizer.
#+ Required scope = prefix + entity + separator + operation,
#+ e.g. configureScopes("", ".") -> "Customers.read",
#+      configureScopes("Role.", ".") -> "Role.Customers.read".
PUBLIC FUNCTION configureScopes(prefix STRING, separator STRING)
    LET m_scopePrefix = NVL(prefix, "")
    IF separator IS NOT NULL THEN
        LET m_scopeSeparator = separator
    END IF
END FUNCTION

# ---------------------------------------------------------------------------
# Decision
# ---------------------------------------------------------------------------

#+ Authorize a request. When no authorizer is registered, allow everything.
PUBLIC FUNCTION authorize(auth ODataTypes.T_ODataAuthContext)
    RETURNS ODataTypes.T_ODataAuthResult
    DEFINE res ODataTypes.T_ODataAuthResult
    IF NOT m_hasAuthorizer THEN
        RETURN allow()
    END IF
    CALL m_authorizer(auth) RETURNING res.*
    RETURN res
END FUNCTION

# ---------------------------------------------------------------------------
# Built-in scope authorizer
# ---------------------------------------------------------------------------

#+ Allow when the caller's scopes include "<prefix><entity><sep><operation>".
#+ Registered via useScopeAuthorizer(). Parameter name must be `auth`.
PUBLIC FUNCTION scopeAuthorizer(auth ODataTypes.T_ODataAuthContext)
    RETURNS ODataTypes.T_ODataAuthResult
    DEFINE required, scopes STRING

    LET required = SFMT("%1%2%3%4",
        m_scopePrefix, auth.entity, m_scopeSeparator, auth.operation)

    LET scopes = auth.scope
    IF scopes IS NULL OR scopes.getLength() == 0 THEN
        # No scopes presented at all -> treat as unauthenticated.
        IF auth.token IS NULL OR auth.token.getLength() == 0 THEN
            RETURN deny(401, "Authentication required")
        END IF
        RETURN deny(403, SFMT("Missing required scope '%1'", required))
    END IF

    IF scopeContains(scopes, required) THEN
        RETURN allow()
    END IF
    RETURN deny(403, SFMT("Missing required scope '%1'", required))
END FUNCTION

#+ TRUE if a space- or comma-separated scope string contains an exact token.
#+ Public so custom authorizers can reuse it.
PUBLIC FUNCTION scopeContains(scopes STRING, want STRING) RETURNS BOOLEAN
    DEFINE tok base.StringTokenizer
    IF scopes IS NULL THEN
        RETURN FALSE
    END IF
    LET tok = base.StringTokenizer.create(scopes, " ,")
    WHILE tok.hasMoreTokens()
        IF tok.nextToken() == want THEN
            RETURN TRUE
        END IF
    END WHILE
    RETURN FALSE
END FUNCTION

# ---------------------------------------------------------------------------
# Result helpers (also usable by custom authorizers)
# ---------------------------------------------------------------------------

PUBLIC FUNCTION allow() RETURNS ODataTypes.T_ODataAuthResult
    DEFINE res ODataTypes.T_ODataAuthResult
    LET res.allowed = TRUE
    LET res.status = 200
    RETURN res
END FUNCTION

PUBLIC FUNCTION deny(status INTEGER, message STRING)
    RETURNS ODataTypes.T_ODataAuthResult
    DEFINE res ODataTypes.T_ODataAuthResult
    LET res.allowed = FALSE
    IF status == 0 THEN
        LET res.status = 403
    ELSE
        LET res.status = status
    END IF
    LET res.message = message
    RETURN res
END FUNCTION
