# nri-postgresql Availability Monitoring — Code Review & Risk Analysis

**PRs Reviewed:** [#1 Core Availability](https://github.com/brybry192/nri-postgresql/pull/1) · [#2 E2E Harness](https://github.com/brybry192/nri-postgresql/pull/2) · [#3 Dashboard](https://github.com/brybry192/nri-postgresql/pull/3)
**Date:** April 11, 2026
**Scope:** Connection/resource leaks, server-side impact, client performance, backoff strategy

-----

## Executive Summary

The PRs introduce solid opt-in observability to nri-postgresql: pgx/v5 driver migration, connection timing via DialFunc, explicit canary queries, and per-query telemetry. The architecture is sound — features default off, timing piggybacks on natural first-query dials, and the explicit check is bounded by a context timeout.

However, I’ve identified **several connection leak vectors, server-side impact risks, and missing backoff logic** that need to be addressed before these run across diverse environments at scale. The most critical finding is that persistent failure modes (auth failures, DNS issues, misconfiguration) will hammer the PostgreSQL server or upstream infrastructure on every collection cycle with zero backoff, which is the exact opposite of what a monitoring agent should do when it detects trouble.

-----

## PART 1: Connection & Resource Leak Analysis

### 1.1 — CRITICAL: `sqlx.DB` Pool Lifecycle on Repeated Failures

**Risk: Server-side connection accumulation**

The integration creates a new `PGSQLConnection` (wrapping `sqlx.DB` via `stdlib.OpenDB`) on every collection cycle. When the DB is unreachable and the new “fall through with empty collection list” logic kicks in (Bug Fix #3 from the PR), the code:

1. Calls `NewConnection()` → creates a new `sqlx.DB` pool
1. Pool creation succeeds (it’s lazy — no dial happens yet)
1. Availability check runs → DialFunc fires → connection attempt fails
1. Health samples are emitted with `available=0`
1. Process exits with code 1

The concern: **is the `sqlx.DB` pool being closed before exit?** The `sqlx.DB` wraps a `database/sql.DB` which manages a connection pool. If `db.Close()` is never called — and I don’t see evidence of a `defer con.Close()` in the main flow — then:

- On happy-path exits, Go’s process teardown closes the underlying TCP sockets. Fine.
- **On the “fall through” path**, if the DialFunc managed to establish a TCP connection but auth failed (pg_error_28), that connection sits in the pool’s idle set. The PG server sees it as an established backend. If the infra agent restarts the binary immediately (which NR infra does), you get one leaked PG backend per cycle.
- With a 15-second collection interval, that’s 4 leaked backends/minute until `idle_in_transaction_session_timeout` or `tcp_keepalives_idle` cleans them up server-side.

**Recommendation:** Add an explicit `defer con.Close()` immediately after `NewConnection()` returns successfully. This is critical for the auth-failure path where TCP connects but the session is in an error state.

### 1.2 — HIGH: `rows.Close()` Timing in `ExplicitCheck`

From the availability.go source I was able to review:

```go
rows, err := conn.QueryxContext(ctx, query)
// ... error handling ...
defer rows.Close()
result.Available = rows.Next()
```

This is correctly structured — `rows.Close()` is deferred after the nil-err check. However, there’s a subtle issue: **if the context deadline fires between `QueryxContext` returning rows and `rows.Close()` executing, pgx may need to send a protocol-level close to the server**. With a cancelled context, the underlying `*pgx.Conn` may already be in a broken state, and `rows.Close()` could block or silently fail to release the server-side cursor.

In pgx/v5 via stdlib, this is generally handled well — `rows.Close()` is a no-op if the connection is already broken. But in edge cases with TLS connections through proxies (PgBouncer, RDS Proxy, HAProxy), a half-closed TLS session can leave the proxy holding a server connection.

**Recommendation:** Wrap the rows iteration in an explicit check:

```go
if err == nil {
    defer rows.Close()
    result.Available = rows.Next()
    // ...
}
```

(This is already what the code does — verified. The risk is low but worth documenting for proxy environments.)

### 1.3 — MEDIUM: DialFunc Connection Not Returned to Pool on Timing-Only Path

From the commit messages, when only `COLLECT_CONNECTION_TIMING` is true (no availability check), a `Ping()` is used to trigger the DialFunc. The `Ping()` call:

1. Acquires a connection from the pool (triggers DialFunc → DNS + TCP)
1. Sends a protocol-level ping
1. Returns the connection to the pool

The connection is now sitting in the pool’s idle set. If the main collection queries use a different database connection (the integration opens per-database connections for table/index metrics), this timing connection may sit idle for the entire cycle and only be cleaned up on process exit.

**Server-side impact:** One extra idle connection per cycle per monitored instance. With 50 monitored instances, that’s 50 idle PG backends consuming ~5-10MB each of PG shared memory.

**Recommendation:** Consider explicitly closing the pool connection used for timing after capturing the measurements, or document that `COLLECT_CONNECTION_TIMING` adds one persistent idle connection per monitored instance.

### 1.4 — MEDIUM: Per-Database Connection Multiplication

The existing nri-postgresql architecture opens a new connection per database for table/index metrics. With the pgx migration, each of these connections goes through `stdlib.OpenDB`, creating a new `sql.DB` pool per database. If `COLLECT_QUERY_TELEMETRY` is enabled, the telemetry accumulator records timing for queries across all these per-database connections.

The question is: **are all these per-database pools closed at end of cycle?** The original lib/pq code had the same lifecycle, so this isn’t a regression — but the pgx migration changes the pool implementation under the hood, and pgx’s `stdlib.OpenDB` pools have different default settings than `database/sql`’s defaults with lib/pq.

Specifically, pgx’s stdlib connector doesn’t set `MaxOpenConns` by default, meaning the pool can grow unbounded if queries are issued concurrently. The original lib/pq path via `sql.Open` had the same default, but lib/pq connections are lighter weight than pgx connections (pgx maintains more internal state per connection).

**Recommendation:** Explicitly set `db.SetMaxOpenConns(1)` on the `sql.DB` returned by `stdlib.OpenDB`, since the integration is single-threaded and only needs one connection per database.

-----

## PART 2: Server-Side Impact Analysis

### 2.1 — CRITICAL: No Backoff on Persistent Failures

This is the most important finding. The integration runs on a fixed interval (typically 15-30 seconds). When a failure is persistent — wrong password, expired cert, DNS misconfiguration, PG server in recovery mode — the integration will:

1. Attempt a full TCP+TLS+Auth handshake every cycle
1. Run the availability check query (which will fail)
1. Emit `available=0` with the error code
1. Exit, get restarted by the infra agent, repeat

For **auth failures** (`pg_error_28`), every attempt:

- Opens a TCP connection to PG
- Completes the TLS handshake
- Sends the StartupMessage
- PG forks a new backend process, loads the auth config, evaluates pg_hba.conf
- PG rejects the auth and logs an error to `postgresql.log`
- Backend process exits

At 15-second intervals, that’s **4 failed auth attempts per minute**, each appearing in PG’s log. In environments with log shipping (CloudWatch, Datadog, etc.), this generates continuous noise. In environments with `log_connections = on` and fail2ban-style tooling, it could trigger lockouts.

For **DNS failures**, the impact is upstream — every cycle issues a DNS lookup that either times out (consuming a goroutine for the timeout duration) or immediately fails. In Kubernetes with CoreDNS, rapid DNS failures can cause NXDOMAIN storms that affect other pods.

For **connection_refused** (PG is down), each attempt triggers a TCP SYN → RST exchange. On cloud infrastructure with security groups, these rejected connections may be logged and billed.

### 2.2 — HIGH: Availability Check Query Execution Cost

The default `SELECT 1` is trivially cheap, but the PR allows custom queries via `AVAILABILITY_CHECK_QUERY`. Users could configure:

```sql
SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()
```

This is fine. But nothing prevents a user from setting:

```sql
SELECT count(*) FROM large_table
```

There’s no validation or guardrail on the query. Combined with the timeout (default 10 seconds), a bad canary query could hold a PG backend busy for 10 seconds every 15-second cycle — effectively consuming 67% of one backend’s capacity.

**Recommendation:** Add a `statement_timeout` SET at the session level before running the canary query, independent of the context timeout. The context timeout prevents the *client* from waiting, but a cancelled query may still run on the server if `statement_timeout` isn’t set.

```go
// Before running the canary:
conn.Exec("SET statement_timeout = '5000'")  // ms
```

This ensures the server also kills the query, not just the client.

### 2.3 — MEDIUM: Connection Timing DialFunc and DNS Retry Storms

The `timingDialFunc` wraps the standard dialer to measure DNS and TCP timing. When DNS fails, the DialFunc captures the timing and returns the error. But `database/sql`‘s connection pool has retry logic — if a connection attempt fails, it may retry based on the pool’s internal backoff. With pgx’s stdlib integration, the retry behavior depends on whether the pool considers the failure transient.

If the pool retries, the DialFunc fires again, issuing another DNS lookup. Combined with the 10-second availability check timeout, you could get multiple DNS lookups per cycle within the timeout window.

**Recommendation:** Verify that `stdlib.OpenDB` with a single `Ping()` or `QueryxContext` call does not internally retry connection establishment. If it does, the DialFunc measurements would be for the *last* attempt, not the first, which would make the timing data misleading.

-----

## PART 3: Backoff / Shunning Strategy Recommendation

This is where I think you can make the biggest impact. The current design treats every collection cycle identically — there’s no memory of previous failures. Here’s a concrete shunning strategy:

### 3.1 — Proposed: Error-Aware Shunning with Exponential Backoff

```
┌─────────────────────┐
│   Collection Cycle   │
│   Starts             │
└──────────┬──────────┘
           │
           ▼
    ┌──────────────┐     YES    ┌───────────────────┐
    │ Is instance  ├───────────►│ Emit cached        │
    │ shunned?     │            │ available=0 sample │
    └──────┬───────┘            │ with last errorCode│
           │ NO                 │ + shunned=true     │
           ▼                    └─────────┬─────────┘
    ┌──────────────┐                      │
    │ Normal check │                      ▼
    └──────┬───────┘              ┌───────────────┐
           │                      │ Decrement TTL │
      ┌────┴────┐                 │ If TTL=0:     │
      │         │                 │   unshun      │
    OK      FAIL                  └───────────────┘
      │         │
      ▼         ▼
   Reset    ┌──────────────────┐
   shun     │ Classify error:  │
   state    │                  │
            │ SHUNNABLE?       │
            │ • auth_failed    │
            │ • ssl_error      │
            │ • dns_resolution │
            │   _failed        │
            │ • connection     │
            │   _refused       │
            │                  │
            │ NOT SHUNNABLE:   │
            │ • timeout        │
            │ • pg_error_57    │
            │ • unknown_error  │
            └────────┬─────────┘
                     │
               SHUNNABLE
                     │
                     ▼
            ┌──────────────────┐
            │ Set shun TTL:    │
            │                  │
            │ First fail: 2    │
            │ 2nd:        4    │
            │ 3rd:        8    │
            │ 4th:       16    │
            │ Max:       60    │
            │ (cycles)         │
            └──────────────────┘
```

### 3.2 — Shunnable vs. Non-Shunnable Errors

The key insight is that **not all errors deserve backoff**:

|Error Code             |Shunnable?  |Rationale                                                         |
|-----------------------|------------|------------------------------------------------------------------|
|`auth_failed`          |**YES**     |Won’t self-resolve. Human must fix password/pg_hba.conf           |
|`ssl_error`            |**YES**     |Certificate issue. Won’t self-resolve                             |
|`dns_resolution_failed`|**YES**     |Usually config error. Might self-resolve but worth backing off    |
|`connection_refused`   |**Soft YES**|PG is down. Will self-resolve on restart, but hammering won’t help|
|`timeout`              |**NO**      |Transient. Server might be under load. Next cycle could work      |
|`pg_error_57`          |**NO**      |Admin killed query/backend. Transient by nature                   |
|`unknown_error`        |**NO**      |Can’t predict. Try again next cycle                               |

### 3.3 — Implementation Sketch

Since nri-postgresql is a short-lived binary (exits after each collection), shun state must be stored externally. Options:

**Option A: Filesystem state file (simplest)**

```go
// /var/db/newrelic-infra/nri-postgresql-shun.json
{
  "instances": {
    "prod-pg-01:5432": {
      "shunUntilCycle": 1712847600,
      "consecutiveFailures": 3,
      "lastErrorCode": "auth_failed",
      "lastErrorTime": "2026-04-11T10:00:00Z"
    }
  }
}
```

The binary reads this file at startup, checks if the current instance is shunned, and if so, emits a cached `available=0` sample with `shunned=true` without attempting any connection. On shun expiry, it tries again. On success, it clears the shun entry. On failure, it doubles the TTL.

**Option B: Environment variable handoff**
The NR infra agent can pass state between invocations via environment variables. Less reliable, but avoids filesystem writes.

**Option A is strongly recommended** — it’s simple, debuggable (operators can `cat` the file), and can be manually cleared (`rm` the file) to force an immediate retry.

### 3.4 — Backoff Ceiling and Alerting Interaction

The backoff ceiling (proposed: 60 cycles ≈ 15 minutes at 15s intervals) must be chosen carefully:

- **Too short** (< 5 cycles): Doesn’t meaningfully reduce load
- **Too long** (> 120 cycles / 30 min): Creates gaps in the availability time series that could cause NRQL `SINCE` queries to miss the failure entirely
- **Sweet spot**: 60 cycles (≈ 15 min) — still emits `available=0` every cycle (so alerts fire), but doesn’t attempt a real connection

The critical design point: **even when shunned, the integration MUST still emit `available=0` health samples**. The shunning only suppresses the connection attempt, not the metric emission. This ensures NRQL alert conditions continue to see the outage.

-----

## PART 4: Additional Findings

### 4.1 — Value Receiver Bug Was a Near-Miss

The PR documents fixing a bug where `Query`/`Queryx` had value receivers, causing the telemetry accumulator to be silently discarded on each call. The fix (changing to `*telemetryAccumulator`) is correct, but this pattern is a code smell that could reappear:

**Recommendation:** Add a `go vet` check or linter rule that flags value receivers on `PGSQLConnection`. Consider making `PGSQLConnection` implement an interface — interface values always hold pointers, making value-receiver mutations impossible.

### 4.2 — Context Cancellation vs. pgx Statement Cancellation

When the availability check context expires, Go cancels the context. pgx v5 via stdlib handles this by sending a CancelRequest message to PostgreSQL (protocol-level cancellation). This is correct behavior — it frees the server-side backend.

However, CancelRequest in PostgreSQL is inherently racy — it sends a cancel signal to the backend process, which may or may not be processing the query at that moment. If the backend has already finished the query but the network is slow, the cancel may hit the *next* query on that connection. Since the pool reuses connections, a stale cancel could affect a subsequent monitoring query.

pgx v5 handles this by marking connections that received a cancel as needing a reset, so this is mitigated. But document this behavior for proxy environments (PgBouncer transaction pooling) where the “connection” the cancel targets may have been reassigned to a different client.

### 4.3 — TLS DialFunc Interaction

The `timingDialFunc` measures DNS and TCP time. But when TLS is enabled (which it should be in production), the TLS handshake happens *after* the TCP connect and *inside* the DialFunc (since pgx’s `DialFunc` returns a `net.Conn`, and TLS wrapping happens at a different layer).

Actually, re-reading the pgx architecture: the `DialFunc` returns a raw TCP `net.Conn`. TLS is handled by pgx’s `ConnConfig.TLSConfig` — pgx wraps the raw conn in `tls.Client` *after* the DialFunc returns. This means the DialFunc timing correctly captures only DNS+TCP, and TLS time would need to be measured separately (via the `TLSConfig.VerifyConnection` callback or by timing around the Ping).

The commit messages mention removing `TotalConnectMs` and `TLSAndAuthMs` — which is the right call since they required an extra Ping. But this means **TLS handshake time is invisible** in the current implementation. For environments where TLS certificate chain validation is slow (large CRL lists, OCSP stapling), this is a blind spot.

**Recommendation:** Document that TLS handshake time is not currently measured. Consider adding it in a follow-up via `tls.Config.VerifyConnection` timing if there’s demand.

### 4.4 — Error Message Credential Sanitization

The commit messages mention sanitizing error messages to redact credentials from PostgreSQL connection URLs. This is critical — pgx error messages can include the DSN which contains the password. Verify that the sanitization covers:

- `postgresql://user:password@host/db` format
- `host=x password=y` key-value format
- Error messages from `pgconn.PgError` which may echo back the startup parameters

-----

## PART 5: Summary of Recommendations

### Must Fix (Before Merge)

|#|Issue                                                    |Severity|Impact                                            |
|-|---------------------------------------------------------|--------|--------------------------------------------------|
|1|Add `defer con.Close()` after `NewConnection()`          |CRITICAL|Connection leak on auth failures                  |
|2|Set `db.SetMaxOpenConns(1)` on pools from `stdlib.OpenDB`|HIGH    |Unbounded pool growth                             |
|3|Add `SET statement_timeout` before canary query          |HIGH    |Server-side query not cancelled on context timeout|

### Should Fix (Before Production Rollout)

|#|Issue                                                       |Severity|Impact                               |
|-|------------------------------------------------------------|--------|-------------------------------------|
|4|Implement shunning/backoff for persistent failures          |HIGH    |Reduces server hammering on misconfig|
|5|Document idle connection cost of `COLLECT_CONNECTION_TIMING`|MEDIUM  |Capacity planning                    |
|6|Validate canary query doesn’t contain dangerous patterns    |MEDIUM  |Prevent accidental heavy queries     |

### Nice to Have (Follow-Up)

|#|Issue                                                      |Severity|Impact                              |
|-|-----------------------------------------------------------|--------|------------------------------------|
|7|Add TLS handshake timing measurement                       |LOW     |Complete connection phase visibility|
|8|Linter rule against value receivers on PGSQLConnection     |LOW     |Prevent regression of bug #2        |
|9|Document proxy (PgBouncer) interaction with cancel protocol|LOW     |Operational awareness               |

-----

## Appendix: Shunning State File Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "version": { "type": "integer", "const": 1 },
    "instances": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "properties": {
          "shunUntilUnix": {
            "type": "integer",
            "description": "Unix timestamp when shun expires"
          },
          "consecutiveShunnableFailures": {
            "type": "integer",
            "description": "Consecutive failures with shunnable error codes"
          },
          "lastErrorCode": {
            "type": "string",
            "description": "Most recent classified error code"
          },
          "lastErrorMessage": {
            "type": "string",
            "description": "Most recent sanitized error message"
          },
          "lastAttemptUnix": {
            "type": "integer",
            "description": "Unix timestamp of last real connection attempt"
          },
          "backoffCycles": {
            "type": "integer",
            "description": "Current backoff in cycles (2, 4, 8, 16, 32, 60 max)"
          }
        },
        "required": ["shunUntilUnix", "consecutiveShunnableFailures", "lastErrorCode"]
      }
    }
  }
}
```
# Test Proposal: Connection Safety, Backoff, and Resource Lifecycle

**Related:** [PR Review Report](./nri-postgresql-pr-review-report.md)
**Date:** April 11, 2026

-----

## 1. What Exists Today

The current test suite (from PR #1) covers:

|Layer      |File                     |What It Tests                                                                                                                 |
|-----------|-------------------------|------------------------------------------------------------------------------------------------------------------------------|
|Unit       |`availability_test.go`   |ExplicitCheck happy path, error path, timeout/cancellation, custom query                                                      |
|Unit       |`query_telemetry_test.go`|Accumulation, drain, disabled state, error classification, query name extraction                                              |
|Unit       |`timing_test.go`         |DialFunc DNS/TCP measurement, DNS failure timing capture                                                                      |
|Unit       |`metrics_test.go`        |publishConnectionSample, publishAvailabilityCheckSample, publishQueryTelemetrySamples, PopulateMetrics with flags             |
|Integration|`postgresql_test.go`     |ConnectionSampleAlwaysEmitted, ObservabilityFlags (table-driven), ConnectionFailureAvailabilityCheck, AvailabilityCheckTimeout|
|E2E        |`test-availability.sh`   |Container stop, network disconnect, container pause, password change, query cancel, backend terminate                         |

**What’s missing:** Every existing test treats each collection cycle as independent. No test verifies what happens across repeated cycles with the same failure, validates resource cleanup, measures server-side connection count, or exercises backoff behavior. The tests below fill those gaps.

-----

## 2. Proposed Test Structure

```
src/
├── connection/
│   ├── pool_lifecycle_test.go        ← NEW: 2.1
│   └── shun/
│       ├── shun.go                   ← NEW: backoff/shunning implementation
│       ├── shun_test.go              ← NEW: 2.2
│       └── testdata/
│           ├── shun_state_valid.json
│           ├── shun_state_corrupt.json
│           └── shun_state_v0.json
├── availability/
│   ├── availability_test.go          ← EXISTING + additions (2.3)
│   └── canary_safety_test.go         ← NEW: 2.4
├── metrics/
│   └── metrics_test.go              ← EXISTING + additions (2.5)
tests/
├── postgresql_test.go               ← EXISTING + additions (2.6)
└── e2e/
    └── test-availability.sh          ← EXISTING + additions (2.7)
