# Go Repository Review Checklist

Use this checklist when researching a Go codebase. Not every item applies to every repo — skip what's irrelevant.

---

## Structure and Build

- [ ] Go version (from `go.mod`) and module path
- [ ] Directory layout — `cmd/`, `pkg/`, `internal/`, flat?
- [ ] Makefile targets — what does `make test` actually run?
- [ ] CI pipeline — what's enforced (lint, race, coverage gates)?
- [ ] Build tags or platform-specific code

## Dependencies

- [ ] Major dependencies and their roles (list in a table)
- [ ] Dependency currency — are any significantly outdated?
- [ ] Vendoring strategy (`vendor/`, Go modules only, or mixed?)
- [ ] Any deprecated dependencies still in use

## Code Patterns

- [ ] Error handling — wrapping with `%w`, sentinel errors, `errors.Is`/`errors.As` usage
- [ ] Error classification — transient vs permanent, retryable detection
- [ ] Concurrency — goroutine lifecycle, context propagation, sync primitives
- [ ] Nil safety — pointer fields, optional returns, interface nil checks
- [ ] Interface design — narrow interfaces, where they're defined (consumer vs provider)
- [ ] Configuration loading — flags, env vars, config files, validation

## Testing

- [ ] Unit test coverage (run `go test -race -coverprofile`)
- [ ] What's mocked vs real — are mocks masking real behavior?
- [ ] Integration tests — Docker Compose? testcontainers? Real services?
- [ ] Race detector enabled (`-race` flag in CI)?
- [ ] Test helpers or fixtures worth noting
- [ ] Coverage gaps — untested error paths, edge cases

## Observability

- [ ] Logging approach — structured? What library? Log levels?
- [ ] Metrics — what's emitted, what system (Prometheus, StatsD, custom)?
- [ ] Tracing — OpenTelemetry? Manual spans?
- [ ] Health endpoints — readiness, liveness probes

## Security

- [ ] Credential handling — how are secrets passed? Sanitized in errors/logs?
- [ ] TLS configuration — supported? Required? Configurable?
- [ ] Input validation at system boundaries

## Documentation

- [ ] README accuracy — does it reflect current state?
- [ ] Configuration reference — are all flags/env vars documented?
- [ ] Outdated references (old package managers, dead links)
