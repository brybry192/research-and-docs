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
