#!/usr/bin/env bats
# Test suite for install.sh
# Run: bats tests/test-install.bats
#      make test
#
# Every test runs with a throwaway HOME and a fake curl on PATH, so nothing
# is downloaded and the real home directory is never touched.

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
  export REPO_ROOT
}

setup() {
  # SCRIPT_SH: the shell under test (TEST_SH, default sh)
  load shell-under-test
  TEST_DIR="$(mktemp -d)"
  TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
  export TEST_DIR

  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"
  unset ZDOTDIR WORKTREE_REF

  # Fake curl: records the URL and writes a recognisable file.
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/curl" <<FAKE
#!/bin/sh
out=""
url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *)  url="\$1"; shift ;;
  esac
done
printf '%s\n' "\$url" >> "$TEST_DIR/curl.log"
printf '# downloaded from %s\n' "\$url" > "\$out"
FAKE
  chmod +x "$TEST_DIR/bin/curl"
  export PATH="$TEST_DIR/bin:$PATH"

  # A directory that looks like a checkout but is NOT the installer's own:
  # piped installs must never copy from here.
  mkdir -p "$TEST_DIR/cwd"
  echo '# planted w.zsh' > "$TEST_DIR/cwd/w.zsh"
  echo '# planted w.sh'  > "$TEST_DIR/cwd/w.sh"

  PREFIX="$TEST_DIR/prefix"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# Simulate `curl .../install.sh | sh`: $0 is the shell, cwd is untrusted.
piped_install() {
  (cd "$TEST_DIR/cwd" && $SCRIPT_SH -s -- --prefix "$PREFIX" "$@" < "$REPO_ROOT/install.sh")
}

# ── source selection ───────────────────────────────────────────────

@test "install (piped): does not copy w.sh from the current directory" {
  SHELL=/bin/bash run piped_install
  [ "$status" -eq 0 ]
  [ -f "$PREFIX/w.sh" ]
  run grep -c 'planted' "$PREFIX/w.sh"
  [ "$output" = "0" ]
  grep -q '^# downloaded from ' "$PREFIX/w.sh"
}

@test "install (piped): does not copy w.zsh from the current directory" {
  SHELL=/usr/bin/zsh run piped_install
  [ "$status" -eq 0 ]
  [ -f "$PREFIX/w.zsh" ]
  run grep -c 'planted' "$PREFIX/w.zsh"
  [ "$output" = "0" ]
}

@test "install (piped): even an install.sh in cwd is not treated as a clone" {
  cp "$REPO_ROOT/install.sh" "$TEST_DIR/cwd/install.sh"
  SHELL=/bin/bash run piped_install
  [ "$status" -eq 0 ]
  grep -q '^# downloaded from ' "$PREFIX/w.sh"
}

@test "install (clone): copies the variant next to install.sh, from any cwd" {
  cd "$TEST_DIR/cwd"
  SHELL=/bin/bash run $SCRIPT_SH "$REPO_ROOT/install.sh" --prefix "$PREFIX"
  [ "$status" -eq 0 ]
  cmp -s "$REPO_ROOT/w.sh" "$PREFIX/w.sh"
  [ ! -s "$TEST_DIR/curl.log" ]
  [[ "$output" == *"(local clone)"* ]]
}

@test "install (clone): --remote downloads instead of copying" {
  cd "$TEST_DIR/cwd"
  SHELL=/bin/bash run $SCRIPT_SH "$REPO_ROOT/install.sh" --prefix "$PREFIX" --remote
  [ "$status" -eq 0 ]
  grep -q '^# downloaded from ' "$PREFIX/w.sh"
}

@test "install (piped): a failed download leaves nothing installed" {
  printf '#!/bin/sh\nexit 22\n' > "$TEST_DIR/bin/curl"
  SHELL=/bin/bash run piped_install
  [ "$status" -ne 0 ]
  [ ! -e "$PREFIX/w.sh" ]
  run find "$PREFIX" -name '*.download.*'
  [ -z "$output" ]
  [ ! -e "$HOME/.bashrc" ]
}

@test "install (piped): an empty download is rejected" {
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && : > "$2"; shift; done\n' > "$TEST_DIR/bin/curl"
  SHELL=/bin/bash run piped_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"was empty"* ]]
  [ ! -e "$PREFIX/w.sh" ]
}

# ── pinned ref ─────────────────────────────────────────────────────

@test "install: downloads from the pinned release tag, not main" {
  SHELL=/bin/bash run piped_install
  [ "$status" -eq 0 ]
  url=$(cat "$TEST_DIR/curl.log")
  [ "$url" = "https://raw.githubusercontent.com/tmack8001/worktree/v0.1.1/w.sh" ]
}

