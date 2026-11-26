#!/usr/bin/env zsh
# ── Test suite for w.zsh ──────────────────────────────────────────
#
# Creates throwaway git repos in a temp directory, sources w.zsh,
# and exercises each feature. Run with: zsh tests/test-w.zsh
#
# The `w` alias is set up automatically by sourcing w.zsh, so all
# test calls using `w` work without any changes here.
#
# Exit codes: 0 = all passed, 1 = failures

set -uo pipefail

# ── Helpers ────────────────────────────────────────────────────────

PASS=0
FAIL=0
ERRORS=()
RESULTS_FILE=""

_w_test_init() {
  RESULTS_FILE="$TEST_ROOT/.test-results"
  : > "$RESULTS_FILE"
}

pass() {
  (( PASS++ ))
  printf "  ✅ %s\n" "$1"
  echo "PASS" >> "$RESULTS_FILE"
}

fail() {
  (( FAIL++ ))
  ERRORS+=("$1")
  printf "  ❌ %s\n" "$1"
  echo "FAIL:$1" >> "$RESULTS_FILE"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label (expected: '$expected', got: '$actual')"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (output missing: '$needle')"
  fi
}

assert_dir_exists() {
  local label="$1" dir="$2"
  if [[ -d "$dir" ]]; then
    pass "$label"
  else
    fail "$label (directory not found: $dir)"
  fi
}

assert_dir_not_exists() {
  local label="$1" dir="$2"
  if [[ ! -d "$dir" ]]; then
    pass "$label"
  else
    fail "$label (directory should not exist: $dir)"
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label (expected exit $expected, got $actual)"
  fi
}

# ── Test environment setup ─────────────────────────────────────────

TEST_ROOT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/w-test.XXXXXX")" && pwd -P)
SCRIPT_DIR="${0:A:h}"

# Source w.zsh from repo root (one level up from tests/)
source "$SCRIPT_DIR/../w.zsh"

# Init results tracking
RESULTS_FILE="$TEST_ROOT/.test-results"
: > "$RESULTS_FILE"

# Create a bare "remote" and a main repo clone
setup_repo() {
  local name="${1:-test-repo}"
  local bare_dir="$TEST_ROOT/${name}-bare.git"
  local repo_dir="$TEST_ROOT/$name"

  git init --bare "$bare_dir" >/dev/null 2>&1
  git clone "$bare_dir" "$repo_dir" >/dev/null 2>&1

  # Create initial commit on main
  (
    cd "$repo_dir"
    git checkout -b main >/dev/null 2>&1
    echo "init" > README.md
    git add README.md
    git commit -m "initial commit" >/dev/null 2>&1
    git push -u origin main >/dev/null 2>&1
    # Set origin HEAD so _w_base_branch can detect it
    git remote set-head origin main >/dev/null 2>&1
  )

  echo "$repo_dir"
}

# Any tmux a test reaches talks to a private server under TEST_ROOT, never the
# user's (TMUX_TMPDIR picks the socket dir; TMUX would point at the current
# server, so drop it). cleanup stops that server: a detached tmux server keeps
# the caller's output pipe open and would hang `make test | ...`.
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
mkdir -p "$TEST_ROOT/tmux"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
unset TMUX

