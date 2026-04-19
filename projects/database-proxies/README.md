# Database Application-Layer Proxies

Research into open-source application-layer proxies for PostgreSQL, MySQL, and Redis/Valkey that are compatible with Kubernetes hosting and managed service backends (Aurora, ElastiCache, Azure Managed Redis).

## Table of Contents

1. [Documents](#documents)
2. [Scope](#scope)
3. [Key Findings](#key-findings)
4. [Source Repos](#source-repos)

## Documents

| Document | Description |
|---|---|
| [ProxySQL Study](proxysql-study.md) | MySQL/PostgreSQL proxy — connection pooling, query routing, failover |
| [PgDog Study](pgdog-study.md) | PostgreSQL proxy — pooling, load balancing, sharding |
| [Redis/Valkey Proxies](redis-valkey-proxies.md) | Survey of Redis/Valkey proxy options for managed services |
| [Comparison](comparison.md) | Cross-proxy feature comparison and recommendations |

## Scope

All proxies evaluated must meet these criteria:

- **Open source** — permissive or copyleft license
- **Kubernetes-compatible** — deployable in K8s via Helm, Deployment, or StatefulSet
- **Managed service backends** — must work with:
  - Aurora MySQL and Aurora PostgreSQL
  - ElastiCache Valkey (cluster mode enabled and disabled)
  - Azure Managed Redis (cluster mode enabled/disabled, Redis Enterprise sharding)

## Key Findings

### MySQL/PostgreSQL

- **ProxySQL** is the most mature option, supporting both MySQL (full) and PostgreSQL (production-ready since v3.0.3). Three-tier release strategy (Stable/Innovative/AI). GPL-3.0 licensed. 6.7k stars. Proven with Aurora MySQL via specific `innodb_read_only` detection.
- **PgDog** is a newer Rust-based PostgreSQL proxy with built-in sharding, connection pooling, and load balancing. Pre-v1.0 but very actively developed (weekly releases). AGPL-3.0 licensed. 4.3k stars. Official Helm chart and Terraform module.

### Redis/Valkey

- **Envoy Proxy** (Redis filter) is the most production-mature option with CNCF backing, full Redis Cluster support, and AWS IAM auth integration. Heaviest resource footprint.
- **Predixy** is a lightweight C++ proxy with Redis Sentinel + Cluster support. Latest release Dec 2023 (v7.0.1). Good for simpler deployments.
- **Twemproxy** is battle-tested (Twitter, Pinterest, Uber) but does not support Redis Cluster auto-discovery. Last release July 2021. Best for cluster-mode-disabled backends.
- Several other options (Codis, Redis Cluster Proxy, Aster, Overlord) are unmaintained and not recommended.

## Source Repos

| Project | URL | Stars | Language | License |
|---|---|---|---|---|
| ProxySQL | https://github.com/sysown/proxysql | 6,695 | C++ | GPL-3.0 |
| PgDog | https://github.com/pgdogdev/pgdog | 4,283 | Rust | AGPL-3.0 |
| Envoy Proxy | https://github.com/envoyproxy/envoy | 27,848 | C++ | Apache-2.0 |
| Predixy | https://github.com/joyieldInc/predixy | 1,576 | C++ | BSD-3-Clause |
| Twemproxy | https://github.com/twitter/twemproxy | 12,347 | C | Apache-2.0 |

*Star counts and metadata verified via `gh api` on 2026-04-19.*

---

*Research date: 2026-04-19*
