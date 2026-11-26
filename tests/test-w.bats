#!/usr/bin/env bats
# Test suite for w.sh (POSIX sh variant)
# Run: bats tests/test-w.bats
#      make test

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
  export REPO_ROOT
  # The real tmux (if any), captured before a test puts a fake one on PATH,
  # so teardown can always stop the test's private tmux server.
  REAL_TMUX="$(command -v tmux 2>/dev/null || true)"
  export REAL_TMUX
}

setup() {
  # Source in setup so every test subprocess has the functions available
  # shellcheck source=../w.sh
  source "$REPO_ROOT/w.sh"

  TEST_DIR="$(mktemp -d)"
  # Resolve symlinks (macOS /tmp -> /private/tmp) so path comparisons work
  TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
  export TEST_DIR

  git init --bare "$TEST_DIR/remote.git" -q
  git clone       "$TEST_DIR/remote.git" "$TEST_DIR/repo" -q
  git -C "$TEST_DIR/repo" checkout -b main -q
  echo "init"   > "$TEST_DIR/repo/README.md"
  git -C "$TEST_DIR/repo" add README.md
  git -C "$TEST_DIR/repo" commit -qm "initial commit"
  git -C "$TEST_DIR/repo" push -u origin main -q
  git -C "$TEST_DIR/repo" remote set-head origin main

  export REPO="$TEST_DIR/repo"
  export WTS="$TEST_DIR/repo-worktrees"

  # Any tmux a test reaches talks to a private server under TEST_DIR, never
  # the user's (TMUX_TMPDIR picks the socket dir; TMUX would point at the
  # current server, so drop it).
  mkdir -p "$TEST_DIR/tmux"
  export TMUX_TMPDIR="$TEST_DIR/tmux"
  unset TMUX
}

teardown() {
  # Stop the private tmux server, if a test started one: a detached server
  # inherits bats' output pipe and would keep bats waiting forever.
  if [ -n "$REAL_TMUX" ]; then
    TMUX_TMPDIR="$TEST_DIR/tmux" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
  fi
  cd "$BATS_TEST_DIRNAME" || return
  rm -rf "$TEST_DIR"
}

# A PATH directory with only the commands w.sh needs, so `command -v tmux`
# (and fzf) fail even where they are installed next to git.
_path_without_tmux() {
  local bin="$TEST_DIR/no-tmux-bin" c p
  mkdir -p "$bin"
  for c in git mktemp basename dirname cat rm sort awk grep sed tr head cut wc mkdir find cp mv; do
    p="$(command -v "$c")" || continue
    ln -sf "$p" "$bin/$c"
  done
  printf '%s' "$bin"
}

# Output with ANSI colour sequences removed.
_plain() {
  printf '%s' "$1" | sed "s/$(printf '\033')\[[0-9;]*m//g"
}

# ── _w_repo_info ───────────────────────────────────────────────────

@test "_w_repo_info: resolves main repo from repo root" {
  cd "$REPO"
  _w_repo_info
  [ "$W_MAIN_REPO" = "$(pwd -P)" ]
}

@test "_w_repo_info: sets worktrees dir" {
  cd "$REPO"
  _w_repo_info
  [ "$W_WORKTREES_DIR" = "$TEST_DIR/repo-worktrees" ]
}

@test "_w_repo_info: resolves main repo from inside a worktree" {
  git -C "$REPO" worktree add "$WTS/probe" -b probe -q
  cd "$WTS/probe"
  _w_repo_info
  [ "$W_MAIN_REPO" = "$(cd "$REPO" && pwd -P)" ]
}

# ── _w_base_branch ─────────────────────────────────────────────────

@test "_w_base_branch: reads base_branch from .worktree.toml" {
  echo 'base_branch = "develop"' > "$REPO/.worktree.toml"
  result=$(_w_base_branch "$REPO")
  [ "$result" = "develop" ]
}

@test "_w_base_branch: falls back to origin HEAD" {
  result=$(_w_base_branch "$REPO")
  [ "$result" = "main" ]
}

@test "_w_base_branch: toml without base_branch falls back to origin HEAD" {
  printf '[profile.default]\nbranches = "*"\n' > "$REPO/.worktree.toml"
  result=$(_w_base_branch "$REPO")
  [ "$result" = "main" ]
}

# ── _w_repo_name_from_url ──────────────────────────────────────────

@test "_w_repo_name_from_url: ssh url with .git" {
  result=$(_w_repo_name_from_url "git@github.com:org/my-project.git")
  [ "$result" = "my-project" ]
}

@test "_w_repo_name_from_url: https url with .git" {
  result=$(_w_repo_name_from_url "https://github.com/org/my-project.git")
  [ "$result" = "my-project" ]
}

@test "_w_repo_name_from_url: url without .git suffix" {
  result=$(_w_repo_name_from_url "https://github.com/org/my-project")
  [ "$result" = "my-project" ]
}

# ── worktree add ───────────────────────────────────────────────────

@test "w add: creates worktree for new branch" {
  cd "$REPO"
  worktree add test-feature 2>/dev/null
  [ -d "$WTS/test-feature" ]
}

