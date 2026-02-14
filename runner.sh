#!/usr/bin/env bash
# runner.sh — Parallel Feature Runner using Claude Code Agent Teams
# Spawns parallel Claude Code sessions to implement features in isolated git worktrees.
#
# Usage:
#   ./runner.sh --features "Add auth" "Build API" "Add search"
#   ./runner.sh --from-file features.txt
#   ./runner.sh --issue 42 --issue 78 --issue 103
#   ./runner.sh --issue 42 --features "Extra task"
#
# Same self-spawning architecture as pr_review.sh — one script is both
# orchestrator and worker, selected by the internal --_single flag.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: Header, Colors, Logging
# ─────────────────────────────────────────────────────────────────────────────

readonly VERSION="1.0.0"
# shellcheck disable=SC2155
readonly SCRIPT_NAME="$(basename "$0")"
# shellcheck disable=SC2155
readonly SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/${SCRIPT_NAME}"

_use_color() {
    [[ "${RUNNER_NO_COLOR:-}" == "1" ]] && return 1
    [[ "${NO_COLOR:-}" == "1" ]] && return 1
    [[ -t 1 ]] && return 0
    return 1
}

if _use_color; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    WHITE=$'\033[1;37m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
    # Background colors for badges
    BG_GREEN=$'\033[42m'
    BG_RED=$'\033[41m'
    BG_BLUE=$'\033[44m'
    BG_YELLOW=$'\033[43m'
    BG_BLACK=$'\033[40m'
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" WHITE=""
    BOLD="" DIM="" RESET=""
    BG_GREEN="" BG_RED="" BG_BLUE="" BG_YELLOW="" BG_BLACK=""
fi

# Logging with visual icons
info()  { printf '  %s%s%s %s\n' "$BLUE"   "ℹ" "$RESET" "$*"; }
ok()    { printf '  %s%s%s %s\n' "$GREEN"  "✓" "$RESET" "$*"; }
warn()  { printf '  %s%s%s %s\n' "$YELLOW" "⚠" "$RESET" "$*" >&2; }
error() { printf '  %s%s%s %s\n' "$RED"    "✗" "$RESET" "$*" >&2; }
fatal() { printf '  %s%s %s%s\n' "$RED"    "✗" "$*" "$RESET" >&2; exit 1; }
step()  { printf '  %s▸%s %s\n' "$CYAN"   "$RESET" "$*"; }

# Section header — visually separates phases
_section() {
    local title="$1"
    echo ""
    printf '  %s%s─── %s %s───%s\n' "$BOLD" "$CYAN" "$title" "$CYAN" "$RESET"
    echo ""
}

# Hero banner for main entrypoints
_banner() {
    local title="$1"
    local subtitle="${2:-}"
    local width=56
    local border
    border=$(printf '═%.0s' $(seq 1 "$width"))
    echo ""
    printf '  %s%s╔%s╗%s\n' "$BOLD" "$CYAN" "$border" "$RESET"
    printf '  %s%s║%s  %s%-*s%s%s║%s\n' "$BOLD" "$CYAN" "$RESET" "$WHITE" $(( width - 2 )) "$title" "$BOLD" "$CYAN" "$RESET"
    if [[ -n "$subtitle" ]]; then
        printf '  %s%s║%s  %s%-*s%s%s║%s\n' "$BOLD" "$CYAN" "$RESET" "$DIM" $(( width - 2 )) "$subtitle" "$BOLD" "$CYAN" "$RESET"
    fi
    printf '  %s%s╚%s╝%s\n' "$BOLD" "$CYAN" "$border" "$RESET"
    echo ""
}

