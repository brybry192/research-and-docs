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

The initial version of this research (commit b20c853) stated that lib/pq was "officially in maintenance mode" and that its README recommended pgx. Bryant caught this during review — he knows lib/pq well and recognized the claim as wrong. He checked the [lib/pq repo](https://github.com/lib/pq) directly and confirmed: no maintenance notice exists, no recommendation to use pgx exists, and the project shipped 7 releases in 2026 with active feature development.

### What actually happened with lib/pq's status

The AI's claim was not invented from nothing — it was **stale information presented as current fact**, which is arguably worse because it's harder to catch.

The real history, verified via [lib/pq issue #1010](https://github.com/lib/pq/issues/1010) and git history:

1. **April 2020:** Commit [c782d9f](https://github.com/lib/pq/commit/c782d9f159ffd7573168ac7e788e8e516a301053) added a "Status" section to the README stating: *"This package is effectively in maintenance mode and is not actively developed. [...] We recommend using pgx which is actively maintained."*
2. **September 2021:** A follow-up commit "Clarify maintenance mode" expanded the notice. At this point the project had minimal activity — the last release before the revival was v1.10.9 in April 2023.
3. **Late 2025 / early 2026:** The project was revived with active development. New maintainers took over. Seven releases shipped in Q1 2026 (v1.11.0 through v1.12.3) with significant new features: `pq.Config`, `pq.NewConnectorConfig()`, CockroachDB testing, protocol debug output, pgbouncer/pgpool CI testing.
4. **March 17, 2026:** The README was [completely rewritten](https://github.com/lib/pq/commits?path=README.md), removing the maintenance mode notice. The project is now actively maintained.

The AI research agent picked up the 2020-2023 era information (which was widely cited across blog posts, StackOverflow, and migration guides) and presented it as current fact without checking whether it was still true. The commit hash and date it cited were real — the maintenance notice **did** exist — but it was removed weeks before this research was conducted.

### Why this matters

If this had been a topic Bryant was less familiar with, the stale claim would have gone unchallenged. He would have repeated it in PR reviews, technical discussions, and architectural decisions — citing a README notice that was removed weeks earlier. That's the real danger of AI-generated research: **the output reads with high confidence regardless of whether it reflects the current state of the world.**

Stale-but-once-true claims are the hardest to catch because they sound plausible, have real supporting evidence in the historical record, and are echoed across the internet in outdated articles.

### Warning to readers

This repository contains AI-assisted research. AI tools will confidently present outdated or fabricated details — specific quotes, commit hashes, version numbers, maintenance status — as current fact. **Do not cite anything from this repo in a professional context without independently verifying it against the actual source.** If a document references a README, a release page, or a project status, click the link and read it yourself. The more specific and quotable a claim looks, the more important it is to verify.

A verification script is provided at [`tools/verify-claims.sh`](../../tools/verify-claims.sh) to automate checking GitHub-based claims. Run it against any research document before trusting it. See [`tools/README.md`](../../tools/README.md) for details.