cleanup() {
  if [[ -n "$REAL_TMUX" ]]; then
    TMUX_TMPDIR="$TEST_ROOT/tmux" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
  fi
  cd / && rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# A PATH directory with only the commands w.zsh needs, so `command -v tmux`
# fails even where tmux is installed next to git.
path_without_tmux() {
  local bin="$TEST_ROOT/no-tmux-bin" c p
  mkdir -p "$bin"
  for c in git mktemp basename dirname cat rm sort awk grep sed tr head cut wc mkdir find cp mv; do
    p=$(command -v "$c") || continue
    ln -sf "$p" "$bin/$c"
  done
  print -r -- "$bin"
}

# ── Test groups ────────────────────────────────────────────────────

test_repo_info() {
  echo "── _w_repo_info ──"
  local repo
  repo=$(setup_repo "repo-info-test")

  # From main repo
  (
    cd "$repo"
    local W_MAIN_REPO W_WORKTREES_DIR
    _w_repo_info
    local resolved_repo=$(cd "$repo" && pwd -P)
    assert_eq "resolves main repo" "$resolved_repo" "$W_MAIN_REPO"
    assert_eq "worktrees dir" "${resolved_repo:h}/repo-info-test-worktrees" "$W_WORKTREES_DIR"
  )

  # From inside a worktree
  (
    cd "$repo"
    git worktree add "$TEST_ROOT/repo-info-test-worktrees/wt-probe" -b wt-probe >/dev/null 2>&1
    cd "$TEST_ROOT/repo-info-test-worktrees/wt-probe"
    local W_MAIN_REPO W_WORKTREES_DIR
    _w_repo_info
    local resolved_repo=$(cd "$repo" && pwd -P)
    assert_eq "resolves main repo from worktree" "$resolved_repo" "$W_MAIN_REPO"
  )
}

test_base_branch() {
  echo "── _w_base_branch ──"

  # With .worktree.toml base_branch
  local repo
  repo=$(setup_repo "base-branch-toml")
  cat > "$repo/.worktree.toml" <<'TOML'
base_branch = "develop"

[profile.default]
branches = "*"
TOML
  local result
  result=$(_w_base_branch "$repo")
  assert_eq "reads base_branch from toml" "develop" "$result"

  # Without toml, falls back to origin HEAD
  local repo2
  repo2=$(setup_repo "base-branch-origin")
  result=$(_w_base_branch "$repo2")
  assert_eq "falls back to origin HEAD (main)" "main" "$result"

  # With toml but no base_branch, falls back to origin HEAD
  local repo3
  repo3=$(setup_repo "base-branch-no-key")
  cat > "$repo3/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"
TOML
  result=$(_w_base_branch "$repo3")
  assert_eq "no base_branch key falls back to origin" "main" "$result"
}

test_add_new_branch() {
  echo "── w add (new branch) ──"
  local repo
  repo=$(setup_repo "add-new")

  (
    cd "$repo"
    local output
    output=$(w add test-feature 2>&1)
    assert_contains "prints creating message" "$output" "Creating worktree"
    assert_dir_exists "worktree created" "$TEST_ROOT/add-new-worktrees/test-feature"

    local base_commit wt_commit
    base_commit=$(git -C "$repo" rev-parse main)
    wt_commit=$(git -C "$TEST_ROOT/add-new-worktrees/test-feature" rev-parse HEAD)
    assert_eq "new branch based on main" "$base_commit" "$wt_commit"
  )
}

test_add_existing_branch() {
  echo "── w add (existing branch) ──"
  local repo
  repo=$(setup_repo "add-existing")

  (
    cd "$repo"
    git checkout -b existing-branch >/dev/null 2>&1
    echo "change" >> README.md
    git add README.md
    git commit -m "on existing" >/dev/null 2>&1
    git checkout main >/dev/null 2>&1

    w add existing-branch >/dev/null 2>&1
    assert_dir_exists "worktree for existing branch" "$TEST_ROOT/add-existing-worktrees/existing-branch"
  )
}

test_add_already_exists() {
  echo "── w add (worktree already exists) ──"
  local repo
  repo=$(setup_repo "add-dup")

  (
    cd "$repo"
    w add dup-branch >/dev/null 2>&1
    local output
    output=$(w add dup-branch 2>&1)
    assert_contains "says already exists" "$output" "Already exists"
  )
}

test_add_no_branch() {
  echo "── w add (no branch given) ──"
  local repo
  repo=$(setup_repo "add-nobranch")

  (
    cd "$repo"
    local output
    output=$(w add "" 2>&1)
    assert_contains "shows usage" "$output" "usage:"
  )
}

test_cd() {
  echo "── w cd ──"
  local repo
  repo=$(setup_repo "cd-test")

  (
    cd "$repo"
    w add cd-target >/dev/null 2>&1
    cd "$repo"  # go back

    w cd cd-target
    local resolved_wt=$(cd "$TEST_ROOT/cd-test-worktrees/cd-target" && pwd -P)
    assert_eq "cd into worktree" "$resolved_wt" "$(pwd -P)"
  )

  # cd to nonexistent
  (
    cd "$repo"
    local output
    output=$(w cd nonexistent 2>&1)
    assert_contains "cd nonexistent fails" "$output" "No worktree"
  )
}

test_ls() {
  echo "── w ls ──"
  local repo
  repo=$(setup_repo "ls-test")

  (
    cd "$repo"
    w add ls-branch >/dev/null 2>&1
    cd "$repo"

    local raw
    raw=$(git -C "$repo" worktree list 2>&1)
    assert_contains "git worktree list shows ls-branch" "$raw" "ls-branch"
    assert_contains "ls marks current worktree" "$(w ls 2>&1)" "▶"
  )
}

test_ls_outside_worktree() {
  echo "── w ls (from outside repo) ──"
  local repo
  repo=$(setup_repo "ls-outside")

  (
    cd "$repo"
    w add ls-outside-branch >/dev/null 2>&1
  )

  # Run from a directory that is NOT a worktree — this triggered the
  # "path: inconsistent type for assignment" error when `local path=`
  # was declared inside the while loop in _w_ls_format.
  (
    cd "$TEST_ROOT"
    local output
    output=$(w ls 2>&1)
    local rc=$?
    assert_exit_code "w ls outside repo exits 0" "0" "$rc"
    if [[ "$output" != *"inconsistent type"* ]]; then
      pass "no zsh type error from _w_ls_format outside repo"
    else
      fail "_w_ls_format produced 'inconsistent type' error outside repo"
    fi
  )

  # Pipe worktree list directly into _w_ls_format from outside a repo
  # to specifically exercise the path variable scoping fix.
  (
    cd "$TEST_ROOT"
    local output
    output=$(git -C "$repo" worktree list | _w_ls_format 2>&1)
    local rc=$?
    assert_exit_code "_w_ls_format pipe exits 0 outside repo" "0" "$rc"
    if [[ "$output" != *"inconsistent type"* ]]; then
      pass "_w_ls_format no type error when piped outside repo"
    else
      fail "_w_ls_format type error when piped outside repo"
    fi
    assert_contains "_w_ls_format shows branch" "$output" "ls-outside-branch"
  )
}

test_rm() {
  echo "── w rm ──"
  local repo
  repo=$(setup_repo "rm-test")

  (
    cd "$repo"
    w add rm-target >/dev/null 2>&1
    assert_dir_exists "worktree exists before rm" "$TEST_ROOT/rm-test-worktrees/rm-target"

    # Simulate confirmation by piping the branch name
    cd "$repo"
    echo "rm-target" | w rm rm-target 2>&1 >/dev/null
    assert_dir_not_exists "worktree removed" "$TEST_ROOT/rm-test-worktrees/rm-target"
  )
}

test_rm_wrong_confirm() {
  echo "── w rm (wrong confirmation) ──"
  local repo
  repo=$(setup_repo "rm-abort")

  (
    cd "$repo"
    w add abort-branch >/dev/null 2>&1
    cd "$repo"
    local output
    output=$(echo "wrong-name" | w rm abort-branch 2>&1)
    assert_contains "aborts on wrong name" "$output" "Aborted"
    assert_dir_exists "worktree still exists" "$TEST_ROOT/rm-abort-worktrees/abort-branch"
  )
}

test_rm_guess_from_worktree() {
  echo "── w rm (no branch: derived from the worktree) ──"
  local repo
  repo=$(setup_repo "rm-guess")
  local wts="$TEST_ROOT/rm-guess-worktrees"

  (
    cd "$repo"
    w add feature/foo >/dev/null 2>&1
    mkdir -p "$wts/feature/foo/sub"
    cd "$wts/feature/foo/sub"
    local output rc
    output=$(echo "feature/foo" | w rm 2>&1); rc=$?
    assert_exit_code "rm in slash-branch worktree succeeds" "0" "$rc"
    assert_contains "rm names the whole slash branch" "$output" "delete branch 'feature/foo'"
    assert_dir_not_exists "slash-branch worktree removed" "$wts/feature/foo"
    if git -C "$repo" show-ref --verify --quiet refs/heads/feature/foo; then
      fail "slash branch deleted"
    else
      pass "slash branch deleted"
    fi
  )

  (
    git -C "$repo" worktree add --detach "$wts/feature/detached" -q
    cd "$wts/feature/detached"
    local output rc
    output=$(echo "feature" | w rm 2>&1); rc=$?
    assert_exit_code "rm with detached HEAD fails" "1" "$rc"
    assert_contains "rm with detached HEAD says so" "$output" "HEAD is detached"
    [[ "$output" != *"Type the name"* ]] && pass "rm with detached HEAD does not prompt" \
      || fail "rm with detached HEAD guessed a branch and prompted"
    assert_dir_exists "detached worktree kept" "$wts/feature/detached"
  )

  (
    local sp="$TEST_ROOT/rm guess spaced"
    git clone -q "$TEST_ROOT/rm-guess-bare.git" "$sp" 2>/dev/null
    cd "$sp"
    w add feature/spaced >/dev/null 2>&1
    cd "$sp-worktrees/feature/spaced"
    local output rc
    output=$(echo "feature/spaced" | w rm 2>&1); rc=$?
    assert_exit_code "rm in a path with spaces succeeds" "0" "$rc"
    assert_dir_not_exists "worktree in a path with spaces removed" "$sp-worktrees/feature/spaced"
  )
}

# An explicit branch is looked up in `git worktree list`, never mapped to
# <worktrees>/<branch>.
test_branch_arg_from_git() {
  echo "── w rm / w dev <branch>: worktree path from git ──"
  local repo
  repo=$(setup_repo "barg")
  local wts="$TEST_ROOT/barg-worktrees"

  (
    cd "$repo"
    git -C "$repo" worktree add -q -b feature/deep "$wts/flat-dir"
    local output rc
    output=$(echo "feature/deep" | w rm feature/deep 2>&1); rc=$?
    assert_exit_code "rm <slash branch> in a differently named dir succeeds" "0" "$rc"
    assert_dir_not_exists "rm removed the dir git has the branch in" "$wts/flat-dir"
    git -C "$repo" show-ref --verify --quiet refs/heads/feature/deep \
      && fail "rm deleted feature/deep" || pass "rm deleted feature/deep"

    # $wts/foo holds branch bar; branch foo lives in $wts/other
    git -C "$repo" worktree add -q -b bar "$wts/foo"
    git -C "$repo" worktree add -q -b foo "$wts/other"
    output=$(echo "foo" | w rm foo 2>&1); rc=$?
    assert_exit_code "rm foo succeeds" "0" "$rc"
    assert_eq "rm foo leaves the dir named foo (branch bar)" "refs/heads/bar" \
      "$(git -C "$wts/foo" symbolic-ref HEAD 2>/dev/null)"
    assert_dir_not_exists "rm foo removes the worktree git has foo in" "$wts/other"

    git -C "$repo" branch lonely
    mkdir -p "$wts/lonely"
    output=$(echo "lonely" | w rm lonely 2>&1); rc=$?
    assert_exit_code "rm of a branch with no worktree fails" "1" "$rc"
    assert_contains "rm says the branch has no worktree" "$output" "No worktree has branch 'lonely' checked out"
    [[ "$output" != *"Type the name"* ]] && pass "rm of a branch with no worktree does not prompt" \
      || fail "rm of a branch with no worktree prompted"
    assert_dir_exists "rm of a branch with no worktree keeps the dir" "$wts/lonely"

    output=$(echo "main" | w rm main 2>&1); rc=$?
    assert_exit_code "rm of the main working tree's branch fails" "1" "$rc"
    assert_contains "rm names the main working tree" "$output" "checked out in the main working tree ($repo)"
    git -C "$repo" show-ref --verify --quiet refs/heads/main \
      && pass "rm keeps main" || fail "rm deleted main"
  )

  cat > "$repo/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"
TOML
  local bin="$TEST_ROOT/barg-bin"
  _zt_fake_tmux "$bin"
  (
    cd "$repo"
    git -C "$repo" worktree add -q -b feature/devdeep "$wts/devflat"
    local output rc
    output=$(PATH="$bin:$PATH" w dev feature/devdeep 2>&1); rc=$?
    assert_exit_code "dev <slash branch> in a differently named dir succeeds" "0" "$rc"
    if grep -q -- "^new-session -d -s barg-feature-devdeep -c $wts/devflat " "$bin/tmux.log"; then
      pass "dev starts in the dir git has the branch in"
    else
      fail "dev did not start in $wts/devflat"
    fi

    : > "$bin/tmux.log"
    git -C "$repo" branch devlonely
    mkdir -p "$wts/devlonely"
    output=$(PATH="$bin:$PATH" w dev devlonely 2>&1); rc=$?
    assert_exit_code "dev of a branch with no worktree fails" "1" "$rc"
    assert_contains "dev says the branch has no worktree" "$output" "No worktree has branch 'devlonely' checked out"
    grep -q 'new-session' "$bin/tmux.log" && fail "dev started a session without a worktree" \
      || pass "dev starts no session without a worktree"
  )
}

test_switch_from_git() {
  echo "── w cd / w <branch> / w add: existing worktree found with git ──"
  local repo
  repo=$(setup_repo "swg")
  local wts="$TEST_ROOT/swg-worktrees"
  git -C "$repo" worktree add -q -b feature/cdflat "$wts/cd-flat"
  git -C "$repo" worktree add -q -b bar "$wts/foo"
  git -C "$repo" worktree add -q -b foo "$wts/other"
  git -C "$repo" branch lonely
  mkdir -p "$wts/lonely"
  git -C "$repo" worktree add -q -b gone "$wts/gone-dir"
  rm -rf "$wts/gone-dir"

  (
    local output rc
    cd "$repo"
    w cd feature/cdflat
    assert_eq "cd <slash branch> goes to the dir git has it in" "$wts/cd-flat" "$PWD"
    cd "$repo"
    w cd foo
    assert_eq "cd foo goes to the worktree with branch foo, not the dir named foo" "$wts/other" "$PWD"
    output=$(w cd main 2>&1); rc=$?
    assert_exit_code "cd main succeeds" "0" "$rc"
    assert_contains "cd main says it is the main working tree" "$output" "checked out in the main working tree"
    w cd main 2>/dev/null
    assert_eq "cd main goes to the main working tree" "$repo" "$PWD"
    output=$(w cd lonely 2>&1); rc=$?
    assert_exit_code "cd to a branch with no worktree fails" "1" "$rc"
    assert_contains "cd says the branch has no worktree" "$output" "No worktree has branch 'lonely' checked out"
    w cd lonely >/dev/null 2>&1
    assert_eq "cd to a branch with no worktree stays put" "$repo" "$PWD"
    output=$(w cd gone 2>&1); rc=$?
    assert_exit_code "cd to a pruned-away worktree fails" "1" "$rc"
    assert_contains "cd names the unusable worktree" "$output" \
      "git lists branch 'gone' as checked out in $wts/gone-dir, which is not a usable worktree"
  )

  git -C "$repo" worktree add -q -b feature/goflat "$wts/go-flat"
  git -C "$repo" branch feature/fresh
  (
    local output rc
    cd "$repo"
    output=$(w feature/goflat 2>&1); rc=$?
    assert_exit_code "w <branch> elsewhere succeeds" "0" "$rc"
    [[ "$output" != *"Creating worktree"* ]] && pass "w <branch> elsewhere creates nothing" \
      || fail "w <branch> elsewhere created a worktree"
    assert_dir_not_exists "w <branch> elsewhere makes no <worktrees>/<branch>" "$wts/feature/goflat"
    w feature/goflat >/dev/null 2>&1
    assert_eq "w <branch> goes to the dir git has it in" "$wts/go-flat" "$PWD"

    cd "$wts/go-flat"
    output=$(w main 2>&1); rc=$?
    assert_exit_code "w main succeeds" "0" "$rc"
    [[ "$output" != *"Creating worktree"* && "$output" != *fatal* ]] && pass "w main creates nothing" \
      || fail "w main tried to create a worktree: $output"
    assert_dir_not_exists "w main makes no <worktrees>/main" "$wts/main"
    w main >/dev/null 2>&1
    assert_eq "w main goes to the main working tree" "$repo" "$PWD"

    w feature/fresh >/dev/null 2>&1
    assert_eq "w <branch with no worktree> creates <worktrees>/<branch>" "$wts/feature/fresh" "$PWD"

    cd "$repo"
    output=$(w add feature/goflat 2>&1); rc=$?
    assert_exit_code "add of a branch checked out elsewhere succeeds" "0" "$rc"
    assert_contains "add says it already exists" "$output" "Already exists"
    w add feature/goflat >/dev/null 2>&1
    assert_eq "add switches to the dir git has it in" "$wts/go-flat" "$PWD"

    output=$(w add main 2>&1); rc=$?
    assert_exit_code "add main succeeds" "0" "$rc"
    [[ "$output" != *fatal* ]] && pass "add main does not fail in git" || fail "add main: $output"
    assert_dir_not_exists "add main makes no <worktrees>/main" "$wts/main"

    cd "$repo"
    git -C "$repo" worktree remove "$wts/other"
    output=$(w add foo 2>&1); rc=$?
    assert_exit_code "add foo with \$wts/foo holding bar fails" "1" "$rc"
    assert_contains "add foo says the dir is taken" "$output" \
      "$wts/foo already exists but does not have branch 'foo' checked out"
    assert_eq "add foo leaves bar's worktree alone" "refs/heads/bar" "$(git -C "$wts/foo" symbolic-ref HEAD)"
    w add foo >/dev/null 2>&1
    assert_eq "add foo stays put" "$repo" "$PWD"
  )
}

test_dev_guess_from_worktree() {
  echo "── w dev (no branch: derived from the worktree) ──"
  local repo
  repo=$(setup_repo "dev-guess")
  local wts="$TEST_ROOT/dev-guess-worktrees"
  cat > "$repo/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"
TOML
  local bin="$TEST_ROOT/dev-guess-bin"
  _zt_fake_tmux "$bin"

  (
    cd "$repo"
    w add feature/devslash >/dev/null 2>&1
    cd "$wts/feature/devslash"
    local output rc
    output=$(PATH="$bin:$PATH" w dev 2>&1); rc=$?
    assert_exit_code "dev in slash-branch worktree succeeds" "0" "$rc"
    if grep -q -- '-s dev-guess-feature-devslash ' "$bin/tmux.log"; then
      pass "dev session named after the whole slash branch"
    else
      fail "dev session not named after the whole slash branch"
    fi

    : > "$bin/tmux.log"
    git -C "$repo" worktree add --detach "$wts/feature/devdetached" -q
    cd "$wts/feature/devdetached"
    output=$(PATH="$bin:$PATH" w dev 2>&1); rc=$?
    assert_exit_code "dev with detached HEAD fails" "1" "$rc"
    assert_contains "dev with detached HEAD says so" "$output" "HEAD is detached"
    if grep -q 'new-session' "$bin/tmux.log"; then
      fail "dev with detached HEAD started a session"
    else
      pass "dev with detached HEAD starts no session"
    fi
  )
}

test_help() {
  echo "── w help ──"
  local output
  output=$(w help 2>&1)
  assert_contains "help shows usage" "$output" "git worktree helper"
  assert_contains "help shows name" "$output" "worktree — git worktree helper (aliases: w, wt)"
  assert_contains "help shows config" "$output" ".worktree.toml"
  assert_contains "help shows aliases" "$output" "are set up by default."
}

test_subcommand_help() {
  echo "── subcommand --help ──"
  local repo
  repo=$(setup_repo "help-test")

  (
    cd "$repo"
    local output

    output=$(w add --help 2>&1)
    assert_contains "add --help" "$output" "Create a new worktree"

    output=$(w rm --help 2>&1)
    assert_contains "rm --help" "$output" "Remove a worktree"

    output=$(w cd --help 2>&1)
    assert_contains "cd --help" "$output" "Change directory"

    output=$(w ls --help 2>&1)
    assert_contains "ls --help" "$output" "List worktrees"

    output=$(w dev --help 2>&1)
    assert_contains "dev --help" "$output" "Launch a tmux dev session"
  )

  # The same help outside any git repository (TEST_ROOT is not one).
  (
    cd "$TEST_ROOT"
    local output
    if git rev-parse --git-dir >/dev/null 2>&1; then
      fail "TEST_ROOT is inside a git repository"
    fi
    for sub in add rm cd ls dev; do
      output=$(w "$sub" --help 2>&1)
      if [[ "$output" == *"Not in a git repository"* || "$output" != *[Uu]sage* ]]; then
        fail "$sub --help outside a repo (got: $output)"
      else
        pass "$sub --help outside a repo"
      fi
    done
  )
}

test_load_config_profile_matching() {
  echo "── _w_load_config (profile matching) ──"
  local repo
  repo=$(setup_repo "config-match")

  cat > "$repo/.worktree.toml" <<'TOML'
base_branch = "main"

[profile.frontend]
branches = "fe/*, frontend/*, ui/*"
session = "my-fe-session"

[[profile.frontend.setup]]
run = "echo setup-fe"

[[profile.frontend.pre]]
run = "echo pre-fe"

[[profile.frontend.windows]]
name = "proxy"
dir = "src/tsx"
run = "npm run proxy"

[[profile.frontend.windows]]
name = "fe"
run = "make run-fe"

[profile.backend]
branches = "be/*, backend/*, api/*"

[[profile.backend.setup]]
run = "echo setup-be"

[[profile.backend.windows]]
name = "server"
run = "make run"

[profile.default]
branches = "*"

[[profile.default.setup]]
run = "echo setup-default"

[[profile.default.windows]]
name = "shell"
run = "echo default-shell"
TOML

  # Short-form frontend match
  _w_load_config "$repo/.worktree.toml" "fe/my-feature"
  assert_eq "fe/* matches frontend" "frontend" "${W_PROFILE[name]}"
  assert_eq "frontend session override" "my-fe-session" "${W_PROFILE[session]}"
  assert_eq "frontend setup cmd" "echo setup-fe" "${W_SETUP_CMDS[1]}"
  assert_eq "frontend pre cmd" "echo pre-fe" "${W_PRE_CMDS[1]}"
  assert_eq "frontend window count" "2" "${#W_WINDOW_NAMES[@]}"
  assert_eq "frontend window 1 name" "proxy" "${W_WINDOW_NAMES[1]}"
  assert_eq "frontend window 1 dir" "src/tsx" "${W_WINDOW_DIRS[1]}"
  assert_eq "frontend window 1 cmd" "npm run proxy" "${W_WINDOW_CMDS[1]}"
  assert_eq "frontend window 2 name" "fe" "${W_WINDOW_NAMES[2]}"
  assert_eq "frontend window 2 cmd" "make run-fe" "${W_WINDOW_CMDS[2]}"

  # Long-form frontend match
  _w_load_config "$repo/.worktree.toml" "frontend/redesign"
  assert_eq "frontend/* matches frontend" "frontend" "${W_PROFILE[name]}"

  # ui/* frontend match
  _w_load_config "$repo/.worktree.toml" "ui/button-fix"
  assert_eq "ui/* matches frontend" "frontend" "${W_PROFILE[name]}"

  # Short-form backend match
  _w_load_config "$repo/.worktree.toml" "be/api-change"
  assert_eq "be/* matches backend" "backend" "${W_PROFILE[name]}"
  assert_eq "backend setup cmd" "echo setup-be" "${W_SETUP_CMDS[1]}"
  assert_eq "backend window count" "1" "${#W_WINDOW_NAMES[@]}"
  assert_eq "backend window 1 name" "server" "${W_WINDOW_NAMES[1]}"

  # Long-form backend match
  _w_load_config "$repo/.worktree.toml" "backend/auth-refactor"
  assert_eq "backend/* matches backend" "backend" "${W_PROFILE[name]}"

  # api/* backend match
  _w_load_config "$repo/.worktree.toml" "api/v2-endpoints"
  assert_eq "api/* matches backend" "backend" "${W_PROFILE[name]}"

  # Default fallback
  _w_load_config "$repo/.worktree.toml" "random-branch"
  assert_eq "unmatched falls to default" "default" "${W_PROFILE[name]}"
  assert_eq "default setup cmd" "echo setup-default" "${W_SETUP_CMDS[1]}"
}

test_load_config_first_match_wins() {
  echo "── _w_load_config (first match wins) ──"
  local repo
  repo=$(setup_repo "config-first")

  cat > "$repo/.worktree.toml" <<'TOML'
[profile.specific]
branches = "fe/auth*, frontend/auth*"

[[profile.specific.setup]]
run = "echo specific"

[profile.broad]
branches = "fe/*, frontend/*"

[[profile.broad.setup]]
run = "echo broad"
TOML

  _w_load_config "$repo/.worktree.toml" "fe/auth-fix"
  assert_eq "specific fe/ pattern wins over broad" "specific" "${W_PROFILE[name]}"

  _w_load_config "$repo/.worktree.toml" "frontend/auth-refactor"
  assert_eq "specific frontend/ pattern wins over broad" "specific" "${W_PROFILE[name]}"

  _w_load_config "$repo/.worktree.toml" "fe/other-thing"
  assert_eq "non-auth fe/ falls to broad" "broad" "${W_PROFILE[name]}"

  _w_load_config "$repo/.worktree.toml" "frontend/other-thing"
  assert_eq "non-auth frontend/ falls to broad" "broad" "${W_PROFILE[name]}"
}

test_load_config_no_match_no_default() {
  echo "── _w_load_config (no match, no default) ──"
  local repo
  repo=$(setup_repo "config-nomatch")

  cat > "$repo/.worktree.toml" <<'TOML'
[profile.frontend]
branches = "fe/*"

[[profile.frontend.setup]]
run = "echo fe"
TOML

  _w_load_config "$repo/.worktree.toml" "random-branch"
  local rc=$?
  assert_eq "returns 1 when no match and no default" "1" "$rc"
}

test_load_config_missing_file() {
  echo "── _w_load_config (missing file) ──"
  _w_load_config "/nonexistent/.worktree.toml" "anything"
  local rc=$?
  assert_eq "returns 1 for missing file" "1" "$rc"
}

test_load_config_comments_and_whitespace() {
  echo "── _w_load_config (comments & whitespace) ──"
  local repo
  repo=$(setup_repo "config-comments")

  cat > "$repo/.worktree.toml" <<'TOML'
# This is a comment
base_branch = "develop"   # inline comment

  [profile.default]   # another comment
  branches = "*"

  [[profile.default.setup]]
  run = "echo hello"   # trailing comment
TOML

  _w_load_config "$repo/.worktree.toml" "anything"
  assert_eq "comments stripped, profile matches" "default" "${W_PROFILE[name]}"
  assert_eq "comments stripped from value" "echo hello" "${W_SETUP_CMDS[1]}"
}

test_setup_runs_commands() {
  echo "── _w_run_setup ──"
  local repo
  repo=$(setup_repo "setup-run")

  cat > "$repo/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.setup]]
run = "touch .setup-marker-1"

[[profile.default.setup]]
run = "touch .setup-marker-2"

[[profile.default.windows]]
name = "shell"
run = "echo hi"
TOML

  (
    cd "$repo"
    WORKTREE_ALLOW_REPO_COMMANDS=1 worktree add setup-test >/dev/null 2>&1
  )

  local wt="$TEST_ROOT/setup-run-worktrees/setup-test"
  if [[ -f "$wt/.setup-marker-1" && -f "$wt/.setup-marker-2" ]]; then
    pass "setup commands created marker files"
  else
    fail "setup commands did not create marker files"
  fi
}

test_add_from_worktree_uses_base() {
  echo "── w add from worktree uses base branch ──"
  local repo
  repo=$(setup_repo "add-from-wt")

  (
    cd "$repo"
    # Create a worktree with a diverged commit
    w add diverged-branch >/dev/null 2>&1
    echo "diverged" >> README.md
    git add README.md
    git commit -m "diverged commit" >/dev/null 2>&1

    # Now from inside this diverged worktree, create another branch
    # It should be based on main, not on diverged-branch
    w add fresh-from-wt >/dev/null 2>&1
  )

  local main_commit diverged_commit fresh_commit
  main_commit=$(git -C "$repo" rev-parse main)
  diverged_commit=$(git -C "$TEST_ROOT/add-from-wt-worktrees/diverged-branch" rev-parse HEAD)
  fresh_commit=$(git -C "$TEST_ROOT/add-from-wt-worktrees/fresh-from-wt" rev-parse HEAD)

  assert_eq "fresh branch based on main, not diverged" "$main_commit" "$fresh_commit"
  if [[ "$fresh_commit" != "$diverged_commit" ]]; then
    pass "fresh branch is NOT based on diverged worktree"
  else
    fail "fresh branch incorrectly based on diverged worktree"
  fi
}

test_not_in_repo() {
  echo "── w outside git repo ──"
  (
    cd "$TEST_ROOT"
    # With a non-fallback subcommand, should still error
    local output
    output=$(w add test 2>&1)
    local rc=$?
    assert_contains "error outside repo with subcommand" "$output" "Not in a git repository"
    assert_exit_code "nonzero exit outside repo with subcommand" "1" "$rc"

    # Bare w should not error about "not in a git repository"
    # Hide fzf so _w_fzf_all returns quickly with "fzf not installed"
    output=$(PATH="/usr/bin:/bin" w 2>&1)
    if [[ "$output" != *"Not in a git repository"* ]]; then
      pass "bare w outside repo falls back to --all"
    else
      fail "bare w outside repo should not complain about git"
    fi

    # w ls outside repo should print, not require fzf
    output=$(PATH="/usr/bin:/bin" w ls 2>&1)
    if [[ "$output" != *"Not in a git repository"* && "$output" != *"fzf not installed"* ]]; then
      pass "w ls outside repo prints worktrees without fzf"
    else
      fail "w ls outside repo should not require fzf or complain about git"
    fi
  )
}

test_dev_no_config() {
  echo "── w dev (no .worktree.toml) ──"
  local repo
  repo=$(setup_repo "dev-noconfig")

  (
    cd "$repo"
    w add dev-test >/dev/null 2>&1
    cd "$TEST_ROOT/dev-noconfig-worktrees/dev-test"
    local output
    output=$(w dev 2>&1)
    assert_contains "dev fails without config" "$output" "No .worktree.toml"
  )
}

test_dev_no_tmux() {
  echo "── w dev (tmux not available) ──"
  local repo
  repo=$(setup_repo "dev-notmux")

  cat > "$repo/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.windows]]
name = "shell"
run = "echo hi"
TOML

  (
    cd "$repo"
    w add tmux-test >/dev/null 2>&1
    cd "$TEST_ROOT/dev-notmux-worktrees/tmux-test"

    # Hide tmux from PATH (a PATH with only the needed tools, not /usr/bin)
    local output nopath rc
    nopath=$(path_without_tmux)
    output=$(PATH="$nopath" w dev 2>&1); rc=$?
    assert_exit_code "dev without tmux fails" "1" "$rc"
    assert_contains "dev without tmux says so" "$output" "tmux not installed"
  )
}

test_shortcut_syntax() {
  echo "── w <branch> shortcut ──"
  local repo
  repo=$(setup_repo "shortcut")

  (
    cd "$repo"
    # First call creates the worktree
    w shortcut-branch >/dev/null 2>&1
    assert_dir_exists "shortcut creates worktree" "$TEST_ROOT/shortcut-worktrees/shortcut-branch"

    # Go back to main repo, then use shortcut again — should cd, not re-add
    cd "$repo"
    local output
    output=$(w shortcut-branch 2>&1)
    # Should NOT say "Creating worktree" — it already exists
    if [[ "$output" != *"Creating worktree"* ]]; then
      pass "shortcut cd's into existing worktree without re-creating"
    else
      fail "shortcut tried to re-create existing worktree"
    fi
  )
}

test_slash_branches() {
  echo "── w add with slashes in branch name ──"
  local repo
  repo=$(setup_repo "slash-test")

  (
    cd "$repo"
    w add fe/deep/nested >/dev/null 2>&1
    assert_dir_exists "nested slash branch" "$TEST_ROOT/slash-test-worktrees/fe/deep/nested"
  )
}

test_repo_name_from_url() {
  echo "── _w_repo_name_from_url ──"
  local result

  result=$(_w_repo_name_from_url "git@github.com:org/my-project.git")
  assert_eq "ssh url with .git" "my-project" "$result"

  result=$(_w_repo_name_from_url "https://github.com/org/my-project.git")
  assert_eq "https url with .git" "my-project" "$result"

  result=$(_w_repo_name_from_url "git@github.com:org/my-project")
  assert_eq "ssh url without .git" "my-project" "$result"

  result=$(_w_repo_name_from_url "https://github.com/org/my-project")
  assert_eq "https url without .git" "my-project" "$result"
}

test_clone_bare() {
  echo "── w clone (bare) ──"
  # Create a bare remote to clone from
  local bare_remote="$TEST_ROOT/clone-bare-remote.git"
  git init --bare "$bare_remote" >/dev/null 2>&1
  local tmp_clone="$TEST_ROOT/clone-bare-tmp"
  git clone "$bare_remote" "$tmp_clone" >/dev/null 2>&1
  (
    cd "$tmp_clone"
    git checkout -b main >/dev/null 2>&1
    echo "init" > README.md
    git add README.md
    git commit -m "initial" >/dev/null 2>&1
    git push -u origin main >/dev/null 2>&1
  )

  local clone_dir="$TEST_ROOT/clone-bare-workspace"
  mkdir -p "$clone_dir"
  (
    cd "$clone_dir"
    local output
    output=$(w clone "$bare_remote" 2>&1)
    assert_contains "clone shows package emoji" "$output" "📦"
    assert_contains "clone shows ready" "$output" "Ready"
    assert_dir_exists "bare repo created" "$clone_dir/clone-bare-remote"
  )
}

test_clone_with_branch() {
  echo "── w clone (with branch) ──"
  # Create a bare remote to clone from
  local bare_remote="$TEST_ROOT/clone-branch-remote.git"
  git init --bare "$bare_remote" >/dev/null 2>&1
  local tmp_clone="$TEST_ROOT/clone-branch-tmp"
  git clone "$bare_remote" "$tmp_clone" >/dev/null 2>&1
  (
    cd "$tmp_clone"
    git checkout -b main >/dev/null 2>&1
    echo "init" > README.md
    git add README.md
    git commit -m "initial" >/dev/null 2>&1
    git push -u origin main >/dev/null 2>&1
  )

  # Now clone it with w clone and a branch
  local clone_dir="$TEST_ROOT/clone-with-branch"
  mkdir -p "$clone_dir"
  (
    cd "$clone_dir"
    local output
    output=$(w clone "$bare_remote" fe/test-feature 2>&1)
    assert_contains "clone shows worktree emoji" "$output" "🌿"
    assert_dir_exists "worktree created from clone" "$clone_dir/clone-branch-remote-worktrees/fe/test-feature"
  )
}

test_clone_no_url() {
  echo "── w clone (no url) ──"
  local output
  output=$(w clone 2>&1)
  assert_contains "clone no url shows usage" "$output" "usage:"
}

test_clone_already_exists() {
  echo "── w clone (already exists) ──"
  local bare_remote="$TEST_ROOT/clone-dup-remote.git"
  git init --bare "$bare_remote" >/dev/null 2>&1
  local tmp_clone="$TEST_ROOT/clone-dup-tmp"
  git clone "$bare_remote" "$tmp_clone" >/dev/null 2>&1
  (
    cd "$tmp_clone"
    git checkout -b main >/dev/null 2>&1
    echo "init" > README.md
    git add README.md
    git commit -m "initial" >/dev/null 2>&1
    git push -u origin main >/dev/null 2>&1
  )

  local clone_dir="$TEST_ROOT/clone-dup-workspace"
  mkdir -p "$clone_dir"
  (
    cd "$clone_dir"
    w clone "$bare_remote" >/dev/null 2>&1
    local output
    output=$(w clone "$bare_remote" 2>&1)
    assert_contains "clone already exists" "$output" "already exists"
  )
}

test_clone_help() {
  echo "── w clone --help ──"
  local output
  output=$(w clone --help 2>&1)
  assert_contains "clone help" "$output" "Clone a repository"
}

test_resolve_branch_url() {
  echo "── _w_resolve_branch_url ──"

  # Valid tree URLs
  local result
  result=$(_w_resolve_branch_url "https://github.com/org/repo/tree/main" 2>/dev/null)
  assert_eq "simple branch" "main" "$result"

  result=$(_w_resolve_branch_url "https://github.com/org/repo/tree/feat/my-feature" 2>/dev/null)
  assert_eq "slash branch" "feat/my-feature" "$result"

  result=$(_w_resolve_branch_url "https://github.com/tmack/worktrees/tree/claude/pink-dolphins-7864b7" 2>/dev/null)
  assert_eq "deeply nested branch" "claude/pink-dolphins-7864b7" "$result"

  result=$(_w_resolve_branch_url "https://github.com/org/repo/tree/feat/foo/" 2>/dev/null)
  assert_eq "strips trailing slash" "feat/foo" "$result"

  result=$(_w_resolve_branch_url "http://github.com/org/repo/tree/my-branch" 2>/dev/null)
  assert_eq "http tree url" "my-branch" "$result"

  # Invalid inputs
  _w_resolve_branch_url "feat/login" >/dev/null 2>&1
  assert_exit_code "plain branch returns 1" "1" "$?"

  _w_resolve_branch_url "https://github.com/org/repo/pull/42" >/dev/null 2>&1
  assert_exit_code "pr url returns 1" "1" "$?"

  _w_resolve_branch_url "https://gitlab.com/org/repo/tree/main" >/dev/null 2>&1
  assert_exit_code "non-github tree url returns 1" "1" "$?"

  _w_resolve_branch_url "https://github.com/org/repo/tree/" >/dev/null 2>&1
  assert_exit_code "tree url without branch returns 1" "1" "$?"
}

test_add_branch_tree_url() {
  echo "── w add <tree-url> ──"
  local repo
  repo=$(setup_repo "tree-url")

  (
    cd "$repo"
    git checkout -b tree-url-branch >/dev/null 2>&1
    echo "x" > tree-url.txt
    git add tree-url.txt
    git commit -m "tree url branch" >/dev/null 2>&1
    git push origin tree-url-branch >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    git branch -D tree-url-branch >/dev/null 2>&1
  )

  local output
  output=$(cd "$repo" && w add "https://github.com/org/repo/tree/tree-url-branch" 2>&1)
  assert_contains "shows resolved message" "$output" "Resolved branch URL"
  assert_dir_exists "worktree created" "$TEST_ROOT/tree-url-worktrees/tree-url-branch"
}

test_add_slash_branch_tree_url() {
  echo "── w add <tree-url> (slash branch) ──"
  local repo
  repo=$(setup_repo "tree-url-slash")

  (
    cd "$repo"
    git checkout -b feat/tree-nested >/dev/null 2>&1
    echo "x" > nested.txt
    git add nested.txt
    git commit -m "nested" >/dev/null 2>&1
    git push origin feat/tree-nested >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    git branch -D feat/tree-nested >/dev/null 2>&1
  )

  cd "$repo" && w add "https://github.com/org/repo/tree/feat/tree-nested" >/dev/null 2>&1
  assert_dir_exists "slash branch worktree created" "$TEST_ROOT/tree-url-slash-worktrees/feat/tree-nested"
}

test_shortcut_tree_url() {
  echo "── w <tree-url> shortcut ──"
  local repo
  repo=$(setup_repo "tree-shortcut")

  (
    cd "$repo"
    git checkout -b tree-shortcut >/dev/null 2>&1
    git push origin tree-shortcut >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    git branch -D tree-shortcut >/dev/null 2>&1
  )

  local output
  output=$(cd "$repo" && w "https://github.com/org/repo/tree/tree-shortcut" 2>&1)
  assert_contains "shortcut resolves tree url" "$output" "Resolved branch URL"
  assert_dir_exists "shortcut creates worktree" "$TEST_ROOT/tree-shortcut-worktrees/tree-shortcut"
}

# ── _w_resolve_pr_url ─────────────────────────────────────────────

test_resolve_pr_url() {
  echo "── _w_resolve_pr_url ──"

  # Non-PR strings should return 1
  _w_resolve_pr_url "feat/login" >/dev/null 2>&1
  assert_exit_code "plain branch name returns 1" "1" "$?"

  _w_resolve_pr_url "" >/dev/null 2>&1
  assert_exit_code "empty string returns 1" "1" "$?"

  _w_resolve_pr_url "https://gitlab.com/org/repo/merge_requests/42" >/dev/null 2>&1
  assert_exit_code "non-github url returns 1" "1" "$?"

  _w_resolve_pr_url "https://github.com/org/repo/pull/" >/dev/null 2>&1
  assert_exit_code "url missing pr number returns 1" "1" "$?"

  _w_resolve_pr_url "https://github.com/org/repo/issues/42" >/dev/null 2>&1
  assert_exit_code "issues url returns 1" "1" "$?"

  # Valid PR URL patterns — without gh available all should fail with the gh error,
  # not with "not a PR URL" (i.e. pattern matching must succeed).
  local output
  output=$(GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url "https://github.com/org/repo/pull/42" 2>&1)
  assert_contains "https pull url reaches gh check" "$output" "gh CLI not installed"

  output=$(GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url "https://github.com/org/repo/pulls/42" 2>&1)
  assert_contains "https pulls url reaches gh check" "$output" "gh CLI not installed"

  output=$(GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url "https://github.com/org/repo/pull/42/" 2>&1)
  assert_contains "trailing slash url reaches gh check" "$output" "gh CLI not installed"

  output=$(GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url "http://github.com/org/repo/pull/1" 2>&1)
  assert_contains "http pull url reaches gh check" "$output" "gh CLI not installed"

  # /pulls/ must be normalised to /pull/ before gh is called —
  # the gh error message (or "Failed to resolve") must not contain /pulls/
  output=$(GITHUB_CMD=wt-test-no-such-gh _w_resolve_pr_url "https://github.com/org/repo/pulls/42" 2>&1)
  if [[ "$output" != *"/pulls/"* ]]; then
    pass "/pulls/ normalised to /pull/ before gh call"
  else
    fail "/pulls/ was NOT normalised — still present in output"
  fi
}

# ── w add: remote branch tracking ────────────────────────────────

test_add_remote_branch_tracking() {
  echo "── w add (remote branch tracking) ──"
  local repo
  repo=$(setup_repo "remote-track")

  # Push a branch to the remote then delete the local copy so it only
  # exists on origin — simulates a freshly pushed branch.
  (
    cd "$repo"
    git checkout -b remote-only >/dev/null 2>&1
    echo "remote" > remote-file.txt
    git add remote-file.txt
    git commit -m "remote branch commit" >/dev/null 2>&1
    git push origin remote-only >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    git branch -D remote-only >/dev/null 2>&1

    w add remote-only >/dev/null 2>&1
  )

  local wt_dir="$TEST_ROOT/remote-track-worktrees/remote-only"
  assert_dir_exists "worktree created for remote-only branch" "$wt_dir"

  local branch
  branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  assert_eq "worktree is on remote-only branch" "remote-only" "$branch"
}

test_add_remote_branch_upstream() {
  echo "── w add (remote branch upstream tracking) ──"
  local repo
  repo=$(setup_repo "remote-upstream")

  (
    cd "$repo"
    git checkout -b tracked-remote >/dev/null 2>&1
    echo "x" > tracked.txt
    git add tracked.txt
    git commit -m "tracked" >/dev/null 2>&1
    git push origin tracked-remote >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    git branch -D tracked-remote >/dev/null 2>&1

    w add tracked-remote >/dev/null 2>&1
  )

  local wt_dir="$TEST_ROOT/remote-upstream-worktrees/tracked-remote"
  local upstream
  upstream=$(git -C "$wt_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  assert_eq "remote branch has upstream tracking" "origin/tracked-remote" "$upstream"
}

test_add_remote_branch_message() {
  echo "── w add (remote branch output message) ──"
  local repo
  repo=$(setup_repo "remote-msg")

  (
    cd "$repo"
    git checkout -b msg-remote >/dev/null 2>&1
    echo "x" > msg.txt
    git add msg.txt
    git commit -m "msg" >/dev/null 2>&1
    git push origin msg-remote >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    git branch -D msg-remote >/dev/null 2>&1
  )

  local output
  output=$(cd "$repo" && w add msg-remote 2>&1)
  assert_contains "output mentions tracking origin" "$output" "tracking origin/msg-remote"
}

# ── w add PR URL (no gh CLI) ──────────────────────────────────────

test_add_pr_url_no_gh() {
  echo "── w add <pr-url> (no gh CLI) ──"
  local repo
  repo=$(setup_repo "pr-url-no-gh")

  (
    cd "$repo"
    local output
    output=$(GITHUB_CMD=wt-test-no-such-gh w add "https://github.com/org/repo/pull/1" 2>&1)
    assert_contains "w add pr-url without gh errors" "$output" "gh CLI not installed"
  )
}

test_shortcut_pr_url_no_gh() {
  echo "── w <pr-url> shortcut (no gh CLI) ──"
  local repo
  repo=$(setup_repo "pr-shortcut-no-gh")

  (
    cd "$repo"
    local output
    output=$(GITHUB_CMD=wt-test-no-such-gh w "https://github.com/org/repo/pull/1" 2>&1)
    assert_contains "w pr-url shortcut without gh errors" "$output" "gh CLI not installed"
  )
}

# ── w add --help updated content ─────────────────────────────────

test_add_help_pr_url() {
  echo "── w add --help (PR URL / branch URL content) ──"
  local output
  output=$(cd "$TEST_ROOT" && w add --help 2>&1)
  assert_contains "add help mentions github-pr-url" "$output" "github-pr-url"
  assert_contains "add help mentions github-branch-url" "$output" "github-branch-url"
  assert_contains "add help shows Examples section" "$output" "Examples:"
}

# ── w help: pr-url entry ─────────────────────────────────────────

test_help_pr_url_entry() {
  echo "── w help (pr-url line) ──"
  local output
  output=$(w help 2>&1)
  assert_contains "help shows pr-url entry" "$output" "pr-url"
}

# ── dependency bootstrap ──────────────────────────────────────────

test_bootstrap_deps() {
  echo "── _w_bootstrap_deps ──"
  local repo
  repo=$(setup_repo "deps")

  # node_modules at root is cloned into the new worktree
  (
    cd "$repo"
    mkdir -p "$repo/node_modules/pkg"
    echo "module.exports = 1" > "$repo/node_modules/pkg/index.js"
    w add deps-basic >/dev/null 2>&1
    assert_dir_exists "node_modules cloned" "$TEST_ROOT/deps-worktrees/deps-basic/node_modules"
    if [[ -f "$TEST_ROOT/deps-worktrees/deps-basic/node_modules/pkg/index.js" ]]; then
      pass "node_modules contents cloned"
    else
      fail "node_modules contents not cloned"
    fi
  )

  # nested dep dir is cloned at its relative path
  local repo2
  repo2=$(setup_repo "deps-nested")
  (
    cd "$repo2"
    mkdir -p "$repo2/frontend/node_modules/pkg"
    echo "x" > "$repo2/frontend/node_modules/pkg/index.js"
    w add nested >/dev/null 2>&1
    assert_dir_exists "nested node_modules cloned" \
      "$TEST_ROOT/deps-nested-worktrees/nested/frontend/node_modules"
  )

  # WORKTREE_NO_DEP_BOOTSTRAP disables the clone
  local repo3
  repo3=$(setup_repo "deps-off")
  (
    cd "$repo3"
    mkdir -p "$repo3/node_modules/pkg"
    echo "x" > "$repo3/node_modules/pkg/index.js"
    WORKTREE_NO_DEP_BOOTSTRAP=1 w add off >/dev/null 2>&1
    assert_dir_not_exists "bootstrap disabled by env" \
      "$TEST_ROOT/deps-off-worktrees/off/node_modules"
  )

  # WORKTREE_DEP_DIRS overrides which dirs are copied
  local repo4
  repo4=$(setup_repo "deps-override")
  (
    cd "$repo4"
    mkdir -p "$repo4/.venv/bin" "$repo4/node_modules"
    echo "x" > "$repo4/.venv/bin/activate"
    echo "x" > "$repo4/node_modules/marker"
    WORKTREE_DEP_DIRS=".venv" w add override >/dev/null 2>&1
    assert_dir_exists "override dir cloned" "$TEST_ROOT/deps-override-worktrees/override/.venv"
    assert_dir_not_exists "non-override dir skipped" \
      "$TEST_ROOT/deps-override-worktrees/override/node_modules"
  )

  # does not clobber a dep dir already present in the worktree
  local repo5
  repo5=$(setup_repo "deps-existing")
  mkdir -p "$repo5/vendor"; echo "fresh" > "$repo5/vendor/lib"
  local dest="$TEST_ROOT/preexist-dest"
  mkdir -p "$dest/vendor"; echo "PREEXISTING" > "$dest/vendor/lib"
  _w_bootstrap_deps "$repo5" "$dest"
  assert_eq "existing dep dir not clobbered" "PREEXISTING" "$(cat "$dest/vendor/lib")"

  # bare repo is a no-op (nothing to copy from)
  local bare_dest="$TEST_ROOT/from-bare-dest"
  mkdir -p "$bare_dest"
  _w_bootstrap_deps "$TEST_ROOT/deps-bare.git" "$bare_dest"
  if [[ -z "$(ls -A "$bare_dest")" ]]; then
    pass "bare repo bootstrap is a no-op"
  else
    fail "bare repo bootstrap copied something"
  fi
}

test_dep_dirs_toml() {
  echo "── _w_resolve_dep_dirs (.worktree.toml) ──"
  local repo
  repo=$(setup_repo "dep-toml")
  cat > "$repo/.worktree.toml" <<'TOML'
dep_dirs = "shared_vendor"

[profile.frontend]
branches = "fe/*, ui/*"
dep_dirs = "frontend/node_modules"

[profile.default]
branches = "*"
TOML

  local res
  res=$(_w_resolve_dep_dirs "$repo" "fe/x" | tr '\n' ' '); res="${res% }"
  assert_eq "top-level replaces defaults, profile extends it" \
    "shared_vendor frontend/node_modules" "$res"

  res=$(_w_resolve_dep_dirs "$repo" "random-branch" | tr '\n' ' '); res="${res% }"
  assert_eq "unmatched branch: top-level base only" \
    "shared_vendor" "$res"

  res=$(WORKTREE_DEP_DIRS="only_this" _w_resolve_dep_dirs "$repo" "fe/x" | tr '\n' ' '); res="${res% }"
  assert_eq "env var replaces the whole set" "only_this" "$res"

  # no top-level dep_dirs: profile extends the built-in defaults
  local repo_nb
  repo_nb=$(setup_repo "dep-nobase")
  cat > "$repo_nb/.worktree.toml" <<'TOML'
[profile.frontend]
branches = "fe/*"
dep_dirs = "frontend/node_modules"
TOML
  res=$(_w_resolve_dep_dirs "$repo_nb" "fe/x" | tr '\n' ' '); res="${res% }"
  assert_eq "no top-level: profile extends built-ins" \
    "node_modules vendor frontend/node_modules" "$res"

  # end-to-end: top-level replaces built-ins, profile extends the clone
  local repo2
  repo2=$(setup_repo "dep-toml-e2e")
  cat > "$repo2/.worktree.toml" <<'TOML'
dep_dirs = "shared_vendor"

[profile.default]
branches = "*"
dep_dirs = "extra_pkgs"
TOML
  (
    cd "$repo2"
    mkdir -p "$repo2/node_modules" "$repo2/shared_vendor" "$repo2/extra_pkgs"
    echo x > "$repo2/node_modules/m"
    echo x > "$repo2/shared_vendor/m"
    echo x > "$repo2/extra_pkgs/m"
    w add e2e >/dev/null 2>&1
    assert_dir_not_exists "builtin node_modules replaced by top-level" \
      "$TEST_ROOT/dep-toml-e2e-worktrees/e2e/node_modules"
    assert_dir_exists "top-level base dir cloned" \
      "$TEST_ROOT/dep-toml-e2e-worktrees/e2e/shared_vendor"
    assert_dir_exists "profile dep dir cloned" \
      "$TEST_ROOT/dep-toml-e2e-worktrees/e2e/extra_pkgs"
  )
}

# ── Repo-command opt-in ───────────────────────────────────────────

test_setup_skipped_by_default() {
  echo "── repo commands: setup skipped without opt-in ──"
  local repo
  repo=$(setup_repo "optin-setup")

  cat > "$repo/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.setup]]
run = "touch .setup-marker"
TOML

  (
    cd "$repo"
    unset WORKTREE_ALLOW_REPO_COMMANDS
    local output wt="$TEST_ROOT/optin-setup-worktrees"
    output=$(worktree add gated 2>&1)
    assert_dir_exists "worktree still created" "$wt/gated"
    if [[ ! -e "$wt/gated/.setup-marker" ]]; then
      pass "setup command not run by default"
    else
      fail "setup command ran without opt-in"
    fi
    assert_contains "skip notice" "$output" "Not running 1 setup command(s)"
    assert_contains "skip notice lists the command" "$output" "touch .setup-marker"
    assert_contains "skip notice names the opt-in" "$output" "WORKTREE_ALLOW_REPO_COMMANDS=1"

    cd "$repo"
    local v i=0
    for v in 0 true yes " 1" "" 11; do
      (( i++ ))
      WORKTREE_ALLOW_REPO_COMMANDS="$v" worktree add "other-$i" >/dev/null 2>&1
      cd "$repo"
    done
    if [[ -z "$(find "$wt" -name .setup-marker)" ]]; then
      pass "values other than 1 do not opt in"
    else
      fail "a value other than 1 enabled setup commands"
    fi

    WORKTREE_ALLOW_REPO_COMMANDS=1 worktree add allowed >/dev/null 2>&1
    if [[ -f "$wt/allowed/.setup-marker" ]]; then
      pass "WORKTREE_ALLOW_REPO_COMMANDS=1 runs setup"
    else
      fail "WORKTREE_ALLOW_REPO_COMMANDS=1 did not run setup"
    fi
  )
}

# Logs each call; like tmux, new-session and new-window with -P print an id
# (@0, @1, ...) for the window they create.
_zt_fake_tmux() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/tmux" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$bin/tmux.log"
[ "\$1" = has-session ] && exit 1
case " \$* " in
  *" -P "*) n=\$(grep -c -- ' -P ' "$bin/tmux.log"); echo "@\$((n - 1))" ;;
esac
exit 0
FAKE
  chmod +x "$bin/tmux"
  : > "$bin/tmux.log"
}

