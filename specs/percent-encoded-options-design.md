# Percent-encoded query option names — accept `%24top` as well as `$top`

**Status:** Spec for implementation — 2026-11-16
**Author:** Drafted with Mike Folcher.
**Scope target:** odatalib **1.2.1** (patch release; additive; read-only; no change to the `.odata` format).
**Builds on:** the three REST functions in
[`ODataService`](../com/fourjs/odatalib/ODataService.4gl) that take `$`-options:
`getEntitySet`, `getEntityCount`, `getNavigation`.

---

## 1. Summary

A client that percent-encodes the `$` in a query option name sends `?%24top=5` instead of
`?$top=5`. The GAS REST engine (GWS) rejects that request itself with
`400 Unexpected Rest query parameter` and an **empty body**; odatalib is never called. Every
`$`-option request from such a client fails: `$filter`, `$select`, `$top`, `$skip`, `$count`,
`$orderby`, `$expand`, `$apply`.

The fix is small and additive: declare each option **twice** on the three REST functions, once as
`$top` (today) and once as `%24top`, and merge the two before the existing code runs. It was
prototyped and verified end to end (section 7). This document is everything needed to implement it,
test it and release it without the conversation it came from.

## 2. Problem and evidence

Found while building a Northwind OData service on odatalib 1.2.0
(`genero-edl/step3-odata`, GAS 6.00.05, Genero 6.00.03, PostgreSQL). The reporter found that "many" of
17 demo URLs returned 400. Reproducing their encoding, **13 of the 17 fail**: every URL that has a
query option. The four with no query string work. The Apache access log shows what the client
actually sent:

```
GET /gas6/ws/r/step3-odata/northwind/Customers?%24top=5&%24select=CustomerID%2CCompanyName%2CCountry HTTP/1.1" 400 -
GET /gas6/ws/r/step3-odata/northwind/Orders?%24select=OrderID HTTP/1.1" 400 -
GET /gas6/ws/r/step3-odata/northwind/Customers?$filter=Country%20eq%20%27Germany%27&%24select=CompanyName%2CCity&%24count=true HTTP/1.1" 400 -
```

The client could not be identified (the access log records no User-Agent). Any client or HTTP
library that serialises query names with `encodeURIComponent`-style encoding produces `%24`; some
tools also re-encode a URL they are given. The other encoded characters in those requests (`%2C`,
`%20`, `%27`) are not a problem. Only `%24` in a **name** is.

Reproduction against any odatalib service under GAS (isolated with `curl`):

| Request | Result |
|---|---|
| `Customers?$top=2` | 200 |
| `Customers?%24top=2` | **400** |
| `Customers?$top=2&%24skip=1` (mixed) | **400** |
| `Customers?%24filter=Country%20eq%20%27Germany%27&$top=2` | **400** |
| `Customers?$select=CustomerID%2CCompanyName&$top=2` (`%2C` in a *value*) | 200 |
| `Customers?$filter=Country%20eq%20%27Germany%27&$top=2` (`%27`, `%20` in a value) | 200 |

The 400 response, in full:

```
HTTP/1.1 400 Unexpected Rest query parameter
X-FourJs-Web-Service: GWS Server (Build 202610231756)
Content-Length: 0
```

Not an OData error envelope, because the library never ran.

## 3. Root cause

GWS matches each query parameter **name** in the request against the `WSName` declared on the
function's `WSQuery` parameters, exactly as written; it percent-decodes values but, as observed, not
names (the `WSQuery` page of the Genero manual describes decoding of values and says nothing about
names). odatalib declares
`WSName = "$top"` etc., so `%24top` matches nothing and GWS answers 400 before dispatch. No GWS
setting that relaxes this was found (manual pages for `WSQuery`, `WSName`; MCP skill
`fourjs-rest-services`). Things that are **not** affected:

- `%24` in a **path** segment already works: `Orders/%24count` returns 200 on 1.2.0.
- `$batch` sub-request URLs: the library parses those itself and already accepts `%24top` there
  (checked: `{"url":"Customers?%24top=2&%24select=CustomerID"}` returns inner status 200 with 2
  rows on 1.2.0). No change needed; keep it as a regression check.

## 4. Requirements

1. **R1.** Every `$`-option accepted today by `getEntitySet`, `getEntityCount` and
   `getNavigation` is also accepted as `%24<name>`: `select`, `filter`, `top`, `skip`, `count`,
   `orderby`, `expand`, `apply` (`getEntityCount` takes `$filter` only, as today).
2. **R2.** A request may mix forms (`$top=2&%24select=CustomerID`). The result is identical to the
   all-`$` form, byte for byte.