@test "w add: new branch is based on main, not current HEAD" {
  cd "$REPO"
  worktree add diverged 2>/dev/null
  echo "x" >> "$WTS/diverged/README.md"
  git -C "$WTS/diverged" add README.md
  git -C "$WTS/diverged" commit -qm "diverged"

  cd "$WTS/diverged"
  worktree add fresh 2>/dev/null

  main_sha=$(git -C "$REPO" rev-parse main)
  fresh_sha=$(git -C "$WTS/fresh" rev-parse HEAD)
  [ "$fresh_sha" = "$main_sha" ]
}

@test "w add: checks out existing local branch" {
  git -C "$REPO" checkout -b existing -q
  git -C "$REPO" checkout main -q
  cd "$REPO"
  worktree add existing 2>/dev/null
  [ -d "$WTS/existing" ]
}

@test "w add: already exists switches without re-creating" {
  cd "$REPO"
  worktree add dup-branch 2>/dev/null
  run worktree add dup-branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already exists"* ]]
}

@test "w add: no branch prints usage" {
  cd "$REPO"
  run worktree add ""
  [[ "$output" == *"usage:"* ]]
}

@test "w add: slash branches create nested directories" {
  cd "$REPO"
  worktree add fe/deep/nested 2>/dev/null
  [ -d "$WTS/fe/deep/nested" ]
}

@test "w add: runs setup commands when WORKTREE_ALLOW_REPO_COMMANDS=1" {
  cat > "$REPO/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.setup]]
run = "touch .setup-marker"
TOML
  cd "$REPO"
  export WORKTREE_ALLOW_REPO_COMMANDS=1
  worktree add setup-test 2>/dev/null
  [ -f "$WTS/setup-test/.setup-marker" ]
}

# ── repo-command opt-in (setup) ────────────────────────────────────

_write_setup_toml() {
  cat > "$REPO/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.setup]]
run = "touch .setup-marker"

[[profile.default.setup]]
run = "touch .setup-marker-2"
TOML
}

@test "opt-in: setup commands are skipped by default" {
  _write_setup_toml
  unset WORKTREE_ALLOW_REPO_COMMANDS
  cd "$REPO"
  run worktree add gated
  [ "$status" -eq 0 ]
  [ -d "$WTS/gated" ]
  [ ! -e "$WTS/gated/.setup-marker" ]
  [ ! -e "$WTS/gated/.setup-marker-2" ]
  [[ "$output" == *"Not running 2 setup command(s)"* ]]
  [[ "$output" == *"touch .setup-marker"* ]]
  [[ "$output" == *"WORKTREE_ALLOW_REPO_COMMANDS=1"* ]]
}

@test "opt-in: values other than 1 do not enable setup commands" {
  _write_setup_toml
  cd "$REPO"
  i=0
  for v in 0 true yes " 1" "" "11"; do
    i=$((i + 1))
    WORKTREE_ALLOW_REPO_COMMANDS="$v"
    worktree add "gated-$i" >/dev/null 2>&1
    cd "$REPO"
    [ -d "$WTS/gated-$i" ]
  done
  run find "$WTS" -name '.setup-marker*'
  [ -z "$output" ]
}

@test "opt-in: WORKTREE_ALLOW_REPO_COMMANDS=1 runs every setup command" {
  _write_setup_toml
  cd "$REPO"
  export WORKTREE_ALLOW_REPO_COMMANDS=1
  run worktree add allowed
  [ "$status" -eq 0 ]
  [ -f "$WTS/allowed/.setup-marker" ]
  [ -f "$WTS/allowed/.setup-marker-2" ]
  [[ "$output" != *"Not running"* ]]
}

@test "opt-in: no skip notice when the profile has no setup commands" {
  printf '[profile.default]\nbranches = "*"\n' > "$REPO/.worktree.toml"
  cd "$REPO"
  run worktree add nocmds
  [ "$status" -eq 0 ]
  [[ "$output" != *"Not running"* ]]
}

# ── repo-command opt-in (dev: pre + window commands) ───────────────

_fake_tmux() {
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/tmux" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$TEST_DIR/tmux.log"
[ "\$1" = has-session ] && exit 1
exit 0
FAKE
  chmod +x "$TEST_DIR/bin/tmux"
  : > "$TEST_DIR/tmux.log"
}

_write_dev_toml() {
  cat > "$REPO/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.pre]]
run = "touch .pre-marker"

[[profile.default.windows]]
name = "server"
run = "echo window-cmd"
TOML
}

@test "opt-in: w dev skips pre and window commands by default" {
  _write_dev_toml
  _fake_tmux
  cd "$REPO"
  worktree add devgate >/dev/null 2>&1
  unset WORKTREE_ALLOW_REPO_COMMANDS
  PATH="$TEST_DIR/bin:$PATH"
  cd "$WTS/devgate"
  run worktree dev
  [ "$status" -eq 0 ]
  [ ! -e "$WTS/devgate/.pre-marker" ]
  [[ "$output" == *"Not running 1 pre command(s)"* ]]
  [[ "$output" == *"Not running 1 window command(s)"* ]]
  grep -q '^new-window .*-n server' "$TEST_DIR/tmux.log"
  run grep -c 'send-keys' "$TEST_DIR/tmux.log"
  [ "$output" = "0" ]
}