```

-----

## 2.1 — Pool Lifecycle Tests (`pool_lifecycle_test.go`)

**Purpose:** Prove that `sqlx.DB` pools are closed on every exit path and that connection counts stay bounded.

These are the highest-priority new tests. They directly address the connection leak risks identified in the review.

### Test: Pool Is Closed After Successful Collection

```
Given: A working PostgreSQL instance
When:  A full collection cycle completes (NewConnection → metrics → exit)
Then:  con.Close() is called before the function returns
       The underlying sql.DB reports 0 open connections after Close()
```

**Implementation approach:** Wrap `stdlib.OpenDB` in a test spy that records `Close()` calls. Run `PopulateMetrics` to completion. Assert the spy saw exactly one `Close()` call. Also query `db.Stats().OpenConnections` and assert it’s 0 after close.

### Test: Pool Is Closed After Connection Failure (Auth)

```
Given: A PostgreSQL instance with the wrong password configured
When:  NewConnection succeeds (lazy pool) but the first query triggers auth failure
Then:  con.Close() is called before the function returns
       No TCP connections remain open to the server
```

**Implementation approach:** Use a real PG instance (Docker) with a mismatched password. After the cycle, use `pg_stat_activity` from a *separate* admin connection to assert there are zero backends from the monitoring user. This is a critical test — it catches the leak described in review finding 1.1.

### Test: Pool Is Closed After Connection Failure (DNS)

```
Given: A hostname that does not resolve (e.g., "nonexistent.invalid")
When:  NewConnection is called
Then:  con.Close() is called (even though no TCP was established)
       No goroutines are leaked (DNS resolver goroutine returns)
