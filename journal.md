# Research Journal

Running log of research sessions. One entry per session — date, topic, outputs, open threads.

---

## 2026-04

- **2026-04-05** — NRI integrations deep dives: nri-postgresql, nri-mysql, nri-redis
  - Outputs: `projects/nri-integrations/nri-postgresql/study-guide.md`, `projects/nri-integrations/nri-mysql/study-guide.md`, `projects/nri-integrations/nri-redis/study-guide.md`
  - Cross-plugin comparison: `projects/nri-integrations/architecture/nri-cross-plugin-comparison.md`
  - Open thread: licensing inconsistency across plugins (MIT vs Apache-2.0) — worth raising upstream?
  - Open thread: no benchmark tests in any of the three integrations
  - Open thread: READMEs still reference govendor (deprecated)

- **2026-04-05** — Repository restructuring
  - Reorganized from flat `integrations/`+`architecture/` to `projects/` layout
  - Added domain-specific templates (Go repo analysis, system architecture, comparison)
  - Added research checklists (Go, Kubernetes, database integration)

- **2026-04-06** — PostgreSQL driver ecosystem deep dive
  - Prompted by [brybry192/nri-postgresql#1](https://github.com/brybry192/nri-postgresql/pull/1) (lib/pq → pgx migration)
  - Go drivers: `projects/postgres-drivers/go-drivers.md` (lib/pq, pgx, sqlx, sqlc, GORM, Bun)
  - Multi-language: `projects/postgres-drivers/multilang-drivers.md` (Java, Ruby, Python)
  - PR review: `projects/postgres-drivers/nri-postgresql-driver-migration.md`
  - Key finding: lib/pq README officially recommends pgx; sqlc + pgx is the recommended enterprise Go stack
  - Open thread: evaluate sqlc adoption for nri-postgresql metric queries

- **2026-04-06** — Enterprise schema management research
  - Output: `projects/schema-management/study-guide.md`
  - Compared Flyway, Liquibase, Atlas, dbmate, golang-migrate, Sqitch
  - Atlas recommended as primary tool; squawk linting as highest-ROI CI safety layer
  - Detailed blue/green patterns: app-level, logical replication, proxy-based, Aurora managed
  - Open thread: build a pre-apply safety hook (table size check + lock timeout injection)
  - Open thread: evaluate squawk integration in CI for existing migration pipelines
