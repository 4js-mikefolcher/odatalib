################################################################################
# NorthwindPgService.4gl
#
# Reference OData service backed by the real PostgreSQL Northwind database
# (the richer, strictly-typed dataset). Same shape as NorthwindService, but it
# connects to PostgreSQL and serves the larger northwind-pg.odata schema, which
# includes the composite-key OrderDetails entity.
#
# Requires FGLPROFILE to map the "northwind" connection to the dbmpgs driver
# (see examples/fglprofile). Hosted by GAS via examples/resources/northwind-pg.xcf.
################################################################################
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataService
IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider
IMPORT FGL NorthwindFunctions

MAIN
    DEFINE msg, cfgPath STRING

    TRY
        CONNECT TO "northwind" USER "nwuser" USING "nwuser"
    CATCH
        DISPLAY SFMT("SQL connection failed: %1 %2", sqlca.sqlcode, sqlerrmessage)
        EXIT PROGRAM 1
    END TRY

    LET cfgPath = fgl_getenv("ODATA_CONFIG")
    IF cfgPath IS NULL OR cfgPath.getLength() == 0 THEN
        LET cfgPath = "northwind-pg.odata"
    END IF

    IF NOT ODataConfig.loadConfigFromFile(cfgPath) THEN
        DISPLAY SFMT("Failed to load OData configuration: %1", cfgPath)
        EXIT PROGRAM 1
    END IF

    CALL ODataFunctionProvider.register(
        "CountrySummary", FUNCTION NorthwindFunctions.provideCountrySummary)

    CALL ODataService.register(ODataConfig.getServiceName())
    DISPLAY SFMT("OData service '%1' started (PostgreSQL)",
        ODataConfig.getServiceName())

    LET msg = ODataService.run()
    DISPLAY msg
END MAIN