```

**Implementation approach:** Use `runtime.NumGoroutine()` before and after. Allow a small delta (the Go runtime has background goroutines) but fail if goroutine count grows by more than 2. This catches DNS resolver goroutines that get stuck on unreachable nameservers.

### Test: Pool MaxOpenConns Is Bounded

```
Given: A working PostgreSQL instance
When:  NewConnection creates a pool via stdlib.OpenDB
Then:  db.Stats().MaxOpenConnections == 1
       (or whatever bound is set)
```

**Implementation approach:** Direct assertion on the `sql.DB` stats. This is a simple regression guard for review finding 1.4.

### Test: Per-Database Connections Are All Closed

```
Given: A PG instance with 3 databases (db1, db2, db3)
When:  A full collection cycle runs (table + index metrics for all 3)
Then:  pg_stat_activity shows 0 backends from the monitoring user after cycle
```

**Implementation approach:** Integration test with Docker PG. Count `pg_stat_activity WHERE usename = 'newrelic'` before the cycle starts, after it completes, and 2 seconds later. All three counts should be equal (ideally 0 for the admin connection’s perspective, but the admin connection itself will be 1).

### Test: Rapid Successive Cycles Don’t Accumulate Connections

```
Given: A working PostgreSQL instance
When:  10 collection cycles run back-to-back (simulating fast restarts)
Then:  Peak pg_stat_activity count never exceeds 2
       (1 for the current cycle + 1 transient overlap)
       Final count after all cycles is 0
