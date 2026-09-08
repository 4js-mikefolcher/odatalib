# Resolved in v1.0.2: relationship traversal bypassed the authorizer

> **This issue is FIXED.** It is kept as an engineering record of the
> vulnerability, its exploit and its fix. odatalib **v1.0.2 and later are not
> affected**; releases up to and including v1.0.1 were. Past tense below
> describes the pre-fix behaviour.

**Status:** RESOLVED & verified live (2026-06-25, MariaDB + Postgres + Oracle).
  - ✅ **`$expand` (data disclosure) — FIXED & verified.** Unauthorized expand targets
    are silently omitted (200, nav property absent); authorized expands still work.
    `tests/security_test.sh` B1 = PASS, B4 regression PASS on mdb + pgs.
  - ✅ **`$filter` lambda `any()`/`all()` (inference) — FIXED & verified.** `ODataService`
    authorizes every lambda navigation target before evaluating the filter, via
    `ODataAuth.authorizeFilterNav(ent, q, authCtx)` (a pre-flight walk of the parsed
    filter tree, covering `$apply`'s `filter(...)` too). A denied target **rejects** the
    request (`403`) rather than silently evaluating it. Live-verified: a single-schema
    principal's `SalesOrderDetails?$filter=Product/any(p:p/Color eq 'Black')` returns
    `403 Missing scope 'AdventureWorks.Production.read'` on all three engines; the same
    query with `Sales+Production` (or `All.read`) returns the correct count (30099);
    `$apply=filter(Product/any(...))` also → 403; and a SAME-schema lambda
    (`SalesOrders?$filter=Details/any(...)`, Details∈Sales) under Sales.read is NOT
    over-blocked (200). Suite B5 = PASS (mdb + pgs).
**Severity:** high — now closed (both manifestations fixed & verified).
**Affects:** any service that registers an authorizer via `ODataAuth.setAuthorizer`.
**Discovered:** 2026-06-24; `$expand` fixed 2026-06-25; lambda vector outstanding.

## Summary

`ODataService` authorizes the **root** entity of a request but does **not**
authorize the targets reached by **relationship traversal**. A caller allowed to
read entity A can therefore reach any entity B navigable from A, **even if the
authorizer would deny B directly**. Two manifestations, same root cause:

1. **`$expand` (data disclosure):** B's fields are returned in the payload.
2. **`$filter` over a navigation — lambda `any()`/`all()` (inference):** B's
   columns can be used as a filter predicate, e.g. an under-scoped caller runs
   `SalesOrderDetails?$filter=Product/any(p: p/Color eq 'Black')` and gets the
   same result count as a fully-authorized caller — using Production data the
   authorizer would deny. No fields are returned, but it is an oracle over B.

## Confirmed exploit

AdventureWorks maps each entity to an original schema and grants access via
`AdventureWorks.<Schema>.read` scopes. With a token carrying **only**
`AdventureWorks.Sales.read`:

```
GET Customers(<id>)?$expand=Person      -> 200, includes the full Person record
                                           (Person schema; should require
                                           AdventureWorks.Person.read)
GET SalesOrderDetails(SalesOrderID=43659,SalesOrderDetailID=1)?$expand=Product
                                        -> 200, includes the full Product record
                                           (Production schema)
```

Both return the cross-schema data. Direct access is correctly denied
(`GET People -> 403`, `GET Products -> 403`), and the **navigation segment** form
is correctly denied (`GET Customers(<id>)/Person -> 403`) — only `$expand` leaks.

## Root cause

In `com/fourjs/odatalib/ODataService.4gl`, the read handlers call the authorizer
for the root entity, then apply `$expand` with no further checks:

- key-get path: `ODataService.4gl:319` — `CALL ODataExpand.apply(ent, q, result.rows)`
- collection path: `ODataService.4gl:363` — same call

`com/fourjs/odatalib/ODataExpand.4gl` contains no authorization logic
(`authorize` / `T_ODataAuthContext` are never referenced). By contrast, the
navigation-segment handler (`ODataService.4gl:~439`) re-authorizes the target via
`dispatchGet`, which is why `/Customers(id)/Person` is correctly blocked while
`?$expand=Person` is not.

## Expected behavior (consumer decision for AdventureWorks)

`200 OK` with the **unauthorized expansion silently omitted**: the root entity is
returned, allowed expands are included, and any expand whose target the authorizer
denies is dropped from the payload (no error). This keeps `$expand` a best-effort
projection rather than a hard failure. (A service could alternatively choose `403`;
the fix should make the policy clear, and ideally configurable.)

## Suggested fix

Authorize each `$expand` target before applying it, at **every** nesting level:

- In `ODataExpand.apply` (or at the two call sites in `ODataService.4gl`), for each
  requested expansion resolve the target entity, build a `T_ODataAuthContext` for it
  (operation `read`, carrying the same scopes/token from the request context), and
  call `ODataAuth.authorize`.
- On deny: **skip** that expansion (omit the nav property) rather than emitting it.
  Apply the same check recursively to nested `$expand`.
- The authorizer is already the single decision point; this just extends the
  existing root-entity check to expansion targets. No-authorizer (open) services are
  unaffected (authorize allows by default).
- Apply the SAME target-authorization to navigation properties referenced in a
  `$filter` lambda (`any()`/`all()`), in `ODataQuery`/the filter-to-SQL path: if the
  caller is not authorized for the navigation's target entity, reject the filter
  (BadRequest/403) rather than silently evaluating it. Otherwise the `$expand` fix
  alone still leaves the inference channel open.

Add a regression test: a single-scope principal expanding a cross-schema nav must
not receive the target's fields. (`tests/security_test.sh` B1 in the AdventureWorks
project already asserts this — it is currently an XFAIL pending this fix.)

## Workaround (consumers, until fixed)

If per-entity authorization matters and you cannot yet patch odatalib, do not rely
on `$expand` for isolation: either disable `$expand` across trust boundaries, or
ensure navigations never cross an authorization boundary. Direct reads and
navigation **segments** are already enforced; only `$expand` is affected.