@test "opt-in: w dev runs pre and window commands with WORKTREE_ALLOW_REPO_COMMANDS=1" {
  _write_dev_toml
  _fake_tmux
  cd "$REPO"
  worktree add devallow >/dev/null 2>&1
  export WORKTREE_ALLOW_REPO_COMMANDS=1
  PATH="$TEST_DIR/bin:$PATH"
  cd "$WTS/devallow"
  run worktree dev
  [ "$status" -eq 0 ]
  [ -f "$WTS/devallow/.pre-marker" ]
  [[ "$output" != *"Not running"* ]]
  grep -q 'send-keys .*echo window-cmd Enter' "$TEST_DIR/tmux.log"
}

@test "opt-in: w dev aborts when an allowed pre command fails" {
  cat > "$REPO/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.pre]]
run = "false"
TOML
  _fake_tmux
  cd "$REPO"
  worktree add devfail >/dev/null 2>&1
  export WORKTREE_ALLOW_REPO_COMMANDS=1
  PATH="$TEST_DIR/bin:$PATH"
  cd "$WTS/devfail"
  run worktree dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"aborting session"* ]]
  run grep -c 'new-session' "$TEST_DIR/tmux.log"
  [ "$output" = "0" ]
}

# ── worktree shortcut (w <branch>) ─────────────────────────────────

@test "w <branch>: creates worktree if it doesn't exist" {
  cd "$REPO"
  worktree shortcut-branch 2>/dev/null
  [ -d "$WTS/shortcut-branch" ]
}

@test "w <branch>: switches without re-creating if it exists" {
  cd "$REPO"
  worktree shortcut-branch 2>/dev/null
  cd "$REPO"
  run worktree shortcut-branch
  [[ "$output" != *"Creating worktree"* ]]
}

# ── worktree cd ────────────────────────────────────────────────────

@test "w cd: changes into existing worktree" {
  cd "$REPO"
  worktree add cd-target 2>/dev/null
  cd "$REPO"
  worktree cd cd-target
  [ "$(pwd -P)" = "$(cd "$WTS/cd-target" && pwd -P)" ]
}

@test "w cd: fails for nonexistent worktree" {
  cd "$REPO"
  run worktree cd nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"No worktree"* ]]
}

# ── worktree ls ────────────────────────────────────────────────────

@test "w ls: lists worktrees including branches" {
  cd "$REPO"
  worktree add ls-branch 2>/dev/null
  cd "$REPO"
  run worktree ls
  [[ "$output" == *"ls-branch"* ]]
}

@test "w ls: marks current worktree with ▶" {
  cd "$REPO"
  # run spawns a subshell; pass PWD explicitly so _w_ls_format can compare
  run bash -c "source '$REPO_ROOT/w.sh' && cd '$REPO' && worktree ls"
  [[ "$output" == *"▶"* ]]
}

# ── worktree rm ────────────────────────────────────────────────────

@test "w rm: removes worktree on correct confirmation" {
  cd "$REPO"
  worktree add rm-target 2>/dev/null
  cd "$REPO"
  echo "rm-target" | bash -c "source '$REPO_ROOT/w.sh' && cd '$REPO' && worktree rm rm-target" 2>/dev/null
  [ ! -d "$WTS/rm-target" ]
}

@test "w rm: aborts on wrong confirmation" {
  cd "$REPO"
  worktree add abort-branch 2>/dev/null
  cd "$REPO"
  run bash -c "echo 'wrong' | (source '$REPO_ROOT/w.sh' && cd '$REPO' && worktree rm abort-branch 2>&1)"
  [[ "$output" == *"Aborted"* ]]
  [ -d "$WTS/abort-branch" ]
}

# ── worktree dev ───────────────────────────────────────────────────

@test "w dev: fails without .worktree.toml" {
  cd "$REPO"
  worktree add dev-test 2>/dev/null
  cd "$WTS/dev-test"
  run worktree dev
  [[ "$output" == *"No .worktree.toml"* ]]
}

@test "w dev: fails without tmux when config exists" {
  cat > "$REPO/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.windows]]
name = "shell"
run = "echo hi"
TOML
  cd "$REPO"
  worktree add tmux-test 2>/dev/null
  local nopath
  nopath="$(_path_without_tmux)"
  run bash -c "source '$REPO_ROOT/w.sh' && cd '$WTS/tmux-test' && PATH='$nopath' worktree dev 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tmux not installed"* ]]
  [[ "$output" != *"Starting dev session"* ]]
}

# ── worktree outside a repo ────────────────────────────────────────

@test "w add: errors outside a git repo" {
  cd "$TEST_DIR"
  run worktree add test
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not in a git repository"* ]]
}

@test "w (bare): falls back gracefully outside a git repo" {
  local nopath
  nopath="$(_path_without_tmux)"
  run bash -c "source '$REPO_ROOT/w.sh' && cd '$TEST_DIR' && PATH='$nopath' worktree 2>&1"
  [[ "$output" != *"Not in a git repository"* ]]
  [[ "$output" == *"fzf not installed"* ]]
}

