---
topic: Go PostgreSQL driver ecosystem
date: 2026-04-06
source_repos:
  - https://github.com/lib/pq
  - https://github.com/jackc/pgx
  - https://github.com/jmoiron/sqlx
  - https://github.com/sqlc-dev/sqlc
  - https://github.com/go-gorm/gorm
  - https://github.com/uptrace/bun
tags: [go, postgresql, pgx, lib-pq, sqlx, sqlc, gorm, bun, orm, enterprise]
status: reviewed
---

# Go PostgreSQL Driver & Data Access Ecosystem

A comprehensive analysis of Go's PostgreSQL driver, ORM, and query tool landscape — with enterprise standardization recommendations.

---

## Table of Contents

1. [lib/pq](#1-libpq)
2. [pgx](#2-pgx)
3. [go-pg / Bun](#3-go-pg--bun)
4. [GORM](#4-gorm)
5. [sqlx](#5-sqlx)
6. [sqlc](#6-sqlc)
7. [Enterprise Standardization Analysis](#7-enterprise-standardization-analysis)

---

## 1. lib/pq

**GitHub:** [github.com/lib/pq](https://github.com/lib/pq) | **Stars:** ~9,845 | **Latest:** v1.12.3 (Apr 2026)

### Maintenance Status

Officially in maintenance mode. The README states:

> "This package is currently in maintenance mode, which means: It generally does not accept new features. It does accept bug fixes and version compatibility changes provided by the community. Maintainers usually do not resolve reported issues."

> "For users that require new features or reliable resolution of reported bugs, we recommend using pgx which is under active development."

This notice was added April 2020 (commit c782d9f). Bug-fix releases continue, but no new features.

### Key Limitations

| Limitation | Impact |
|---|---|
| No `DialFunc` | Cannot inject custom dialers for SSH tunnels, SOCKS proxies, Cloud SQL connectors, or IAM auth |
| Global driver registry | `init()` registration — one config per driver name per process |
| Text-only protocol | No binary encoding; more parsing overhead, slower throughput |
| No statement caching | Full Parse-Bind-Execute cycle on every parameterized query |
| No built-in pooling | Relies entirely on `database/sql`'s pool (no hooks, health checks) |
| No batch queries | Cannot send multiple queries in a single round trip |
| Limited type support | Fewer native PostgreSQL type mappings than pgx |

---

## 2. pgx

**GitHub:** [github.com/jackc/pgx](https://github.com/jackc/pgx) | **Stars:** ~13,580 | **Latest:** v5.9.1 (Mar 2026) | **Go:** 1.25+ | **PostgreSQL:** 14+

### Key Differentiators

- ~70 PostgreSQL types supported natively (arrays, hstore, jsonb, inet/cidr, UUID, etc.)
- Automatic statement preparation and caching (~3x QPS for repeated query patterns)
- Binary wire format (eliminates text parsing overhead)
- Batch queries (multiple queries in one round trip)
- COPY protocol for bulk loads
- LISTEN/NOTIFY first-class support
- Tracing interfaces (BatchTracer, CopyFromTracer, PrepareTracer)
- Savepoint-based nested transactions

### The stdlib Adapter (pgx/v5/stdlib)

Registers pgx as a `database/sql` driver. Migration from lib/pq is often:

```go
// Before
import _ "github.com/lib/pq"
db, err := sqlx.Open("postgres", connStr)

// After
import "github.com/jackc/pgx/v5/stdlib"
config, _ := pgx.ParseConfig(connStr)
db := sqlx.NewDb(stdlib.OpenDB(*config), "pgx")
```

All existing `sql.DB` / `sqlx.DB` code continues to work. For advanced operations (COPY, batch), escape via `(*sql.Conn).Raw()` to the native `*pgx.Conn`.

### Connection Pooling (pgxpool)

| Setting | Default | Purpose |
|---|---|---|
| MaxConns | max(4, NumCPU) | Maximum pool size |
| MinConns | 0 | Minimum idle connections |
| MaxConnLifetime | 1h | Max connection age |
| MaxConnIdleTime | 30m | Idle timeout |
| HealthCheckPeriod | 1m | Background health checks |

Lifecycle hooks: `BeforeConnect`, `AfterConnect`, `BeforeAcquire`, `AfterRelease`, `BeforeClose`, `PrepareConn`.

### DialFunc and Hooks

- `pgconn.Config.DialFunc` — custom dialer injection (Cloud SQL Go Connector uses this for IAM auth)
- `pgconn.Config.TLSConfig` — full `*tls.Config` control with sslmode fallback
- `ValidateConnect` — post-auth callback to verify server
- `AfterConnect` — post-connection setup (LISTEN, SET commands)
- `OnNotification` — async notification handler

### Performance vs lib/pq

| Mode | Improvement over lib/pq |
|---|---|
| pgx native | 50-100% faster |
| pgx via stdlib | 10-20% faster |

Advisory lock benchmarks: 69% in 2-4ms (lib/pq) → 61% in 0-2ms (pgx). Batch queries: 96.95% sub-2ms (pgx) vs 85.65% (lib/pq).

### Downsides

- PostgreSQL-only — pgx native API locks out multi-database support
- Larger API surface (pgxpool, pgconn, pgtype, stdlib, tracers)
- Breaking changes between major versions (v4→v5 required non-trivial migration)
- Native API is not `database/sql` — code cannot swap to MySQL/SQLite without rewrite

---

## 3. go-pg / Bun

### go-pg

**GitHub:** [github.com/go-pg/pg](https://github.com/go-pg/pg) | **Stars:** ~5,786 | **Status:** Maintenance mode

The README states: *"go-pg is in a maintenance mode and only critical issues are addressed. New development happens in Bun repo."* Last push: November 2025.

### Bun

**GitHub:** [github.com/uptrace/bun](https://github.com/uptrace/bun) | **Stars:** ~4,738 | **Latest:** v1.2.18 (Feb 2026)

SQL-first ORM. Queries look closer to SQL than GORM's method-chaining. Supports PostgreSQL, MySQL, MariaDB, SQLite. Uses `database/sql` under the hood (works with pgx/stdlib).

Key features: model struct mapping, split query types (SelectQuery, InsertQuery, etc.), built-in migration system, relation support, soft deletes, fixtures.

**Bun vs pgx:** Bun is an ORM layer on top of `database/sql` — it complements pgx/stdlib, it does not replace pgx. For direct query execution, pgx native is always faster.

---

## 4. GORM

**GitHub:** [github.com/go-gorm/gorm](https://github.com/go-gorm/gorm) | **Stars:** ~39,640 | **Latest:** v1.31.1 (Nov 2025)

The most popular Go ORM by far. Its PostgreSQL driver (`gorm.io/driver/postgres`) uses pgx/v5/stdlib internally.

### Strengths

- **AutoMigrate** for dev/prototyping — creates/alters tables from Go structs
- **Associations** — belongs-to, has-one, has-many, many-to-many with Preload/Joins
- **Hooks** — full lifecycle (BeforeCreate, AfterCreate, etc.)
- **Ecosystem** — largest community, extensive plugins, documentation

### Weaknesses

| Issue | Detail |
|---|---|
| Performance | 30-50% slower than pgx at scale due to reflection |
| N+1 queries | Without explicit Preload/Joins, associations trigger per-record queries |
| Debugging | Generated SQL is not obvious from Go code |
| AutoMigrate | Cannot handle drops, type changes, or complex migrations — unsuitable for production |
| Implicit behavior | Zero-value handling, soft deletes, auto-timestamps can surprise |

### Enterprise Assessment

Good for internal tools, admin panels, and low-throughput services. High-throughput production services frequently migrate away from GORM. Teams end up mixing GORM + raw SQL, creating inconsistency.

---

## 5. sqlx

**GitHub:** [github.com/jmoiron/sqlx](https://github.com/jmoiron/sqlx) | **Stars:** ~17,564 | **Latest:** v1.4.0 (Apr 2024)

A set of extensions on `database/sql`. Explicitly not an ORM. Sits on top of `database/sql` and makes it more ergonomic.

### Key Features

- **Struct scanning:** `Get` (single row → struct) and `Select` (rows → slice) with `db` tag mapping
- **Named queries:** `:first_name` syntax, `NamedExec`, `NamedQuery`
- **`sqlx.In`:** Expands slice arguments for `IN (?)` clauses
- **Rebind:** Converts `?` placeholders to `$1, $2` for PostgreSQL

### Why It's Popular

Zero magic — you write SQL, you know what runs. Thin layer, easy to audit. Works with any `database/sql` driver. Gentle learning curve from raw `database/sql`.

### Pairing with pgx

Since pgx/stdlib registers as a `database/sql` driver, sqlx works on top seamlessly: pgx's performance + binary protocol underneath, sqlx's ergonomic scanning on top. This is one of the most popular combinations in production Go.

### Concerns

Development has slowed (last release April 2024, last push August 2024). No query building — raw SQL strings with runtime errors. Reflection-based scanning (minimal overhead, but not zero).

---

## 6. sqlc

**GitHub:** [github.com/sqlc-dev/sqlc](https://github.com/sqlc-dev/sqlc) | **Stars:** ~17,302 | **Latest:** v1.30.0 (Sep 2025)

SQL-first code generation. Write SQL queries in `.sql` files, sqlc generates type-safe Go code at build time.

### How It Works

```
1. Define schema in SQL migration files
2. Write queries with annotations: -- name: GetUser :one
3. Run `sqlc generate` (< 100ms)
4. Generated: model structs, Querier interface, query functions with proper types
```

sqlc uses PostgreSQL's actual query parser (via pg_query_go) to validate SQL against your schema at generation time.

### pgx Integration

First-class support via `sql_package: "pgx/v5"` in sqlc.yaml. Generated code targets pgx types directly. sqlc queries and raw pgx calls coexist in the same transaction.

### Strengths

- Compile-time SQL validation (invalid columns, type mismatches caught before runtime)
- Zero reflection at runtime — generated code is as fast as hand-written pgx
- `sqlc vet` in CI verifies queries stay valid as schema evolves (~4s in GitHub Actions)
- Incremental adoption — mix with raw pgx freely
- Configuration: `emit_json_tags`, `emit_interface`, custom type overrides

### Limitations

| Limitation | Detail |
|---|---|
| Dynamic queries | No mechanism for dynamic WHERE clauses or optional filters — the Achilles heel |
| No schema management | Validates against schema but does not run migrations |
| SQL knowledge required | Teams unfamiliar with SQL will struggle |
| Generated code churn | Schema changes regenerate code, noisy PR diffs |
| Naming conventions | Query naming and file organization require team standards |

Workaround for dynamic queries: CASE statements with boolean flags, or multiple query variants. A query with 5 optional filters produces combinatorial complexity.

---

## 7. Enterprise Standardization Analysis

### Option Comparison

| Stack | Best For | Performance | Migration Cost | SQL Control | Type Safety |
|---|---|---|---|---|---|
| **pgx/stdlib + sqlx** | Migrating from lib/pq | Good (10-20% over lib/pq) | Lowest | Full (raw SQL) | Runtime only |
| **pgx native** | Performance-critical services | Best (50-100% over lib/pq) | Medium | Full | Runtime only |
| **sqlc + pgx** | New services, correctness | Best | Medium | Full | Compile-time |
| **GORM** | Internal tools, prototyping | Lowest (30-50% overhead) | Low | Limited | Runtime only |

### Recommended Stack: pgx/v5 + sqlc (new services)

For an organization standardizing across hundreds of Go services:

- **pgx native** for the driver layer (performance, hooks, cloud-native features)
- **sqlc** for query development (type safety, compile-time validation, CI enforcement)
- **Raw pgx** for dynamic queries where sqlc cannot express the pattern
- **pgx/v5/stdlib** as bridge for services needing `database/sql` compatibility
- **Goose or Atlas** for schema migrations (sqlc does not manage schema)

### Migration Path from lib/pq

**Phase 1 — Low risk, immediate:**
Swap `_ "github.com/lib/pq"` for `_ "github.com/jackc/pgx/v5/stdlib"`. Change driver name. All existing code works. Immediate benefit: binary protocol, statement caching.

**Phase 2 — Medium effort:**
For services needing DialFunc/hooks: configure `pgxpool.Config` and use `stdlib.OpenDBFromPool`. Migrate connection strings to `pgx.ParseConfig`.

**Phase 3 — Per-service, as needed:**
Migrate hot paths to pgx native via `(*sql.Conn).Raw()`. Introduce sqlc for new queries alongside existing raw SQL/sqlx.

**Phase 4 — Long-term:**
New services start with pgx native + sqlc as default. Existing services migrate during feature work.

---

## Sources

| Source | URL |
|---|---|
| lib/pq README | https://github.com/lib/pq#status |
| pgx GitHub | https://github.com/jackc/pgx |
| pgx/v5/stdlib docs | https://pkg.go.dev/github.com/jackc/pgx/v5/stdlib |
| pgx vs lib/pq benchmarks | https://devandchill.com/posts/2020/05/go-lib/pq-or-pgx-which-performs-better/ |
| go-pg GitHub | https://github.com/go-pg/pg |
| sqlc + pgx guide | https://docs.sqlc.dev/en/stable/guides/using-go-and-pgx.html |
| All-in on sqlc/pgx | https://brandur.org/sqlc |
| sqlx guide | https://jmoiron.github.io/sqlx/ |
| Go ORM comparison (2026) | https://encore.cloud/resources/go-orms |
| GitLab: recommend pgx over lib/pq | https://gitlab.com/gitlab-org/gitlab/-/merge_requests/49135 |
