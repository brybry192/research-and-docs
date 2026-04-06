# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

A personal knowledge base of technical research, architecture deep-dives, and reference documentation. Research topics are primarily Go, databases, Docker, Kubernetes, controllers, proxies, and testing infrastructure. This is a documentation-only repo — there are no build, test, or lint commands.

## Structure

```
projects/              # All research organized by project (self-contained)
templates/             # Reusable document templates
checklists/            # Reusable review checklists
tools/                 # Verification scripts
journal.md             # Running session log
```

## Mandatory: Verify Before Committing

AI research output will confidently present stale or fabricated information as current fact. This has already happened in this repo — see the [lib/pq incident](projects/postgres-drivers/README.md#what-actually-happened-with-libpqs-status).

**Before committing any research document, you MUST:**

1. **Run `./tools/verify-claims.sh`** against the document to check GitHub-based claims
2. **Fetch and read the actual README** for any project whose status you describe (maintenance mode, deprecated, actively maintained)
3. **Verify quoted text** exists in the source — do not trust sub-agent output that includes quotes
4. **Check release dates and versions** against the actual releases page
5. **Never use sub-agent research output without verification** — sub-agents will fabricate specific quotes, commit hashes, and dates that look real but are not

If you cannot verify a claim, either omit it or explicitly mark it as unverified.

## Workflow

1. Each research effort gets its own directory under `projects/<project-name>/`
2. Start documents from the appropriate template in `templates/`
3. Use the matching checklist from `checklists/` during research
4. **Verify all factual claims** — run `./tools/verify-claims.sh` and manually check high-risk claims
5. Log each session in `journal.md` (date, outputs, open threads)
6. Commit messages should reference source repos and research date

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
