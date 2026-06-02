################################################################################
# NorthwindService.4gl
#
# Reference OData service program. Hosted by GAS as a REST service; exposes the
# Northwind sample entities declared in northwind.odata over OData v4.
#
# Build (library on FGLLDPATH), then deploy as a GAS REST service. Run directly
# for a standalone listener:
#     fglrun NorthwindService
################################################################################
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataService
IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider
IMPORT FGL com.fourjs.odatalib.ODataAuth
IMPORT FGL NorthwindCreate
IMPORT FGL NorthwindFunctions
IMPORT FGL NorthwindAuth

MAIN
    DEFINE msg, cfgPath STRING

    # In a real deployment connect to the customer database here. The sample
    # uses an in-memory SQLite database seeded on startup.
    CONNECT TO ":memory:+driver='dbmsqt'"
    CALL NorthwindCreate.createDatabase()

    # Config path: ODATA_CONFIG env var (set by the .xcf for GAS), else the
    # working-directory default for a terminal run.
    LET cfgPath = fgl_getenv("ODATA_CONFIG")
    IF cfgPath IS NULL OR cfgPath.getLength() == 0 THEN
        LET cfgPath = "northwind.odata"
    END IF

    IF NOT ODataConfig.loadConfigFromFile(cfgPath) THEN
        DISPLAY SFMT("Failed to load OData configuration: %1", cfgPath)
        EXIT PROGRAM 1
    END IF

    # Register function-provider callbacks for "function" entities.
    CALL ODataFunctionProvider.register(
        "CountrySummary", FUNCTION NorthwindFunctions.provideCountrySummary)

    # Authorization: apply the example per-entity policy. Scopes arrive in the
    # framework's X-OData-Scopes header (or, in production, the GAS-granted Scope
    # context once the bearer token is validated).
    CALL ODataAuth.setAuthorizer(FUNCTION NorthwindAuth.authorize)

    CALL ODataService.register(ODataConfig.getServiceName())
    DISPLAY SFMT("OData service '%1' started", ODataConfig.getServiceName())

    LET msg = ODataService.run()
    DISPLAY msg
END MAIN
