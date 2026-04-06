# NRI Integrations Research

Deep-dive research into New Relic on-host integrations (OHIs) — architecture, code flow, testing, and improvement opportunities.

---

## Table of Contents

- [NRI Plugin System Overview](#nri-plugin-system-overview)
- [Documents](#documents)
- [Quick Reference: Source Repos](#quick-reference-source-repos)

---

## NRI Plugin System Overview

All integrations in this project share the same foundational architecture:

- Written in Go, built with `infra-integrations-sdk/v3`
- Run as short-lived binaries forked by the Infrastructure Agent on each poll interval
- Emit a single-line JSON payload to stdout → picked up by the agent → forwarded to NRDB
- Configured via YAML files in `/etc/newrelic-infra/integrations.d/`

See [study-guide.md section 1](nri-postgresql/study-guide.md#1-the-nri-plugin-system--architecture-overview) for the full system overview (documented alongside nri-postgresql as the reference integration).

---

## Documents

### Integration Deep Dives

| Integration | Document | Summary |
|---|---|---|
| nri-postgresql | [study-guide.md](nri-postgresql/study-guide.md) | Full deep dive |
| nri-mysql | [study-guide.md](nri-mysql/study-guide.md) | Full deep dive |
| nri-redis | [study-guide.md](nri-redis/study-guide.md) | Full deep dive |

### Architecture

| File | Description | Date |
|---|---|---|
| [nri-cross-plugin-comparison.md](architecture/nri-cross-plugin-comparison.md) | Side-by-side comparison, alignment gaps, shared concerns | Apr 2026 |

---

## Quick Reference: Source Repos

| Integration | GitHub | pkg.go.dev |
|---|---|---|
| nri-postgresql | https://github.com/newrelic/nri-postgresql | https://pkg.go.dev/github.com/newrelic/nri-postgresql |
| nri-mysql | https://github.com/newrelic/nri-mysql | https://pkg.go.dev/github.com/newrelic/nri-mysql |
| nri-redis | https://github.com/newrelic/nri-redis | https://pkg.go.dev/github.com/newrelic/nri-redis |
| infra-integrations-sdk | https://github.com/newrelic/infra-integrations-sdk | https://pkg.go.dev/github.com/newrelic/infra-integrations-sdk |
