#!/bin/sh
# build-release.sh — build the reproducible worktree release assets.
#
# Usage: sh scripts/build-release.sh <version> <outdir> [<commit>]
#
#   <version>  X.Y.Z, without the leading "v" (the tag is v<version>, the asset is not)
#   <outdir>   created if missing; must not be the repository or contain it
#   <commit>   the commit whose tree is packaged (default: HEAD). The files come from
#              that commit with `git archive`, never from the working tree, so a dirty
#              checkout cannot leak into a release, and this script (from the current
#              checkout) can package an older commit.
#
# Writes into <outdir>:
#   worktree-<version>.tar.gz  every path under worktree-<version>/
#   SHA256SUMS                 coreutils format "<sha256>  <path>": the packaged files by
#                              repo-relative path, then the tarball line last
#   + a copy of each packaged file at its repo-relative path, so that
#     `cd <outdir> && sha256sum -c SHA256SUMS` passes. Only the tarball and SHA256SUMS
#     are published.
#
# Reproducibility: the file list is fixed and sorted (C locale), GNU tar writes ustar with
# --sort=name, every mtime is the commit time of <commit> (SOURCE_DATE_EPOCH overrides),
# owner and group 0, modes normalised (644, or 755 where the tree has the execute bit),
# and `gzip -n` leaves out the name and time. The same commit, GNU tar and gzip give the
# same bytes (tests/test-release.bats builds twice and compares).
#
# Environment:
#   SOURCE_DATE_EPOCH  override the fixed mtime (digits)
#   TAR                tar command (default: the first GNU tar on PATH, tar or gtar)
#
# gzip is the first gzip executable on PATH. GNU gzip is what the release workflow uses (ubuntu);
# another gzip (Apple's, busybox's) gives a valid archive with different bytes.
#
# Exit: 0 ok, 1 build error, 2 usage.

set -eu

usage() { echo "usage: build-release.sh <version> <outdir> [<commit>]" >&2; exit 2; }
die() { echo "build-release.sh: $*" >&2; exit 1; }

[ $# -eq 2 ] || [ $# -eq 3 ] || usage
VERSION=$1
OUTDIR=$2
COMMIT_ARG=${3:-HEAD}
[ -n "$OUTDIR" ] || usage

case $VERSION in
  v*) die "version '$VERSION' must not start with 'v' (the tag is v<version>, the asset is not)" ;;
esac
printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  || die "version '$VERSION' is not X.Y.Z"

# The files a release contains, repo-relative, already in C-locale order.
FILES="LICENSE README.md install.sh w.sh w.zsh"

ROOT=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P) || die "cannot resolve repository root"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git repository"

case $COMMIT_ARG in
  -*|*[!A-Za-z0-9._/^~-]*) die "invalid commit '$COMMIT_ARG'" ;;
esac
COMMIT=$(git -C "$ROOT" rev-parse --verify --quiet "$COMMIT_ARG^{commit}") \
  || die "commit '$COMMIT_ARG' not found"

# --- GNU tar ----------------------------------------------------------------
# Walk PATH for an executable GNU tar (`command -v tar` can be a busybox applet or bsdtar).
find_gnu_tar() {
  _oifs=$IFS; IFS=:
  set -f
  # shellcheck disable=SC2086 # split PATH on ':' on purpose
  set -- $PATH
  set +f
  IFS=$_oifs
  for _d in "$@"; do
    [ -n "$_d" ] || continue
    for _n in tar gtar; do
      if [ -x "$_d/$_n" ] && [ ! -d "$_d/$_n" ] && "$_d/$_n" --version 2>/dev/null | grep -q 'GNU tar'; then
        printf '%s\n' "$_d/$_n"; return 0
      fi
    done
  done
  return 1
}
TARBIN=${TAR:-}
if [ -z "$TARBIN" ]; then
  TARBIN=$(find_gnu_tar) || die "GNU tar is required for deterministic archives (none on PATH; on macOS: brew install gnu-tar)"
fi
"$TARBIN" --version 2>/dev/null | grep -q 'GNU tar' || die "'$TARBIN' is not GNU tar"

