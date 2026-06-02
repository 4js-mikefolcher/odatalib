################################################################################
# NorthwindAuth.4gl
#
# Example custom authorizer demonstrating the framework's authorization hook.
# Registered with ODataAuth.setAuthorizer(FUNCTION NorthwindAuth.authorize).
#
# Policy (illustrative):
#   * CountrySummary is a public aggregate  -> always allowed.
#   * Customers / Orders require a per-entity scope "<Entity>.<operation>",
#     e.g. "Customers.read", presented in the caller's scopes.
#
# In this sample the scopes arrive in the X-OData-Scopes request header (wired
# via ODataAuth.setScopeHeader). In a real deployment GAS would validate the
# bearer token and surface the granted scopes (in ctx["Scope"] or a header).
################################################################################
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataAuth

#+ Signature MUST match ODataTypes.T_ODataAuthFunc (parameter name `auth`).
PUBLIC FUNCTION authorize(auth ODataTypes.T_ODataAuthContext)
    RETURNS ODataTypes.T_ODataAuthResult
    DEFINE required STRING

    # Public, non-sensitive aggregate.
    IF auth.entity == "CountrySummary" THEN
        RETURN ODataAuth.allow()
    END IF

    LET required = SFMT("%1.%2", auth.entity, auth.operation)

    IF auth.scope IS NULL OR auth.scope.getLength() == 0 THEN
        IF auth.token IS NULL OR auth.token.getLength() == 0 THEN
            RETURN ODataAuth.deny(401, "Authentication required")
        END IF
        RETURN ODataAuth.deny(403, SFMT("Missing scope '%1'", required))
    END IF

    IF ODataAuth.scopeContains(auth.scope, required) THEN
        RETURN ODataAuth.allow()
    END IF
    RETURN ODataAuth.deny(403, SFMT("Missing scope '%1'", required))
END FUNCTION
