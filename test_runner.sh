#!/usr/bin/env bash
# test_runner.sh — Comprehensive test suite for runner.sh
#
# Usage:
#   ./test_runner.sh              Run all tests
#   ./test_runner.sh --verbose    Run with verbose output
#   ./test_runner.sh --filter X   Run only tests matching X
#
# Architecture:
#   Pure bash test framework — no external dependencies beyond git, jq.
#   Each test runs in an isolated temp directory with its own git repo.
#   Tests are grouped by section matching runner.sh's architecture.

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Test Framework
# ─────────────────────────────────────────────────────────────────────────────

readonly TEST_SCRIPT="$(cd "$(dirname "$0")" && pwd)/runner.sh"
VERBOSE=false
FILTER=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILURES=()
TEST_TMPDIR=""

# Colors
if [[ -t 1 ]]; then
    T_RED=$'\033[0;31m'
    T_GREEN=$'\033[0;32m'
    T_YELLOW=$'\033[0;33m'
    T_CYAN=$'\033[0;36m'
    T_BOLD=$'\033[1m'
    T_DIM=$'\033[2m'
    T_RESET=$'\033[0m'
else
    T_RED="" T_GREEN="" T_YELLOW="" T_CYAN="" T_BOLD="" T_DIM="" T_RESET=""
fi

_test_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v) VERBOSE=true; shift ;;
            --filter|-f)  shift; FILTER="$1"; shift ;;
            *)            shift ;;
        esac
    done
}

# Create an isolated test environment with a real git repo
_test_setup() {
    TEST_TMPDIR="$(mktemp -d /tmp/runner-test-XXXXXX)"
    mkdir -p "${TEST_TMPDIR}/repo"
    (
        cd "${TEST_TMPDIR}/repo"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "# Test Repo" > README.md
        git add README.md
        git commit -q -m "Initial commit"
    )
    export TEST_REPO="${TEST_TMPDIR}/repo"
    export TEST_WORKTREE_DIR="${TEST_TMPDIR}/worktrees"
    mkdir -p "$TEST_WORKTREE_DIR"
}

_test_teardown() {
    if [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]]; then
        # Clean up any worktrees first to avoid git complaints
        (
            cd "${TEST_REPO}" 2>/dev/null && \
            git worktree list --porcelain 2>/dev/null | grep "^worktree " | \
            while read -r _ wt_path; do
                [[ "$wt_path" == "$TEST_REPO" ]] && continue
                git worktree remove --force "$wt_path" 2>/dev/null || true
            done
        ) 2>/dev/null || true
        rm -rf "$TEST_TMPDIR"
    fi
}

# Source specific functions from runner.sh for unit testing
# This creates a subshell that sources runner.sh's functions without running main()
_source_runner_functions() {
    # We extract functions by sourcing with a modified main
    # - Comment out main call
    # - Replace readonly X="$(cmd)" with X="safe_val" to avoid readonly + sourcing issues
    sed -e 's/^main "\$@"$/# main "$@"/' \
        -e 's/^readonly SCRIPT_NAME=.*/SCRIPT_NAME="runner.sh"/' \
        -e 's/^readonly SCRIPT_PATH=.*/SCRIPT_PATH="\/dev\/null"/' \
        -e 's/^readonly ENV_MAX_SIZE=.*/ENV_MAX_SIZE=$((5 * 1024 * 1024))/' \
        "$TEST_SCRIPT" > "${TEST_TMPDIR}/runner_lib.sh"
    # Pre-set required variables to avoid unbound variable errors
    cat > "${TEST_TMPDIR}/source_helper.sh" <<'HELPER'
#!/usr/bin/env bash
set -uo pipefail
# Pre-initialize arrays and variables that runner.sh expects
FEATURES=()
ISSUE_NUMBERS=()
FROM_FILE=""
REPO=""
WORKTREE_PARENT="/tmp/test-worktrees"
MODEL="opus"
MAX_TURNS=75
BASE_BRANCH=""
PORT_OFFSET=10
NO_PORT_REWRITE=false
TAB_MODE="auto"
CLEANUP=false
NO_ENV_COPY=false
NO_TEAMS=false
_SINGLE=false
_FEATURE_INDEX=""
_FEATURE_DESC=""
_FEATURE_SLUG=""
_ISSUE_NUMBER=""
_ISSUE_JSON=""
GIT_ROOT=""
RESOLVED_BASE_BRANCH=""
WORKTREE_DIR=""
LOCKFILE=""
MANIFEST_FILE=""
_ISSUE_TITLES=()
_ISSUE_JSONS=()
_ISSUE_NUM_LIST=()
HELPER
    cat "${TEST_TMPDIR}/source_helper.sh" "${TEST_TMPDIR}/runner_lib.sh" > "${TEST_TMPDIR}/runner_testable.sh"
}

run_test() {
    local test_name="$1"
    local test_func="$2"

    # Apply filter
    if [[ -n "$FILTER" && ! "$test_name" =~ $FILTER ]]; then
        ((TESTS_SKIPPED++))
        return 0
    fi

    ((TESTS_RUN++))

    _test_setup

    local output exit_code=0
    output="$($test_func 2>&1)" || exit_code=$?

    _test_teardown

    if [[ $exit_code -eq 0 ]]; then
        ((TESTS_PASSED++))
        printf '  %s✓%s %s\n' "$T_GREEN" "$T_RESET" "$test_name"
        if [[ "$VERBOSE" == true && -n "$output" ]]; then
            echo "$output" | sed 's/^/    /'
        fi
    else
        ((TESTS_FAILED++))
        printf '  %s✗%s %s\n' "$T_RED" "$T_RESET" "$test_name"
        FAILURES+=("$test_name")
        echo "$output" | sed 's/^/    /'
    fi
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        echo "ASSERT_EQ FAILED${msg:+: $msg}"
        echo "  expected: '${expected}'"
        echo "  actual:   '${actual}'"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "ASSERT_CONTAINS FAILED${msg:+: $msg}"
        echo "  expected to contain: '${needle}'"
        echo "  in: '${haystack}'"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "ASSERT_NOT_CONTAINS FAILED${msg:+: $msg}"
        echo "  expected NOT to contain: '${needle}'"
        echo "  in: '${haystack}'"
        return 1
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="${2:-}"
    if [[ ! -f "$path" ]]; then
        echo "ASSERT_FILE_EXISTS FAILED${msg:+: $msg}"
        echo "  file not found: '${path}'"
        return 1
    fi
}

