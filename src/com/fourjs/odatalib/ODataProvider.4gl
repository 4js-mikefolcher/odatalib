################################################################################
# ODataProvider.4gl
#
# Provider dispatch layer. An entity set declares provider = "sql" | "function"
# in its .odata config; this module routes a parsed query to the matching
# provider implementation and returns a uniform T_ODataResult.
#
# Providers:
#   * "sql"      -> ODataSqlProvider: table / view backed, framework builds SQL.
#   * "function" -> ODataFunctionProvider: a customer-registered BDL callback
#                   (function reference) applies business logic + access control
#                   and returns rows; the framework handles OData paging/count.
#                   The registry is empty unless an app registers callbacks, so
#                   SQL-only applications incur no cost from this import.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataSqlProvider
IMPORT FGL com.fourjs.odatalib.ODataFunctionProvider

#+ Fetch a page of rows for an entity set using its configured provider.
PUBLIC FUNCTION fetch(
    entity ODataTypes.T_ODataEntity, query ODataTypes.T_ODataQuery)
    RETURNS ODataTypes.T_ODataResult
    DEFINE res ODataTypes.T_ODataResult

    CASE entity.provider
        WHEN "sql"
            RETURN ODataSqlProvider.fetch(entity, query)
        WHEN "function"
            RETURN ODataFunctionProvider.fetch(entity, query)
        OTHERWISE
            LET res.ok = FALSE
            LET res.errorCode = "InternalError"
            LET res.errorMessage =
                SFMT("Unknown provider '%1' for entity '%2'",
                    entity.provider, entity.name)
            RETURN res
    END CASE
END FUNCTION

#+ Fetch a single entity by key using its configured provider.
PUBLIC FUNCTION fetchByKey(
    entity ODataTypes.T_ODataEntity, keyValue STRING)
    RETURNS ODataTypes.T_ODataResult
    DEFINE res ODataTypes.T_ODataResult

    CASE entity.provider
        WHEN "sql"
            RETURN ODataSqlProvider.fetchByKey(entity, keyValue)
        WHEN "function"
            RETURN ODataFunctionProvider.fetchByKey(entity, keyValue)
        OTHERWISE
            LET res.ok = FALSE
            LET res.errorCode = "InternalError"
            LET res.errorMessage =
                SFMT("Unknown provider '%1' for entity '%2'",
                    entity.provider, entity.name)
            RETURN res
    END CASE
END FUNCTION
