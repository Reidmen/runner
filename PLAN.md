# Parallel Feature Runner — Implementation Plan

## Context

You have `pr_review.sh` (~1108 lines) that orchestrates parallel Claude Code sessions for PR reviews using git worktrees, iTerm2/tmux/bg terminal modes, and agent teams. The goal is to build an analogous tool — `runner.sh` — that instead of reviewing PRs, **spawns parallel Claude Code sessions to implement new features**. Each feature runs in its own isolated git worktree with port-isolated `.env` files, tracked via a manifest, and accessible through ergonomic tabs/commands.

## Deliverable

**Single file**: `runner.sh` (~1450 lines)

Same self-spawning architecture as `pr_review.sh` — one script is both orchestrator and worker, selected by the internal `--_single` flag.

---

## Architecture Overview

```
Usage modes:
  ./runner.sh --features "Add auth" "Build API" "Add search"
  ./runner.sh --from-file features.txt
  ./runner.sh --issue 42 --issue 78 --issue 103       ← issue-driven
  ./runner.sh --issue 42 --features "Extra task"       ← mixed mode

Orchestrator (multi-feature mode):
  ├─ If --issue: fetches issue details via `gh issue view`
  │   ├─ Extracts title, body, labels, assignees, comments
  │   └─ Derives feature description + slug from issue
  ├─ If --features: uses provided descriptions directly
  ├─ Slugifies all features
  ├─ Detects terminal: iTerm2 / tmux / background
  ├─ Initializes manifest (runner-manifest.json)
  └─ Spawns N child processes (each with --_single):

Worker (single-feature mode, per tab/window):
  ├─ Validates prerequisites (git, claude, jq, gh if issue mode)
  ├─ Resolves git root and base branch
  ├─ Creates worktree: ~/.feature_runner/feature-add-auth/
  ├─ Creates branch: feature/add-auth (from base branch)
  ├─ Copies .env files into worktree
  ├─ Rewrites ports: PORT=3000 → PORT=3010 (offset by index)
  ├─ If issue mode: writes full issue context to .feature-context/
  ├─ Builds prompt with agent team instructions (+ issue context)
  ├─ Launches Claude Code (with agent teams)
  ├─ Updates manifest with result
  └─ Drops into interactive shell with convenience commands
```

---

## Key Sections

### 1. Header, Colors, Logging (~100 lines)
Reuse `pr_review.sh` patterns verbatim: `set -euo pipefail`, `_use_color()`, color vars (RED/GREEN/YELLOW/BLUE/CYAN/BOLD/DIM/RESET), `info()`/`ok()`/`warn()`/`error()`/`fatal()`/`step()`/`_boxln()`. Rename env var to `RUNNER_NO_COLOR`.

### 2. Defaults & Argument Parsing (~160 lines)

**CLI interface:**
```
./runner.sh --features "Add user auth" "Build REST API" [OPTIONS]
./runner.sh --from-file features.txt [OPTIONS]
./runner.sh --issue 42 --issue 78 [OPTIONS]
./runner.sh --issue 42 --features "Extra task" [OPTIONS]   # mixed mode
```

**Options:**
| Flag | Default | Purpose |
|------|---------|---------|
| `--features <desc...>` | — | Feature descriptions (strings) |
| `--from-file <file>` | — | Read features from file (one per line, `#` comments) |
| `--issue <number>` | — | GitHub issue number(s) — fetch title/body/comments as feature context |
| `-r, --repo <owner/repo>` | current repo | Target repository |
| `-d, --dir <path>` | `~/.feature_runner` | Worktree parent directory |
| `-m, --model <model>` | `opus` | Claude model |
| `-b, --max-turns <N>` | `75` | Max agentic turns |
| `--base-branch <branch>` | current branch | Branch to create features from |
| `--port-offset <N>` | `10` | Port increment per feature |
| `--no-port-rewrite` | false | Skip port rewriting |
| `--tabs <mode>` | `auto` | Terminal mode: auto/iterm/tmux/bg |
| `-c, --cleanup` | false | Remove worktree after completion |
| `--no-env-copy` | false | Skip .env copying |
| `--no-teams` | false | Use subagents instead of agent teams |
| `--no-color` | false | Disable colors |