assert_dir_exists() {
    local path="$1"
    local msg="${2:-}"
    if [[ ! -d "$path" ]]; then
        echo "ASSERT_DIR_EXISTS FAILED${msg:+: $msg}"
        echo "  directory not found: '${path}'"
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        echo "ASSERT_EXIT_CODE FAILED${msg:+: $msg}"
        echo "  expected exit code: ${expected}"
        echo "  actual exit code:   ${actual}"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 1: Slugification
# ─────────────────────────────────────────────────────────────────────────────

test_slugify_basic() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify 'Add user authentication'")"
    assert_eq "add-user-authentication" "$result" "basic slugify"
}

test_slugify_with_special_chars() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify 'Add OAuth2 & JWT Auth!'")"
    assert_eq "add-oauth2-jwt-auth" "$result" "special chars removed"
}

test_slugify_with_multiple_spaces() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify 'Add   multiple   spaces'")"
    assert_eq "add-multiple-spaces" "$result" "multiple spaces collapsed"
}

test_slugify_truncation() {
    _source_runner_functions
    local long_input="Add a very long feature description that exceeds the maximum allowed slug length of fifty characters"
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify '$long_input'")"
    # Should be <= 50 chars
    local len=${#result}
    if [[ $len -gt 50 ]]; then
        echo "Slug too long: ${len} chars (max 50)"
        echo "Slug: ${result}"
        return 1
    fi
    # Should not end with hyphen
    if [[ "$result" == *- ]]; then
        echo "Slug ends with hyphen: ${result}"
        return 1
    fi
}

test_slugify_leading_trailing_hyphens() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify '---hello world---'")"
    assert_eq "hello-world" "$result" "leading/trailing hyphens trimmed"
}

test_slugify_uppercase() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify 'BUILD REST API'")"
    assert_eq "build-rest-api" "$result" "uppercase converted"
}

test_slugify_numbers() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify 'Add v2 API endpoint 42'")"
    assert_eq "add-v2-api-endpoint-42" "$result" "numbers preserved"
}

test_validate_slugs_unique_pass() {
    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; validate_slugs_unique 'slug-a' 'slug-b' 'slug-c'" 2>&1)" || exit_code=$?
    assert_exit_code "0" "$exit_code" "unique slugs should pass"
}

