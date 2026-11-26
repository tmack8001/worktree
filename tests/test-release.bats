#!/usr/bin/env bats
# Tests for scripts/build-release.sh (reproducible release tarball + SHA256SUMS).
# Run: bats tests/test-release.bats
#
# Each test builds from a throwaway fixture repository holding a copy of the
# script, so results do not depend on this checkout's history or state.

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
  export REPO_ROOT
  # Hermetic git: a fixed, obviously fake identity and no system or global
  # config (CI runners have no user.name/user.email; a developer's signing,
  # hooks or defaults must not change the results).
  export GIT_AUTHOR_NAME="worktree test" GIT_AUTHOR_EMAIL="test@example.invalid"
  export GIT_COMMITTER_NAME="worktree test" GIT_COMMITTER_EMAIL="test@example.invalid"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG GIT_CONFIG_SYSTEM
  # Listings are read with GNU tar (gtar on macOS), whose -tv format the
  # tests parse; build-release.sh requires GNU tar anyway.
  GTAR=""
  for t in gtar tar; do
    if command -v "$t" >/dev/null 2>&1 && "$t" --version 2>/dev/null | grep -q 'GNU tar'; then
      GTAR="$(command -v "$t")"; break
    fi
  done
  export GTAR
}

setup() {
  # SCRIPT_SH: the shell under test (TEST_SH, default sh)
  load shell-under-test
  [ -n "$GTAR" ] || { echo "GNU tar (tar or gtar) is required" >&2; return 1; }
  TEST_DIR="$(mktemp -d)"
  TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
  export TEST_DIR
  FIX="$TEST_DIR/fixture"
  mkdir -p "$FIX/scripts"
  cp "$REPO_ROOT/scripts/build-release.sh" "$FIX/scripts/"
  git -C "$FIX" init -q
  printf 'license\n' > "$FIX/LICENSE"
  printf 'readme\n' > "$FIX/README.md"
  printf '#!/bin/sh\necho install\n' > "$FIX/install.sh"
  printf '#!/bin/sh\necho w v1\n' > "$FIX/w.sh"
  printf '#!/usr/bin/env zsh\necho w\n' > "$FIX/w.zsh"
  printf 'not packaged\n' > "$FIX/extra.txt"
  chmod 755 "$FIX/install.sh" "$FIX/w.sh" "$FIX/w.zsh"
  _commit "first" "2026-01-02T03:04:05Z"
  FIRST="$(git -C "$FIX" rev-parse HEAD)"
  printf '#!/bin/sh\necho w v2\n' > "$FIX/w.sh"
  _commit "second" "2026-02-03T04:05:06Z"
  SECOND="$(git -C "$FIX" rev-parse HEAD)"
  export FIX FIRST SECOND
}

teardown() {
  cd "$BATS_TEST_DIRNAME" || return
  rm -rf "$TEST_DIR"
}

# _commit <message> <date>: commit everything with fixed identity and dates,
# independent of the caller's git config (signing, identity).
_commit() {
  git -C "$FIX" add -A
  GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
    git -C "$FIX" -c user.name=test -c user.email=test@example.invalid \
      -c commit.gpgsign=false commit -qm "$1"
}

_build() { # _build <outdir> [<version> [<commit>]]
  $SCRIPT_SH "$FIX/scripts/build-release.sh" "${2:-1.2.3}" "$1" ${3:+"$3"}
}

_sha256_check() { # verify SHA256SUMS inside a dir with whatever tool exists
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$1" && sha256sum -c SHA256SUMS)
  else
    (cd "$1" && shasum -a 256 -c SHA256SUMS)
  fi
}

@test "build-release: two builds give byte-identical outputs" {
  _build "$TEST_DIR/a"
  _build "$TEST_DIR/b"
  cmp "$TEST_DIR/a/worktree-1.2.3.tar.gz" "$TEST_DIR/b/worktree-1.2.3.tar.gz"
  cmp "$TEST_DIR/a/SHA256SUMS" "$TEST_DIR/b/SHA256SUMS"
}

@test "build-release: the umask of the build does not change the bytes" {
  _build "$TEST_DIR/a"
  (umask 077 && _build "$TEST_DIR/b")
  cmp "$TEST_DIR/a/worktree-1.2.3.tar.gz" "$TEST_DIR/b/worktree-1.2.3.tar.gz"
}

@test "build-release: SHA256SUMS verifies and lists the files, tarball last" {
  _build "$TEST_DIR/out"
  run _sha256_check "$TEST_DIR/out"
  [ "$status" -eq 0 ]
  run awk '{print $2}' "$TEST_DIR/out/SHA256SUMS"
  [ "$output" = "$(printf '%s\n' LICENSE README.md install.sh w.sh w.zsh worktree-1.2.3.tar.gz)" ]
  run grep -Evc '^[0-9a-f]{64}  [^ ]+$' "$TEST_DIR/out/SHA256SUMS"
  [ "$output" = "0" ]
}

@test "build-release: SHA256SUMS catches a modified file" {
  _build "$TEST_DIR/out"
  printf 'tampered\n' >> "$TEST_DIR/out/w.sh"
  run _sha256_check "$TEST_DIR/out"
  [ "$status" -ne 0 ]
}

