# runner.sh

Parallel feature runner that spawns isolated Claude Code sessions per feature using git worktrees.

## Quick Start

```bash
# Single feature
./runner.sh --features "Add user authentication"

# Multiple parallel features
./runner.sh --features "Add auth" "Build REST API" "Add search"

# From GitHub issues
./runner.sh --issue 42 --issue 78

# From a file
./runner.sh --from-file features.txt

# Mixed: issues + manual features
./runner.sh --issue 42 --features "Add rate limiting"
```

## How It Works

```
Orchestrator
├── Parses features (CLI, file, or GitHub issues)
├── Creates isolated git worktrees per feature
├── Rewrites .env ports to avoid conflicts
├── Spawns parallel Claude sessions (iTerm2 tabs / tmux windows / background)
└── Tracks everything in runner-manifest.json

Worker (per feature)
├── Branch: feature/<slug>
├── Copies .env files, offsets ports
├── Claude implements with 5-phase workflow:
│   1. Architecture & Planning → .feature-context/PLAN.md
│   2. Implementation → atomic commits
│   3. Testing → .feature-context/TEST-RESULTS.md
│   4. Integration → .feature-context/INTEGRATION.md
│   5. Summary → .feature-context/SUMMARY.md
└── Drops into interactive shell
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--features <desc...>` | -- | Feature descriptions |
| `--from-file <file>` | -- | One feature per line (`#` comments) |
| `--issue <N>` | -- | GitHub issue number (repeatable) |
| `-r, --repo <owner/repo>` | current | Target repository |
| `-d, --dir <path>` | `~/.feature_runner` | Worktree parent |
| `-m, --model <model>` | `opus` | Claude model |
| `-b, --max-turns <N>` | `75` | Max agentic turns |
| `--base-branch <branch>` | current | Branch to fork from |
| `--port-offset <N>` | `10` | Port increment per feature |
| `--no-port-rewrite` | -- | Skip port rewriting |
| `--tabs <mode>` | `auto` | `auto` / `iterm` / `tmux` / `bg` |
| `-c, --cleanup` | -- | Remove worktree after completion |
| `--no-env-copy` | -- | Skip .env copying |
| `--no-teams` | -- | Use subagents instead of agent teams |

## Port Isolation

Each feature gets offset ports to avoid conflicts:

```
Feature 0 (add-auth):    PORT=3000  API_PORT=8080
Feature 1 (build-api):   PORT=3010  API_PORT=8090
Feature 2 (add-search):  PORT=3020  API_PORT=8100
```

## Post-Session Shell

After Claude finishes, you drop into a shell with these commands:

| Command | Description |
|---------|-------------|
| `status` | Feature info, artifacts, commits |
| `log` | View SUMMARY.md |
| `diff` | Diff from base branch |
| `merge-ready` | Check if ready to merge |
| `features` | All features with status |

## Prerequisites

- `git`, `jq`, `claude` (Claude Code CLI)
- `gh` (GitHub CLI) -- only for `--issue` mode

## Testing

67 tests across 15 groups, pure bash (no external test framework required).

```bash
./test_runner.sh              # Run all 67 tests
./test_runner.sh --verbose    # With detailed output
./test_runner.sh --filter X   # Filter tests by name pattern
```

### Test Coverage

| Group | Tests | What's Covered |
|-------|-------|----------------|
| Slugification | 12 | Basic, special chars, truncation, unicode, uniqueness validation |
| Argument Parsing | 6 | Help, version, unknown flags, no-features error, from-file |
| Issue Slugs | 2 | Format, truncation |
| Git Worktrees | 7 | Resolve root, base branch, create, reuse existing |
| Lockfiles | 4 | Acquire, stale removal, active rejection, release |
| .env Copying | 3 | Basic, disabled, nested directories |
| Port Rewriting | 8 | Offsets, index 0 unchanged, custom offset, disabled, logging |
| Manifest | 6 | Init, idempotent, add, multiple, status updates |
| Terminal Detection | 2 | Explicit modes, env detection |
| Prompt Building | 4 | Basic, with/without issue, team config JSON |
| Issue Context | 1 | Full ISSUE.md generation |
| Safety Patterns | 6 | Strict mode, executable, printf, atomic writes, size guard |
| Child Commands | 2 | Basic, all options |
| End-to-End | 4 | Worktree lifecycle, cleanup, manifest lifecycle, env+port |

### Static Analysis

Passes `shellcheck -S warning` (zero warnings). Run:

```bash
shellcheck -s bash runner.sh
```

## Safety

- `set -euo pipefail` -- strict error handling
- Lockfiles with PID + stale detection -- no duplicate sessions
- Slug collision prevention -- pre-validated before spawning
- EXIT trap -- always cleans lockfiles; cleans worktrees on failure
- `printf '%q'` -- injection-safe command construction
- Atomic manifest writes -- `jq` + tmp + `mv`
- Env file size guard -- 5MB per file
- Base branch validation before worktree creation

## License

MIT