# Compact box for results/summaries
_boxln() {
    local msg="$1"
    local width=$(( ${#msg} + 4 ))
    local border
    border=$(printf '─%.0s' $(seq 1 "$width"))
    printf '  %s┌%s┐%s\n' "$BOLD" "$border" "$RESET"
    printf '  %s│  %s  │%s\n' "$BOLD" "$msg" "$RESET"
    printf '  %s└%s┘%s\n' "$BOLD" "$border" "$RESET"
}

# Status badge for feature list
_badge() {
    local label="$1"
    local bg="$2"
    printf '%s%s %s %s' "$bg" "$WHITE" "$label" "$RESET"
}

# Elapsed time tracker
_TIMER_START=""
_timer_start() { _TIMER_START="$(date +%s)"; }
_timer_elapsed() {
    [[ -z "$_TIMER_START" ]] && echo "0s" && return
    local now elapsed
    now="$(date +%s)"
    elapsed=$(( now - _TIMER_START ))
    if [[ $elapsed -lt 60 ]]; then
        echo "${elapsed}s"
    else
        echo "$((elapsed / 60))m $((elapsed % 60))s"
    fi
}

# Progress indicator for multi-step operations
_progress() {
    local current="$1"
    local total="$2"
    local label="$3"
    local pct=$(( current * 100 / total ))
    local filled=$(( pct / 5 ))
    local empty=$(( 20 - filled ))
    local bar=""
    [[ $filled -gt 0 ]] && bar+="$(printf '%0.s█' $(seq 1 "$filled"))"
    [[ $empty -gt 0 ]]  && bar+="$(printf '%0.s░' $(seq 1 "$empty"))"
    printf '  %s[%s/%s]%s %s %s%s%s %s%d%%%s\n' \
        "$DIM" "$current" "$total" "$RESET" \
        "$bar" "$BOLD" "$label" "$RESET" \
        "$DIM" "$pct" "$RESET"
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: Defaults & Argument Parsing
# ─────────────────────────────────────────────────────────────────────────────

FEATURES=()
ISSUE_NUMBERS=()
FROM_FILE=""
REPO=""
WORKTREE_PARENT="${HOME}/.feature_runner"
MODEL="opus"
MAX_TURNS=75
BASE_BRANCH=""
PORT_OFFSET=10
NO_PORT_REWRITE=false
TAB_MODE="auto"
CLEANUP=false
NO_ENV_COPY=false
NO_TEAMS=false

# Internal flags (passed to child processes)
_SINGLE=false
_FEATURE_INDEX=""
_FEATURE_DESC=""
_FEATURE_SLUG=""
_ISSUE_NUMBER=""
_ISSUE_JSON=""

# Issue data storage (bash 3.2 compatible — parallel indexed arrays)
_ISSUE_TITLES=()
_ISSUE_JSONS=()
_ISSUE_NUM_LIST=()

usage() {
    cat <<EOF
${BOLD}Parallel Feature Runner${RESET} v${VERSION}

${BOLD}USAGE${RESET}
  ${SCRIPT_NAME} --features "Add auth" "Build API" [OPTIONS]
  ${SCRIPT_NAME} --from-file features.txt [OPTIONS]
  ${SCRIPT_NAME} --issue 42 --issue 78 [OPTIONS]
  ${SCRIPT_NAME} --issue 42 --features "Extra task" [OPTIONS]

${BOLD}INPUT OPTIONS${RESET}
  --features <desc...>        Feature descriptions (one or more strings)
  --from-file <file>          Read features from file (one per line, # comments)
  --issue <number>            GitHub issue number (repeatable)

${BOLD}OPTIONS${RESET}
  -r, --repo <owner/repo>    Target repository (default: current repo)
  -d, --dir <path>           Worktree parent directory (default: ~/.feature_runner)
  -m, --model <model>        Claude model (default: opus)
  -b, --max-turns <N>        Max agentic turns (default: 75)
  --base-branch <branch>     Branch to create features from (default: current)
  --port-offset <N>          Port increment per feature (default: 10)
  --no-port-rewrite          Skip port rewriting
  --tabs <mode>              Terminal mode: auto|iterm|tmux|bg (default: auto)
  -c, --cleanup              Remove worktree after completion
  --no-env-copy              Skip .env copying
  --no-teams                 Use subagents instead of agent teams
  --no-color                 Disable colors

${BOLD}EXAMPLES${RESET}
  ${SCRIPT_NAME} --features "Add user authentication with OAuth2"
  ${SCRIPT_NAME} --features "Add auth" "Build REST API" "Add search" --tabs tmux
  ${SCRIPT_NAME} --from-file features.txt --model sonnet --max-turns 50
  ${SCRIPT_NAME} --issue 42 --issue 78 --base-branch develop
  ${SCRIPT_NAME} --issue 42 --features "Add rate limiting" --port-offset 20
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --features)
                shift
                # Collect all following args until next flag
                while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                    FEATURES+=("$1")
                    shift
                done
                ;;
            --from-file)
                shift
                FROM_FILE="${1:?--from-file requires a filename}"
                shift
                ;;
            --issue)
                shift
                ISSUE_NUMBERS+=("${1:?--issue requires a number}")
                shift
                ;;
            -r|--repo)
                shift
                REPO="${1:?--repo requires owner/repo}"
                shift
                ;;
            -d|--dir)
                shift
                WORKTREE_PARENT="${1:?--dir requires a path}"
                shift
                ;;
            -m|--model)
                shift
                MODEL="${1:?--model requires a model name}"
                shift
                ;;
            -b|--max-turns)
                shift
                MAX_TURNS="${1:?--max-turns requires a number}"
                shift
                ;;
            --base-branch)
                shift
                BASE_BRANCH="${1:?--base-branch requires a branch name}"
                shift
                ;;
            --port-offset)
                shift
                PORT_OFFSET="${1:?--port-offset requires a number}"
                shift
                ;;
            --no-port-rewrite)
                NO_PORT_REWRITE=true
                shift
                ;;
            --tabs)
                shift
                TAB_MODE="${1:?--tabs requires a mode}"
                shift
                ;;
            -c|--cleanup)
                CLEANUP=true
                shift
                ;;
            --no-env-copy)
                NO_ENV_COPY=true
                shift
                ;;
            --no-teams)
                NO_TEAMS=true
                shift
                ;;
            --no-color)
                export RUNNER_NO_COLOR=1
                shift
                ;;
            -h|--help)
                usage
                ;;
            --version)
                echo "runner.sh v${VERSION}"
                exit 0
                ;;
            # Internal flags (passed to child processes)
            --_single)
                _SINGLE=true
                shift
                ;;
            --_feature-index)
                shift
                _FEATURE_INDEX="$1"
                shift
                ;;
            --_feature-desc)
                shift
                _FEATURE_DESC="$1"
                shift
                ;;
            --_feature-slug)
                shift
                _FEATURE_SLUG="$1"
                shift
                ;;
            --_issue-number)
                shift
                _ISSUE_NUMBER="$1"
                shift
                ;;
            --_issue-json)
                shift
                _ISSUE_JSON="$1"
                shift
                ;;
            *)
                fatal "Unknown option: $1 (try --help)"
                ;;
        esac
    done
}

