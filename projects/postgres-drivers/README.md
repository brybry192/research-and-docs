# PostgreSQL Driver & Data Access Ecosystem

Research into PostgreSQL drivers, ORMs, query builders, and code generators across Go, Java, Ruby, and Python — with enterprise standardization analysis.

---

## Table of Contents

- [Documents](#documents)
- [Context](#context)
- [Key Findings](#key-findings)

---

## Documents

| Document | Scope |
|---|---|
| [go-drivers.md](go-drivers.md) | lib/pq, pgx, sqlx, sqlc, GORM, Bun — strengths, weaknesses, enterprise standardization |
| [multilang-drivers.md](multilang-drivers.md) | Java (JDBC, Hibernate, jOOQ), Ruby (pg gem, ActiveRecord, Sequel), Python (psycopg2/3, asyncpg, SQLAlchemy) |
| [nri-postgresql-driver-migration.md](nri-postgresql-driver-migration.md) | PR review: lib/pq → pgx/v5 migration in nri-postgresql, expanded rationale and risk mitigation |

---

## Context

This research was prompted by [brybry192/nri-postgresql#1](https://github.com/brybry192/nri-postgresql/pull/1), which migrates nri-postgresql from lib/pq to pgx/v5. The PR needed a stronger "why" section for the driver migration, and the research expanded into a comprehensive cross-language analysis for enterprise standardization.

---

## Key Findings

- **lib/pq is officially in maintenance mode** and its own README recommends pgx
- **pgx/v5 is the clear successor** for Go — 50-100% faster native, DialFunc/hooks enable features lib/pq cannot support
- **sqlc + pgx** is the recommended enterprise Go stack for new services (SQL-first, compile-time validation)
- **Java:** pgJDBC + HikariCP + Hibernate (CRUD) / jOOQ (analytics) — the hybrid approach is increasingly mainstream
- **Ruby:** pg gem is the only driver; ActiveRecord for Rails, Sequel for PostgreSQL-heavy or non-Rails work
- **Python:** psycopg3 is the safe default driver; SQLAlchemy 2.0 for enterprise data access
- **Cross-language pattern:** every ecosystem is moving toward SQL-first, type-safe approaches over heavy ORMs