test_dev_commands_gated() {
  echo "── repo commands: dev pre/window gated ──"
  local repo
  repo=$(setup_repo "optin-dev")

  cat > "$repo/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.pre]]
run = "touch .pre-marker"

[[profile.default.windows]]
name = "server"
run = "echo window-cmd"
TOML

  local bin="$TEST_ROOT/optin-dev-bin"
  _zt_fake_tmux "$bin"

  (
    cd "$repo"
    worktree add devgate >/dev/null 2>&1
    local wt="$TEST_ROOT/optin-dev-worktrees/devgate"
    cd "$wt"
    unset WORKTREE_ALLOW_REPO_COMMANDS
    local output rc
    output=$(PATH="$bin:$PATH" worktree dev 2>&1); rc=$?
    assert_exit_code "dev without opt-in succeeds" "0" "$rc"
    [[ ! -e "$wt/.pre-marker" ]] && pass "pre command not run by default" || fail "pre command ran without opt-in"
    assert_contains "pre skip notice" "$output" "Not running 1 pre command(s)"
    assert_contains "window skip notice" "$output" "Not running 1 window command(s)"
    if grep -q '^new-window .*-n server' "$bin/tmux.log" && ! grep -q 'send-keys' "$bin/tmux.log"; then
      pass "window created without typing its command"
    else
      fail "window command was sent without opt-in"
    fi

    : > "$bin/tmux.log"
    output=$(WORKTREE_ALLOW_REPO_COMMANDS=1 PATH="$bin:$PATH" worktree dev 2>&1); rc=$?
    assert_exit_code "dev with opt-in succeeds" "0" "$rc"
    [[ -f "$wt/.pre-marker" ]] && pass "pre command runs with opt-in" || fail "pre command did not run with opt-in"
    if grep -q 'send-keys .*echo window-cmd Enter' "$bin/tmux.log"; then
      pass "window command sent with opt-in"
    else
      fail "window command not sent with opt-in"
    fi
  )
}

