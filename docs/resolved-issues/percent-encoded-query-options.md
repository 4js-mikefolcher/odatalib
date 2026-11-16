# Resolved in v1.2.1: percent-encoded query option names (`%24top`) were rejected by GWS

> **This issue is FIXED.** It is kept as an engineering record of the defect and
> its fix. odatalib **v1.2.1 and later are not affected**; releases up to and
> including v1.2.0 were. Past tense below describes the pre-fix behaviour.

**Status:** FIXED & verified (2026-11-16). `getEntitySet`, `getEntityCount` and
`getNavigation` now declare every `$`-option twice (`$top` and `%24top`) and merge
the two spellings before the request is handled.
**Affects (pre-fix):** every request whose query string spelled an option name as
`%24<name>` — `$select`, `$filter`, `$top`, `$skip`, `$count`, `$orderby`,
`$expand`, `$apply`. All engines (the failure is in GWS, before any SQL).
**Discovered:** while building a Northwind OData service on odatalib 1.2.0 (GAS
6.00.05, Genero 6.00.03, PostgreSQL): 13 of 17 demo URLs returned `400`.

## Symptom

A client that percent-encodes the `$` in a query option *name* sends `?%24top=5`
instead of `?$top=5`. GWS answered `400` itself, with an empty body, and odatalib was
never called:

```
HTTP/1.1 400 Unexpected Rest query parameter
X-FourJs-Web-Service: GWS Server (Build 202511171702)
Content-Length: 0
```

It is not an OData error envelope, because the library never ran. Only `%24` in a
**name** was affected; other encoded characters (`%2C`, `%20`, `%27`) in a *value*
were always fine, and so was `%24` in a *path* segment (`Orders/%24count`).

## Root cause

GWS matches each query parameter **name** in the request against the `WSName`
declared on the REST function's `WSQuery` parameters, exactly as written. It
percent-decodes values but, as observed, not names. odatalib declared
`WSName = "$top"` etc., so `%24top` matched nothing and GWS rejected the request
before dispatch. No GWS or GAS setting that relaxes this was found.

`$batch` sub-request URLs were not affected: the library parses those itself
(`parseQueryOptions` percent-decodes names and values), so `%24top` already worked
inside a batch.

## Reproduce (on v1.2.0)

`B` is the root URL of any odatalib service under GAS:

| Request | Result on 1.2.0 |
|---|---|
| `Customers?$top=2` | 200 |
| `Customers?%24top=2` | **400** (empty body) |
| `Customers?$top=2&%24skip=1` (mixed) | **400** |
| `Customers?%24filter=Country%20eq%20%27Germany%27&$top=2` | **400** |
| `Customers?$select=CustomerID%2CCompanyName&$top=2` (`%2C` in a *value*) | 200 |
| `Customers?$filter=Country%20eq%20%27Germany%27&$top=2` (`%27`, `%20` in a value) | 200 |

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$B/Customers?\$top=2"     # 200
curl -s -o /dev/null -w '%{http_code}\n' "$B/Customers?%24top=2"    # 400
```

The in-memory regression suite (`make test`) never goes through GAS, so it could not
see this class of defect.

## The fix

In `com/fourjs/odatalib/ODataService.4gl`, for `getEntitySet` and `getNavigation`
(eight options) and `getEntityCount` (`$filter` only), each option gained an extra
optional `WSQuery` parameter named for its `%24` spelling
(`WSName = "%24top"`, carried in `topEncoded`, with `WSDescription = "Alias of $top"`).
Before the existing body runs, each alias is copied into the real parameter when
that is empty:

```genero
   IF pTop IS NULL THEN LET pTop = topEncoded END IF
```

Everything downstream (`dispatchGet`, `dispatchNavigation`, the parsers, the
providers) receives the same eight values as before.

Behaviour decisions:

- **Mixed forms** (`$top=2&%24select=CustomerID`) are merged; the result is
  byte-identical to the all-`$` request.
- **The same option in both spellings** (`$top=1&%24top=2`): the `$` form wins and
  no error is raised. (GWS already answers `400` for a *repeated identical* name such
  as `$top=1&$top=2`; the two spellings are different names to GWS, so this case does
  reach the library.)
- **Unknown names are still rejected** — `?%24bogus=1` and `?foo=1` return `400`;
  the endpoints did not become "accept any parameter".
- **Not covered (unchanged):** other options a client may send (`$format`, `$search`,
  `$levels`) are still `400` from GWS, with a raw `$` or an encoded one; and the
  `$`-less 4.01 spellings (`?top=5`).

Side effect: the OpenAPI description GWS publishes for the service
(`<service-url>?openapi.json`) now lists 16 query parameters on the collection and
navigation operations and 2 on `/$count` (the `%24` entries described as
"Alias of `$…`"), where it listed 8 and 1.

## Verification

Against PostgreSQL Northwind (`examples/northwind-pg.odata`) and PostgreSQL
AdventureWorks (`examples/adventureworks.odata`), served by a standalone GAS
6.00.01 with Genero 6.00.03, new build and unmodified 1.2.0 side by side:

| Check | 1.2.0 | Fixed |
|---|---|---|
| `tests/gas_encoding_test.sh` (17 checks: 11 encoded-vs-plain pairs, both-spellings precedence ×2, unknown options ×3, `$batch`) — Northwind | 4 pass / 13 fail | 17 / 17 |
| same, AdventureWorks (`ODATA_PROFILE=adventureworks`) | 4 pass / 13 fail | 17 / 17 |
| 39 plain-`$` requests (paging links, `$expand`, `$apply`, `$metadata`, 400/404 envelopes) plus `$batch`, compared old vs new | — | identical status and body |
| `make test` (in-memory SQLite) | 62 / 62 | 62 / 62 |
| `make test-portability` (live PostgreSQL) | — | AdventureWorks 47 / 47, Northwind 40 / 40 |
| `make compile` (`-Wall`) | clean | clean |

The 13 failures on 1.2.0 are exactly the encoded requests; the unknown-option and
`$batch` checks pass on both builds, as intended.

Genero 5: the whole library compiles with `fglcomp -M -Wall -Werror` and `make test`
passes (62 / 62) on 5.00.00. A minimal non-packaged REST service declaring
`WSName = "%24top"` was run under GWS on 5.00.00, 5.00.02, 5.00.03 and 6.00.03: all
four accept the name, route `?%24top=2` to it, apply the `$`-wins rule and still
answer `400` for `?%24bogus=1`. (Separately, and unchanged by this fix, the packaged
`com.fourjs.odatalib.ODataService` module could not be registered by the 5.00.00,
5.00.02 and 5.00.03 runtimes tried: `-15536 The module name must not contain a '.'`,
identically on unmodified 1.2.0.)
