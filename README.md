# research-and-docs

A personal knowledge base of technical research, architecture deep-dives, and reference documentation — primarily generated with Claude AI assistance.

> **Purpose:** Capture and version-control research output so it's searchable, linkable, and buildable-upon across sessions.

---

## Table of Contents

- [Projects](#projects)
- [Templates](#templates)
- [Checklists](#checklists)
- [Journal](#journal)
- [Conventions](#conventions)
- [Starting a Research Session](#starting-a-research-session)

---

## Projects

All research is organized by project under `projects/`. Each project is self-contained with its own README and documents.

| Project | Status | Last Updated | Summary |
|---|---|---|---|
| [nri-integrations](projects/nri-integrations/) | reviewed | Apr 2026 | Architecture deep-dives of nri-postgresql, nri-mysql, nri-redis + cross-plugin comparison |
| [postgres-drivers](projects/postgres-drivers/) | reviewed | Apr 2026 | PostgreSQL driver & data access ecosystem across Go, Java, Ruby, Python + nri-postgresql migration review |
| [schema-management](projects/schema-management/) | reviewed | Apr 2026 | Enterprise schema management — tool comparison, safety layers, blue/green deployments |

---

## Templates

Reusable document structures in `templates/`. Use these as starting points for new research.

| Template | Use When |
|---|---|
| [integration-deep-dive.md](templates/integration-deep-dive.md) | Researching a database integration, driver, or plugin |
| [go-repo-analysis.md](templates/go-repo-analysis.md) | Analyzing any Go repository — structure, patterns, deps, testing |
| [system-architecture.md](templates/system-architecture.md) | Analyzing distributed systems — controllers, proxies, services |
| [comparison.md](templates/comparison.md) | Side-by-side evaluation of tools, libraries, or approaches |
| [research-session.md](templates/research-session.md) | General-purpose research that doesn't fit the above |

---

## Checklists

Reusable review processes in `checklists/`. Use these during research to ensure consistent coverage.

| Checklist | Use When |
|---|---|
| [go-repo-review.md](checklists/go-repo-review.md) | Reviewing any Go codebase |
| [kubernetes-review.md](checklists/kubernetes-review.md) | Reviewing K8s controllers, operators, or CRD-based systems |
| [database-integration-review.md](checklists/database-integration-review.md) | Reviewing database clients, drivers, integrations, or proxies |

---

## Journal

[journal.md](journal.md) — Running log of research sessions with dates, outputs, and open threads. Check here to pick up context from prior sessions.

---

## Conventions

### File Naming

- `kebab-case` for all files and directories
- Primary research: `study-guide.md` | Comparisons: `comparison.md` | Quick reference: `reference.md`

### Frontmatter

Every research document starts with:

```yaml
---
topic: <short topic name>
date: <YYYY-MM-DD>
source_repos:
  - https://github.com/...
tags: [go, kubernetes, database]
status: draft | reviewed | stable
---
```

### Status Labels

| Status | Meaning |
|---|---|
| `draft` | First-pass research, not fully verified |
| `reviewed` | Read through and spot-checked |
| `stable` | Unlikely to need updates unless source material changes |

### Diagrams

Use [Mermaid](https://mermaid.js.org/) for architecture diagrams, sequence diagrams, state machines, and dependency graphs. Mermaid renders natively in GitHub Markdown — no images to maintain.

---

## Starting a Research Session

```
I have a research-and-docs repo at https://github.com/<username>/research-and-docs.
Here is a read/write PAT scoped to that repo: ghp_...

Please research [TOPIC], write the output to projects/[project-name]/, commit, and push.
```

### PAT Scopes Required

- **Contents:** Read and Write
- **Metadata:** Read

Use a fine-grained PAT scoped to this repository only. Never commit a PAT to this repo.