# ── tmux sessions are matched by exact name ───────────────────────
#
# Real tmux against the private server under TEST_ROOT. A plain `-t name` also
# matches a session whose name only starts with `name`; worktree must never
# kill or attach such a session.

_zt_tmux_session() {
  "$REAL_TMUX" new-session -d -s "$1" </dev/null >/dev/null 2>&1
}

_zt_tmux_has() {
  "$REAL_TMUX" has-session -t "=$1" </dev/null >/dev/null 2>&1
}

# tmux passing everything to the real one, except attach-session (which needs
# a terminal) logs the session its target resolves to (list-windows takes a
# target-session, as attach-session does).
_zt_attach_logging_tmux() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/tmux" <<FAKE
#!/bin/sh
if [ "\$1" = attach-session ]; then
  [ "\$2" = -t ] || exit 1
  "$REAL_TMUX" list-windows -t "\$3" -F '#{session_name}' 2>/dev/null | head -n 1 >> "$bin/attach.log"
  exit
fi
exec "$REAL_TMUX" "\$@"
FAKE
  chmod +x "$bin/tmux"
  : > "$bin/attach.log"
}

test_tmux_exact_match() {
  echo "── tmux: sessions matched by exact name ──"
  if [[ -z "$REAL_TMUX" ]]; then
    echo "  (skipped: tmux not installed)"
    return 0
  fi

  local repo
  repo=$(setup_repo "tx")
  local wts="$TEST_ROOT/tx-worktrees"
  cat > "$repo/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.windows]]
name = "server"
TOML

  (
    cd "$repo"
    w add foo >/dev/null 2>&1
    _zt_tmux_session tx-foo-bar
    echo "foo" | w rm foo >/dev/null 2>&1
    assert_dir_not_exists "rm removed the worktree" "$wts/foo"
    _zt_tmux_has tx-foo-bar && pass "rm leaves a session that only starts with the name" \
      || fail "rm killed tx-foo-bar for worktree foo"

    cd "$repo"
    w add foo >/dev/null 2>&1
    _zt_tmux_session tx-foo
    echo "foo" | w rm foo >/dev/null 2>&1
    _zt_tmux_has tx-foo && fail "rm left its own session tx-foo" || pass "rm kills its own session"
    _zt_tmux_has tx-foo-bar && pass "rm keeps the longer session next to its own" \
      || fail "rm killed tx-foo-bar next to tx-foo"
  )

  local bin="$TEST_ROOT/tx-bin"
  _zt_attach_logging_tmux "$bin"
  (
    cd "$repo"
    w add foo >/dev/null 2>&1
    cd "$wts/foo"
    local output rc
    output=$(PATH="$bin:$PATH" w dev 2>&1); rc=$?
    assert_exit_code "dev with only a longer session succeeds" "0" "$rc"
    [[ "$output" != *"Reattaching"* ]] && pass "dev does not reattach a longer session" \
      || fail "dev reattached tx-foo-bar for foo"
    assert_eq "dev attaches its own new session" "tx-foo" "$(<"$bin/attach.log")"
    assert_eq "dev puts its windows in its own session" "shell server " \
      "$("$REAL_TMUX" list-windows -t "=tx-foo" -F '#W' 2>/dev/null | tr '\n' ' ')"
    assert_eq "dev adds no window to the longer session" "1" \
      "$("$REAL_TMUX" list-windows -t "=tx-foo-bar" -F x 2>/dev/null | wc -l | tr -d ' ')"

    : > "$bin/attach.log"
    output=$(PATH="$bin:$PATH" w dev 2>&1); rc=$?
    assert_contains "dev reattaches its own session" "$output" "Reattaching to tx-foo"
    assert_eq "dev reattaches tx-foo, not tx-foo-bar" "tx-foo" "$(<"$bin/attach.log")"
  )
  "$REAL_TMUX" kill-session -t "=tx-foo" >/dev/null 2>&1
  "$REAL_TMUX" kill-session -t "=tx-foo-bar" >/dev/null 2>&1
}