**Internal flags** (passed to child processes): `--_single`, `--_feature-index`, `--_feature-desc`, `--_feature-slug`, `--_issue-number`, `--_issue-json`

### 3. Slugification (~30 lines)
Convert feature descriptions to branch-safe slugs:
- `"Add user authentication with OAuth2"` → `add-user-authentication-with-oauth2`
- Lowercase → replace non-alphanumeric with hyphens → collapse multiple hyphens → trim → truncate to 50 chars
- Pre-validate all slugs for uniqueness before spawning children

### 4. Issue Resolution — `--issue` mode (~100 lines)

When `--issue <N>` is provided, the script fetches full issue context via `gh` and converts it into a feature entry. This happens **before** slug computation and spawning.

**Issue fetching** (in orchestrator, before spawning children):
```bash
ISSUE_NUMBERS=()   # populated by --issue flags during arg parsing

resolve_issues() {
    command -v gh &>/dev/null || fatal "'gh' CLI required for --issue mode"
    local repo_flag=""
    [[ -n "$REPO" ]] && repo_flag="--repo $REPO"

    for issue_num in "${ISSUE_NUMBERS[@]}"; do
        step "Fetching issue #${issue_num}"

        # Fetch full issue JSON (title, body, labels, assignees, comments)
        local issue_json
        issue_json=$(gh issue view "$issue_num" $repo_flag --json \
            title,body,labels,assignees,comments,state,milestone,number) \
            || fatal "Failed to fetch issue #${issue_num}. Check repo and permissions."

        local title body labels state
        title=$(echo "$issue_json" | jq -r '.title')
        body=$(echo "$issue_json" | jq -r '.body // ""')
        labels=$(echo "$issue_json" | jq -r '[.labels[].name] | join(", ")')
        state=$(echo "$issue_json" | jq -r '.state')

        [[ "$state" == "CLOSED" ]] && warn "Issue #${issue_num} is closed — proceeding anyway"

        # Use issue title as feature description
        FEATURES+=("${title}")
        # Store issue JSON for passing to child processes
        _ISSUE_DATA["$title"]="$issue_json"
        _ISSUE_NUMS["$title"]="$issue_num"

        ok "Issue #${issue_num}: ${title}"
        [[ -n "$labels" ]] && info "  Labels: ${labels}"
    done
}
```

**Issue context file** (in worker, after worktree creation):
When a feature originated from an issue, the worker writes rich context to `.feature-context/ISSUE.md`:
```bash
write_issue_context() {
    local issue_json="$1"
    local context_dir="$2"
    local issue_file="${context_dir}/ISSUE.md"

    local number title body labels assignees comments_count
    number=$(echo "$issue_json" | jq -r '.number')
    title=$(echo "$issue_json" | jq -r '.title')
    body=$(echo "$issue_json" | jq -r '.body // "No description"')
    labels=$(echo "$issue_json" | jq -r '[.labels[].name] | join(", ") // "none"')
    assignees=$(echo "$issue_json" | jq -r '[.assignees[].login] | join(", ") // "unassigned"')
    comments_count=$(echo "$issue_json" | jq '.comments | length')

    cat > "$issue_file" <<ISSUE_EOF
# Issue #${number}: ${title}

## Description
${body}

## Metadata
- **Labels:** ${labels}
- **Assignees:** ${assignees}
- **Comments:** ${comments_count}

## Comments
$(echo "$issue_json" | jq -r '.comments[] | "### \(.author.login) (\(.createdAt))\n\(.body)\n"')
ISSUE_EOF

    ok "Issue context written to .feature-context/ISSUE.md"
}
```

**Prompt enrichment**: When issue context exists, the Claude prompt gets an additional section:
```
## Issue Context

This feature is based on GitHub Issue #__ISSUE_NUM__. Full issue details
(description, comments, labels) are in `.feature-context/ISSUE.md`.
Read it carefully before planning — it contains requirements, discussion,
and decisions from the team.
```

**Slug derivation for issues**: Uses `issue-<number>-<slugified-title>` format, e.g. `issue-42-add-user-authentication`. This ensures uniqueness even if issue titles overlap with `--features` descriptions.

