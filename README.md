# runner.sh

Parallel feature runner that spawns isolated Claude Code sessions per feature using git worktrees.

## Setup

`runner.sh` can live anywhere. It does **not** need to be inside your project.

```bash
# Option A: Clone and use directly
git clone git@github.com:Reidmen/runner.git ~/runner
~/runner/runner.sh --features "Add auth"

# Option B: Symlink to your PATH
ln -s ~/runner/runner.sh /usr/local/bin/runner

# Option C: Copy the script anywhere
cp runner.sh ~/bin/runner.sh
```

## Quick Start

**Run from inside any git repository:**

```bash
cd ~/projects/my-app        # must be inside a git repo

# Single feature
runner.sh --features "Add user authentication"

# Multiple parallel features
runner.sh --features "Add auth" "Build REST API" "Add search"

# From GitHub issues
runner.sh --issue 42 --issue 78

# From a file
runner.sh --from-file features.txt

# Mixed: issues + manual features
runner.sh --issue 42 --features "Add rate limiting"
```

Your repo stays untouched. All work happens in `~/.feature_runner/` (configurable with `--dir`):

```
~/projects/my-app/                  ← your repo (nothing changes here)
~/.feature_runner/                  ← worktrees created here
    runner-manifest.json
    feature-add-auth/               ← full checkout on branch feature/add-auth
    feature-build-api/              ← full checkout on branch feature/build-api
```

When done, merge from your repo: `git merge feature/add-auth`

## How It Works

`runner.sh` is a **self-spawning script** -- the same file acts as both **orchestrator** and **worker**. An internal `--_single` flag determines the role.

```
./runner.sh --features "Add auth" "Build API" "Add search"

runner.sh (orchestrator)
  ├── spawns: runner.sh --_single --_feature-slug add-auth ...     → tab 1
  ├── spawns: runner.sh --_single --_feature-slug build-api ...    → tab 2
  └── spawns: runner.sh --_single --_feature-slug add-search ...   → tab 3
```

### Orchestrator

1. **Collect features** from `--features`, `--from-file`, or `--issue` (all three can be mixed)
2. **Slugify** each description into a branch-safe name (`"Add OAuth2 auth"` -> `add-oauth2-auth`)
3. **Validate** all slugs are unique
4. **Initialize manifest** at `~/.feature_runner/runner-manifest.json`
5. **Build child commands** with `printf '%q'` for safe escaping
6. **Detect terminal and spawn**:
   - **iTerm2** -- AppleScript creates named tabs
   - **tmux** -- creates session with one window per feature
   - **background** -- log files + live dashboard

### Worker (one per feature)

1. **Acquire lockfile** (`~/.feature_runner/.lock-feature-<slug>`) with PID-based stale detection
2. **Create git worktree** -- `git worktree add -b feature/<slug>` for full isolation
3. **Copy `.env` files** from the original repo (3-pass scan, skips tracked/large files)
4. **Rewrite ports** -- offsets `PORT=3000` by `index * offset` to prevent collisions
5. **Write issue context** (if `--issue`) -- full body, labels, comments to `.feature-context/ISSUE.md`
6. **Launch Claude Code** with a prompt defining 5 phases:

   | Phase | Artifact |
   |-------|----------|
   | Architecture & Planning | `.feature-context/PLAN.md` |
   | Implementation | Atomic git commits |
   | Testing | `.feature-context/TEST-RESULTS.md` |
   | Integration verification | `.feature-context/INTEGRATION.md` |
   | Summary | `.feature-context/SUMMARY.md` |

   Optionally uses a 4-agent team (architect, implementer, tester, integrator) via `--agents`.

7. **Update manifest** with status (`completed`/`failed`), exit code, timestamp
8. **Drop into interactive shell** with convenience commands (`status`, `diff`, `merge-ready`, etc.)

### File Layout

```
~/.feature_runner/
├── runner-manifest.json                ← tracks all features
├── logs/                               ← background mode only
│   └── add-auth.log
├── feature-add-auth/                   ← git worktree (isolated checkout)
│   ├── .env                            ← copied + port-rewritten
│   └── .feature-context/
│       ├── PLAN.md
│       ├── SUMMARY.md
│       ├── TEST-RESULTS.md
│       ├── INTEGRATION.md
│       ├── ISSUE.md                    ← only in --issue mode
│       └── env-ports-modified.log
└── feature-build-api/                  ← another worktree
    └── ...
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
