################################################################################
# odata_test.4gl
#
# Assert-based regression suite for odatalib. Runs the whole query pipeline
# (config -> ODataQuery -> provider -> ODataExpand -> ODataSerializer) against a
# self-contained in-memory SQLite database — no external server, just the Genero
# toolchain — so it can run in CI (`make test`). Exits non-zero if any check
# fails.
#
# Reuses the example seed (NorthwindCreate) + function provider
# (NorthwindFunctions) and the SQLite config examples/northwind.odata, which now
# declares Customers<->Orders navigation so $expand / lambda are covered too.
################################################################################
IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataQuery
IMPORT FGL com.fourjs.odatalib.ODataProvider
IMPORT FGL com.fourjs.odatalib.ODataExpand
IMPORT FGL com.fourjs.odatalib.ODataSerializer
IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider
IMPORT FGL NorthwindCreate
IMPORT FGL NorthwindFunctions

DEFINE m_pass, m_fail INTEGER

MAIN
    DEFINE cfg STRING

    CONNECT TO ":memory:+driver='dbmsqt'"
    CALL NorthwindCreate.createDatabase()

    LET cfg = fgl_getenv("ODATA_TEST_CONFIG")
    IF cfg IS NULL OR cfg.getLength() == 0 THEN
        LET cfg = "northwind.odata"
    END IF
    IF NOT ODataConfig.loadConfigFromFile(cfg) THEN
        DISPLAY "FATAL: could not load config ", cfg
        EXIT PROGRAM 2
    END IF
    CALL ODataFunctionProvider.register(
        "CountrySummary", FUNCTION NorthwindFunctions.provideCountrySummary)

    CALL testMetadata()
    CALL testCollectionAndFilter()
    CALL testFilterFunctions()
    CALL testInNullContains()
    CALL testOrderAndPaging()
    CALL testKeyLookup()
    CALL testExpand()
    CALL testLambda()
    CALL testApply()
    CALL testFunctionProvider()
    CALL testErrors()

    DISPLAY ""
    DISPLAY SFMT("==== odatalib tests: %1 passed, %2 failed ====", m_pass, m_fail)
    IF m_fail > 0 THEN
        EXIT PROGRAM 1
    END IF
END MAIN

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

FUNCTION testMetadata()
    DEFINE xml STRING
    LET xml = ODataSerializer.buildMetadata()
    CALL checkTrue("metadata has <NavigationProperty",
        xml.getIndexOf("<NavigationProperty", 1) > 0)
    CALL checkTrue("metadata has <NavigationPropertyBinding",
        xml.getIndexOf("<NavigationPropertyBinding", 1) > 0)
    CALL checkTrue("metadata has Customers EntitySet",
        xml.getIndexOf('<EntitySet Name="Customers"', 1) > 0)
END FUNCTION