```

**Implementation approach:** This is the stress test for the leak scenario. Run the integration binary 10 times in a bash loop, sampling `pg_stat_activity` between each run. Use `max_connections = 20` on the test PG instance so a leak would hit the limit and cause visible failures.

-----

## 2.2 — Shunning / Backoff Tests (`shun_test.go`)

**Purpose:** Validate the backoff state machine independently of the database, using pure Go unit tests with a fake clock.

### Test: First Shunnable Failure Sets Backoff to 2 Cycles

```
Given: No prior shun state for instance "pg-01:5432"
When:  RecordFailure("pg-01:5432", "auth_failed") is called
Then:  IsShunned("pg-01:5432") returns true
       ShunState.BackoffCycles == 2
       ShunState.ConsecutiveShunnableFailures == 1
```

### Test: Consecutive Shunnable Failures Double Backoff

```
Given: Instance "pg-01:5432" has 1 prior shunnable failure (backoff=2)
When:  RecordFailure("pg-01:5432", "auth_failed") is called again
Then:  ShunState.BackoffCycles == 4
       ShunState.ConsecutiveShunnableFailures == 2
```

### Test: Backoff Caps at Maximum

```
Given: Instance "pg-01:5432" has been failing for 10 consecutive cycles
When:  RecordFailure is called again
Then:  ShunState.BackoffCycles == 60 (cap)
       It does not grow beyond 60
