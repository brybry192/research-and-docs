---
topic: NRI Cross-Plugin Comparison
date: 2026-04-05
source_repos:
  - https://github.com/newrelic/nri-postgresql
  - https://github.com/newrelic/nri-mysql
  - https://github.com/newrelic/nri-redis
  - https://github.com/newrelic/infra-integrations-sdk
tags: [go, newrelic, integrations, architecture, comparison]
status: reviewed
---

# NRI Cross-Plugin Comparison

Extracted from the [full study guide](../nri-postgresql/study-guide.md) — focuses on coordination, gaps, and alignment between the three integrations.

---

## At a Glance

| Dimension | nri-postgresql | nri-mysql | nri-redis |
|---|---|---|---|
| License | MIT | Apache-2.0 | Apache-2.0 |
| Go version | 1.23.5 | 1.21+ | 1.23 |
| Latest release | v2.25.0 (Feb 2026) | ~v1.15+ | v1.12.1 |
| Data collection | SQL (lib/pq + sqlx) | SQL (go-mysql + sqlx) | Redis INFO + CONFIG GET (radix) |
| Source structure | Layered packages | Flat src/ + QPM sub-packages | Flat src/ files |
| Collection scope control | Rich: collection_list JSON | Coarse: boolean flags | None |
| Version-gated queries | Yes (semver) | Yes (QPM) | No |
| Custom metrics extension | Yes (YAML query file) | No | No |
| Unit test mock | go-sqlmock **v1** | go-sqlmock (newer) | radix mock interface |
| Integration tests | Docker + gojsonschema | Docker + gojsonschema | Docker + gojsonschema |
| Benchmark tests | ❌ | ❌ | ❌ |
| `context.Context` | ❌ | Partial (QPM only) | ❌ |
| FIPS builds | ✅ | Check repo | ✅ (v1.12) |

---

## Where They Are Well Coordinated ✅

- **Same SDK contract:** All three use `infra-integrations-sdk/v3`, the same JSON protocol, and the same agent-invoked binary model
- **Same `remote_monitoring` pattern:** Consistent entity naming for multi-instance deployments
- **Same Makefile targets:** `make` / `make test` / `make integration-test` across all three
- **Same CI/CD automation:** `newrelic-coreint-bot` (releases) + Renovate (deps) — great operational consistency
- **Same test library:** `stretchr/testify` + co-located `*_test.go` files
- **Same legacy compat:** All three include `legacy/definition.yml` for protocol v2 backward compatibility
- **Same security process:** HackerOne bug bounty + CLA for contributions
- **FIPS builds:** Shipped in recent releases of postgresql and redis

---

## Where They Are NOT Aligned ⚠️

### License inconsistency
- nri-postgresql: **MIT**
- nri-mysql, nri-redis: **Apache-2.0**
- Not a functional issue but matters for consumers tracking license obligations

### Collection scope control
- nri-postgresql: powerful `collection_list` (ALL / array / JSON object)
- nri-mysql: coarse boolean flags
- nri-redis: no scope control at all
- No shared library or pattern exists across repos

### Custom metrics extensibility
- Only nri-postgresql supports custom SQL query YAML files
- nri-mysql and nri-redis require code changes to add metrics

### go-sqlmock version divergence
- nri-postgresql: `go-sqlmock.v1` (very old — different mock API surface)
- nri-mysql: newer go-sqlmock version
- Creates inconsistent test patterns between two SQL-backed integrations

### Package organization
- nri-postgresql: clearest layered structure
- nri-mysql: flat `mysql.go` mixes concerns (QPM sub-packages help)
- nri-redis: appropriately compact
- No enforced convention across repos

### context.Context discipline
- None of them enforce query timeouts across the full code path
- nri-mysql QPM partially uses context — creates an inconsistent experience within the same binary

### Documentation debt (all three)
- All README files still reference **govendor** as the dependency manager
- All repos use **Go modules** (`go.mod`) in practice
- `IntegrationVersion = "0.0.0"` hardcoded in constants packages (real version injected via ldflags at build time)

---

## Entity Hierarchy Per Integration

```
nri-postgresql:
  pg-instance  (1)         → PostgresqlInstanceSample
  pg-database  (1 per DB)  → PostgresqlDatabaseSample
  pg-table     (1 per tbl) → PostgresqlTableSample
  pg-index     (1 per idx) → PostgresqlIndexSample
  pg-pgbouncer (optional)  → PostgresqlPgbouncerSample

nri-mysql:
  node (1)                 → MysqlSample
                           → MySQLSlowQueriesSample (QPM)
                           → MySQLIndividualQueriesSample (QPM)
                           → MySQLQueryExecutionPlanSample (QPM)
                           → MySQLWaitEventSample (QPM)
                           → MySQLBlockingSessionSample (QPM)

nri-redis:
  redis (1)                → RedisSample
                           → RedisKeyspaceSample (per keyspace DB)
```

---

## Shared Improvement Opportunities

| Issue | Impact | Effort |
|---|---|---|
| Add `context.Context` with deadlines to all query paths | Prevents hangs on locked/slow DB | Medium |
| Fix README govendor → Go modules | Contributor confusion | Low |
| Fix `IntegrationVersion "0.0.0"` | Misleading metric attributes | Low |
| Add Go benchmark tests (`BenchmarkX`) | Quantify collection overhead | Medium |
| Run integration tests on every PR in CI | Catch regressions before release | Medium |
| Add fuzz tests for JSON/text parsers | Harden against malformed DB responses | High |
| Align go-sqlmock versions (postgresql ↑ to v2+) | Consistent test patterns | Low |
| Standardize collection scope control across plugins | Operator consistency | High |
| SDK v4 migration path (all three) | Dimensional metrics, better entity synthesis | High |

---

## Architecture Layers (Shared Pattern)

```
┌──────────────────────────────────────────────────┐
│  CONFIGURATION: ArgumentList struct tags          │
│  ← env vars / CLI flags ← YAML config file       │
└──────────────────────────┬───────────────────────┘
                           │
┌──────────────────────────▼───────────────────────┐
│  CONNECTION                                       │
│  PGSQLConnection (lib/pq+sqlx) ← postgresql       │
│  sql.DB (go-mysql+sqlx)        ← mysql            │
│  radix.Pool (TCP/Unix/TLS)     ← redis            │
└──────────────────────────┬───────────────────────┘
                           │
┌──────────────────────────▼───────────────────────┐
│  DATA COLLECTION                                  │
│  SQL queries / INFO commands / CONFIG GET         │
└──────────────────────────┬───────────────────────┘
                           │
┌──────────────────────────▼───────────────────────┐
│  SDK ENTITY/METRIC LAYER                          │
│  integration.Entity() → MetricSet → SetMetric()   │
│  SetInventoryItem()                               │
└──────────────────────────┬───────────────────────┘
                           │
┌──────────────────────────▼───────────────────────┐
│  OUTPUT                                           │
│  integration.Publish() → JSON stdout → Agent      │
└──────────────────────────────────────────────────┘
```
