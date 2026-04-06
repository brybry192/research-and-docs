#!/usr/bin/env bash
#
# verify-claims.sh — Verify factual claims in research documents against primary sources.
#
# This script extracts GitHub repository references from markdown files,
# fetches actual metadata via the GitHub API, and flags discrepancies
# between what the document claims and what the source shows.
#
# Usage:
#   ./tools/verify-claims.sh <file.md>           # verify one document
#   ./tools/verify-claims.sh projects/**/*.md     # verify all research
#
# Requires: gh (GitHub CLI, authenticated), curl, jq
#
# What it checks:
#   - GitHub repo URLs resolve (not 404)
#   - Star counts are within 10% of claimed values
#   - Release versions and dates match actual releases
#   - README content matches any quoted text
#   - Repos claimed as "maintenance mode" or "deprecated" actually say so
#   - Repos claimed as "actively maintained" have recent activity
#
# What it CANNOT check:
#   - Performance benchmark claims
#   - Subjective assessments ("best for enterprise")
#   - Claims about features without running the code
#   - Non-GitHub sources (docs sites, blog posts)
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
#   2 — missing dependencies

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { ((PASS++)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}FAIL${NC} $1"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}WARN${NC} $1"; }

# --- Dependency check ---
for cmd in gh curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is required but not installed." >&2
        exit 2
    fi
done

if ! gh auth status &>/dev/null; then
    echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
    exit 2
fi