```

### Test: Success Clears Shun State

```
Given: Instance "pg-01:5432" is shunned with backoff=16
When:  RecordSuccess("pg-01:5432") is called
Then:  IsShunned("pg-01:5432") returns false
       ShunState is removed from the state map
```

### Test: Shun Expires After TTL Cycles

```
Given: Instance "pg-01:5432" was shunned 2 cycles ago with backoff=2
When:  IsShunned("pg-01:5432") is checked (using fake clock advanced 2 cycles)
Then:  Returns false (shun expired, time to retry)
```

### Test: Non-Shunnable Errors Don’t Trigger Shunning

```
Given: No prior shun state
When:  RecordFailure("pg-01:5432", "timeout") is called
Then:  IsShunned("pg-01:5432") returns false
       (timeouts are transient — retry immediately)
```

Table-driven across all error codes:

```go
func TestShunnableErrorClassification(t *testing.T) {
    tests := []struct {
        errorCode  string
        shunnable  bool
    }{
        {"auth_failed",           true},
        {"ssl_error",             true},
        {"dns_resolution_failed", true},
        {"connection_refused",    true},
        {"timeout",               false},
        {"pg_error_57",           false},
        {"pg_error_28",           true},  // auth class
        {"unknown_error",         false},
    }
    // ...
}
```

### Test: State File Persistence — Write and Read Back

```
Given: Shun state with 3 instances in various states
When:  SaveState(path) is called, then LoadState(path) on a new ShunManager
Then:  All 3 instances' states match exactly
       Timestamps survive the round-trip
```

### Test: State File — Corrupt File Treated as Empty

```
Given: A state file containing invalid JSON
When:  LoadState(path) is called
Then:  Returns empty state (no shunned instances)
       Logs a warning
       Does not crash or panic
```

### Test: State File — Missing File Treated as Empty

```
Given: No state file exists at the configured path
When:  LoadState(path) is called
Then:  Returns empty state
       No error logged (this is normal for first run)
```

### Test: State File — Permission Denied on Write

```
Given: State file path is in a read-only directory
When:  SaveState(path) is called
Then:  Returns an error
       Does not crash
       Shun state still works in-memory for the current cycle
```

### Test: Multiple Instances Are Independent

```
Given: "pg-01" is shunned (auth_failed, backoff=8)
       "pg-02" is not shunned
       "pg-03" is shunned (dns, backoff=2, expired)
When:  IsShunned is checked for each
Then:  pg-01: true (still in backoff window)
       pg-02: false (never failed)
       pg-03: false (shun expired, will retry)
```

### Test: Shunned Instance Still Emits available=0

```
Given: Instance "pg-01" is shunned
When:  The collection cycle runs for pg-01
Then:  A PostgresqlHealthSample is emitted with:
         available=0
         errorCode=(last known error code)
         shunned=true
         shunRemainingCycles=N
       No TCP connection is attempted
```

This is the most important behavioral test — it validates that shunning is invisible to downstream alerting.

-----

## 2.3 — Availability Check Additions (`availability_test.go`)

### Test: ExplicitCheck — Context Cancelled After Rows Returned

```
Given: A query that returns rows, but context is cancelled during rows.Next()
When:  ExplicitCheck runs
Then:  rows.Close() is still called (no leak)
       Result has errorCode="timeout"
       Result.Available is false
```

**Implementation approach:** Use a mock connection where `QueryxContext` returns valid rows but the context is cancelled by a goroutine with a small delay. Verify `rows.Close()` was called via mock assertions.

### Test: ExplicitCheck — Rows Object is Nil-Safe

```
Given: QueryxContext returns (nil, error)
When:  ExplicitCheck runs
Then:  Does not panic on nil rows
       Returns available=false with classified error
```

This is already likely covered, but make it explicit — some database/sql drivers return non-nil rows even on error.

### Test: ExplicitCheck — Custom Query Returning Multiple Rows

```
Given: AVAILABILITY_CHECK_QUERY = "SELECT generate_series(1, 100)"
When:  ExplicitCheck runs
Then:  Available=true (at least one row)
       Only the first row is consumed (rows.Next called once)
       rows.Close() releases the remaining 99 rows server-side
```

This validates that the check doesn’t drain the entire result set.

### Test: ExplicitCheck — Query Returning Zero Rows

```
Given: AVAILABILITY_CHECK_QUERY = "SELECT 1 WHERE false"
When:  ExplicitCheck runs
Then:  Available=false
       No error code (zero rows is not an error, but not "available")
