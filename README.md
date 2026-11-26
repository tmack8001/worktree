# worktree — git worktree helper

A shell function that wraps `git worktree` with sensible defaults, config-driven scaffolding, and tmux dev sessions. Worktrees are created in a sibling directory (`../<repo>-worktrees/<branch>`) to keep your main repo clean.

The command is `worktree`, with `w` and `wt` set up as aliases by default — use whichever fits your muscle memory.

Two variants are available:
- `w.zsh` — full-featured, requires zsh
- `w.sh` — POSIX sh compatible, works with bash, dash, and others

> [!WARNING]
> **Security: `.worktree.toml` is code from the repository.** A committed `.worktree.toml` can contain
> `setup`, `pre` and window `run` commands written by anyone who can push to that repo (or open a PR you check
> out). Since v0.1.1 worktree **does not run them** unless you opt in with `WORKTREE_ALLOW_REPO_COMMANDS=1`;
> without it, the commands are printed and skipped. Only opt in for repos you trust, after reading their
> `.worktree.toml`, and prefer scoping it to one command (`WORKTREE_ALLOW_REPO_COMMANDS=1 w add my-branch`)
> over exporting it in your shell rc. See [Running repo commands](#running-repo-commands-opt-in).
>
> **Installer.** Read `install.sh` before piping it to a shell. It downloads a pinned release (`v0.1.1`), not
> `main`; it never copies files from your current directory (before v0.1.1, `curl ... | sh` run in a directory
> containing a `w.sh`/`w.zsh` installed that file instead).

## Install

### One-liner

```sh
curl -fsSL https://raw.githubusercontent.com/tmack8001/worktree/v0.1.1/install.sh | sh
```

The installer picks the variant from your login shell (`$SHELL`: zsh gets `w.zsh`, anything else `w.sh`) and adds
a source line to your rc file (`~/.zshrc`; `~/.bashrc` or `~/.bash_profile` for bash; `~/.profile` otherwise).

Piped from `curl`, it downloads `w.sh`/`w.zsh` at the pinned release tag. Run from a clone (`./install.sh`), it copies
the files next to `install.sh`. Files in your current directory are never used.

### Options

```sh
./install.sh --zsh              # force zsh variant
./install.sh --sh               # force POSIX sh variant
./install.sh --prefix ~/.bin    # custom install directory
./install.sh --rc ~/.zshrc      # rc file to add the source line to
./install.sh --ref main         # download another ref (tag, branch or commit) instead of the pinned release
./install.sh --remote           # download even when run from a clone
./install.sh --dry-run          # preview without making changes
```

`WORKTREE_REF=<ref>` is equivalent to `--ref`. Tracking `main` means installing unreleased code; prefer a tag.

### Manual

Source the appropriate file in your `.zshrc` / `.bashrc` / `.profile`:

```sh
# zsh
source ~/path/to/w.zsh

# bash / sh
. ~/path/to/w.sh
```

This defines the `worktree` function and sets up `w` and `wt` as aliases. To skip the aliases:

```sh
WORKTREE_NO_ALIASES=1 source ~/path/to/w.zsh
```

Or define your own after sourcing:

```sh
source ~/path/to/w.zsh
unalias wt   # keep only w
```

### Dependencies

- `git` (required)
- `gh` (optional — resolving GitHub PR URLs). worktree runs `${GITHUB_CMD:-${GH_CMD:-gh}}`: `GITHUB_CMD` if set and
  not empty, else `GH_CMD`, else `gh`. The value is a command line split on spaces, so a wrapper such as `ghid`
  can pick the identity; the repo is always passed explicitly as `-R owner/repo`.
- `zsh` or POSIX `sh` / `bash` (required)
- `fzf` (optional — interactive worktree switcher)
- `tmux` (optional — `w dev` sessions)

## Usage

The examples below use `w` (the short alias), but `wt` and `worktree` work identically.

```
worktree                        interactive worktree switcher (fzf, current repo)
worktree --all                  interactive switcher across all repos (fzf)
worktree clone <url> [branch]   clone a repo headless for worktree workflows
worktree add <branch>           create worktree & cd into it
worktree <branch>               cd into worktree if it exists, otherwise create it
worktree rm [<branch>]          remove worktree & delete branch
worktree ls [--all]             list worktrees (--all for all repos)
worktree cd <branch>            cd into existing worktree
worktree dev [<branch>]         launch tmux dev session
worktree help                   show help
```

Every subcommand supports `--help` for detailed usage.

## Quick start

```sh
# From inside any git repo
w fe/login-redesign        # creates worktree, cd's into it
w ls                       # see all worktrees
w fe/login-redesign        # already exists — just cd's into it
w rm fe/login-redesign     # clean up (confirms before deleting)
```

`w <branch>` is the everyday command — it does the right thing whether the worktree exists or not.

### Interactive picker

```sh
w                          # fzf picker for current repo's worktrees
w --all                    # fzf picker across all repos (scans ~/dev, siblings)
```

The fzf display shows entries as `repo-name › branch-name`. When run outside a git repository, `w` and `w ls` automatically fall back to the cross-repo view.

## Starting from scratch with clone

```sh
w clone git@github.com:org/project.git
# creates ./project (bare) and ./project-worktrees/

w clone git@github.com:org/project.git fe/my-feature
# same as above, plus creates a worktree and cd's into it
```

## Base branch

New branches are always based off the repo's development branch, not whatever branch you happen to be on. The base is resolved in order:

1. `base_branch` in `.worktree.toml` (if present)
2. `origin/HEAD` (remote default branch)
3. `main` or `master` (first that exists locally)

## Config-driven scaffolding

Drop a `.worktree.toml` in your repo root to automate post-creation setup and define tmux dev sessions. The file can be committed (team convention) or `.gitignore`d (personal).

Two examples are provided:
- [`examples/worktree.toml.simple`](examples/worktree.toml.simple) — setup commands only, no tmux
- [`examples/worktree.toml.advanced`](examples/worktree.toml.advanced) — per-branch profiles with tmux windows

### Minimal example

```toml
base_branch = "main"

[profile.default]
branches = "*"

[[profile.default.setup]]
run = "cp .env.example .env"

[[profile.default.setup]]
run = "npm install"
```

Setup commands run once when you `worktree add <branch>`, **if you have opted in** (see below).

### Running repo commands (opt-in)

`setup`, `pre` and window `run` commands come from the repository's `.worktree.toml`, so worktree treats them as
untrusted by default: it lists them and skips them. The worktree is still created, dependencies are still
bootstrapped and `worktree dev` still creates the tmux windows (without typing their commands).

To run them, set `WORKTREE_ALLOW_REPO_COMMANDS=1` (exactly `1`; any other value is off):

```sh
WORKTREE_ALLOW_REPO_COMMANDS=1 w add fe/my-feature   # this command only
WORKTREE_ALLOW_REPO_COMMANDS=1 w dev
```

Read the repo's `.worktree.toml` first. Exporting the variable in your rc file turns it on for every repo you
touch, including ones you clone later; a per-repo trust model is planned for 1.0.

### Config lifecycle

| Phase | When it runs | What it's for |
|-------|-------------|---------------|
| `setup` | Once, during `worktree add` (opt-in) | Environment config, initial installs |
| `pre` | Every `worktree dev`, before tmux (opt-in) | Ensure deps are current, build steps. Aborts on failure. |
| `windows` | Every `worktree dev` (commands opt-in) | Long-running processes (dev servers, watchers, proxies) |

### Profile matching

The `branches` field accepts comma-separated glob patterns. First matching profile wins. `[profile.default]` is the fallback.

### tmux sessions

`worktree dev` creates a tmux session with a `shell` window plus whatever windows are defined in the matched profile. If a session already exists, it reattaches.

```sh
w fe/my-feature     # create worktree, run setup
w dev               # launch tmux with defined windows
w dev               # reattaches to existing session
```

## Dependency bootstrap

Installed dependency directories (`node_modules`, `vendor`) are typically `.gitignore`d, so `git worktree add` never populates them — a brand-new worktree can't build or test until they exist. On `w add` (and `w <branch>`), these dirs are **cloned from the main repo into the new worktree** so it's usable immediately.

The clone uses **copy-on-write** where the filesystem supports it (APFS `clonefile` on macOS, reflink on Linux with GNU coreutils), so it's near-instant and shares disk blocks until something writes. It clones rather than symlinks, so a later `npm install` in the worktree can't corrupt the main repo's dependencies. Dep dirs at any depth are handled (e.g. `frontend/node_modules`), and anything already present in the worktree (such as a committed `vendor/`) is left untouched.

If the branch changes its dependencies, a follow-up install (e.g. `npm install`) only fetches the delta — a copied `node_modules` is a fast baseline, not a substitute for install.

### Declaring dep dirs per project

The built-in list (`node_modules`, `vendor`) covers common cases, but a project can declare its own in `.worktree.toml` — committed and shared with the team. A **top-level `dep_dirs` replaces the built-in defaults** and becomes the repo's base set; a matched `[profile.X]` `dep_dirs` then **extends** that base for its branches:

```toml
# base set for every worktree — replaces the built-in node_modules + vendor
dep_dirs = "node_modules packages/shared/node_modules"

[profile.frontend]
branches = "fe/*, ui/*"
dep_dirs = "apps/web/node_modules"     # added on top of the base for fe/* and ui/*

[profile.backend]
branches = "be/*, api/*"
dep_dirs = ".gradle vendor"            # added on top of the base for be/* and api/*
```

Values are space-separated dir names matched at any depth. The base is the top-level `dep_dirs` (or the built-ins if there's no top-level key); a matched profile's `dep_dirs` is unioned onto it and deduplicated. If you set a top-level `dep_dirs`, remember to include `node_modules`/`vendor` there if you still want them, since it replaces the defaults.

| Variable | Effect |
|----------|--------|
| `WORKTREE_NO_DEP_BOOTSTRAP=1` | Disable bootstrapping entirely |
| `WORKTREE_DEP_DIRS="a b c"` | Imperative override — **replaces** the whole computed set (for "exactly these, nothing else") |

The built-in list is limited to *relocatable* dep dirs. Python virtualenvs (`.venv`/`venv`) are **excluded by default** because their `activate` scripts and shebangs hardcode the absolute path and don't survive a move — add them via a `dep_dirs` key or `WORKTREE_DEP_DIRS` only if you know yours tolerates relocation.

## Progress indicators

- 📦 cloning a repo
- 🌿 creating a worktree
- 📋 config profile matched
- 🔧 running setup commands
- ⚙️ running pre-launch commands
- 🚀 starting a tmux dev session
- 🗑️ removing a worktree
- ✅ success / ❌ failure

## Running tests

```sh
make test
```

Or explicitly via

```
bats tests/test-w.bats # BATS suite (w.sh, requires bats-core)
bats tests/test-install.bats # BATS suite (install.sh; fake curl, throwaway HOME)
zsh tests/test-w.zsh   # zsh-specific suite (w.zsh)
```

Install test dependencies with `make deps` (requires Homebrew).

## Demo

![w demo](demo/demo.gif)

To regenerate the GIF after making changes, install [VHS](https://github.com/charmbracelet/vhs) and run from the repo root:

```sh
vhs demo/demo.tape
```

## Alternatives

### Native git worktree ([source](https://git-scm.com/docs/git-worktree))

Typical commands used day to day:

```sh
git worktree list
git worktree add <path> <branch>
```

Focus: no abstraction
Strengths: Built-in, no dependencies
Weakness: Verbose, manual lifecycle management, single repository only


### zsh-git-worktrees ([source](https://github.com/egyptianbman/zsh-git-worktrees))

Typical commands used day to day:

```sh
gwt
gwt <my-feature>
```

Focus: script away friction, not change workflow
Strengths: fast, minimum, tab completetion, shell-native
Weaknesses: no lifecycle management, no workflow abstraction, limited flexibility (forced directory structure)


### worktrunk ([source](https://github.com/max-sixty/worktrunk))

> [!TIP]
> I am increasingly using worktrunk more and more for managing worktrees within a single repository. However, this project (for now) I focused on navigating and managing multiple worktrees across multiple repositories (e.g. `w list --all`), which avoids that limitation. The built in flexibility of worktrunk is by far superior for management and workflow automation/simplification.

Typical commands used day to day:

```sh
wt list
wt list --full
wt switch <feature>
wt switch --execute kiro-cli chat "build <feature>"
```

Focus: general purpose workflow engine with high degrees of configurability
Strengths: rich workflows, async data loading, robust automation hooks, CI/CD integrations
Weaknesses: single repository scope, higher complexity

### git-wt ([source](https://github.com/fingergohappy/git-wt))

Typical commands used day to day:

```
git-wt create <feature>
git-wt list
git-wt remove <feature>
```

Focus: lightweight, opinionated wrapper around git worktree
Strengths: simple, centralized workspace directory
Weaknesses: limited extensibility, minimal automation, single-repository scope


### Comparison

| Tool                | Focus                 | Abstraction Level | Multi-repo | Automation |
| ------------------- | --------------------- | ----------------- | ---------- | ---------- |
| Native git worktree | Raw Git               | Low               | ❌          | ❌          |
| zsh-git-worktrees   | CLI ergonomics        | Low               | ❌          | ❌          |
| git-wt              | Lightweight wrapper   | Medium            | ❌          | ⚠️         |
| worktrunk           | Workflow engine       | High              | ❌          | ✅          |
| **this project**    | Multi-repo navigation | Medium            | ✅          | ⚠️         |


## License

MIT
