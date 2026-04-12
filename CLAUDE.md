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

## Known Hallucination Patterns

These are failure modes observed in this repo. Learn from them.

### Stale-but-once-true claims (most dangerous)

The AI presented lib/pq as "in maintenance mode" with a real commit hash and real date — because a maintenance notice **did** exist from April 2020 through March 2026, but was removed weeks before the research was conducted. This is worse than pure fabrication because: the claim sounds plausible, has real historical evidence, and is echoed across outdated blog posts and StackOverflow answers. The user caught it only because he already knew the project well.

**Defense:** Always fetch the current README and recent releases for any project you describe. Historical information from training data or web searches is not a substitute for checking the actual repo right now.

### Confident specificity as a warning sign

The more specific and quotable a claim looks (exact quotes, commit hashes, precise star counts, specific dates), the more likely it is fabricated or stale. Vague claims are easier to spot-check; precise-sounding claims create false confidence.

**Defense:** Treat high-specificity claims as high-risk. Verify every quoted string, commit hash, and version number against the primary source before including it.

### Sub-agent output passed through without verification

Research sub-agents will return detailed, well-structured output that reads as authoritative. The main agent's instinct is to trust and pass it through. This is how the lib/pq error made it into three documents before being caught.

**Defense:** Never commit sub-agent research output directly. Read it critically, then verify the key claims yourself using `gh api`, `WebFetch`, or direct file reads. If verification is not possible, mark claims as unverified.

### What to do when caught

If the user identifies a factual error:
1. Investigate the actual source immediately — do not guess or speculate about what happened
2. Correct every document that contains the error
3. Document what went wrong and why in the project README (see [postgres-drivers correction notice](projects/postgres-drivers/README.md#what-went-wrong))
4. Credit the person who caught it — they did the work you should have done

## Verification Tooling

### `./tools/verify-claims.sh <file.md>`

Requires: `gh` (authenticated), `curl`, `jq`. Checks:
- GitHub repo URLs resolve
- Maintenance/deprecated claims match actual README content
- "Actively maintained" claims verified against last push date (180-day threshold)
- Release versions exist in actual release/tag list
- Quoted README text exists in the current README
- Archived repos flagged

Run against **every** research document before committing. See [tools/README.md](tools/README.md) for the full workflow and manual verification guidance.

### High-risk claims that require manual verification

Even after `verify-claims.sh` passes, manually check:
- Project status claims (maintenance mode, deprecated, actively maintained) — fetch the README yourself
- Non-GitHub sources (docs sites, blog posts, package registries)
- Performance benchmark claims (no automated way to verify)
- "Officially recommends" claims (strong assertion, frequently fabricated)

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