```

This is an edge case — a valid query that returns no rows should be distinguishable from a failed query.

-----

## 2.4 — Canary Query Safety Tests (`canary_safety_test.go`)

**Purpose:** Validate guardrails around user-supplied availability check queries.

### Test: Statement Timeout Is Set Before Canary Query

```
Given: A canary query configured as "SELECT pg_sleep(30)"
       AVAILABILITY_CHECK_TIMEOUT_MS = 500
When:  ExplicitCheck runs
Then:  The server-side backend is cancelled within ~500ms
       (not just the client context — the server stops work)
```

**Implementation approach:** Integration test with Docker PG. After triggering the timeout, immediately query `pg_stat_activity` and assert no backend is still running `pg_sleep`.

### Test: Canary Query Cannot Execute DDL

```
Given: AVAILABILITY_CHECK_QUERY = "DROP TABLE IF EXISTS important"
When:  The query is validated before execution
Then:  Validation rejects the query (if validation is implemented)
       OR: the monitoring user has no DDL permissions (defense in depth)
```

This is more of a documentation/operational test. If we add query validation, test it. If we rely on PG permissions, test that the recommended monitoring role lacks DDL grants.

### Test: Canary Query Error Does Not Leak Query Text in Logs

```
Given: AVAILABILITY_CHECK_QUERY contains sensitive info
       (e.g., "SELECT * FROM secrets WHERE token = 'abc123'")
When:  The query fails
Then:  The error message in the health sample does not contain 'abc123'
       The log output does not contain 'abc123'
```

The query itself is intentionally reported in the health sample (`db.availabilityCheck.query`), which is fine. But error messages from PG might echo parameters — verify sanitization.

-----

## 2.5 — Metrics Tests Additions (`metrics_test.go`)

### Test: PopulateMetrics Emits Samples When Connection Fails

```
Given: NewConnection returns an error (unreachable host)
       ENABLE_AVAILABILITY_CHECK = true
When:  PopulateMetrics runs
Then:  Both implicit (checkType=implicit) and explicit (checkType=explicit)
       samples are emitted with available=0
       The process does not call os.Exit before Publish()
```

This is the regression test for Bug Fix #3 from the PR. The existing test covers it partially, but add an explicit assertion that `Publish()` was called before any exit.

### Test: PopulateMetrics With Shunned Instance

```
Given: Instance is shunned (auth_failed, 3 cycles remaining)
When:  PopulateMetrics runs
Then:  No NewConnection call is made
       Health samples are emitted with cached error info + shunned=true
       Publish() is called
       Shun TTL is decremented
```

### Test: Connection Timing Values Are Non-Zero After Check

```
Given: COLLECT_CONNECTION_TIMING = true, ENABLE_AVAILABILITY_CHECK = true
When:  PopulateMetrics runs against a real PG (Docker)
Then:  con.Timing.DNSLookupMs > 0
       con.Timing.TCPConnectMs > 0
       Both values appear in the published health sample
```

The PR documented that timing was always 0 before the fix (Bug #4). This regression test ensures the ordering (ExplicitCheck → then publishConnectionSample) stays correct.

-----

## 2.6 — Integration Test Additions (`postgresql_test.go`)

### Test: RepeatedFailureCyclesDoNotLeakConnections

```
Given: PG instance with max_connections=10, wrong password configured
When:  The integration binary runs 15 times back-to-back
Then:  Every run completes (no "too many connections" error)
       pg_stat_activity never exceeds 2 backends from the test user
```

**Implementation approach:** This is a Go integration test that shells out to the compiled binary. Between runs, query `pg_stat_activity` via an admin connection. This is THE definitive connection leak test.

### Test: TimeoutDoesNotLeaveServerBackend

```
Given: AVAILABILITY_CHECK_QUERY = "SELECT pg_sleep(30)"
       AVAILABILITY_CHECK_TIMEOUT_MS = 500
When:  The integration binary runs
Then:  Binary exits within ~1 second (not 30)
       pg_stat_activity shows no backends running pg_sleep
       within 2 seconds of the binary exiting
```

**Implementation approach:** Run the binary, wait for exit, then immediately check `pg_stat_activity` for lingering `pg_sleep` queries. If statement_timeout is properly set, the backend should be gone.

### Test: AuthFailureDoesNotLeaveIdleConnection

```
Given: PG instance, monitoring user password changed mid-cycle
When:  Integration binary runs with stale password
Then:  Binary emits available=0 with errorCode=pg_error_28
       pg_stat_activity shows 0 connections from the monitoring user
       after the binary exits
```

This specifically targets the auth-failure TCP leak path.

### Test: ConcurrentDatabaseCollectionConnectionCount

```
Given: PG instance with 5 databases
       All observability flags enabled
When:  Integration binary runs one full cycle
Then:  Peak pg_stat_activity from monitoring user <= 2
       (1 main connection + 1 per-database, but only 1 at a time)
       After binary exits: 0 connections
```

Validates that per-database connections are sequential, not parallel, and all are cleaned up.

-----

## 2.7 — E2E Test Additions (`test-availability.sh`)

### Test 6: Repeated Auth Failure — Connection Count Stability

```bash
# Change password, wait for 5 collection cycles, check pg_stat_activity
# via admin connection. Assert connection count stays <= 1 across all 5 cycles.
# This catches the "leaked backend per cycle" pattern.

echo "=== Test 6: Repeated auth failure connection stability ==="
docker exec e2e-postgres-1 psql -U admin -c \
  "ALTER USER newrelic PASSWORD 'wrong';"

for i in $(seq 1 5); do
  sleep $INTERVAL
  COUNT=$(docker exec e2e-postgres-1 psql -U admin -tA -c \
    "SELECT count(*) FROM pg_stat_activity WHERE usename='newrelic';")
  echo "  Cycle $i: $COUNT connections from monitoring user"
  if [ "$COUNT" -gt 1 ]; then
    echo "  FAIL: connection leak detected ($COUNT > 1)"
    LEAKED=true
  fi
done

# Restore password
docker exec e2e-postgres-1 psql -U admin -c \
  "ALTER USER newrelic PASSWORD 'correct';"
