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

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

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
    w add setup-test >/dev/null 2>&1
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

    # Temporarily hide tmux from PATH
    local output
    output=$(PATH="/usr/bin:/bin" w dev 2>&1)
    if [[ "$output" == *"tmux not installed"* || "$output" == *"Starting dev session"* ]]; then
      # Either tmux isn't available (expected) or it is (also fine)
      pass "dev handles tmux availability correctly"
    else
      fail "dev unexpected output: $output"
    fi
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
