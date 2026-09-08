# Resolved issues

Engineering records of defects that have been **fixed and verified**. They are
kept for provenance — what the bug was, how it was exploited or reproduced, and
what the fix changed — so consumers can tell which releases were affected.

Nothing in this directory is an open issue. Each document names the release that
carries its fix.

| Issue | Affected | Fixed in |
|-------|----------|----------|
| [Relationship traversal bypassed the authorizer](expand-authorization-bypass.md) — `$expand` / `$filter` lambda cross-entity disclosure | ≤ v1.0.1 | **v1.0.2** |
| [`$filter` on an `Edm.Boolean` column failed on PostgreSQL](postgres-boolean-filter.md) — and returned wrong rows on MariaDB | ≤ v1.0.1 | **v1.0.2** |

Open issues, if any, are tracked in the GitHub issue tracker and summarised
under *Limitations & roadmap* in the [README](../../README.md).
