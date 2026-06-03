# odatalib — Genero OData v4 Framework

A Genero BDL library, distributed via [fglpkg](https://github.com/4js-mikefolcher/fglpkg),
that exposes **read-only OData v4** services over the GAS REST web-services
engine. Customers declare their entity sets in a `.odata` config file and the
framework handles request parsing, query translation, paging, and OData-shaped
JSON / CSDL responses. Any OData-capable BI tool (Power BI, Tableau, Excel,
Metabase, …) can then consume the data with zero client-side code.

> **Status: v0 vertical slice.** This is the first increment of the framework
> described in [`specs/genero-odata-framework-spec.md`](specs/genero-odata-framework-spec.md).
> It proves the architecture end to end with a working SQL-backed provider. See
> [Limitations & roadmap](#limitations--roadmap) for what is intentionally not
> yet implemented.

---

## Architecture

```
  BI tool            GAS REST           odatalib (this package)        DB / BDL
 ┌─────────┐  OData  ┌─────────┐  call  ┌───────────────────────┐  SQL ┌───────┐
 │ Power BI│ ──────► │ Web Svc │ ─────► │ ODataService (routes)  │ ───► │  rows │
 │  Tableau│ ◄────── │ Engine  │ ◄───── │ Query→Provider→Serial. │ ◄─── │       │
 └─────────┘  JSON   └─────────┘        └───────────────────────┘      └───────┘
```

### Modules (`com/fourjs/odatalib`)

| Module | Responsibility |
|---|---|
| `ODataTypes` | Shared TYPEs: schema model, parsed-query model, provider result |
| `ODataConfig` | Loads the `.odata` JSON config; entity/property lookup accessors |
| `ODataQuery` | Parses `$filter`, `$select`, `$top`, `$skip`, `$orderby`, `$count`, `$expand` into a normalised query |
| `ODataProvider` | Provider dispatch (`sql` \| `function`) → uniform `T_ODataResult` |
| `ODataSqlProvider` | SQL/table-backed provider: builds parameterised SQL via `base.SqlHandle`, DB-agnostic scroll-cursor paging |
| `ODataFunctionProvider` | Function-backed provider: registry of customer callbacks (function references); the customer's BDL applies business logic + access control |
| `ODataSerializer` | OData JSON envelopes (`@odata.context`/`count`/`nextLink`) + CSDL `$metadata` XML + service document |
| `ODataError` | OData error envelope `{ "error": { "code", "message" } }` + HTTP status via `SetRestError` |
| `ODataAuth` | Pluggable per-request authorization hook + built-in scope authorizer |
| `ODataService` | The GAS REST endpoints, service registration, and the `ProcessServices` loop |

### Endpoints (relative to the GAS service base URL)

| Method | Path | Result |
|---|---|---|
| `GET` | `/` | Service document (entity-set listing) |
| `GET` | `/$metadata` | CSDL metadata (XML) |
| `GET` | `/{EntitySet}` | Entity collection (+ `$`-query options) |
| `GET` | `/{EntitySet}(key)` | Single entity by key, e.g. `/Customers('ALFKI')` or `/Orders(10248)` |

The collection and single-entity routes share one GAS template — `Customers`
and `Customers('ALFKI')` are both single OData path segments, so the service
inspects the captured segment for a `(key)` suffix. (GAS REST cannot express a
`/{set}({key})` template directly; this is why the two are unified.)

### Supported OData v4 query surface (v0)

- `$filter` — `eq ne gt lt ge le`, and `contains` / `startswith` / `endswith`,
  combined with `and` / `or` / `not` and parenthesised grouping, with correct
  `not` > `and` > `or` precedence; `eq null` / `ne null` map to SQL `IS NULL` /
  `IS NOT NULL`
- `$select` — property projection
- `$top`, `$skip` — pagination
- `$orderby` — multi-term, `asc` / `desc`
- `$count=true` — total count via `@odata.count`
- Server-driven paging — `@odata.nextLink`, default page size 200, cap 1000
  (per-entity `pageSize`)
- `$expand` — captured but not yet materialised

Malformed options return a `400 BadRequest`; unsupported-but-recognised
constructs return `501 NotImplemented`; both as OData error envelopes.

---

## The `.odata` configuration file

A single JSON document declaring the service, its CSDL namespace, and its
entity sets. Each entity binds to a provider and lists the properties it
exposes (with OData `Edm.*` types and the backing DB column for SQL providers).

```json
{
  "service": "northwind",
  "namespace": "Northwind",
  "entities": [
    {
      "name": "Customers",          // entity set name (URL segment)
      "entityType": "Customer",     // CSDL entity type name
      "provider": "sql",            // "sql" | "function"
      "source": "customers",        // table/view (sql) or function id (function)
      "key": "CustomerID",          // key property name
      "pageSize": 50,               // server page size (optional; default 200, cap 1000)
      "properties": [
        { "name": "CustomerID",  "column": "customer_id",  "type": "Edm.String", "key": true },
        { "name": "CompanyName", "column": "company_name", "type": "Edm.String" },
        { "name": "Country",     "column": "country",      "type": "Edm.String" }
      ]
    }
  ]
}
```

Notes:
- JSON keys map onto BDL records via `json_name` — `type` → `edmType`,
  `key` → `isKey`/`keyName`.
- For SQL providers, only declared properties are ever selected (never
  `SELECT *`), and JSON keys come from the config property names by SELECT
  position, so the wire shape is stable across database engines.

---

## Hybrid pluggable providers

An entity declares `provider`:

- **`sql`** — backed by a table or view. The framework translates the OData
  query into parameterised SQL.
- **`function`** — backed by a customer-authored BDL callback that applies
  business logic + access control and returns rows, honouring the spec's
  *"BDL is the gatekeeper"* invariant. This is how BDL-processed data (joins,
  derived fields, aggregates) — not raw database rows — is exposed.

### Authoring a function provider

The callback is registered with the framework via a **function reference**, so
the library never has to import customer code and SQL-only apps carry no cost.

1. Declare the entity with `"provider": "function"` in the `.odata` file (the
   `source` and per-property `column` are not used for function entities).

2. Write a callback whose signature matches `ODataTypes.T_ODataProviderFunc`
   **exactly — including parameter names** (`entity`, `query`), because Genero
   function-reference types are name-sensitive:

   ```4gl
   PUBLIC FUNCTION provideCountrySummary(
       entity STRING, query ODataTypes.T_ODataQuery)
       RETURNS ODataTypes.T_ODataResult
       DEFINE res ODataTypes.T_ODataResult
       LET res = ODataFunctionProvider.newResult()   -- ok=TRUE, empty rows
       -- ... run BDL business logic + access control, fill res.rows ...
       RETURN res                                     -- or errorResult(code,msg)
   END FUNCTION
   ```

   The callback returns the matching rows in `res.rows`; the framework then
   applies `$top`/`$skip` paging, `$count` and `@odata.nextLink` over them, so a
   simple provider can ignore paging. A provider that wants efficient paging or
   access control can inspect `query.filters` / `query.top` / `query.skip`.

3. Register the reference at startup, before serving:

   ```4gl
   CALL ODataFunctionProvider.register(
       "CountrySummary", FUNCTION MyModule.provideCountrySummary)
   ```

See [`examples/NorthwindFunctions.4gl`](examples/NorthwindFunctions.4gl) for a
working `CountrySummary` provider that aggregates customers by country.

---

## Authorization

GAS **authenticates** the caller (HTTP Basic / OIDC / etc., configured on the
GAS side); the framework **authorizes** each request. Because the endpoints are
generic (one operation serves every entity), authorization is a runtime hook
rather than a static per-operation `WSScope`: it receives the target entity, the
operation (`read` in v0), and a principal, and returns allow/deny.

Identity reaches the BDL service via:
- the **`Authorization`** header (bearer token) — always forwarded by GAS;
- the **`X-OData-Scopes`** / **`X-OData-User`** headers — declared as `WSHeader`
  params on the service so GAS forwards them (custom headers are otherwise
  stripped); or
- the GAS-granted **`Scope`** request-context entry after token validation.

**Custom authorizer** (full control):

```4gl
PUBLIC FUNCTION authorize(auth ODataTypes.T_ODataAuthContext)
    RETURNS ODataTypes.T_ODataAuthResult
    IF auth.entity == "CountrySummary" THEN RETURN ODataAuth.allow() END IF
    IF ODataAuth.scopeContains(auth.scope, SFMT("%1.%2", auth.entity, auth.operation)) THEN
        RETURN ODataAuth.allow()
    END IF
    RETURN ODataAuth.deny(403, "Forbidden")
END FUNCTION
-- register at startup:
CALL ODataAuth.setAuthorizer(FUNCTION MyModule.authorize)
```

**Built-in scope authorizer** (convention over configuration) — requires scope
`"<entity>.<operation>"` (configurable prefix/separator):

```4gl
CALL ODataAuth.configureScopes("", ".")   -- e.g. "Customers.read"
CALL ODataAuth.useScopeAuthorizer()
```

If no authorizer is registered the service is **open**. The hook gates entity
data (collections + key lookups); `$metadata` and the service document are not
gated by it (use a module-level `WSScope` / GAS config to restrict those).

Verified live on GAS (with [`examples/NorthwindAuth.4gl`](examples/NorthwindAuth.4gl)):

```
GET /Customers                                   -> 401 (no credentials)
GET /Customers  -H 'X-OData-Scopes: Customers.read'  -> 200
GET /Customers  -H 'X-OData-Scopes: Orders.read'     -> 403
GET /CountrySummary                              -> 200 (public per policy)
```

## Building & installing

The library compiles against Genero 6.x (developed with `fglcomp 6.00.01`).

```bash
# Set the library on the module path
export FGLLDPATH="$PWD/src:$FGLLDPATH"

# Compile the library modules (dependency order)
cd src
for m in ODataTypes ODataConfig ODataError ODataAuth ODataSqlProvider \
         ODataFunctionProvider ODataProvider ODataSerializer ODataService; do
  fglcomp -M -Wall com/fourjs/odatalib/$m.4gl
done
```

Distributed as an fglpkg package (`fglpkg.json`, root `com/fourjs/odatalib`):

```bash
fglpkg publish          # publish the library
fglpkg install odatalib # consume it in an application
```

## Running the example

A small in-memory (SQLite) Northwind sample lives in `examples/`.

```bash
export FGLLDPATH="$PWD/src:$PWD/examples:$FGLLDPATH"
cd examples
fglcomp -M NorthwindCreate.4gl NorthwindFunctions.4gl NorthwindAuth.4gl \
           SmokeTest.4gl NorthwindService.4gl

# 1) Smoke test — exercises config → parse → provider → serializer WITHOUT GAS
FGLGUI=0 fglrun SmokeTest

# 2) Real service — register with GAS and serve OData over REST
fglrun NorthwindService    # then deploy/route via GAS as a REST service
```

`SmokeTest` prints the `$metadata` document, service document, several filtered
/ ordered / counted / paged collections, a key lookup, and the error responses
— a full end-to-end validation of the framework logic.

### Against a real PostgreSQL Northwind

For a richer, strictly-typed dataset (the full 14-table Northwind, with numeric,
`real` and `date` columns), point the example at a PostgreSQL `northwind`
database. `examples/fglprofile` maps the `northwind` connection name to the
`dbmpgs` driver, and `examples/northwind-pg.odata` declares the larger schema
(Customers, Orders, Products, Categories, Suppliers + the CountrySummary
function provider) with the real Postgres column names and `Edm.*` types.

```bash
export FGLLDPATH="$PWD/src:$PWD/examples:$FGLLDPATH"
export FGLPROFILE="$PWD/examples/fglprofile"      # northwind -> dbmpgs @ localhost:5432
cd examples
fglcomp -M NorthwindFunctions.4gl PgSmokeTest.4gl
FGLGUI=0 fglrun PgSmokeTest                       # connects as nwuser
```

`PgSmokeTest` exercises the type-aware paths SQLite's loose typing hides:
integer / `real` / `date` `$filter`s, an integer key lookup, and `Edm.Date`
serialisation. This is the dataset used to verify the type-aware binding and
`LIKE`-escaping fixes noted under [Limitations & roadmap](#limitations--roadmap).

## Consuming from Power BI

Power BI Desktop → **Get Data → OData feed** → enter the service URL
(`…/odata/northwind`) → authenticate (HTTP Basic over HTTPS for v0) → the
declared entity sets appear in the query builder. Use **Import** mode and
periodic refresh (the recommended pattern for OData BI).

---

## GAS deployment & verification status

Verified end-to-end on **GAS 6.00.01** (standalone `httpdispatch`) with
[`examples/resources/northwind.xcf`](examples/resources/northwind.xcf). Confirmed live:

- Routing precedence — literal `/$metadata` and `/` win over `/{entitySet}` ✅
- Single-segment key parse — `Customers('ALFKI')` / `CountrySummary('Germany')` ✅
- `$`-prefixed options — `$top`/`$skip`/`$count`/`$filter` (incl. `contains`)/`$orderby`/`$select` ✅
- Both providers (SQL + function) over HTTP ✅
- OData error envelopes with correct HTTP status (400/404) ✅

To run it yourself:

```bash
export FGLASDIR="…/Genero Studio …/Contents/Resources/gas"
"$FGLASDIR/bin/httpdispatch" -p "$FGLASDIR" \
  -E res.appdata.path=/tmp/odata-gas \
  -E res.path.services=$PWD/examples/resources
curl 'http://localhost:6394/ws/r/northwind/northwind/Customers?$top=10&$count=true'
```

**Note on `$metadata` content type:** GAS streams the CSDL document (via
`WSAttachment`, so it is sent raw rather than XML-serialised into an `<rv0>`
wrapper) with `Content-Type: text/xml`, derived from the file extension.
`text/xml` is a valid XML media type (RFC 7303) accepted by OData clients
including Power BI; the body is well-formed CSDL.

## Limitations & roadmap

**Not yet implemented (v0 scope):**
- `$expand` materialisation, `$batch`, `$apply`, lambda operators (`any`/`all`),
  delta/change-tracking, actions/functions
- Write operations (POST/PATCH/PUT/DELETE) — read-only by design
- OAuth2 (v1); v0 targets HTTP Basic + BDL access-control gating via `WSScope`

**Known v0 caveats:**
- `@odata.nextLink` percent-encodes the common OData filter charset; a full
  RFC 3986 encoder is a follow-up.

**Recently closed (verified against PostgreSQL Northwind):**
- *Type-aware filter binding.* `$filter` and key-predicate values are now bound
  with the program-variable type implied by the property's `Edm.*` type
  (`Edm.Int16/32/64`, `Edm.Single/Double/Decimal`, `Edm.Date`), so numeric and
  date comparisons — and integer key lookups like `Orders(10248)` — work on
  strict engines. Previously every value was bound as a string, which Postgres
  rejected with *"operator does not exist: real > character varying"*. A literal
  that does not match its column type is now a clean `400`, not a `500`.
- *`LIKE` wildcard escaping.* `contains`/`startswith`/`endswith` values are
  escaped (`%`, `_`, `\`) and matched with an `ESCAPE '\'` clause, so user input
  is matched literally instead of acting as SQL wildcards.
- *`Edm.Single` precision.* 4-byte-float columns are re-narrowed to single
  precision on serialisation, so a stored `32.38` emits as `32.38`, not
  `32.380001…` (the float4→float8 widening the driver returns). `Edm.Double`
  keeps full precision; `Edm.Decimal` is exact and unaffected.
- *Null literal in `$filter`.* `eq null` / `ne null` now translate to SQL
  `IS NULL` / `IS NOT NULL` (the bare `null` keyword is distinguished from the
  quoted text value `'null'`). Relational operators against `null` (`gt`/`lt`/…)
  return a clean `400`.
- *Parenthesised / `not` `$filter`.* `$filter` is now parsed into an expression
  tree by a recursive-descent parser, so grouping with parentheses, the `not`
  operator, and correct `not` > `and` > `or` precedence are all supported (e.g.
  `(Country eq 'Germany' or Country eq 'France') and not contains(City,'a')`).
  Unbalanced parentheses return a clean `400`.
