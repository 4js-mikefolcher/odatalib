################################################################################
# ODataSerializer.4gl
#
# Builds the OData v4 wire artefacts:
#   * the service document (entity-set listing)
#   * the CSDL $metadata XML document
#   * the entity-collection JSON envelope (@odata.context / count / nextLink)
#   * the single-entity JSON envelope
#
# Metadata and the service document are derived from the loaded ODataConfig;
# the envelopes wrap a provider's T_ODataResult.
################################################################################
PACKAGE com.fourjs.odatalib

IMPORT util
IMPORT FGL com.fourjs.odatalib.ODataTypes
IMPORT FGL com.fourjs.odatalib.ODataConfig

CONSTANT EDMX_NS = "http://docs.oasis-open.org/odata/ns/edmx"
CONSTANT EDM_NS = "http://docs.oasis-open.org/odata/ns/edm"

# ---------------------------------------------------------------------------
# Service document
# ---------------------------------------------------------------------------
PUBLIC FUNCTION buildServiceDocument(baseUrl STRING) RETURNS util.JSONObject
    DEFINE root, item util.JSONObject
    DEFINE arr util.JSONArray
    DEFINE i INTEGER
    DEFINE ent ODataTypes.T_ODataEntity

    LET root = util.JSONObject.create()
    CALL root.put("@odata.context", SFMT("%1/$metadata", baseUrl))
    LET arr = util.JSONArray.create()
    FOR i = 1 TO ODataConfig.getEntityCount()
        LET ent = ODataConfig.getEntityAt(i)
        LET item = util.JSONObject.create()
        CALL item.put("name", ent.name)
        CALL item.put("kind", "EntitySet")
        CALL item.put("url", ent.name)
        CALL arr.put(arr.getLength() + 1, item)
    END FOR
    CALL root.put("value", arr)
    RETURN root
END FUNCTION

# ---------------------------------------------------------------------------
# CSDL $metadata document
# ---------------------------------------------------------------------------
PUBLIC FUNCTION buildMetadata() RETURNS STRING
    DEFINE buf base.StringBuffer
    DEFINE i, j INTEGER
    DEFINE ent ODataTypes.T_ODataEntity
    DEFINE prop ODataTypes.T_ODataProperty
    DEFINE keyProps DYNAMIC ARRAY OF STRING
    DEFINE ns, nullable STRING

    LET ns = ODataConfig.getNamespace()
    LET buf = base.StringBuffer.create()
    CALL buf.append('<?xml version="1.0" encoding="UTF-8"?>\n')
    CALL buf.append(SFMT('<edmx:Edmx Version="4.0" xmlns:edmx="%1">\n', EDMX_NS))
    CALL buf.append(" <edmx:DataServices>\n")
    CALL buf.append(SFMT('  <Schema Namespace="%1" xmlns="%2">\n', ns, EDM_NS))

    # Entity types
    FOR i = 1 TO ODataConfig.getEntityCount()
        LET ent = ODataConfig.getEntityAt(i)
        CALL buf.append(SFMT('   <EntityType Name="%1">\n', ent.entityType))
        # <Key> lists every key property (one <PropertyRef> per part of a
        # composite key), in declaration order.
        LET keyProps = ODataConfig.keyProperties(ent)
        IF keyProps.getLength() > 0 THEN
            CALL buf.append("    <Key>\n")
            FOR j = 1 TO keyProps.getLength()
                CALL buf.append(
                    SFMT('     <PropertyRef Name="%1"/>\n', keyProps[j]))
            END FOR
            CALL buf.append("    </Key>\n")
        END IF
        FOR j = 1 TO ent.properties.getLength()
            LET prop = ent.properties[j]
            IF ODataConfig.isKeyProperty(ent, prop.name) THEN
                LET nullable = "false"
            ELSE
                LET nullable = "true"
            END IF
            CALL buf.append(SFMT('    <Property Name="%1" Type="%2" Nullable="%3"/>\n',
                prop.name, edmTypeOrDefault(prop.edmType), nullable))
        END FOR
        CALL buf.append("   </EntityType>\n")
    END FOR

    # Entity container
    CALL buf.append('   <EntityContainer Name="Container">\n')
    FOR i = 1 TO ODataConfig.getEntityCount()
        LET ent = ODataConfig.getEntityAt(i)
        CALL buf.append(SFMT('    <EntitySet Name="%1" EntityType="%2.%3"/>\n',
            ent.name, ns, ent.entityType))
    END FOR
    CALL buf.append("   </EntityContainer>\n")

    CALL buf.append("  </Schema>\n")
    CALL buf.append(" </edmx:DataServices>\n")
    CALL buf.append("</edmx:Edmx>\n")
    RETURN buf.toString()
END FUNCTION

PRIVATE FUNCTION edmTypeOrDefault(t STRING) RETURNS STRING
    IF t IS NULL OR t.getLength() == 0 THEN
        RETURN "Edm.String"
    END IF
    RETURN t
END FUNCTION

# ---------------------------------------------------------------------------
# Entity-collection envelope
# ---------------------------------------------------------------------------
#+ Wrap a collection result. nextLink is included only when result.hasMore is
#+ TRUE and a non-NULL nextLink was supplied by the service layer.
PUBLIC FUNCTION buildCollection(
    baseUrl STRING,
    entitySet STRING,
    result ODataTypes.T_ODataResult,
    wantCount BOOLEAN,
    nextLink STRING)
    RETURNS util.JSONObject
    DEFINE root util.JSONObject

    LET root = util.JSONObject.create()
    CALL root.put("@odata.context", SFMT("%1/$metadata#%2", baseUrl, entitySet))
    IF wantCount THEN
        CALL root.put("@odata.count", result.count)
    END IF
    CALL root.put("value", result.rows)
    IF result.hasMore AND nextLink IS NOT NULL THEN
        CALL root.put("@odata.nextLink", nextLink)
    END IF
    RETURN root
END FUNCTION

# ---------------------------------------------------------------------------
# Single-entity envelope
# ---------------------------------------------------------------------------
#+ Decorate the first row of a result with the entity @odata.context. Returns
#+ NULL when the result carries no row.
PUBLIC FUNCTION buildEntity(
    baseUrl STRING, entitySet STRING, result ODataTypes.T_ODataResult)
    RETURNS util.JSONObject
    DEFINE row util.JSONObject

    IF result.rows IS NULL OR result.rows.getLength() == 0 THEN
        RETURN NULL
    END IF
    LET row = result.rows.get(1)
    CALL row.put("@odata.context",
        SFMT("%1/$metadata#%2/$entity", baseUrl, entitySet))
    RETURN row
END FUNCTION