FUNCTION testCollectionAndFilter()
    DEFINE r ODataTypes.T_ODataResult
    LET r = runColl("Customers", NULL, NULL, NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkInt("Customers count", r.count, 6)
    CALL checkInt("Customers rows", r.rows.getLength(), 6)

    LET r = runColl("Customers", NULL, "Country eq 'Germany'", NULL, NULL, "true",
        NULL, NULL, NULL)
    CALL checkInt("Germany count", r.count, 4)

    LET r = runColl("Customers", NULL,
        "Country eq 'Germany' and CompanyName eq 'Frankenversand'", NULL, NULL,
        NULL, NULL, NULL, NULL)
    CALL checkInt("and-filter rows", r.rows.getLength(), 1)

    LET r = runColl("Customers", NULL,
        "not (Country eq 'Germany')", NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkInt("not Germany count", r.count, 2)
END FUNCTION

FUNCTION testFilterFunctions()
    DEFINE r ODataTypes.T_ODataResult
    LET r = runColl("Customers", NULL, "tolower(Country) eq 'germany'", NULL,
        NULL, "true", NULL, NULL, NULL)
    CALL checkInt("tolower(Country)=germany", r.count, 4)

    LET r = runColl("Customers", NULL, "length(CompanyName) gt 23", NULL, NULL,
        "true", NULL, NULL, NULL)
    # 'Ana Trujillo Emparedados' (24) and 'Drachenblut Delikatessen' (24);
    # 'Blauer See Delikatessen' is 23, excluded.
    CALL checkInt("length(CompanyName)>23", r.count, 2)

    LET r = runColl("Orders", NULL, "round(Freight) eq 32", NULL, NULL, "true",
        NULL, NULL, NULL)
    CALL checkInt("round(Freight)=32", r.count, 1)
END FUNCTION

FUNCTION testInNullContains()
    DEFINE r ODataTypes.T_ODataResult
    LET r = runColl("Customers", NULL, "CustomerID in ('ALFKI','BLAUS')", NULL,
        NULL, "true", NULL, NULL, NULL)
    CALL checkInt("in-list count", r.count, 2)

    LET r = runColl("Customers", NULL, "contains(CompanyName,'Delikatessen')",
        NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkInt("contains Delikatessen", r.count, 2)

    LET r = runColl("Customers", NULL, "Country ne null", NULL, NULL, "true",
        NULL, NULL, NULL)
    CALL checkInt("Country ne null", r.count, 6)
END FUNCTION

FUNCTION testOrderAndPaging()
    DEFINE r ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject
    LET r = runColl("Customers", "CustomerID", NULL, "2", NULL, NULL, NULL, NULL,
        NULL)
    CALL checkInt("top=2 rows", r.rows.getLength(), 2)

    LET r = runColl("Orders", "OrderID,Freight", NULL, NULL, NULL, NULL,
        "Freight desc", NULL, NULL)
    LET obj = r.rows.get(1)
    CALL checkInt("orderby Freight desc -> 10250 first", obj.get("OrderID"), 10250)
END FUNCTION

FUNCTION testKeyLookup()
    DEFINE r ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject
    DEFINE ent ODataTypes.T_ODataEntity
    DEFINE found BOOLEAN
    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found
    LET r = ODataProvider.fetchByKey(ent, "ALFKI")
    CALL checkTrue("key lookup ok", r.ok AND r.rows.getLength() == 1)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        CALL checkStr("ALFKI CompanyName", obj.get("CompanyName"),
            "Alfreds Futterkiste")
    END IF
END FUNCTION

FUNCTION testExpand()
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE r ODataTypes.T_ODataResult
    DEFINE ent ODataTypes.T_ODataEntity
    DEFINE obj util.JSONObject
    DEFINE arr util.JSONArray
    DEFINE found, eok BOOLEAN
    DEFINE ecode, emsg STRING

    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found
    LET r = ODataProvider.fetchByKey(ent, "ALFKI")
    LET q = ODataQuery.parse(NULL, NULL, NULL, NULL, NULL, NULL, "Orders", NULL)
    CALL checkTrue("expand parse ok", q.ok)
    CALL ODataExpand.apply(ent, q, r.rows) RETURNING eok, ecode, emsg
    CALL checkTrue("expand apply ok", eok)
    LET obj = r.rows.get(1)
    LET arr = obj.get("Orders")
    CALL checkTrue("ALFKI Orders array present", arr IS NOT NULL)
    IF arr IS NOT NULL THEN
        CALL checkInt("ALFKI expanded Orders = 2", arr.getLength(), 2)
    END IF
END FUNCTION

FUNCTION testLambda()
    DEFINE r ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject
    LET r = runColl("Customers", "CustomerID",
        "Orders/any(o: o/Freight gt 50)", NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkInt("lambda any(Freight>50) count", r.count, 1)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        CALL checkStr("lambda match is FRANK", obj.get("CustomerID"), "FRANK")
    END IF
END FUNCTION

FUNCTION testApply()
    DEFINE r ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject
    LET r = runColl("Orders", NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        "aggregate($count as N)")
    CALL checkInt("aggregate rows", r.rows.getLength(), 1)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        CALL checkInt("aggregate $count N=4", obj.get("N"), 4)
    END IF

    LET r = runColl("Customers", NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        "groupby((Country),aggregate($count as N))")
    CALL checkInt("groupby Country -> 3 groups", r.rows.getLength(), 3)
END FUNCTION

FUNCTION testFunctionProvider()
    DEFINE r ODataTypes.T_ODataResult
    LET r = runColl("CountrySummary", NULL, NULL, NULL, NULL, "true", NULL, NULL,
        NULL)
    CALL checkTrue("function provider ok", r.ok)
    CALL checkTrue("CountrySummary has rows", r.rows.getLength() > 0)
END FUNCTION

FUNCTION testErrors()
    DEFINE q ODataTypes.T_ODataQuery
    # unsupported operator -> BadRequest
    LET q = ODataQuery.parse(NULL, "Country xx 'x'", NULL, NULL, NULL, NULL,
        NULL, NULL)
    CALL checkTrue("bad operator -> not ok", NOT q.ok)
    CALL checkStr("bad operator code", q.errorCode, "BadRequest")

    # deferred function -> NotImplemented
    LET q = ODataQuery.parse(NULL, "year(Freight) eq 1", NULL, NULL, NULL, NULL,
        NULL, NULL)
    CALL checkStr("year() -> NotImplemented", q.errorCode, "NotImplemented")

    # arithmetic -> NotImplemented
    LET q = ODataQuery.parse(NULL, "Freight add 1 gt 2", NULL, NULL, NULL, NULL,
        NULL, NULL)
    CALL checkStr("arithmetic -> NotImplemented", q.errorCode, "NotImplemented")

    # unknown property -> provider BadRequest
    CALL checkProviderErr("Orders", "Bogus eq 1", "BadRequest")
END FUNCTION

# ---------------------------------------------------------------------------
# Harness helpers
# ---------------------------------------------------------------------------

#+ Parse + fetch (+ expand) a collection request and return the result.
FUNCTION runColl(
    entName STRING, pSelect STRING, pFilter STRING, pTop STRING, pSkip STRING,
    pCount STRING, pOrderby STRING, pExpand STRING, pApply STRING)
    RETURNS ODataTypes.T_ODataResult
    DEFINE ent ODataTypes.T_ODataEntity
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE r ODataTypes.T_ODataResult
    DEFINE found, eok BOOLEAN
    DEFINE ecode, emsg STRING

    CALL ODataConfig.findEntity(entName) RETURNING ent.*, found
    IF NOT found THEN
        LET r.ok = FALSE
        LET r.errorCode = "NotFound"
        RETURN r
    END IF
    LET q = ODataQuery.parse(pSelect, pFilter, pTop, pSkip, pCount, pOrderby,
        pExpand, pApply)
    IF NOT q.ok THEN
        LET r.ok = FALSE
        LET r.errorCode = q.errorCode
        LET r.errorMessage = q.errorMessage
        RETURN r
    END IF
    IF q.expandRoots.getLength() > 0 THEN
        LET q.selectList = ODataExpand.ensureJoinKeys(ent, q, q.selectList)
    END IF
    LET r = ODataProvider.fetch(ent, q)
    IF r.ok AND q.expandRoots.getLength() > 0 THEN
        CALL ODataExpand.apply(ent, q, r.rows) RETURNING eok, ecode, emsg
    END IF
    RETURN r
END FUNCTION

#+ Assert that a filter against an entity yields a provider error with `code`.
FUNCTION checkProviderErr(entName STRING, pFilter STRING, code STRING)
    DEFINE r ODataTypes.T_ODataResult
    LET r = runColl(entName, NULL, pFilter, NULL, NULL, NULL, NULL, NULL, NULL)
    CALL checkTrue(SFMT("provider error for '%1'", pFilter), NOT r.ok)
    CALL checkStr(SFMT("provider error code for '%1'", pFilter), r.errorCode, code)
END FUNCTION

FUNCTION checkInt(label STRING, got INTEGER, want INTEGER)
    IF got == want THEN
        LET m_pass = m_pass + 1
    ELSE
        LET m_fail = m_fail + 1
        DISPLAY SFMT("FAIL: %1 (got %2, want %3)", label, got, want)
    END IF
END FUNCTION

FUNCTION checkStr(label STRING, got STRING, want STRING)
    IF got == want THEN
        LET m_pass = m_pass + 1
    ELSE
        LET m_fail = m_fail + 1
        DISPLAY SFMT("FAIL: %1 (got '%2', want '%3')", label, got, want)
    END IF
END FUNCTION

FUNCTION checkTrue(label STRING, cond BOOLEAN)
    IF cond THEN
        LET m_pass = m_pass + 1
    ELSE
        LET m_fail = m_fail + 1
        DISPLAY SFMT("FAIL: %1 (expected TRUE)", label)
    END IF
END FUNCTION
