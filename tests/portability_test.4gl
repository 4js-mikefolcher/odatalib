################################################################################
# portability_test.4gl
#
# Cross-engine / cross-schema portability suite for odatalib. Runs the whole
# query pipeline (config -> ODataQuery -> provider -> ODataExpand ->
# ODataSerializer) against a *live* database server selected by FGLPROFILE, and
# asserts the full OData functional surface: $filter (incl. value functions),
# $select/$top/$skip/$orderby/$count, $expand (nested + multi-level), lambda
# any/all, $apply aggregation, key lookup, $metadata, and the error paths.
#
# It is driven entirely by environment variables so the same binary can be run
# against every (engine, schema) combination from a shell loop:
#
#   ODATA_TEST_CONFIG   the .odata config file to load        (required)
#   ODATA_DB            the database name to CONNECT TO        (required)
#   ODATA_SCHEMA        "nw" (Northwind) or "aw" (AdventureWorks)   (required)
#
#   export FGLPROFILE=/opt/fourjs/dbfiles/fglprofile.pgs
#   ODATA_TEST_CONFIG=adventureworks.odata ODATA_DB=adventureworks \
#     ODATA_SCHEMA=aw FGLGUI=0 fglrun portability_test.42m
#
# AdventureWorks data is identical across the three engines, so its checks are
# exact counts. Northwind differs per engine (and the Postgres copy is mutated
# by a live CRUD app), so its checks are relational / known-row facts and
# query-equivalence properties that hold regardless of the row totals.
#
# Exits non-zero if any check fails.
################################################################################
IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig
IMPORT FGL com.fourjs.odatalib.ODataQuery
IMPORT FGL com.fourjs.odatalib.ODataProvider
IMPORT FGL com.fourjs.odatalib.ODataExpand
IMPORT FGL com.fourjs.odatalib.ODataSerializer
IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider
IMPORT FGL NorthwindFunctions

DEFINE m_pass, m_fail INTEGER
DEFINE m_db, m_cfg, m_schema STRING

MAIN
    LET m_cfg = fgl_getenv("ODATA_TEST_CONFIG")
    LET m_db = fgl_getenv("ODATA_DB")
    LET m_schema = fgl_getenv("ODATA_SCHEMA")
    IF m_cfg IS NULL OR m_db IS NULL OR m_schema IS NULL THEN
        DISPLAY "FATAL: set ODATA_TEST_CONFIG, ODATA_DB, ODATA_SCHEMA"
        EXIT PROGRAM 2
    END IF

    DISPLAY SFMT("==== portability: schema=%1 db=%2 config=%3 ====",
        m_schema, m_db, m_cfg)

    TRY
        CONNECT TO m_db
    CATCH
        DISPLAY SFMT("FATAL: CONNECT TO %1 failed: %2 %3",
            m_db, sqlca.sqlcode, sqlerrmessage)
        EXIT PROGRAM 3
    END TRY

    IF NOT ODataConfig.loadConfigFromFile(m_cfg) THEN
        DISPLAY SFMT("FATAL: could not load config %1", m_cfg)
        EXIT PROGRAM 2
    END IF

    CALL testMetadata()
    CASE m_schema
        WHEN "aw" CALL awScenarios()
        WHEN "nw"
            CALL ODataFunctionProvider.register(
                "CountrySummary", FUNCTION NorthwindFunctions.provideCountrySummary)
            CALL nwScenarios()
        OTHERWISE
            DISPLAY SFMT("FATAL: unknown ODATA_SCHEMA '%1' (want nw|aw)", m_schema)
            EXIT PROGRAM 2
    END CASE
    CALL testErrors()

    DISCONNECT CURRENT
    DISPLAY ""
    DISPLAY SFMT("==== %1/%2: %3 passed, %4 failed ====",
        m_schema, m_db, m_pass, m_fail)
    IF m_fail > 0 THEN
        EXIT PROGRAM 1
    END IF
END MAIN