3. **R3.** Requests that use only `$` behave exactly as before. `make test` still passes and
   `make compile` stays free of warnings (`-Wall`).
4. **R4.** If the same option is sent in both forms, the `$` form wins and no error is raised.
   (Chosen for simplicity. Note GWS already answers 400 for a *repeated* name, e.g.
   `$top=1&$top=2`, so this case is an edge. Rejecting it with a `400 BadRequest` envelope is an
   acceptable stricter alternative if the implementer prefers; pick one, document it, test it.)
5. **R5.** Unknown options must still be rejected. `Customers?%24bogus=1` and `Customers?foo=1`
   return 400, as today. The change must not turn the endpoints into "accept any parameter".
6. **R6.** `$batch` behaviour is unchanged (section 3).

### Non-goals

- Other options a client may send, notably `$format=json`, `$search`, `$levels`. GWS also answers
  400 for these today (verified: `Customers?$format=json` returns 400 even with a raw `$`). A
  related but separate compatibility gap; open a follow-up if wanted.
- The `$`-less option names that OData 4.01 allows (`?top=5`).
- Any Apache or GAS configuration change. The fix lives in the package.
- Changes to the `.odata` format, the SQL providers, authorisation or serialisation.

## 5. Design

For each of the three functions: add the encoded names as extra **optional** `WSQuery` parameters,
then copy them into the real parameters when those are empty, before the existing body runs.

```4gl
    pTop STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$top"),     -- unchanged
    ...
    eTop STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24top"),   -- new
    ...
    IF pTop IS NULL THEN LET pTop = eTop END IF                        -- new, first statement
```

- `getEntitySet`: 8 new parameters (`eSelect eFilter eTop eSkip eCount eOrderby eExpand eApply`),
  8 merge lines.
- `getEntityCount`: 1 new parameter (`eFilter`), 1 merge line.
- `getNavigation`: same 8 as `getEntitySet`.
- The merge lines go **after** the `DEFINE`s and before the first executable statement of each
  function (BDL requires declarations first).
- Everything downstream (`dispatchGet`, `dispatchNavigation`, the parser, providers) is untouched:
  they receive the same eight values as before.

Reference implementation: Appendix A (78 lines, verified). Apply it by intent, not with `patch`;
line offsets will have moved. Consider adding a `WSDescription` to each new parameter such as
`"Alias of $top for clients that percent-encode the $"`, so the 16-parameter signature is
self-explaining wherever GWS publishes the service description. That effect was not checked.

### Alternatives considered

| Option | Verdict |
|---|---|
| Apache `mod_rewrite` turning `%24` into `$` for `/ws/` | Works in principle but is outside the package, global to the web server, and every deployment must repeat it. Not tested. |
| A GWS / GAS setting to relax name matching | None found. |
| Read the raw query string from `WSContext` and parse it in the library | Not evaluated. The README (GAS deployment notes) describes `WSContext` as a request-only dictionary; whether it exposes the raw query string is unknown. Worth a spike only if the 17 extra parameters are judged too heavy. |
| One record-typed `WSQuery` parameter for all options | Not evaluated. |

## 6. Test plan

The existing suite (`tests/odata_test.4gl`, in-memory SQLite) never goes through GAS, so it cannot
see this class of defect. Add a **GAS-level** check and keep the existing suite as the regression
guard.

**T1 — new `tests/gas_encoding_test.sh`** (curl + a few lines of python3 or jq for JSON; takes
`ODATA_URL`, the root of an already-running service, e.g.
`http://localhost/gas6/ws/r/<xcf>/<service>`; not wired into `make test` because it needs GAS;
document it in the README under *GAS deployment*). For every row below, request the encoded form and
the plain `$` form and assert **status 200 and identical bodies** (except where stated):

| # | Encoded request (path relative to the service root) | Function covered |
|---|---|---|
| 1 | `Customers?%24top=2` | getEntitySet |
| 2 | `Customers?%24select=CustomerID%2CCompanyName&%24top=2` | getEntitySet |
| 3 | `Customers?%24filter=Country%20eq%20%27Germany%27&%24count=true` | getEntitySet |
| 4 | `Orders?%24orderby=OrderID%20desc&%24top=1&%24skip=1` | getEntitySet |
| 5 | `Orders(10248)?%24expand=Customer` | getEntitySet (key request) |
| 6 | `Orders?%24apply=groupby((ShipCountry),aggregate(%24count%20as%20N))` | getEntitySet, `$apply` |
| 7 | `Customers('ALFKI')/Orders?%24top=2` | getNavigation |
| 8 | `Orders/$count?%24filter=ShipCountry%20eq%20%27France%27` | getEntityCount |
| 9 | `Customers?$top=2&%24select=CustomerID` (mixed) | R2 |
| 10 | every parameter and value fully percent-encoded (`%28 %29 %2C %27 %20`) | R2 |
| 11 | `$batch` with sub-URL `Customers?%24top=2&%24select=CustomerID` | R6 |

