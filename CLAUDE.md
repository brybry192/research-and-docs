# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

A personal knowledge base of technical research, architecture deep-dives, and reference documentation. Research topics are primarily Go, databases, Docker, Kubernetes, controllers, proxies, and testing infrastructure. This is a documentation-only repo — there are no build, test, or lint commands.

## Structure

```
projects/              # All research organized by project (self-contained)
templates/             # Reusable document templates
checklists/            # Reusable review checklists
journal.md             # Running session log
```

## Workflow

1. Each research effort gets its own directory under `projects/<project-name>/`
2. Start documents from the appropriate template in `templates/`
3. Use the matching checklist from `checklists/` during research
4. Log each session in `journal.md` (date, outputs, open threads)
5. Commit messages should reference source repos and research date

## Document Conventions

### YAML Frontmatter (required on all research docs)

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

### File Naming

- **kebab-case** for all files and directories
- Primary research: `study-guide.md` | Comparisons: `comparison.md` | Quick reference: `reference.md`

### Templates

| Template | Use When |
|---|---|
| `integration-deep-dive.md` | Database integrations, drivers, plugins |
| `go-repo-analysis.md` | Any Go repository |
| `system-architecture.md` | Distributed systems, controllers, proxies |
| `comparison.md` | Side-by-side evaluations |
| `research-session.md` | General-purpose research |

### Checklists

| Checklist | Use When |
|---|---|
| `go-repo-review.md` | Any Go codebase |
| `kubernetes-review.md` | K8s controllers, operators, CRDs |
| `database-integration-review.md` | Database clients, drivers, proxies |

### Diagrams

Use Mermaid for all diagrams (architecture, sequence, state, dependency graphs). Mermaid renders natively in GitHub — no images to maintain. Include diagrams inline in documents where they clarify component relationships or data flow.

### Table of Contents

Include a table of contents section at the top of README.md files unless the file is very short (fewer than ~4 sections).

### Project README Pattern

Each project directory gets a README.md that serves as the project-level index: what was researched, links to all documents, and source repo references.
