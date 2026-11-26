# tests/shell-under-test.sh: run one function of a sourced file in the shell under test (see
# shell-under-test.bash). Run as: $TEST_SH shell-under-test.sh FILE STATE VARS FUNCTION [ARG...]
# Sources FILE, calls FUNCTION ARG..., then writes to STATE a script that `cd`s to the final working directory
# and sets each variable named in VARS (space separated) that is set, quoted for any shell. Exits with
# FUNCTION's status. POSIX sh only: this runs under every shell in the matrix.

_wsut_file=$1 _wsut_state=$2 _wsut_vars=$3
shift 3

# shellcheck disable=SC1090
. "$_wsut_file"

_wsut_rc=0
"$@" || _wsut_rc=$?

# Print $1 single-quoted; embedded newlines are kept as they are.
_wsut_q() {
  _wsut_r='' _wsut_s=$1
  while :; do
    case $_wsut_s in
      *\'*) _wsut_r="$_wsut_r${_wsut_s%%\'*}'\\''"; _wsut_s=${_wsut_s#*\'} ;;
      *) break ;;
    esac
  done
  printf "'%s%s'" "$_wsut_r" "$_wsut_s"
}

{
  printf 'cd -- '; _wsut_q "$PWD"; printf '\n'
  for _wsut_v in $_wsut_vars; do
    eval "[ -n \"\${$_wsut_v+x}\" ]" || continue
    _wsut_val=; eval "_wsut_val=\$$_wsut_v"
    printf '%s=' "$_wsut_v"; _wsut_q "$_wsut_val"; printf '\n'
  done
} > "$_wsut_state"

exit "$_wsut_rc"