# ── tmux session names tmux would rewrite ─────────────────────────
#
# tmux stores a session name with '.' and ':' as '_' (and escapes '\\', '$'
# and control characters), so worktree must use that stored form everywhere.

test_tmux_names() {
  echo "── tmux: session names tmux would rewrite ──"
  assert_eq "_w_tmux_name maps . and : to _" "my_re_po-fix/v1_2" "$(_w_tmux_name 'my.re:po-fix/v1.2')"
  assert_eq "_w_tmux_name maps \\ \$ tab and non-ASCII bytes to _" "a_b_c_d__ e" \
    "$(_w_tmux_name $'a\\b$c\tdé e')"
  assert_eq "_w_tmux_name keeps a plain name" "plain-name_09 ok" "$(_w_tmux_name 'plain-name_09 ok')"
  assert_eq "_w_tmux_name maps # (a tmux format) and ; (a command separator) to _" "issue_S_" \
    "$(_w_tmux_name 'issue#S;')"
  assert_eq "_w_tmux_name maps every # and ;" "a_b_{session_id}c__" "$(_w_tmux_name 'a;b#{session_id}c##')"
  assert_eq "_w_tmux_dir doubles # and ends a trailing ; with /" "/x/issue##S;/" "$(_w_tmux_dir '/x/issue#S;')"
  assert_eq "_w_tmux_dir keeps a plain dir" "/x/plain dir;x" "$(_w_tmux_dir '/x/plain dir;x')"
  assert_eq "_w_session_name default" "my_repo-fix-v1_2" "$(_w_session_name /x/my.repo fix/v1.2)"
  assert_eq "_w_session_name override made tmux-safe" "my_session_1" \
    "$(_w_session_name /x/repo b 'my.session:1')"

  if [[ -z "$REAL_TMUX" ]]; then
    echo "  (skipped: tmux not installed)"
    return 0
  fi

  local r="$TEST_ROOT/my.re:po" s="my_re_po-fix-v1_2"
  setup_repo "tn" >/dev/null
  git clone -q "$TEST_ROOT/tn-bare.git" "$r" 2>/dev/null
  cat > "$r/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.windows]]
name = "server"
TOML
  local bin="$TEST_ROOT/tn-bin"
  _zt_attach_logging_tmux "$bin"
  (
    cd "$r"
    w add fix/v1.2 >/dev/null 2>&1
    assert_dir_exists "worktree in a repo with . and :" "$r-worktrees/fix/v1.2"
    cd "$r-worktrees/fix/v1.2"
    local output rc
    output=$(PATH="$bin:$PATH" w dev 2>&1); rc=$?
    assert_exit_code "dev with . and : in the name succeeds" "0" "$rc"
    assert_contains "dev names the session as tmux stores it" "$output" "Starting dev session: $s "
    assert_eq "dev attaches the session it created" "$s" "$(<"$bin/attach.log")"
    assert_eq "dev puts its windows in that session" "shell server " \
      "$("$REAL_TMUX" list-windows -t "=$s" -F '#W' 2>/dev/null | tr '\n' ' ')"

    : > "$bin/attach.log"
    output=$(PATH="$bin:$PATH" w dev 2>&1); rc=$?
    assert_exit_code "second dev succeeds" "0" "$rc"
    assert_contains "second dev reattaches" "$output" "Reattaching to $s"
    assert_eq "second dev attaches the same session" "$s" "$(<"$bin/attach.log")"
    assert_eq "no second session is created" "1" \
      "$("$REAL_TMUX" list-sessions -F x 2>/dev/null | wc -l | tr -d ' ')"

    cd "$r"
    echo "fix/v1.2" | w rm fix/v1.2 >/dev/null 2>&1
    assert_dir_not_exists "rm removed the worktree" "$r-worktrees/fix/v1.2"
    _zt_tmux_has "$s" && fail "rm left the session $s" || pass "rm kills the session tmux stored"
  )
  "$REAL_TMUX" kill-session -t "=$s" >/dev/null 2>&1
}

