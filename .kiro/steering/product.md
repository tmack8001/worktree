# worktree — Product Context

## What this tool is

`worktree` is a shell helper that wraps `git worktree` with sensible defaults, a consistent directory layout, config-driven scaffolding, and optional tmux dev session management. It's available as `w` and `wt` aliases.

The command surface is intentionally minimal: `w <branch>` is the everyday command — it creates the worktree if it doesn't exist, or switches into it if it does.

## Why it exists

Raw `git worktree` is powerful but verbose. Every workflow step requires knowing and typing the full path, manually running setup after creation, and managing tmux sessions by hand. This tool collapses that friction into a single command.

More importantly, it's designed for workflows where **multiple worktrees are active simultaneously** — each branch isolated in its own directory, each with its own installed dependencies, environment config, and running processes.

## The agentic / multi-process use case

This is where the tool earns its keep.

When running multiple AI agents or automated processes in parallel (e.g., several Kiro sessions, CI-style runners, or local agent loops each working on a different feature), `git worktree` is the right primitive: each worktree is a fully isolated working directory sharing one git object store. No stashing, no branch switching, no stepping on each other.

The problem is scaffolding. Each new worktree needs:
- Environment files copied (`.env`, secrets, local config)
- Dependencies installed (`npm install`, `make install`, etc.)
- Services started (dev server, proxy, watcher)

Without automation, a human or agent has to remember and repeat this for every branch. `.worktree.toml` solves this.

### How `.worktree.toml` scaffolds each worktree

Drop a `.worktree.toml` in the repo root. When any process runs `w add <branch>` or `w <branch>`, the matching profile's `setup` commands run automatically in the new worktree directory. The worktree is ready to use immediately, without any manual follow-up.

```toml
base_branch = "main"

[profile.default]
branches = "*"

[[profile.default.setup]]
run = "cp .env.example .env"

[[profile.default.setup]]
run = "npm install"
```

For `worktree dev`, `pre` commands run before tmux windows launch (ensuring deps are current), and `windows` entries define the long-running processes for that branch.

### Profile matching

Profiles match branch names via glob patterns. This means different branch prefixes (`fe/*`, `be/*`, `api/*`) can get different setup routines and dev sessions automatically — no flags or arguments needed.

### Lifecycle summary

| Phase | Trigger | Purpose |
|-------|---------|---------|
| `setup` | `worktree add` (once) | Copy env files, install deps |
| `pre` | `worktree dev` (every time) | Ensure deps current, run build steps |
| `windows` | `worktree dev` | Start long-running processes in tmux |

## Directory layout

Worktrees live at `../<repo>-worktrees/<branch>` relative to the main repo. This keeps the repo root clean and makes the worktree directory easy to discover or pass to other tools:

```
~/dev/
  myapp/                  ← bare or main repo
  myapp-worktrees/
    main/
    fe/login-redesign/
    be/new-api/
    agent-task-123/       ← spun up by an agent, isolated
```

Each directory under `myapp-worktrees/` is fully independent: separate `node_modules`, separate `.env`, separate running processes.

## Multi-repo support

`w ls --all` and `w --all` (fzf picker) scan `~/dev` and sibling directories to show worktrees across all repos. This is useful when managing many parallel workstreams across multiple repositories from a single shell or agent context.

## Key commands for agents

```sh
w <branch>          # create worktree + run setup, or switch if exists
w add <branch>      # explicit create + setup
w dev [<branch>]    # launch tmux session (pre + windows from .worktree.toml)
w rm [<branch>]     # clean up worktree and branch
w ls [--all]        # list active worktrees
w clone <url>       # clone a repo in bare mode, ready for worktree workflows
```

## What to keep in mind when modifying this tool

- **POSIX compatibility**: `w.sh` must work in bash/dash/sh. No zsh-isms (`typeset -A`, `${match[1]}`, etc.). `w.zsh` can use zsh-specific features freely.
- **No side effects on import**: sourcing the file should only define functions and set aliases. No git operations, no filesystem changes.
- **Setup commands run in the worktree root**: `_w_run_setup` `cd`s into `$dest` before `eval`ing each command.
- **Config is optional**: all config-driven paths must degrade gracefully when `.worktree.toml` is absent.
- **The TOML parser is hand-rolled**: it handles the subset of TOML actually used (`[profile.x]`, `[[profile.x.setup]]`, `[[profile.x.windows]]`, string values). Don't assume full TOML compliance.
- **Tests**: `make test` runs both the bats suite (`tests/test-w.bats` for `w.sh`) and the zsh suite (`tests/test-w.zsh` for `w.zsh`). Run both after any change.
