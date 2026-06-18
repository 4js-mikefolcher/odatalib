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
| `GET` | `/{EntitySet}(key)` | Single entity by key — single `/Customers('ALFKI')`, `/Orders(10248)`, `/Products(ProductID=11)`, or composite `/OrderDetails(OrderID=10248,ProductID=11)` |

The collection and single-entity routes share one GAS template — `Customers`
and `Customers('ALFKI')` are both single OData path segments, so the service
inspects the captured segment for a `(key)` suffix. (GAS REST cannot express a
`/{set}({key})` template directly; this is why the two are unified.)

### Supported OData v4 query surface (v0)

- `$filter` — `eq ne gt lt ge le`, `in (…)`, and `contains` / `startswith` /
  `endswith`, combined with `and` / `or` / `not` and parenthesised grouping, with
  correct `not` > `and` > `or` precedence; `eq null` / `ne null` map to SQL
  `IS NULL` / `IS NOT NULL`. Lambda operators on collection navigation properties:
  `nav/any(v: P)`, `nav/all(v: P)`, and `nav/any()` (existence) — compiled to a
  correlated `EXISTS` / `NOT EXISTS` subquery (SQL providers; single-pair joins).
  Value functions on the compared property: `tolower`, `toupper`, `trim`,
  `length`, `round` (the portable set; date-part / `floor` / `ceiling` / multi-arg
  / arithmetic return `501`)
- `$count` path — `GET /{set}/$count` returns the bare match count as `text/plain`
  (honours `$filter`)
- Navigation traversal — `GET /{set}({key})/{navProp}` returns the related set
  (to-many → collection, to-one → single entity), with the full query-option set
  applied to the related result
- `$select` — property projection
- `$top`, `$skip` — pagination
- `$orderby` — multi-term, `asc` / `desc`
- `$count=true` — total count via `@odata.count`
- Server-driven paging — `@odata.nextLink`, default page size 200, cap 1000
  (per-entity `pageSize`)
