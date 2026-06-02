################################################################################
# NorthwindFunctions.4gl
#
# Example "function provider" callbacks: BDL business logic exposed as OData
# entities. CountrySummary is a derived/aggregated entity (customers grouped by
# country) — the kind of BDL-processed data a direct-database connector could
# not produce. Registered with the framework in the service MAIN via a function
# reference.
################################################################################
IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider

#+ Function provider for the CountrySummary entity set.
#+ Signature MUST match ODataTypes.T_ODataProviderFunc exactly (param names too).
PUBLIC FUNCTION provideCountrySummary(
    entity STRING, query ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataResult
    DEFINE res ODataTypes.T_ODataResult
    DEFINE sqlObj base.SqlHandle
    DEFINE o util.JSONObject
    DEFINE i, cnt INTEGER
    DEFINE sql, countryFilter STRING

    LET res = ODataFunctionProvider.newResult()

    # Honour an eq filter on the Country key (used by client $filter and by the
    # framework's single-entity key lookup). This is where a real provider would
    # also enforce the customer's row-level access control.
    FOR i = 1 TO query.filters.getLength()
        IF query.filters[i].property == "Country"
            AND query.filters[i].operator == "eq" THEN
            LET countryFilter = query.filters[i].value
        END IF
    END FOR

    IF countryFilter IS NULL THEN
        LET sql = "SELECT country, COUNT(*)",
            " FROM customers GROUP BY country ORDER BY country"
    ELSE
        LET sql = "SELECT country, COUNT(*)",
            " FROM customers WHERE country = ?",
            " GROUP BY country ORDER BY country"
    END IF

    TRY
        LET sqlObj = base.SqlHandle.create()
        CALL sqlObj.prepare(sql)
        IF countryFilter IS NOT NULL THEN
            CALL sqlObj.setParameter(1, countryFilter)
        END IF
        CALL sqlObj.open()
        WHILE TRUE
            CALL sqlObj.fetch()
            IF sqlca.sqlcode == NOTFOUND THEN EXIT WHILE END IF
            LET o = util.JSONObject.create()
            CALL o.put("Country", sqlObj.getResultValue(1))
            LET cnt = sqlObj.getResultValue(2)      -- INTEGER -> JSON number
            CALL o.put("CustomerCount", cnt)
            CALL res.rows.put(res.rows.getLength() + 1, o)
        END WHILE
        CALL sqlObj.close()
    CATCH
        RETURN ODataFunctionProvider.errorResult("InternalError",
            SFMT("CountrySummary failed (SQLCODE %1)", sqlca.sqlcode))
    END TRY

    RETURN res
END FUNCTION