# The pane text of the window named $2 in session $1, once it shows $3 (polled
# for up to 10s: the window's shell runs the typed command when it starts);
# with no $3, as it is now.
_zt_window_text() {
  local id n=0 text
  # one window per line: its id, a space, its name (tmux escapes a tab in -F)
  id=$("$REAL_TMUX" list-windows -t "=$1" -F '#{window_id} #{window_name}' 2>/dev/null |
    awk -v n="$2" '{ id = $1; sub(/^[^ ]* /, ""); if ($0 == n) print id }')
  [[ -n "$id" ]] || return 1
  while (( n < 50 )); do
    text=$("$REAL_TMUX" capture-pane -p -t "$id" 2>/dev/null)
    [[ "$text" == *"${3:-}"* ]] && break
    sleep 0.2; (( n++ ))
  done
  print -r -- "$text"
}

# A window name with '.' (a pane separator) or ':' (a session separator) broke
# `=session:name` targets, so its command went nowhere; windows are now
# targeted by the id tmux prints when it creates them.
test_tmux_window_names() {
  echo "── tmux: window commands reach their window, whatever its name ──"
  if [[ -z "$REAL_TMUX" ]]; then
    echo "  (skipped: tmux not installed)"
    return 0
  fi
  local repo
  repo=$(setup_repo "wn")
  local wts="$TEST_ROOT/wn-worktrees"
  cat > "$repo/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.windows]]
name = "a.b"
run = "echo A1""MARK"

[[profile.default.windows]]
name = "c:d"
run = "echo C2""MARK"

[[profile.default.windows]]
name = "plain"
run = "echo P3""MARK"
TOML
  local bin="$TEST_ROOT/wn-bin" s=wn-winnames
  _zt_attach_logging_tmux "$bin"
  mkdir -p "$TEST_ROOT/wn-home"
  (
    cd "$repo"
    w add winnames >/dev/null 2>&1
    cd "$wts/winnames"
    # the windows' shells: plain sh with no profile, so only the typed commands run
    export SHELL=/bin/sh HOME="$TEST_ROOT/wn-home" ENV=
    local output rc t
    output=$(WORKTREE_ALLOW_REPO_COMMANDS=1 PATH="$bin:$PATH" w dev 2>&1); rc=$?
    assert_exit_code "dev with . and : in window names succeeds" "0" "$rc"
    assert_eq "dev attaches its session" "$s" "$(<"$bin/attach.log")"
    assert_eq "window names are kept as written" "shell a.b c:d plain " \
      "$("$REAL_TMUX" list-windows -t "=$s" -F '#W' 2>/dev/null | tr '\n' ' ')"
    assert_eq "the shell window is selected" "1shell" \
      "$("$REAL_TMUX" list-windows -t "=$s" -F '#{window_active}#W' 2>/dev/null | grep '^1')"
    t=$(_zt_window_text "$s" a.b A1MARK)
    [[ "$t" == *A1MARK* && "$t" != *C2* && "$t" != *P3* ]] && pass "a.b gets its own command" \
      || fail "a.b pane: $t"
    t=$(_zt_window_text "$s" c:d C2MARK)
    [[ "$t" == *C2MARK* && "$t" != *A1* && "$t" != *P3* ]] && pass "c:d gets its own command" \
      || fail "c:d pane: $t"
    t=$(_zt_window_text "$s" plain P3MARK)
    [[ "$t" == *P3MARK* && "$t" != *A1* && "$t" != *C2* ]] && pass "plain gets its own command" \
      || fail "plain pane: $t"
    t=$(_zt_window_text "$s" shell)
    [[ "$t" != *A1* && "$t" != *C2* && "$t" != *P3* ]] && pass "the shell window gets no command" \
      || fail "shell pane: $t"
  )
  "$REAL_TMUX" kill-session -t "=$s" >/dev/null 2>&1
}

