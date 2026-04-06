# Tools

Scripts and utilities for validating AI-generated research.

---

## Table of Contents

- [verify-claims.sh](#verify-claimssh)
- [Verification Workflow](#verification-workflow)
- [What to Verify Manually](#what-to-verify-manually)

---

## verify-claims.sh

Automated verification of factual claims in research documents against primary sources.

### Usage

```bash
# Verify a single document
./tools/verify-claims.sh projects/postgres-drivers/go-drivers.md

# Verify all research documents
./tools/verify-claims.sh projects/**/*.md

# Verify everything
./tools/verify-claims.sh projects/**/*.md
```

### What it checks

| Check | How |
|---|---|
| GitHub repos exist | `gh api repos/{owner}/{repo}` — catches dead links and typos |
| Maintenance/deprecated claims | Fetches the actual README and searches for maintenance language |
| "Actively maintained" claims | Verifies last push date is within 180 days |
| Release versions | Verifies claimed versions exist in actual release/tag list |
| Quoted README text | Fetches README and searches for the quoted string |
| Archived repos | Flags repos that are archived on GitHub |

### What it CANNOT check

- Performance benchmark claims (would need to run benchmarks)
- Subjective assessments ("best for enterprise")
- Feature claims without running the code
- Non-GitHub sources (docs sites, blog posts, StackOverflow)
- Whether information is current vs stale-but-once-true

### Requirements

- `gh` (GitHub CLI, authenticated)
- `curl`
- `jq`

---

## Verification Workflow

Run this workflow on every research document before committing.

### Before committing new research

```bash
# 1. Run automated verification
./tools/verify-claims.sh path/to/new-document.md

# 2. Fix any FAIL results — these are claims that could not be verified

# 3. Review WARN results — these may need manual checking

# 4. For any remaining claims the script can't check, verify manually (see below)

# 5. Commit only after all FAIL results are resolved
```

### After AI generates research

The most dangerous failure mode is **stale information presented as current fact** (see the [lib/pq incident](../projects/postgres-drivers/README.md#what-actually-happened-with-libpqs-status)). AI models are trained on data from a specific point in time and will confidently present outdated information as current. The internet is full of old blog posts and StackOverflow answers that reinforce stale claims.

**High-risk claims to always verify manually:**

1. **Project status claims** ("in maintenance mode", "deprecated", "actively maintained") — projects change status. Check the actual repo, not what the AI says.
2. **Quoted text** ("the README says...") — fetch the README and search for the quote. If the quote is not there, the AI made it up or it was removed.
3. **Specific commit hashes and dates** — these can be real but point to old state. Verify the current state, not just that the commit exists.
4. **Version numbers and release dates** — check the releases page directly.
5. **Star counts** — these change daily. Round to nearest thousand and mark as approximate.

---

## What to Verify Manually

The script handles GitHub-based claims. For everything else:

| Claim Type | How to Verify |
|---|---|
| Package docs (pkg.go.dev, PyPI, Maven) | Open the URL, confirm the page exists and matches |
| Performance benchmarks | Look for the cited benchmark source; if no source, flag as unverified |
| Feature claims ("supports X") | Check the project's docs or source code |
| Blog post / article citations | Open the URL, confirm it exists and says what's claimed |
| "Best practice" or "recommended" claims | These are opinions, not facts — label them as such |

### Red flags that suggest AI fabrication

- Extremely specific quotes with no link to verify against
- Commit hashes cited inline (AI often generates plausible-looking but fake hashes)
- Precise star counts (AI snapshots a number from training data that may be years old)
- Claims that a project "officially recommends" a competitor (verify — this is a strong claim)
- Dates for events that are suspiciously round (e.g., "April 2020", "January 2023")