**Mixed mode**: `--issue` and `--features` can be combined. Issues are resolved first and appended to the `FEATURES` array. All features (from both sources) are then processed uniformly.

### 5. Git Worktree Management (~150 lines)
- **Branch naming**: `feature/<slug>` — for issues: `feature/issue-42-add-auth`
- **Creation**: `git worktree add -b feature/<slug> <worktree-dir> <base-branch>` (vs reviewer's `fetch origin pull/N/head`)
- **Lockfiles**: `${WORKTREE_PARENT}/.lock-feature-<slug>` with PID, stale detection via `kill -0`
- **EXIT trap**: removes lockfile always; removes worktree + branch on failure
- **Git-ignore safety**: add worktree parent to `.git/info/exclude` if nested inside repo

### 6. .env Copying + Port Rewriting (~180 lines)

**Env copying**: Reuse `pr_review.sh` three-pass pattern verbatim (pattern list → root `.env*` sweep → deep `.env*` sweep with depth 4). Same `_try_copy()` with skip-tracked, skip-worktree-parent, and 5MB size guards.

**Port rewriting** (new):
- Scan all `.env*` files for lines matching `^[A-Z_]*PORT[A-Z_]*=([0-9]+)`
- Apply offset: `new_port = old_port + (feature_index * port_offset)`
- Feature 0 keeps original ports, feature 1 gets +10, feature 2 gets +20, etc.
- Write changes log to `.feature-context/env-ports-modified.log`
- In-place rewrite via temp file + `mv` (atomic)

**Example**: 3 features with `--port-offset 10`:
```
Feature 0 (add-auth):    PORT=3000  API_PORT=8080  VITE_PORT=5173
Feature 1 (build-api):   PORT=3010  API_PORT=8090  VITE_PORT=5183
Feature 2 (add-search):  PORT=3020  API_PORT=8100  VITE_PORT=5193
```

### 7. Manifest Management (~60 lines)
Track all features in `${WORKTREE_PARENT}/runner-manifest.json`:
```json
{
  "version": 1,
  "created": "2026-02-14T10:30:00Z",
  "features": [{
    "slug": "add-auth",
    "description": "Add user authentication",
    "branch": "feature/add-auth",
    "worktree": "/Users/reidmen/.feature_runner/feature-add-auth",
    "index": 0,
    "port_offset": 0,
    "pid": 12345,
    "status": "running|completed|failed",
    "started": "...",
    "completed": null,
    "exit_code": null,
    "issue_number": null,
    "source": "features|issue|file"
  }]
}
```
Atomic updates via `jq` + temp file + `mv`. Functions: `manifest_init()`, `manifest_add_feature()`, `manifest_update_status()`, `manifest_show()`.

### 8. Multi-Feature Orchestration (~250 lines)
Self-spawning pattern identical to `pr_review.sh`:

**iTerm2 mode**: AppleScript to create tabs, titles like `"Feature: add-auth"`, 0.3s sleep between spawns.

**tmux mode**: Session `features-HHMMSS`, one window per feature, attach or print switch instructions.

**Background mode**: Log files per feature, live dashboard with cursor-overwrite showing spinning/done/failed status, Ctrl+C detaches without killing children.

### 9. Claude Prompt — Agent Team (~120 lines)

Prompt instructs Claude to create a 4-agent team:

| Agent | Role |
|-------|------|
| **architect** | Analyze codebase, identify patterns, write implementation plan to `.feature-context/PLAN.md` |
| **implementer** | Write production code following the plan, make atomic git commits |
| **tester** | Write unit + integration tests, run test suite, report to `.feature-context/TEST-RESULTS.md` |
| **integrator** | Verify imports/exports/types/docs, ensure end-to-end functionality, write `.feature-context/INTEGRATION.md` |

**Workflow**: architect → implementer → tester → integrator → iterate if issues found.

**Final deliverable**: `.feature-context/SUMMARY.md` with: what was implemented, files created/modified, test results, integration notes, merge-readiness assessment.

**Subagent fallback** (`--no-teams`): Same 4 roles as explicit `--agents` JSON with per-agent tools and prompts.

### 10. Post-Session Interactive Shell (~150 lines)
Same `exec bash --rcfile` pattern as `pr_review.sh`. Custom prompt `[feature/add-auth] ~/path $`. Convenience commands:

| Command | Action |
|---------|--------|
| `status` | Show feature info, list `.feature-context/` artifacts, commits on branch |
| `log` | Display `SUMMARY.md` via `less` |
| `diff` | `git diff ${BASE_BRANCH}...HEAD` |
| `merge-ready` | Check: clean tree, has commits, test results exist, summary exists |
| `features` | Show all features from manifest with status icons |

---

## Key Differences from `pr_review.sh`

| Aspect | `pr_review.sh` | `runner.sh` |
|--------|----------------|-------------|
| Input | PR numbers (integers) | Feature descriptions, issue numbers, or file |
| Branch source | `fetch origin pull/N/head` | `worktree add -b feature/slug base-branch` |
| Branch naming | `pr-review/42` | `feature/add-auth` |
| Worktree dir | `~/.pr_reviewer/pr-42/` | `~/.feature_runner/feature-add-auth/` |
| Context dir | `.pr-review-context/` | `.feature-context/` |
| Agent roles | code-quality, security, logic, architecture reviewers | architect, implementer, tester, integrator |
| Port rewriting | None | Full .env port offset system |
| Manifest | None | `runner-manifest.json` |
| `gh` dependency | Required | Only for `--issue` mode |
| Max turns | 50 | 75 |
| Shell commands | `review`, `pdiff`, `files` | `status`, `log`, `diff`, `merge-ready`, `features` |
| Output artifacts | `REVIEW.md` | `PLAN.md`, `SUMMARY.md`, `TEST-RESULTS.md`, `INTEGRATION.md`, `ISSUE.md` (if issue mode) |

---

## Safety Patterns

- `set -euo pipefail` — strict error handling
- Lockfiles with PID + stale detection — no duplicate feature sessions
- Slug collision prevention — pre-validated before any spawning
- EXIT trap — always cleans lockfiles; cleans worktrees on failure
- `printf '%q'` for command construction — no injection
- `%s` in all logging — no backslash interpretation
- Atomic manifest writes — `jq` → tmp → `mv`
- Env file size guards — 5MB per file
- Subshell for `run_claude()` — `cd` isolated
- Base branch validation before worktree creation

---

## Verification

1. **Single feature**: `./runner.sh --features "Add hello world endpoint"` — verify worktree created, Claude launches, artifacts generated
2. **Parallel features**: `./runner.sh --features "Add auth" "Add API"` — verify separate worktrees, separate branches, tabs/windows created
3. **Port isolation**: Check `.env` files in each worktree have different ports
4. **Manifest**: Inspect `~/.feature_runner/runner-manifest.json` after run
5. **Post-shell**: Verify `status`, `diff`, `merge-ready`, `features` commands work in the drop-in shell
6. **Cleanup**: `./runner.sh --features "test" --cleanup` — verify worktree removed after completion
7. **Lockfile**: Run same feature twice simultaneously — verify second invocation is rejected
8. **Issue mode**: `./runner.sh --issue 42` — verify issue fetched, `ISSUE.md` written, prompt includes issue context
9. **Mixed mode**: `./runner.sh --issue 42 --features "Extra task"` — verify both issue-derived and manual features spawn correctly
10. **Issue slug**: Verify branch is named `feature/issue-42-<title-slug>` (not conflicting with plain `--features` slugs)

---

## Continuing This Work with Claude Code

To resume implementation from this plan, start a new Claude Code session in this directory and provide the following prompt:

```
Read PLAN.md in this repository. It contains the full implementation plan for
runner.sh — a parallel feature runner using Claude Code agent teams and git
worktrees. Implement runner.sh following the plan exactly.

Reference implementation: https://github.com/Reidmen/reviewer (pr_review.sh)
— reuse its patterns for colors, logging, terminal modes, env copying, and
the self-spawning orchestrator/worker architecture.
```

Alternatively, to work on a specific section:

```
Read PLAN.md. Implement only section N (the <section name>) of runner.sh.
The reference implementation is at https://github.com/Reidmen/reviewer.
```

To resume a partially-completed `runner.sh`:

```
Read PLAN.md and the current runner.sh. Identify which sections from the plan
are already implemented and which are missing. Continue implementation from
where it left off.
```