- `$expand` — to-one and to-many navigation properties, backed by declared
  relationships (see [The `.odata` configuration file](#the-odata-configuration-file))
  and materialised with one batched query per expanded property (no N+1).
  Supports:
  - **Nested options** inside an expand item: `$select`, `$filter`, `$orderby`,
    `$top`, `$skip`, `$count` — e.g.
    `Orders($filter=Freight gt 50;$orderby=OrderDate desc;$top=3;$count=true)`.
    `$top`/`$skip` apply **per parent**; `$count` emits `"<nav>@odata.count"`.
  - **Multi-level** expand — `$expand=Orders($expand=OrderDetails($expand=Product))`,
    bounded by the per-service `expandMaxDepth` (default 3).

  `$expand=*`, `$compute`/`$search`/`$apply`/`$levels`/lambda inside a nested
  option, and composite-column joins return `501`.
- `$apply` — server-side aggregation (SQL providers): `aggregate(…)` for grand
  totals and `groupby((dims)[, aggregate(…)])` for grouped rows, with an optional
  leading `filter(<pred>)` pre-aggregation segment. Methods: `sum`, `average`,
  `min`, `max`, `countdistinct`, and `$count as <alias>`. `$orderby`/`$top`/
  `$skip`/`$count` apply to the aggregated result. Example:
  `Orders?$apply=filter(Freight gt 50)/groupby((ShipCountry),aggregate($count as N))`
- `$batch` — JSON batch (OData v4.01): `POST /$batch` with
  `{"requests":[{"id","method":"GET","url"}, …]}` runs a bundle of independent
  `GET`s and returns `{"responses":[{"id","status","body"}, …]}`. Each sub-request
  is routed through the same logic as a direct `GET` (all query options work
  inside a sub-URL), authorised with the batch request's own headers, and
  **continue-on-error** (a failing sub-request is isolated; the batch returns
  `200`). Read-only: a non-`GET` sub-request → `405`, `$metadata` in a batch →
  `501`; only `application/json` is accepted (multipart/mixed is rejected).

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
- **Keys** can be single or composite. The entity-level `"key"` is a shorthand
  for a single key; alternatively (and required for composite keys) flag each key
  property with `"key": true`. A composite key is addressed with the named form
  `OrderDetails(OrderID=10248,ProductID=11)`; a single key accepts either the
  unnamed (`Products(11)`) or named (`Products(ProductID=11)`) form.
- **Relationships** for `$expand` are declared per entity in an optional
  `navigation` array, each entry naming the target entity set, the cardinality
  (`"kind": "one"` | `"many"`) and the join key pair(s):
  ```json
  "navigation": [
    { "name": "Customer",     "target": "Customers",    "kind": "one",
      "on": [{ "from": "CustomerID", "to": "CustomerID" }] },
    { "name": "OrderDetails", "target": "OrderDetails",  "kind": "many",
      "on": [{ "from": "OrderID", "to": "OrderID" }] }
  ]
  ```
  `from` is a property on this entity, `to` a property on the target. The
  service-level `"expandMaxRows"` (default 10000) caps the rows fetched per
  expansion.
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

### Securing the service (read before exposing publicly)

The service is **open by default** — if you never register an authorizer, every
request is allowed. `ODataService.register()` emits a one-time startup **warning**
to the DVM log in that case (`WARNING [odatalib]: no authorizer registered …`).
Before any public deployment, work through this checklist:

1. **Register an authorizer** (`ODataAuth.setAuthorizer` or `useScopeAuthorizer`)
   and confirm the startup warning is gone. The hook gates entity data; restrict
   `$metadata` / the service document at the GAS layer if they must be private.
2. **Serve over HTTPS only.** HTTP Basic and bearer tokens are sent in headers;
   terminate TLS at GAS or a fronting proxy and disable plain HTTP.
3. **Keep the cost guards sane** for your data volumes — per-entity `pageSize`
   (server cap 1000), `expandMaxRows` (default 10000), `expandMaxDepth`
   (default 3). These bound a single request's fan-out; lower them for large
   tables / untrusted callers.
4. **Set GAS timeouts** (`GWS_CONNECTTIMEOUT` / `GWS_RWTIMEOUT` /
   `GWS_SERVERTIMEOUT`, as in the example `.xcf`) so a slow/expensive query can't
   pin a DVM indefinitely.
5. **Least-privilege DB user.** The SQL provider only ever issues `SELECT`s
   against the declared tables/views — grant the connection user nothing more.
6. Values are always **bound as parameters** (never concatenated) and identifiers
   come from the `.odata` config (not the URL), so `$filter`/`$select`/`$orderby`
   are not injection vectors — but the points above are still yours to own.

## Building & installing

The library compiles against Genero 6.x (developed with `fglcomp 6.00.01`).

```bash
# Set the library on the module path (the package root is the project root)
export FGLLDPATH="$PWD:$FGLLDPATH"

# Compile the library modules (dependency order)
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

## Tests

`make test` runs the assert-based regression suite ([`tests/odata_test.4gl`](tests/odata_test.4gl))
against an **in-memory SQLite** database — no external server, just the Genero
toolchain — covering the query pipeline end to end: `$filter` (incl. the value
functions, `in`, `null`, `contains`), `$select`/`$top`/`$skip`/`$orderby`/`$count`,
key lookup, `$expand`, lambda `any`, `$apply`, the function provider, CSDL
metadata, and the error paths. It exits non-zero on any failure.

```bash
make test     # compile the library + run the suite
make clean    # remove .42m
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `make test`;
because the Genero toolchain is licensed and not on GitHub-hosted runners, it
targets a **self-hosted runner** labelled `genero` (FGLDIR set, `fglcomp`/`fglrun`
on `PATH`). The richer PostgreSQL suite, [`examples/PgSmokeTest.4gl`](examples/PgSmokeTest.4gl),
is run manually against a live Northwind database (see its header).

### Cross-engine portability suite

[`tests/portability_test.4gl`](tests/portability_test.4gl) runs the full OData
surface against a **live** database server and has been verified across
**Oracle**, **MariaDB**, and **PostgreSQL** on two schemas — Northwind and
[AdventureWorks](examples/adventureworks.odata). It is driven by environment
variables so one binary covers every (engine, schema) combination:

| Var | Meaning |
|-----|---------|
| `ODATA_TEST_CONFIG` | the `.odata` config to load (e.g. `adventureworks.odata`) |
| `ODATA_DB` | the database name to `CONNECT TO` |
| `ODATA_SCHEMA` | `aw` (AdventureWorks, exact-count asserts) or `nw` (Northwind, relational / known-fact asserts) |

```bash
# AdventureWorks on Oracle (FGLPROFILE selects the engine/driver)
FGLPROFILE=/path/to/fglprofile.ora \
  ODATA_DB=adventureworks ODATA_CONFIG=adventureworks.odata ODATA_SCHEMA=aw \
  make test-portability
```

AdventureWorks data is identical across the three engines, so its checks are
exact counts; Northwind totals differ per engine (and a live copy may be mutated
by an application), so its checks are relational, known-row, and query-equivalence
properties that hold regardless of the row totals. All generated SQL uses
unquoted lowercase identifiers, scroll-cursor paging (no dialect `LIMIT`/`OFFSET`),
and letter-led subquery aliases, so it is portable across these engines.

## Running the example

A small in-memory (SQLite) Northwind sample lives in `examples/`.

```bash
export FGLLDPATH="$PWD:$PWD/examples:$FGLLDPATH"
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
(Customers, Orders, Products, Categories, Suppliers, the composite-key
OrderDetails entity, and the CountrySummary function provider) with the real
Postgres column names and `Edm.*` types.

```bash
export FGLLDPATH="$PWD:$PWD/examples:$FGLLDPATH"
export FGLPROFILE="$PWD/examples/fglprofile"      # northwind -> dbmpgs @ localhost:5432
cd examples
fglcomp -M NorthwindFunctions.4gl PgSmokeTest.4gl
FGLGUI=0 fglrun PgSmokeTest                       # connects as nwuser
```

`PgSmokeTest` exercises the type-aware paths SQLite's loose typing hides:
integer / `real` / `date` `$filter`s, an integer key lookup, and `Edm.Date`
serialisation. This is the dataset used to verify the type-aware binding and
`LIKE`-escaping fixes noted under [Limitations & roadmap](#limitations--roadmap).

To serve this dataset over GAS (e.g. to exercise composite-key URLs live),
`examples/NorthwindPgService.4gl` is the PostgreSQL counterpart of the SQLite
`NorthwindService` — it connects via `FGLPROFILE` and serves `northwind-pg.odata`.
Pair it with a deployment descriptor created from the template under
[GAS deployment](#gas-deployment--verification-status) (the `.xcf` files are
gitignored because they bake in an absolute project path).

## Consuming from Power BI

Power BI Desktop → **Get Data → OData feed** → enter the service URL
(`…/odata/northwind`) → authenticate (HTTP Basic over HTTPS for v0) → the
declared entity sets appear in the query builder. Use **Import** mode and
periodic refresh (the recommended pattern for OData BI).

---

## GAS deployment & verification status

Verified end-to-end on **GAS 6.00.01** (standalone `httpdispatch`). Confirmed live:

- Routing precedence — literal `/$metadata` and `/` win over `/{entitySet}` ✅
- Single-segment key parse — `Customers('ALFKI')` / `CountrySummary('Germany')` ✅
- `$`-prefixed options — `$top`/`$skip`/`$count`/`$filter` (incl. `contains`)/`$orderby`/`$select` ✅
- Combined options in one URL — `$filter`+`$expand`(nested `$select`)+`$orderby`+`$count`+`$top`, against single- and composite-key entities ✅
- Both providers (SQL + function) over HTTP ✅
- OData error envelopes with correct HTTP status (400/404/501) ✅

**Deployment descriptor.** The `.xcf` files are gitignored (they bake in an
absolute project path). Create `examples/resources/northwind.xcf` from this
template, editing `odata.project.dir` to your checkout:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<APPLICATION Parent="ws.default"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:noNamespaceSchemaLocation="https://4js.com/ns/gas/6.00/cfextws.xsd">
  <RESOURCE Id="odata.project.dir" Source="INTERNAL">/path/to/odatalib</RESOURCE>
  <EXECUTION>
    <ENVIRONMENT_VARIABLE Id="FGLLDPATH" Concat="APPEND">$(odata.project.dir):$(odata.project.dir)/examples</ENVIRONMENT_VARIABLE>
    <ENVIRONMENT_VARIABLE Id="FGLPROFILE">$(odata.project.dir)/examples/fglprofile</ENVIRONMENT_VARIABLE>
    <ENVIRONMENT_VARIABLE Id="ODATA_CONFIG">$(odata.project.dir)/examples/northwind-pg.odata</ENVIRONMENT_VARIABLE>
    <PATH>$(odata.project.dir)/examples</PATH>
    <MODULE>NorthwindPgService</MODULE>
    <ACCESS_CONTROL><ALLOW_FROM>ALL</ALLOW_FROM></ACCESS_CONTROL>
    <POOL><START>2</START><MIN_AVAILABLE>2</MIN_AVAILABLE><MAX_AVAILABLE>5</MAX_AVAILABLE></POOL>
  </EXECUTION>
</APPLICATION>
```

To run it yourself:

```bash
export FGLASDIR="…/Genero Studio …/Contents/Resources/gas"
"$FGLASDIR/bin/httpdispatch" -p "$FGLASDIR" \
  -E res.appdata.path=/tmp/odata-gas \
  -E res.path.services=$PWD/examples/resources
# Encode spaces in query options as %20 — curl sends raw spaces in the request line otherwise.
curl 'http://localhost:6394/ws/r/northwind/northwind/Customers?$top=10&$count=true'
curl 'http://localhost:6394/ws/r/northwind/northwind/Orders?$filter=ShipCountry%20eq%20%27France%27&$top=3'
```

**Note on `$metadata` content type:** GAS streams the CSDL document (via
`WSAttachment`, so it is sent raw rather than XML-serialised into an `<rv0>`
wrapper) with `Content-Type: text/xml`, derived from the file extension.
`text/xml` is a valid XML media type (RFC 7303) accepted by OData clients
including Power BI; the body is well-formed CSDL.

**Note on the `OData-Version` header:** the OData spec *recommends* (SHOULD, not
MUST) that responses carry `OData-Version: 4.0`. The GAS REST engine does not
expose response-header control to a `RegisterRestService` handler (there is no
`WSBody`/output-header binding, and the `WSContext` dictionary is request-only),
so the library cannot emit it from BDL. If a strict client requires it, inject it
at the **GAS level** with an `<HTTP>` header rule in the dispatcher configuration
(schema `header-type` in `cfcommon.xsd`):

```xml
<HTTP>
  <SERVICE><HEADER Name="OData-Version">4.0</HEADER></SERVICE>
</HTTP>
```

All clients we tested (Power BI, JSON/HTTP clients) interoperate without it.

## Limitations & roadmap

**Not yet implemented (v0 scope):**
- delta/change-tracking, actions/functions; `$expand=*`, `$levels`,
  nested lambda, single-valued navigation-path comparisons, and `$apply`
  transformations beyond `filter`/`groupby`/`aggregate` (e.g. `compute`,
  `topcount`) or post-aggregation `$filter`
- Write operations (POST/PATCH/PUT/DELETE) — read-only by design
- OAuth2 (v1); v0 targets HTTP Basic + BDL access-control gating via `WSScope`

**Platform limitation (not a roadmap item):**
- **multipart/mixed `$batch`** (the legacy v4.0 batch format) cannot be supported
  on the GAS REST engine. The engine has no raw-body hook (`WSBody` does not
  exist); the only raw input, `WSAttachment`, pre-parses a `multipart/mixed`
  request as form-data (stripping the envelope), rejects a multi-part body, and
  cannot be an array — so the raw batch envelope is unreachable, and a custom
  multipart response cannot be emitted either (verified by spike on GAS 6.00.01).
  Use **JSON batch** (`application/json`, OData v4.01), which is fully supported.

**Known v0 caveats:**
- `@odata.nextLink` percent-encodes the common OData filter charset; a full
  RFC 3986 encoder is a follow-up.

**Recently closed (verified against PostgreSQL Northwind):**
- *Client-compat surface.* (1) `$filter` value functions `tolower`/`toupper`/
  `trim`/`length`/`round` (mapped to ANSI `LOWER`/`UPPER`/`TRIM`/`LENGTH`/`ROUND`,
  bound by the function's result type; date-part/`floor`/`ceiling`/multi-arg/
  arithmetic → `501` pending a dialect layer). (2) `GET /{set}/$count` → bare count
  as `text/plain`. (3) `GET /{set}({key})/{navProp}` navigation traversal (to-many
  collection / to-one entity) with the full query-option set. The two new
  two-segment routes don't shadow the existing ones (literal `/$count` wins over
  the `{navProp}` placeholder — verified on live GAS).
- *CSDL navigation bindings.* `$metadata` now emits a `<NavigationPropertyBinding>`
  inside each `<EntitySet>` (one per declared relationship), so OData clients
  (Power BI / Excel / Tableau) can resolve which entity set a navigation property
  targets and build their relationship model — not just the `<NavigationProperty>`
  type declarations.
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
- *Composite-key entities.* An entity may declare more than one key property
  (`"key": true` per property). Key lookups accept the named form
  `OrderDetails(OrderID=10248,ProductID=11)` (and named/unnamed single keys);
  `$metadata` emits one `<PropertyRef>` per key part. A wrong arity or non-key
  name returns a clean `400`. Verified on live GAS against PostgreSQL.
- *`$expand`.* Declared `navigation` relationships are materialised into the
  response — to-one as a nested object, to-many as a nested array. Expansion runs
  above the providers: the parent rows' join keys drive a single batched `in (…)`
  query against the target entity's provider, then rows are stitched back by key
  (so it works across the SQL/function boundary). `$metadata` advertises the
  relationships as `<NavigationProperty>`. A new `in` filter operator backs this
  and is exposed in `$filter`. The per-service `expandMaxRows` (default 10000)
  caps the related fetch.
- *Richer `$expand` — nested options + multi-level.* Inside an expand item,
  `$select`/`$filter`/`$orderby`/`$top`/`$skip`/`$count` are all supported
  (e.g. `Orders($filter=Freight gt 50;$orderby=OrderDate desc;$top=3;$count=true)`).
  Nested `$top`/`$skip` apply **per parent** (fetch the ordered batch once, slice
  each parent's array at stitch — no N+1); nested `$count` emits a
  `"<nav>@odata.count"` annotation reflecting the per-parent total before paging.
  Multi-level expand (`$expand=Orders($expand=OrderDetails($expand=Product))`)
  recurses over the shared nested JSON, bounded by the per-service `expandMaxDepth`
  (default 3; deeper → `501`). The `$expand` forest is parsed into a flat node
  pool (the same index-pool technique as the `$filter` tree, since BDL has no
  recursive types). Verified on live GAS against PostgreSQL.
- *Lambda operators (`any` / `all`).* `$filter` can test a collection navigation
  property: `Customers?$filter=Orders/any(o: o/Freight gt 100)`,
  `Orders?$filter=OrderDetails/all(d: d/Quantity ge 10)`,
  `Categories?$filter=Products/any()`. Each compiles to a correlated subquery —
  `any` → `EXISTS (… AND P)`, `all` → `NOT EXISTS (… AND NOT P)` (so `all` is
  vacuously true for a parent with no related rows). The lambda predicate `P`
  reuses the full `$filter` grammar over the target entity and composes with the
  rest of the filter via `and`/`or`/`not`. A lambda overloads a `"lambda"` node in
  the existing filter tree (no new type). SQL providers, single-pair joins;
  function-provider host/target, nested lambda, and composite joins return `501`.
  Verified on live GAS against PostgreSQL.
- *`$apply` (server-side aggregation).* `aggregate(…)` (grand totals) and
  `groupby((dims)[, aggregate(…)])` (grouped rows) with an optional leading
  `filter(<pred>)` pre-aggregation segment (which reuses the full `$filter`
  grammar, lambda included). Methods `sum`/`average`/`min`/`max`/`countdistinct`
  and `$count as <alias>` compile to `SUM`/`AVG`/`MIN`/`MAX`/`COUNT(DISTINCT …)`/
  `COUNT(*)` with a `GROUP BY` over the dimensions; `$orderby`/`$top`/`$skip`
  page/sort the grouped result and `$count` returns the group count. The result
  is dynamic columns (dimension property names + aggregate aliases) flowing
  through the standard collection envelope. Aggregates over an `Edm.Single`
  measure are re-narrowed to single precision. Aliases are validated identifiers;
  `sum`/`average` require a numeric measure. SQL providers only; `$apply` combined
  with `$select`/`$expand`/top-level `$filter`, on a key request, against a
  function provider, or any other transformation returns `501`/`400`. Verified on
  live GAS against PostgreSQL.
- *`$batch` (JSON batch, OData v4.01).* `POST /$batch` runs a `requests` array of
  independent `GET`s and returns a `responses` array (`id`/`status`/`body`). Every
  request — direct or batched — flows through one non-raising dispatch core
  (`dispatchGet`): the direct `GET` maps an error outcome onto `SetRestError`,
  while a sub-request echoes the same `status`+`body` inside the batch, so batched
  behaviour cannot drift from direct. All query options work inside a sub-URL
  (parsed + percent-decoded), authorisation uses the batch request's headers, and
  it is continue-on-error (the batch returns `200`; failures are isolated per
  sub-response). Read-only: a non-`GET` sub-request → `405`, `$metadata` → `501`;
  JSON only (a non-JSON body is rejected). Verified on live GAS against PostgreSQL.
- *Service loop lifecycle.* `ODataService.run()` now only terminates the DVM on
  `-2` / `-4` / `-10` (per the documented engine contract); transient
  per-connection codes such as `-3` no longer end the process, so the GAS pool
  reuses the DVM instead of churning under load.