```

### Test 7: Shunning Behavior Validation

```bash
# After test 6 runs (auth failure), verify that:
# 1. The shun state file exists and contains pg-01
# 2. Subsequent cycles don't attempt TCP connections (check netstat/ss)
# 3. Health samples are still emitted with shunned=true
# 4. After clearing the shun file, the next cycle retries

echo "=== Test 7: Shunning behavior ==="

# Check shun state file
SHUN_FILE="/var/db/newrelic-infra/nri-postgresql-shun.json"
if docker exec newrelic-infra cat "$SHUN_FILE" | jq -e '.instances["e2e-postgres-1:5432"]'; then
  echo "  PASS: instance is shunned"
else
  echo "  MISS: shun state not written"
fi

# Wait 2 cycles, verify no new TCP SYNs to postgres port
docker exec newrelic-infra bash -c \
  "ss -tn state syn-sent dst e2e-postgres-1:5432" | grep -c "SYN" || true

# Verify health samples still emitting
# (NerdGraph query for PostgresqlHealthSample WHERE shunned=true)
```

### Test 8: Shun Recovery — Automatic Retry After Expiry

```bash
# After test 7, restore correct password and wait for shun to expire.
# Verify the instance recovers to available=1 without manual intervention.

echo "=== Test 8: Shun recovery ==="
docker exec e2e-postgres-1 psql -U admin -c \
  "ALTER USER newrelic PASSWORD 'correct';"

# Wait for shun expiry (backoff * interval)
# With backoff=2 and interval=10s, wait 25s to be safe
sleep 25

# Query NerdGraph for latest health sample
# Assert available=1 and shunned is absent
```

-----

## 3. Test Infrastructure Needs

### 3.1 — Fake Clock for Shunning Tests

The shunning state machine uses wall-clock time for TTL expiry. Unit tests need a controllable clock:

```go
type Clock interface {
    Now() time.Time
}

type realClock struct{}
func (realClock) Now() time.Time { return time.Now() }

type fakeClock struct {
    current time.Time
}
func (c *fakeClock) Now() time.Time { return c.current }
func (c *fakeClock) Advance(d time.Duration) { c.current = c.current.Add(d) }
```

Inject `Clock` into `ShunManager`. Production uses `realClock`. Tests use `fakeClock` with deterministic advancement.

### 3.2 — Connection Spy for Pool Lifecycle Tests

```go
type connectionSpy struct {
    *sqlx.DB
    closeCalled int
    mu          sync.Mutex
}

func (s *connectionSpy) Close() error {
    s.mu.Lock()
    s.closeCalled++
    s.mu.Unlock()
    return s.DB.Close()
}
```

Wrap the real `sqlx.DB` in the spy. Assert `closeCalled == 1` at end of each test.

### 3.3 — pg_stat_activity Helper

For integration tests that check server-side connection state:

```go
func getActiveConnections(t *testing.T, adminDSN string, monitoringUser string) int {
    t.Helper()
    db, err := sql.Open("pgx", adminDSN)
    require.NoError(t, err)
    defer db.Close()

    var count int
    err = db.QueryRow(
        "SELECT count(*) FROM pg_stat_activity WHERE usename = $1 AND pid != pg_backend_pid()",
        monitoringUser,
    ).Scan(&count)
    require.NoError(t, err)
    return count
}
```

Use with `assert.Eventually` for tests where connections take a moment to clean up:

```go
assert.Eventually(t, func() bool {
    return getActiveConnections(t, adminDSN, "newrelic") == 0
}, 5*time.Second, 500*time.Millisecond,
    "monitoring user connections should reach 0 after cycle completes")
```

### 3.4 — Docker Compose Test Fixture

The integration tests need a PG instance with:

- `max_connections = 15` (low enough that leaks cause visible `too many connections` errors)
- An admin user (for `pg_stat_activity` checks)
- A monitoring user with limited permissions
- `log_connections = on` and `log_disconnections = on` (to verify cleanup in logs)

This largely exists in the e2e stack from PR #2. Factor the Docker Compose into a shared test fixture.

-----

## 4. Priority Order

|Priority|Test Suite                                    |Why                                                  |
|--------|----------------------------------------------|-----------------------------------------------------|
|**P0**  |RepeatedFailureCyclesDoNotLeakConnections     |Directly validates the #1 risk from the review       |
|**P0**  |Pool Is Closed After Connection Failure (Auth)|Catches the specific TCP leak on auth reject         |
|**P0**  |Shunnable error classification (table-driven) |Foundation for the backoff feature                   |
|**P1**  |TimeoutDoesNotLeaveServerBackend              |Validates server-side cancellation works             |
|**P1**  |Shun state persistence round-trip             |Shunning is useless if state doesn’t survive restarts|
|**P1**  |Shunned instance still emits available=0      |Alerting must not break during backoff               |
|**P1**  |Backoff exponential growth + cap              |Core state machine correctness                       |
|**P2**  |Rapid successive cycles connection count      |Stress test for the overall lifecycle                |
|**P2**  |Per-database connection cleanup               |Validates the broader pool management                |
|**P2**  |E2E repeated auth failure connection stability|End-to-end validation of the leak fix                |
|**P3**  |Canary query safety tests                     |Defense in depth                                     |
|**P3**  |Corrupt/missing state file handling           |Robustness edge cases                                |
|**P3**  |Custom query returning zero rows              |Behavioral edge case                                 |

-----

## 5. Coverage Mapping to Review Findings

|Review Finding                                  |Tests That Cover It                                                                                                             |
|------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
|1.1 — Pool not closed on auth failure           |Pool Is Closed After Connection Failure (Auth), AuthFailureDoesNotLeaveIdleConnection, RepeatedFailureCyclesDoNotLeakConnections|
|1.2 — rows.Close() timing with cancelled context|ExplicitCheck — Context Cancelled After Rows Returned                                                                           |
|1.3 — Idle connection from timing-only Ping     |Per-Database Connections Are All Closed, ConcurrentDatabaseCollectionConnectionCount                                            |
|1.4 — Unbounded pool growth                     |Pool MaxOpenConns Is Bounded                                                                                                    |
|2.1 — No backoff on persistent failures         |All shunning tests (2.2), E2E tests 6-8                                                                                         |
|2.2 — Canary query execution cost               |Statement Timeout Is Set Before Canary Query, TimeoutDoesNotLeaveServerBackend                                                  |
|2.3 — DNS retry storms                          |Pool Is Closed After Connection Failure (DNS), goroutine leak check                                                             |
|4.2 — Context cancel vs pgx cancel race         |ExplicitCheck — Context Cancelled After Rows Returned, TimeoutDoesNotLeaveServerBackend                                         |

-----

## 6. Session Handoff Prompt

Use the prompt below to spin up a new session that has full context on this project, the review findings, and the test plan. Paste it as-is, then attach the two report files and the relevant source files from the repo.

-----

```markdown
# Context

