# nri-mysql Research

**Source:** https://github.com/newrelic/nri-mysql  
**License:** Apache-2.0  
**Language:** Go 1.21+

---

## Documents

| File | Description | Date |
|---|---|---|
| [study-guide.md](study-guide.md) | Full architecture, code flow, testing, and improvement analysis | Apr 2026 |

---

## Key Facts at a Glance

- Flat `src/` structure for core metrics; `query-performance-monitoring/` sub-packages for QPM feature
- Coarse collection control via boolean feature flags (`extended_metrics`, `extended_innodb_metrics`, etc.)
- **Standout feature:** Query Performance Monitoring (QPM) added ~2024 — slow queries, EXPLAIN plans, wait events, blocking sessions
- Uses Go generics (`CollectMetrics[T any]`) in QPM utils for type-safe result scanning
- Uses `go-sql-driver/mysql` + `sqlx` for database access
- `MetricSetLimit=100` batching workaround for SDK's 1000-metric payload limit
- **Known concern:** flat `mysql.go` mixes concerns, `IntegrationVersion = "0.0.0"` constant, no `context.Context` in core path
