# tests/shell-under-test.bash: run the code under test in the shell named by TEST_SH.
#
# TEST_SH names the shell that w.sh, install.sh and build-release.sh run under, as a command plus its arguments
# (TEST_SH=dash, TEST_SH="busybox ash", TEST_SH="bash --posix", TEST_SH=/bin/bash). bats itself always runs
# under bash; only the code under test changes shell. `make shells` sets it for each shell in SHELLS.
#
# Unset or empty TEST_SH keeps the plain `make test` behaviour: test-w.bats sources w.sh into bats' own bash,
# and the scripts run under `sh`.
#
#   W_SH        the shell for w.sh subprocesses that the suite starts itself (default bash)
#   SCRIPT_SH   the shell for install.sh and build-release.sh (default sh)
#   w_source    make every w.sh function callable from the test (see below)
#
# shellcheck shell=bash

# shellcheck disable=SC2034 # used by the suites that load this file
W_SH="${TEST_SH:-bash}"
# shellcheck disable=SC2034
SCRIPT_SH="${TEST_SH:-sh}"

# Variables w.sh reads from its environment or keeps between calls; forwarded into the shell under test when set
# in the test, so a plain `VAR=x` (not exported) reaches w.sh as it does when w.sh is sourced into bash.
_wsut_forward_vars() {
  grep -oE '\$\{?[A-Z_][A-Z0-9_]*' "$1" | tr -d '${' | sort -u |
    grep -vxE 'HOME|IFS|IFS_SAVE|PATH|PWD|OLDPWD|_'
}

# Variables w.sh's brace functions set for their caller (W_MAIN_REPO, the W_CFG_* config, ...): copied back
# from the shell under test after each call.
_wsut_result_vars() {
  grep -oE '\bW_[A-Z0-9_]+=' "$1" | tr -d '=' | sort -u
}

# w_source FILE: with TEST_SH empty, source FILE into this bash. Otherwise define, for each function FILE
# defines, a bash function of the same name that runs it in a fresh $TEST_SH which sources FILE, starts in
# this directory, and hands back what the caller of a sourced function would see: the exit status, stdin,
# stdout and stderr (passed straight through), the working directory, and the W_* variables.
w_source() {
  local file=$1 fn
  if [ -z "${TEST_SH:-}" ]; then
    # shellcheck disable=SC1090
    source "$file"
    return
  fi
  WSUT_FILE=$file
  WSUT_FWD=$(_wsut_forward_vars "$file" | tr '\n' ' ')
  WSUT_RES=$(_wsut_result_vars "$file" | tr '\n' ' ')
  for fn in $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*()[[:space:]]*[({].*/\1/p' "$file" | sort -u); do
    eval "$fn() { _wsut_call $fn \"\$@\"; }"
  done
}

_wsut_call() {
  local state rc=0 v
  state=$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR}/wsut.XXXXXX") || return 1
  (
    for v in $WSUT_FWD; do
      [ -n "${!v+x}" ] && export "${v?}"
    done
    # shellcheck disable=SC2086 # TEST_SH is a command plus its arguments
    exec $TEST_SH "$BATS_TEST_DIRNAME/shell-under-test.sh" "$WSUT_FILE" "$state" "$WSUT_RES" "$@"
  ) || rc=$?
  if [ -s "$state" ]; then
    # shellcheck disable=SC1090
    . "$state"
  fi
  rm -f "$state"
  return "$rc"
}