# A profile's `session` override names the session w dev makes; w rm must
# look it up the same way and kill that session, not the default name.
test_rm_session_override() {
  echo "── tmux: w rm kills the profile's session override ──"
  if [[ -z "$REAL_TMUX" ]]; then
    echo "  (skipped: tmux not installed)"
    return 0
  fi
  local repo
  repo=$(setup_repo "so")
  local wts="$TEST_ROOT/so-worktrees"
  cat > "$repo/.worktree.toml" <<'TOML'
[profile.fe]
branches = "fe/*"
session = "custom.sess"

[[profile.fe.windows]]
name = "server"

[profile.default]
branches = "*"
TOML
  local bin="$TEST_ROOT/so-bin"
  _zt_attach_logging_tmux "$bin"
  (
    cd "$repo"
    w add fe/login >/dev/null 2>&1
    cd "$wts/fe/login"
    local output rc
    output=$(PATH="$bin:$PATH" w dev 2>&1); rc=$?
    assert_exit_code "dev with a session override succeeds" "0" "$rc"
    assert_eq "dev attaches the override session" "custom_sess" "$(<"$bin/attach.log")"
    _zt_tmux_session so-fe-login
    _zt_tmux_session custom_sess-2
    cd "$repo"
    echo "fe/login" | w rm fe/login >/dev/null 2>&1
    assert_dir_not_exists "rm removed the worktree" "$wts/fe/login"
    _zt_tmux_has custom_sess && fail "rm left the override session custom_sess" \
      || pass "rm kills the override session"
    _zt_tmux_has so-fe-login && pass "rm keeps the session with the default name" \
      || fail "rm killed so-fe-login instead of the override"
    _zt_tmux_has custom_sess-2 && pass "rm keeps a longer session next to the override" \
      || fail "rm killed custom_sess-2"
  )
  "$REAL_TMUX" kill-session -t "=so-fe-login" >/dev/null 2>&1
  "$REAL_TMUX" kill-session -t "=custom_sess-2" >/dev/null 2>&1
  "$REAL_TMUX" kill-session -t "=custom_sess" >/dev/null 2>&1
}