# gzip: the first executable on PATH, never a shell's builtin applet (busybox ash would run its
# own gzip, whose output differs from GNU gzip's).
find_gzip() {
  _oifs=$IFS; IFS=:
  set -f
  # shellcheck disable=SC2086 # split PATH on ':' on purpose
  set -- $PATH
  set +f
  IFS=$_oifs
  for _d in "$@"; do
    if [ -n "$_d" ] && [ -x "$_d/gzip" ] && [ ! -d "$_d/gzip" ]; then
      printf '%s\n' "$_d/gzip"; return 0
    fi
  done
  return 1
}
GZIPBIN=$(find_gzip) || die "gzip not found on PATH"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else die "no sha256 tool found (need sha256sum, shasum or openssl)"; fi
}

# --- inputs: every file must be a regular file (blob, not symlink) in the commit --
missing=""
for f in $FILES; do
  mode=$(git -C "$ROOT" ls-tree "$COMMIT" -- "$f" | awk '{print $1; exit}')
  case $mode in
    100644|100755) ;;
    "") missing="$missing $f" ;;
    *) die "$f is not a regular file in $COMMIT (mode $mode)" ;;
  esac
done
[ -z "$missing" ] || die "missing in commit $COMMIT:$missing"

# --- timestamp --------------------------------------------------------------
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  case $SOURCE_DATE_EPOCH in ''|*[!0-9]*) die "SOURCE_DATE_EPOCH must be digits, got '$SOURCE_DATE_EPOCH'" ;; esac
  EPOCH=$SOURCE_DATE_EPOCH
else
  EPOCH=$(git -C "$ROOT" log -1 --format=%ct "$COMMIT") || die "cannot read the commit time of $COMMIT"
fi

# --- output dir -------------------------------------------------------------
mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
OUT=$(CDPATH='' cd -P -- "$OUTDIR" && pwd -P) || die "cannot enter $OUTDIR"
[ "$OUT" != "$ROOT" ] || die "outdir must not be the repository root"
case "$ROOT/" in "$OUT"/*) die "outdir must not contain the repository" ;; esac

NAME="worktree-$VERSION"
TARBALL="$NAME.tar.gz"
rm -f "$OUT/$TARBALL" "$OUT/SHA256SUMS"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/worktree-release.XXXXXX") || die "cannot create a temp dir"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
mkdir "$WORK/$NAME"

# --- stage the commit's files -------------------------------------------------
# shellcheck disable=SC2086 # FILES is a fixed list of plain names
git -C "$ROOT" archive --format=tar "$COMMIT" -- $FILES | "$TARBIN" -xf - -C "$WORK/$NAME" \
  || die "cannot export the files of $COMMIT"
for f in $FILES; do
  [ -f "$WORK/$NAME/$f" ] || die "$f was not exported from $COMMIT"
done

# --- tarball ----------------------------------------------------------------
# Modes: u+rw, go+r, go-w; X keeps execute only where the owner has it, so a checkout
# under umask 077 or 002 packs identically.
(
  cd "$WORK"
  # shellcheck disable=SC2086 # FILES is a fixed list of plain names
  for f in $FILES; do printf '%s/%s\n' "$NAME" "$f"; done | LC_ALL=C sort > list
  printf '%s\n' "$NAME" | cat - list > list.all
  LC_ALL=C "$TARBIN" -cf - \
    --format=ustar --sort=name --no-recursion \
    --mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner \
    --mode='u+rw,go+rX,go-w' \
    -T list.all
) | "$GZIPBIN" -n -9 > "$OUT/$TARBALL" || die "tar/gzip failed"

# --- staged copies + SHA256SUMS ------------------------------------------------
{
  for f in $FILES; do
    cp "$WORK/$NAME/$f" "$OUT/$f"
    printf '%s  %s\n' "$(sha256_of "$WORK/$NAME/$f")" "$f"
  done
  printf '%s  %s\n' "$(sha256_of "$OUT/$TARBALL")" "$TARBALL"
} > "$OUT/SHA256SUMS"

echo "built $OUT/$TARBALL from $COMMIT (mtime $EPOCH)"
grep "  $TARBALL\$" "$OUT/SHA256SUMS"