# ---------------------------------------------------------------------------
# Schema-independent: $metadata
# ---------------------------------------------------------------------------
FUNCTION testMetadata()
    DEFINE xml STRING
    LET xml = ODataSerializer.buildMetadata()
    CALL checkTrue("metadata has <EntityType",
        xml.getIndexOf("<EntityType", 1) > 0)
    CALL checkTrue("metadata has <NavigationProperty",
        xml.getIndexOf("<NavigationProperty", 1) > 0)
    CALL checkTrue("metadata has <NavigationPropertyBinding",
        xml.getIndexOf("<NavigationPropertyBinding", 1) > 0)
    CALL checkTrue("metadata has <EntityContainer",
        xml.getIndexOf("<EntityContainer", 1) > 0)
END FUNCTION

# ---------------------------------------------------------------------------
# AdventureWorks scenarios (exact counts; data is identical across engines)
# ---------------------------------------------------------------------------
FUNCTION awScenarios()
    DEFINE r ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject
    DEFINE arr util.JSONArray
    DEFINE nPlain INTEGER

    # --- collection + $count (exact totals) ---------------------------------
    LET r = runColl("SalesTerritories", NULL, NULL, NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkInt("SalesTerritories count", r.count, 10)
    CALL checkInt("SalesTerritories rows", r.rows.getLength(), 10)

    LET r = runColl("Products", NULL, NULL, NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkInt("Products count", r.count, 504)

    LET r = runColl("Customers", NULL, NULL, NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkInt("Customers count", r.count, 19820)

    LET r = runColl("SalesOrders", NULL, NULL, NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkInt("SalesOrders count", r.count, 31465)

    # --- INTEGER filter ------------------------------------------------------
    LET r = runColl("SalesOrders", "SalesOrderID,TerritoryID", "TerritoryID eq 1",
        "20", NULL, "true", NULL, NULL, NULL)
    CALL checkInt("SalesOrders TerritoryID eq 1 count", r.count, 4594)
    CALL allEqInt(r, "TerritoryID", 1, "TerritoryID eq 1 rows match")

    # --- DECIMAL filter ------------------------------------------------------
    LET r = runColl("Products", "ProductID,ListPrice", "ListPrice gt 1000",
        "20", NULL, "true", NULL, NULL, NULL)
    CALL checkInt("Products ListPrice gt 1000 count", r.count, 86)
    CALL allGtDec(r, "ListPrice", 1000, "ListPrice gt 1000 rows match")

    # --- STRING filter -------------------------------------------------------
    LET r = runColl("Products", "ProductID,Color", "Color eq 'Black'",
        "20", NULL, "true", NULL, NULL, NULL)
    CALL checkInt("Products Color eq 'Black' count", r.count, 93)
    CALL allEqStr(r, "Color", "Black", "Color eq Black rows match")

    # --- value functions -----------------------------------------------------
    LET r = runColl("Products", NULL, "tolower(Color) eq 'black'", NULL, NULL,
        "true", NULL, NULL, NULL)
    CALL checkInt("tolower(Color) eq 'black' count", r.count, 93)

    LET r = runColl("Products", "ProductID", "round(ListPrice) eq 35", NULL, NULL,
        "true", NULL, NULL, NULL)
    CALL checkTrue("round(ListPrice) executes (>=0)", r.ok AND r.count >= 0)

    # --- key lookup ----------------------------------------------------------
    LET obj = keyLookup("Products", "1")
    CALL checkTrue("Products(1) found", obj IS NOT NULL)
    IF obj IS NOT NULL THEN
        CALL checkStr("Products(1).Name", obj.get("Name"), "Adjustable Race")
    END IF

    # --- $orderby + $top -----------------------------------------------------
    LET r = runColl("Products", "ProductID,ListPrice", "ListPrice gt 0", "10",
        NULL, NULL, "ListPrice desc", NULL, NULL)
    CALL checkInt("Products $top=10 rows", r.rows.getLength(), 10)
    CALL checkTrue("$orderby ListPrice desc is non-increasing",
        descDec(r, "ListPrice"))

    # --- $expand (collection) ------------------------------------------------
    LET r = runColl("Customers", NULL, "CustomerID eq 11091", NULL, NULL, NULL,
        NULL, "Orders", NULL)
    CALL checkInt("Customers(11091) expand row", r.rows.getLength(), 1)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        LET arr = obj.get("Orders")
        CALL checkTrue("11091 Orders array present", arr IS NOT NULL)
        IF arr IS NOT NULL THEN
            CALL checkInt("11091 expanded Orders = 28", arr.getLength(), 28)
        END IF
    END IF

    # --- $expand nested options ($top/$orderby/$select/$count) ---------------
    LET r = runColl("Customers", NULL, "CustomerID eq 11091", NULL, NULL, NULL,
        NULL, "Orders($count=true;$top=5;$orderby=SalesOrderID desc;$select=SalesOrderID)",
        NULL)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        LET arr = obj.get("Orders")
        CALL checkTrue("nested expand Orders array present", arr IS NOT NULL)
        IF arr IS NOT NULL THEN
            CALL checkInt("nested $top=5 -> 5 rows", arr.getLength(), 5)
        END IF
        CALL checkInt("nested $count -> Orders@odata.count=28",
            obj.get("Orders@odata.count"), 28)
    END IF

    # --- $expand multi-level (Order -> Details -> Product) -------------------
    LET r = runColl("SalesOrders", NULL, "SalesOrderID eq 43659", NULL, NULL,
        NULL, NULL, "Details($expand=Product($select=Name))", NULL)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        LET arr = obj.get("Details")
        CALL checkTrue("43659 Details array present", arr IS NOT NULL)
        IF arr IS NOT NULL THEN
            CALL checkInt("43659 Details = 12", arr.getLength(), 12)
            IF arr.getLength() > 0 THEN
                LET obj = arr.get(1)
                CALL checkTrue("detail has nested Product object",
                    obj.get("Product") IS NOT NULL)
            END IF
        END IF
    END IF

    # --- lambda any / all ----------------------------------------------------
    LET r = runColl("SalesTerritories", NULL, "Customers/any()", NULL, NULL,
        "true", NULL, NULL, NULL)
    CALL checkInt("territories with any customer", r.count, 10)

    LET r = runColl("Customers", NULL, "Orders/any(o: o/Freight gt 100)", NULL,
        NULL, "true", NULL, NULL, NULL)
    CALL checkInt("customers any(order freight>100)", r.count, 471)

    LET r = runColl("SalesOrders", NULL, "Details/all(d: d/OrderQty ge 1)", NULL,
        NULL, "true", NULL, NULL, NULL)
    CALL checkInt("orders all(detail qty>=1)", r.count, 31465)

    # --- $apply --------------------------------------------------------------
    LET r = runColl("SalesOrders", NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        "aggregate($count as N, Freight with sum as F, SubTotal with sum as S)")
    CALL checkInt("aggregate rows", r.rows.getLength(), 1)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        CALL checkInt("aggregate $count N", obj.get("N"), 31465)
        CALL checkDec("aggregate sum(Freight)", obj.get("F"), 3183430.2518, 0.01)
        CALL checkDec("aggregate sum(SubTotal)", obj.get("S"), 109846381.4039, 0.5)
    END IF

    LET r = runColl("SalesOrders", NULL, NULL, NULL, NULL, "true", "N desc", NULL,
        "groupby((TerritoryID),aggregate($count as N))")
    CALL checkInt("groupby TerritoryID -> 10 groups (rows)", r.rows.getLength(), 10)
    CALL checkInt("groupby TerritoryID -> 10 groups ($count)", r.count, 10)
    IF r.rows.getLength() >= 1 THEN
        LET obj = r.rows.get(1)
        CALL checkInt("top territory by orders is #9", obj.get("TerritoryID"), 9)
        CALL checkInt("top territory order count", obj.get("N"), 6843)
    END IF

    # --- aggregate-equivalence: $apply $count must equal a plain $count ------
    LET r = runColl("Products", NULL, NULL, NULL, NULL, "true", NULL, NULL, NULL)
    LET nPlain = r.count
    LET r = runColl("Products", NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        "aggregate($count as N)")
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        CALL checkInt("aggregate count == plain count", obj.get("N"), nPlain)
    END IF
END FUNCTION

# ---------------------------------------------------------------------------
# Northwind scenarios (relational / known-row facts + equivalence properties;
# the per-engine row totals differ and the Postgres copy is live-mutated)
# ---------------------------------------------------------------------------
FUNCTION nwScenarios()
    DEFINE r, r2 ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject
    DEFINE arr, det util.JSONArray

    # --- known-row key lookup (ALFKI is canonical in every Northwind) --------
    LET obj = keyLookup("Customers", "ALFKI")
    CALL checkTrue("Customers(ALFKI) found", obj IS NOT NULL)
    IF obj IS NOT NULL THEN
        CALL checkStr("ALFKI CompanyName", obj.get("CompanyName"),
            "Alfreds Futterkiste")
        CALL checkStr("ALFKI Country", obj.get("Country"), "Germany")
    END IF

    # --- STRING filter: every returned row really satisfies the predicate ----
    LET r = runColl("Customers", "CustomerID,Country", "Country eq 'Germany'",
        "50", NULL, "true", NULL, NULL, NULL)
    CALL checkTrue("Germany filter returns rows", r.count > 0)
    CALL allEqStr(r, "Country", "Germany", "Country eq Germany rows match")

    # --- value-function equivalence: tolower(Country)='germany' == eq Germany -
    LET r2 = runColl("Customers", NULL, "tolower(Country) eq 'germany'", NULL,
        NULL, "true", NULL, NULL, NULL)
    CALL checkInt("tolower(Country) equivalence to eq 'Germany'", r2.count, r.count)

    # --- INTEGER filter ------------------------------------------------------
    LET r = runColl("Orders", "OrderID", "OrderID gt 11000", "50", NULL, "true",
        NULL, NULL, NULL)
    CALL checkTrue("OrderID gt 11000 returns rows", r.count > 0)
    CALL allGtInt(r, "OrderID", 11000, "OrderID gt 11000 rows match")

    # --- DECIMAL/Single filter -----------------------------------------------
    LET r = runColl("Orders", "OrderID,Freight", "Freight gt 100", "50", NULL,
        "true", NULL, NULL, NULL)
    CALL checkTrue("Freight gt 100 returns rows", r.count > 0)
    CALL allGtDec(r, "Freight", 100, "Freight gt 100 rows match")

    # --- length() value function (verify each row's length in BDL) -----------
    LET r = runColl("Customers", "CustomerID,CompanyName",
        "length(CompanyName) gt 18", "50", NULL, "true", NULL, NULL, NULL)
    CALL checkTrue("length(CompanyName)>18 returns rows", r.count > 0)
    CALL allLenGt(r, "CompanyName", 18, "length(CompanyName)>18 rows match")

    # --- round() executes ----------------------------------------------------
    LET r = runColl("Orders", "OrderID", "round(Freight) eq 32", NULL, NULL,
        "true", NULL, NULL, NULL)
    CALL checkTrue("round(Freight) executes (>=0)", r.ok AND r.count >= 0)

    # --- in / contains -------------------------------------------------------
    LET r = runColl("Customers", "CustomerID", "CustomerID in ('ALFKI','ANATR')",
        NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkTrue("in-list returns 1..2 rows", r.count >= 1 AND r.count <= 2)
    CALL allInTwo(r, "CustomerID", "ALFKI", "ANATR", "in-list rows match")

    LET r = runColl("Customers", "CustomerID,CompanyName",
        "contains(CompanyName,'Alfreds')", NULL, NULL, "true", NULL, NULL, NULL)
    CALL checkTrue("contains('Alfreds') finds ALFKI", r.count >= 1)

    # --- $orderby (non-increasing) + $top ------------------------------------
    LET r = runColl("Orders", "OrderID,Freight", "Freight gt 0", "5", NULL, NULL,
        "Freight desc", NULL, NULL)
    CALL checkTrue("$top=5 rows <= 5", r.rows.getLength() <= 5)
    CALL checkTrue("$orderby Freight desc is non-increasing", descDec(r, "Freight"))

    # --- $expand (ALFKI Orders) ----------------------------------------------
    LET r = runColl("Customers", NULL, "CustomerID eq 'ALFKI'", NULL, NULL, NULL,
        NULL, "Orders", NULL)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        LET arr = obj.get("Orders")
        CALL checkTrue("ALFKI Orders array present", arr IS NOT NULL)
        IF arr IS NOT NULL THEN
            CALL checkTrue("ALFKI has >=1 order", arr.getLength() >= 1)
        END IF
    END IF

    # --- $expand nested ($top) -----------------------------------------------
    LET r = runColl("Customers", NULL, "CustomerID eq 'ALFKI'", NULL, NULL, NULL,
        NULL, "Orders($top=3;$select=OrderID)", NULL)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        LET arr = obj.get("Orders")
        IF arr IS NOT NULL THEN
            CALL checkTrue("nested $top=3 -> <=3 rows", arr.getLength() <= 3)
        END IF
    END IF

    # --- $expand multi-level (ALFKI Orders -> OrderDetails) ------------------
    LET r = runColl("Customers", NULL, "CustomerID eq 'ALFKI'", NULL, NULL, NULL,
        NULL, "Orders($expand=OrderDetails)", NULL)
    IF r.rows.getLength() == 1 THEN
        LET obj = r.rows.get(1)
        LET arr = obj.get("Orders")
        IF arr IS NOT NULL AND arr.getLength() >= 1 THEN
            LET obj = arr.get(1)
            LET det = obj.get("OrderDetails")
            CALL checkTrue("nested OrderDetails array present", det IS NOT NULL)
        END IF
    END IF

    # --- lambda monotonicity: any(P) is a subset of any() --------------------
    LET r = runColl("Customers", NULL, "Orders/any()", NULL, NULL, "true", NULL,
        NULL, NULL)
    LET r2 = runColl("Customers", NULL, "Orders/any(o: o/Freight gt 100)", NULL,
        NULL, "true", NULL, NULL, NULL)
    CALL checkTrue("lambda any() executes", r.ok)
    CALL checkTrue("lambda any(Freight>100) executes", r2.ok)
    CALL checkTrue("any(Freight>100) subset of any()",
        r2.count >= 0 AND r2.count <= r.count)

    LET r = runColl("Orders", NULL, "OrderDetails/all(d: d/Quantity ge 1)", NULL,
        NULL, "true", NULL, NULL, NULL)
    CALL checkTrue("lambda all() executes and returns rows", r.ok AND r.count > 0)

    # --- $apply equivalence: aggregate $count == plain $count ----------------
    LET r = runColl("Orders", NULL, NULL, NULL, NULL, "true", NULL, NULL, NULL)
    LET r2 = runColl("Orders", NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        "aggregate($count as N)")
    IF r2.rows.getLength() == 1 THEN
        LET obj = r2.rows.get(1)
        CALL checkInt("aggregate count == plain Orders count", obj.get("N"), r.count)
    END IF

    LET r = runColl("Customers", NULL, NULL, NULL, NULL, "true", "Country", NULL,
        "groupby((Country),aggregate($count as N))")
    CALL checkTrue("groupby Country returns groups", r.rows.getLength() > 0)
    CALL checkInt("groupby $count == group rows", r.count, r.rows.getLength())

    # --- function provider ---------------------------------------------------
    LET r = runColl("CountrySummary", NULL, NULL, NULL, NULL, "true", NULL, NULL,
        NULL)
    CALL checkTrue("function provider ok", r.ok)
    CALL checkTrue("CountrySummary has rows", r.rows.getLength() > 0)
END FUNCTION

# ---------------------------------------------------------------------------
# Schema-independent: error paths (pure parser/provider behaviour)
# ---------------------------------------------------------------------------
FUNCTION testErrors()
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE ent STRING

    IF m_schema == "aw" THEN
        LET ent = "Products"
    ELSE
        LET ent = "Orders"
    END IF

    LET q = ODataQuery.parse(NULL, "Color zz 'x'", NULL, NULL, NULL, NULL, NULL, NULL)
    CALL checkStr("bad operator -> BadRequest", q.errorCode, "BadRequest")

    LET q = ODataQuery.parse(NULL, "year(OrderDate) eq 1", NULL, NULL, NULL, NULL,
        NULL, NULL)
    CALL checkStr("year() -> NotImplemented", q.errorCode, "NotImplemented")

    LET q = ODataQuery.parse(NULL, "Freight add 1 gt 2", NULL, NULL, NULL, NULL,
        NULL, NULL)
    CALL checkStr("arithmetic -> NotImplemented", q.errorCode, "NotImplemented")

    CALL checkProviderErr(ent, "Bogus eq 1", "BadRequest")
END FUNCTION

# ---------------------------------------------------------------------------
# Pipeline helpers
# ---------------------------------------------------------------------------
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
        IF NOT eok THEN
            LET r.ok = FALSE
            LET r.errorCode = ecode
            LET r.errorMessage = emsg
        END IF
    END IF
    RETURN r
END FUNCTION

#+ Single-entity key lookup; returns the row object (or NULL).
FUNCTION keyLookup(entName STRING, keyVal STRING) RETURNS util.JSONObject
    DEFINE ent ODataTypes.T_ODataEntity
    DEFINE r ODataTypes.T_ODataResult
    DEFINE found BOOLEAN
    CALL ODataConfig.findEntity(entName) RETURNING ent.*, found
    IF NOT found THEN RETURN NULL END IF
    LET r = ODataProvider.fetchByKey(ent, keyVal)
    IF NOT r.ok OR r.rows.getLength() != 1 THEN RETURN NULL END IF
    RETURN r.rows.get(1)
END FUNCTION

FUNCTION checkProviderErr(entName STRING, pFilter STRING, code STRING)
    DEFINE r ODataTypes.T_ODataResult
    LET r = runColl(entName, NULL, pFilter, NULL, NULL, NULL, NULL, NULL, NULL)
    CALL checkTrue(SFMT("provider error for '%1'", pFilter), NOT r.ok)
    CALL checkStr(SFMT("provider error code for '%1'", pFilter), r.errorCode, code)
END FUNCTION

# ---------------------------------------------------------------------------
# Row-set assertion helpers (prove every returned row satisfies the predicate)
# ---------------------------------------------------------------------------
FUNCTION allEqStr(r ODataTypes.T_ODataResult, prop STRING, want STRING, label STRING)
    DEFINE i INTEGER
    DEFINE obj util.JSONObject
    FOR i = 1 TO r.rows.getLength()
        LET obj = r.rows.get(i)
        IF obj.get(prop) != want THEN
            CALL checkTrue(SFMT("%1 (row %2 = '%3')", label, i, obj.get(prop)), FALSE)
            RETURN
        END IF
    END FOR
    CALL checkTrue(label, TRUE)
END FUNCTION

FUNCTION allInTwo(r ODataTypes.T_ODataResult, prop STRING, a STRING, b STRING, label STRING)
    DEFINE i INTEGER
    DEFINE obj util.JSONObject
    DEFINE v STRING
    FOR i = 1 TO r.rows.getLength()
        LET obj = r.rows.get(i)
        LET v = obj.get(prop)
        IF v != a AND v != b THEN
            CALL checkTrue(SFMT("%1 (row %2 = '%3')", label, i, v), FALSE)
            RETURN
        END IF
    END FOR
    CALL checkTrue(label, TRUE)
END FUNCTION

FUNCTION allEqInt(r ODataTypes.T_ODataResult, prop STRING, want INTEGER, label STRING)
    DEFINE i, v INTEGER
    DEFINE obj util.JSONObject
    FOR i = 1 TO r.rows.getLength()
        LET obj = r.rows.get(i)
        LET v = obj.get(prop)
        IF v != want THEN
            CALL checkTrue(SFMT("%1 (row %2 = %3)", label, i, v), FALSE)
            RETURN
        END IF
    END FOR
    CALL checkTrue(label, TRUE)
END FUNCTION

FUNCTION allGtInt(r ODataTypes.T_ODataResult, prop STRING, minv INTEGER, label STRING)
    DEFINE i, v INTEGER
    DEFINE obj util.JSONObject
    FOR i = 1 TO r.rows.getLength()
        LET obj = r.rows.get(i)
        LET v = obj.get(prop)
        IF NOT (v > minv) THEN
            CALL checkTrue(SFMT("%1 (row %2 = %3)", label, i, v), FALSE)
            RETURN
        END IF
    END FOR
    CALL checkTrue(label, TRUE)
END FUNCTION

FUNCTION allGtDec(r ODataTypes.T_ODataResult, prop STRING, minv DECIMAL, label STRING)
    DEFINE i INTEGER
    DEFINE v DECIMAL(20,4)
    DEFINE obj util.JSONObject
    FOR i = 1 TO r.rows.getLength()
        LET obj = r.rows.get(i)
        LET v = obj.get(prop)
        IF NOT (v > minv) THEN
            CALL checkTrue(SFMT("%1 (row %2 = %3)", label, i, v), FALSE)
            RETURN
        END IF
    END FOR
    CALL checkTrue(label, TRUE)
END FUNCTION

FUNCTION allLenGt(r ODataTypes.T_ODataResult, prop STRING, minv INTEGER, label STRING)
    DEFINE i INTEGER
    DEFINE s STRING
    DEFINE obj util.JSONObject
    FOR i = 1 TO r.rows.getLength()
        LET obj = r.rows.get(i)
        LET s = obj.get(prop)
        IF NOT (s.getLength() > minv) THEN
            CALL checkTrue(SFMT("%1 (row %2 len %3)", label, i, s.getLength()), FALSE)
            RETURN
        END IF
    END FOR
    CALL checkTrue(label, TRUE)
END FUNCTION

#+ TRUE when the named DECIMAL property is non-increasing across the rows.
FUNCTION descDec(r ODataTypes.T_ODataResult, prop STRING) RETURNS BOOLEAN
    DEFINE i INTEGER
    DEFINE prev, cur DECIMAL(20,4)
    DEFINE obj util.JSONObject
    FOR i = 1 TO r.rows.getLength()
        LET obj = r.rows.get(i)
        LET cur = obj.get(prop)
        IF i > 1 AND cur > prev THEN
            RETURN FALSE
        END IF
        LET prev = cur
    END FOR
    RETURN TRUE
END FUNCTION

# ---------------------------------------------------------------------------
# Assertion primitives
# ---------------------------------------------------------------------------
FUNCTION checkInt(label STRING, got INTEGER, want INTEGER)
    IF got == want THEN
        LET m_pass = m_pass + 1
    ELSE
        LET m_fail = m_fail + 1
        DISPLAY SFMT("FAIL: %1 (got %2, want %3)", label, got, want)
    END IF
END FUNCTION

FUNCTION checkDec(label STRING, got DECIMAL, want DECIMAL, tol DECIMAL)
    DEFINE d DECIMAL(20,4)
    LET d = got - want
    IF d < 0 THEN LET d = -d END IF
    IF d <= tol THEN
        LET m_pass = m_pass + 1
    ELSE
        LET m_fail = m_fail + 1
        DISPLAY SFMT("FAIL: %1 (got %2, want %3 +/-%4)", label, got, want, tol)
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