test_validate_slugs_unique_fail() {
    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; validate_slugs_unique 'slug-a' 'slug-b' 'slug-a'" 2>&1)" || exit_code=$?
    assert_exit_code "1" "$exit_code" "duplicate slugs should fail"
    assert_contains "$result" "Duplicate" "should mention duplicate"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 2: Argument Parsing
# ─────────────────────────────────────────────────────────────────────────────

test_parse_help_flag() {
    local result exit_code=0
    result="$(bash "$TEST_SCRIPT" --help 2>&1)" || exit_code=$?
    assert_exit_code "0" "$exit_code" "help should exit 0"
    assert_contains "$result" "Parallel Feature Runner" "help header"
    assert_contains "$result" "--features" "help shows --features"
    assert_contains "$result" "--issue" "help shows --issue"
    assert_contains "$result" "--from-file" "help shows --from-file"
}

test_parse_version_flag() {
    local result exit_code=0
    result="$(bash "$TEST_SCRIPT" --version 2>&1)" || exit_code=$?
    assert_exit_code "0" "$exit_code" "version should exit 0"
    assert_contains "$result" "runner.sh v" "version output"
}

test_parse_unknown_flag() {
    local result exit_code=0
    result="$(bash "$TEST_SCRIPT" --unknown-flag 2>&1)" || exit_code=$?
    assert_exit_code "1" "$exit_code" "unknown flag should fail"
    assert_contains "$result" "Unknown option" "error message"
}

test_parse_no_features() {
    # Running with no features should fail (after trying to run orchestrator)
    local result exit_code=0
    result="$(cd "$TEST_REPO" && bash "$TEST_SCRIPT" 2>&1)" || exit_code=$?
    assert_exit_code "1" "$exit_code" "no features should fail"
    assert_contains "$result" "No features specified" "error message"
}

test_parse_features_from_file() {
    local feature_file="${TEST_TMPDIR}/features.txt"
    cat > "$feature_file" <<'EOF'
# This is a comment
Add user authentication

Build REST API

# Another comment
Add search functionality
EOF
    _source_runner_functions
    local result
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        FROM_FILE='${feature_file}'
        read_features_from_file '${feature_file}'
        for f in \"\${FEATURES[@]}\"; do echo \"\$f\"; done
    ")"
    local line1 line2 line3
    line1="$(echo "$result" | sed -n '1p')"
    line2="$(echo "$result" | sed -n '2p')"
    line3="$(echo "$result" | sed -n '3p')"
    assert_eq "Add user authentication" "$line1" "first feature"
    assert_eq "Build REST API" "$line2" "second feature"
    assert_eq "Add search functionality" "$line3" "third feature"
}

test_parse_features_file_missing() {
    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; read_features_from_file '/nonexistent/file.txt'" 2>&1)" || exit_code=$?
    assert_exit_code "1" "$exit_code" "missing file should fail"
    assert_contains "$result" "not found" "error message"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 3: Issue Slug Generation
# ─────────────────────────────────────────────────────────────────────────────

test_issue_slug_basic() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; issue_slug 42 'Add user authentication'")"
    assert_eq "issue-42-add-user-authentication" "$result" "issue slug format"
}

test_issue_slug_truncation() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; issue_slug 999 'A very long issue title that should be truncated to fit the slug length limit'")"
    # issue-999- prefix is 10 chars, title slug should be truncated
    assert_contains "$result" "issue-999-" "has issue prefix"
    # Total should be reasonable
    local len=${#result}
    if [[ $len -gt 55 ]]; then
        echo "Issue slug too long: ${len} chars"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 4: Git Worktree Management
# ─────────────────────────────────────────────────────────────────────────────

test_resolve_git_root() {
    _source_runner_functions
    local result
    result="$(bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        resolve_git_root
        echo \"\$GIT_ROOT\"
    ")"
    # Resolve symlinks for macOS /tmp -> /private/tmp
    local expected
    expected="$(cd "$TEST_REPO" && pwd -P)"
    local actual
    actual="$(cd "$result" 2>/dev/null && pwd -P 2>/dev/null || echo "$result")"
    assert_eq "$expected" "$actual" "git root resolved"
}

test_resolve_git_root_not_repo() {
    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "
        cd /tmp
        source '${TEST_TMPDIR}/runner_testable.sh'
        resolve_git_root
    " 2>&1)" || exit_code=$?
    assert_exit_code "1" "$exit_code" "non-repo should fail"
    assert_contains "$result" "Not inside a git repository" "error message"
}

test_resolve_base_branch_current() {
    _source_runner_functions
    local result
    result="$(bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        BASE_BRANCH=''
        resolve_base_branch
        echo \"\$RESOLVED_BASE_BRANCH\"
    " | tail -1)"
    # Should be main or master depending on git config
    if [[ "$result" != "main" && "$result" != "master" ]]; then
        echo "Expected 'main' or 'master', got: '$result'"
        return 1
    fi
}

test_resolve_base_branch_explicit() {
    # Create a branch in the test repo
    (cd "$TEST_REPO" && git checkout -q -b develop && git checkout -q main 2>/dev/null || git checkout -q master)
    _source_runner_functions
    local result
    result="$(bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        BASE_BRANCH='develop'
        resolve_base_branch
        echo \"\$RESOLVED_BASE_BRANCH\"
    " | tail -1)"
    assert_eq "develop" "$result" "explicit base branch"
}

test_resolve_base_branch_nonexistent() {
    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        BASE_BRANCH='nonexistent-branch'
        resolve_base_branch
    " 2>&1)" || exit_code=$?
    assert_exit_code "1" "$exit_code" "nonexistent branch should fail"
    assert_contains "$result" "does not exist" "error message"
}

test_create_worktree() {
    _source_runner_functions
    local main_branch
    main_branch="$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)"

    local result
    result="$(bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        RESOLVED_BASE_BRANCH='${main_branch}'
        create_worktree 'test-feature'
        echo \"\$WORKTREE_DIR\"
    " 2>&1)"

    local wt_dir="${TEST_WORKTREE_DIR}/feature-test-feature"
    assert_dir_exists "$wt_dir" "worktree directory created"

    # Verify it's on the right branch
    local branch
    branch="$(cd "$wt_dir" && git rev-parse --abbrev-ref HEAD)"
    assert_eq "feature/test-feature" "$branch" "correct branch"
}

test_create_worktree_reuse_existing() {
    _source_runner_functions
    local main_branch
    main_branch="$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)"

    # Create worktree first time
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        RESOLVED_BASE_BRANCH='${main_branch}'
        create_worktree 'reuse-test'
    " 2>&1

    # Create again — should reuse
    local result exit_code=0
    result="$(bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        RESOLVED_BASE_BRANCH='${main_branch}'
        create_worktree 'reuse-test'
    " 2>&1)" || exit_code=$?
    assert_exit_code "0" "$exit_code" "reuse should succeed"
    assert_contains "$result" "Reusing existing worktree" "reuse message"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 5: Lockfile Management
# ─────────────────────────────────────────────────────────────────────────────

test_acquire_lock_new() {
    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        acquire_lock 'test-lock'
        echo \"\$LOCKFILE\"
        cat \"\$LOCKFILE\"
    " 2>&1)" || exit_code=$?
    assert_exit_code "0" "$exit_code" "lock acquisition"
    assert_file_exists "${TEST_WORKTREE_DIR}/.lock-feature-test-lock" "lockfile created"
}

test_acquire_lock_stale_removal() {
    # Create a lockfile with a dead PID
    mkdir -p "$TEST_WORKTREE_DIR"
    echo "99999999" > "${TEST_WORKTREE_DIR}/.lock-feature-stale-test"

    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        acquire_lock 'stale-test'
    " 2>&1)" || exit_code=$?
    assert_exit_code "0" "$exit_code" "stale lock should be removed"
    assert_contains "$result" "stale" "stale lockfile warning"
}

test_acquire_lock_active_rejection() {
    # Create a lockfile with current shell's PID (which is alive)
    mkdir -p "$TEST_WORKTREE_DIR"
    echo "$$" > "${TEST_WORKTREE_DIR}/.lock-feature-active-test"

    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        acquire_lock 'active-test'
    " 2>&1)" || exit_code=$?
    assert_exit_code "1" "$exit_code" "active lock should be rejected"
    assert_contains "$result" "already running" "active lock error"
}

test_release_lock() {
    mkdir -p "$TEST_WORKTREE_DIR"
    local lockfile="${TEST_WORKTREE_DIR}/.lock-feature-release-test"
    echo "$$" > "$lockfile"

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        LOCKFILE='${lockfile}'
        release_lock
    " 2>&1

    if [[ -f "$lockfile" ]]; then
        echo "Lockfile still exists after release"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 6: .env Copying
# ─────────────────────────────────────────────────────────────────────────────

test_env_copy_basic() {
    # Create .env files in test repo
    echo "PORT=3000" > "${TEST_REPO}/.env"
    echo "API_KEY=secret" > "${TEST_REPO}/.env.local"

    local target="${TEST_TMPDIR}/target"
    mkdir -p "$target"

    _source_runner_functions
    local result
    result="$(bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        NO_ENV_COPY=false
        copy_env_files '${target}'
    " 2>&1)"

    assert_file_exists "${target}/.env" ".env copied"
    assert_file_exists "${target}/.env.local" ".env.local copied"
}

test_env_copy_skip_when_disabled() {
    echo "PORT=3000" > "${TEST_REPO}/.env"

    local target="${TEST_TMPDIR}/target"
    mkdir -p "$target"

    _source_runner_functions
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        NO_ENV_COPY=true
        copy_env_files '${target}'
    " 2>&1

    if [[ -f "${target}/.env" ]]; then
        echo ".env should NOT have been copied when NO_ENV_COPY=true"
        return 1
    fi
}

test_env_copy_nested() {
    # Create nested .env
    mkdir -p "${TEST_REPO}/packages/api"
    echo "API_PORT=8080" > "${TEST_REPO}/packages/api/.env"

    local target="${TEST_TMPDIR}/target"
    mkdir -p "$target"

    _source_runner_functions
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        NO_ENV_COPY=false
        copy_env_files '${target}'
    " 2>&1

    assert_file_exists "${target}/packages/api/.env" "nested .env copied"
}

test_env_copy_all_variants() {
    # Create every common .env variant
    echo "PORT=3000"        > "${TEST_REPO}/.env"
    echo "LOCAL=true"       > "${TEST_REPO}/.env.local"
    echo "DEV=true"         > "${TEST_REPO}/.env.development"
    echo "TEST=true"        > "${TEST_REPO}/.env.test"
    echo "PROD=true"        > "${TEST_REPO}/.env.production"
    echo "STAGE=true"       > "${TEST_REPO}/.env.staging"
    echo "CI=true"          > "${TEST_REPO}/.env.ci"
    echo "DOCKER=true"      > "${TEST_REPO}/.env.docker"
    # Nested variant
    mkdir -p "${TEST_REPO}/apps/web"
    echo "VITE_PORT=5173"   > "${TEST_REPO}/apps/web/.env.local"

    local target="${TEST_TMPDIR}/target"
    mkdir -p "$target"

    _source_runner_functions
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        NO_ENV_COPY=false
        copy_env_files '${target}'
    " 2>&1

    assert_file_exists "${target}/.env"               ".env copied"
    assert_file_exists "${target}/.env.local"          ".env.local copied"
    assert_file_exists "${target}/.env.development"    ".env.development copied"
    assert_file_exists "${target}/.env.test"           ".env.test copied"
    assert_file_exists "${target}/.env.production"     ".env.production copied"
    assert_file_exists "${target}/.env.staging"        ".env.staging copied"
    assert_file_exists "${target}/.env.ci"             ".env.ci copied"
    assert_file_exists "${target}/.env.docker"         ".env.docker copied"
    assert_file_exists "${target}/apps/web/.env.local" "nested .env.local copied"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 7: Port Rewriting
# ─────────────────────────────────────────────────────────────────────────────

test_port_rewrite_basic() {
    local target="${TEST_TMPDIR}/target"
    mkdir -p "${target}/.feature-context"
    cat > "${target}/.env" <<'EOF'
PORT=3000
API_PORT=8080
VITE_PORT=5173
DATABASE_URL=postgres://localhost:5432/mydb
NOT_A_PORT_VAR=hello
EOF

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        NO_PORT_REWRITE=false
        rewrite_ports '${target}' 1 10
    " 2>&1

    local content
    content="$(cat "${target}/.env")"
    assert_contains "$content" "PORT=3010" "PORT rewritten"
    assert_contains "$content" "API_PORT=8090" "API_PORT rewritten"
    assert_contains "$content" "VITE_PORT=5183" "VITE_PORT rewritten"
    assert_contains "$content" "DATABASE_URL=postgres://localhost:5432/mydb" "non-port preserved"
    assert_contains "$content" "NOT_A_PORT_VAR=hello" "non-port var preserved"
}

test_port_rewrite_index_zero_unchanged() {
    local target="${TEST_TMPDIR}/target"
    mkdir -p "${target}/.feature-context"
    echo "PORT=3000" > "${target}/.env"

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        NO_PORT_REWRITE=false
        rewrite_ports '${target}' 0 10
    " 2>&1

    local content
    content="$(cat "${target}/.env")"
    assert_contains "$content" "PORT=3000" "index 0 keeps original port"
}

test_port_rewrite_index_two() {
    local target="${TEST_TMPDIR}/target"
    mkdir -p "${target}/.feature-context"
    echo "PORT=3000" > "${target}/.env"

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        NO_PORT_REWRITE=false
        rewrite_ports '${target}' 2 10
    " 2>&1

    local content
    content="$(cat "${target}/.env")"
    assert_contains "$content" "PORT=3020" "index 2 gets +20"
}

test_port_rewrite_custom_offset() {
    local target="${TEST_TMPDIR}/target"
    mkdir -p "${target}/.feature-context"
    echo "PORT=3000" > "${target}/.env"

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        NO_PORT_REWRITE=false
        rewrite_ports '${target}' 1 100
    " 2>&1

    local content
    content="$(cat "${target}/.env")"
    assert_contains "$content" "PORT=3100" "custom offset +100"
}

test_port_rewrite_disabled() {
    local target="${TEST_TMPDIR}/target"
    mkdir -p "$target"
    echo "PORT=3000" > "${target}/.env"

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        NO_PORT_REWRITE=true
        rewrite_ports '${target}' 1 10
    " 2>&1

    local content
    content="$(cat "${target}/.env")"
    assert_contains "$content" "PORT=3000" "disabled rewrite keeps original"
}

test_port_rewrite_log_created() {
    local target="${TEST_TMPDIR}/target"
    mkdir -p "${target}/.feature-context"
    echo "PORT=3000" > "${target}/.env"

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        NO_PORT_REWRITE=false
        rewrite_ports '${target}' 1 10
    " 2>&1

    assert_file_exists "${target}/.feature-context/env-ports-modified.log" "log file created"
    local log_content
    log_content="$(cat "${target}/.feature-context/env-ports-modified.log")"
    assert_contains "$log_content" "PORT" "log contains PORT"
    assert_contains "$log_content" "3000" "log contains old port"
    assert_contains "$log_content" "3010" "log contains new port"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 8: Manifest Management
# ─────────────────────────────────────────────────────────────────────────────

test_manifest_init() {
    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        manifest_init
    " 2>&1

    local manifest="${TEST_WORKTREE_DIR}/runner-manifest.json"
    assert_file_exists "$manifest" "manifest created"

    local version
    version="$(jq '.version' "$manifest")"
    assert_eq "1" "$version" "manifest version"

    local features_count
    features_count="$(jq '.features | length' "$manifest")"
    assert_eq "0" "$features_count" "empty features array"
}

test_manifest_init_idempotent() {
    _source_runner_functions
    # Initialize twice
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        manifest_init
        manifest_init
    " 2>&1

    local manifest="${TEST_WORKTREE_DIR}/runner-manifest.json"
    local version
    version="$(jq '.version' "$manifest")"
    assert_eq "1" "$version" "manifest unchanged after second init"
}

test_manifest_add_feature() {
    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        manifest_init
        MANIFEST_FILE='${TEST_WORKTREE_DIR}/runner-manifest.json'
        manifest_add_feature 'add-auth' 'Add user authentication' 'feature/add-auth' \
            '${TEST_WORKTREE_DIR}/feature-add-auth' 0 0 null features
    " 2>&1

    local manifest="${TEST_WORKTREE_DIR}/runner-manifest.json"
    local slug
    slug="$(jq -r '.features[0].slug' "$manifest")"
    assert_eq "add-auth" "$slug" "feature slug"

    local status
    status="$(jq -r '.features[0].status' "$manifest")"
    assert_eq "running" "$status" "initial status is running"

    local source
    source="$(jq -r '.features[0].source' "$manifest")"
    assert_eq "features" "$source" "source is features"
}

test_manifest_add_multiple_features() {
    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        manifest_init
        MANIFEST_FILE='${TEST_WORKTREE_DIR}/runner-manifest.json'
        manifest_add_feature 'add-auth' 'Add auth' 'feature/add-auth' \
            '${TEST_WORKTREE_DIR}/feature-add-auth' 0 0 null features
        manifest_add_feature 'build-api' 'Build API' 'feature/build-api' \
            '${TEST_WORKTREE_DIR}/feature-build-api' 1 10 null features
        manifest_add_feature 'issue-42' 'Fix bug' 'feature/issue-42' \
            '${TEST_WORKTREE_DIR}/feature-issue-42' 2 20 42 issue
    " 2>&1

    local manifest="${TEST_WORKTREE_DIR}/runner-manifest.json"
    local count
    count="$(jq '.features | length' "$manifest")"
    assert_eq "3" "$count" "three features added"

    local issue_num
    issue_num="$(jq '.features[2].issue_number' "$manifest")"
    assert_eq "42" "$issue_num" "issue number stored"
}

test_manifest_update_status_completed() {
    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        manifest_init
        MANIFEST_FILE='${TEST_WORKTREE_DIR}/runner-manifest.json'
        manifest_add_feature 'add-auth' 'Add auth' 'feature/add-auth' \
            '${TEST_WORKTREE_DIR}/feature-add-auth' 0 0 null features
        manifest_update_status 'add-auth' 'completed' 0
    " 2>&1

    local manifest="${TEST_WORKTREE_DIR}/runner-manifest.json"
    local status
    status="$(jq -r '.features[0].status' "$manifest")"
    assert_eq "completed" "$status" "status updated to completed"

    local exit_code
    exit_code="$(jq '.features[0].exit_code' "$manifest")"
    assert_eq "0" "$exit_code" "exit code is 0"

    local completed
    completed="$(jq -r '.features[0].completed' "$manifest")"
    if [[ "$completed" == "null" ]]; then
        echo "completed timestamp should be set"
        return 1
    fi
}

test_manifest_update_status_failed() {
    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        manifest_init
        MANIFEST_FILE='${TEST_WORKTREE_DIR}/runner-manifest.json'
        manifest_add_feature 'add-auth' 'Add auth' 'feature/add-auth' \
            '${TEST_WORKTREE_DIR}/feature-add-auth' 0 0 null features
        manifest_update_status 'add-auth' 'failed' 1
    " 2>&1

    local manifest="${TEST_WORKTREE_DIR}/runner-manifest.json"
    local status
    status="$(jq -r '.features[0].status' "$manifest")"
    assert_eq "failed" "$status" "status updated to failed"

    local exit_code
    exit_code="$(jq '.features[0].exit_code' "$manifest")"
    assert_eq "1" "$exit_code" "exit code is 1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 9: Terminal Detection
# ─────────────────────────────────────────────────────────────────────────────

test_detect_terminal_explicit() {
    _source_runner_functions
    local result

    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        TAB_MODE='tmux'
        detect_terminal
    ")"
    assert_eq "tmux" "$result" "explicit tmux"

    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        TAB_MODE='iterm'
        detect_terminal
    ")"
    assert_eq "iterm" "$result" "explicit iterm"

    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        TAB_MODE='bg'
        detect_terminal
    ")"
    assert_eq "bg" "$result" "explicit bg"
}

test_detect_terminal_iterm_env() {
    _source_runner_functions
    local result
    result="$(bash -c "
        export TERM_PROGRAM='iTerm.app'
        source '${TEST_TMPDIR}/runner_testable.sh'
        TAB_MODE='auto'
        detect_terminal
    ")"
    assert_eq "iterm" "$result" "iTerm detected from TERM_PROGRAM"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 10: Prompt Building
# ─────────────────────────────────────────────────────────────────────────────

test_build_prompt_basic() {
    _source_runner_functions
    local result
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        build_prompt 'Add user authentication' 'add-user-auth' '' false
    ")"
    assert_contains "$result" "Feature Implementation: Add user authentication" "prompt title"
    assert_contains "$result" "feature/add-user-auth" "branch in prompt"
    assert_contains "$result" "Phase 1: Architecture" "phase 1"
    assert_contains "$result" "Phase 2: Implementation" "phase 2"
    assert_contains "$result" "Phase 3: Testing" "phase 3"
    assert_contains "$result" "Phase 4: Integration" "phase 4"
    assert_contains "$result" "Phase 5: Summary" "phase 5"
    assert_contains "$result" ".feature-context/PLAN.md" "plan artifact"
    assert_contains "$result" ".feature-context/SUMMARY.md" "summary artifact"
}

test_build_prompt_with_issue() {
    _source_runner_functions
    local result
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        build_prompt 'Fix authentication bug' 'issue-42-fix-auth' '42' true
    ")"
    assert_contains "$result" "Issue Context" "issue context section"
    assert_contains "$result" "Issue #42" "issue number"
    assert_contains "$result" ".feature-context/ISSUE.md" "issue file reference"
}

test_build_prompt_without_issue() {
    _source_runner_functions
    local result
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        build_prompt 'Add search' 'add-search' '' false
    ")"
    assert_not_contains "$result" "Issue Context" "no issue context section"
}

test_build_team_config_valid_json() {
    _source_runner_functions
    local result
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        build_team_config
    ")"

    # Validate it's valid JSON
    echo "$result" | jq '.' > /dev/null 2>&1
    local exit_code=$?
    assert_exit_code "0" "$exit_code" "team config is valid JSON"

    # Check all 4 agents exist
    local count
    count="$(echo "$result" | jq 'length')"
    assert_eq "4" "$count" "4 agents defined"

    # Check agent names
    local names
    names="$(echo "$result" | jq -r '.[].name' | sort | tr '\n' ',')"
    assert_contains "$names" "architect" "architect agent"
    assert_contains "$names" "implementer" "implementer agent"
    assert_contains "$names" "integrator" "integrator agent"
    assert_contains "$names" "tester" "tester agent"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 11: Issue Context Writing
# ─────────────────────────────────────────────────────────────────────────────

test_write_issue_context() {
    local context_dir="${TEST_TMPDIR}/context"
    mkdir -p "$context_dir"

    local issue_json='{"number":42,"title":"Fix login bug","body":"Users cannot login with OAuth","labels":[{"name":"bug"},{"name":"priority:high"}],"assignees":[{"login":"developer1"}],"comments":[{"author":{"login":"pm1"},"createdAt":"2026-01-15T10:00:00Z","body":"This is blocking the release"}]}'

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        write_issue_context '${issue_json}' '${context_dir}'
    " 2>&1

    assert_file_exists "${context_dir}/ISSUE.md" "ISSUE.md created"

    local content
    content="$(cat "${context_dir}/ISSUE.md")"
    assert_contains "$content" "Issue #42" "issue number"
    assert_contains "$content" "Fix login bug" "issue title"
    assert_contains "$content" "Users cannot login with OAuth" "issue body"
    assert_contains "$content" "bug" "label"
    assert_contains "$content" "developer1" "assignee"
    assert_contains "$content" "blocking the release" "comment body"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 12: Safety Patterns
# ─────────────────────────────────────────────────────────────────────────────

test_strict_mode_set() {
    # Verify the script uses set -euo pipefail
    local header
    header="$(head -20 "$TEST_SCRIPT")"
    assert_contains "$header" "set -euo pipefail" "strict mode enabled"
}

test_script_is_executable() {
    if [[ ! -x "$TEST_SCRIPT" ]]; then
        echo "runner.sh is not executable"
        return 1
    fi
}

test_printf_format_strings() {
    # Verify logging functions use %s format (no backslash interpretation)
    local content
    content="$(cat "$TEST_SCRIPT")"

    # Check that info/ok/warn/error/fatal/step all use printf '%s'
    local func
    for func in info ok warn error fatal step; do
        local line
        line="$(grep "^${func}()" "$TEST_SCRIPT")"
        if [[ -n "$line" ]]; then
            assert_contains "$line" "printf" "${func} uses printf"
        fi
    done
}

test_atomic_manifest_writes() {
    # Verify manifest functions use tmp file + mv pattern
    local content
    content="$(cat "$TEST_SCRIPT")"

    # Check manifest_add_feature uses tmpfile + mv
    assert_contains "$content" 'mv "$tmpfile" "$MANIFEST_FILE"' "atomic write in manifest_add"
}

test_env_size_guard() {
    local content
    content="$(cat "$TEST_SCRIPT")"
    assert_contains "$content" "ENV_MAX_SIZE" "size guard constant"
    assert_contains "$content" "5MB" "5MB limit mentioned"
}

test_child_cmd_uses_printf_q() {
    local content
    content="$(cat "$TEST_SCRIPT")"
    assert_contains "$content" "printf '%q'" "printf %q for safe command construction"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 13: Build Child Command
# ─────────────────────────────────────────────────────────────────────────────

test_build_child_cmd_basic() {
    _source_runner_functions
    # Remove readonly SCRIPT_PATH and re-declare it
    sed -i '' "s/^readonly SCRIPT_PATH=.*/SCRIPT_PATH='\/path\/to\/runner.sh'/" "${TEST_TMPDIR}/runner_testable.sh"
    local result
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='/tmp/worktrees'
        MODEL='opus'
        MAX_TURNS=75
        RESOLVED_BASE_BRANCH='main'
        PORT_OFFSET=10
        NO_PORT_REWRITE=false
        CLEANUP=false
        NO_ENV_COPY=false
        NO_TEAMS=false
        REPO=''
        build_child_cmd 0 'Add auth' 'add-auth' '' ''
    ")"
    assert_contains "$result" "--_single" "single flag"
    assert_contains "$result" "--_feature-index" "feature index"
    assert_contains "$result" "--_feature-desc" "feature desc"
    assert_contains "$result" "--_feature-slug" "feature slug"
    assert_contains "$result" "add-auth" "slug value"
}

test_build_child_cmd_with_options() {
    _source_runner_functions
    # Remove readonly SCRIPT_PATH and re-declare it
    sed -i '' "s/^readonly SCRIPT_PATH=.*/SCRIPT_PATH='\/path\/to\/runner.sh'/" "${TEST_TMPDIR}/runner_testable.sh"
    local result
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='/tmp/worktrees'
        MODEL='sonnet'
        MAX_TURNS=50
        RESOLVED_BASE_BRANCH='develop'
        PORT_OFFSET=20
        NO_PORT_REWRITE=true
        CLEANUP=true
        NO_ENV_COPY=true
        NO_TEAMS=true
        REPO='owner/repo'
        build_child_cmd 2 'Build API' 'build-api' '' ''
    ")"
    assert_contains "$result" "--no-port-rewrite" "no port rewrite flag"
    assert_contains "$result" "--cleanup" "cleanup flag"
    assert_contains "$result" "--no-env-copy" "no env copy flag"
    assert_contains "$result" "--no-teams" "no teams flag"
    assert_contains "$result" "--repo" "repo flag"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 14: Edge Cases
# ─────────────────────────────────────────────────────────────────────────────

test_slugify_empty_string() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify ''")"
    assert_eq "" "$result" "empty string returns empty slug"
}

test_slugify_only_special_chars() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify '!@#\$%^&*()'")"
    assert_eq "" "$result" "only special chars returns empty slug"
}

test_slugify_unicode() {
    _source_runner_functions
    local result
    result="$(bash -c "source '${TEST_TMPDIR}/runner_testable.sh'; slugify 'Add café support'")"
    # Non-ASCII chars get replaced with hyphens
    assert_contains "$result" "add" "starts with add"
    assert_contains "$result" "support" "ends with support"
}

test_port_rewrite_no_env_files() {
    local target="${TEST_TMPDIR}/empty-target"
    mkdir -p "${target}/.feature-context"

    _source_runner_functions
    local result exit_code=0
    result="$(bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        NO_PORT_REWRITE=false
        rewrite_ports '${target}' 1 10
    " 2>&1)" || exit_code=$?
    assert_exit_code "0" "$exit_code" "no env files should not fail"
}

test_port_rewrite_preserves_non_port_lines() {
    local target="${TEST_TMPDIR}/target"
    mkdir -p "${target}/.feature-context"
    cat > "${target}/.env" <<'EOF'
# Configuration
APP_NAME=myapp
PORT=3000
DATABASE_URL=postgres://localhost:5432/db
API_PORT=8080
DEBUG=true
# End
EOF

    _source_runner_functions
    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        NO_PORT_REWRITE=false
        rewrite_ports '${target}' 1 10
    " 2>&1

    local content
    content="$(cat "${target}/.env")"
    assert_contains "$content" "# Configuration" "comment preserved"
    assert_contains "$content" "APP_NAME=myapp" "non-port var preserved"
    assert_contains "$content" "DATABASE_URL=postgres://localhost:5432/db" "URL preserved"
    assert_contains "$content" "DEBUG=true" "boolean preserved"
    assert_contains "$content" "# End" "trailing comment preserved"
    assert_contains "$content" "PORT=3010" "PORT rewritten"
    assert_contains "$content" "API_PORT=8090" "API_PORT rewritten"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Group 15: End-to-End Integration
# ─────────────────────────────────────────────────────────────────────────────

test_e2e_worktree_lifecycle() {
    _source_runner_functions
    local main_branch
    main_branch="$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)"

    # Full lifecycle: create worktree → verify → cleanup
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        RESOLVED_BASE_BRANCH='${main_branch}'
        create_worktree 'lifecycle-test'
    " 2>&1

    local wt_dir="${TEST_WORKTREE_DIR}/feature-lifecycle-test"
    assert_dir_exists "$wt_dir" "worktree created"

    # Verify we can make changes in the worktree
    echo "test file" > "${wt_dir}/test.txt"
    (cd "$wt_dir" && git add test.txt && git commit -q -m "test commit")

    # Cleanup
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        RESOLVED_BASE_BRANCH='${main_branch}'
        cleanup_worktree 'lifecycle-test'
    " 2>&1

    if [[ -d "$wt_dir" ]]; then
        echo "Worktree should be removed after cleanup"
        return 1
    fi

    # Branch should still exist (has commits)
    local branch_exists=0
    git -C "$TEST_REPO" rev-parse --verify "feature/lifecycle-test" &>/dev/null || branch_exists=1
    assert_exit_code "0" "$branch_exists" "branch kept (has commits)"
}

test_e2e_worktree_cleanup_empty_branch() {
    _source_runner_functions
    local main_branch
    main_branch="$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)"

    # Create worktree but don't add commits
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        RESOLVED_BASE_BRANCH='${main_branch}'
        create_worktree 'empty-branch-test'
    " 2>&1

    # Cleanup
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        RESOLVED_BASE_BRANCH='${main_branch}'
        cleanup_worktree 'empty-branch-test'
    " 2>&1

    # Empty branch should be deleted
    local branch_exists=0
    git -C "$TEST_REPO" rev-parse --verify "feature/empty-branch-test" &>/dev/null || branch_exists=1
    assert_exit_code "1" "$branch_exists" "empty branch removed"
}

test_e2e_manifest_lifecycle() {
    _source_runner_functions

    bash -c "
        source '${TEST_TMPDIR}/runner_testable.sh'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        manifest_init
        MANIFEST_FILE='${TEST_WORKTREE_DIR}/runner-manifest.json'

        # Add features
        manifest_add_feature 'feat-a' 'Feature A' 'feature/feat-a' \
            '${TEST_WORKTREE_DIR}/feature-feat-a' 0 0 null features
        manifest_add_feature 'feat-b' 'Feature B' 'feature/feat-b' \
            '${TEST_WORKTREE_DIR}/feature-feat-b' 1 10 null features

        # Complete one, fail the other
        manifest_update_status 'feat-a' 'completed' 0
        manifest_update_status 'feat-b' 'failed' 1
    " 2>&1

    local manifest="${TEST_WORKTREE_DIR}/runner-manifest.json"

    # Verify final state
    local a_status b_status
    a_status="$(jq -r '.features[0].status' "$manifest")"
    b_status="$(jq -r '.features[1].status' "$manifest")"
    assert_eq "completed" "$a_status" "feat-a completed"
    assert_eq "failed" "$b_status" "feat-b failed"

    local a_exit b_exit
    a_exit="$(jq '.features[0].exit_code' "$manifest")"
    b_exit="$(jq '.features[1].exit_code' "$manifest")"
    assert_eq "0" "$a_exit" "feat-a exit 0"
    assert_eq "1" "$b_exit" "feat-b exit 1"
}

test_e2e_env_copy_and_rewrite() {
    # Create .env in test repo
    cat > "${TEST_REPO}/.env" <<'EOF'
PORT=3000
API_PORT=8080
VITE_PORT=5173
SECRET_KEY=abc123
EOF

    _source_runner_functions
    local main_branch
    main_branch="$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)"

    # Create worktree
    bash -c "
        cd '${TEST_REPO}'
        source '${TEST_TMPDIR}/runner_testable.sh'
        GIT_ROOT='${TEST_REPO}'
        WORKTREE_PARENT='${TEST_WORKTREE_DIR}'
        RESOLVED_BASE_BRANCH='${main_branch}'
        NO_ENV_COPY=false
        NO_PORT_REWRITE=false

        create_worktree 'env-test'
        copy_env_files '${TEST_WORKTREE_DIR}/feature-env-test'
        rewrite_ports '${TEST_WORKTREE_DIR}/feature-env-test' 2 10
    " 2>&1

    local env_file="${TEST_WORKTREE_DIR}/feature-env-test/.env"
    assert_file_exists "$env_file" ".env in worktree"

    local content
    content="$(cat "$env_file")"
    assert_contains "$content" "PORT=3020" "PORT offset by 20"
    assert_contains "$content" "API_PORT=8100" "API_PORT offset by 20"
    assert_contains "$content" "VITE_PORT=5193" "VITE_PORT offset by 20"
    assert_contains "$content" "SECRET_KEY=abc123" "non-port preserved"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test Runner
# ─────────────────────────────────────────────────────────────────────────────

run_all_tests() {
    echo ""
    echo "${T_BOLD}╔═══════════════════════════════════════════════════════════╗${T_RESET}"
    echo "${T_BOLD}║       runner.sh — Test Suite v1.0                        ║${T_RESET}"
    echo "${T_BOLD}╚═══════════════════════════════════════════════════════════╝${T_RESET}"
    echo ""

    # Group 1: Slugification
    echo "${T_CYAN}${T_BOLD}Slugification${T_RESET}"
    run_test "slugify: basic description" test_slugify_basic
    run_test "slugify: special characters" test_slugify_with_special_chars
    run_test "slugify: multiple spaces" test_slugify_with_multiple_spaces
    run_test "slugify: truncation at 50 chars" test_slugify_truncation
    run_test "slugify: leading/trailing hyphens" test_slugify_leading_trailing_hyphens
    run_test "slugify: uppercase conversion" test_slugify_uppercase
    run_test "slugify: numbers preserved" test_slugify_numbers
    run_test "slugify: empty string" test_slugify_empty_string
    run_test "slugify: only special chars" test_slugify_only_special_chars
    run_test "slugify: unicode chars" test_slugify_unicode
    run_test "validate: unique slugs pass" test_validate_slugs_unique_pass
    run_test "validate: duplicate slugs fail" test_validate_slugs_unique_fail
    echo ""

    # Group 2: Argument Parsing
    echo "${T_CYAN}${T_BOLD}Argument Parsing${T_RESET}"
    run_test "args: --help flag" test_parse_help_flag
    run_test "args: --version flag" test_parse_version_flag
    run_test "args: unknown flag errors" test_parse_unknown_flag
    run_test "args: no features provided" test_parse_no_features
    run_test "args: --from-file reads features" test_parse_features_from_file
    run_test "args: --from-file missing file" test_parse_features_file_missing
    echo ""

    # Group 3: Issue Slugs
    echo "${T_CYAN}${T_BOLD}Issue Slug Generation${T_RESET}"
    run_test "issue slug: basic format" test_issue_slug_basic
    run_test "issue slug: truncation" test_issue_slug_truncation
    echo ""

    # Group 4: Git Worktree Management
    echo "${T_CYAN}${T_BOLD}Git Worktree Management${T_RESET}"
    run_test "git: resolve root" test_resolve_git_root
    run_test "git: resolve root outside repo" test_resolve_git_root_not_repo
    run_test "git: resolve current branch" test_resolve_base_branch_current
    run_test "git: resolve explicit branch" test_resolve_base_branch_explicit
    run_test "git: resolve nonexistent branch" test_resolve_base_branch_nonexistent
    run_test "git: create worktree" test_create_worktree
    run_test "git: reuse existing worktree" test_create_worktree_reuse_existing
    echo ""

    # Group 5: Lockfile Management
    echo "${T_CYAN}${T_BOLD}Lockfile Management${T_RESET}"
    run_test "lock: acquire new lock" test_acquire_lock_new
    run_test "lock: remove stale lock" test_acquire_lock_stale_removal
    run_test "lock: reject active lock" test_acquire_lock_active_rejection
    run_test "lock: release lock" test_release_lock
    echo ""

    # Group 6: .env Copying
    echo "${T_CYAN}${T_BOLD}.env File Copying${T_RESET}"
    run_test "env: copy basic .env files" test_env_copy_basic
    run_test "env: skip when disabled" test_env_copy_skip_when_disabled
    run_test "env: copy nested .env files" test_env_copy_nested
    run_test "env: copy all .env.* variants" test_env_copy_all_variants
    echo ""

    # Group 7: Port Rewriting
    echo "${T_CYAN}${T_BOLD}Port Rewriting${T_RESET}"
    run_test "ports: basic rewrite (+10)" test_port_rewrite_basic
    run_test "ports: index 0 unchanged" test_port_rewrite_index_zero_unchanged
    run_test "ports: index 2 gets +20" test_port_rewrite_index_two
    run_test "ports: custom offset (+100)" test_port_rewrite_custom_offset
    run_test "ports: disabled preserves original" test_port_rewrite_disabled
    run_test "ports: log file created" test_port_rewrite_log_created
    run_test "ports: no env files doesn't fail" test_port_rewrite_no_env_files
    run_test "ports: preserves non-port lines" test_port_rewrite_preserves_non_port_lines
    echo ""

    # Group 8: Manifest Management
    echo "${T_CYAN}${T_BOLD}Manifest Management${T_RESET}"
    run_test "manifest: initialize" test_manifest_init
    run_test "manifest: idempotent init" test_manifest_init_idempotent
    run_test "manifest: add feature" test_manifest_add_feature
    run_test "manifest: add multiple features" test_manifest_add_multiple_features
    run_test "manifest: update to completed" test_manifest_update_status_completed
    run_test "manifest: update to failed" test_manifest_update_status_failed
    echo ""

    # Group 9: Terminal Detection
    echo "${T_CYAN}${T_BOLD}Terminal Detection${T_RESET}"
    run_test "terminal: explicit mode" test_detect_terminal_explicit
    run_test "terminal: iTerm2 from env" test_detect_terminal_iterm_env
    echo ""

    # Group 10: Prompt Building
    echo "${T_CYAN}${T_BOLD}Prompt Building${T_RESET}"
    run_test "prompt: basic feature prompt" test_build_prompt_basic
    run_test "prompt: with issue context" test_build_prompt_with_issue
    run_test "prompt: without issue context" test_build_prompt_without_issue
    run_test "prompt: team config valid JSON" test_build_team_config_valid_json
    echo ""

    # Group 11: Issue Context
    echo "${T_CYAN}${T_BOLD}Issue Context Writing${T_RESET}"
    run_test "issue: write context file" test_write_issue_context
    echo ""

    # Group 12: Safety Patterns
    echo "${T_CYAN}${T_BOLD}Safety Patterns${T_RESET}"
    run_test "safety: strict mode (set -euo pipefail)" test_strict_mode_set
    run_test "safety: script is executable" test_script_is_executable
    run_test "safety: printf format strings" test_printf_format_strings
    run_test "safety: atomic manifest writes" test_atomic_manifest_writes
    run_test "safety: env size guard" test_env_size_guard
    run_test "safety: printf %q for commands" test_child_cmd_uses_printf_q
    echo ""

    # Group 13: Build Child Command
    echo "${T_CYAN}${T_BOLD}Build Child Command${T_RESET}"
    run_test "child cmd: basic construction" test_build_child_cmd_basic
    run_test "child cmd: with all options" test_build_child_cmd_with_options
    echo ""

    # Group 14: End-to-End Integration
    echo "${T_CYAN}${T_BOLD}End-to-End Integration${T_RESET}"
    run_test "e2e: worktree lifecycle" test_e2e_worktree_lifecycle
    run_test "e2e: cleanup empty branch" test_e2e_worktree_cleanup_empty_branch
    run_test "e2e: manifest lifecycle" test_e2e_manifest_lifecycle
    run_test "e2e: env copy + port rewrite" test_e2e_env_copy_and_rewrite
    echo ""

    # Summary
    echo "${T_BOLD}════════════════════════════════════════════════════════════${T_RESET}"
    printf '  %sTotal:%s %d  ' "$T_BOLD" "$T_RESET" "$TESTS_RUN"
    printf '%sPassed:%s %d  ' "$T_GREEN" "$T_RESET" "$TESTS_PASSED"
    printf '%sFailed:%s %d  ' "$T_RED" "$T_RESET" "$TESTS_FAILED"
    printf '%sSkipped:%s %d\n' "$T_YELLOW" "$T_RESET" "$TESTS_SKIPPED"
    echo "${T_BOLD}════════════════════════════════════════════════════════════${T_RESET}"

    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo ""
        echo "${T_RED}${T_BOLD}Failed tests:${T_RESET}"
        for f in "${FAILURES[@]}"; do
            echo "  ${T_RED}✗${T_RESET} $f"
        done
    fi

    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

_test_parse_args "$@"
run_all_tests
exit $?
