# Enterprise Schema Management

Research into language-agnostic, SQL-based schema management solutions for multi-language organizations — with emphasis on safety, risk preview, automated protections, and blue/green deployment strategies.

---

## Table of Contents

- [Documents](#documents)
- [Context](#context)
- [Key Findings](#key-findings)

---

## Documents

| Document | Scope |
|---|---|
| [study-guide.md](study-guide.md) | Tool comparison, safety layers, rollback strategies, blue/green deployments, enterprise recommendations |

---

## Context

Research prompted by the need for a standardized schema management approach at a large, multi-language organization (Go, Java, Ruby, Python). ORM-based migration tools (ActiveRecord, Hibernate auto-DDL, Alembic) are explicitly out of scope — the focus is on language-agnostic, SQL-based solutions that multiple teams can share.

The core concern is **safety**: how to preview risk before applying migrations, automatically protect against dangerous changes, and provide rollback paths when things go wrong.

---

## Key Findings

- **Atlas** is the most modern and safety-focused tool — declarative schema diffing, built-in linting, CI integration
- **Flyway** has the widest enterprise adoption but lacks rollback in the community edition
- **Liquibase** has the richest rollback support but is complex to operate
- **squawk** (PG migration linter) + CI gates is the highest-ROI safety layer you can add today
- **PostgreSQL DDL is transactional** — leverage this for atomic rollback (MySQL cannot do this)
- **Blue/green with logical replication** is the gold standard for zero-downtime schema changes at scale
- **Expand-and-contract** is the safest schema change pattern regardless of tooling
