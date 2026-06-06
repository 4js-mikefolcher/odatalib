# `$batch` (batch requests) — Technical Design

**Status:** Design pass for review — 2026-06-06
**Author:** Drafted with Mike Folcher.
**Scope target:** odatalib (additive; read-only).
**Builds on:** the GAS REST surface and per-request flow in
[`ODataService`](../com/fourjs/odatalib/ODataService.4gl), the error model in
[`ODataError`](../com/fourjs/odatalib/ODataError.4gl), and every existing query
feature (all reused unchanged through a shared dispatch core).

---

## 1. Summary

`$batch` lets a client send several OData requests in one HTTP round-trip and get
all the responses back together — the pattern BI/automation clients use to avoid
chatty round-trips. For a **read-only** service every sub-request is a `GET`, so
there are no change sets, no transactions, and no atomicity — just a bundle of
independent reads, each with its own status.

```
POST /$batch        Content-Type: application/json
{
  "requests": [
    { "id": "1", "method": "GET", "url": "Customers('ALFKI')?$select=CompanyName" },
    { "id": "2", "method": "GET", "url": "Orders?$top=2&$count=true" },
    { "id": "3", "method": "GET", "url": "Nope" }
  ]
}
->  200 OK   Content-Type: application/json
{
  "responses": [
    { "id": "1", "status": 200, "body": { "CompanyName": "Alfreds Futterkiste", … } },
    { "id": "2", "status": 200, "body": { "@odata.count": 830, "value": [ … ] } },
    { "id": "3", "status": 404, "body": { "error": { "code": "NotFound", … } } }
  ]
}
```

### Format decision: JSON batch (OData v4.01) only
OData defines two batch formats: the legacy **multipart/mixed** (v4.0) and the
**JSON batch** (v4.01). This design implements **JSON batch only**:

- The GAS REST engine has **no raw-body attribute** (`WSBody` does not exist); a
  POST body is delivered either as a **typed record** (engine deserialises the
  JSON) or as a `WSAttachment` temp file. JSON batch maps cleanly onto a typed
  record; multipart/mixed would require receiving the raw body as a temp file and
  hand-parsing embedded HTTP messages and MIME boundaries — fragile and large.
- JSON batch is the modern format and sufficient for a read-only service.
- A `$batch` POST with a non-JSON `Content-Type` (e.g. `multipart/mixed`) returns
  **`415 Unsupported Media Type`** with an OData error envelope.

### In scope (v1)
- `POST /$batch` with `application/json`, a `requests` array of `GET`
  sub-requests, each routed through the **same logic** as a direct `GET`
  (entity collection, key lookup, service document) with all query options
  (`$filter`/`$select`/`$top`/`$skip`/`$count`/`$orderby`/`$expand`/`$apply`,
  lambda — everything already supported).
- **Continue-on-error**: a failing sub-request yields its own error status/body;
  the batch as a whole still returns `200` with the remaining responses.
- Per-sub-request `status` + `body` echoed with the request `id`.

### Out of scope (documented; safe degradations)
- **multipart/mixed** batch → `415` (above).
- **Change sets / writes** (`POST`/`PATCH`/`PUT`/`DELETE` sub-requests) → each
  such sub-request gets a **`405 Method Not Allowed`** sub-response (read-only).
- **Request referencing** (`$<id>` URLs) and **atomicityGroup** → ignored; a
  sub-request URL referencing a prior id is treated literally (and will 404).
- **`$metadata` inside a batch** → `501` sub-response (CSDL is XML; it does not
  belong in a JSON batch body). The service document (`"/"`) **is** supported.
- Per-sub-request headers → not honoured; authorization uses the batch request's
  own headers/context for every sub-request (§5).

---

## 2. The core refactor: a non-raising dispatch function

`ODataError.raiseCode` calls `SetRestError`, which sets the HTTP status **of the
single response**. That is correct for a direct `GET`, but a batch sub-request's
status must go **inside** the batch body, not on the envelope. So the per-request
logic must be able to *return* an outcome instead of raising it.

Extract the body of `getEntitySet` (auth → find entity → key/collection → build
JSON) into a shared, **non-raising** function:

