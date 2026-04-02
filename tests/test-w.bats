#!/usr/bin/env bats
# Test suite for w.sh (POSIX sh variant)
# Run: bats tests/test-w.bats
#      make test

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
  export REPO_ROOT
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
}

teardown() {
  rm -rf "$TEST_DIR"
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

@test "w add: runs setup commands from .worktree.toml" {
  cat > "$REPO/.worktree.toml" <<'TOML'
[profile.default]
branches = "*"

[[profile.default.setup]]
run = "touch .setup-marker"
TOML
  cd "$REPO"
  worktree add setup-test 2>/dev/null
  [ -f "$WTS/setup-test/.setup-marker" ]
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
  run bash -c "source '$REPO_ROOT/w.sh' && cd '$WTS/tmux-test' && PATH=/usr/bin:/bin worktree dev 2>&1"
  [[ "$output" == *"tmux not installed"* || "$output" == *"Starting dev session"* ]]
}

# ── worktree outside a repo ────────────────────────────────────────

@test "w add: errors outside a git repo" {
  cd "$TEST_DIR"
  run worktree add test
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not in a git repository"* ]]
}

@test "w (bare): falls back gracefully outside a git repo" {
  run bash -c "source '$REPO_ROOT/w.sh' && cd '$TEST_DIR' && PATH=/usr/bin:/bin worktree 2>&1"
  [[ "$output" != *"Not in a git repository"* ]]
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

@test "w help: shows usage" {
  run worktree help
  [[ "$output" == *"git worktree helper"* ]]
  [[ "$output" == *"worktree dev"* ]]
  [[ "$output" == *"worktree clone"* ]]
  [[ "$output" == *"w, wt"* ]]
}

@test "w add --help: shows subcommand help" {
  run worktree add --help
  [[ "$output" == *"Create a new worktree"* ]]
}

@test "w rm --help: shows subcommand help" {
  run worktree rm --help
  [[ "$output" == *"Remove a worktree"* ]]
}

@test "w dev --help: shows subcommand help" {
  run worktree dev --help
  [[ "$output" == *"Launch a tmux dev session"* ]]
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