I'm working on an open-source fork of `nri-postgresql` (New Relic's PostgreSQL infrastructure integration). The fork adds opt-in availability monitoring features behind four new flags:

- `COLLECT_CONNECTION_TIMING` — DNS/TCP phase timing via pgx v5 DialFunc
- `ENABLE_AVAILABILITY_CHECK` — configurable canary query each collection cycle
- `AVAILABILITY_CHECK_TIMEOUT_MS` — context deadline bounding the canary
- `COLLECT_QUERY_TELEMETRY` — per-internal-query duration and error tracking

The driver was migrated from `lib/pq` to `pgx/v5/stdlib` (via `stdlib.OpenDB`). The integration is a short-lived Go binary invoked by the New Relic infrastructure agent every collection cycle (typically 15–30 seconds), and it exits after publishing metrics.

## PRs

- PR #1 (core): https://github.com/brybry192/nri-postgresql/pull/1
- PR #2 (e2e harness): https://github.com/brybry192/nri-postgresql/pull/2
- PR #3 (dashboard): https://github.com/brybry192/nri-postgresql/pull/3

## Review Findings

A code review identified these risks (full report attached as `nri-postgresql-pr-review-report.md`):

**Connection / resource leaks:**
1. **`sqlx.DB` pool not explicitly closed** — on auth failures, TCP connects but auth is rejected. Without `defer con.Close()`, the pool holds a half-authenticated connection until process exit. At 15s intervals that's 4 leaked PG backends/minute.
2. **`rows.Close()` timing with cancelled contexts** — if context deadline fires between `QueryxContext` returning rows and `rows.Close()`, pgx may fail to release the server-side cursor in proxy environments (PgBouncer, RDS Proxy).
3. **Idle connection from timing-only `Ping()`** — when only `COLLECT_CONNECTION_TIMING` is enabled, the Ping creates one idle connection per cycle that sits unused.
4. **Unbounded pool via `stdlib.OpenDB`** — no `SetMaxOpenConns(1)` is called, so the pool can theoretically grow despite the integration being single-threaded.

**Server-side impact:**
5. **No backoff on persistent failures** — auth failures, DNS misconfig, expired certs hammer the PG server every cycle (4 failed handshakes/minute generating log noise, CoreDNS NXDOMAIN storms in K8s, security group logging on cloud).
6. **Server-side query not killed on context cancel** — the context timeout stops the client from waiting, but without `SET statement_timeout`, a bad canary query keeps running on the PG backend.

**Proposed mitigation:** An error-aware shunning system with exponential backoff. Shunnable errors (auth_failed, ssl_error, dns_resolution_failed, connection_refused) trigger backoff (2→4→8→16→32→60 cycle cap). Non-shunnable errors (timeout, pg_error_57) retry immediately. Shunned instances still emit `available=0` health samples so NRQL alerts keep firing. State persists across invocations via a JSON file at `/var/db/newrelic-infra/nri-postgresql-shun.json`.

## Test Proposal

A test proposal is attached as `nri-postgresql-test-proposal.md`. It defines ~30 new tests across 5 layers:

- **Pool lifecycle tests** — connection spy, `pg_stat_activity` assertions, goroutine leak checks
- **Shunning unit tests** — fake clock, state machine, file persistence, error classification
- **Availability check additions** — cancelled context mid-rows, zero-row queries, nil-safety
- **Integration tests** — repeated failure leak detection, server-side cancellation, per-database cleanup
- **E2E additions** — auth failure connection stability, shunning behavior, automatic recovery

## What I Need

I need you to act as a senior Go developer and implement the following (in priority order):

1. **The shunning package** (`src/connection/shun/shun.go`) — the `ShunManager` with `Clock` interface, `IsShunned`, `RecordFailure`, `RecordSuccess`, `LoadState`, `SaveState`, and the shunnable error classification.

2. **The shunning tests** (`src/connection/shun/shun_test.go`) — full coverage of the state machine using a fake clock: backoff progression, cap, reset on success, TTL expiry, non-shunnable errors, persistence round-trip, corrupt file handling, missing file handling, multi-instance independence.

3. **The pool lifecycle tests** (`src/connection/pool_lifecycle_test.go`) — connection spy, `Close()` assertion on success path, auth failure path, DNS failure path, `MaxOpenConns` guard.

4. **Integration of shunning into `PopulateMetrics`** — wire the `ShunManager` into the main collection loop so shunned instances skip `NewConnection` but still emit health samples.

5. **The must-fix items from the review** — `defer con.Close()`, `db.SetMaxOpenConns(1)`, `SET statement_timeout` before canary query.

The repo uses `sqlx`, `testify` (assert/require/mock), `go-sqlmock` for unit tests, and Docker Compose for integration tests. The existing test patterns are in the PR descriptions above — follow the same style.

## Key Files to Reference

- `src/connection/pgsql_connection.go` — `NewConnection`, `PGSQLConnection` struct, `Query`/`Queryx`/`QueryxContext`
- `src/connection/timing.go` — `ConnectionTiming`, `timingDialFunc`
- `src/connection/query_telemetry.go` — `telemetryAccumulator`, `ClassifyError`
- `src/availability/availability.go` — `ExplicitCheck`
- `src/metrics/metrics.go` — `PopulateMetrics`, `publishConnectionSample`, `publishAvailabilityCheckSample`
- `src/main.go` — entry point, `BuildCollectionList` fallthrough logic
- `src/args/argument_list.go` — flag definitions

Please start with the shunning package and its tests, then move to the pool lifecycle tests, then wire everything together.
```
