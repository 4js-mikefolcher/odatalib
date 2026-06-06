################################################################################
# SmokeTest.4gl
#
# Exercises the whole OData pipeline (config -> query parse -> provider ->
# serializer) WITHOUT the GAS web service engine, so it can be run from a plain
# terminal to validate the framework logic end to end.
#
#     fglrun SmokeTest
################################################################################
IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataQuery
IMPORT FGL com.fourjs.odatalib.ODataProvider
IMPORT FGL com.fourjs.odatalib.ODataSerializer
IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider
IMPORT FGL NorthwindCreate
IMPORT FGL NorthwindFunctions

DEFINE baseUrl STRING

MAIN
    DEFINE ent ODataTypes.T_ODataEntity
    DEFINE found BOOLEAN

    LET baseUrl = "http://localhost:8080/odata/northwind"

    CONNECT TO ":memory:+driver='dbmsqt'"
    CALL NorthwindCreate.createDatabase()

    IF NOT ODataConfig.loadConfigFromFile("northwind.odata") THEN
        DISPLAY "Config load FAILED"
        EXIT PROGRAM 1
    END IF
    CALL ODataFunctionProvider.register(
        "CountrySummary", FUNCTION NorthwindFunctions.provideCountrySummary)
    DISPLAY "== Service: ", ODataConfig.getServiceName(),
        " (namespace ", ODataConfig.getNamespace(), ") =="

    DISPLAY "\n== $metadata =="
    DISPLAY ODataSerializer.buildMetadata()

    DISPLAY "\n== Service document =="
    DISPLAY ODataSerializer.buildServiceDocument(baseUrl).toString()

    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found

    DISPLAY "\n== Customers?$select=CompanyName,Country&$filter=Country eq 'Germany'&$orderby=CompanyName desc&$count=true =="
    CALL showCollection(ent,
        "CompanyName,Country", "Country eq 'Germany'",
        NULL, NULL, "true", "CompanyName desc")

    DISPLAY "\n== Customers?$filter=startswith(CompanyName,'A') =="
    CALL showCollection(ent,
        NULL, "startswith(CompanyName,'A')", NULL, NULL, NULL, NULL)

    DISPLAY "\n== Customers?$top=2 (paging) =="
    CALL showCollection(ent, NULL, NULL, "2", NULL, NULL, NULL)

    DISPLAY "\n== Customers('ALFKI') =="
    CALL showEntity(ent, "ALFKI")

    DISPLAY "\n== Customers('NOPE') (expect not found) =="
    CALL showEntity(ent, "NOPE")

    DISPLAY "\n== Bad filter (expect error result) =="
    CALL showCollection(ent, NULL, "Country xx 'Germany'",
        NULL, NULL, NULL, NULL)

    # --- function provider: BDL-processed (aggregated) entity ----------------
    CALL ODataConfig.findEntity("CountrySummary") RETURNING ent.*, found

    DISPLAY "\n== CountrySummary?$count=true (function provider) =="
    CALL showCollection(ent, NULL, NULL, NULL, NULL, "true", NULL)

    DISPLAY "\n== CountrySummary('Germany') (function provider, key lookup) =="
    CALL showEntity(ent, "Germany")

    DISCONNECT CURRENT
END MAIN

FUNCTION showCollection(
    ent ODataTypes.T_ODataEntity,
    pSelect STRING, pFilter STRING, pTop STRING, pSkip STRING,
    pCount STRING, pOrderby STRING)
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE result ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject

    LET q = ODataQuery.parse(pSelect, pFilter, pTop, pSkip, pCount, pOrderby, NULL, NULL)
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