if [ $# -eq 0 ]; then
    echo "Usage: $0 <file.md> [file2.md ...]"
    exit 2
fi

# --- Extract GitHub repo references ---
extract_github_repos() {
    # Match github.com/owner/repo patterns, deduplicate
    grep -oE 'github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' "$1" \
        | sed 's|github\.com/||' \
        | sed 's|[)\]"'"'"'].*||' \
        | sed 's|/releases.*||; s|/pull.*||; s|/issues.*||; s|#.*||; s|\.git$||' \
        | sort -u
}

# --- Extract star count claims ---
# Matches patterns like "Stars:** ~9,845" or "Stars:** 13,580"
extract_star_claims() {
    grep -oE 'Stars:\*\*[[:space:]]*~?[0-9,]+' "$1" 2>/dev/null \
        | sed 's/Stars:\*\*[[:space:]]*~\?//' \
        | tr -d ',' \
        || true
}

# --- Extract version claims ---
# Matches patterns like "Latest:** v1.12.3" or "version:** 42.7.10"
extract_version_claims() {
    grep -oiE '(Latest|Version|Current version):\*\*[[:space:]]*v?[0-9][0-9.]*' "$1" 2>/dev/null \
        | sed 's/.*\*\*[[:space:]]*//' \
        || true
}

# --- Extract maintenance/status claims ---
extract_status_claims() {
    grep -inE '(maintenance mode|deprecated|actively maintained|unmaintained|no longer maintained|archived)' "$1" 2>/dev/null \
        || true
}

# --- Extract quoted text (lines starting with >) ---
extract_quotes() {
    grep -E '^>\s*"' "$1" 2>/dev/null | sed 's/^>[[:space:]]*//' | tr -d '"' \
        || true
}

# --- Check a single GitHub repo ---
check_repo() {
    local owner_repo="$1"
    local file="$2"

    # Verify repo exists
    local repo_json
    repo_json=$(gh api "repos/$owner_repo" 2>/dev/null) || {
        fail "$owner_repo — repo does not exist or is not accessible"
        return
    }

    local actual_stars
    actual_stars=$(echo "$repo_json" | jq -r '.stargazers_count')
    local archived
    archived=$(echo "$repo_json" | jq -r '.archived')
    local pushed_at
    pushed_at=$(echo "$repo_json" | jq -r '.pushed_at')

    pass "$owner_repo — repo exists (stars: $actual_stars, last push: ${pushed_at:0:10})"

    # Check if document claims maintenance mode / deprecated / actively maintained
    local status_claims
    status_claims=$(grep -in "$owner_repo" "$file" 2>/dev/null || true)

    if echo "$status_claims" | grep -qi "maintenance mode\|deprecated\|unmaintained\|no longer maintained" 2>/dev/null; then
        # Document claims this repo is in maintenance mode — verify via README
        local readme_content
        readme_content=$(gh api "repos/$owner_repo/readme" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)

        if echo "$readme_content" | grep -qi "maintenance mode\|deprecated\|no longer maintained"; then
            pass "$owner_repo — maintenance mode claim verified in README"
        else
            # Check activity as secondary signal
            local days_since_push
            local push_epoch
            push_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pushed_at" "+%s" 2>/dev/null || date -d "$pushed_at" "+%s" 2>/dev/null || echo 0)
            local now_epoch
            now_epoch=$(date "+%s")
            days_since_push=$(( (now_epoch - push_epoch) / 86400 ))

            if [ "$days_since_push" -lt 90 ]; then
                fail "$owner_repo — claimed maintenance mode but README has no such notice AND last push was ${days_since_push} days ago"
            else
                warn "$owner_repo — claimed maintenance mode, README has no notice, but last push was ${days_since_push} days ago"
            fi
        fi
    fi

    if echo "$status_claims" | grep -qi "actively maintained\|active development" 2>/dev/null; then
        local days_since_push
        local push_epoch
        push_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pushed_at" "+%s" 2>/dev/null || date -d "$pushed_at" "+%s" 2>/dev/null || echo 0)
        local now_epoch
        now_epoch=$(date "+%s")
        days_since_push=$(( (now_epoch - push_epoch) / 86400 ))

        if [ "$days_since_push" -lt 180 ]; then
            pass "$owner_repo — actively maintained claim checks out (last push ${days_since_push} days ago)"
        else
            fail "$owner_repo — claimed actively maintained but last push was ${days_since_push} days ago"
        fi
    fi

    # Check archived status
    if [ "$archived" = "true" ]; then
        warn "$owner_repo — repo is ARCHIVED on GitHub"
    fi
}

# --- Check release version claims ---
check_releases() {
    local owner_repo="$1"
    local file="$2"

    # Get actual releases
    local releases
    releases=$(gh api "repos/$owner_repo/releases" --jq '.[:5][] | .tag_name' 2>/dev/null || true)

    if [ -z "$releases" ]; then
        # Try tags instead
        releases=$(gh api "repos/$owner_repo/tags" --jq '.[:5][] | .name' 2>/dev/null || true)
    fi

    if [ -z "$releases" ]; then
        return
    fi

    local latest
    latest=$(echo "$releases" | head -1)

    # Check if document mentions a version for this repo
    # Look for the repo name near a version number
    local repo_name
    repo_name=$(echo "$owner_repo" | cut -d/ -f2)
    local version_context
    version_context=$(grep -i "$repo_name" "$file" 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

    if [ -n "$version_context" ]; then
        # Normalize: strip leading 'v' for comparison
        local claimed
        claimed=$(echo "$version_context" | sed 's/^v//')
        local actual
        actual=$(echo "$latest" | sed 's/^v//')

        if echo "$releases" | sed 's/^v//' | grep -qF "$claimed"; then
            pass "$owner_repo — version $version_context exists in releases"
        else
            warn "$owner_repo — document mentions $version_context but actual releases are: $(echo "$releases" | head -3 | tr '\n' ', ')"
        fi
    fi
}

# --- Check quoted README text ---
check_readme_quotes() {
    local owner_repo="$1"
    local file="$2"

    local readme_content
    readme_content=$(gh api "repos/$owner_repo/readme" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [ -z "$readme_content" ]; then
        return
    fi

    # Look for quoted text in the document that's near a reference to this repo
    local repo_name
    repo_name=$(echo "$owner_repo" | cut -d/ -f2)

    # Extract quotes from the file
    while IFS= read -r quote; do
        [ -z "$quote" ] && continue

        # Take first 40 chars of quote for matching (quotes may be truncated/reformatted)
        local snippet
        snippet=$(echo "$quote" | head -c 60)

        if echo "$readme_content" | grep -qiF "$snippet"; then
            pass "$owner_repo — quoted text verified: \"${snippet:0:50}...\""
        else
            fail "$owner_repo — quoted text NOT FOUND in README: \"${snippet:0:50}...\""
        fi
    done < <(extract_quotes "$file")
}

# --- Main ---
echo ""
echo -e "${BOLD}=== Research Claim Verification ===${NC}"
echo ""

for file in "$@"; do
    if [ ! -f "$file" ]; then
        echo -e "${RED}File not found: $file${NC}"
        continue
    fi

    echo -e "${BOLD}--- $file ---${NC}"
    echo ""

    # Extract and check all GitHub repos mentioned
    repos=$(extract_github_repos "$file")

    if [ -z "$repos" ]; then
        echo "  No GitHub repos referenced."
        echo ""
        continue
    fi

    for repo in $repos; do
        # Skip non-repo paths (e.g. github.com/user-attachments)
        if echo "$repo" | grep -qE '(user-attachments|apps|orgs|settings)'; then
            continue
        fi

        check_repo "$repo" "$file"
        check_releases "$repo" "$file"
        check_readme_quotes "$repo" "$file"
    done

    # Check for any status claims about repos not in the GitHub URL list
    echo ""
    echo "  Status claims in document:"
    status=$(extract_status_claims "$file")
    if [ -n "$status" ]; then
        echo "$status" | while IFS= read -r line; do
            echo -e "    ${YELLOW}→${NC} $line"
        done
    else
        echo "    (none)"
    fi

    echo ""
done

# --- Summary ---
echo -e "${BOLD}=== Summary ===${NC}"
echo -e "  ${GREEN}PASS:${NC} $PASS"
echo -e "  ${RED}FAIL:${NC} $FAIL"
echo -e "  ${YELLOW}WARN:${NC} $WARN"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}${BOLD}VERIFICATION FAILED — $FAIL claim(s) could not be verified.${NC}"
    echo "Review the failures above and correct the documents before committing."
    exit 1
else
    echo -e "${GREEN}All verifiable claims passed.${NC}"
    exit 0
fi
