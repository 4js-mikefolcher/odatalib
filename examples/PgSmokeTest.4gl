################################################################################
# PgSmokeTest.4gl
#
# Like SmokeTest, but runs the whole OData pipeline (config -> query parse ->
# provider -> serializer) against the real PostgreSQL Northwind database instead
# of the tiny in-memory SQLite seed. The richer, strictly-typed dataset exercises
# numeric / date filters and the JSON type serialisation that SQLite's loose
# typing hides.
#
#     export FGLPROFILE="$PWD/fglprofile"
#     FGLGUI=0 fglrun PgSmokeTest
################################################################################
IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataQuery
IMPORT FGL com.fourjs.odatalib.ODataProvider
IMPORT FGL com.fourjs.odatalib.ODataSerializer
IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider
IMPORT FGL NorthwindFunctions

DEFINE baseUrl STRING

MAIN
    DEFINE ent ODataTypes.T_ODataEntity
    DEFINE found BOOLEAN

    LET baseUrl = "http://localhost:8080/odata/northwind"

    TRY
        CONNECT TO "northwind" USER "nwuser" USING "nwuser"
    CATCH
        DISPLAY SFMT("CONNECT failed: %1 %2", sqlca.sqlcode, sqlerrmessage)
        EXIT PROGRAM 1
    END TRY

    IF NOT ODataConfig.loadConfigFromFile("northwind-pg.odata") THEN
        DISPLAY "Config load FAILED"
        EXIT PROGRAM 1
    END IF
    CALL ODataFunctionProvider.register(
        "CountrySummary", FUNCTION NorthwindFunctions.provideCountrySummary)
    DISPLAY "== Service: ", ODataConfig.getServiceName(),
        " (namespace ", ODataConfig.getNamespace(), ") =="

    # --- string filter (the v0 happy path) -----------------------------------
    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found
    DISPLAY "\n== Customers?$filter=Country eq 'Germany'&$top=3&$count=true =="
    CALL showCollection(ent, "CustomerID,CompanyName,Country",
        "Country eq 'Germany'", "3", NULL, "true", "CompanyName")

    # --- INTEGER output + INTEGER filter --------------------------------------
    CALL ODataConfig.findEntity("Orders") RETURNING ent.*, found
    DISPLAY "\n== Orders?$select=OrderID,Freight&$top=3  (are OrderID/Freight JSON numbers?) =="
    CALL showCollection(ent, "OrderID,CustomerID,Freight", NULL, "3", NULL, NULL, "OrderID")

    DISPLAY "\n== Orders?$filter=OrderID gt 11070&$count=true  (INTEGER filter) =="
    CALL showCollection(ent, "OrderID,Freight", "OrderID gt 11070", NULL, NULL, "true", "OrderID")

    # --- REAL / floating filter -----------------------------------------------
    DISPLAY "\n== Orders?$filter=Freight gt 800&$count=true  (REAL filter) =="
    CALL showCollection(ent, "OrderID,Freight", "Freight gt 800", NULL, NULL, "true", NULL)

    # --- DATE filter ----------------------------------------------------------
    DISPLAY "\n== Orders?$filter=OrderDate ge 1998-05-01&$count=true  (DATE filter) =="
    CALL showCollection(ent, "OrderID,OrderDate", "OrderDate ge 1998-05-01", "3", NULL, "true", "OrderDate")

    # --- Products: numeric mix ------------------------------------------------
    CALL ODataConfig.findEntity("Products") RETURNING ent.*, found
    DISPLAY "\n== Products?$filter=UnitPrice le 10&$count=true  (REAL filter, Int16 output) =="
    CALL showCollection(ent, "ProductID,ProductName,UnitPrice,UnitsInStock",
        "UnitPrice le 10", "3", NULL, "true", "UnitPrice")

    DISPLAY "\n== Products(11)  (INTEGER key lookup) =="
    CALL showEntity(ent, "11")

    # --- function provider, against real customers table ----------------------
    CALL ODataConfig.findEntity("CountrySummary") RETURNING ent.*, found
    DISPLAY "\n== CountrySummary?$count=true  (function provider) =="
    CALL showCollection(ent, NULL, NULL, "5", NULL, "true", NULL)

    DISCONNECT CURRENT
END MAIN

FUNCTION showCollection(
    ent ODataTypes.T_ODataEntity,
    pSelect STRING, pFilter STRING, pTop STRING, pSkip STRING,
    pCount STRING, pOrderby STRING)
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE result ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject

    LET q = ODataQuery.parse(pSelect, pFilter, pTop, pSkip, pCount, pOrderby, NULL)
    IF NOT q.ok THEN
        DISPLAY SFMT("  query error [%1]: %2", q.errorCode, q.errorMessage)
        RETURN
    END IF
    LET result = ODataProvider.fetch(ent, q)
    IF NOT result.ok THEN
        DISPLAY SFMT("  provider error [%1]: %2",
            result.errorCode, result.errorMessage)
        RETURN
    END IF
    LET obj = ODataSerializer.buildCollection(
        baseUrl, ent.name, result, q.wantCount, NULL)
    DISPLAY obj.toString()
END FUNCTION

FUNCTION showEntity(ent ODataTypes.T_ODataEntity, keyVal STRING)
    DEFINE result ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject

    LET result = ODataProvider.fetchByKey(ent, keyVal)
    IF NOT result.ok THEN
        DISPLAY SFMT("  [%1]: %2", result.errorCode, result.errorMessage)
        RETURN
    END IF
    LET obj = ODataSerializer.buildEntity(baseUrl, ent.name, result)
    IF obj IS NULL THEN
        DISPLAY "  (no row)"
    ELSE
        DISPLAY obj.toString()
    END IF
END FUNCTION
