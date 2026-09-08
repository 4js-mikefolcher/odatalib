# Resolved in v1.0.2: `$filter` on an `Edm.Boolean` column failed on PostgreSQL

> **This issue is FIXED.** It is kept as an engineering record of the bug and
> its cross-engine fix. odatalib **v1.0.2 and later are not affected**;
> releases up to and including v1.0.1 were. Past tense below describes the
> pre-fix behaviour.

**Status:** FIXED & verified (2026-06-25). `bindParam` now binds `Edm.Boolean` as a
real boolean. Re-tested on all three engines: `SalesOrders?$filter=OnlineOrderFlag eq
true` → 27659, `eq false` → 3806 (sum 31465 = total) on MariaDB, PostgreSQL **and**
Oracle. PostgreSQL no longer errors (-6372). Bonus: the fix also corrected a latent
**correctness** bug — pre-fix MariaDB bound the boolean as text `'true'`, which MySQL
coerced to 0, so `eq true` wrongly returned the `false` rows (3806).
**Affects (pre-fix):** PostgreSQL erred (-6372); MariaDB returned wrong rows; Oracle was correct.
**Discovered:** 2026-06-24, testing the flattened AdventureWorks service across MariaDB / PostgreSQL / Oracle.

## Symptom

A `$filter` that compares a boolean property errors only on PostgreSQL:

```
GET SalesOrders?$filter=OnlineOrderFlag eq true&$count=true
  MariaDB   -> 200, @odata.count = 3806
  Oracle    -> 200, @odata.count = 27659
  PostgreSQL-> 500, "Database error (SQLCODE -6372)"
```

The PostgreSQL server-side error is a type mismatch of the form
`operator does not exist: boolean = text`.

Non-boolean filters (string, integer, decimal, and `and`/`or`/`not`/grouping/
functions over them) work on all three engines — this is specific to columns
typed `Edm.Boolean` in the `.odata` config.

## Root cause

WHERE values are sent as **bound parameters**, typed by their Edm type in
`bindParam()` (`com/fourjs/odatalib/ODataSqlProvider.4gl`). There is no
`Edm.Boolean` branch, so a boolean literal falls through to `OTHERWISE` and is
bound as a **string**:

```genero
    CASE edmType
        WHEN "Edm.Int16"   ...
        WHEN "Edm.Int32"   ...
        WHEN "Edm.Decimal" ...
        WHEN "Edm.Date"    ...
        OTHERWISE
            # Edm.String, Edm.Boolean, Edm.Guid, Edm.DateTimeOffset, unknown
            CALL sqlObj.setParameter(idx, val)   -- binds "true"/"false" as TEXT
    END CASE
```

So the generated predicate is effectively `WHERE "onlineorderflag" = $1` with `$1`
sent as the text `'true'`. PostgreSQL is strictly typed and will not implicitly
compare a `boolean` column to a `text` parameter, so it raises
`operator does not exist: boolean = text`. MariaDB (column is `TINYINT(1)`) and
Oracle (emulated via `ifxemul`, `NUMBER`/`CHAR`) silently coerce the string, so
they don't error — though their coercion semantics differ and are themselves
fragile.

This is the same class of strict-typing problem as the double-quote-dialect
identifier issue (see the `dblquotes=false` note in the project README): behaviour
that "just works" on MariaDB is rejected by PostgreSQL.

## Reproduce

```bash
# Any entity with an Edm.Boolean property; AdventureWorks SalesOrders.OnlineOrderFlag.
curl -s "<base>/SalesOrders?\$filter=OnlineOrderFlag%20eq%20true&\$count=true"
# PostgreSQL -> {"error":{"code":"...","message":"Database error (SQLCODE -6372)"}}
```

## Suggested fix

Add an explicit `Edm.Boolean` branch to `bindParam()` that binds a real boolean,
normalising the OData literals `true`/`false` (and the numeric `1`/`0`). A `DEFINE`
must precede the first executable statement of the function, so declare the
`BOOLEAN` alongside `iv`/`bv`/`fv`/`dv`/`dt` at the top (a block-scoped
`VAR boolv BOOLEAN = …` inside the `WHEN` arm would also be legal, but `DEFINE`
keeps this branch consistent with the ones above):

```genero
    DEFINE iv INTEGER
    ...
    DEFINE dt DATE
    DEFINE boolv BOOLEAN          -- with the other bind locals
    ...
    CASE edmType
        ...
        WHEN "Edm.Boolean"
            LET boolv = (val.toLowerCase() == "true" OR val == "1")
            CALL sqlObj.setParameter(idx, boolv)
```

Binding a Genero `BOOLEAN` lets the ODI driver send a dialect-correct parameter
(PostgreSQL `boolean`, and the appropriate `TINYINT`/`NUMBER` mapping for
MariaDB/Oracle), instead of a text literal.

**Verify the fix on all three drivers**, since boolean binding is exactly where
they diverge:

- MariaDB: `OnlineOrderFlag eq true` should still return 3806.
- Oracle: should still return 27659.
- PostgreSQL: should now return a count instead of -6372.

If a Genero `BOOLEAN` bind turns out not to map cleanly on every driver, the
fallback is to render boolean comparisons as inline SQL literals (`= TRUE` /
`= FALSE`) for the double-quote dialects rather than as bound parameters.

Also add a regression case (a boolean `$filter`) to the portability suite
(`tests/portability_test.4gl`) so this is caught cross-engine in future.

## Workaround (consumers)

Until fixed, avoid boolean comparisons in `$filter` against the PostgreSQL
backend. Filter on a correlated non-boolean column, or post-filter client-side.