@test "w ls: lists all worktrees when outside a git repo" {
  cd "$REPO"
  worktree add outside-test 2>/dev/null
  cd "$TEST_DIR"
  run worktree ls
  [ "$status" -eq 0 ]
  [[ "$output" != *"Not in a git repository"* ]]
  [[ "$output" != *"fzf not installed"* ]]
}

# ── worktree help ──────────────────────────────────────────────────

# The help tests run from TEST_DIR, which is not a git repository, so they do
# not depend on where bats was started.

@test "w help: shows usage" {
  cd "$TEST_DIR"
  run worktree help
  [ "$status" -eq 0 ]
  local plain
  plain="$(_plain "$output")"
  [[ "$plain" == *"git worktree helper"* ]]
  [[ "$plain" == *"worktree dev"* ]]
  [[ "$plain" == *"worktree clone"* ]]
  [[ "$plain" == *"w, wt"* ]]
}

@test "w add --help: shows subcommand help" {
  cd "$TEST_DIR"
  run worktree add --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Create a new worktree"* ]]
}

@test "w rm --help: shows subcommand help" {
  cd "$TEST_DIR"
  run worktree rm --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remove a worktree"* ]]
}

@test "w dev --help: shows subcommand help" {
  cd "$TEST_DIR"
  run worktree dev --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launch a tmux dev session"* ]]
}

@test "w cd --help: shows subcommand help" {
  cd "$TEST_DIR"
  run worktree cd --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Change directory"* ]]
}

@test "w ls --help: shows subcommand help" {
  cd "$TEST_DIR"
  run worktree ls --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"List worktrees"* ]]
}

@test "help tests: TEST_DIR is not inside a git repository" {
  cd "$TEST_DIR"
  run git rev-parse --git-dir
  [ "$status" -ne 0 ]
}

# ── worktree clone ─────────────────────────────────────────────────

@test "w clone: clones bare repo" {
  cd "$TEST_DIR"
  run worktree clone "$TEST_DIR/remote.git"
  [[ "$output" == *"📦"* ]]
  [[ "$output" == *"Ready"* ]]
  [ -d "$TEST_DIR/remote" ]
}

@test "w clone: creates worktree when branch given" {
  cd "$TEST_DIR"
  run worktree clone "$TEST_DIR/remote.git" fe/feature
  [[ "$output" == *"🌿"* ]]
  [ -d "$TEST_DIR/remote-worktrees/fe/feature" ]
}

@test "w clone: errors when destination already exists" {
  cd "$TEST_DIR"
  worktree clone "$TEST_DIR/remote.git" 2>/dev/null
  run worktree clone "$TEST_DIR/remote.git"
  [[ "$output" == *"already exists"* ]]
}

@test "w clone: no url prints usage" {
  run worktree clone
  [[ "$output" == *"usage:"* ]]
}

@test "w clone --help: shows help" {
  run worktree clone --help
  [[ "$output" == *"Clone a repository"* ]]
}

# ── _w_resolve_pr_url ─────────────────────────────────────────────

@test "_w_resolve_pr_url: returns 1 for plain branch name" {
  run _w_resolve_pr_url "feat/login"
  [ "$status" -eq 1 ]
}

@test "_w_resolve_pr_url: returns 1 for non-github url" {
  run _w_resolve_pr_url "https://gitlab.com/org/repo/merge_requests/42"
  [ "$status" -eq 1 ]
}

@test "_w_resolve_pr_url: returns 1 for empty input" {
  run _w_resolve_pr_url ""
  [ "$status" -eq 1 ]
}

@test "_w_resolve_pr_url: errors when gh not installed" {
  run bash -c "source '$REPO_ROOT/w.sh' && GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url 'https://github.com/org/repo/pull/42' 2>&1"
  [[ "$output" == *"gh CLI not installed"* ]]
}

@test "_w_resolve_pr_url: normalizes /pulls/ to /pull/ in error message" {
  # gh is made unavailable (GITHUB_CMD points nowhere) so we can only confirm the URL is normalised
  # before gh is called (visible in the error output)
  run bash -c "source '$REPO_ROOT/w.sh' && GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url 'https://github.com/org/repo/pulls/42' 2>&1"
  # Returns non-zero (gh not found), but must NOT output /pulls/ in any
  # gh-related message — the URL was already normalised before that call
  [[ "$output" != *"/pulls/"* ]]
}

@test "_w_resolve_pr_url: accepts http:// PR URL" {
  run bash -c "source '$REPO_ROOT/w.sh' && GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url 'http://github.com/org/repo/pull/1' 2>&1"
  # gh not installed, but we get the gh error (not "not a PR URL")
  [[ "$output" == *"gh CLI not installed"* ]]
}

@test "_w_resolve_pr_url: accepts trailing-slash URL" {
  run bash -c "source '$REPO_ROOT/w.sh' && GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url 'https://github.com/org/repo/pull/42/' 2>&1"
  [[ "$output" == *"gh CLI not installed"* ]]
}

@test "_w_resolve_pr_url: rejects url missing PR number" {
  run _w_resolve_pr_url "https://github.com/org/repo/pull/"
  [ "$status" -eq 1 ]
}

# ── w add: remote branch tracking ─────────────────────────────────