```4gl
PUBLIC TYPE T_ODataSubResponse RECORD
    status  INTEGER,            # HTTP status (200 / 4xx / 5xx)
    code    STRING,             # OData error code  (NULL on success)
    message STRING,             # error message     (NULL on success)
    body    util.JSONObject     # success payload OR the error envelope object
END RECORD

PRIVATE FUNCTION dispatchGet(
    name STRING, keyVal STRING, isKeyReq BOOLEAN,
    pSelect, pFilter, pTop, pSkip, pCount, pOrderby, pExpand, pApply STRING,
    hScopes, hUser, baseUrl STRING)
    RETURNS T_ODataSubResponse
```

Every `CALL ODataError.raiseCode(c, m) RETURN NULL` in the current flow becomes
`RETURN subErr(c, m)` (status via `ODataError.httpStatusFor`, body = the
`{"error":{code,message}}` object); every success `RETURN obj` becomes
`RETURN subOk(obj)` (status 200).

`getEntitySet` then becomes a thin wrapper over the **same** core — preserving the
verified direct-GET behaviour exactly:

```4gl
CALL splitEntityKey(entitySet) RETURNING name, keyVal, isKeyReq
IF entitySet == "$metadata" THEN … raise BadRequest … END IF   # unchanged guard
CALL dispatchGet(name, keyVal, isKeyReq, pSelect, …, pApply, hScopes, hUser,
                 serviceBaseUrl()) RETURNING sub.*
IF sub.status >= 400 THEN
    CALL ODataError.raise(sub.status, sub.code, sub.message)   # SetRestError path
    RETURN NULL
END IF
RETURN sub.body
```

This keeps **one** code path for all request handling (direct and batched), so
the batch feature cannot drift from direct behaviour. The regression suites
(SQLite SmokeTest, PgSmokeTest) re-verify the wrapper.

---

## 3. The `$batch` endpoint

```4gl
PUBLIC TYPE T_ODataBatchItem RECORD
    id     STRING,
    method STRING,
    url    STRING                 # service-root-relative, e.g. "Orders?$top=2"
END RECORD
PUBLIC TYPE T_ODataBatchRequest RECORD
    requests DYNAMIC ARRAY OF T_ODataBatchItem
END RECORD

PUBLIC FUNCTION batch(req T_ODataBatchRequest)
    ATTRIBUTES(WSPost, WSPath = "/$batch",
        WSDescription = "OData JSON batch ($batch)")
    RETURNS util.JSONObject ATTRIBUTES(WSMedia = "application/json")
```

- The engine deserialises the JSON body into `req` (the documented typed-body
  mechanism). Unknown per-item members (`headers`, `body`, `atomicityGroup`) are
  ignored by the deserialiser.
- **Content-Type guard:** if `ctx["Content-Type"]` is present and not
  `application/json` (e.g. `multipart/mixed`), raise `415` and return.
- For each `requests[i]`:
  1. **Method:** non-`GET` (case-insensitive) → sub-response `405`.
  2. **Parse the URL:** strip a leading `/`; split into path segment and query
     string at the first `?`; empty path → service document; `"$metadata"` →
     `501`; otherwise `splitEntityKey(path)` + parse the query string into the
     `$`-options (URL-decoding `%XX` and `+`).
  3. **Dispatch:** `dispatchGet(...)` with the parsed options and the batch
     request's auth headers/context.
  4. **Collect:** `{ "id": <id>, "status": <status>, "body": <body> }` into the
     `responses` array (the `body` is the success payload or the error envelope).
- Return `{ "responses": [ … ] }` as a `util.JSONObject` (status `200`), serialised
  by the engine exactly like the service document.

### URL / query-string parsing (new small helpers)
- `splitSubUrl(url) -> (pathSeg, queryStr)` — split at the first `?`, trim a
  leading `/`.
- `parseQueryOptions(queryStr) -> dict` — split on `&`, then `key=value` on the
  first `=`, **percent-decode** key and value (`%XX` → byte, `+` → space). Pull
  `$select`/`$filter`/`$top`/`$skip`/`$count`/`$orderby`/`$expand`/`$apply` into
  the `dispatchGet` arguments; unknown `$`-options are ignored (consistent with
  the direct path, which only binds the known ones).
