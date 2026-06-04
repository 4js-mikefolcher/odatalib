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

#+ Per-service cap on rows fetched while materialising a single $expand
#+ (default 10000 when not configured).
PUBLIC FUNCTION getExpandMaxRows() RETURNS INTEGER
    IF m_schema.expandMaxRows > 0 THEN
        RETURN m_schema.expandMaxRows
    END IF
    RETURN 10000
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

#+ Resolve a navigation property of an entity by name.
#+ found is FALSE when no such navigation property is declared.
PUBLIC FUNCTION findNavigation(
    entity ODataTypes.T_ODataEntity, navName STRING)
    RETURNS (ODataTypes.T_ODataNavigation, BOOLEAN)
    DEFINE i INTEGER
    DEFINE empty ODataTypes.T_ODataNavigation
    FOR i = 1 TO entity.navigation.getLength()
        IF entity.navigation[i].name == navName THEN
            RETURN entity.navigation[i].*, TRUE
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
# Key resolution (single or composite)
# ---------------------------------------------------------------------------

#+ The ordered list of key property names for an entity: every property flagged
#+ isKey (composite keys keep declaration order), or the single `keyName`
#+ shorthand when no property carries the flag. Empty when the entity has no key.
PUBLIC FUNCTION keyProperties(entity ODataTypes.T_ODataEntity)
    RETURNS DYNAMIC ARRAY OF STRING
    DEFINE out DYNAMIC ARRAY OF STRING
    DEFINE i INTEGER
    FOR i = 1 TO entity.properties.getLength()
        IF entity.properties[i].isKey THEN
            LET out[out.getLength() + 1] = entity.properties[i].name
        END IF
    END FOR
    IF out.getLength() == 0
        AND entity.keyName IS NOT NULL AND entity.keyName.getLength() > 0 THEN
        LET out[1] = entity.keyName
    END IF
    RETURN out
END FUNCTION

#+ TRUE when propName is one of the entity's key properties.
PUBLIC FUNCTION isKeyProperty(
    entity ODataTypes.T_ODataEntity, propName STRING) RETURNS BOOLEAN
    DEFINE kp DYNAMIC ARRAY OF STRING
    DEFINE i INTEGER
    LET kp = keyProperties(entity)
    FOR i = 1 TO kp.getLength()
        IF kp[i] == propName THEN
            RETURN TRUE
        END IF
    END FOR
    RETURN FALSE
END FUNCTION

#+ Turn a parsed key predicate into eq filters AND-ed over the key properties.
#+ Validates arity and names so a malformed key is a clean 400. The unnamed form
#+ (name == "") is only valid for a single-key entity. Returns (filters, ok, err).
PUBLIC FUNCTION buildKeyFilters(
    entity ODataTypes.T_ODataEntity,
    keyParts DYNAMIC ARRAY OF ODataTypes.T_ODataKeyPart)
    RETURNS (DYNAMIC ARRAY OF ODataTypes.T_ODataFilter, BOOLEAN, STRING)
    DEFINE filters DYNAMIC ARRAY OF ODataTypes.T_ODataFilter
    DEFINE keyProps DYNAMIC ARRAY OF STRING
    DEFINE i, np INTEGER
    DEFINE pname STRING

    LET keyProps = keyProperties(entity)
    IF keyProps.getLength() == 0 THEN
        RETURN filters, FALSE, SFMT("Entity '%1' has no key", entity.name)
    END IF
    LET np = keyParts.getLength()
    IF np != keyProps.getLength() THEN
        RETURN filters, FALSE,
            SFMT("Key for '%1' needs %2 value(s), got %3",
                entity.name, keyProps.getLength(), np)
    END IF

    FOR i = 1 TO np
        LET pname = keyParts[i].name
        IF pname IS NULL OR pname.getLength() == 0 THEN
            IF keyProps.getLength() != 1 THEN
                RETURN filters, FALSE,
                    SFMT("The composite key of '%1' must name each value",
                        entity.name)
            END IF
            LET pname = keyProps[1]
        ELSE
            IF NOT isKeyProperty(entity, pname) THEN
                RETURN filters, FALSE,
                    SFMT("'%1' is not a key property of '%2'",
                        pname, entity.name)
            END IF
        END IF
        LET filters[i].property = pname
        LET filters[i].operator = "eq"
        LET filters[i].value = keyParts[i].value
        LET filters[i].isNull = FALSE
        IF i < np THEN
            LET filters[i].conjunction = "and"
        ELSE
            LET filters[i].conjunction = ""
        END IF
    END FOR
    RETURN filters, TRUE, NULL
END FUNCTION

#+ Render a key predicate for diagnostics, e.g. "OrderID=10248,ProductID=11" or
#+ the bare value for an unnamed single key.
PUBLIC FUNCTION keyDescription(
    keyParts DYNAMIC ARRAY OF ODataTypes.T_ODataKeyPart) RETURNS STRING
    DEFINE buf base.StringBuffer
    DEFINE i INTEGER
    LET buf = base.StringBuffer.create()
    FOR i = 1 TO keyParts.getLength()
        IF i > 1 THEN CALL buf.append(",") END IF
        IF keyParts[i].name IS NOT NULL AND keyParts[i].name.getLength() > 0 THEN
            CALL buf.append(keyParts[i].name)
            CALL buf.append("=")
        END IF
        CALL buf.append(keyParts[i].value)
    END FOR
    RETURN buf.toString()
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