@test "w add: tracks remote branch that exists on origin" {
  # Push a branch to the remote so it appears as a remote ref
  git -C "$REPO" checkout -b remote-only -q
  echo "remote" > "$REPO/remote-file.txt"
  git -C "$REPO" add remote-file.txt
  git -C "$REPO" commit -qm "remote branch commit"
  git -C "$REPO" push origin remote-only -q
  git -C "$REPO" checkout main -q
  git -C "$REPO" branch -D remote-only -q

  cd "$REPO"
  worktree add remote-only 2>/dev/null
  [ -d "$WTS/remote-only" ]
  # The worktree should be on the remote-only branch
  branch=$(git -C "$WTS/remote-only" rev-parse --abbrev-ref HEAD)
  [ "$branch" = "remote-only" ]
}

@test "w add: remote branch has upstream tracking set" {
  git -C "$REPO" checkout -b tracked-remote -q
  echo "x" > "$REPO/tracked.txt"
  git -C "$REPO" add tracked.txt
  git -C "$REPO" commit -qm "tracked"
  git -C "$REPO" push origin tracked-remote -q
  git -C "$REPO" checkout main -q
  git -C "$REPO" branch -D tracked-remote -q

  cd "$REPO"
  worktree add tracked-remote 2>/dev/null
  upstream=$(git -C "$WTS/tracked-remote" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  [ "$upstream" = "origin/tracked-remote" ]
}

@test "w add: shows tracking message for remote branch" {
  git -C "$REPO" checkout -b msg-remote -q
  echo "x" > "$REPO/msg.txt"
  git -C "$REPO" add msg.txt
  git -C "$REPO" commit -qm "msg"
  git -C "$REPO" push origin msg-remote -q
  git -C "$REPO" checkout main -q
  git -C "$REPO" branch -D msg-remote -q

  cd "$REPO"
  run worktree add msg-remote
  [[ "$output" == *"tracking origin/msg-remote"* ]]
}

# ── w add PR URL (no gh CLI) ───────────────────────────────────────

@test "w add: PR URL without gh CLI prints error" {
  cd "$REPO"
  GITHUB_CMD=wt-test-no-such-gh run worktree add 'https://github.com/org/repo/pull/1'
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh CLI not installed"* ]]
  # fails closed: no worktree named after the URL
  [ ! -e "$WTS/https:" ]
  run git -C "$REPO" worktree list
  [[ "$output" != *"github.com"* ]]
}

@test "w <pr-url>: PR URL shortcut without gh CLI prints error" {
  cd "$REPO"
  GITHUB_CMD=wt-test-no-such-gh run worktree 'https://github.com/org/repo/pull/1'
  [ "$status" -eq 1 ]
  [ ! -e "$WTS/https:" ]
  [[ "$output" == *"gh CLI not installed"* ]]
}

# ── gh command override (GITHUB_CMD, then GH_CMD, then gh) ─────────

_fake_gh() {
  # _fake_gh <name> <branch-to-print>
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/$1" <<FAKE
#!/bin/sh
printf '%s %s\n' "$1" "\$*" >> "$TEST_DIR/gh.log"
printf '%s' "$2"
FAKE
  chmod +x "$TEST_DIR/bin/$1"
}

_gh_setup() {
  _fake_gh fake-gh-a branch-a
  _fake_gh fake-gh-b branch-b
  _fake_gh gh branch-plain
  : > "$TEST_DIR/gh.log"
  PATH="$TEST_DIR/bin:$PATH"
  unset GITHUB_CMD GH_CMD
}

@test "gh override: GITHUB_CMD wins over GH_CMD" {
  _gh_setup
  GITHUB_CMD=fake-gh-a GH_CMD=fake-gh-b run _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 0 ]
  [ "$output" = "branch-a" ]
  run grep -c '^fake-gh-b' "$TEST_DIR/gh.log"
  [ "$output" = "0" ]
}

@test "gh override: GH_CMD is used when GITHUB_CMD is unset" {
  _gh_setup
  GH_CMD=fake-gh-b run _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 0 ]
  [ "$output" = "branch-b" ]
}

@test "gh override: empty GITHUB_CMD counts as unset" {
  _gh_setup
  GITHUB_CMD='' GH_CMD=fake-gh-b run _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 0 ]
  [ "$output" = "branch-b" ]
}

@test "gh override: falls back to plain gh when neither is set" {
  _gh_setup
  run _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 0 ]
  [ "$output" = "branch-plain" ]
  grep -q '^gh pr view' "$TEST_DIR/gh.log"
}

@test "gh override: empty GITHUB_CMD and GH_CMD fall back to gh" {
  _gh_setup
  GITHUB_CMD='' GH_CMD='' run _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 0 ]
  [ "$output" = "branch-plain" ]
}

@test "gh override: value is a command line split into words" {
  _gh_setup
  GITHUB_CMD="fake-gh-a --profile work" run _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 0 ]
  grep -q '^fake-gh-a --profile work pr view ' "$TEST_DIR/gh.log"
}

@test "gh override: passes the normalised PR URL and an explicit -R owner/repo" {
  _gh_setup
  GITHUB_CMD=fake-gh-a run _w_resolve_pr_url 'https://github.com/acme/widgets/pulls/7/'
  [ "$status" -eq 0 ]
  grep -qF 'fake-gh-a pr view https://github.com/acme/widgets/pull/7 -R acme/widgets --json headRefName' "$TEST_DIR/gh.log"
}

