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
IMPORT FGL com.fourjs.odatalib.ODataExpand
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

    # --- $filter value functions (portable set) -------------------------------
    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found
    DISPLAY "\n== Customers?$filter=tolower(Country) eq 'germany'&$count=true  (expect 11) =="
    CALL showCollection(ent, "CustomerID", "tolower(Country) eq 'germany'", "3", NULL, "true", NULL)

    DISPLAY "\n== Customers?$filter=length(CompanyName) gt 18&$count=true  (expect 45) =="
    CALL showCollection(ent, "CustomerID", "length(CompanyName) gt 18", "3", NULL, "true", NULL)

    CALL ODataConfig.findEntity("Orders") RETURNING ent.*, found
    DISPLAY "\n== Orders?$filter=round(Freight) eq 32&$count=true  (expect 11) =="
    CALL showCollection(ent, "OrderID", "round(Freight) eq 32", "3", NULL, "true", NULL)

    DISPLAY "\n== Orders?$filter=year(OrderDate) eq 1997  (deferred, expect 501) =="
    CALL showCollection(ent, "OrderID", "year(OrderDate) eq 1997", NULL, NULL, NULL, NULL)

    DISPLAY "\n== Orders?$filter=Freight add 1 gt 2  (arithmetic, expect 501) =="
    CALL showCollection(ent, "OrderID", "Freight add 1 gt 2", NULL, NULL, NULL, NULL)

    # --- richer $expand: nested options ---------------------------------------
    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found
    DISPLAY "\n== Customers(ALFKI) $expand=Orders($orderby=OrderDate desc;$top=3;$select=OrderID)  (expect 11103,11011,10952) =="
    CALL showExpand(ent, "CustomerID", "CustomerID eq 'ALFKI'", NULL,
        "Orders($orderby=OrderDate desc;$top=3;$select=OrderID)")

    DISPLAY "\n== Customers(ALFKI) $expand=Orders($filter=Freight gt 50;$select=OrderID,Freight)  (expect 2 orders) =="
    CALL showExpand(ent, "CustomerID", "CustomerID eq 'ALFKI'", NULL,
        "Orders($filter=Freight gt 50;$select=OrderID,Freight)")

    DISPLAY "\n== Customers(ALFKI) $expand=Orders($count=true;$top=2;$select=OrderID)  (expect Orders@odata.count=7, 2 rows) =="
    CALL showExpand(ent, "CustomerID", "CustomerID eq 'ALFKI'", NULL,
        "Orders($count=true;$top=2;$select=OrderID)")

    # --- richer $expand: multi-level ------------------------------------------
    CALL ODataConfig.findEntity("Orders") RETURNING ent.*, found
    DISPLAY "\n== Orders(10248) $expand=OrderDetails($expand=Product($select=ProductName))  (2-level, 3 details) =="
    CALL showExpand(ent, "OrderID", "OrderID eq 10248", NULL,
        "OrderDetails($expand=Product($select=ProductName))")

    # --- richer $expand: error paths ------------------------------------------
    DISPLAY "\n== Orders(10248) $expand=OrderDetails($search=x)  (expect 501) =="
    CALL showExpand(ent, "OrderID", "OrderID eq 10248", NULL, "OrderDetails($search=x)")

    DISPLAY "\n== Orders(10248) $expand=OrderDetails($expand=Product($expand=Category($expand=Products)))  (expect depth 501) =="
    CALL showExpand(ent, "OrderID", "OrderID eq 10248", NULL,
        "OrderDetails($expand=Product($expand=Category($expand=Products)))")

    # --- lambda operators (any / all) -----------------------------------------
    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found
    DISPLAY "\n== Customers?$filter=Orders/any(o: o/Freight gt 100)&$count=true  (expect 55) =="
    CALL showCollection(ent, "CustomerID", "Orders/any(o: o/Freight gt 100)",
        "3", NULL, "true", NULL)

    DISPLAY "\n== Customers?$filter=Country eq 'Germany' and Orders/any(o: o/Freight gt 50)&$count=true  (expect 11) =="
    CALL showCollection(ent, "CustomerID",
        "Country eq 'Germany' and Orders/any(o: o/Freight gt 50)",
        "3", NULL, "true", NULL)

    DISPLAY "\n== Customers?$filter=Orders/any(o: o/ShipCountry in ('France','Spain'))&$count=true  (expect 14) =="
    CALL showCollection(ent, "CustomerID",
        "Orders/any(o: o/ShipCountry in ('France','Spain'))", "3", NULL, "true", NULL)

    CALL ODataConfig.findEntity("Orders") RETURNING ent.*, found
    DISPLAY "\n== Orders?$filter=OrderDetails/all(d: d/Quantity ge 10)&$count=true  (expect 507) =="
    CALL showCollection(ent, "OrderID", "OrderDetails/all(d: d/Quantity ge 10)",
        "3", NULL, "true", NULL)

    CALL ODataConfig.findEntity("Categories") RETURNING ent.*, found
    DISPLAY "\n== Categories?$filter=Products/any()&$count=true  (expect 9) =="
    CALL showCollection(ent, "CategoryID", "Products/any()", "3", NULL, "true", NULL)

    # --- lambda error paths ---------------------------------------------------
    CALL ODataConfig.findEntity("Orders") RETURNING ent.*, found
    DISPLAY "\n== Orders?$filter=OrderDetails/all()  (expect 400) =="
    CALL showCollection(ent, "OrderID", "OrderDetails/all()", NULL, NULL, NULL, NULL)

    DISPLAY "\n== Customers?$filter=Orders/any(o: o/Bogus eq 1)  (expect 400) =="
    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found
    CALL showCollection(ent, "CustomerID", "Orders/any(o: o/Bogus eq 1)",
        NULL, NULL, NULL, NULL)

    DISPLAY "\n== CountrySummary?$filter=Customers/any()  (function host, expect 501) =="
    CALL ODataConfig.findEntity("CountrySummary") RETURNING ent.*, found
    CALL showCollection(ent, NULL, "Customers/any()", NULL, NULL, NULL, NULL)

    # --- $apply (aggregation) -------------------------------------------------
    CALL ODataConfig.findEntity("Orders") RETURNING ent.*, found
    DISPLAY "\n== Orders?$apply=aggregate($count as N, Freight with sum as F)  (expect N=856, F=65450.10) =="
    CALL showApply(ent, "aggregate($count as N, Freight with sum as F)", NULL, NULL, NULL)

    DISPLAY "\n== Orders?$apply=groupby((ShipCountry),aggregate($count as N))&$orderby=N desc&$top=3  (USA 142, Germany 124, Brazil 83) =="
    CALL showApply(ent, "groupby((ShipCountry),aggregate($count as N))", "N desc", "3", NULL)

    DISPLAY "\n== Orders?$apply=filter(Freight gt 50)/groupby((ShipCountry),aggregate($count as N))&$orderby=N desc&$top=3  (USA 62, Germany 58, Austria 33) =="
    CALL showApply(ent,
        "filter(Freight gt 50)/groupby((ShipCountry),aggregate($count as N))",
        "N desc", "3", NULL)

    DISPLAY "\n== Orders?$apply=groupby((ShipCountry),aggregate(CustomerID with countdistinct as Custs))&$orderby=ShipCountry&$top=3 =="
    CALL showApply(ent,
        "groupby((ShipCountry),aggregate(CustomerID with countdistinct as Custs))",
        "ShipCountry", "3", NULL)

    CALL ODataConfig.findEntity("Products") RETURNING ent.*, found
    DISPLAY "\n== Products?$apply=groupby((CategoryID),aggregate(UnitPrice with average as AvgPrice, UnitPrice with max as MaxPrice))&$orderby=CategoryID&$top=3  (cat1 avg~30.75 max 263.5) =="
    CALL showApply(ent,
        "groupby((CategoryID),aggregate(UnitPrice with average as AvgPrice, UnitPrice with max as MaxPrice))",
        "CategoryID", "3", NULL)

    CALL ODataConfig.findEntity("Customers") RETURNING ent.*, found
    DISPLAY "\n== Customers?$apply=groupby((Country))&$count=true&$top=3  (expect @odata.count=21) =="
    CALL showApply(ent, "groupby((Country))", "Country", "3", "true")

    # --- $apply error paths ---------------------------------------------------
    DISPLAY "\n== Customers?$apply=aggregate(CompanyName with sum as X)  (non-numeric, expect 400) =="
    CALL showApply(ent, "aggregate(CompanyName with sum as X)", NULL, NULL, NULL)

    DISPLAY "\n== Customers?$apply=groupby((Bogus))  (expect 400) =="
    CALL showApply(ent, "groupby((Bogus))", NULL, NULL, NULL)

    DISPLAY "\n== Orders?$apply=topcount(5,Freight)  (expect 501) =="
    CALL ODataConfig.findEntity("Orders") RETURNING ent.*, found
    CALL showApply(ent, "topcount(5,Freight)", NULL, NULL, NULL)

    DISPLAY "\n== CountrySummary?$apply=aggregate($count as N)  (function host, expect 501) =="
    CALL ODataConfig.findEntity("CountrySummary") RETURNING ent.*, found
    CALL showApply(ent, "aggregate($count as N)", NULL, NULL, NULL)

    DISCONNECT CURRENT
