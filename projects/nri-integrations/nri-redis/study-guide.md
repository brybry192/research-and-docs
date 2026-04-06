# New Relic Infrastructure Integrations — Deep-Dive Study Guide

**nri-postgresql · nri-mysql · nri-redis**

Architecture · Code Flow · Testing · Concerns · Comparisons

*April 2026*

---

## Table of Contents

1. [The NRI Plugin System — Architecture Overview](#1-the-nri-plugin-system--architecture-overview)
2. [nri-postgresql — Deep Dive](#2-nri-postgresql--deep-dive)
3. [nri-mysql — Deep Dive](#3-nri-mysql--deep-dive)
4. [nri-redis — Deep Dive](#4-nri-redis--deep-dive)
5. [Cross-Plugin Comparison](#5-cross-plugin-comparison)
6. [Testing — Detailed Analysis](#6-testing--detailed-analysis)
7. [Code Flow Visualizations](#7-code-flow-visualizations)
8. [Synthesis — Key Improvement Ideas](#8-synthesis--key-improvement-ideas)
9. [Study Reference Links](#9-study-reference-links)

---

## 1. The NRI Plugin System — Architecture Overview

New Relic on-host integrations (OHIs) follow a precise contract between the Infrastructure Agent and a small, statically-compiled Go binary. Understanding the plugin system first makes every individual integration immediately legible.

### 1.1 How the Infrastructure Agent Discovers and Runs Integrations

The Infrastructure Agent polls `/etc/newrelic-infra/integrations.d/` for YAML config files. Each file describes one or more integration instances with a **name** (matching the binary on PATH), **interval**, and **env** key-value pairs that become env-vars or CLI flags when the binary is launched.

The agent forks the binary on each polling interval. The binary:

1. Reads its configuration from environment variables / CLI flags (parsed by the SDK)
2. Connects to the target service
3. Collects metrics and/or inventory
4. Marshals a JSON payload to stdout (single line)
5. Exits — the agent reads stdout, validates the JSON, and forwards it to New Relic

> ✅ **Best Practice:** The "run and exit" model means integrations are stateless by design. There is no long-running daemon to manage; restart semantics come for free from the agent scheduler.

### 1.2 The infra-integrations-sdk/v3 Foundation

All three integrations use `infra-integrations-sdk v3` (protocol v2/v3 JSON). The SDK provides:

| SDK Package | Purpose |
|---|---|
| `integration.Integration` | Root object; holds all entities; calls `Publish()` to write JSON to stdout |
| `integration.Entity` | Logical monitoring target (instance, database, table, index…) |
| `metric.Set` | Named bag of metric key-value pairs attached to an entity (`event_type`) |
| `inventory.Inventory` | Configuration / state data — shown in NR Inventory UI |
| `args.DefaultArgumentList` | Struct tag-driven CLI/env flag parsing; embedded in each plugin's ArgumentList |
| `log` | Structured logger writing to stderr so it doesn't pollute the stdout JSON stream |

### 1.3 JSON Protocol — What Goes Over the Wire

The integration binary emits a single-line JSON document matching protocol v2/v3. The Infrastructure Agent reads this, validates it, and forwards to NRDB.

```json
{
  "name": "com.newrelic.postgresql",
  "protocol_version": "2",
  "integration_version": "2.x.x",
  "data": [
    {
      "entity": { "name": "localhost:5432", "type": "pg-instance", "id_attributes": [] },
      "metrics": [{ "event_type": "PostgresqlInstanceSample" }],
      "inventory": { "config/postgresql": { "key": "value" } },
      "events": []
    },
    { "/* pg-database entity */": {} },
    { "/* pg-table entity */": {} }
  ]
}
```

### 1.4 Entity Model

SDK v3 allows a single payload to carry **multiple entities**. Each entity has a unique **(name, type)** pair plus optional id_attributes that disambiguate e.g. two postgres instances on the same host.

Metric types supported: `GAUGE`, `RATE`, `DELTA`, `ATTRIBUTE` (string).

`RATE` and `DELTA` metrics require at least one namespace attribute so the SDK can persist the previous value across runs. This is stored to disk in a storer file.

### 1.5 Deployment Artifacts

Each integration ships as three files placed on the monitored host:

- **Binary:** `/var/db/newrelic-infra/newrelic-integrations/bin/nri-<n>`
- **Definition (legacy v2 protocol):** `/var/db/newrelic-infra/newrelic-integrations/<n>-definition.yml`
- **Config:** `/etc/newrelic-infra/integrations.d/<n>-config.yml`

> 📌 **Note:** The `definition.yml` file is a legacy artifact from SDK v1/v2. Modern integrations still include it for backward compatibility but derive most behaviour from the binary + config YAML.

### 1.6 Data Flow Diagram

```
┌─────────────────────────────────────────────────┐
│          Infrastructure Agent (daemon)          │
│  Polls /etc/newrelic-infra/integrations.d/      │
│  Reads interval, env vars, name → forks binary  │
└──────────────────────┬──────────────────────────┘
                       │ fork+exec every interval
┌──────────────────────▼──────────────────────────┐
│            nri-<n> Binary                       │
│                                                 │
│  1. SDK parses CLI flags / env vars             │
│  2. Build connection (TCP/socket/TLS)           │
│  3. Execute SQL / REDIS / INFO commands         │
│  4. Populate Entities → MetricSets → Inventory  │
│  5. integration.Publish() → JSON → stdout       │
└──────────────────────┬──────────────────────────┘
                       │ single-line JSON
┌──────────────────────▼──────────────────────────┐
│          Infrastructure Agent (reads stdout)    │
│  Validates JSON → forwards to NR Ingest API     │
└──────────────────────┬──────────────────────────┘
                       │ HTTPS
┌──────────────────────▼──────────────────────────┐
│         New Relic Platform (NRDB)               │
│  Event types: PostgresqlInstanceSample,         │
│               MysqlSample, RedisSample, …       │
└─────────────────────────────────────────────────┘
```

---

## 2. nri-postgresql — Deep Dive

**Repository:** https://github.com/newrelic/nri-postgresql  
**License:** MIT · **Latest:** v2.25.0 · **Language:** Go 1.23

### 2.1 Repository Layout

```
nri-postgresql/
├── src/
│   ├── main.go                  ← entry point, SDK init, orchestration
│   ├── args/                    ← ArgumentList struct (CLI/env config)
│   ├── collection/              ← CollectionList parser (ALL / JSON array / JSON object)
│   ├── connection/              ← PGSQLConnection wrapper around sqlx + lib/pq
│   ├── inventory/               ← pg_settings inventory collection
│   └── metrics/                 ← all metric population (instance, db, table, index, pgbouncer)
├── queries/                     ← standalone .pgsql files for reference / dev
├── tests/                       ← integration test scaffolding (JSON schema validation)
├── legacy/                      ← postgresql-definition.yml (protocol v2 compat)
├── build/                       ← build scripts (goreleaser, Makefile helpers)
├── go.mod / go.sum
├── Makefile
├── postgresql-config.yml.sample
└── postgresql-config.yml.k8s_sample
```

### 2.2 Key Dependencies

| Dependency | Role |
|---|---|
| `lib/pq v1.10.9` | Pure-Go PostgreSQL driver (implements database/sql) |
| `jmoiron/sqlx v1.4.0` | Enhanced sql.DB wrapper — struct scanning, named queries |
| `blang/semver/v4` | Semantic version parsing — used to gate version-specific SQL queries |
| `infra-integrations-sdk/v3` | Core SDK: entity model, metric types, args parsing, JSON publish |
| `stretchr/testify` | Test assertions (assert, require, mock) |
| `go-sqlmock.v1` | SQL driver mock for unit testing DB interactions |
| `xeipuuv/gojsonschema` | JSON Schema validation in integration tests |
| `gopkg.in/yaml.v3` | YAML parsing for custom metrics query file |

### 2.3 Code Flow — Step by Step

#### 2.3.1 Entry: src/main.go

[`src/main.go`](https://github.com/newrelic/nri-postgresql/blob/master/src/main.go)

1. **SDK Init:** `integration.New("com.newrelic.postgresql", version)` constructs the root Integration and registers CLI flags defined in `ArgumentList`.
2. **Args Parse:** SDK calls `flag.Parse()` + reads matching env vars. `args.Validate()` checks required fields.
3. **Collection Parse:** `collection.ParseCollectionList(args.CollectionList)` returns a `DatabaseList` map describing which databases/schemas/tables/indexes to instrument. Supports `"ALL"`, a JSON array of DB names, or a granular JSON object.
4. **Inventory:** If `--inventory` or `--all` mode: `inventory.PopulateInventory(args.ConnectionInfo(), instance, integration)`.
5. **Metrics:** If `--metrics` or `--all` mode: `metrics.PopulateMetrics(ci, databaseList, instance, integration, …)`.
6. **Publish:** `integration.Publish()` serializes all entities to JSON on stdout.

#### 2.3.2 Connection Layer: src/connection/

[`src/connection/`](https://github.com/newrelic/nri-postgresql/tree/master/src/connection)

`PGSQLConnection` wraps `*sqlx.DB`. Key methods: `Query(query, dest)` (sqlx StructScan), `QueryRows(query, dest)`, `HaveExtensionInSchema(ext, schema)` — checks `pg_extension` before attempting tablefunc-dependent lock queries.

`connection.Info` is an **interface** for building connection strings, enabling tests to inject a mock. The real implementation builds a postgres DSN from the `ArgumentList` fields (host, port, user, password, SSL params).

**SSL Modes:** `EnableSSL` / `TrustServerCertificate` flags map to lib/pq `sslmode=` options (`disable`, `require`, `verify-ca`, `verify-full`).

#### 2.3.3 Collection Parser: src/collection/

[`src/collection/`](https://github.com/newrelic/nri-postgresql/tree/master/src/collection)

The `collection_list` argument is the most unique architectural feature of nri-postgresql. It accepts three formats:

- **`"ALL"`:** Auto-discover all non-system databases, schemas, tables, and indexes via `pg_catalog` queries.
- **JSON Array `["db1","db2"]`:** Collect all schemas/tables/indexes within named databases.
- **JSON Object:** Granular control — specify exactly which schemas, tables, and indexes to instrument. No auto-discovery.

This design gives operators control over ingestion volume and avoids accidentally reporting internal/system tables.

#### 2.3.4 Metrics Layer: src/metrics/

[`src/metrics/metrics.go`](https://github.com/newrelic/nri-postgresql/blob/master/src/metrics/metrics.go)

`PopulateMetrics()` is the metrics orchestrator. It:

- Opens one master connection, runs `SHOW server_version` to get a `*semver.Version`.
- Calls **`PopulateInstanceMetrics`** → event type `PostgresqlInstanceSample` (one entity per host:port).
- Calls **`PopulateDatabaseMetrics`** → event type `PostgresqlDatabaseSample` (one entity per database).
- Optionally calls **`PopulateDatabaseLockMetrics`** (requires tablefunc extension, warns if absent).
- Calls **`PopulateTableMetrics`** and **`PopulateIndexMetrics`** per database — opens **a new connection per database** since schemas are per-DB in Postgres. ⚠️
- Optionally calls **`PopulatePgBouncerMetrics`** if configured.
- Runs **custom SQL queries** from a YAML file if provided.

Version-gating is used throughout: SQL queries differ between PostgreSQL 9.x, 10+, and 12+. The semver comparison drives which `QueryDefinition` is selected.

#### 2.3.5 QueryDefinition Pattern

Metrics are defined as `QueryDefinition` structs, each containing a SQL string and a `[]*fieldDefinition` mapping column names to metric names + types. The processor executes the query, iterates rows with sqlx StructScan, and calls `metricSet.SetMetric` for each field. This is a clean data-driven pattern that avoids hardcoding parse logic.

#### 2.3.6 Inventory Layer: src/inventory/

[`src/inventory/`](https://github.com/newrelic/nri-postgresql/tree/master/src/inventory)

Queries `pg_settings` to enumerate runtime configuration parameters. Each setting becomes an inventory item under `config/postgresql/<setting_name>`. This is surfaced in the NR Infrastructure Inventory UI and queryable via `InfrastructureEvent WHERE format='inventoryChange'`.

### 2.4 Testing Approach

#### 2.4.1 Unit Tests

Test files live alongside source files (`*_test.go` in each package). `go-sqlmock.v1` is used to mock `*sqlx.DB` — the mock expects precise SQL strings and returns mock rows. `stretchr/testify` provides `assert` and `require` helpers.

Example: [`src/connection/pgsql_connection_test.go`](https://github.com/newrelic/nri-postgresql/blob/master/src/connection/pgsql_connection_test.go) validates extension detection queries. [`src/metrics/metrics_test.go`](https://github.com/newrelic/nri-postgresql/blob/master/src/metrics/metrics_test.go) tests metric population against mock DB rows.

#### 2.4.2 Integration Tests

The `tests/` directory contains JSON Schema validation files and Docker Compose scaffolding. Integration tests spin up a real PostgreSQL container and validate the full JSON output against a schema (via gojsonschema). This is a good approach but the tests are not always run in CI — the Makefile target is `make integration-test` and requires Docker.

#### 2.4.3 No Performance / Benchmark Tests

> ⚠️ **Concern:** No Go benchmark tests (`func BenchmarkX`) were found. Collection of table/index metrics for large databases (thousands of tables) could be slow due to per-database connection overhead and N+1-style query loops. No pprof/benchmark evidence of this being measured.

### 2.5 Configuration Best Practices Demonstrated

> ✅ The `collection_list` JSON object format is powerful — it allows surgical control over exactly which databases, schemas, tables, and indexes are monitored, preventing over-collection on large instances.

- Custom queries (`custom_metrics_query`) allow operators to extend metrics without forking the binary.
- PgBouncer metrics are opt-in (`collect_pg_bouncer_metrics`), keeping base overhead low.
- SSL is off by default; full cert verification is available.
- Kubernetes autodiscovery is supported natively via `nri-discovery-kubernetes` (see k8s_sample config).

### 2.6 Concerns and Areas for Improvement

> ⚠️ **Per-database connection churn:** For each database in the collection list, a new `*sqlx.DB` connection is opened, used, and closed. For a PostgreSQL instance with 50+ databases, this creates significant connection overhead. A connection pool or reuse strategy would improve performance.

> ⚠️ **N+1 query pattern in table/index collection:** `populateTableMetricsForDatabase` iterates through schemas and opens per-schema queries. There is no batching across schemas. For instances with many schemas per database, this multiplies round-trips.

> ⚠️ **go-sqlmock.v1 is pinned to a very old version.** Upgrading to go-sqlmock v2+ would give access to `RowsFromCSVString` and other quality-of-life improvements.

> ⚠️ **README references govendor** as the dependency manager, but the repo now uses Go modules (`go.mod`). This is a documentation inconsistency that could confuse new contributors.

> ⚠️ **IntegrationVersion is hardcoded as "0.0.0"** in the constants package. The real version is injected at build time via `-ldflags`. If the build pipeline omits ldflags (e.g. during local development), version reporting breaks.

> ⚠️ **No context.Context usage** — all queries use the bare connection without deadlines. If a PostgreSQL query hangs (e.g. waiting on a lock), the integration binary will hang indefinitely until the agent kills it.

---

## 3. nri-mysql — Deep Dive

**Repository:** https://github.com/newrelic/nri-mysql  
**License:** Apache-2.0 · **Language:** Go 1.21+

### 3.1 Repository Layout

```
nri-mysql/
├── src/
│   ├── mysql.go                 ← entry point + orchestration (flat, no sub-dirs)
│   ├── args/                    ← ArgumentList struct
│   ├── mysql_test.go            ← unit tests alongside source
│   └── query-performance-monitoring/
│       ├── performance_main.go  ← QPM orchestrator
│       ├── utils/               ← shared helpers (DSN build, entity create, IngestMetric)
│       ├── constants/           ← named SQL queries, thresholds, defaults
│       ├── slow-query-metrics/  ← slow query collection
│       ├── individual-query-details/ ← per-query detail collection
│       ├── query-plan/          ← EXPLAIN FORMAT=JSON execution plan capture
│       ├── wait-event-metrics/  ← performance_schema wait events
│       └── blocking-sessions/   ← blocking session detection
├── legacy/
├── go.mod / go.sum
├── Makefile
└── mysql-config.yml.sample
```

Unlike nri-postgresql, nri-mysql uses a **flat `src/` structure** — the primary metrics and inventory logic lives directly in `src/mysql.go`. The `query-performance-monitoring` feature (added 2024/2025) introduced the only sub-package structure, organized by feature area.

### 3.2 Key Dependencies

| Dependency | Role |
|---|---|
| `go-sql-driver/mysql` | MySQL driver (database/sql compatible) |
| `jmoiron/sqlx` | Enhanced DB wrapper — same as postgresql |
| `infra-integrations-sdk/v3` | Core SDK (same as postgresql) |
| `stretchr/testify` | Test assertions |
| `DATA-DOG/go-sqlmock` | SQL mocking in tests |

### 3.3 Code Flow — Step by Step

#### 3.3.1 Entry: src/mysql.go

The entry point is simpler than nri-postgresql — nri-mysql collects a fixed set of metrics rather than a configurable collection hierarchy. Flow:

1. **SDK Init:** `integration.New("com.newrelic.mysql", version)`
2. **Args Parse:** `ArgumentList` includes standard connectivity (hostname, port, socket, username, password, TLS) plus metric flags (`extendedMetrics`, `extendedInnodbMetrics`, `extendedMyIsamMetrics`).
3. **Entity Create:** `utils.CreateNodeEntity()` resolves local vs remote monitoring to build the entity name. If `remoteMonitoring=false`, uses the local host entity instead.
4. **Metrics:** Executes `SHOW STATUS`, `SHOW VARIABLES`, `information_schema.INNODB_METRICS` queries. Results mapped to `MySQLSample` event type.
5. **Query Performance Monitoring (optional):** If `enableQueryMonitoring=true`: `PopulateQueryPerformanceMetrics()` runs the full QPM pipeline.
6. **Inventory:** Reads global variables as inventory items.
7. **Publish.**

#### 3.3.2 Argument Design — Extended Metrics Flags

nri-mysql uses boolean feature flags (`extended_metrics`, `extended_innodb_metrics`, `extended_my_isam_metrics`) to gate additional metric sets. This is a coarser-grained approach than nri-postgresql's `collection_list` — operators toggle whole groups, not individual metrics.

#### 3.3.3 Query Performance Monitoring Sub-System

[`src/query-performance-monitoring/`](https://github.com/newrelic/nri-mysql/tree/master/src/query-performance-monitoring)  
[`src/query-performance-monitoring/utils`](https://pkg.go.dev/github.com/newrelic/nri-mysql/src/query-performance-monitoring/utils)

This is the most sophisticated feature unique to nri-mysql (added ~2024). It instruments MySQL's `performance_schema` to capture:

- **Slow Queries:** Groups slow queries from `performance_schema.events_statements_summary_by_digest`. Configurable via `slowQueryFetchInterval` + `queryCountThreshold`.
- **Individual Query Details:** Per-statement detailed metrics for queries exceeding `queryResponseTimeThreshold`.
- **Query Execution Plans:** `EXPLAIN FORMAT=JSON` for SELECT, INSERT, UPDATE, DELETE statements. Captures index usage, join types, cost estimates.
- **Wait Event Metrics:** Aggregated wait events by type from `performance_schema.events_waits_summary_global_by_event_name`.
- **Blocking Sessions:** Detects sessions blocked on locks via `performance_schema.data_lock_waits`.

**IngestMetric pattern:** Due to the SDK's 1000-metric-per-payload limit (codified in `MetricSetLimit=100` constant), the QPM subsystem batches metrics into chunks before calling `integration.Publish()`. This is a clever workaround but adds complexity.

> ✅ **Best Practice: Generic `CollectMetrics[T any]`:** The utils package uses a Go generics function to execute a prepared query and scan results into any struct type. This is elegant and reduces boilerplate across the various QPM collectors.

### 3.4 Testing Approach

Unit tests are co-located with source files. `go-sqlmock` is used for DB interaction tests. The QPM sub-packages have their own test files validating individual collectors. Docker-based integration test scaffolding similar to nri-postgresql validates real MySQL output against expected schemas.

### 3.5 Configuration Best Practices Demonstrated

> ✅ `DefaultExcludedDatabases` constant explicitly filters out `"mysql"`, `"information_schema"`, `"performance_schema"`, `"sys"`, and `""` from QPM collection — avoiding monitoring the monitor's own overhead.

- Remote monitoring (`remote_monitoring: true`) is recommended — creates a proper remote entity instead of decorating the local host.
- TLS is fully supported (`enable_tls`, `insecure_skip_verify`, `tls_ca`, `tls_cert`, `tls_key`).
- `extra_connection_url_args` allows DSN-level tuning without hardcoding.

### 3.6 Concerns and Areas for Improvement

> ⚠️ **IntegrationVersion is "0.0.0" hardcoded** in constants — same issue as nri-postgresql. QPM constants package references the integration version constant, making this inconsistency visible in query monitoring event attributes.

> ⚠️ **Flat `src/` structure** for the core `mysql.go` becomes problematic as the file grows. Metrics, inventory, connection, and orchestration logic are mixed. nri-postgresql's package-per-concern layout is more maintainable.

> ⚠️ **QPM readiness checks** (`ErrEssentialConsumerNotEnabled`, `ErrEssentialInstrumentNotEnabled`) are good, but their error messages require deep MySQL knowledge to act on. Better error messages with docs links would reduce operator friction.

> ⚠️ **No `context.Context`** in core metrics path — same timeout concern as nri-postgresql. QPM collectors may use sqlx context internally, but the main loop does not enforce an overall deadline.

> ⚠️ **`MetricSetLimit=100` batching** is a symptom of the SDK's 1000-metric limit. The workaround works but creates repeated `Publish()` calls that could be replaced by proper dimensional metric chunking if the SDK were upgraded to v4.

> ⚠️ **README still references govendor** despite using Go modules. Same documentation debt as nri-postgresql.

---

## 4. nri-redis — Deep Dive

**Repository:** https://github.com/newrelic/nri-redis  
**License:** Apache-2.0 · **Latest:** v1.12.1 · **Language:** Go 1.23

### 4.1 Repository Layout

```
nri-redis/
├── src/
│   ├── redis.go         ← entry point, args, orchestration, entity creation
│   ├── metrics.go       ← INFO command parsing + metric population
│   ├── inventory.go     ← CONFIG GET command parsing + inventory
│   ├── connection.go    ← TCP/TLS/Unix socket connection to Redis
│   ├── args.go          ← ArgumentList struct (extracted from redis.go)
│   └── *_test.go        ← unit tests per file
├── tests/               ← integration tests + Docker scaffolding
├── legacy/
├── go.mod / go.sum
├── Makefile
└── redis-config.yml.sample
```

nri-redis has the most **compact codebase** of the three, appropriate to its subject: Redis exposes metrics entirely through two commands (`INFO` and `CONFIG GET`) rather than a SQL query interface. The flat `src/` layout is natural given the small surface area.

### 4.2 Key Dependencies

| Dependency | Role |
|---|---|
| `mediocregopher/radix/v3` | Redis client — handles TCP, Unix socket, TLS, auth, pipelining for key-length queries |
| `infra-integrations-sdk/v3` | Core SDK (same as others) |
| `stretchr/testify` | Test assertions |

> 📌 **Note:** nri-redis does NOT use `database/sql` or `sqlx` — it talks to Redis natively via the radix client, which is the correct approach since Redis is not a relational DB.

### 4.3 Code Flow — Step by Step

#### 4.3.1 Entry: src/redis.go

[`src/redis.go`](https://github.com/newrelic/nri-redis/blob/master/src/redis.go)

1. **SDK Init:** `integration.New("com.newrelic.redis", version)`
2. **Args Parse:** Includes TCP/Unix socket options, TLS config, renamed-commands map, keys to monitor, `config_inventory` flag, `remote_monitoring` flag.
3. **Connection:** `connection.go` builds a `radix.Pool` (TCP) or `radix.NewPool` with Unix socket. TLS is wrapped via `tls.Config`. Auth sends `AUTH` command if password set. Redis 6+ username+password via `AUTH user pass`.
4. **Entity:** Entity name = `"hostname:port"` (TCP) or `"unixSocketPath"` (socket mode). If `remoteMonitoring=false` and `UseUnixSocket=false`, falls back to local entity.
5. **Metrics:** Sends `INFO` all-sections command, parses colon-delimited response lines, maps known keys to `RedisSample` metric set. Key-length sub-queries use pipelining (`LLEN`, `SCARD`, `ZCARD`, `HLEN`, `STRLEN` per key type).
6. **Inventory:** Sends `CONFIG GET *` (if `config_inventory=true`), parses response, populates inventory items.
7. **Publish.**

#### 4.3.2 Renamed Commands Support

Redis allows renaming sensitive commands (e.g. `CONFIG` to `MYCONFIGALIAS`). nri-redis supports this via the `renamed_commands` JSON map argument. The connection layer substitutes renamed command names wherever the integration would normally use the default command name. This is a thoughtful production-hardening feature.

#### 4.3.3 Key-Length Collection

The `keys` argument accepts a JSON array of key names. For each key, the type is determined via `TYPE` command, then the appropriate length command is pipelined (`LLEN` for lists, `SCARD` for sets, etc.). A `keys_limit` (default 30) caps collection to prevent excessive overhead.

#### 4.3.4 Metrics Parsing

[`src/metrics.go`](https://github.com/newrelic/nri-redis/blob/master/src/metrics.go)

The `INFO` command returns a multi-section plaintext response. Parsing is done by splitting lines, filtering `#` section headers, and splitting on `:`. Known metric names are mapped to NR metric names and types via a static map in `metrics.go`. Unknown INFO fields are silently ignored — a pragmatic approach.

### 4.4 Testing Approach

Tests for each file. Metrics tests parse mock INFO output strings and validate the resulting metric set. The radix client is abstracted behind an interface, allowing injection of a mock redis client. The `tests/` directory uses Docker Compose to spin up real Redis 6 and Redis 7 servers.

### 4.5 Configuration Best Practices Demonstrated

> ✅ `config_inventory: false` option is explicitly documented for AWS ElastiCache and other managed Redis services where `CONFIG GET` is prohibited. This is great operator-awareness design.

- Unix socket support for co-located deployments avoids network overhead.
- TLS with skip-verify (`tls_insecure_skip_verify`) is available for dev/test — correctly labeled as insecure.
- `use_unix_socket` flag cleanly separates the connection method from the entity name — important for multi-instance monitoring on the same host.

### 4.6 Concerns and Areas for Improvement

> ⚠️ **`strings.Title()` is deprecated** in Go 1.18+ in favor of `golang.org/x/text/cases`. While cosmetic, it generates deprecation warnings.

> ⚠️ **`CONFIG GET *` fetches ALL configuration values.** For Redis instances with many config parameters, this is unnecessarily broad. A targeted `CONFIG GET` list would reduce payload size and parsing time.

> ⚠️ **Static metric map in `metrics.go`** means adding new Redis INFO metrics requires code changes and a release. A declarative metric definition file (like nri-postgresql's `QueryDefinition` pattern) would be more maintainable.

> ⚠️ **No key-length monitoring for STREAM type** (`XLEN` command) — Redis Streams are a commonly used data type that is not covered.

> ⚠️ **radix/v3** — the Go Redis ecosystem has since moved to go-redis and radix v4. v3 is functional but may lag behind modern Redis features (e.g. RESP3 protocol, Redis 7+ ACL improvements).

> ⚠️ Same documentation debt as the others: README references govendor despite `go.mod` being present.

---

## 5. Cross-Plugin Comparison

### 5.1 At a Glance

| Dimension | nri-postgresql | nri-mysql | nri-redis |
|---|---|---|---|
| License | MIT | Apache-2.0 | Apache-2.0 |
| Go Module Version | go 1.23.5 | go 1.21+ | go 1.23 |
| Latest release | v2.25.0 (Feb 2026) | ~v1.15+ | v1.12.1 |
| Data collection mechanism | SQL queries (lib/pq + sqlx) | SQL queries (go-mysql + sqlx) | Redis INFO + CONFIG GET (radix) |
| Source structure | Layered packages | Flat src/ + QPM sub-packages | Flat src/ files |
| Collection scope control | Rich: collection_list JSON (ALL / array / object) | Coarse: boolean feature flags | None (all INFO metrics always) |
| Version-gated queries | Yes (semver) | Yes (MySQL version check in QPM) | No |
| Custom metrics extension | Yes (custom_metrics_query YAML) | No | No |
| Unique feature | PgBouncer monitoring, table/index granularity, bloat detection | QPM: slow queries, EXPLAIN plans, wait events, blocking sessions | Key-length monitoring, renamed-command support |
| Unit test tooling | go-sqlmock v1 + testify | go-sqlmock + testify | radix mock interface + testify |
| Integration test mechanism | Docker + JSON schema validation | Docker + JSON schema validation | Docker + JSON schema validation |
| Performance / benchmark tests | None | None | None |
| context.Context usage | No | Partial (QPM only) | No |
| FIPS-compliant builds | Yes (release artifacts) | Check repo | Yes (v1.12) |

### 5.2 Where They Are Well Coordinated

> ✅ All three integrations share the same foundational contract: `infra-integrations-sdk v3`, the same YAML config structure (name/interval/env), the same Makefile targets (`make` / `make test` / `make integration-test`), the same CI/CD automation (newrelic-coreint-bot + Renovate), and the same JSON output protocol.

- All three use the same `remote_monitoring` pattern for entity naming, making multi-instance deployments consistent.
- All three include a `legacy/` definition.yml for backward compatibility with protocol v2.
- All three use the same security reporting channel (HackerOne / Bug Bounty) and CLA process.
- All three ship FIPS-compliant binary packages (as of recent releases).
- All three use `stretchr/testify` and the same test file co-location convention.
- All three are managed by Renovate bot for dependency updates and newrelic-coreint-bot for release automation — good operational consistency.

### 5.3 Where They Are NOT Aligned

> ⚠️ **License inconsistency:** nri-postgresql uses MIT; nri-mysql and nri-redis use Apache-2.0. This is not a functional issue but matters for consumers tracking license obligations.

> ⚠️ **Collection scope control:** nri-postgresql's `collection_list` is powerful and flexible. nri-mysql uses coarse boolean flags. nri-redis has no scope control at all. There is no shared library or pattern for collection scope management.

> ⚠️ **Custom metrics extensibility:** Only nri-postgresql supports custom SQL query files. nri-mysql and nri-redis cannot be extended without code changes.

> ⚠️ **go-sqlmock version:** nri-postgresql pins `go-sqlmock.v1` (very old). nri-mysql uses a newer version. This divergence means different mock API surfaces and test patterns between two similar SQL-backed integrations.

> ⚠️ **Package organization:** nri-postgresql has the clearest layered structure; nri-mysql mixes concerns in a flat layout (though QPM sub-packages improve this); nri-redis is appropriately compact. There is no shared organizational convention enforced across repos.

> ⚠️ **Context/timeout discipline:** None of them consistently use `context.Context` for query timeouts across the full code path. nri-mysql's QPM partially uses context, creating an inconsistent experience.

> ⚠️ **Documentation debt:** All three README files still reference govendor as the dependency manager despite using Go modules. This is a shared unresolved documentation issue.

---

## 6. Testing — Detailed Analysis

### 6.1 Unit Testing

All three integrations follow the Go standard of co-locating `*_test.go` files with source. Coverage is reasonable for happy-path scenarios but has gaps:

- SQL mock tests validate that specific queries are issued, but often don't test edge cases like partial rows, extra columns, or DB errors mid-result-set.
- nri-postgresql's version-gating logic (semver branching) has limited coverage for boundary versions (e.g. exact version 10.0.0, 12.0.0).
- nri-redis metrics parsing tests are the most comprehensive among the three — every INFO section line is validated.

### 6.2 Integration Testing

All three use a Docker Compose + real service approach. This is a sound strategy that validates the full pipeline from binary to JSON output:

- PostgreSQL integration tests use JSON schema validation via gojsonschema.
- Redis integration tests spin up Redis 6 and Redis 7 variants.
- MySQL integration tests validate against a live MySQL 5.7/8.0 instance.

> ℹ️ Integration tests require Docker and are not run in all CI configurations. They are gated behind `make integration-test` and may not run on every PR. A clearer CI matrix would improve confidence.

### 6.3 End-to-End Testing

> ⚠️ **True E2E testing** (binary deployed alongside a real Infrastructure Agent, data verified in New Relic) does not appear to exist in any of these repos. This gap means integration contract changes (e.g., event_type renames, attribute drops) could reach production undetected.

### 6.4 Performance / Benchmark Testing

> ⚠️ **No benchmark tests** (`func BenchmarkX`) exist in any of the three repos. For nri-postgresql specifically, the per-database-connection overhead for large instances and the N+1 query patterns are unexplored performance risks. Adding Go benchmarks with a mock DB would quantify this.

### 6.5 Recommendations

1. Add table-driven unit tests for error paths (DB connection failure, malformed query results, partial rows).
2. Add Go benchmark tests for the critical collection paths — especially nri-postgresql's database/table/index iteration.
3. Add a CI step that runs integration tests on every PR (not just in release pipelines) using GitHub Actions service containers.
4. Add a contract test that validates the emitted JSON against the NR entity synthesis rules, catching attribute rename regressions.
5. Consider adding fuzz tests for the nri-postgresql `collection_list` JSON parser and nri-redis INFO line parser.

---

## 7. Code Flow Visualizations

### 7.1 nri-postgresql: Full Execution Flow

```
main()
  └─ integration.New(name, version)
  └─ sdk.ParseFlags(args)          ← env vars + CLI flags → ArgumentList
  └─ validateArgs(args)
  └─ collection.ParseCollectionList(args.CollectionList)
        "ALL"      → queryAllDatabases()    → DatabaseList{*: *}
        []string   → DatabaseList{db1: nil}
        JSON obj   → DatabaseList{db1: {schema1: {tbl1: [idx1]}}}
  └─ inventory.PopulateInventory()
        └─ connection.NewConnection(pg-instance)
        └─ SELECT * FROM pg_settings
        └─ entity.SetInventoryItem per row
  └─ metrics.PopulateMetrics()
        └─ connection.NewConnection(pg-instance)
        └─ SHOW server_version → semver.Version
        └─ PopulateInstanceMetrics()
              └─ QueryDefinition[instance] → PostgresqlInstanceSample
        └─ PopulateDatabaseMetrics(for each db in DatabaseList)
              └─ generateDatabaseDefinitions(version)
              └─ processDatabaseDefinitions()
                    └─ pgIntegration.Entity(dbName, "pg-database")
                    └─ MetricSet(PostgresqlDatabaseSample)
        └─ [if collectDbLocks] PopulateDatabaseLockMetrics()
              └─ HaveExtensionInSchema("tablefunc","public") → bool
              └─ CROSSTAB query → PostgresqlDatabaseLockSample
        └─ PopulateTableMetrics(for each db → schema → table)
              └─ per-db NewConnection() ← ⚠️ connection per DB
              └─ generateTableDefinitions(schemaList, version, bloat)
              └─ pgIntegration.Entity(tableName, "pg-table")
              └─ MetricSet(PostgresqlTableSample)
        └─ PopulateIndexMetrics() ← same per-db connection pattern
        └─ [if pgbouncer] PopulatePgBouncerMetrics()
        └─ [if customQuery] CollectCustomConfig()
  └─ integration.Publish()         ← serialize → stdout
```

### 7.2 nri-mysql: Full Execution Flow

```
main()
  └─ integration.New("com.newrelic.mysql", version)
  └─ sdk.ParseFlags(args)
  └─ utils.CreateNodeEntity(integration, remoteMonitoring, host, port)
        └─ if remoteMonitoring → integration.Entity(host:port, "node")
        └─ else               → integration.LocalEntity()
  └─ db = sqlx.Open("mysql", GenerateDSN(args))
  └─ populateMySQLMetrics(db, entity)
        └─ SHOW STATUS       → MysqlSample (core metrics)
        └─ SHOW VARIABLES    → MysqlSample + inventory
        └─ if extendedMetrics → SHOW GLOBAL STATUS extended set
        └─ if extendedInnodbMetrics → information_schema.INNODB_METRICS
        └─ if extendedMyIsamMetrics → SHOW STATUS LIKE "Key_%"
  └─ [if enableQueryMonitoring]
        └─ qpm.PopulateQueryPerformanceMetrics(args, entity, integration)
              └─ validatePrerequisites() ← performance_schema checks
              └─ slow_query.Collect()   → MySQLSlowQueriesSample
              └─ individual.Collect()   → MySQLIndividualQueriesSample
              └─ plan.Collect()         → MySQLQueryExecutionPlanSample
              └─ wait_events.Collect()  → MySQLWaitEventSample
              └─ blocking.Collect()     → MySQLBlockingSessionSample
              └─ IngestMetric(batch) × N  ← ⚠️ multiple Publish() calls
  └─ integration.Publish()
```

### 7.3 nri-redis: Full Execution Flow

```
main()
  └─ integration.New("com.newrelic.redis", version)
  └─ sdk.ParseFlags(args)
  └─ validateArgs()  ← must have hostname:port OR unixSocketPath
  └─ conn = connection.NewRedisConnection(args)
        └─ if UnixSocketPath → radix.NewPool("unix", socketPath)
        └─ else              → radix.NewPool("tcp", host:port)
        └─ if UseTLS         → wrap with tls.Config
        └─ if Password       → conn.AUTH [user] password
  └─ entity = resolveEntity(integration, args)
        └─ if remoteMonitoring or UseUnixSocket → integration.Entity(name, "redis")
        └─ else                                 → integration.LocalEntity()
  └─ metrics.PopulateMetrics(conn, entity, args)
        └─ conn.INFO all-sections → parse key:value lines
        └─ metricSet.SetMetric per known INFO key
        └─ keyspace.Collect(conn, keys, keysLimit)
              └─ per key: conn.TYPE → pick LENGTH command
              └─ pipeline LLEN/SCARD/ZCARD/HLEN/STRLEN
              └─ RedisKeyspaceSample per keyspace DB
  └─ [if configInventory] inventory.PopulateInventory(conn, entity)
        └─ conn.CONFIG GET *
        └─ entity.SetInventoryItem per config key
  └─ integration.Publish()
```

### 7.4 Architecture Layers Diagram (All Three)

```
┌─────────────────────────────────────────────────────────────────────┐
│                   CONFIGURATION LAYER                               │
│  ArgumentList (struct tags) ← env vars / CLI ← YAML config file    │
└──────────────────────────────────────┬──────────────────────────────┘
                                       │
┌──────────────────────────────────────▼──────────────────────────────┐
│                   CONNECTION LAYER                                  │
│  PGSQLConnection (lib/pq + sqlx)     ← nri-postgresql               │
│  sql.DB via go-mysql + sqlx           ← nri-mysql                   │
│  radix.Pool (TCP/Unix/TLS)            ← nri-redis                   │
└──────────────────────────────────────┬──────────────────────────────┘
                                       │
┌──────────────────────────────────────▼──────────────────────────────┐
│                   DATA COLLECTION LAYER                             │
│  SQL queries / INFO / CONFIG GET → raw results                      │
└──────────────────────────────────────┬──────────────────────────────┘
                                       │
┌──────────────────────────────────────▼──────────────────────────────┐
│                   ENTITY / METRIC LAYER (SDK)                       │
│  integration.Entity() → MetricSet.SetMetric() / SetInventoryItem()  │
└──────────────────────────────────────┬──────────────────────────────┘
                                       │
┌──────────────────────────────────────▼──────────────────────────────┐
│                   OUTPUT LAYER                                      │
│  integration.Publish() → JSON (stdout) → Infrastructure Agent        │
└─────────────────────────────────────────────────────────────────────┘
```

### 7.5 Entity Hierarchy per Integration

```
nri-postgresql entities per run:
  pg-instance  (1)         → PostgresqlInstanceSample
  pg-database  (1 per DB)  → PostgresqlDatabaseSample
  pg-table     (1 per tbl) → PostgresqlTableSample
  pg-index     (1 per idx) → PostgresqlIndexSample
  pg-pgbouncer (optional)  → PostgresqlPgbouncerSample

nri-mysql entities per run:
  node  (1)               → MysqlSample
                          → MySQLSlowQueriesSample (QPM)
                          → MySQLIndividualQueriesSample (QPM)
                          → MySQLQueryExecutionPlanSample (QPM)
                          → MySQLWaitEventSample (QPM)
                          → MySQLBlockingSessionSample (QPM)

nri-redis entities per run:
  redis  (1)              → RedisSample
                          → RedisKeyspaceSample (per keyspace DB)
```

---

## 8. Synthesis — Key Improvement Ideas

### 8.1 Shared Concerns Across All Three

| Issue | Impact | Effort |
|---|---|---|
| `context.Context` for all queries | Prevents infinite hangs on locked/slow DB | Medium |
| Fix README govendor references → Go modules | Contributor confusion | Low |
| Fix `IntegrationVersion "0.0.0"` in constants | Misleading version in metric events | Low |
| Add Go benchmark tests (`BenchmarkX`) | Quantify collection overhead for large instances | Medium |
| CI: run integration tests on every PR | Catch regressions before release | Medium |
| Add fuzz tests for JSON/text parsers | Harden against malformed DB responses | High |

### 8.2 nri-postgresql Specific

- **Connection pooling per collection run** — open one connection per database instead of open-use-close-open pattern within the metrics loop.
- **Upgrade go-sqlmock from v1 to v2** for better mock API and modern Go compatibility.
- Add explicit timeouts on `pg_settings` queries (these can be slow if the DB is under load).
- Document the `custom_metrics_query` YAML format with more worked examples.
- Consider adding EXPLAIN plan collection to match MySQL's QPM parity.

### 8.3 nri-mysql Specific

- **Refactor `src/mysql.go` into packages** (`connection/`, `metrics/`, `inventory/`) matching nri-postgresql's cleaner layout.
- Consider **SDK v4 migration** to use dimensional metrics natively, eliminating the `MetricSetLimit=100` batching workaround.
- Add rich error context to QPM prerequisite failure messages (links to MySQL docs on enabling performance_schema consumers).
- Add `context.Context` with deadline to the core metrics path, not just QPM.

### 8.4 nri-redis Specific

- **Add Redis Streams key-length support** (`XLEN` command).
- **Replace `strings.Title()`** with `golang.org/x/text/cases.Title()` to eliminate deprecation warnings.
- Consider a **declarative metric map file** instead of hardcoded static map in `metrics.go`, enabling metric additions without code changes.
- **Upgrade to radix v4** or evaluate go-redis as an alternative for better Redis 7+ and RESP3 support.
- Scope `CONFIG GET` to a targeted list instead of `CONFIG GET *`.

### 8.5 Cross-Cutting Architectural Improvements

- **Align go-sqlmock versions** between nri-postgresql and nri-mysql for consistent mock API patterns.
- **Standardize collection scope control** — define a shared pattern (possibly a shared library or convention) for toggling metric collection across all integrations.
- **Adopt a shared package layout convention** so contributors moving between integrations don't face radically different organization.
- **SDK v4 migration path** — all three would benefit from dimensional metrics support and the improved entity synthesis model in SDK v4.

---

## 9. Study Reference Links

### Repositories

| Resource | URL |
|---|---|
| nri-postgresql (main) | https://github.com/newrelic/nri-postgresql |
| nri-postgresql/src/ | https://github.com/newrelic/nri-postgresql/tree/master/src |
| nri-postgresql metrics.go | https://github.com/newrelic/nri-postgresql/blob/master/src/metrics/metrics.go |
| nri-postgresql connection/ | https://github.com/newrelic/nri-postgresql/tree/master/src/connection |
| nri-postgresql collection/ | https://github.com/newrelic/nri-postgresql/tree/master/src/collection |
| nri-postgresql inventory/ | https://github.com/newrelic/nri-postgresql/tree/master/src/inventory |
| nri-postgresql go.mod | https://github.com/newrelic/nri-postgresql/blob/master/go.mod |
| nri-postgresql k8s sample | https://github.com/newrelic/nri-postgresql/blob/master/postgresql-config.yml.k8s_sample |
| nri-mysql (main) | https://github.com/newrelic/nri-mysql |
| nri-mysql QPM package | https://github.com/newrelic/nri-mysql/tree/master/src/query-performance-monitoring |
| nri-mysql args (pkg.go.dev) | https://pkg.go.dev/github.com/newrelic/nri-mysql/src/args |
| nri-mysql QPM utils | https://pkg.go.dev/github.com/newrelic/nri-mysql/src/query-performance-monitoring/utils |
| nri-mysql QPM constants | https://pkg.go.dev/github.com/newrelic/nri-mysql/src/query-performance-monitoring/constants |
| nri-redis (main) | https://github.com/newrelic/nri-redis |
| nri-redis redis.go | https://github.com/newrelic/nri-redis/blob/master/src/redis.go |
| nri-redis metrics.go | https://github.com/newrelic/nri-redis/blob/master/src/metrics.go |
| nri-redis releases | https://github.com/newrelic/nri-redis/releases |

### SDK & Platform Docs

| Resource | URL |
|---|---|
| infra-integrations-sdk | https://github.com/newrelic/infra-integrations-sdk |
| SDK Tutorial (v3) | https://github.com/newrelic/infra-integrations-sdk/blob/master/docs/tutorial.md |
| SDK Multiple Entities Tutorial | https://github.com/newrelic/infra-integrations-sdk/blob/master/docs/tutorial_multiple_entities.md |
| Entity Definition | https://github.com/newrelic/infra-integrations-sdk/blob/master/docs/entity-definition.md |
| SDK v3 to v4 Migration | https://github.com/newrelic/infra-integrations-sdk/blob/master/docs/v3tov4.md |
| Integration JSON Spec (pkg.go.dev) | https://pkg.go.dev/github.com/newrelic/infra-integrations-sdk/integration |
| PostgreSQL integration docs | https://docs.newrelic.com/install/postgresql/ |
| MySQL integration docs | https://docs.newrelic.com/install/mysql/ |
| Redis integration docs | https://docs.newrelic.com/docs/infrastructure/host-integrations/host-integrations-list/redis/redis-integration/ |
| Understand integration data | https://docs.newrelic.com/docs/infrastructure/infrastructure-data/infra-integration-data/ |

### Key Go Packages Used

| Package | URL |
|---|---|
| lib/pq (PostgreSQL driver) | https://pkg.go.dev/github.com/lib/pq |
| jmoiron/sqlx | https://pkg.go.dev/github.com/jmoiron/sqlx |
| go-sqlmock | https://pkg.go.dev/github.com/DATA-DOG/go-sqlmock |
| blang/semver | https://pkg.go.dev/github.com/blang/semver/v4 |
| mediocregopher/radix v3 | https://pkg.go.dev/github.com/mediocregopher/radix/v3 |
| go-sql-driver/mysql | https://pkg.go.dev/github.com/go-sql-driver/mysql |

---

*Generated April 2026 · For personal study use*