@test "gh override: a missing override command fails closed and is named" {
  _gh_setup
  GITHUB_CMD=wt-test-no-such-gh GH_CMD=fake-gh-b run _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 2 ]
  [[ "$output" == *"wt-test-no-such-gh"* ]]
  [[ "$output" == *"gh CLI not installed"* ]]
  [ ! -s "$TEST_DIR/gh.log" ]
}

@test "gh override: plain gh missing from PATH is reported" {
  mkdir -p "$TEST_DIR/empty-bin"
  run env -i PATH="$TEST_DIR/empty-bin" "$BASH" -c ". '$REPO_ROOT/w.sh'; _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7' 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"gh CLI not installed"* ]]
  [[ "$output" == *"'gh' not found"* ]]
}

@test "gh override: empty output from gh is a resolve failure" {
  _gh_setup
  _fake_gh fake-gh-empty ""
  GITHUB_CMD=fake-gh-empty run _w_resolve_pr_url 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Failed to resolve PR URL"* ]]
}

@test "gh override: w add stops when gh returns no branch" {
  _gh_setup
  _fake_gh fake-gh-empty ""
  cd "$REPO"
  GITHUB_CMD=fake-gh-empty run worktree add 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to resolve PR URL"* ]]
  [ ! -e "$WTS/https:" ]
}

@test "gh override: w add resolves the PR branch through the override" {
  _gh_setup
  cd "$REPO"
  GITHUB_CMD=fake-gh-a run worktree add 'https://github.com/acme/widgets/pull/7'
  [ "$status" -eq 0 ]
  [ -d "$WTS/branch-a" ]
}

# ── _w_resolve_branch_url ─────────────────────────────────────────

@test "_w_resolve_branch_url: extracts simple branch from tree URL" {
  result=$(_w_resolve_branch_url "https://github.com/org/repo/tree/main")
  [ "$result" = "main" ]
}

@test "_w_resolve_branch_url: extracts slash branch from tree URL" {
  result=$(_w_resolve_branch_url "https://github.com/org/repo/tree/feat/my-feature")
  [ "$result" = "feat/my-feature" ]
}

@test "_w_resolve_branch_url: extracts deeply nested branch" {
  result=$(_w_resolve_branch_url "https://github.com/tmack/worktrees/tree/claude/pink-dolphins-7864b7")
  [ "$result" = "claude/pink-dolphins-7864b7" ]
}

@test "_w_resolve_branch_url: strips trailing slash" {
  result=$(_w_resolve_branch_url "https://github.com/org/repo/tree/feat/foo/")
  [ "$result" = "feat/foo" ]
}

@test "_w_resolve_branch_url: accepts http:// tree URL" {
  result=$(_w_resolve_branch_url "http://github.com/org/repo/tree/my-branch")
  [ "$result" = "my-branch" ]
}

@test "_w_resolve_branch_url: returns 1 for plain branch name" {
  run _w_resolve_branch_url "feat/login"
  [ "$status" -eq 1 ]
}

@test "_w_resolve_branch_url: returns 1 for PR URL" {
  run _w_resolve_branch_url "https://github.com/org/repo/pull/42"
  [ "$status" -eq 1 ]
}

@test "_w_resolve_branch_url: returns 1 for non-github URL" {
  run _w_resolve_branch_url "https://gitlab.com/org/repo/tree/main"
  [ "$status" -eq 1 ]
}

@test "_w_resolve_branch_url: returns 1 for tree URL without branch" {
  run _w_resolve_branch_url "https://github.com/org/repo/tree/"
  [ "$status" -eq 1 ]
}

# ── w add branch tree URL ─────────────────────────────────────────

@test "w add: branch tree URL creates worktree for extracted branch" {
  # Push a branch to origin so the worktree can be checked out
  git -C "$REPO" checkout -b tree-url-branch -q
  echo "x" > "$REPO/tree-url.txt"
  git -C "$REPO" add tree-url.txt
  git -C "$REPO" commit -qm "tree url branch"
  git -C "$REPO" push origin tree-url-branch -q
  git -C "$REPO" checkout main -q
  git -C "$REPO" branch -D tree-url-branch -q

  cd "$REPO"
  run worktree add "https://github.com/org/repo/tree/tree-url-branch"
  [ "$status" -eq 0 ]
  [ -d "$WTS/tree-url-branch" ]
}

@test "w add: branch tree URL shows resolved message" {
  git -C "$REPO" checkout -b tree-url-msg -q
  git -C "$REPO" push origin tree-url-msg -q
  git -C "$REPO" checkout main -q
  git -C "$REPO" branch -D tree-url-msg -q

  cd "$REPO"
  run worktree add "https://github.com/org/repo/tree/tree-url-msg"
  [[ "$output" == *"Resolved branch URL"* ]]
}

@test "w <tree-url>: shortcut resolves and creates worktree" {
  git -C "$REPO" checkout -b tree-shortcut -q
  git -C "$REPO" push origin tree-shortcut -q
  git -C "$REPO" checkout main -q
  git -C "$REPO" branch -D tree-shortcut -q

  cd "$REPO"
  run worktree "https://github.com/org/repo/tree/tree-shortcut"
  [ "$status" -eq 0 ]
  [ -d "$WTS/tree-shortcut" ]
}

