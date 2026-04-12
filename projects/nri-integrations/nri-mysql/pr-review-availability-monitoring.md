# nri-mysql Availability Monitoring — Code Review, Test Proposal & Session Handoff

**PRs Reviewed:** [#1 Core Availability](https://github.com/brybry192/nri-mysql/pull/1) · [#2 E2E Harness](https://github.com/brybry192/nri-mysql/pull/2) · [#3 Dashboard](https://github.com/brybry192/nri-mysql/pull/3)
**Date:** April 12, 2026
**Scope:** Connection/resource leaks, server-side impact, client performance, backoff strategy, test gaps

-----

## Executive Summary

The nri-mysql PRs mirror the nri-postgresql availability monitoring pattern: opt-in flags for connection timing (DNS/TCP/TLS via custom DialFunc), explicit canary queries, per-query telemetry, and structured error classification — all emitting `MysqlHealthSample` events. The architecture shares the same strengths (features default off, timing piggybacks on natural operations, timeout-bounded checks) and **the same structural risks** found in the PostgreSQL sibling.

Key MySQL-specific differences that affect this analysis:

- **go-sql-driver/mysql** is the underlying driver (not pgx). It uses `database/sql` natively and has different connection pool behavior.
- **COM_PING** is used for implicit availability (MySQL protocol-level ping), bounded by a 5-second context deadline.
- **TLS handshake timing is measured independently** via `tls.Config.VerifyConnection` callback — an improvement over the PostgreSQL PR where TLS timing was a blind spot.
- **No driver migration** — nri-mysql already uses go-sql-driver/mysql, so there’s no lib/pq → pgx transition risk.
- **Single connection architecture** — nri-mysql doesn’t open per-database connections like nri-postgresql does, which eliminates the per-database pool multiplication risk.

Despite the simpler connection model, the core risks around persistent-failure hammering and connection lifecycle remain identical.

-----

## PART 1: Connection & Resource Leak Analysis

### 1.1 — CRITICAL: `sql.DB` Pool Not Explicitly Closed on Failure Path

Same structural risk as the PostgreSQL PR. When the connection “falls through” to emit `available=0` on failure:

1. `sql.Open` creates a `sql.DB` pool (lazy — no dial yet)
1. The 5-second COM_PING fires → DialFunc triggers → TCP connects → auth fails or timeout
1. Health samples emitted
1. Process exits

If auth failed (MySQL error 1045), the TCP connection was established before MySQL rejected credentials. The `sql.DB` pool holds that connection. Without `defer db.Close()`, it sits until process exit. With the NR infra agent restarting the binary every cycle, that’s one leaked MySQL thread per cycle.

MySQL’s `wait_timeout` (default 28800s = 8 hours) governs idle connection cleanup. That’s far more aggressive than PG’s default, but in a tight 15-second cycle loop, you’d accumulate connections faster than the timeout clears them.

**Impact:** With `max_connections = 151` (MySQL default) and 15-second cycles, you’d exhaust the connection limit in ~38 minutes of continuous auth failure.

**Recommendation:** `defer db.Close()` immediately after `sql.Open` or the equivalent connection factory call.

### 1.2 — HIGH: COM_PING 5-Second Timeout vs. Frozen Server

The PR mentions a 5-second context deadline on the implicit ping. With go-sql-driver/mysql, `db.PingContext(ctx)` sends COM_PING over an existing connection (or establishes one first). If the server is frozen (container paused — SIGSTOP), the TCP connection hangs.

The 5-second timeout cancels the Go context, but go-sql-driver/mysql’s behavior on context cancellation is to close the underlying `net.Conn`. This is correct — it prevents the connection from being returned to the pool in a broken state.

However: **if `SetConnMaxLifetime` is not configured and the pool creates a new connection for the next attempt**, the DialFunc fires again. With `database/sql`’s internal retry logic on `ErrBadConn`, you could get 2-3 dial attempts within a single `PingContext` call.

**Recommendation:** Set `db.SetMaxOpenConns(1)` and `db.SetConnMaxIdleTime(0)` to prevent the pool from attempting to maintain idle connections that it can’t health-check.

### 1.3 — MEDIUM: `invalid_connection` Error from KILL — Connection State

The E2E test validates that `KILL <connection_id>` produces `invalid_connection`. This is correct behavior. But the interesting question is: **what happens to the `sql.DB` pool after the KILL?**

When MySQL KILLs a connection, the next query on that `net.Conn` returns `mysql.ErrInvalidConn`. The go-sql-driver marks the connection as bad and discards it. The pool then creates a new connection for the next query. This is fine for the canary query, but if the KILL happens during a regular monitoring query (SHOW GLOBAL STATUS, etc.), the pool will retry with a fresh connection — issuing a new TCP+TLS+Auth handshake mid-cycle.

This isn’t a leak, but it’s worth documenting: a KILL during monitoring may cause one query to fail while subsequent queries succeed on a new connection, creating a partial-failure health sample.

### 1.4 — MEDIUM: TLS VerifyConnection Callback Ordering

The PR mentions `wrapTLSConfig` using `VerifyConnection` to measure TLS handshake time. The go-sql-driver/mysql calls `VerifyConnection` after the TLS handshake completes but before authentication. If the callback panics or takes too long, it blocks the connection setup.

The timing measurement is a simple `time.Since(start)` which is safe. But if the original user-provided `VerifyConnection` callback (from the TLS config) is also present, the wrapper must chain them correctly. A bug here could silently skip the user’s certificate verification.

**Recommendation:** Verify that when `wrapTLSConfig` detects an existing `VerifyConnection` on the user’s TLS config, it calls the original *before* recording the timestamp. If the original returns an error, the timing should still be recorded (it’s useful to know how long a TLS failure took).

-----

## PART 2: Server-Side Impact Analysis

### 2.1 — CRITICAL: No Backoff on Persistent Failures (Same as PostgreSQL)

Identical structural issue. Every collection cycle hammers MySQL with:

- TCP connect + TLS handshake + auth attempt (even if password is wrong)
- MySQL logs every failed auth to the error log
- With `log_error_verbosity = 3`, this includes the source IP, user, and connection attempt details
- MySQL’s `performance_schema.host_cache` tracks connection errors per host — enough failures can trigger automatic host blocking

**MySQL-specific amplifier:** MySQL has `max_connect_errors` (default 100). After 100 failed connections from the same host, MySQL blocks that host entirely with `Host 'x' is blocked because of many connection errors`. The monitoring agent would then get `connection_refused`-like behavior even after the root cause (wrong password) is fixed, requiring a `FLUSH HOSTS` to recover.

At 4 attempts per minute, you’d hit `max_connect_errors = 100` in **25 minutes**. After that, the monitoring agent is locked out until someone intervenes.

**This is worse than the PostgreSQL case.** MySQL’s host blocking is automatic and silent.

**Recommendation:** Shunning/backoff is even more critical for MySQL than for PostgreSQL. Implement the same strategy proposed in the PostgreSQL review, with an additional MySQL-specific test: verify that repeated auth failures don’t trigger `max_connect_errors` host blocking.

### 2.2 — HIGH: Canary Query Without `max_execution_time`

MySQL 5.7.8+ supports `max_execution_time` as an optimizer hint:

```sql
SELECT /*+ MAX_EXECUTION_TIME(5000) */ 1
```

Or as a session variable:

```sql
SET SESSION max_execution_time = 5000;
```

The context timeout prevents the *client* from waiting, but like PostgreSQL, a cancelled query may continue running on the server. MySQL’s behavior on client disconnect depends on `mysql_native_password` vs `caching_sha2_password` and the connection state — in some cases, a query continues until it reaches a safe cancellation point.

**Recommendation:** Issue `SET SESSION max_execution_time = <timeout_ms>` before the canary query, or use the optimizer hint syntax. This ensures MySQL kills the query server-side.

### 2.3 — MEDIUM: iptables REJECT vs DROP in E2E Tests

The E2E uses `iptables -j REJECT --reject-with tcp-reset` for the connection_refused test. This is correct for testing the `connection_refused` error code. But in production, firewalls more commonly use DROP (silent — the client hangs until timeout) rather than REJECT.

This means the `connection_refused` classification may be less common in real environments than `timeout`. Not a code issue, but worth noting in operational documentation: operators should expect `timeout` rather than `connection_refused` for most network-level blocking.

-----

## PART 3: Backoff / Shunning Strategy — MySQL-Specific Additions

The same shunning architecture from the PostgreSQL proposal applies, with these MySQL-specific additions to the error classification:

|Error Code          |Shunnable?  |MySQL-Specific Rationale                                  |
|--------------------|------------|----------------------------------------------------------|
|`mysql_error_1045`  |**YES**     |Access denied. Password wrong. Won’t self-resolve.        |
|`mysql_error_1044`  |**YES**     |Access denied for database. Permission issue.             |
|`mysql_error_1049`  |**YES**     |Unknown database. Config error.                           |
|`mysql_error_1129`  |**YES**     |Host blocked (max_connect_errors). Needs FLUSH HOSTS.     |
|`mysql_error_1040`  |**Soft YES**|Too many connections. May self-resolve, but backoff helps.|
|`mysql_error_1158`  |**NO**      |Network read error. Transient.                            |
|`mysql_error_1159`  |**NO**      |Network write timeout. Transient.                         |
|`invalid_connection`|**NO**      |Connection was killed. Transient by nature.               |
|`connection_reset`  |**NO**      |TCP reset. Transient.                                     |

**Critical addition:** If the error is `mysql_error_1129` (host blocked), the shun duration should be **long** (30+ minutes) because the block persists until a human runs `FLUSH HOSTS` or `mysqladmin flush-hosts`. Retrying against a blocked host just increments the internal counter further.

-----

## PART 4: Test Proposal

### What Exists Today

|Layer      |Tests                                                                                                                            |
|-----------|---------------------------------------------------------------------------------------------------------------------------------|
|Unit       |timingDialFunc, wrapTLSConfig, classifyError (all error categories), sanitizeErrorMessage, extractQueryName, telemetryAccumulator|
|Integration|TestNoObservabilityFlags, TestMysqlObservabilityFlags, TestConnectionFailureHealthSample, TestAvailabilityCheckTimeout           |
|E2E        |Container stop, iptables REJECT, container pause, password change, KILL connection — all NerdGraph verified                      |

### Proposed New Tests

#### P0 — Must Have

**RepeatedAuthFailureDoesNotLeakConnections**
Run the binary 20 times with wrong password against MySQL with `max_connections=20`. Assert no “Too many connections” error occurs. Check `SHOW PROCESSLIST` between runs — monitoring user thread count must stay <= 1.

**RepeatedAuthFailureDoesNotTriggerHostBlock**
Run the binary with wrong password for N cycles. Assert MySQL’s `performance_schema.host_cache.COUNT_AUTHENTICATION_ERRORS` stays below `max_connect_errors`. This is THE test that prevents the 25-minute lockout scenario.

**PoolClosedAfterAuthFailure**
Using a connection spy, verify `db.Close()` is called when auth fails (mysql_error_1045).

**ShunnableErrorClassification (table-driven)**
Validate all MySQL error codes map to correct shunnable/non-shunnable classification. Include `mysql_error_1129` (host blocked) as the highest-backoff case.

**ShunStateMachine (same as PostgreSQL)**
First failure sets backoff=2, consecutive doubles, cap at 60, success clears, non-shunnable doesn’t trigger, state file round-trip, corrupt file recovery.

#### P1 — Should Have

**ServerSideQueryCancelledOnTimeout**
Run `SELECT BENCHMARK(999999999, SHA2('test', 256))` as canary with 500ms timeout. After the binary exits, check `SHOW PROCESSLIST` — no thread should be running BENCHMARK.

**PingTimeoutDoesNotBlockCycle**
With a paused MySQL container (SIGSTOP), verify the binary exits within ~6 seconds (5s ping timeout + 1s overhead), not hanging until the default `wait_timeout`.

**ShunnedInstanceStillEmitsAvailable0**
When shunned, verify `MysqlHealthSample` is emitted with `available=0`, `shunned=true`, and no TCP connection is attempted (check `SHOW PROCESSLIST` from admin connection).

**TLSTimingCapturedCorrectly**
With TLS enabled, verify `tlsHandshakeMs > 0` in the health sample. With TLS disabled (inventorydb), verify `tlsHandshakeMs == 0` or absent. This validates the `wrapTLSConfig` callback.

**MaxConnErrorsProtection**
Set `max_connect_errors = 5` on test MySQL. Run 4 cycles with wrong password. Assert monitoring can still *attempt* connection on cycle 5 (not blocked). Then fix the password — cycle 5 should succeed. This proves the backoff keeps attempts below the host block threshold.

#### P2 — Nice to Have

**ConnectionKillMidQuery**
Kill the monitoring connection during `SHOW GLOBAL STATUS`. Verify partial results don’t corrupt the MysqlSample output, and the health sample correctly reports `invalid_connection`.

**TLSVerifyConnectionChaining**
If the user provides a custom `VerifyConnection` callback in their TLS config, verify it still runs AND timing is still captured. Verify that if the user’s callback rejects the cert, the timing is still recorded and the error is classified as `tls_error`.

**E2E: Repeated Auth Failure Connection Stability**
Same as PostgreSQL E2E test 6: change password, watch `SHOW PROCESSLIST` for 5 cycles, assert thread count stays bounded.

**E2E: max_connect_errors Integration**
Set `max_connect_errors = 10`, run chaos password test for 15 cycles, verify the host is NOT blocked due to backoff keeping attempts below threshold.

### Test Infrastructure Needs

Same as PostgreSQL: fake clock, connection spy, process list helper. MySQL-specific:

```go
func getMonitoringThreads(t *testing.T, adminDSN string, user string) int {
    t.Helper()
    db, err := sql.Open("mysql", adminDSN)
    require.NoError(t, err)
    defer db.Close()

    var count int
    err = db.QueryRow(
        "SELECT COUNT(*) FROM information_schema.processlist WHERE user = ? AND id != CONNECTION_ID()",
        user,
    ).Scan(&count)
    require.NoError(t, err)
    return count
}

func getHostCacheErrors(t *testing.T, adminDSN string, host string) int {
    t.Helper()
    db, err := sql.Open("mysql", adminDSN)
    require.NoError(t, err)
    defer db.Close()

    var count int
    err = db.QueryRow(
        "SELECT IFNULL(SUM(COUNT_AUTHENTICATION_ERRORS), 0) FROM performance_schema.host_cache WHERE IP = ?",
        host,
    ).Scan(&count)
    require.NoError(t, err)
    return count
}
```

-----

## PART 5: Summary of Recommendations

### Must Fix (Before Merge)

|#|Issue                                                   |Severity|Impact                                            |
|-|--------------------------------------------------------|--------|--------------------------------------------------|
|1|Add `defer db.Close()` after connection factory         |CRITICAL|Connection leak on auth failures                  |
|2|Set `db.SetMaxOpenConns(1)` on the pool                 |HIGH    |Unbounded pool growth                             |
|3|Add `SET SESSION max_execution_time` before canary query|HIGH    |Server-side query not cancelled on context timeout|

### Should Fix (Before Production Rollout)

|#|Issue                                                        |Severity|Impact                                                      |
|-|-------------------------------------------------------------|--------|------------------------------------------------------------|
|4|Implement shunning/backoff for persistent failures           |CRITICAL|Prevents `max_connect_errors` host blocking (25-min lockout)|
|5|Test that repeated auth failures don’t trigger host block    |HIGH    |Validate #4 works                                           |
|6|Document `max_connect_errors` interaction in operational docs|MEDIUM  |Operator awareness                                          |

### Nice to Have (Follow-Up)

|#|Issue                                                   |Severity|Impact             |
|-|--------------------------------------------------------|--------|-------------------|
|7|Verify TLS VerifyConnection callback chaining           |LOW     |Defense in depth   |
|8|Document iptables DROP vs REJECT error code expectations|LOW     |Operational clarity|

-----

## PART 6: Cross-Integration Observations

Having reviewed both nri-postgresql and nri-mysql, the shunning package should be a **shared library** rather than duplicated. The state machine, file persistence, fake clock, and backoff math are identical. Only the error classification differs (PG error codes vs MySQL error numbers). Consider:

```
shared/shun/
├── shun.go           # ShunManager, state machine, file I/O
├── shun_test.go      # State machine tests
├── classify.go       # Interface: IsShunnable(errorCode string) bool
├── classify_test.go
└── testdata/
```

Each integration provides its own `IsShunnable` implementation:

- PostgreSQL: `auth_failed`, `ssl_error`, `dns_resolution_failed`, `connection_refused`
- MySQL: `mysql_error_1045`, `mysql_error_1044`, `mysql_error_1049`, `mysql_error_1129`, `dns_resolution_failed`, `connection_refused`, `ssl_error`

-----

## PART 7: Session Handoff Prompt

```markdown
# Context

I'm working on an open-source fork of `nri-mysql` (New Relic's MySQL infrastructure integration). The fork adds opt-in availability monitoring features behind four new flags:

- `COLLECT_CONNECTION_TIMING` — DNS/TCP/TLS phase timing via custom DialFunc + tls.Config.VerifyConnection
- `AVAILABILITY_CHECK_QUERY` — configurable canary query (e.g., "SELECT 1")
- `AVAILABILITY_CHECK_TIMEOUT_MS` — context deadline bounding the canary (default 5000ms)
- `COLLECT_QUERY_TELEMETRY` — per-internal-query duration and error tracking

The driver is go-sql-driver/mysql (no migration — same driver as upstream). The integration is a short-lived Go binary invoked by the New Relic infrastructure agent every collection cycle (typically 15–30 seconds), and it exits after publishing metrics. Unlike nri-postgresql, nri-mysql uses a single connection (no per-database pool multiplication).

## PRs

- PR #1 (core): https://github.com/brybry192/nri-mysql/pull/1
- PR #2 (e2e harness): https://github.com/brybry192/nri-mysql/pull/2
- PR #3 (dashboard): https://github.com/brybry192/nri-mysql/pull/3

## Sister Project

A parallel implementation exists for PostgreSQL:
- https://github.com/brybry192/nri-postgresql/pull/1 (core)
- Review report and test proposal already completed for that project
- The shunning package should ideally be shared between both integrations

## Review Findings

A code review identified these risks (full report attached):

**Connection / resource leaks:**
1. **`sql.DB` pool not explicitly closed** — on auth failures (mysql_error_1045), TCP connects but auth is rejected. Without `defer db.Close()`, leaked MySQL threads accumulate.
2. **Pool not bounded** — no `SetMaxOpenConns(1)` means the pool can grow despite single-threaded usage.

**Server-side impact (MySQL-specific and CRITICAL):**
3. **`max_connect_errors` host blocking** — MySQL blocks a host after N failed connections (default 100). At 4 attempts/min with wrong password, the monitoring host is blocked in 25 minutes. Unlike PostgreSQL, this is *automatic and silent* — requires `FLUSH HOSTS` to recover.
4. **No backoff on persistent failures** — same as PostgreSQL, but worse due to #3.
5. **Server-side query not killed on context cancel** — need `SET SESSION max_execution_time` before canary query.

**Proposed mitigation:** Error-aware shunning with exponential backoff (shared package with nri-postgresql). MySQL-specific: `mysql_error_1129` (host blocked) gets extra-long backoff since it requires human intervention.

## What I Need

Implement in priority order:

1. **The shared shunning package** — `ShunManager` with `Clock` interface, `IsShunnable` interface (so PG and MySQL can provide their own classification), `LoadState`/`SaveState`, exponential backoff with cap at 60 cycles.

2. **MySQL-specific `IsShunnable` implementation** — covers `mysql_error_1045` (auth), `mysql_error_1044` (db access), `mysql_error_1049` (unknown db), `mysql_error_1129` (host blocked, extra-long backoff), `dns_resolution_failed`, `connection_refused`, `ssl_error`.

3. **Shunning tests** — fake clock, state machine (backoff progression, cap, reset, TTL expiry), file persistence, corrupt file, multi-instance independence. Table-driven error classification.

4. **Connection leak tests** — connection spy asserting `db.Close()` on auth failure path. Integration test: 20 cycles with wrong password against MySQL with `max_connections=20`, assert no "Too many connections". `SHOW PROCESSLIST` thread count assertion.

5. **`max_connect_errors` protection test** — set `max_connect_errors=5`, run repeated auth failures with backoff, verify host is NOT blocked.

6. **Must-fix items** — `defer db.Close()`, `db.SetMaxOpenConns(1)`, `SET SESSION max_execution_time` before canary query.

7. **Wire shunning into the collection loop** — shunned instances skip connection but still emit `MysqlHealthSample` with `available=0`, `shunned=true`.

## Key Files to Reference

- `src/connection/connection.go` — connection factory, pool creation
- `src/connection/timing.go` — `timingDialFunc`, `wrapTLSConfig`, `ConnectionTiming`
- `src/connection/telemetry.go` — `classifyError`, `sanitizeErrorMessage`, `telemetryAccumulator`
- `src/health/health.go` — health sample emission, COM_PING, explicit check
- `src/query_runner.go` or equivalent — main collection loop
- `src/args/args.go` — flag definitions

The repo uses go-sql-driver/mysql, testify (assert/require/mock), and Docker Compose for integration tests. Follow the existing test patterns.
```
