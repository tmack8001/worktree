#!/bin/sh
# build-tmux.sh VERSION SHA256 OUTDIR: download the tmux VERSION release tarball from GitHub, check its
# SHA-256, build it, and copy the binary to OUTDIR/tmux. CI uses it for tmux versions no package manager on
# the runners ships (the supported floor). Needs curl, a C compiler, make, and the libevent and ncurses
# headers (apt: libevent-dev libncurses-dev).
#
# The CFLAGS let old releases build with a current GCC (-fcommon: GCC 10 made -fno-common the default;
# -std=gnu99 and -w: newer C defaults and warnings that old sources trip over).
set -eu

[ $# -eq 3 ] || { echo "usage: $0 VERSION SHA256 OUTDIR" >&2; exit 2; }
version=$1 sum=$2 out=$3
case "$version" in *[!0-9a-z.]*|'') echo "build-tmux: bad version: $version" >&2; exit 2 ;; esac
case "$sum" in *[!0-9a-f]*|'') echo "build-tmux: bad sha256: $sum" >&2; exit 2 ;; esac
[ "${#sum}" -eq 64 ] || { echo "build-tmux: bad sha256: $sum" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/build-tmux.XXXXXX")
[ -n "$work" ] && [ -d "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
tarball="$work/tmux-$version.tar.gz"
curl -fsSL --retry 3 -o "$tarball" "https://github.com/tmux/tmux/releases/download/$version/tmux-$version.tar.gz"

if command -v sha256sum >/dev/null 2>&1; then have=$(sha256sum "$tarball")
else have=$(shasum -a 256 "$tarball"); fi
have=${have%% *}
[ "$have" = "$sum" ] || { echo "build-tmux: tmux-$version.tar.gz has sha256 $have, expected $sum" >&2; exit 1; }

tar -xzf "$tarball" -C "$work"
(
  cd "$work/tmux-$version"
  CFLAGS="-O1 -w -fcommon -std=gnu99" ./configure >"$work/configure.log" 2>&1 || { cat "$work/configure.log" >&2; exit 1; }
  make -j4 >"$work/make.log" 2>&1 || { tail -n 50 "$work/make.log" >&2; exit 1; }
)
mkdir -p "$out"
cp "$work/tmux-$version/tmux" "$out/tmux"
"$out/tmux" -V