@test "w add: slash branch tree URL creates nested worktree" {
  git -C "$REPO" checkout -b feat/tree-nested -q
  git -C "$REPO" push origin feat/tree-nested -q
  git -C "$REPO" checkout main -q
  git -C "$REPO" branch -D feat/tree-nested -q

  cd "$REPO"
  worktree add "https://github.com/org/repo/tree/feat/tree-nested" 2>/dev/null
  [ -d "$WTS/feat/tree-nested" ]
}

# ── w add --help updated content ──────────────────────────────────

@test "w add --help: mentions github-pr-url" {
  cd "$TEST_DIR"
  run worktree add --help
  [[ "$output" == *"github-pr-url"* ]]
}

@test "w add --help: mentions github-branch-url" {
  cd "$TEST_DIR"
  run worktree add --help
  [[ "$output" == *"github-branch-url"* ]]
}

@test "w add --help: shows examples section" {
  cd "$TEST_DIR"
  run worktree add --help
  [[ "$output" == *"Examples:"* ]]
}

# ── TOML config parser ─────────────────────────────────────────────

@test "_w_load_config: matches fe/* to frontend profile" {
  cat > "$TEST_DIR/test.toml" <<'TOML'
[profile.frontend]
branches = "fe/*, frontend/*"

[[profile.frontend.setup]]
run = "echo fe"

[profile.default]
branches = "*"

[[profile.default.setup]]
run = "echo default"
TOML
  _w_load_config "$TEST_DIR/test.toml" "fe/my-feature"
  profile=$(head -1 "$W_CFG_DIR/profile")
  setup=$(head -1 "$W_CFG_DIR/setup_cmds")
  [ "$profile" = "frontend" ]
  [ "$setup" = "echo fe" ]
}

@test "_w_load_config: falls back to default profile" {
  cat > "$TEST_DIR/test.toml" <<'TOML'
[profile.frontend]
branches = "fe/*"

[[profile.frontend.setup]]
run = "echo fe"

[profile.default]
branches = "*"

[[profile.default.setup]]
run = "echo default"
TOML
  _w_load_config "$TEST_DIR/test.toml" "random-branch"
  profile=$(head -1 "$W_CFG_DIR/profile")
  setup=$(head -1 "$W_CFG_DIR/setup_cmds")
  [ "$profile" = "default" ]
  [ "$setup" = "echo default" ]
}

@test "_w_load_config: first matching profile wins" {
  cat > "$TEST_DIR/test.toml" <<'TOML'
[profile.specific]
branches = "fe/auth*"

[[profile.specific.setup]]
run = "echo specific"

[profile.broad]
branches = "fe/*"

[[profile.broad.setup]]
run = "echo broad"
TOML
  _w_load_config "$TEST_DIR/test.toml" "fe/auth-fix"
  profile=$(head -1 "$W_CFG_DIR/profile")
  [ "$profile" = "specific" ]
}

@test "_w_load_config: returns 1 when no match and no default" {
  cat > "$TEST_DIR/test.toml" <<'TOML'
[profile.frontend]
branches = "fe/*"

[[profile.frontend.setup]]
run = "echo fe"
TOML
  run _w_load_config "$TEST_DIR/test.toml" "random-branch"
  [ "$status" -eq 1 ]
}

@test "_w_load_config: returns 1 for missing file" {
  run _w_load_config "/nonexistent/.worktree.toml" "anything"
  [ "$status" -eq 1 ]
}

@test "_w_load_config: strips comments and whitespace" {
  cat > "$TEST_DIR/test.toml" <<'TOML'
# comment
base_branch = "develop"  # inline

[profile.default]
branches = "*"

[[profile.default.setup]]
run = "echo hello"
TOML
  _w_load_config "$TEST_DIR/test.toml" "anything"
  profile=$(head -1 "$W_CFG_DIR/profile")
  setup=$(head -1 "$W_CFG_DIR/setup_cmds")
  [ "$profile" = "default" ]
  [ "$setup" = "echo hello" ]
}

# ── dependency bootstrap ───────────────────────────────────────────

@test "w add: clones node_modules into the new worktree" {
  mkdir -p "$REPO/node_modules/pkg"
  echo "module.exports = 1" > "$REPO/node_modules/pkg/index.js"
  cd "$REPO"
  worktree add deps-basic 2>/dev/null
  [ -f "$WTS/deps-basic/node_modules/pkg/index.js" ]
}

@test "w add: clones a nested dep dir at its relative path" {
  mkdir -p "$REPO/frontend/node_modules/pkg"
  echo "x" > "$REPO/frontend/node_modules/pkg/index.js"
  cd "$REPO"
  worktree add deps-nested 2>/dev/null
  [ -f "$WTS/deps-nested/frontend/node_modules/pkg/index.js" ]
}