END MAIN

#+ Parse $apply (+ optional $orderby/$top/$count), fetch via the provider (which
#+ routes aggregation to applyFetch), and print the serialised result or error.
FUNCTION showApply(
    ent ODataTypes.T_ODataEntity,
    pApply STRING, pOrderby STRING, pTop STRING, pCount STRING)
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE result ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject

    LET q = ODataQuery.parse(NULL, NULL, pTop, NULL, pCount, pOrderby, NULL, pApply)
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

#+ Parse $select/$filter/$top/$expand, fetch the collection, apply expansion
#+ in-process, and print the serialised result (or the parse/expand error).
FUNCTION showExpand(
    ent ODataTypes.T_ODataEntity,
    pSelect STRING, pFilter STRING, pTop STRING, pExpand STRING)
    DEFINE q ODataTypes.T_ODataQuery
    DEFINE result ODataTypes.T_ODataResult
    DEFINE obj util.JSONObject
    DEFINE eok BOOLEAN
    DEFINE ecode, emsg STRING

    LET q = ODataQuery.parse(pSelect, pFilter, pTop, NULL, NULL, NULL, pExpand, NULL)
    IF NOT q.ok THEN
        DISPLAY SFMT("  query error [%1]: %2", q.errorCode, q.errorMessage)
        RETURN
    END IF
    IF q.expandRoots.getLength() > 0 THEN
        LET q.selectList = ODataExpand.ensureJoinKeys(ent, q, q.selectList)
    END IF
    LET result = ODataProvider.fetch(ent, q)
    IF NOT result.ok THEN
        DISPLAY SFMT("  provider error [%1]: %2",
            result.errorCode, result.errorMessage)
        RETURN
    END IF
    IF q.expandRoots.getLength() > 0 THEN
        CALL ODataExpand.apply(ent, q, result.rows) RETURNING eok, ecode, emsg
        IF NOT eok THEN
            DISPLAY SFMT("  expand error [%1]: %2", ecode, emsg)
            RETURN
        END IF
    END IF
    LET obj = ODataSerializer.buildCollection(
        baseUrl, ent.name, result, q.wantCount, NULL)
    DISPLAY obj.toString()
END FUNCTION

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