@test "build-release: tarball holds only the release files, root-owned, under worktree-<version>/" {
  _build "$TEST_DIR/out"
  run "$GTAR" -tzf "$TEST_DIR/out/worktree-1.2.3.tar.gz"
  [ "$output" = "$(printf '%s\n' worktree-1.2.3/ worktree-1.2.3/LICENSE worktree-1.2.3/README.md \
    worktree-1.2.3/install.sh worktree-1.2.3/w.sh worktree-1.2.3/w.zsh)" ]
  run "$GTAR" --numeric-owner -tvzf "$TEST_DIR/out/worktree-1.2.3.tar.gz"
  [[ "$output" != *extra.txt* ]]
  while read -r mode owner _; do
    [ "$owner" = "0/0" ]
    case $mode in drwxr-xr-x|-rw-r--r--|-rwxr-xr-x) ;; *) false ;; esac
  done <<< "$output"
}

@test "build-release: default commit is HEAD" {
  run _build "$TEST_DIR/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $SECOND"* ]]
  mkdir "$TEST_DIR/x"
  tar -xzf "$TEST_DIR/out/worktree-1.2.3.tar.gz" -C "$TEST_DIR/x"
  [ "$(cat "$TEST_DIR/x/worktree-1.2.3/w.sh")" = "$(printf '#!/bin/sh\necho w v2')" ]
}

@test "build-release: explicit HEAD commit equals the default build" {
  _build "$TEST_DIR/a"
  _build "$TEST_DIR/b" 1.2.3 "$SECOND"
  cmp "$TEST_DIR/a/worktree-1.2.3.tar.gz" "$TEST_DIR/b/worktree-1.2.3.tar.gz"
}

@test "build-release: a commit argument packages that commit's tree and time" {
  run _build "$TEST_DIR/out" 1.2.3 "$FIRST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $FIRST"* ]]
  mkdir "$TEST_DIR/x"
  tar -xzf "$TEST_DIR/out/worktree-1.2.3.tar.gz" -C "$TEST_DIR/x"
  [ "$(cat "$TEST_DIR/x/worktree-1.2.3/w.sh")" = "$(printf '#!/bin/sh\necho w v1')" ]
  run env TZ=UTC "$GTAR" -tvzf "$TEST_DIR/out/worktree-1.2.3.tar.gz" worktree-1.2.3/w.sh
  [[ "$output" == *"2026-01-02"* ]]
}

@test "build-release: an older commit builds reproducibly too" {
  _build "$TEST_DIR/a" 1.2.3 "$FIRST"
  _build "$TEST_DIR/b" 1.2.3 "$FIRST"
  cmp "$TEST_DIR/a/worktree-1.2.3.tar.gz" "$TEST_DIR/b/worktree-1.2.3.tar.gz"
  _build "$TEST_DIR/c" 1.2.3 "$SECOND"
  run cmp -s "$TEST_DIR/a/worktree-1.2.3.tar.gz" "$TEST_DIR/c/worktree-1.2.3.tar.gz"
  [ "$status" -ne 0 ]
}

@test "build-release: uncommitted changes are never packaged" {
  _build "$TEST_DIR/a"
  printf 'dirty\n' >> "$FIX/w.sh"
  _build "$TEST_DIR/b"
  cmp "$TEST_DIR/a/worktree-1.2.3.tar.gz" "$TEST_DIR/b/worktree-1.2.3.tar.gz"
}

@test "build-release: rejects bad versions" {
  for v in v1.2.3 1.2 1.2.3.4 1.2.3-rc.1 1.2.3+meta 01.2.3 x.y.z ""; do
    run $SCRIPT_SH "$FIX/scripts/build-release.sh" "$v" "$TEST_DIR/out"
    [ "$status" -eq 1 ] || { echo "accepted '$v'"; false; }
  done
  [ ! -e "$TEST_DIR/out/SHA256SUMS" ]
}

@test "build-release: wrong argument count is a usage error" {
  run $SCRIPT_SH "$FIX/scripts/build-release.sh" 1.2.3
  [ "$status" -eq 2 ]
  run $SCRIPT_SH "$FIX/scripts/build-release.sh" 1.2.3 "$TEST_DIR/out" HEAD extra
  [ "$status" -eq 2 ]
}

@test "build-release: rejects a commit missing a release file" {
  git -C "$FIX" rm -q LICENSE
  _commit "drop license" "2026-03-04T05:06:07Z"
  run _build "$TEST_DIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing"*"LICENSE"* ]]
  [ ! -e "$TEST_DIR/out/worktree-1.2.3.tar.gz" ]
}

@test "build-release: a release file that is a symlink is rejected" {
  rm "$FIX/README.md"
  ln -s LICENSE "$FIX/README.md"
  _commit "symlink readme" "2026-03-04T05:06:07Z"
  run _build "$TEST_DIR/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md is not a regular file"* ]]
}

@test "build-release: rejects an unknown or malformed commit" {
  run _build "$TEST_DIR/out" 1.2.3 0123456789012345678901234567890123456789
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
  run _build "$TEST_DIR/out" 1.2.3 "--output=/tmp/x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid commit"* ]]
}

@test "build-release: refuses the repository root as outdir" {
  run _build "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not be the repository root"* ]]
}

@test "build-release: builds this checkout's HEAD" {
  if ! git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD >/dev/null; then
    skip "not a git checkout"
  fi
  run $SCRIPT_SH "$REPO_ROOT/scripts/build-release.sh" 0.0.0 "$TEST_DIR/self"
  [ "$status" -eq 0 ]
  run _sha256_check "$TEST_DIR/self"
  [ "$status" -eq 0 ]
}
