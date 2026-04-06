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

- **lib/pq is actively maintained** (7 releases in 2026, including new features) — pgx migration is driven by technical need (DialFunc, per-connection config), not lib/pq's health
- **pgx provides capabilities lib/pq does not** — DialFunc, batch queries, COPY, binary protocol, per-connection config, connection pool hooks
- **sqlc + pgx** is a strong enterprise Go stack for new services (SQL-first, compile-time validation)
- **Java:** pgJDBC + HikariCP + Hibernate (CRUD) / jOOQ (analytics) — the hybrid approach is increasingly mainstream
- **Ruby:** pg gem is the only driver; ActiveRecord for Rails, Sequel for PostgreSQL-heavy or non-Rails work
- **Python:** psycopg3 is the safe default driver; SQLAlchemy 2.0 for enterprise data access
- **Cross-language pattern:** every ecosystem is moving toward SQL-first, type-safe approaches over heavy ORMs

## Correction Notice

### What went wrong

The initial version of this research (commit b20c853) stated that lib/pq was "officially in maintenance mode" and that its README recommended pgx. **This was completely fabricated.** A research sub-agent invented the claim — complete with a fake quoted README notice, a fake commit hash (c782d9f), and a fake date (April 2020) — and it was committed without verification against the actual source.

Bryant caught this during review because he knows lib/pq well and recognized the claim as wrong. He checked the [lib/pq repo](https://github.com/lib/pq) directly and confirmed: no maintenance notice exists, no recommendation to use pgx exists, and the project shipped 7 releases in 2026 with active feature development. All affected documents have been corrected.

### Why this matters

If this had been a topic Bryant was less familiar with, the fabricated claim would have gone unchallenged. He would have repeated it in PR reviews, technical discussions, and architectural decisions — looking like a fool citing a README notice that doesn't exist. That's the real danger of AI-generated research: **the output reads with high confidence regardless of whether it's true.**

### Warning to readers

This repository contains AI-assisted research. While we verify claims against primary sources where possible, AI tools will confidently fabricate details — specific quotes, commit hashes, version numbers, dates, and maintenance status — that are entirely wrong. **Do not cite anything from this repo in a professional context without independently verifying it against the actual source.** If a document references a README, a release page, or a project status, click the link and read it yourself. The more specific and quotable a claim looks, the more important it is to verify.