read_features_from_file() {
    local file="$1"
    [[ -f "$file" ]] || fatal "Features file not found: $file"

    while IFS= read -r line; do
        # Skip empty lines and comments
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        FEATURES+=("$line")
    done < "$file"
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: Slugification
# ─────────────────────────────────────────────────────────────────────────────

slugify() {
    local input="$1"
    local slug

    # Lowercase
    slug="$(echo "$input" | tr '[:upper:]' '[:lower:]')"
    # Replace non-alphanumeric with hyphens (requires sed for char class)
    # shellcheck disable=SC2001
    slug="$(echo "$slug" | sed 's/[^a-z0-9]/-/g')"
    # Collapse multiple hyphens (requires sed for quantifier)
    # shellcheck disable=SC2001
    slug="$(echo "$slug" | sed 's/-\{2,\}/-/g')"
    # Trim leading/trailing hyphens
    slug="${slug#-}"
    slug="${slug%-}"
    # Truncate to 50 chars
    slug="${slug:0:50}"
    # Trim trailing hyphen after truncation
    slug="${slug%-}"

    echo "$slug"
}

validate_slugs_unique() {
    local slugs=("$@")
    local seen=""
    for s in "${slugs[@]}"; do
        # Use newline-delimited list for O(n) dedup without associative arrays
        if echo "$seen" | grep -qxF "$s"; then
            fatal "Duplicate feature slug: '$s' — feature descriptions must produce unique slugs"
        fi
        seen="${seen}${s}"$'\n'
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 4: Issue Resolution (--issue mode)
# ─────────────────────────────────────────────────────────────────────────────

resolve_issues() {
    command -v gh &>/dev/null || fatal "'gh' CLI required for --issue mode. Install: https://cli.github.com"

    local repo_flag=""
    [[ -n "$REPO" ]] && repo_flag="--repo $REPO"

    for issue_num in "${ISSUE_NUMBERS[@]}"; do
        step "Fetching issue #${issue_num}"

        local issue_json
        # shellcheck disable=SC2086
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
        # Store issue data in parallel arrays (bash 3.2 compatible)
        _ISSUE_TITLES+=("$title")
        _ISSUE_JSONS+=("$issue_json")
        _ISSUE_NUM_LIST+=("$issue_num")

        ok "Issue #${issue_num}: ${title}"
        [[ -n "$labels" ]] && info "  Labels: ${labels}"
    done
}

_lookup_issue_num() {
    local title="$1"
    local i=0
    for t in "${_ISSUE_TITLES[@]}"; do
        if [[ "$t" == "$title" ]]; then
            echo "${_ISSUE_NUM_LIST[$i]}"
            return 0
        fi
        ((i++))
    done
    echo ""
}

_lookup_issue_json() {
    local title="$1"
    local i=0
    for t in "${_ISSUE_TITLES[@]}"; do
        if [[ "$t" == "$title" ]]; then
            echo "${_ISSUE_JSONS[$i]}"
            return 0
        fi
        ((i++))
    done
    echo ""
}

issue_slug() {
    local issue_num="$1"
    local title="$2"
    local title_slug
    title_slug="$(slugify "$title")"
    # Truncate title slug to leave room for issue- prefix
    title_slug="${title_slug:0:38}"
    title_slug="${title_slug%-}"
    echo "issue-${issue_num}-${title_slug}"
}

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

# ─────────────────────────────────────────────────────────────────────────────
# Section 5: Git Worktree Management
# ─────────────────────────────────────────────────────────────────────────────

GIT_ROOT=""
RESOLVED_BASE_BRANCH=""
WORKTREE_DIR=""
LOCKFILE=""

resolve_git_root() {
    GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
        || fatal "Not inside a git repository"
}

resolve_base_branch() {
    if [[ -n "$BASE_BRANCH" ]]; then
        # Validate the provided branch exists
        git -C "$GIT_ROOT" rev-parse --verify "$BASE_BRANCH" &>/dev/null \
            || fatal "Base branch '$BASE_BRANCH' does not exist"
        RESOLVED_BASE_BRANCH="$BASE_BRANCH"
    else
        # Use current branch
        RESOLVED_BASE_BRANCH="$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
            || fatal "Cannot determine current branch"
    fi
    info "Base branch: ${RESOLVED_BASE_BRANCH}"
}

acquire_lock() {
    local slug="$1"
    LOCKFILE="${WORKTREE_PARENT}/.lock-feature-${slug}"

    if [[ -f "$LOCKFILE" ]]; then
        local lock_pid
        lock_pid="$(cat "$LOCKFILE" 2>/dev/null || echo "")"
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            fatal "Feature '${slug}' is already running (PID ${lock_pid}). Remove ${LOCKFILE} if stale."
        else
            warn "Removing stale lockfile for '${slug}' (PID ${lock_pid} not running)"
            rm -f "$LOCKFILE"
        fi
    fi

    mkdir -p "$WORKTREE_PARENT"
    echo $$ > "$LOCKFILE"
}

release_lock() {
    [[ -n "${LOCKFILE:-}" && -f "${LOCKFILE:-}" ]] && rm -f "$LOCKFILE"
}

create_worktree() {
    local slug="$1"
    local feature_branch="feature/${slug}"
    WORKTREE_DIR="${WORKTREE_PARENT}/feature-${slug}"

    # Safety: add worktree parent to git excludes if nested inside repo
    local exclude_file="${GIT_ROOT}/.git/info/exclude"
    local rel_parent=""
    if [[ "$WORKTREE_PARENT" == "$GIT_ROOT"/* ]]; then
        rel_parent="${WORKTREE_PARENT#"$GIT_ROOT/"}"
    fi
    if [[ -n "$rel_parent" ]] && ! grep -qF "$rel_parent" "$exclude_file" 2>/dev/null; then
        echo "$rel_parent" >> "$exclude_file"
        info "Added ${rel_parent} to .git/info/exclude"
    fi

    if [[ -d "$WORKTREE_DIR" ]]; then
        warn "Worktree already exists: ${WORKTREE_DIR}"
        info "Reusing existing worktree"
        return 0
    fi

    step "Creating worktree: ${WORKTREE_DIR}"
    step "Branch: ${feature_branch} (from ${RESOLVED_BASE_BRANCH})"

    # Check if branch already exists
    if git -C "$GIT_ROOT" rev-parse --verify "$feature_branch" &>/dev/null; then
        # Branch exists — create worktree without -b
        git -C "$GIT_ROOT" worktree add "$WORKTREE_DIR" "$feature_branch" \
            || fatal "Failed to create worktree for existing branch '${feature_branch}'"
    else
        # Create new branch from base
        git -C "$GIT_ROOT" worktree add -b "$feature_branch" "$WORKTREE_DIR" "$RESOLVED_BASE_BRANCH" \
            || fatal "Failed to create worktree: ${WORKTREE_DIR}"
    fi

    ok "Worktree created: ${WORKTREE_DIR}"
}

cleanup_worktree() {
    local slug="$1"
    local feature_branch="feature/${slug}"
    local wt_dir="${WORKTREE_PARENT}/feature-${slug}"

    if [[ -d "$wt_dir" ]]; then
        step "Removing worktree: ${wt_dir}"
        git -C "$GIT_ROOT" worktree remove --force "$wt_dir" 2>/dev/null || rm -rf "$wt_dir"
    fi

    # Remove branch if no commits ahead of base
    if git -C "$GIT_ROOT" rev-parse --verify "$feature_branch" &>/dev/null; then
        local ahead
        ahead="$(git -C "$GIT_ROOT" rev-list "${RESOLVED_BASE_BRANCH}..${feature_branch}" --count 2>/dev/null || echo "0")"
        if [[ "$ahead" -eq 0 ]]; then
            git -C "$GIT_ROOT" branch -d "$feature_branch" 2>/dev/null || true
            info "Removed empty branch: ${feature_branch}"
        else
            warn "Keeping branch ${feature_branch} (${ahead} commits ahead)"
        fi
    fi
}

# EXIT trap for worker mode
_worker_exit_handler() {
    local exit_code=$?
    release_lock

    if [[ "$CLEANUP" == true ]] || [[ $exit_code -ne 0 && -n "${_FEATURE_SLUG:-}" ]]; then
        if [[ $exit_code -ne 0 ]]; then
            warn "Worker exited with code ${exit_code} — cleaning up worktree"
        fi
        cleanup_worktree "${_FEATURE_SLUG}" 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 6: .env Copying + Port Rewriting
# ─────────────────────────────────────────────────────────────────────────────

readonly ENV_MAX_SIZE=$((5 * 1024 * 1024))  # 5MB

_try_copy() {
    local src="$1"
    local dst_dir="$2"
    local relative_path="$3"
    local dst="${dst_dir}/${relative_path}"

    # Skip if file is tracked in git (not a secret)
    if git -C "$GIT_ROOT" ls-files --error-unmatch "$src" &>/dev/null 2>&1; then
        return 0
    fi

    # Skip if inside worktree parent
    if [[ "$src" == "${WORKTREE_PARENT}"* ]]; then
        return 0
    fi

    # Size guard
    local fsize
    fsize="$(wc -c < "$src" 2>/dev/null || echo 0)"
    if [[ "$fsize" -gt "$ENV_MAX_SIZE" ]]; then
        warn "Skipping ${relative_path} (${fsize} bytes > 5MB limit)"
        return 0
    fi

    # Create parent directory
    mkdir -p "$(dirname "$dst")"

    # Copy preserving permissions
    cp -p "$src" "$dst"
    info "  Copied: ${relative_path}"
}

copy_env_files() {
    local target_dir="$1"

    [[ "$NO_ENV_COPY" == true ]] && return 0

    step "Copying .env files"
    local count=0
    local -a copied_paths=()

    # Single pass: find all .env* files up to depth 4
    # Catches: .env, .env.local, .env.development, .env.staging, .env.production,
    #          .env.test, .env.ci, .env.docker, .env.example, and any nested ones
    #          like packages/api/.env, apps/web/.env.local, etc.
    while IFS= read -r -d '' envfile; do
        [[ -f "$envfile" ]] || continue
        local relpath="${envfile#"${GIT_ROOT}/"}"

        # Deduplicate (find can return same file via symlinks)
        local already_copied=false
        for p in "${copied_paths[@]+"${copied_paths[@]}"}"; do
            [[ "$p" == "$relpath" ]] && { already_copied=true; break; }
        done
        [[ "$already_copied" == true ]] && continue

        _try_copy "$envfile" "$target_dir" "$relpath"
        copied_paths+=("$relpath")
        ((count++)) || true
    done < <(find "$GIT_ROOT" -maxdepth 4 -name '.env*' -type f -print0 2>/dev/null || true)

    if [[ $count -eq 0 ]]; then
        info "  No .env files found to copy"
    else
        ok "Copied ${count} .env file(s)"
    fi
}

rewrite_ports() {
    local target_dir="$1"
    local feature_index="$2"
    local offset="$3"

    [[ "$NO_PORT_REWRITE" == true ]] && return 0
    [[ "$feature_index" -eq 0 ]] && return 0  # Feature 0 keeps original ports

    local total_offset=$(( feature_index * offset ))
    step "Rewriting ports (+${total_offset} for feature index ${feature_index})"

    local log_dir="${target_dir}/.feature-context"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/env-ports-modified.log"
    : > "$log_file"

    local modified=0

    while IFS= read -r -d '' envfile; do
        [[ -f "$envfile" ]] || continue
        local relpath="${envfile#"${target_dir}/"}"
        local tmpfile
        tmpfile="$(mktemp "${envfile}.XXXXXX")"
        local file_modified=false

        while IFS= read -r line; do
            if [[ "$line" =~ ^([A-Z_]*PORT[A-Z_]*)=([0-9]+)$ ]]; then
                local var_name="${BASH_REMATCH[1]}"
                local old_port="${BASH_REMATCH[2]}"
                local new_port=$(( old_port + total_offset ))
                printf '%s=%s\n' "$var_name" "$new_port" >> "$tmpfile"
                printf '%s: %s %s → %s\n' "$relpath" "$var_name" "$old_port" "$new_port" >> "$log_file"
                file_modified=true
                ((modified++)) || true
            else
                printf '%s\n' "$line" >> "$tmpfile"
            fi
        done < "$envfile"

        if [[ "$file_modified" == true ]]; then
            mv "$tmpfile" "$envfile"
            info "  Rewrote ports in: ${relpath}"
        else
            rm -f "$tmpfile"
        fi
    done < <(find "$target_dir" -name '.env*' -type f -print0 2>/dev/null || true)

    if [[ $modified -eq 0 ]]; then
        info "  No port variables found to rewrite"
    else
        ok "Rewrote ${modified} port(s) — log: .feature-context/env-ports-modified.log"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 7: Manifest Management
# ─────────────────────────────────────────────────────────────────────────────

MANIFEST_FILE=""

manifest_init() {
    MANIFEST_FILE="${WORKTREE_PARENT}/runner-manifest.json"

    if [[ -f "$MANIFEST_FILE" ]]; then
        info "Manifest exists: ${MANIFEST_FILE}"
        return 0
    fi

    mkdir -p "$WORKTREE_PARENT"
    cat > "$MANIFEST_FILE" <<EOF
{
  "version": 1,
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "features": []
}
EOF
    ok "Manifest initialized: ${MANIFEST_FILE}"
}

manifest_add_feature() {
    local slug="$1"
    local desc="$2"
    local branch="$3"
    local worktree="$4"
    local index="$5"
    local port_off="$6"
    local issue_num="${7:-null}"
    local source="${8:-features}"

    local tmpfile
    tmpfile="$(mktemp "${MANIFEST_FILE}.XXXXXX")"

    # Quote issue_num properly for JSON
    local issue_json_val="null"
    [[ "$issue_num" != "null" && -n "$issue_num" ]] && issue_json_val="$issue_num"

    if jq --arg slug "$slug" \
       --arg desc "$desc" \
       --arg branch "$branch" \
       --arg worktree "$worktree" \
       --argjson index "$index" \
       --argjson port_off "$port_off" \
       --argjson pid "$$" \
       --arg started "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       --arg source "$source" \
       --argjson issue_num "$issue_json_val" \
       '.features += [{
         slug: $slug,
         description: $desc,
         branch: $branch,
         worktree: $worktree,
         index: $index,
         port_offset: $port_off,
         pid: $pid,
         status: "running",
         started: $started,
         completed: null,
         exit_code: null,
         issue_number: $issue_num,
         source: $source
       }]' "$MANIFEST_FILE" > "$tmpfile"; then
        mv "$tmpfile" "$MANIFEST_FILE"
    else
        rm -f "$tmpfile"
        warn "Failed to update manifest"
    fi
}

manifest_update_status() {
    local slug="$1"
    local status="$2"
    local exit_code="${3:-null}"

    local tmpfile
    tmpfile="$(mktemp "${MANIFEST_FILE}.XXXXXX")"

    if jq --arg slug "$slug" \
       --arg status "$status" \
       --argjson exit_code "$exit_code" \
       --arg completed "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       '(.features[] | select(.slug == $slug)) |= . + {
         status: $status,
         completed: $completed,
         exit_code: $exit_code
       }' "$MANIFEST_FILE" > "$tmpfile"; then
        mv "$tmpfile" "$MANIFEST_FILE"
    else
        rm -f "$tmpfile"
        warn "Failed to update manifest status"
    fi
}

manifest_show() {
    [[ -f "$MANIFEST_FILE" ]] || { warn "No manifest found"; return 1; }

    _section "Manifest"

    local count
    count="$(jq '.features | length' "$MANIFEST_FILE")"

    local i=0
    while [[ $i -lt $count ]]; do
        local slug status desc branch issue_num
        slug="$(jq -r ".features[$i].slug" "$MANIFEST_FILE")"
        status="$(jq -r ".features[$i].status" "$MANIFEST_FILE")"
        desc="$(jq -r ".features[$i].description" "$MANIFEST_FILE")"
        branch="$(jq -r ".features[$i].branch" "$MANIFEST_FILE")"
        issue_num="$(jq -r ".features[$i].issue_number // \"\"" "$MANIFEST_FILE")"

        local badge_text badge_bg
        case "$status" in
            running)   badge_text="RUN"; badge_bg="$BG_YELLOW" ;;
            completed) badge_text=" OK"; badge_bg="$BG_GREEN" ;;
            failed)    badge_text="ERR"; badge_bg="$BG_RED" ;;
            *)         badge_text=" - "; badge_bg="$BG_BLACK" ;;
        esac

        printf '  %s  %s%-22s%s %s' "$(_badge "$badge_text" "$badge_bg")" "$BOLD" "$slug" "$RESET" "$desc"
        [[ -n "$issue_num" && "$issue_num" != "null" ]] && printf '  %s#%s%s' "$DIM" "$issue_num" "$RESET"
        printf '\n'
        printf '       %s%s%s\n' "$DIM" "$branch" "$RESET"

        ((i++))
    done
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 8: Multi-Feature Orchestration
# ─────────────────────────────────────────────────────────────────────────────

detect_terminal() {
    if [[ "$TAB_MODE" != "auto" ]]; then
        echo "$TAB_MODE"
        return
    fi

    # Detect iTerm2
    if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] || [[ -n "${ITERM_SESSION_ID:-}" ]]; then
        echo "iterm"
        return
    fi

    # Detect tmux
    if [[ -n "${TMUX:-}" ]] || command -v tmux &>/dev/null; then
        echo "tmux"
        return
    fi

    # Fallback to background mode
    echo "bg"
}

build_child_cmd() {
    local index="$1"
    local desc="$2"
    local slug="$3"
    local issue_num="${4:-}"
    local issue_json="${5:-}"

    local cmd
    cmd="$(printf '%q' "$SCRIPT_PATH")"
    cmd+=" --_single"
    cmd+=" --_feature-index $(printf '%q' "$index")"
    cmd+=" --_feature-desc $(printf '%q' "$desc")"
    cmd+=" --_feature-slug $(printf '%q' "$slug")"
    cmd+=" -d $(printf '%q' "$WORKTREE_PARENT")"
    cmd+=" -m $(printf '%q' "$MODEL")"
    cmd+=" --max-turns $(printf '%q' "$MAX_TURNS")"
    cmd+=" --base-branch $(printf '%q' "$RESOLVED_BASE_BRANCH")"
    cmd+=" --port-offset $(printf '%q' "$PORT_OFFSET")"

    [[ "$NO_PORT_REWRITE" == true ]] && cmd+=" --no-port-rewrite"
    [[ "$CLEANUP" == true ]]         && cmd+=" --cleanup"
    [[ "$NO_ENV_COPY" == true ]]     && cmd+=" --no-env-copy"
    [[ "$NO_TEAMS" == true ]]        && cmd+=" --no-teams"
    [[ -n "$REPO" ]]                 && cmd+=" --repo $(printf '%q' "$REPO")"

    if [[ -n "$issue_num" ]]; then
        cmd+=" --_issue-number $(printf '%q' "$issue_num")"
    fi
    if [[ -n "$issue_json" ]]; then
        # Write issue JSON to temp file and pass path (avoids arg length limits)
        local tmpjson="${WORKTREE_PARENT}/.issue-${slug}.json"
        echo "$issue_json" > "$tmpjson"
        cmd+=" --_issue-json $(printf '%q' "$tmpjson")"
    fi

    echo "$cmd"
}

spawn_iterm() {
    local slugs=("${!1}")
    # $2 (descs) available but unused in iterm mode
    local cmds=("${!3}")

    info "Spawning ${#cmds[@]} iTerm2 tab(s)"

    local i=0
    for cmd in "${cmds[@]}"; do
        local title="Feature: ${slugs[$i]}"
        local escaped_cmd="${cmd//\\/\\\\}"
        escaped_cmd="${escaped_cmd//\"/\\\"}"

        if [[ $i -eq 0 ]]; then
            # Use current tab for first feature
            osascript <<APPLESCRIPT
tell application "iTerm2"
    tell current session of current tab of current window
        set name to "${title}"
        write text "${escaped_cmd}"
    end tell
end tell
APPLESCRIPT
        else
            osascript <<APPLESCRIPT
tell application "iTerm2"
    tell current window
        set newTab to (create tab with default profile)
        tell current session of newTab
            set name to "${title}"
            write text "${escaped_cmd}"
        end tell
    end tell
end tell
APPLESCRIPT
        fi

        ((i++))
        [[ $i -lt ${#cmds[@]} ]] && sleep 0.3
    done

    ok "Spawned ${#cmds[@]} feature(s) in iTerm2 tabs"
}

spawn_tmux() {
    local slugs=("${!1}")
    # $2 (descs) available but unused in tmux mode
    local cmds=("${!3}")

    local session_name
    session_name="features-$(date +%H%M%S)"
    info "Creating tmux session: ${session_name}"

    local i=0
    for cmd in "${cmds[@]}"; do
        local window_name="${slugs[$i]}"

        if [[ $i -eq 0 ]]; then
            tmux new-session -d -s "$session_name" -n "$window_name" "$cmd"
        else
            tmux new-window -t "$session_name" -n "$window_name" "$cmd"
        fi

        ((i++))
    done

    ok "Created tmux session '${session_name}' with ${#cmds[@]} window(s)"

    # Attach if not already in tmux
    if [[ -z "${TMUX:-}" ]]; then
        info "Attaching to tmux session..."
        exec tmux attach-session -t "$session_name"
    else
        info "Switch to session: tmux switch-client -t ${session_name}"
    fi
}

spawn_background() {
    local slugs=("${!1}")
    # $2 (descs) available but unused in background mode
    local cmds=("${!3}")

    local log_dir="${WORKTREE_PARENT}/logs"
    mkdir -p "$log_dir"

    local -a pids=()
    local i=0
    for cmd in "${cmds[@]}"; do
        local log_file="${log_dir}/${slugs[$i]}.log"
        info "Launching background: ${slugs[$i]} → ${log_file}"
        eval "$cmd" > "$log_file" 2>&1 &
        pids+=($!)
        ((i++))
    done

    ok "Launched ${#pids[@]} background feature(s)"

    # Dashboard
    _section "Live Dashboard"
    printf '  %sPress Ctrl+C to detach — features continue in background%s\n' "$DIM" "$RESET"
    echo ""

    # Trap SIGINT to detach gracefully
    trap 'echo ""; echo ""; info "Detached. Features continue in background."; info "Logs: ${log_dir}/"; exit 0' INT

    local all_done=false
    while [[ "$all_done" != true ]]; do
        all_done=true
        local completed_count=0
        local i=0
        for pid in "${pids[@]}"; do
            local slug="${slugs[$i]}"
            local status_icon

            if kill -0 "$pid" 2>/dev/null; then
                status_icon="$(_badge "RUN" "$BG_YELLOW")"
                all_done=false
            elif wait "$pid" 2>/dev/null; then
                status_icon="$(_badge " OK" "$BG_GREEN")"
                ((completed_count++)) || true
            else
                status_icon="$(_badge "ERR" "$BG_RED")"
                ((completed_count++)) || true
            fi

            printf '  %s  %-30s\n' "$status_icon" "$slug"
            ((i++))
        done

        # Progress bar
        local total=${#pids[@]}
        echo ""
        _progress "$completed_count" "$total" "$(_timer_elapsed) elapsed"

        if [[ "$all_done" != true ]]; then
            sleep 2
            # Move cursor up to overwrite (features + blank line + progress)
            printf '\033[%dA' "$(( ${#pids[@]} + 2 ))"
        fi
    done

    echo ""
    printf '  %s%s ALL DONE %s  %s features completed in %s\n' \
        "$BG_GREEN" "$WHITE" "$RESET" "${#pids[@]}" "$(_timer_elapsed)"
    echo ""
    manifest_show
}

orchestrate() {
    local -a slugs=()
    local -a cmds=()

    _section "Feature Plan"

    # Generate slugs
    local i=0
    for desc in "${FEATURES[@]}"; do
        local slug
        local issue_num
        issue_num="$(_lookup_issue_num "$desc")"

        if [[ -n "$issue_num" ]]; then
            slug="$(issue_slug "$issue_num" "$desc")"
        else
            slug="$(slugify "$desc")"
        fi
        slugs+=("$slug")

        printf '  %s%d%s  %-40s %s→ feature/%s%s\n' \
            "$BOLD" $((i+1)) "$RESET" "$desc" "$DIM" "$slug" "$RESET"
        ((i++))
    done
    echo ""

    # Validate uniqueness
    validate_slugs_unique "${slugs[@]}"

    # Initialize manifest
    manifest_init

    # Build child commands
    i=0
    for desc in "${FEATURES[@]}"; do
        local slug="${slugs[$i]}"
        local issue_num
        issue_num="$(_lookup_issue_num "$desc")"
        local issue_json
        issue_json="$(_lookup_issue_json "$desc")"

        local cmd
        cmd="$(build_child_cmd "$i" "$desc" "$slug" "$issue_num" "$issue_json")"
        cmds+=("$cmd")

        # Add to manifest
        local source="features"
        [[ -n "$issue_num" ]] && source="issue"
        [[ -n "$FROM_FILE" && -z "$issue_num" ]] && source="file"
        local issue_val="${issue_num:-null}"
        manifest_add_feature "$slug" "$desc" "feature/${slug}" \
            "${WORKTREE_PARENT}/feature-${slug}" "$i" \
            "$(( i * PORT_OFFSET ))" "$issue_val" "$source"

        ((i++))
    done

    # Detect terminal and spawn
    _section "Launching"

    local term_mode
    term_mode="$(detect_terminal)"
    info "Terminal mode: ${BOLD}${term_mode}${RESET}"

    case "$term_mode" in
        iterm)
            spawn_iterm slugs[@] FEATURES[@] cmds[@]
            ;;
        tmux)
            spawn_tmux slugs[@] FEATURES[@] cmds[@]
            ;;
        bg)
            spawn_background slugs[@] FEATURES[@] cmds[@]
            ;;
        *)
            fatal "Unknown terminal mode: ${term_mode}"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 9: Claude Prompt — Agent Team
# ─────────────────────────────────────────────────────────────────────────────

build_prompt() {
    local desc="$1"
    local slug="$2"
    local issue_number="${3:-}"
    local has_issue_context="${4:-false}"

    local issue_section=""
    if [[ "$has_issue_context" == true && -n "$issue_number" ]]; then
        issue_section="
## Issue Context

This feature is based on GitHub Issue #${issue_number}. Full issue details
(description, comments, labels) are in \`.feature-context/ISSUE.md\`.
Read it carefully before planning — it contains requirements, discussion,
and decisions from the team.
"
    fi

    cat <<PROMPT_EOF
# Feature Implementation: ${desc}

You are implementing a new feature in this codebase. Work methodically through
the phases below. Commit your work after each phase.

## Feature Description
${desc}
${issue_section}

## Working Directory
You are in a dedicated git worktree on branch \`feature/${slug}\`.
All your changes are isolated — the main branch is untouched.

## Implementation Workflow

Work through these phases in order. Each phase builds on the previous one.

### Phase 1: Architecture & Planning
- Explore the codebase to understand structure, patterns, and conventions
- Identify where the feature fits in the architecture
- Write a clear implementation plan to \`.feature-context/PLAN.md\`
- Include: files to create/modify, dependencies, approach rationale
- Commit: "feat(${slug}): add implementation plan"

### Phase 2: Implementation
- Follow the plan from Phase 1
- Match existing code style and patterns exactly
- Make atomic, well-structured changes
- Write clean, production-quality code
- Commit after each logical unit of work with descriptive messages

### Phase 3: Testing
- Write comprehensive tests (unit + integration where applicable)
- Follow existing test patterns and frameworks in the project
- Run the full test suite to ensure nothing is broken
- Write results to \`.feature-context/TEST-RESULTS.md\`
- Commit: "test(${slug}): add tests"

### Phase 4: Integration & Verification
- Verify all imports, exports, and types are correct
- Check for any broken references or missing dependencies
- Ensure the feature works end-to-end
- Update documentation if the project has docs
- Write verification notes to \`.feature-context/INTEGRATION.md\`
- Commit: "feat(${slug}): integration verification"

### Phase 5: Summary
- Write a comprehensive summary to \`.feature-context/SUMMARY.md\` including:
  - What was implemented
  - Files created and modified
  - Test results
  - Integration notes
  - Any caveats or follow-up items
  - Merge-readiness assessment (ready / needs-review / blocked)
- Final commit: "feat(${slug}): complete implementation"

## Guidelines
- Do NOT modify files outside the scope of this feature
- Do NOT push to remote — only local commits
- If you encounter blocking issues, document them in SUMMARY.md
- Prefer small, focused commits over large monolithic ones
- Follow existing conventions — don't introduce new patterns unless necessary
PROMPT_EOF
}

build_team_config() {
    cat <<'TEAM_EOF'
[
  {
    "name": "architect",
    "description": "Analyzes codebase structure and designs implementation plan",
    "prompt": "You are the architect. Your job is to explore the codebase, understand its patterns, and write a clear implementation plan to .feature-context/PLAN.md. Focus on: file structure, existing patterns, where the feature fits, and step-by-step implementation approach.",
    "tools": ["read", "glob", "grep", "write"]
  },
  {
    "name": "implementer",
    "description": "Writes production code following the architect's plan",
    "prompt": "You are the implementer. Read the plan in .feature-context/PLAN.md, then write clean, production-quality code that follows existing patterns. Make atomic commits after each logical unit of work.",
    "tools": ["read", "glob", "grep", "write", "edit", "bash"]
  },
  {
    "name": "tester",
    "description": "Writes tests and runs the test suite",
    "prompt": "You are the tester. Write comprehensive unit and integration tests following existing test patterns. Run the full test suite and report results to .feature-context/TEST-RESULTS.md.",
    "tools": ["read", "glob", "grep", "write", "edit", "bash"]
  },
  {
    "name": "integrator",
    "description": "Verifies end-to-end functionality and integration",
    "prompt": "You are the integrator. Verify all imports, exports, types, and dependencies are correct. Check end-to-end functionality. Update docs if needed. Write findings to .feature-context/INTEGRATION.md.",
    "tools": ["read", "glob", "grep", "write", "edit", "bash"]
  }
]
TEAM_EOF
}

run_claude() {
    local slug="$1"
    local prompt="$2"
    local worktree_dir="$3"

    (
        cd "$worktree_dir" || fatal "Cannot cd to worktree: ${worktree_dir}"

        # Create feature context directory
        mkdir -p .feature-context

        local -a claude_args=()
        claude_args+=(--print)
        claude_args+=(--model "$MODEL")
        claude_args+=(--max-turns "$MAX_TURNS")
        claude_args+=(--dangerously-skip-permissions)

        if [[ "$NO_TEAMS" != true ]]; then
            local team_config
            team_config="$(build_team_config)"
            claude_args+=(--agents "$team_config")
        fi

        printf '  %s▸%s Launching Claude Code\n' "$CYAN" "$RESET"
        printf '    %sModel%s     %s\n' "$DIM" "$RESET" "$MODEL"
        printf '    %sTurns%s     %s max\n' "$DIM" "$RESET" "$MAX_TURNS"
        printf '    %sTeams%s     %s\n' "$DIM" "$RESET" "$([[ "$NO_TEAMS" == true ]] && echo "off (subagents)" || echo "on (architect, implementer, tester, integrator)")"
        printf '    %sWorktree%s  %s\n' "$DIM" "$RESET" "$worktree_dir"
        echo ""

        local exit_code=0
        echo "$prompt" | claude "${claude_args[@]}" || exit_code=$?

        return $exit_code
    )
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 10: Post-Session Interactive Shell
# ─────────────────────────────────────────────────────────────────────────────

drop_into_shell() {
    local slug="$1"
    local worktree_dir="$2"
    local base_branch="$3"

    echo ""
    _boxln "Feature session complete: ${slug}"
    echo ""
    info "Dropping into interactive shell in worktree"
    info "Type 'help' for available commands, 'exit' to leave"
    echo ""

    # Create rcfile for custom shell
    local rcfile
    rcfile="$(mktemp /tmp/runner-shell-XXXXXX)"

    cat > "$rcfile" <<SHELL_EOF
# Source user's profile
[[ -f ~/.bashrc ]] && source ~/.bashrc 2>/dev/null
[[ -f ~/.bash_profile ]] && source ~/.bash_profile 2>/dev/null

# Custom prompt
export PS1='${GREEN}[feature/${slug}]${RESET} \w \$ '

# Feature metadata
export FEATURE_SLUG="${slug}"
export FEATURE_WORKTREE="${worktree_dir}"
export FEATURE_BASE_BRANCH="${base_branch}"
export FEATURE_MANIFEST="${MANIFEST_FILE}"

cd "${worktree_dir}"

# Convenience commands
status() {
    echo ""
    echo "${BOLD}Feature: ${slug}${RESET}"
    echo "  Worktree: ${worktree_dir}"
    echo "  Branch: feature/${slug}"
    echo "  Base: ${base_branch}"
    echo ""

    if [[ -d .feature-context ]]; then
        echo "${BOLD}Artifacts:${RESET}"
        ls -la .feature-context/ 2>/dev/null | tail -n +2
        echo ""
    fi

    echo "${BOLD}Commits on this branch:${RESET}"
    git log --oneline "${base_branch}..HEAD" 2>/dev/null || echo "  (no commits yet)"
    echo ""
}

log() {
    if [[ -f .feature-context/SUMMARY.md ]]; then
        less .feature-context/SUMMARY.md
    else
        echo "No SUMMARY.md found yet."
    fi
}

diff() {
    git diff "${base_branch}...HEAD"
}

merge-ready() {
    echo ""
    local ready=true

    # Clean tree?
    if [[ -z \$(git status --porcelain) ]]; then
        echo "  ${GREEN}✓${RESET} Working tree is clean"
    else
        echo "  ${RED}✗${RESET} Working tree has uncommitted changes"
        ready=false
    fi

    # Has commits?
    local commits
    commits=\$(git rev-list "${base_branch}..HEAD" --count 2>/dev/null || echo 0)
    if [[ \$commits -gt 0 ]]; then
        echo "  ${GREEN}✓${RESET} Has \${commits} commit(s) on branch"
    else
        echo "  ${RED}✗${RESET} No commits on branch"
        ready=false
    fi

    # Test results?
    if [[ -f .feature-context/TEST-RESULTS.md ]]; then
        echo "  ${GREEN}✓${RESET} Test results exist"
    else
        echo "  ${YELLOW}⚠${RESET} No test results found"
    fi

    # Summary?
    if [[ -f .feature-context/SUMMARY.md ]]; then
        echo "  ${GREEN}✓${RESET} Summary exists"
    else
        echo "  ${RED}✗${RESET} No summary found"
        ready=false
    fi

    echo ""
    if [[ "\$ready" == true ]]; then
        echo "  ${GREEN}${BOLD}→ Ready to merge${RESET}"
    else
        echo "  ${YELLOW}${BOLD}→ Not ready — see issues above${RESET}"
    fi
    echo ""
}

features() {
    if [[ -f "${MANIFEST_FILE}" ]]; then
        local count
        count=\$(jq '.features | length' "${MANIFEST_FILE}")
        echo ""
        echo "${BOLD}All Features:${RESET}"
        local i=0
        while [[ \$i -lt \$count ]]; do
            local s st d
            s=\$(jq -r ".features[\$i].slug" "${MANIFEST_FILE}")
            st=\$(jq -r ".features[\$i].status" "${MANIFEST_FILE}")
            d=\$(jq -r ".features[\$i].description" "${MANIFEST_FILE}")
            local icon
            case "\$st" in
                running)   icon="${YELLOW}●${RESET}" ;;
                completed) icon="${GREEN}✓${RESET}" ;;
                failed)    icon="${RED}✗${RESET}" ;;
                *)         icon="○" ;;
            esac
            if [[ "\$s" == "${slug}" ]]; then
                printf '  %s %-20s %s ${BOLD}← current${RESET}\n' "\$icon" "\$s" "\$d"
            else
                printf '  %s %-20s %s\n' "\$icon" "\$s" "\$d"
            fi
            ((i++))
        done
        echo ""
    else
        echo "No manifest found."
    fi
}

help() {
    echo ""
    echo "${BOLD}Available commands:${RESET}"
    echo "  status       Show feature info, artifacts, and commits"
    echo "  log          Display SUMMARY.md"
    echo "  diff         Show diff from base branch"
    echo "  merge-ready  Check if feature is ready to merge"
    echo "  features     Show all features from manifest"
    echo "  help         Show this help"
    echo "  exit         Leave the feature shell"
    echo ""
}

echo "${DIM}Type 'help' for commands, 'status' to see feature info${RESET}"
SHELL_EOF

    exec bash --rcfile "$rcfile"
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 11: Main Entrypoints
# ─────────────────────────────────────────────────────────────────────────────

validate_prerequisites() {
    local -a missing=()

    command -v git    &>/dev/null || missing+=(git)
    command -v claude &>/dev/null || missing+=(claude)
    command -v jq     &>/dev/null || missing+=(jq)

    if [[ ${#ISSUE_NUMBERS[@]} -gt 0 ]]; then
        command -v gh &>/dev/null || missing+=(gh)
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing required tools: ${missing[*]}"
    fi
}

run_worker() {
    # Worker mode: implement a single feature
    trap _worker_exit_handler EXIT
    _timer_start

    resolve_git_root
    RESOLVED_BASE_BRANCH="$BASE_BRANCH"

    local slug="$_FEATURE_SLUG"
    local desc="$_FEATURE_DESC"
    local index="$_FEATURE_INDEX"
    local issue_number="$_ISSUE_NUMBER"
    local issue_json_path="$_ISSUE_JSON"

    _banner "Feature Runner — Worker" "feature/${slug}"

    printf '  %sFeature%s  %s\n' "$DIM" "$RESET" "$desc"
    printf '  %sBranch%s   feature/%s\n' "$DIM" "$RESET" "$slug"
    printf '  %sIndex%s    %s\n' "$DIM" "$RESET" "$index"
    [[ -n "$issue_number" ]] && printf '  %sIssue%s    #%s\n' "$DIM" "$RESET" "$issue_number"

    # Phase 1: Setup
    _section "Setup"

    step "Acquiring lock..."
    acquire_lock "$slug"
    ok "Lock acquired"

    step "Creating worktree..."
    create_worktree "$slug"

    # Phase 2: Environment
    _section "Environment"

    copy_env_files "$WORKTREE_DIR"
    rewrite_ports "$WORKTREE_DIR" "$index" "$PORT_OFFSET"

    # Write issue context if applicable
    local has_issue_context=false
    if [[ -n "$issue_json_path" && -f "$issue_json_path" ]]; then
        local issue_json
        issue_json="$(cat "$issue_json_path")"
        mkdir -p "${WORKTREE_DIR}/.feature-context"
        write_issue_context "$issue_json" "${WORKTREE_DIR}/.feature-context"
        has_issue_context=true
        rm -f "$issue_json_path"
    fi

    # Initialize manifest reference
    MANIFEST_FILE="${WORKTREE_PARENT}/runner-manifest.json"

    # Phase 3: Claude
    _section "Claude Code"

    local prompt
    prompt="$(build_prompt "$desc" "$slug" "$issue_number" "$has_issue_context")"

    local claude_exit=0
    run_claude "$slug" "$prompt" "$WORKTREE_DIR" || claude_exit=$?

    # Phase 4: Results
    _section "Results"

    local elapsed
    elapsed="$(_timer_elapsed)"

    if [[ $claude_exit -eq 0 ]]; then
        manifest_update_status "$slug" "completed" "0"
        echo ""
        printf '  %s%s COMPLETED %s  %s  %s(%s)%s\n' \
            "$BG_GREEN" "$WHITE" "$RESET" "$desc" "$DIM" "$elapsed" "$RESET"
        echo ""
    else
        manifest_update_status "$slug" "failed" "$claude_exit"
        echo ""
        printf '  %s%s FAILED %s  %s  %s(exit %d, %s)%s\n' \
            "$BG_RED" "$WHITE" "$RESET" "$desc" "$DIM" "$claude_exit" "$elapsed" "$RESET"
        echo ""
    fi

    # Drop into interactive shell
    drop_into_shell "$slug" "$WORKTREE_DIR" "$RESOLVED_BASE_BRANCH"
}

run_orchestrator() {
    _timer_start
    _banner "Parallel Feature Runner" "v${VERSION}"

    # Prerequisites
    _section "Prerequisites"
    validate_prerequisites
    ok "All tools available"

    resolve_git_root
    resolve_base_branch

    # Input resolution
    _section "Resolving Features"

    if [[ -n "$FROM_FILE" ]]; then
        step "Reading from file: ${FROM_FILE}"
        read_features_from_file "$FROM_FILE"
        ok "Loaded ${#FEATURES[@]} feature(s) from file"
    fi

    if [[ ${#ISSUE_NUMBERS[@]} -gt 0 ]]; then
        step "Fetching ${#ISSUE_NUMBERS[@]} issue(s) from GitHub..."
        resolve_issues
    fi

    if [[ ${#FEATURES[@]} -eq 0 ]]; then
        fatal "No features specified. Use --features, --from-file, or --issue."
    fi

    echo ""
    printf '  %s%s %d FEATURE(S) %s  ready to implement\n' \
        "$BG_BLUE" "$WHITE" "${#FEATURES[@]}" "$RESET"
    echo ""

    # Configuration summary
    _section "Configuration"
    printf '  %sModel%s        %s\n' "$DIM" "$RESET" "$MODEL"
    printf '  %sMax turns%s    %s\n' "$DIM" "$RESET" "$MAX_TURNS"
    printf '  %sBase branch%s  %s\n' "$DIM" "$RESET" "$RESOLVED_BASE_BRANCH"
    printf '  %sPort offset%s  %s\n' "$DIM" "$RESET" "$PORT_OFFSET"
    printf '  %sWorktree dir%s %s\n' "$DIM" "$RESET" "$WORKTREE_PARENT"
    printf '  %sTeams%s        %s\n' "$DIM" "$RESET" "$([[ "$NO_TEAMS" == true ]] && echo "off (subagents)" || echo "on (4 agents)")"

    # Orchestrate
    orchestrate
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    if [[ "$_SINGLE" == true ]]; then
        run_worker
    else
        run_orchestrator
    fi
}

main "$@"