And these must still fail (R5), with status 400: `Customers?%24bogus=1`, `Customers?foo=1`.
If R4 is implemented as precedence, also assert that `Customers?$top=1&%24top=2` returns exactly one
row.

The dataset is whatever the service serves; use Northwind (`northwind-pg.odata` in `examples/`, or any
service) and compare encoded against plain so the test does not depend on row counts.

**T2 — regression.** `make compile` (no warnings) and `make test` (the in-memory suite) both pass.

**T3 — Genero versions.** The prototype was built and run only on Genero **6.00.03** with GAS
**6.00.05**. The package also ships a Genero **5** variant, so compile it and run T1 on the oldest
supported 5.x if one is available. Specifically confirm that a `WSName` containing `%` is accepted
there. If it is not, report it before releasing.

**How to test an unreleased build without publishing** (this is how the prototype was verified): put
the compiled patched `com/fourjs/odatalib/ODataService.42m` in a scratch directory, create a **second**
GAS descriptor (copy of the service's xcf, different file name) whose `FGLLDPATH` starts with that
directory, run T1 against the second descriptor's URL, then delete the descriptor. The real service
is never touched.

## 7. Verification already done (prototype)

Prototype = Appendix A applied to a scratch copy of 1.2.0's `ODataService.4gl`, compiled with
`fglcomp -M` and served under a temporary descriptor, against the Northwind PostgreSQL database.

| Check | Result |
|---|---|
| Requests sent by the reporter's client (3 above) | all 200 on the patched copy, 400 on 1.2.0 |
| 17 demo URLs with every name and value fully percent-encoded | 1.2.0: 13 fail. Patched: 0 fail. All 17 answers byte-identical to the plain-`$` answers |
| Mixed forms, `Orders/%24count`, `Orders/$count?%24filter=...`, `Customers('ALFKI')/Orders?%24top=2&%24select=OrderID` | 200 |
| `%24format=json` on the patched copy | still 400 (R5) |
| Existing 152-check functional suite of the consuming project, run against the patched copy | 152 / 152 pass |
| `$batch` sub-URL with `%24top` | 200, 2 rows, on both 1.2.0 and patched |

**Not verified:** the `$`+`%24` duplicate rule (R4 is by code reading, not measured); Genero 5; any
effect on a published OpenAPI/service description; which real BI clients (Excel, Power BI, Tableau)
percent-encode `$`. The reporter's client is unidentified.

## 8. Release steps

1. Implement, then T1 to T3.
2. `fglpkg.json`: `"version": "1.2.1"`.
3. README: under *Limitations & roadmap* → *Recently closed*, add a short entry (clients that
   percent-encode `$` are accepted); and the new test script under *GAS deployment*.
4. `docs/resolved-issues/percent-encoded-query-options.md`: what the defect was, how to reproduce it
   (the table in section 2), what the fix changed. Add a row to `docs/resolved-issues/README.md`:
   *Affected* ≤ 1.2.0, *Fixed in* **1.2.1**.
5. `fglpkg lint`, `fglpkg pack --list` (confirm the new doc is in the zip: `fglpkg.json` ships
   `docs/**/*.md`, so it is picked up by the glob), `fglpkg publish --dry-run`.
6. **Stop before `fglpkg publish`** and confirm with Mike. It is irreversible (an approved version is
   immutable), goes to the private `gi` registry, and the new version stays pending until an
   administrator approves it.
7. Consumer follow-up, in `genero-edl/step3-odata` (a separate repo and session): set
   `odatalib` to `1.2.1` in `fglpkg.json`, `fglpkg install`, add an encoded-request section to
   `tests/smoke.py` (the current suite sends only raw `$`, which is why this defect was missed),
   `make test`, then re-check the demo URLs.

## 9. Open decisions for the implementer

1. R4: precedence (`$` wins) or reject with 400. Default: precedence.
2. Whether to add `WSDescription` to the 17 new parameters (see section 5).
3. Whether to open the `$format` follow-up now or leave it in *Limitations & roadmap*.

---

## Appendix A — reference implementation (prototype diff, verified on Genero 6.00.03)

Against `com/fourjs/odatalib/ODataService.4gl` at commit `6d5cbd1` (1.2.0). Hunk offsets will drift.

```diff
--- a/com/fourjs/odatalib/ODataService.4gl
+++ b/com/fourjs/odatalib/ODataService.4gl
@@ -186,6 +186,14 @@
     pOrderby STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$orderby"),
     pExpand STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$expand"),
     pApply STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$apply"),
+    eSelect STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24select"),
+    eFilter STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24filter"),
+    eTop STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24top"),
+    eSkip STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24skip"),
+    eCount STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24count"),
+    eOrderby STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24orderby"),
+    eExpand STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24expand"),
+    eApply STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24apply"),
     hScopes STRING ATTRIBUTES(WSHeader, WSOptional, WSName = "X-OData-Scopes"),
     hUser STRING ATTRIBUTES(WSHeader, WSOptional, WSName = "X-OData-User"))
     ATTRIBUTES(WSGet,
@@ -197,6 +205,14 @@
     DEFINE name, keyVal STRING
     DEFINE sub ODataTypes.T_ODataSubResponse
 
+    IF pSelect IS NULL THEN LET pSelect = eSelect END IF
+    IF pFilter IS NULL THEN LET pFilter = eFilter END IF
+    IF pTop IS NULL THEN LET pTop = eTop END IF
+    IF pSkip IS NULL THEN LET pSkip = eSkip END IF
+    IF pCount IS NULL THEN LET pCount = eCount END IF
+    IF pOrderby IS NULL THEN LET pOrderby = eOrderby END IF
+    IF pExpand IS NULL THEN LET pExpand = eExpand END IF
+    IF pApply IS NULL THEN LET pApply = eApply END IF
     # Defensive guard if a literal path leaked into the placeholder route.
     IF entitySet == "$metadata" THEN
         CALL ODataError.raiseCode("BadRequest",
@@ -226,6 +242,7 @@
 PUBLIC FUNCTION getEntityCount(
     entitySet STRING ATTRIBUTES(WSParam),
     pFilter STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$filter"),
+    eFilter STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24filter"),
     hScopes STRING ATTRIBUTES(WSHeader, WSOptional, WSName = "X-OData-Scopes"),
     hUser STRING ATTRIBUTES(WSHeader, WSOptional, WSName = "X-OData-User"))
     ATTRIBUTES(WSGet,
@@ -236,6 +253,7 @@
     DEFINE isKeyReq BOOLEAN
     DEFINE sub ODataTypes.T_ODataSubResponse
 
+    IF pFilter IS NULL THEN LET pFilter = eFilter END IF
     CALL splitEntityKey(entitySet) RETURNING name, keyVal, isKeyReq
     IF isKeyReq THEN
         CALL ODataError.raiseCode("BadRequest",
@@ -270,6 +288,14 @@
     pOrderby STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$orderby"),
     pExpand STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$expand"),
     pApply STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "$apply"),
+    eSelect STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24select"),
+    eFilter STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24filter"),
+    eTop STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24top"),
+    eSkip STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24skip"),
+    eCount STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24count"),
+    eOrderby STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24orderby"),
+    eExpand STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24expand"),
+    eApply STRING ATTRIBUTES(WSQuery, WSOptional, WSName = "%24apply"),
     hScopes STRING ATTRIBUTES(WSHeader, WSOptional, WSName = "X-OData-Scopes"),
     hUser STRING ATTRIBUTES(WSHeader, WSOptional, WSName = "X-OData-User"))
     ATTRIBUTES(WSGet,
@@ -280,6 +306,14 @@
     DEFINE isKeyReq BOOLEAN
     DEFINE sub ODataTypes.T_ODataSubResponse
 
+    IF pSelect IS NULL THEN LET pSelect = eSelect END IF
+    IF pFilter IS NULL THEN LET pFilter = eFilter END IF
+    IF pTop IS NULL THEN LET pTop = eTop END IF
+    IF pSkip IS NULL THEN LET pSkip = eSkip END IF
+    IF pCount IS NULL THEN LET pCount = eCount END IF
+    IF pOrderby IS NULL THEN LET pOrderby = eOrderby END IF
+    IF pExpand IS NULL THEN LET pExpand = eExpand END IF
+    IF pApply IS NULL THEN LET pApply = eApply END IF
     CALL splitEntityKey(entitySet) RETURNING name, keyVal, isKeyReq
     CALL dispatchNavigation(name, keyVal, isKeyReq, navProp,
             pSelect, pFilter, pTop, pSkip, pCount, pOrderby, pExpand, pApply,
```

## Appendix B — quick reproduction

With any odatalib 1.2.0 service running under GAS (`B` is its root URL):

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$B/Customers?\$top=2"      # 200
curl -s -o /dev/null -w '%{http_code}\n' "$B/Customers?%24top=2"     # 400 (empty body)
curl -si "$B/Customers?%24top=2" | head -3                           # HTTP/1.1 400 Unexpected Rest query parameter
```
