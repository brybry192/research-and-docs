# nri-postgresql Research

**Source:** https://github.com/newrelic/nri-postgresql  
**License:** MIT  
**Latest:** v2.25.0 (Feb 2026)  
**Language:** Go 1.23

---

## Documents

| File | Description | Date |
|---|---|---|
| [study-guide.md](study-guide.md) | Full architecture, code flow, testing, and improvement analysis | Apr 2026 |

---

## Key Facts at a Glance

- Most architecturally mature of the three SQL integrations
- Layered package structure: `collection/`, `connection/`, `metrics/`, `inventory/`
- Unique `collection_list` feature supports ALL / JSON array / JSON object scope control
- Version-gated SQL queries via `blang/semver` for PG 9.x / 10+ / 12+
- Supports PgBouncer monitoring, table/index metrics, bloat detection, custom YAML queries
- Uses `lib/pq` + `sqlx` for database access
- Tests: unit (go-sqlmock v1 + testify), integration (Docker + gojsonschema)
- **Known concern:** per-database connection churn, no `context.Context` timeouts, go-sqlmock pinned to v1
