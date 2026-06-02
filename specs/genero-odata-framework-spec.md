# Genero OData Framework — Technical Specification

**Status:** Draft v0.1 (2026-05-29)
**Author:** Synthesised under Pia Product + Remy R&D discipline (no-hallucination / always-cite). Drafted with Mike Folcher 2026-05-29.
**For:** [Decision #4a](portfolio_executive_summary.md) — reporting embed-partner / forward investment path for GRE+GRW. Reframes the deliverable from "Power BI Reporting Bridge" to "Genero OData Framework" per Mike's 2026-05-29 reframing.
**Status note:** This is a planning spec, not a commitment. Two-engineer prototype authorisation under Decision #4a stands; this document scopes what those engineers build and surfaces the decisions still open.

---

## Executive summary

The "Power BI Reporting Bridge" deliverable in [Decision #4a](portfolio_executive_summary.md) is reframed as a **Genero OData Framework**: a Four Js-authored, BDL-language library distributed via fglpkg that lets customers expose business-logic-processed Genero data as **OData v4** services. Power BI is the v1 reference consumer; the same framework gets Tableau, Excel, Metabase, Looker, and SAP Analytics Cloud for free, since all of them consume OData natively.

The reframing was proposed by Mike on 2026-05-29 after a Q&A walking through the eight Genero-side facts that shape the architectural choice. Key facts that drove the reframing:

1. **The data customers want in Power BI is BDL-processed, not raw database rows.** Genero's report data flows from BDL business logic via `OUTPUT TO REPORT` — filters, joins, derived fields, and customer-specific transforms are all in BDL. A direct-database BI connector would bypass that logic.
2. **GAS already supports REST and SOAP web services**, but no OData framework exists in Genero today.
3. **Customer access control already lives in BDL.** Any external BI access has to honour it.
4. **No existing Power BI prototype** exists; no internal SOW or technical spike has been started.
5. **Customer database mix is Informix / Postgres / SQL Server primarily**, with a few on Oracle / MySQL / MariaDB. Multi-database support is mandatory for a credible deliverable.

Under those facts, an OData *framework* dominates a Power BI *connector* on every axis that matters for Four Js: portability across BI tools, BDL-native business-logic preservation, BDL-native access control, no Power BI licensing entanglement, multi-database support for free, and consistency with the OSS+Sunset operational pattern (Four Js ships substrate, customers compose with domain logic).

---

## What this is — one paragraph

A BDL-language library, distributed via [fglpkg](portfolio_executive_summary.md), that customers add to their Genero application to expose declared business-logic functions as OData v4 read-only endpoints. The endpoints are hosted by GAS (using GAS's existing REST web-services capability), authenticated via the customer's existing access-control model, and consumed by Power BI Desktop's built-in OData connector with zero Four-Js-authored client-side code.

---

## What this is NOT

To avoid scope drift, the following are **explicitly out of scope** for both v0 and v1:

- **Not a Power BI Embedded play.** No embedding of Power BI reports inside Genero / GBC apps. That is a different question (different licensing, different deployment model) and was rejected at this design step.
- **Not a Factur-X migration path.** Factur-X output stays in the legacy GRE engine, which is on the OSS+Sunset track for Xandres-shaped customers (FPSROW-309/310). The OData framework does not produce Factur-X output and does not interact with the Factur-X liability carve-out (per Mike 2026-05-29).
- **Not a forced migration for existing GRE/GRW reports.** Existing customer reporting on GRE/GRW continues to run; the OData framework is the forward path for *new* reporting investment. Customers with hundreds of existing GRW reports are not asked to migrate them (per [portfolio_rationalization.md §GRE+GRW](portfolio_rationalization.md) and Mike 2026-05-29).
- **Not a write API.** OData v4 write operations (POST/PATCH/PUT/DELETE) are out of scope for v0 and v1.
- **Not a database-direct connector.** Power BI does not talk to the customer's database; it talks to BDL business logic via OData. The customer's database choice is invisible.
- **Not a real-time / streaming feed.** Power BI's push-datasets and streaming-datasets APIs are not the model. OData is request/response.
- **Not a "Power BI-only" product.** The framework is BI-tool-agnostic. Power BI is the v1 reference consumer because Decision #4a named it; Tableau / Metabase / Excel / Looker are explicit second-order beneficiaries.

---

## Customer outcome

### v0 alpha (end of 3-6 month window, ≈ Sept 2026)

**One lighthouse customer has one Power BI report consuming live Genero data through the framework.** The data is BDL-processed (not raw database rows). The framework is published as an alpha fglpkg. Customer outcome stated out loud: *"We built a Power BI dashboard against our Genero data without exporting CSVs."*

### v1 GA (6+ month direction, Q1-Q2 2027)

**2-3 lighthouse customers** running OData services in production, multiple Power BI reports per customer. Framework published with full documentation; alternative consumers validated (at least one of Tableau / Metabase / Excel). GRE OSS+Sunset transition complete; OData framework is the documented forward path for new reporting investment.

---

## Strategic framing

The strategy directory has converged on three positions that this spec respects:

1. **Decision #4a:** Pick reporting embed partner (Power BI per Remy's recommendation); authorise 2-engineer prototype. ([portfolio_executive_summary.md](portfolio_executive_summary.md))
2. **GRE/GRW dual track:** Forward path = Reporting Bridge to Power BI/Metabase. Legacy continuity = OSS+Sunset GRE engine + GRW Designer via Maven + fglpkg. ([portfolio_rationalization.md §7](portfolio_rationalization.md))
3. **Kiz's anchor:** *"Not Four Js's fight vs. Power BI/Metabase."* — Four Js stops investing in a competing report engine; the bridge is the forward investment.

The OData-framework framing **strengthens** all three positions:

- **Decision #4a is honoured.** Power BI is the v1 reference consumer; a 2-engineer prototype is feasible at v0 scope. Decision #4a does not require Four Js to build a Power-BI-specific connector — it requires picking the embed partner that the prototype is validated against.
- **Dual track is preserved.** fglpkg distribution is the same channel as the OSS-GRE handoff. The framework rides the existing operational rail.
- **Kiz's "not our fight" anchor is reinforced.** Four Js doesn't build BI. Four Js ships substrate (an OData service in BDL); customers connect their BI tool of choice. This is the cleanest possible expression of the anchor.

The reframing also resolves the **6+ month "Metabase second target"** ([3-6-month-and-directional-roadmap.md §Reporting Bridge](3-6-month-and-directional-roadmap.md)). Under a framework approach, Metabase is not a second integration — it is the same framework with a different consumer. The 6+ month direction is "validate the framework with a non-Power-BI BI tool" rather than "build a second connector."

---

## Architecture

### Data flow

```
+-----------------+      HTTPS/OData       +-----------+      BDL function call      +------------------+      SQL      +----------+
|  Power BI       |  <------------------>  |   GAS     |  <----------------------->  |  Customer BDL    |  <-------->  | Customer |
|  Desktop / Pro  |   (read-only queries)  |  (OData   |   (existing GAS web-svcs)   |  service funcs   |    (existing |   DB     |
|                 |                        |  endpoint)|                              |  using framework |    BDL data  | (Ifx/PG/ |
+-----------------+                        +-----------+                              +------------------+    access)   |  MSSQL)  |
                                                ^                                              ^                        +----------+
                                                |                                              |
                                                |                                              |
                                          +-------------+                              +---------------+
                                          | OData       |                              | BDL access    |
                                          | Framework   |                              | control       |
                                          | (fglpkg)    |                              | (customer-    |
                                          | translates  |                              |  authored)    |
                                          | OData query |                              +---------------+
                                          | to BDL call |
                                          +-------------+
```

### Genero-side components (what 2 engineers build)

1. **OData Framework BDL library** — published via fglpkg as `4js-odata-framework` (or similar). Four-Js-authored. Two halves:
   - **Request parser** — parses incoming OData query strings (`$filter`, `$select`, `$top`, `$skip`, `$orderby`, `$count`, shallow `$expand`) into a normalised BDL-callable form. Validates against the declared schema. Rejects unsupported operators with proper OData error responses.
   - **Response serialiser** — takes BDL function output and emits OData-compliant JSON (default) or AtomPub XML. Generates `$metadata` (CSDL) documents from the declared schema. Manages server-driven paging via `@odata.nextLink`.

2. **Schema declaration mechanism** — *(decision open, see §Open questions)*. Three candidates:
   - **(a) BDL annotations on RECORD types** — most "Genero-native"; heaviest framework engineering (BDL doesn't have first-class attribute annotations on RECORD members today, so this would either require a Four Js-authored pre-processor or a convention-over-configuration approach reading from a parallel `.4st` schema file).
   - **(b) Separate `.odata` config file** — declarative YAML/JSON/XML config that maps BDL functions and RECORD types to OData entities. Lighter framework engineering, requires customers to maintain two files in sync.
   - **(c) Reflection from BDL function signatures** — framework introspects BDL function signatures at runtime/startup and generates the OData metadata. Magical but fragile.

   **Recommendation for v0:** option (b) — separate `.odata` config — as the pragmatic choice. Option (a) gets evaluated for v1 if customers ask for it.

3. **GAS hosting integration** — the framework registers OData endpoints with GAS's existing web-services machinery (the same surface that hosts customer REST and SOAP endpoints today, per Mike 2026-05-29). No new GAS-level capability required; the framework is a BDL library that *uses* GAS web services.

4. **Authentication shim** — bridges Power BI Desktop's OData auth options (Anonymous / Basic / Windows / OAuth2) to GAS's existing authentication and customer BDL access-control hooks. v0 supports HTTP Basic + BDL access-control gating; v1 adds OAuth2.

5. **Reference example app** — a small Northwind-style sample BDL app that exposes an OData service. Used internally for testing and shipped publicly for customer onboarding.

### Power BI-side components

**None — Four Js authors zero Power-BI-side code.** Customers use Power BI Desktop's built-in **OData connector** (Get Data → OData feed), enter the URL of their Genero OData endpoint, authenticate, and the customer's declared entities appear in Power BI's query builder.

This is the strategic point of the framework framing: Power BI on the consumer side is unmodified. Tableau, Metabase, Excel are similarly unmodified.

### v0 supported OData v4 surface

OData v4 is a large specification. v0 ships a focused read-only subset that covers ≥90% of common BI-tool query patterns:

- **Service document** — `GET /odata/{service}` listing entity sets
- **Metadata document** — `GET /odata/{service}/$metadata` returning CSDL XML (and JSON metadata for v4.01 clients)
- **Entity collection** — `GET /odata/{service}/{Entity}` with query options:
  - `$filter` — operators: `eq`, `ne`, `gt`, `lt`, `ge`, `le`, `and`, `or`, `not`, `contains`, `startswith`, `endswith`
  - `$select` — column projection
  - `$top`, `$skip` — pagination
  - `$count=true` — total count
  - `$orderby` — single-column ordering, asc/desc
  - `$expand` — one-level navigation property expansion (shallow only)
- **Single entity** — `GET /odata/{service}/{Entity}({key})`
- **Server-driven paging** — `@odata.nextLink` honoured; default page size 200 rows, configurable per-entity up to 1000
- **Error responses** — OData-compliant JSON error envelopes with proper HTTP status codes

### v0 unsupported OData v4 features (and the reason)

- **Write operations** (POST/PATCH/PUT/DELETE) — read-only v1 keeps the spec smaller and the customer access-control story tractable. Write APIs warrant their own design pass.
- **`$batch`** — adds significant framework complexity; not in BI-tool consumer paths
- **Deep `$expand`** (multi-level navigation) — performance ceiling concerns
- **`$lambda` operators** (`all/`, `any/`) — query-translation complexity
- **Change tracking / delta queries** — needs server-side state
- **Actions and functions** — needs write APIs; out of scope
- **Aggregation extensions** (`$apply`) — BI tools generally do their own aggregation client-side; revisit in v1 if customer evidence points here

---

## Authentication and access control

Power BI Desktop's OData connector supports four authentication modes: **Anonymous, Basic, Windows, OAuth2**. The framework must surface at least one that integrates with the customer's existing BDL access control.

### v0 (alpha)

- **HTTP Basic over HTTPS** as the primary mechanism. Customer's existing BDL access-control hooks gate the OData calls — same gating that protects GAS REST endpoints today.
- **Anonymous mode supported** for customer-owned read-only public datasets (rare; documented as "use at your own risk").
- **Windows / NTLM auth supported** for on-premises deployments where customers want existing AD credentials to flow through.

### v1 (GA)

- **OAuth2 with customer IdP integration.** This is the production-grade story. Framework integrates with GAS's existing identity-provider hooks (whatever they are — needs Remy to confirm what GAS provides out of the box; flagged as Open Question).
- **Token-based service-account access** for non-interactive Power BI refresh scenarios (Power BI Service scheduled refresh).

### Access-control invariant

**BDL is the gatekeeper.** The framework does not bypass customer access control. Every OData query routes through customer-authored BDL functions, which enforce the customer's existing role-based / row-level filtering. This is the single biggest reason to prefer an OData framework over a direct-database BI connector: a direct-DB connector exposes all rows and forces row-level security to be re-implemented in the BI tool's semantic layer; OData over BDL reuses the access control customers already have.

---

## Performance characteristics

The honest tradeoff of routing through BDL is performance vs. direct-DB connectivity. Spec needs to set realistic expectations.

### What's true

- **BDL-routed queries are slower than direct-DB queries.** Every OData GET routes Power BI → GAS → BDL function → DB. Latency adds: roughly 50-200ms per query overhead beyond the underlying DB query time.
- **Power BI Import mode is the recommended consumption pattern.** Customers configure Power BI to cache (Import) the OData dataset and refresh periodically (hourly, daily, on-demand). This is how 90% of OData BI deployments work in the wild — DirectQuery against OData is feasible but only for small datasets.
- **Server-side pagination is mandatory.** Power BI will attempt to fetch the full collection if pagination is not honoured. Default page size 200; cap at 1000 per-entity.
- **Customer-authored aggregation is the right pattern for large datasets.** A customer with a 5M-row transactions table should expose an aggregated "DailyTransactionSummary" entity (the BDL function pre-aggregates) rather than the raw table. Document this as the recommended pattern.

### What's a ceiling

- **DirectQuery against >50k rows** will be slow and is documented as "not recommended."
- **Multi-million-row Import refresh** will work but takes minutes-to-tens-of-minutes depending on DB and BDL function complexity.
- **High-concurrency Power BI Service refresh** (e.g., 50 customers refreshing simultaneously) puts load on GAS that needs to be sized at deployment.

These are not framework defects — they are inherent to BI-over-business-logic-layer designs. The spec is honest about them so customer expectations are set.

---

## Multi-database support

The framework does not talk to the customer's database directly. **BDL talks to the database.** Customer's choice of Informix, Postgres, SQL Server, Oracle, or MySQL/MariaDB is invisible to the framework — and therefore invisible to Power BI.

This is a real strategic advantage:

- **No per-database driver work.** A direct Power BI connector would need DirectQuery support per DB engine — non-trivial.
- **Customers migrating Informix → Postgres** (per the [Informix→Postgres initiative](informix_to_postgres_growth_initiative.md), referenced for context — that PS work is out of scope for this roadmap document) don't need to re-author their OData service; their BDL business logic keeps working with a new DB connection.
- **The framework works the day GAS supports the database**, which is already the customer's existing reality.

---

## Distribution and operationalisation

### fglpkg distribution

The framework ships as an fglpkg package. This is consistent with the [GGC OSS+Sunset](portfolio_executive_summary.md), [GRE OSS+Sunset](portfolio_rationalization.md), and (eventually) BDL partial-OSS distribution channels. **fglpkg productisation itself is still a PoC** (memory fact #2) — the framework cannot ship via fglpkg until fglpkg has a credible release path. Flagged as a dependency in Open Questions.

### Internal documentation

- **Reference example app** — a small Northwind-style sample exposing 3-4 entities. Shipped in the framework's repo.
- **Authoring guide** — how a customer adds the framework to their BDL app, declares a schema, and exposes an OData endpoint. Targets the Sam-shaped technical lead (`persona-03`) — comfortable with BDL, comfortable with REST concepts, less comfortable with OData spec arcana.
- **Power BI consumption guide** — screenshots of Power BI Desktop → Get Data → OData feed → enter URL → authenticate → drag entity. Two pages, not twenty.

### Public Maven publication (v1)

In the v1 GA window, the framework publishes to Maven Central (or a similar public package channel) alongside the OSS-handed-off GRE engine. This is the moment "Four Js ships BDL libraries to the open ecosystem" becomes a real operational pattern, with the OData framework as one of the first inhabitants.

---

## Scope and timing

### 3-6 month window (v0 alpha)

**Resourcing:** 2 engineers, full-time, for the window (per Decision #4a authorisation).

**Deliverables:**
- OData Framework v0 (read-only subset of OData v4, HTTP Basic / Windows / Anonymous auth, `.odata` config-file schema declaration)
- Reference example app
- Internal authoring guide
- Power BI consumption walkthrough
- **One lighthouse customer** running **one Power BI report** in production
- Alpha fglpkg published *(conditional on fglpkg productisation — see Open Questions)*

**Customer-felt outcome:** *one lighthouse customer demos a Power BI dashboard against live Genero data at the end of the window.*

### 6+ month direction (v1 GA)

- **OData Framework v1**: annotation-driven schema declaration (if v0 customer feedback warrants), OAuth2/IdP integration, comprehensive docs, Maven publication
- **2-3 lighthouse customers** running production OData services
- **At least one non-Power-BI consumer validated** (Tableau, Metabase, or Excel) to prove the BI-tool-agnostic claim
- **GRE OSS+Sunset transition complete** — OData framework is the documented forward path for new reporting investment in customer-facing materials
- **Customer-side migration patterns documented** for the small percentage of customers who voluntarily want to replace GRE/GRW reports with Power BI reports against the OData framework

Per Mike 2026-05-29: *"Maybe this is a 6+ month project. There will probably be some work to get GRE OSS and shifted to this model."* The v0/v1 split honours that — v0 is the alpha demonstrating the approach works; v1 is the production framework after the GRE OSS handoff is well underway.

### Roadmap impact

The [3-6 month and directional roadmap](3-6-month-and-directional-roadmap.md) GRE+GRW row should be **downgraded** from *"Power BI Reporting Bridge prototype in production at 1-2 customers (Decision #4a); Factur-X Xandres SOW completes"* to:

> *"**Genero OData Framework v0 alpha** shipped via fglpkg; **one lighthouse customer running one Power BI report against live Genero data**; Factur-X Xandres SOW (`FPSROW-309/310`) completes in legacy GRE track."*

The 6+ month direction column should be:

> *"**Genero OData Framework v1 GA** with 2-3 lighthouse customers + at least one non-Power-BI consumer validated (Tableau / Metabase / Excel); Maven publication; OData framework documented as the official forward path for new reporting investment; GRE+GRW engine OSS+Sunset comms Q4 2026."*

This re-framing is more honest about what's achievable and more strategically valuable than the original "Power BI Reporting Bridge" framing. Spec update to the roadmap is a follow-on edit once this spec lands.

---

## Lighthouse customer profile

No candidates are committed (per Mike 2026-05-29). The spec recommends evaluating customers against this profile:

- **Has Power BI tenant + Power BI Pro licenses** (or willingness to acquire). Customers without Power BI today are wrong for v0 — too many variables.
- **Has a Genero BDL app with reporting needs GRE doesn't well serve.** Modern dashboards, drill-down interactivity, cross-product analytics — these are Power-BI-shaped requirements that GRE struggles with.
- **Has IT willingness to author OData service definitions.** This is a Sam-shaped (`persona-03`) customer — a technical lead comfortable with BDL who can write a few hundred lines of BDL service code.
- **Has a single, well-defined reporting use case** to be the v0 prototype scope. Customers wanting "replace all our existing GRW reports" are wrong for v0 — that's a v1+ ask.
- **Has IT-realistic Power BI auth** — either an AAD tenant they administer, or willingness to use HTTP Basic over HTTPS for the alpha.

**Candidate evaluation needed** (not committed, to be Pia-owned):
- **Reece** — historically a heavy GRE user per the persona corpus; possibly motivated to evaluate alternatives.
- **SBS** — Cleis-anchored persona (`persona-03 Riley`); known modernisation appetite per [outlook doc](four-js-outlook-and-pivot-assessment.md).
- **One ATS or Versaterm-shaped customer** — both have existing Genero deployments with reporting; Versaterm's substrate-trust concerns might make this a less attractive ask there, but ATS is a candidate.

Customer-selection step is part of Pia's lighthouse-program work in the [outlook doc](four-js-outlook-and-pivot-assessment.md); the spec does not commit to a customer here.

---

## Open questions and decisions needed before commit

Items that need a real answer before this spec moves from draft to commit:

1. **Schema declaration mechanism** — config file (option b) vs annotations (option a) vs reflection (option c). Spec recommends config file for v0; needs Remy R&D confirmation that this fits cleanly with GAS web-services machinery.
2. **OAuth2 integration with GAS** — what does GAS provide out of the box for IdP integration? If GAS has an OAuth2 surface already, v0 can include OAuth2. If GAS needs that capability built first, OAuth2 slips to v1. **Needs Remy answer.**
3. **fglpkg alpha-tier distribution** — fglpkg productisation is itself a PoC (memory fact #2). The OData framework v0 alpha distribution is gated on fglpkg being able to ship alpha packages. **Needs Decision #7 fglpkg productisation status.**
4. **GAS REST web-services surface details** — Mike confirmed GAS supports REST and SOAP. The OData framework will plug into the existing REST surface; the integration shape needs Remy to confirm (e.g., does the existing GAS REST framework support custom URL routing patterns like `/odata/{service}/{Entity}`?).
5. **Performance benchmark** — before customer commit, a representative benchmark on Informix and Postgres (the two most common DB choices per Mike 2026-05-29) for: 100k-row entity, 1M-row entity (with `$top=1000` server-paged), `$filter` over indexed and non-indexed columns. Sets honest expectations with the lighthouse customer.
6. **Two-engineer ceiling realism for v0** — the v0 scope laid out here (request parser + response serialiser + config-driven schema + Basic auth + reference app + docs + one customer deployment) is **achievable but tight** for 2 engineers in 3-6 months. If Decision #4a's 2-engineer authorisation is firm, the scope is right-sized; if engineers have other commitments (which is the [capacity-headroom caveat](portfolio_executive_summary.md) Reuben surfaced), v0 timeline slips by 2-3 months and v1 GA moves accordingly.
7. **Lighthouse customer pre-commit cost** — the lighthouse customer commits engineering time to author the OData service against their BDL app. Estimate: 1-2 weeks of customer engineering. Needs to be in the Pia-owned customer pitch.
8. **OData spec licensing and conformance positioning** — OData v4 is an OASIS standard with no licensing fees, but Four Js stating "OData v4 conformant" carries implicit obligations. Spec recommends positioning as "OData v4 *compatible* with a read-only subset" rather than "OData v4 *conformant*" until v1.

---

## Risks

| Risk | What it would invalidate | Watch signal |
|---|---|---|
| **fglpkg productisation slips** | v0 alpha has no distribution channel; framework ships internally only | fglpkg release-readiness gate (Decision #7) by month 3 |
| **GAS REST surface insufficient for OData routing** | Framework needs custom GAS-level work, blowing the 2-engineer scope | Remy R&D feasibility confirmation before engineering kicks off |
| **OAuth2 integration with GAS doesn't exist** | v1 GA slips by 3-6 months while GAS gets IdP integration | GAS auth-roadmap clarity with Remy by month 4 of v0 |
| **No lighthouse customer signs in 3-6 month window** | v0 demo is internal-only; alpha never validates against real customer data shape | Pia-owned customer feasibility pipeline by month 3 |
| **Performance ceiling discovered late** | Lighthouse customer's actual dataset is too large for Import-mode refresh windows | Benchmark on Informix + Postgres by month 4 |
| **OData spec depth needed beyond v0 subset** | Customers ask for `$batch` / deep `$expand` / actions, v0 scope is too thin | Customer authoring feedback from internal reference app + first customer eval |
| **Power BI introduces a competing native Genero connector** | OData framework's positioning weakens — Microsoft owns the customer experience | Unlikely (Microsoft does not build per-ERP connectors at this market scale), but watch for Power BI Custom Connector certified-partner program changes |

---

## Where this analysis is least certain

- **The GAS REST web-services architecture is not detailed in this spec.** Mike confirmed GAS supports REST and SOAP at a high level; the framework's integration shape depends on specifics (URL routing patterns, request/response lifecycle hooks, auth flow) that need Remy R&D walkthrough.
- **OData v4 subset choices are best-judgement, not customer-validated.** The 90% claim for the v0 subset is based on common BI-tool query patterns in the wild, not on a Genero-customer-specific study. First lighthouse customer feedback will sharpen this.
- **Schema declaration mechanism is a real design fork**, not a settled choice. Config file is the spec's recommendation for v0 pragmatism; if customers strongly prefer annotation-driven, v1 might revisit. Three real options on the table; only one becomes the v0 path.
- **The "OData = Tableau + Metabase + Excel for free" claim is true at the protocol level**, but BI-tool-specific quirks always exist (Tableau's web data connector path, Metabase's plugin model, Excel's Power Query integration). v1 validation against at least one non-Power-BI consumer is required to prove the claim, not assume it.
- **Customer access control via BDL has not been characterised in detail** in this spec. The assertion that "BDL is the gatekeeper" is correct at the architectural level; the framework needs to test it against real customer access-control implementations (which vary per customer) during v0.
- **Performance numbers in §Performance characteristics are order-of-magnitude estimates**, not measured. Benchmark step in v0 makes them real.

---

## Sources

- [`portfolio_executive_summary.md`](portfolio_executive_summary.md) — Decision #4a; 2-engineer prototype authorisation
- [`portfolio_rationalization.md` §7 GRE+GRW](portfolio_rationalization.md) — dual-track framing; OSS+Sunset legacy continuity
- [`portfolio_contrast.md`](portfolio_contrast.md) — Kiz "not Four Js's fight vs. Power BI/Metabase" anchor
- [`3-6-month-and-directional-roadmap.md` §Reporting Bridge](3-6-month-and-directional-roadmap.md) — current placement of Power BI Reporting Bridge in 3-6 month window
- [`four-js-outlook-and-pivot-assessment.md` §GRE+GRW dual track](four-js-outlook-and-pivot-assessment.md) — decision pack framing
- [`product_synopses.md` §GRE / GRW](product_synopses.md) — product context; failed external-sales experiment + shallow-usage evidence
- **Mike Folcher 2026-05-29 Q&A** — 8 Genero-side facts that drove the OData-framework reframing:
  1. Data source = BDL business logic via `OUTPUT TO REPORT`, not raw database
  2. GAS supports REST and SOAP web services; no OData framework today
  3. "Browser-native PDF" = Power BI's built-in Export to PDF (out of scope for Four Js)
  4. No lighthouse customer candidates committed; selection depends on technical readiness
  5. Factur-X stays entirely in legacy GRE / OSS+Sunset
  6. No customer migration pressure for existing GRE/GRW reports
  7. No existing Power BI prototype
  8. Customer database mix: Informix / Postgres / SQL Server primarily; few on Oracle / MySQL / MariaDB
- **OData v4 specification** — OASIS standard (Part 1: Protocol, Part 2: URL Conventions, Part 3: CSDL JSON)
- **Power BI OData connector** — Power BI Desktop's built-in OData feed connector documentation

---

*Spec drafted 2026-05-29 under Pia Product + Remy R&D no-hallucination / always-cite discipline. Originated as "Power BI Reporting Bridge spec" per [Decision #4a](portfolio_executive_summary.md); reframed by Mike Folcher 2026-05-29 to "Genero OData Framework" after Q&A walked through the eight Genero-side facts that make a BDL-language OData framework dominate a Power-BI-specific connector on portability, business-logic preservation, access-control reuse, licensing simplicity, and multi-database support. v0 alpha targets one lighthouse customer running one Power BI report by end of 3-6 month window; v1 GA targets 2-3 lighthouse customers + at least one non-Power-BI consumer validated. Companion to [`portfolio_executive_summary.md`](portfolio_executive_summary.md) and [`3-6-month-and-directional-roadmap.md`](3-6-month-and-directional-roadmap.md). Open questions and risks named explicitly; needs Remy R&D feasibility walkthrough before commit. Intended as input to the next Product Strategy Council review.*
