# nri-redis Research

**Source:** https://github.com/newrelic/nri-redis  
**License:** Apache-2.0  
**Latest:** v1.12.1  
**Language:** Go 1.23

---

## Documents

| File | Description | Date |
|---|---|---|
| [study-guide.md](study-guide.md) | Full architecture, code flow, testing, and improvement analysis | Apr 2026 |

---

## Key Facts at a Glance

- Most compact codebase of the three — appropriate for Redis's INFO + CONFIG GET API surface
- Flat `src/` with per-concern files: `redis.go`, `metrics.go`, `inventory.go`, `connection.go`, `args.go`
- Uses `mediocregopher/radix/v3` (not database/sql) — correct choice for Redis
- **Standout features:** renamed-command support for secured Redis instances; `config_inventory: false` for ElastiCache
- Key-length monitoring with pipelining (LLEN/SCARD/ZCARD/HLEN/STRLEN) capped at `keys_limit`
- Tests: unit (radix mock interface + testify), integration (Docker Redis 6 + 7)
- **Known concerns:** `strings.Title()` deprecated, no Redis Streams (XLEN) support, `CONFIG GET *` too broad, radix v3 aging
