---
topic: Database Proxy Comparison
date: 2026-04-19
source_repos:
  - https://github.com/sysown/proxysql
  - https://github.com/pgdogdev/pgdog
  - https://github.com/envoyproxy/envoy
  - https://github.com/joyieldInc/predixy
  - https://github.com/twitter/twemproxy
tags: [proxy, mysql, postgresql, redis, valkey, kubernetes, comparison]
status: draft
---

# Database Proxy Comparison — ProxySQL vs PgDog vs Redis/Valkey Proxies

Comparison of open-source application-layer proxies for MySQL, PostgreSQL, and Redis/Valkey with Kubernetes and managed service compatibility.

---

## Table of Contents

1. [At a Glance](#1-at-a-glance)
2. [MySQL/PostgreSQL Proxies](#2-mysqlpostgresql-proxies)
3. [Redis/Valkey Proxies](#3-redisvalkey-proxies)
4. [Managed Service Compatibility](#4-managed-service-compatibility)
5. [Kubernetes Readiness](#5-kubernetes-readiness)
6. [Recommendations](#6-recommendations)
7. [Sources](#7-sources)

---

## 1. At a Glance

| Dimension | ProxySQL | PgDog | Envoy (Redis) | Predixy | Twemproxy |
|---|---|---|---|---|---|
| Database | MySQL + PostgreSQL | PostgreSQL only | Redis/Valkey | Redis/Valkey | Redis/Memcached |
| Language | C++ | Rust | C++ | C++ | C |
| License | GPL-3.0 | AGPL-3.0 | Apache-2.0 | BSD-3-Clause | Apache-2.0 |
| Stars | 6,695 | 4,283 | 27,848 | 1,576 | 12,347 |
| Latest release | v3.0.7 (Apr 2026) | v0.1.37 (Apr 2026) | Active (CNCF) | v7.0.1 (Dec 2023) | v0.5.0 (Jul 2021) |
| Maturity | Stable (MySQL), Production-ready (PG) | Pre-v1.0 | Very stable | Stable | Battle-tested |

---

## 2. MySQL/PostgreSQL Proxies

### ProxySQL vs PgDog

| Feature | ProxySQL | PgDog |
|---|---|---|
| **MySQL support** | Full (10+ years) | None |
| **PostgreSQL support** | Production-ready (since v3.0.3, Nov 2025) | Full (native focus) |
| **Connection pooling** | Hostgroup-based multiplexing | Transaction + session modes |
| **Read/write splitting** | Regex query rules + read_only detection | SQL parser (from PG source) |
| **Query caching** | Yes (MySQL only) | No |
| **Query rewriting** | Yes (regex-based) | No |
| **Sharding** | No | Yes (hash, list, range, schema) |
| **Cross-shard queries** | N/A | Yes (distributed execution) |
| **Two-phase commit** | N/A | Yes |
| **Failover detection** | Monitor module (5 specialized threads) | `pg_is_in_recovery()` |
| **Admin interface** | SQL over MySQL/PG protocol | Admin database |
| **Hot reload** | Yes (RUNTIME/MEMORY/DISK layers) | Yes (SIGHUP or RELOAD command) |
| **Prometheus** | Built-in exporter (126+ metrics) | OpenMetrics endpoint (40+ metrics) |
| **TSDB** | Embedded (v3.1.6+, 365-day retention) | No |
| **SQL injection prevention** | Yes (firewall whitelist) | No |
| **Authentication** | MySQL native + caching_sha2; PG: Plain/MD5/SCRAM | SCRAM/MD5/Plain + IAM + Azure |
| **Threading** | Multi-threaded (workers + monitor + admin) | Multi-threaded async (Tokio) |

### When to Use Which

**ProxySQL** when:
- You need MySQL support (primary use case)
- You want both MySQL and PostgreSQL behind one proxy
- Query caching or rewriting is needed
- Mature, battle-tested PostgreSQL proxying is sufficient
- You need embedded TSDB or SQL injection prevention

**PgDog** when:
- PostgreSQL-only deployment
- Database sharding is required (ProxySQL has no sharding)
- Cross-shard query execution needed
- Modern Rust-based architecture preferred
- AWS IAM or Azure Workload Identity auth needed
- You accept pre-v1.0 risk for advanced features

---

## 3. Redis/Valkey Proxies

| Feature | Envoy (Redis Filter) | Predixy | Twemproxy |
|---|---|---|---|
| **Cluster auto-discovery** | Yes (CLUSTER SLOTS) | Yes | **No** |
| **MOVED/ASK handling** | Yes | Yes | No |
| **Sentinel support** | No | Yes | No |
| **Blocking commands** | Limited | Yes (BLPOP, BRPOP) | No |
| **Multi-key commands** | Yes | Yes (MSET, MGET, DEL) | Partial |
| **Transactions** | Same hashslot only | Single Sentinel group | No |
| **Lua scripting** | No | Yes | No |
| **Pub/Sub** | No | Yes | No |
| **Read from replicas** | Yes | Yes (multi-datacenter) | No |
| **TLS** | Yes | Unclear | Limited |
| **AUTH** | Separate up/downstream + IAM | Extended (RO/RW/admin) | Basic |
| **Pipelining** | Yes | Yes | Yes |
| **Multi-threaded** | Yes | Yes | Single-threaded |
| **Fault injection** | Yes | No | No |
| **Metrics** | Per-command stats + histograms | Latency monitor + stats | Basic stats port |

### When to Use Which

**Envoy** when:
- Already running Envoy/Istio in your mesh
- ElastiCache cluster mode enabled
- Need IAM authentication for AWS
- Want CNCF-backed production maturity
- Willing to accept heavier resource footprint

**Predixy** when:
- Need Sentinel + Cluster support in one proxy
- Need blocking commands, Pub/Sub, or Lua scripting
- Want lightweight C++ proxy without service mesh overhead
- Accept community Helm chart (no official K8s integration)

**Twemproxy** when:
- ElastiCache cluster mode **disabled** (non-cluster backends)
- Proven scale needed (battle-tested at Twitter, Uber, Pinterest)
- Minimal resource footprint is priority
- Static topology is acceptable

---

## 4. Managed Service Compatibility

### Aurora MySQL

| Proxy | Support | Notes |
|---|---|---|
| ProxySQL | Full | Use `innodb_read_only` for replica detection. AWS sample repo available. |

### Aurora PostgreSQL

| Proxy | Support | Notes |
|---|---|---|
| ProxySQL | Yes | Via PG protocol (v3.0+). No Aurora-specific config needed. |
| PgDog | Yes | AWS IAM token auth supported. Standard PG wire protocol. |

### ElastiCache Valkey

| Proxy | Cluster Disabled | Cluster Enabled | Notes |
|---|---|---|---|
| Envoy | Yes | Yes | Full CLUSTER SLOTS + IAM |
| Predixy | Yes | Yes | Full cluster support |
| Twemproxy | Yes | **No** | Cannot auto-discover topology |

### Azure Managed Redis

| Proxy | Standard | Enterprise (OSS cluster) | Enterprise (Enterprise sharding) |
|---|---|---|---|
| Envoy | Yes | Yes | Yes (single endpoint) |
| Predixy | Yes | Yes | Yes (single endpoint) |
| Twemproxy | Yes | Partial | Yes (single endpoint) |

---

## 5. Kubernetes Readiness

| Dimension | ProxySQL | PgDog | Envoy | Predixy | Twemproxy |
|---|---|---|---|---|---|
| **Official Helm chart** | Yes (stale — last updated Mar 2022) | Yes (active — Apr 2026) | Yes (CNCF) | No (community only) | No |
| **K8s Operator** | No | No | Yes (Envoy Gateway) | No | No |
| **Sidecar support** | Yes (chart available) | No (centralized) | Native (Istio) | No | Community |
| **Terraform module** | No | Yes (ECS) | N/A | No | No |
| **Config hot reload** | Yes | Yes (SIGHUP) | Yes (xDS) | Yes | No |
| **Prometheus sidecar** | Built-in exporter | Built-in OpenMetrics | Built-in | No | No |
| **PDB support** | Manual | Yes (Helm chart) | Yes | No | No |
| **Anti-affinity** | Manual | Yes (Helm chart) | Configurable | No | No |

---

## 6. Recommendations

### For MySQL + Aurora MySQL

**ProxySQL** is the clear choice. No other open-source proxy comes close for MySQL. Use the Stable tier (3.0.x) for production. Configure `innodb_read_only` detection for Aurora replicas.

### For PostgreSQL + Aurora PostgreSQL

**If sharding is needed:** PgDog. It's the only option with built-in hash/list/range sharding, cross-shard queries, and 2PC. Accept the pre-v1.0 risk.

**If sharding is not needed:** Either works. ProxySQL has more mature operations tooling (TSDB, Grafana, admin SQL). PgDog has better K8s integration (active Helm chart, IAM auth). ProxySQL wins if you also run MySQL and want one proxy for both.

### For Redis/Valkey + ElastiCache

**Cluster mode enabled:** Envoy or Predixy. Envoy if you run a service mesh. Predixy if you want a lightweight standalone proxy.

**Cluster mode disabled:** Twemproxy for minimal footprint. Envoy if you want consistency with cluster-mode backends.

**Greenfield:** Consider no proxy — use cluster-aware clients with Valkey Helm chart and K8s operators.

### For Azure Managed Redis

Azure Redis Enterprise's built-in proxy handles internal routing. Any external proxy works with the single endpoint. Choose based on existing infrastructure (Envoy if you have a mesh, Predixy or Twemproxy if standalone).

---

## 7. Sources

| Source | URL |
|---|---|
| ProxySQL GitHub | https://github.com/sysown/proxysql |
| PgDog GitHub | https://github.com/pgdogdev/pgdog |
| PgDog website | https://pgdog.dev |
| Envoy Redis docs | https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/other_protocols/redis |
| Predixy GitHub | https://github.com/joyieldInc/predixy |
| Twemproxy GitHub | https://github.com/twitter/twemproxy |
| ProxySQL PG GA issue | https://github.com/sysown/proxysql/issues/5214 |
| ProxySQL Aurora blog | https://aws.amazon.com/blogs/database/how-to-use-proxysql-with-open-source-platforms-to-split-sql-reads-and-writes-on-amazon-aurora-clusters/ |
| PgDog comparison | https://docs.pgdog.dev/architecture/comparison |
| Redis Cluster Proxy (unmaintained) | https://github.com/RedisLabs/redis-cluster-proxy |
| Valkey Helm chart | https://valkey.io/blog/valkey-helm-chart/ |

*All repository metadata (stars, release dates, push dates) verified via `gh api` on 2026-04-19.*