# ── gh command override ───────────────────────────────────────────

_zt_fake_gh() {
  # _zt_fake_gh <bin> <name> <branch-to-print>
  local bin="$1" name="$2" out="$3"
  mkdir -p "$bin"
  cat > "$bin/$name" <<FAKE
#!/bin/sh
printf '%s %s\n' "$name" "\$*" >> "$bin/gh.log"
printf '%s' "$out"
FAKE
  chmod +x "$bin/$name"
}

test_gh_override() {
  echo "── gh override (GITHUB_CMD, GH_CMD, gh) ──"
  local bin="$TEST_ROOT/gh-bin" url="https://github.com/acme/widgets/pull/7"
  _zt_fake_gh "$bin" fake-gh-a branch-a
  _zt_fake_gh "$bin" fake-gh-b branch-b
  _zt_fake_gh "$bin" gh branch-plain
  _zt_fake_gh "$bin" fake-gh-empty ""

  (
    unset GITHUB_CMD GH_CMD
    PATH="$bin:$PATH"
    local out rc

    out=$(GITHUB_CMD=fake-gh-a GH_CMD=fake-gh-b _w_resolve_pr_url "$url" 2>&1)
    assert_eq "GITHUB_CMD wins over GH_CMD" "branch-a" "$out"

    out=$(GH_CMD=fake-gh-b _w_resolve_pr_url "$url" 2>&1)
    assert_eq "GH_CMD used when GITHUB_CMD unset" "branch-b" "$out"

    out=$(GITHUB_CMD= GH_CMD=fake-gh-b _w_resolve_pr_url "$url" 2>&1)
    assert_eq "empty GITHUB_CMD counts as unset" "branch-b" "$out"

    out=$(_w_resolve_pr_url "$url" 2>&1)
    assert_eq "falls back to plain gh" "branch-plain" "$out"

    out=$(GITHUB_CMD= GH_CMD= _w_resolve_pr_url "$url" 2>&1)
    assert_eq "empty GITHUB_CMD and GH_CMD fall back to gh" "branch-plain" "$out"

    : > "$bin/gh.log"
    GITHUB_CMD="fake-gh-a --profile work" _w_resolve_pr_url "https://github.com/acme/widgets/pulls/7/" >/dev/null 2>&1
    assert_eq "command line split into words, -R passed, URL normalised" \
      "fake-gh-a --profile work pr view https://github.com/acme/widgets/pull/7 -R acme/widgets --json headRefName --jq .headRefName" \
      "$(cat "$bin/gh.log")"

    : > "$bin/gh.log"
    out=$(GITHUB_CMD=wt-test-no-such-gh GH_CMD=fake-gh-b _w_resolve_pr_url "$url" 2>&1); rc=$?
    assert_exit_code "missing override command returns 2" "2" "$rc"
    assert_contains "missing override command is named" "$out" "wt-test-no-such-gh"
    assert_eq "missing override does not fall through to GH_CMD" "" "$(cat "$bin/gh.log")"

    out=$(GITHUB_CMD=fake-gh-empty _w_resolve_pr_url "$url" 2>&1); rc=$?
    assert_exit_code "empty gh output returns 2" "2" "$rc"
    assert_contains "empty gh output reported" "$out" "Failed to resolve PR URL"
  )

  # plain gh absent from PATH (no external commands are needed before the check)
  local out
  out=$(env -i PATH="$TEST_ROOT/empty-bin" "$(command -v zsh)" -fc "source '$SCRIPT_DIR/../w.zsh'; _w_resolve_pr_url '$url'" 2>&1)
  assert_contains "plain gh missing is reported" "$out" "'gh' not found"

  local repo
  repo=$(setup_repo "gh-override-add")
  (
    cd "$repo"
    unset GITHUB_CMD GH_CMD
    PATH="$bin:$PATH"
    GITHUB_CMD=fake-gh-a worktree add "$url" >/dev/null 2>&1
    assert_dir_exists "w add resolves PR via override" "$TEST_ROOT/gh-override-add-worktrees/branch-a"

    cd "$repo"
    local rc
    GITHUB_CMD=fake-gh-empty worktree add "$url" >/dev/null 2>&1; rc=$?
    assert_exit_code "w add stops on unresolved PR URL" "1" "$rc"
    assert_dir_not_exists "no worktree named after the URL" "$TEST_ROOT/gh-override-add-worktrees/https:"
  )
}

# ── Run all tests ──────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════"
echo "  w.zsh test suite"
echo "═══════════════════════════════════════════════"
echo ""

test_repo_info
test_base_branch
test_add_new_branch
test_add_existing_branch
test_add_already_exists
test_add_no_branch
test_cd
test_ls
test_ls_outside_worktree
test_rm
test_rm_wrong_confirm
test_rm_guess_from_worktree
test_help
test_subcommand_help
test_load_config_profile_matching
test_load_config_first_match_wins
test_load_config_no_match_no_default
test_load_config_missing_file
test_load_config_comments_and_whitespace
test_setup_runs_commands
test_add_from_worktree_uses_base
test_not_in_repo
test_dev_no_config
test_dev_no_tmux
test_shortcut_syntax
test_slash_branches
test_repo_name_from_url
test_clone_bare
test_clone_with_branch
test_clone_no_url
test_clone_already_exists
test_clone_help
test_resolve_branch_url
test_add_branch_tree_url
test_add_slash_branch_tree_url
test_shortcut_tree_url
test_resolve_pr_url
test_add_remote_branch_tracking
test_add_remote_branch_upstream
test_add_remote_branch_message
test_add_pr_url_no_gh
test_shortcut_pr_url_no_gh
test_add_help_pr_url
test_help_pr_url_entry
test_bootstrap_deps
test_dep_dirs_toml
test_setup_skipped_by_default
test_dev_commands_gated
test_dev_guess_from_worktree
test_branch_arg_from_git
test_switch_from_git
test_tmux_exact_match
test_tmux_names
test_tmux_window_names
test_rm_session_override
test_gh_override

# ── Summary ────────────────────────────────────────────────────────

# Recount from results file (subshell-safe)
PASS=0
FAIL=0
ERRORS=()
while IFS= read -r result_line; do
  if [[ "$result_line" == "PASS" ]]; then
    (( PASS++ ))
  elif [[ "$result_line" == FAIL:* ]]; then
    (( FAIL++ ))
    ERRORS+=("${result_line#FAIL:}")
  fi
done < "$RESULTS_FILE"

echo ""
echo "═══════════════════════════════════════════════"
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "═══════════════════════════════════════════════"

if (( FAIL > 0 )); then
  echo ""
  echo "Failures:"
  for err in "${ERRORS[@]}"; do
    echo "  • $err"
  done
  echo ""
  exit 1
fi

echo ""
exit 0