- A `percentDecode(s)` helper (no built-in URL-decode is assumed) converts `%XX`
  escapes and `+`.

---

## 4. Routing & precedence

- `POST /$batch` is a distinct **verb** from the existing `GET /{entitySet}`, and
  `/$batch` is a **literal** segment (more specific than the `{entitySet}`
  placeholder). The two cannot collide. **To verify on GAS:** that a literal
  `POST /$batch` is matched ahead of any placeholder and that the `$` in the path
  is accepted (the existing literal `GET /$metadata` already proves a `$`-literal
  path works; `$batch` should behave the same).

---

## 5. Authorization

Each sub-request is authorised exactly as a direct request — `dispatchGet` runs
the existing `buildAuthContext` + `ODataAuth.authorize` per entity, using the
**batch POST's** headers/context (`Authorization`/`OIDC_*`/`X-OData-Scopes`/
`X-OData-User`/GAS `Scope`). A denied sub-request yields a `401`/`403`
sub-response; the batch still returns `200`. (Per-sub-request header overrides are
out of scope for v1.)

---

## 6. Error handling summary

| Condition | Result |
|---|---|
| `$batch` body not `application/json` | `415` (whole request) |
| Malformed JSON body / missing `requests` | `400` (whole request) |
| Sub-request: unknown entity / bad key | sub-response `404` |
| Sub-request: bad query option | sub-response `400` |
| Sub-request: unsupported (`$metadata`, unsupported `$apply`, …) | sub-response `501` |
| Sub-request: non-`GET` method | sub-response `405` |
| Sub-request: auth denied | sub-response `401`/`403` |
| Any sub-request failure | batch still returns `200`; failures isolated |

---

## 7. Implementation map (files)

| File | Change |
|---|---|
| `ODataTypes` | `T_ODataSubResponse`, `T_ODataBatchItem`, `T_ODataBatchRequest` |
| `ODataService` | extract `dispatchGet` (non-raising core) from `getEntitySet`; make `getEntitySet` a thin wrapper; add `batch()` WSPost endpoint; `splitSubUrl`/`parseQueryOptions`/`percentDecode` helpers; `subOk`/`subErr` |
| `ODataError` | (reused as-is; `httpStatusFor` drives sub-statuses) |
| `examples/PgSmokeTest.4gl` | in-process batch: a mixed success/404 bundle, options inside a sub-URL, a non-GET 405, an unsupported 501 |
| `README` | move `$batch` from roadmap to supported (JSON batch, read-only); example |

No change to the providers, query parser, serializer, expand, or apply — `$batch`
is pure orchestration over the shared dispatch core.

---

## 8. Test plan (PG Northwind: in-process → live GAS)

- Mixed bundle: `Customers('ALFKI')`, `Orders?$top=2&$count=true`, `Nope` →
  `responses` with statuses `200/200/404`, ids preserved, batch `200`.
- Options inside a sub-URL (URL-encoded space): `Orders?$filter=ShipCountry%20eq%20'France'&$top=1` → `200` with the filtered row.
- `$expand`/`$apply` inside a sub-request → same result as the direct call.
- Service document sub-request (`url:"/"` or `""`) → `200` entity-set listing.
- Non-GET sub-request (`method:"POST"`) → `405` sub-response (batch still `200`).
- `$metadata` sub-request → `501` sub-response.
- `multipart/mixed` Content-Type → whole request `415`.
- **Regression:** every direct GET (SmokeTest + PgSmokeTest) unchanged after the
  `getEntitySet` → `dispatchGet` refactor.
- Live GAS: confirm `POST /$batch` routes (literal path, POST verb), the typed
  body deserialises, and the JSON `responses` envelope is returned with
  `application/json`.

---

## 9. Locked decisions (2026-06-06)

1. **JSON batch only** — `multipart/mixed` POSTs return `415`.
2. **Non-`GET` sub-requests → `405`** (read-only service).
3. **`$metadata` sub-request → `501`** (service document `"/"` is supported).
4. **Per-sub-request auth = the batch POST's headers/context** (no per-item
   header overrides in v1).