@test "install: --ref overrides the pinned ref" {
  SHELL=/bin/bash run piped_install --ref main
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/curl.log")" = "https://raw.githubusercontent.com/tmack8001/worktree/main/w.sh" ]
}

@test "install: WORKTREE_REF overrides the pinned ref" {
  WORKTREE_REF=v9.9.9 SHELL=/bin/bash run piped_install
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/curl.log")" = "https://raw.githubusercontent.com/tmack8001/worktree/v9.9.9/w.sh" ]
}

@test "install: --ref wins over WORKTREE_REF" {
  WORKTREE_REF=v9.9.9 SHELL=/bin/bash run piped_install --ref feature/x
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/curl.log")" = "https://raw.githubusercontent.com/tmack8001/worktree/feature/x/w.sh" ]
}

@test "install: rejects a ref with unsafe characters" {
  for ref in 'v1;rm' '../x' '-v' 'a b' 'a?b'; do
    SHELL=/bin/bash run piped_install --ref "$ref"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid ref"* ]]
  done
  [ ! -e "$TEST_DIR/curl.log" ]
}

@test "install: --ref without a value is an error" {
  SHELL=/bin/bash run piped_install --ref
  [ "$status" -eq 1 ]
  [[ "$output" == *"--ref requires a value"* ]]
}

@test "install: --prefix without a value is an error" {
  cd "$TEST_DIR/cwd"
  SHELL=/bin/bash run $SCRIPT_SH "$REPO_ROOT/install.sh" --prefix
  [ "$status" -eq 1 ]
  [[ "$output" == *"--prefix requires a value"* ]]
}

@test "install: unknown option is an error" {
  SHELL=/bin/bash run piped_install --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: --bogus"* ]]
}

# ── shell detection ────────────────────────────────────────────────

@test "install: zsh login shell gets w.zsh and ~/.zshrc" {
  SHELL=/usr/bin/zsh run piped_install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"variant : zsh"* ]]
  [[ "$output" == *"rc file : $HOME/.zshrc"* ]]
}

@test "install: bash login shell gets w.sh even when zsh is installed" {
  printf '#!/bin/sh\n' > "$TEST_DIR/bin/zsh"; chmod +x "$TEST_DIR/bin/zsh"
  SHELL=/bin/bash run piped_install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"variant : sh"* ]]
  [[ "$output" == *"rc file : $HOME/.bashrc"* ]]
}

@test "install: bash uses ~/.bash_profile when only that exists" {
  : > "$HOME/.bash_profile"
  SHELL=/bin/bash run piped_install --dry-run
  [[ "$output" == *"rc file : $HOME/.bash_profile"* ]]
}

@test "install: other login shells get w.sh and ~/.profile" {
  : > "$HOME/.bashrc"   # a stray .bashrc must not be picked for dash
  SHELL=/bin/dash run piped_install --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"variant : sh"* ]]
  [[ "$output" == *"rc file : $HOME/.profile"* ]]
}

@test "install: unset SHELL falls back to the sh variant" {
  run env -u SHELL HOME="$HOME" PATH="$PATH" sh -c "cd '$TEST_DIR/cwd' && $SCRIPT_SH -s -- --prefix '$PREFIX' --dry-run < '$REPO_ROOT/install.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"variant : sh"* ]]
}

@test "install: --zsh overrides a bash login shell" {
  SHELL=/bin/bash run piped_install --zsh --dry-run
  [[ "$output" == *"variant : zsh"* ]]
}

@test "install: ZDOTDIR is honoured for zsh" {
  mkdir -p "$TEST_DIR/zdot"
  ZDOTDIR="$TEST_DIR/zdot" SHELL=/usr/bin/zsh run piped_install --dry-run
  [[ "$output" == *"rc file : $TEST_DIR/zdot/.zshrc"* ]]
}

# ── rc file ────────────────────────────────────────────────────────

@test "install: --dry-run changes nothing" {
  SHELL=/bin/bash run piped_install --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$PREFIX" ]
  [ ! -e "$HOME/.bashrc" ]
  [ ! -e "$TEST_DIR/curl.log" ]
}

@test "install: adds the source line once" {
  SHELL=/bin/bash piped_install >/dev/null
  SHELL=/bin/bash piped_install >/dev/null
  run grep -c "$PREFIX/w.sh" "$HOME/.bashrc"
  [ "$output" = "1" ]
}

@test "install: --no-aliases writes the WORKTREE_NO_ALIASES source line" {
  SHELL=/bin/bash piped_install --no-aliases >/dev/null
  grep -qF "WORKTREE_NO_ALIASES=1 . \"$PREFIX/w.sh\"" "$HOME/.bashrc"
}
