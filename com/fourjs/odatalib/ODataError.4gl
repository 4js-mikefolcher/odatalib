################################################################################
# ODataError.4gl
#
# Emits OData v4 compliant error responses. The OData error envelope is:
#
#     { "error": { "code": "<code>", "message": "<text>" } }
#
# We model that shape with a WSError record whose single member `error` is a
# sub-record, so com.WebServiceEngine.SetRestError() serialises exactly the
# nested object OData clients expect, while also setting the HTTP status code.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT com

# Module-level WSError record reused for every error response.
PUBLIC DEFINE odataErrorBody RECORD ATTRIBUTES(WSError = "error")
    error RECORD
        code STRING,
        message STRING
    END RECORD
END RECORD

#+ Map a framework error code to the matching HTTP status.
PUBLIC FUNCTION httpStatusFor(code STRING) RETURNS INTEGER
    CASE code
        WHEN "BadRequest"     RETURN 400
        WHEN "Unauthorized"   RETURN 401
        WHEN "Forbidden"      RETURN 403
        WHEN "NotFound"       RETURN 404
        WHEN "NotImplemented" RETURN 501
        OTHERWISE             RETURN 500
    END CASE
END FUNCTION

#+ Raise an OData error with an explicit HTTP status. Execution continues after
#+ this call (SetRestError does not return) — callers must RETURN immediately.
PUBLIC FUNCTION raise(httpStatus INTEGER, code STRING, message STRING)
    LET odataErrorBody.error.code = code
    LET odataErrorBody.error.message = message
    CALL com.WebServiceEngine.SetRestError(httpStatus, odataErrorBody)
END FUNCTION

#+ Raise an OData error, deriving the HTTP status from the framework code.
PUBLIC FUNCTION raiseCode(code STRING, message STRING)
    CALL raise(httpStatusFor(code), code, message)
END FUNCTION