@test "w add: WORKTREE_NO_DEP_BOOTSTRAP=1 skips the clone" {
  mkdir -p "$REPO/node_modules/pkg"
  echo "x" > "$REPO/node_modules/pkg/index.js"
  ( export WORKTREE_NO_DEP_BOOTSTRAP=1; cd "$REPO"; worktree add deps-off 2>/dev/null )
  [ ! -d "$WTS/deps-off/node_modules" ]
}

@test "w add: WORKTREE_DEP_DIRS overrides the dir list" {
  mkdir -p "$REPO/.venv/bin"
  echo "x" > "$REPO/.venv/bin/activate"
  # node_modules present but NOT in the override list — must be skipped
  mkdir -p "$REPO/node_modules"
  echo "x" > "$REPO/node_modules/marker"
  ( export WORKTREE_DEP_DIRS=".venv"; cd "$REPO"; worktree add deps-override 2>/dev/null )
  [ -f "$WTS/deps-override/.venv/bin/activate" ]
  [ ! -d "$WTS/deps-override/node_modules" ]
}

@test "_w_bootstrap_deps: does not clobber a dep dir already in the worktree" {
  mkdir -p "$REPO/vendor"
  echo "fresh" > "$REPO/vendor/lib"
  dest="$TEST_DIR/preexist"
  mkdir -p "$dest/vendor"
  echo "PREEXISTING" > "$dest/vendor/lib"
  _w_bootstrap_deps "$REPO" "$dest"
  [ "$(cat "$dest/vendor/lib")" = "PREEXISTING" ]
}

@test "_w_bootstrap_deps: bare repo is a no-op" {
  dest="$TEST_DIR/from-bare"
  mkdir -p "$dest"
  _w_bootstrap_deps "$TEST_DIR/remote.git" "$dest"
  [ -z "$(ls -A "$dest")" ]
}

@test "_w_resolve_dep_dirs: top-level replaces defaults, profile extends it" {
  cat > "$REPO/.worktree.toml" <<'TOML'
dep_dirs = "shared_vendor"

[profile.frontend]
branches = "fe/*"
dep_dirs = "frontend/node_modules"
TOML
  result=$(_w_resolve_dep_dirs "$REPO" "fe/x")
  [ "$result" = "shared_vendor frontend/node_modules" ]
}

@test "_w_resolve_dep_dirs: unmatched branch gets the top-level base only" {
  cat > "$REPO/.worktree.toml" <<'TOML'
dep_dirs = "shared_vendor"

[profile.frontend]
branches = "fe/*"
dep_dirs = "frontend/node_modules"

[profile.default]
branches = "*"
TOML
  result=$(_w_resolve_dep_dirs "$REPO" "random-branch")
  [ "$result" = "shared_vendor" ]
}

@test "_w_resolve_dep_dirs: without a top-level, profile extends the built-in defaults" {
  cat > "$REPO/.worktree.toml" <<'TOML'
[profile.frontend]
branches = "fe/*"
dep_dirs = "frontend/node_modules"
TOML
  result=$(_w_resolve_dep_dirs "$REPO" "fe/x")
  [ "$result" = "node_modules vendor frontend/node_modules" ]
}

@test "_w_resolve_dep_dirs: WORKTREE_DEP_DIRS replaces toml + defaults" {
  printf 'dep_dirs = "shared_vendor"\n' > "$REPO/.worktree.toml"
  run env WORKTREE_DEP_DIRS="only_this" bash -c "source '$REPO_ROOT/w.sh'; _w_resolve_dep_dirs '$REPO' main"
  [ "$output" = "only_this" ]
}

@test "w add: top-level dep_dirs replaces built-ins; profile extends the clone" {
  cat > "$REPO/.worktree.toml" <<'TOML'
dep_dirs = "shared_vendor"

[profile.default]
branches = "*"
dep_dirs = "extra_pkgs"
TOML
  mkdir -p "$REPO/node_modules" "$REPO/shared_vendor" "$REPO/extra_pkgs"
  echo x > "$REPO/node_modules/m"
  echo x > "$REPO/shared_vendor/m"
  echo x > "$REPO/extra_pkgs/m"
  cd "$REPO"
  worktree add toml-e2e 2>/dev/null
  [ ! -d "$WTS/toml-e2e/node_modules" ]   # built-in replaced by top-level
  [ -d "$WTS/toml-e2e/shared_vendor" ]    # top-level base
  [ -d "$WTS/toml-e2e/extra_pkgs" ]       # profile extends
}

@test "_w_load_config: parses session override and window fields" {
  cat > "$TEST_DIR/test.toml" <<'TOML'
[profile.frontend]
branches = "fe/*"
session = "my-session"

[[profile.frontend.windows]]
name = "proxy"
dir = "src/tsx"
run = "npm run proxy"

[[profile.frontend.windows]]
name = "fe"
run = "make run-fe"
TOML
  _w_load_config "$TEST_DIR/test.toml" "fe/thing"
  session=$(_w_cfg_get session)
  win1=$(sed -n '1p' "$W_CFG_DIR/window_names")
  win1_dir=$(sed -n '1p' "$W_CFG_DIR/window_dirs")
  win2=$(sed -n '2p' "$W_CFG_DIR/window_names")
  [ "$session" = "my-session" ]
  [ "$win1" = "proxy" ]
  [ "$win1_dir" = "src/tsx" ]
  [ "$win2" = "fe" ]
}
