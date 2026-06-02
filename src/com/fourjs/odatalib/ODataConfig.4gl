################################################################################
# ODataConfig.4gl
#
# Loads a .odata JSON configuration file into the in-memory T_ODataSchema and
# exposes lookup accessors used by the service, provider and serializer layers.
#
# The schema is held as module-level state: the host program calls
# loadConfigFromFile() (or loadConfigFromString()) once, before starting the
# web service engine.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes

PRIVATE DEFINE m_schema ODataTypes.T_ODataSchema
PRIVATE DEFINE m_loaded BOOLEAN = FALSE

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

#+ Load and parse a .odata config file. Returns TRUE on success.
PUBLIC FUNCTION loadConfigFromFile(path STRING) RETURNS BOOLEAN
    DEFINE jsonText STRING
    LET jsonText = readWholeFile(path)
    IF jsonText IS NULL OR jsonText.getLength() == 0 THEN
        RETURN FALSE
    END IF
    RETURN loadConfigFromString(jsonText)
END FUNCTION

#+ Parse a .odata config held in a string. Returns TRUE on success.
PUBLIC FUNCTION loadConfigFromString(jsonText STRING) RETURNS BOOLEAN
    TRY
        CALL util.JSON.parse(jsonText, m_schema)
    CATCH
        LET m_loaded = FALSE
        RETURN FALSE
    END TRY
    IF m_schema.service IS NULL OR m_schema.entities.getLength() == 0 THEN
        LET m_loaded = FALSE
        RETURN FALSE
    END IF
    IF m_schema.namespace IS NULL THEN
        LET m_schema.namespace = m_schema.service
    END IF
    LET m_loaded = TRUE
    RETURN TRUE
END FUNCTION

#+ TRUE once a valid configuration has been loaded.
PUBLIC FUNCTION isLoaded() RETURNS BOOLEAN
    RETURN m_loaded
END FUNCTION

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------

PUBLIC FUNCTION getServiceName() RETURNS STRING
    RETURN m_schema.service
END FUNCTION

PUBLIC FUNCTION getNamespace() RETURNS STRING
    RETURN m_schema.namespace
END FUNCTION

PUBLIC FUNCTION getEntityCount() RETURNS INTEGER
    RETURN m_schema.entities.getLength()
END FUNCTION

#+ Return the entity set at index (1-based). Caller must stay within range.
PUBLIC FUNCTION getEntityAt(idx INTEGER) RETURNS ODataTypes.T_ODataEntity
    RETURN m_schema.entities[idx]
END FUNCTION

#+ Look up an entity set by its (case-sensitive) name.
#+ found is FALSE when the name is not declared.
PUBLIC FUNCTION findEntity(entitySet STRING)
    RETURNS (ODataTypes.T_ODataEntity, BOOLEAN)
    DEFINE i INTEGER
    DEFINE empty ODataTypes.T_ODataEntity
    FOR i = 1 TO m_schema.entities.getLength()
        IF m_schema.entities[i].name == entitySet THEN
            RETURN m_schema.entities[i].*, TRUE
        END IF
    END FOR
    RETURN empty.*, FALSE
END FUNCTION

#+ Resolve a property of an entity by OData name.
#+ found is FALSE when the property is not declared.
PUBLIC FUNCTION findProperty(
    entity ODataTypes.T_ODataEntity, propName STRING)
    RETURNS (ODataTypes.T_ODataProperty, BOOLEAN)
    DEFINE i INTEGER
    DEFINE empty ODataTypes.T_ODataProperty
    FOR i = 1 TO entity.properties.getLength()
        IF entity.properties[i].name == propName THEN
            RETURN entity.properties[i].*, TRUE
        END IF
    END FOR
    RETURN empty.*, FALSE
END FUNCTION

#+ Map an OData property name to its backing DB column for SQL providers.
#+ Falls back to the property name itself when no column override is set.
PUBLIC FUNCTION columnFor(
    entity ODataTypes.T_ODataEntity, propName STRING) RETURNS STRING
    DEFINE prop ODataTypes.T_ODataProperty
    DEFINE found BOOLEAN
    CALL findProperty(entity, propName) RETURNING prop.*, found
    IF NOT found THEN
        RETURN NULL
    END IF
    IF prop.column IS NULL OR prop.column.getLength() == 0 THEN
        RETURN prop.name
    END IF
    RETURN prop.column
END FUNCTION

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

PRIVATE FUNCTION readWholeFile(path STRING) RETURNS STRING
    DEFINE ch base.Channel
    DEFINE buf base.StringBuffer
    DEFINE line STRING
    DEFINE first BOOLEAN = TRUE
    TRY
        LET ch = base.Channel.create()
        CALL ch.openFile(path, "r")
    CATCH
        RETURN NULL
    END TRY
    LET buf = base.StringBuffer.create()
    LET line = ch.readLine()
    WHILE line IS NOT NULL
        IF NOT first THEN
            CALL buf.append("\n")
        END IF
        CALL buf.append(line)
        LET first = FALSE
        LET line = ch.readLine()
    END WHILE
    CALL ch.close()
    RETURN buf.toString()
END FUNCTION
