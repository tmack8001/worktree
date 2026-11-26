#!/usr/bin/env zsh
# worktree — git worktree helper (zsh)
# Worktrees go in ../<repo-name>-worktrees/<branch>
#
# Usage:
#   worktree clone <repo> [branch]  clone a repo headless & optionally add worktree
#   worktree add <branch>           create worktree & cd into it
#   worktree <branch>               cd into worktree or create it
#   worktree <pr-url>               resolve GH PR URL to branch, then add/cd
#   worktree <tree-url>             resolve GH branch tree URL, then add/cd
#   worktree rm  [<branch>]         remove worktree
#   worktree ls  [--all]            list worktrees
#   worktree cd  <branch>           cd into existing worktree
#   worktree dev [<branch>]         launch tmux dev session from .worktree.toml
#   worktree                        interactive switcher (fzf, current repo)
#   worktree --all                  interactive switcher (fzf, all repos)
#
# Aliases w and wt are set up by default. Set WORKTREE_NO_ALIASES=1 to skip.
#
# Config-driven scaffolding:
#   Place a .worktree.toml in your repo root to define post-creation
#   hooks and tmux dev sessions. See 'worktree dev --help' for details.
#   The config can be .gitignored (personal) or committed (team).

_w_repo_info() {
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || {
    toplevel=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    toplevel="${toplevel%/.git}"
  }

  if [[ -z "$toplevel" ]]; then
    echo "Not in a git repository" >&2
    return 1
  fi

  local common_dir
  common_dir=$(git -C "$toplevel" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [[ "$common_dir" == */.git ]]; then
    W_MAIN_REPO="${common_dir%/.git}"
  else
    W_MAIN_REPO="$toplevel"
  fi

  local repo_name="${W_MAIN_REPO:t}"
  W_WORKTREES_DIR="${W_MAIN_REPO:h}/${repo_name}-worktrees"
}

# ── Helpers ────────────────────────────────────────────────────────

# Extract repo name from a git URL
# git@github.com:owner/repo.git → repo
# https://github.com/owner/repo.git → repo
_w_repo_name_from_url() {
  local url="$1"
  local name="${url:t}"       # basename
  name="${name%.git}"         # strip .git suffix
  echo "$name"
}

# Return the last two path segments: parent/name
_w_short_path() { printf '%s/%s' "${1:h:t}" "${1:t}" }

# Strip leading and trailing whitespace
_w_trim() { local s="$1"; s="${s#"${s%%[! 	]*}"}"; s="${s%"${s##*[! 	]}"}"; echo "$s"; }

# Print the top directory of the worktree containing the current directory,
# if that worktree lives under the worktrees dir $1; fail otherwise.
_w_current_worktree_path() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ "$top" == "$1"/?* ]] || return 1
  printf '%s' "$top"
}

# Print the branch checked out in worktree $1, as git records it (so a branch
# with slashes is kept whole). Fail when HEAD is detached or not a branch.
_w_worktree_branch() {
  local ref
  ref=$(git -C "$1" symbolic-ref -q HEAD 2>/dev/null) || return 1
  [[ "$ref" == refs/heads/?* ]] || return 1
  printf '%s' "${ref#refs/heads/}"
}

# Print the worktree that has branch $2 checked out, as git records it in
# `git worktree list --porcelain` for repo $1 (never a path built from the
# branch name: a worktree's directory need not match its branch). The path is
# checked to be a worktree of the same repository with that branch checked
# out, and printed physical (symlinks resolved).
# Fails with 1 when no worktree has the branch, with 2 (printing its path)
# when only the main working tree has it, and with 3 (printing the path git
# records) when git lists the branch in a worktree that is missing or fails
# those checks (e.g. a deleted directory not yet pruned).
_w_branch_worktree_path() {
  local repo="$1" branch="$2" wt top common rc=0
  wt=$(git -C "$repo" worktree list --porcelain 2>/dev/null | W_REF="refs/heads/$branch" awk '
    /^worktree / { wt = substr($0, 10); n++; next }
    $0 == "branch " ENVIRON["W_REF"] { print wt; rc = (n == 1) ? 2 : 0; found = 1; exit }
    END { if (!found) exit 1; exit rc }') || rc=$?
  (( rc == 0 )) || { printf '%s' "$wt"; return $rc; }
  [[ -n "$wt" && -d "$wt" ]] || { printf '%s' "$wt"; return 3; }
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || { printf '%s' "$wt"; return 3; }
  [[ "$(cd "$top" && pwd -P)" == "$(cd "$wt" && pwd -P)" ]] || { printf '%s' "$wt"; return 3; }
  [[ "$(_w_worktree_branch "$wt")" == "$branch" ]] || { printf '%s' "$wt"; return 3; }
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { printf '%s' "$wt"; return 3; }
  [[ "$(cd "$common" && pwd -P)" == "$(cd "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)" ]] || { printf '%s' "$wt"; return 3; }
  (cd "$wt" && pwd -P)
}

# Find the worktree for an EXISTING checkout of branch $2 in repo $1, for
# commands that switch to it (w cd, w <branch>, w add). Prints the directory
# and succeeds when git has the branch checked out in a worktree or in the
# main working tree (saying so for the latter). Fails with 1, printing
# nothing, when no worktree has it (the caller may then create one), and with
# 3 after printing why to stderr when git lists it somewhere unusable.
_w_switch_target() {
  local dest rc=0
  dest=$(_w_branch_worktree_path "$1" "$2") || rc=$?
  case $rc in
    0) printf '%s' "$dest" ;;
    2) if [[ -d "$dest" ]]; then
         echo "↩️  Branch '$2' is checked out in the main working tree — switching to $dest" >&2
         printf '%s' "$dest"
       else
         echo "Branch '$2' is checked out in the main working tree ($dest), which is not a directory" >&2
         return 3
       fi ;;
    1) return 1 ;;
    *) echo "git lists branch '$2' as checked out in $dest, which is not a usable worktree of this repository (see: git worktree list; git worktree prune)" >&2
       return 3 ;;
  esac
}

# ── tmux session names ─────────────────────────────────────────────
#
# tmux does not store every session name as given, and how depends on the
# version (checked with tmux 2.1, 2.6, 2.9a, 3.0a, 3.2a, 3.3a, 3.4, 3.5a and
# 3.8): '.' and ':' are refused (2.1 to 3.0a), stored as '_' (3.2a to 3.5a)
# or kept (3.8), and in a target they split the session from the window and
# pane; '\', '$', control and non-ASCII bytes are escaped or replaced; '#'
# starts a format that new-session expands (2.9a on, not 2.6: `#S`, `#{...}`,
# `##`; 3.8 also drops a trailing '#'); and an argument ending in ';' is a
# command separator. A target like `=repo-v1.2` can then name no session, so
# the name used for new-session and every later target must be one tmux
# stores unchanged. _w_tmux_name makes it one: every byte that is not
# printable ASCII, or is one of . : \ $ # ;, becomes '_'.
# (tr on bytes, as in w.sh, so both variants give the same name.)

_w_tmux_name() {
  printf '%s' "$1" | LC_ALL=C tr -c '\040-\042\045-\055\057-\071\074-\133\135-\176' '_'
}

# A directory for tmux's -c, which tmux expands as a format (every version
# checked: `#S`, `#{...}`, `##`) and, ending in ';', takes as a command
# separator: '#' is doubled, and a trailing ';' gets a '/' after it.
_w_tmux_dir() {
  local d="${1//\#/##}"
  [[ "$d" == *\; ]] && d="$d/"
  printf '%s' "$d"
}

# The tmux session for a worktree: the profile's `session` override if given,
# else <repo basename>-<branch with / as ->, made tmux-safe.
_w_session_name() {
  local repo="$1" branch="$2" name="${3:-}"
  [[ -n "$name" ]] || name="${repo:t}-${branch//\//-}"
  _w_tmux_name "$name"
}

# The session `w dev` uses for branch $2 of repo $1: the `session` of the
# profile .worktree.toml matches for the branch (the same lookup as w dev),
# else the default. w dev and w rm both use this, so w rm kills the session
# w dev made. Runs in a subshell so the caller's loaded config is untouched.
_w_profile_session_name() {
  (
    _w_load_config "$1/.worktree.toml" "$2" >/dev/null 2>&1 || W_PROFILE=()
    _w_session_name "$1" "$2" "${W_PROFILE[session]:-}"
  )
}

# ── GitHub URL resolution ──────────────────────────────────────────

# Detect if a string is a GitHub branch tree URL and extract the branch name.
# Supports:
#   https://github.com/owner/repo/tree/<branch>
#   With or without trailing slash; branch may contain slashes (e.g. feat/foo)
# Returns 0 and prints the branch name on success, returns 1 if not a tree URL.
_w_resolve_branch_url() {
  local input="$1"

  # Match https://github.com/<owner>/<repo>/tree/<branch>
  if [[ "$input" =~ '^https?://github\.com/[^/]+/[^/]+/tree/(.+)$' ]]; then
    local branch="${match[1]}"
    # strip trailing slash if present
    branch="${branch%/}"
    if [[ -n "$branch" ]]; then
      echo "$branch"
      return 0
    fi
  fi

  return 1
}

# Detect if a string is a GitHub PR URL and resolve it to a branch name.
# Supports:
#   https://github.com/owner/repo/pull/123
#   https://github.com/owner/repo/pulls/123
#   With or without trailing slash
# Returns 0 and prints the branch name on success, 1 if not a PR URL, and
# 2 if it is a PR URL but gh is missing or could not resolve it.
#
# gh is invoked as "${GITHUB_CMD:-${GH_CMD:-gh}}" (GITHUB_CMD, else GH_CMD,
# else plain gh; an empty value counts as unset). The value is a command line
# and is split into words, so GITHUB_CMD="ghid --some-flag" works.
_w_gh_cmd() {
  print -rn -- "${GITHUB_CMD:-${GH_CMD:-gh}}"
}

_w_resolve_pr_url() {
  local input="$1"

  # Match GitHub PR URL patterns
  if [[ "$input" =~ '^https?://github\.com/[^/]+/[^/]+/pulls?/[0-9]+/?$' ]]; then
    # Normalize: strip trailing slash, fix /pulls/ to /pull/
    local url="${input%/}"
    url="${url/\/pulls\///pull/}"

    # owner/repo from the URL, passed as an explicit -R so an
    # identity-selecting wrapper (GITHUB_CMD / GH_CMD) is deterministic.
    local slug="${url#*://github.com/}"
    local owner="${slug%%/*}"
    slug="${slug#*/}"
    local name="${slug%%/*}"

    # The gh command line: GITHUB_CMD, else GH_CMD, else gh (split on spaces)
    local gh_cmd
    gh_cmd=$(_w_gh_cmd)
    local -a gh_argv
    gh_argv=(${=gh_cmd})
    if (( ${#gh_argv} == 0 )) || ! command -v "${gh_argv[1]}" &>/dev/null; then
      echo "gh CLI not installed — '${gh_argv[1]:-gh}' not found. Install gh (brew install gh) or set GITHUB_CMD / GH_CMD" >&2
      return 2
    fi

    local branch
    branch=$("${gh_argv[@]}" pr view "$url" -R "$owner/$name" --json headRefName --jq '.headRefName' 2>/dev/null)
    if [[ -z "$branch" ]]; then
      echo "Failed to resolve PR URL: $url" >&2
      return 2
    fi

    echo "$branch"
    return 0
  fi

  return 1
}

# ── Base branch resolution ─────────────────────────────────────────

# Resolve the base branch for new worktrees. Priority:
#   1. base_branch from .worktree.toml (top-level, outside profiles)
#   2. origin HEAD (git remote show origin)
#   3. main, then master (first that exists locally)
_w_base_branch() {
  local repo="$1"
  local config_file="$repo/.worktree.toml"

  # Check .worktree.toml for top-level base_branch
  if [[ -f "$config_file" ]]; then
    local line
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[! ]*}"}"
      line="${line%"${line##*[! ]}"}"
      [[ "$line" =~ '^\[' ]] && break
      if [[ "$line" =~ '^base_branch[[:space:]]*=[[:space:]]*"(.*)"$' ]]; then
        echo "${match[1]}"
        return 0
      fi
    done < "$config_file"
  fi

  # Auto-detect from remote
  local remote_head
  remote_head=$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
  if [[ -n "$remote_head" ]]; then
    echo "${remote_head##refs/remotes/origin/}"
    return 0
  fi

  # Fallback: check common names
  for candidate in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  echo "HEAD"
}

# ── TOML config parser (minimal, handles what we need) ─────────────

_w_load_config() {
  local config_file="$1" branch="$2"
  local current_section="" current_profile="" matched_profile=""
  local in_window="" window_idx=0

  typeset -gA W_PROFILE
  typeset -ga W_SETUP_CMDS
  typeset -ga W_PRE_CMDS
  typeset -ga W_WINDOW_NAMES
  typeset -ga W_WINDOW_DIRS
  typeset -ga W_WINDOW_CMDS
  W_PROFILE=()
  W_SETUP_CMDS=()
  W_PRE_CMDS=()
  W_WINDOW_NAMES=()
  W_WINDOW_DIRS=()
  W_WINDOW_CMDS=()

  [[ -f "$config_file" ]] || return 1

  # First pass: find which profile matches this branch
  local line key val p profiles=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[! ]*}"}"
    line="${line%"${line##*[! ]}"}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ '^\[profile\.([a-zA-Z0-9_-]+)\]$' ]]; then
      current_profile="${match[1]}"
      profiles+=("$current_profile")
      continue
    fi

    if [[ -n "$current_profile" && "$line" =~ '^branches[[:space:]]*=[[:space:]]*"(.*)"$' ]]; then
      local patterns="${match[1]}"
      if [[ -z "$matched_profile" ]]; then
        for p in ${(s:,:)patterns}; do
          p="${p#"${p%%[! ]*}"}"
          p="${p%"${p##*[! ]}"}"
          [[ "$branch" == ${~p} ]] && { matched_profile="$current_profile"; break; }
        done
      fi
    fi
  done < "$config_file"

  # Fall back to default profile
  if [[ -z "$matched_profile" ]]; then
    if (( ${profiles[(I)default]} )); then
      matched_profile="default"
    else
      return 1
    fi
  fi

  # Second pass: parse the matched profile's settings
  current_section=""
  current_profile=""
  in_window=""
  local reading=0

  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[! ]*}"}"
    line="${line%"${line##*[! ]}"}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ '^\[profile\.([a-zA-Z0-9_-]+)\]$' ]]; then
      current_profile="${match[1]}"
      in_window=""
      reading=0
      [[ "$current_profile" == "$matched_profile" ]] && reading=1
      continue
    fi

    if [[ "$line" =~ '^\[\[profile\.([a-zA-Z0-9_-]+)\.setup\]\]$' ]]; then
      current_profile="${match[1]}"
      in_window=""
      reading=0
      [[ "$current_profile" == "$matched_profile" ]] && { reading=1; in_window="setup"; }
      continue
    fi

    if [[ "$line" =~ '^\[\[profile\.([a-zA-Z0-9_-]+)\.pre\]\]$' ]]; then
      current_profile="${match[1]}"
      in_window=""
      reading=0
      [[ "$current_profile" == "$matched_profile" ]] && { reading=1; in_window="pre"; }
      continue
    fi

    if [[ "$line" =~ '^\[\[profile\.([a-zA-Z0-9_-]+)\.windows\]\]$' ]]; then
      current_profile="${match[1]}"
      in_window=""
      reading=0
      if [[ "$current_profile" == "$matched_profile" ]]; then
        reading=1
        in_window="window"
        window_idx=$(( ${#W_WINDOW_NAMES[@]} + 1 ))
        W_WINDOW_NAMES+=("")
        W_WINDOW_DIRS+=("")
        W_WINDOW_CMDS+=("")
      fi
      continue
    fi

    if [[ "$line" =~ '^\[' ]]; then
      reading=0
      in_window=""
      continue
    fi

    (( reading == 0 )) && continue

    if [[ "$line" =~ '^([a-zA-Z_]+)[[:space:]]*=[[:space:]]*"(.*)"$' ]]; then
      key="${match[1]}"
      val="${match[2]}"

      if [[ "$in_window" == "setup" ]]; then
        [[ "$key" == "run" ]] && W_SETUP_CMDS+=("$val")
      elif [[ "$in_window" == "pre" ]]; then
        [[ "$key" == "run" ]] && W_PRE_CMDS+=("$val")
      elif [[ "$in_window" == "window" ]]; then
        case "$key" in
          name) W_WINDOW_NAMES[$window_idx]="$val" ;;
          dir)  W_WINDOW_DIRS[$window_idx]="$val" ;;
          run)  W_WINDOW_CMDS[$window_idx]="$val" ;;
        esac
      else
        W_PROFILE[$key]="$val"
      fi
    fi
  done < "$config_file"

  W_PROFILE[name]="$matched_profile"
  return 0
}

# ── Repo-command opt-in ────────────────────────────────────────────
#
# .worktree.toml lives in the repository, so a committed config can carry
# commands written by anyone who can push to it. The setup, pre and window
# `run` commands are therefore NOT executed unless the user opts in by setting
# WORKTREE_ALLOW_REPO_COMMANDS=1 (exactly "1"). Without it, the commands are
# listed so they can be reviewed, and everything else (worktree creation,
# dependency bootstrap, tmux windows) still happens.

_w_repo_commands_allowed() {
  [[ "${WORKTREE_ALLOW_REPO_COMMANDS:-}" == "1" ]]
}

# _w_repo_commands_skipped <kind> <cmd>...
_w_repo_commands_skipped() {
  local kind="$1"; shift
  local -a cmds
  cmds=("${(@)@:#}")
  (( ${#cmds} )) || return 0
  echo "  ⚠️  Not running ${#cmds} $kind command(s) from .worktree.toml:"
  local cmd
  for cmd in "${cmds[@]}"; do
    echo "      $cmd"
  done
  echo "     Repo commands are off by default. Review them, then re-run with"
  echo "     WORKTREE_ALLOW_REPO_COMMANDS=1 to allow them."
}

# ── Scaffolding & tmux ─────────────────────────────────────────────

_w_run_setup() {
  local dest="$1" repo="$2" branch="$3"
  local config_file="$repo/.worktree.toml"

  _w_load_config "$config_file" "$branch" || return 0

  echo "📋 Matched profile: ${W_PROFILE[name]}"

  if ! _w_repo_commands_allowed; then
    _w_repo_commands_skipped setup "${W_SETUP_CMDS[@]}"
    return 0
  fi

  local cmd
  for cmd in "${W_SETUP_CMDS[@]}"; do
    [[ -z "$cmd" ]] && continue
    echo "  🔧 $cmd"
    (cd "$dest" && eval "$cmd")
  done
}

# ── Dependency bootstrap ───────────────────────────────────────────
#
# Copy the main repo's installed dependency dirs (node_modules, vendor, …)
# into a freshly-created worktree. These are typically gitignored, so
# `git worktree add` never populates them — a new worktree can't build or
# test until they exist. We clone them with copy-on-write where the
# filesystem supports it (APFS clonefile / reflink) so it's near-instant
# and shares disk blocks until something writes. We clone rather than
# symlink so a later install in the worktree can't corrupt the main repo.
#
# Which dirs get cloned (see _w_resolve_dep_dirs):
#   base  = top-level dep_dirs in .worktree.toml, if set  (REPLACES the
#           built-in node_modules + vendor); otherwise the built-in defaults
#   final = base + matched [profile.X] dep_dirs           (the profile EXTENDS)
# So a top-level dep_dirs defines the repo's base set, and each profile adds
# to it for its own branches (fe/*, be/*, …).
#
#   WORKTREE_NO_DEP_BOOTSTRAP=1   disable entirely
#   WORKTREE_DEP_DIRS="a b c"     imperative override — replaces the whole set
#
# The built-in list is limited to *relocatable* dep dirs. Python venvs are
# NOT relocatable (activate scripts + shebangs hardcode the path) and are
# intentionally excluded — add them via a dep_dirs key or WORKTREE_DEP_DIRS
# only if you know your venv tolerates a move.

# Read a top-level (outside any [profile]) dep_dirs value from a config file.
_w_toml_top_dep_dirs() {
  local cfg="$1" line
  [[ -f "$cfg" ]] || return 1
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[! ]*}"}"
    line="${line%"${line##*[! ]}"}"
    [[ "$line" =~ '^\[' ]] && break        # stop at first section header
    if [[ "$line" =~ '^dep_dirs[[:space:]]*=[[:space:]]*"(.*)"$' ]]; then
      echo "${match[1]}"
      return 0
    fi
  done < "$cfg"
  return 1
}

# Resolve the effective dependency-dir list for a branch, one per line.
# WORKTREE_DEP_DIRS replaces everything; otherwise built-ins + top-level
# dep_dirs + matched-profile dep_dirs, deduplicated (order preserved).
_w_resolve_dep_dirs() {
  local repo="$1" branch="$2"

  if [[ -n "${WORKTREE_DEP_DIRS:-}" ]]; then
    print -rl -- ${=WORKTREE_DEP_DIRS}
    return 0
  fi

  local cfg="$repo/.worktree.toml" top=""
  [[ -f "$cfg" ]] && top=$(_w_toml_top_dep_dirs "$cfg")

  # A top-level dep_dirs REPLACES the built-in defaults; otherwise use them.
  local -aU dirs                           # -U keeps the array deduplicated
  if [[ -n "$top" ]]; then
    dirs=(${=top})
  else
    dirs=(node_modules vendor)
  fi

  # The matched profile's dep_dirs (if any) extends the base set.
  if [[ -f "$cfg" ]] && _w_load_config "$cfg" "$branch" 2>/dev/null; then
    local prof="${W_PROFILE[dep_dirs]:-}"
    [[ -n "$prof" ]] && dirs+=(${=prof})
  fi
  print -rl -- $dirs
}

_w_bootstrap_deps() {
  local repo="$1" dest="$2" branch="${3:-}"

  [[ -n "${WORKTREE_NO_DEP_BOOTSTRAP:-}" ]] && return 0

  # A bare main repo has no working tree to copy deps from.
  [[ "$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null)" == true ]] && return 0

  local -a dep_dirs
  dep_dirs=(${(f)"$(_w_resolve_dep_dirs "$repo" "$branch")"})
  (( ${#dep_dirs[@]} )) || return 0

  # Pick the fastest copy the filesystem / coreutils supports.
  local -a copy_cmd
  if cp --version 2>/dev/null | grep -q 'GNU coreutils'; then
    copy_cmd=(cp -a --reflink=auto)          # Linux: reflink when possible
  else
    local _t1 _t2                            # macOS/BSD: probe clonefile(2)
    _t1=$(mktemp 2>/dev/null) && _t2="${_t1}.wclone"
    if [[ -n "$_t1" ]] && cp -c "$_t1" "$_t2" 2>/dev/null; then
      copy_cmd=(cp -Rc)                      # APFS copy-on-write clone
    else
      copy_cmd=(cp -R)                       # last resort: plain recursive copy
    fi
    rm -f "$_t1" "$_t2" 2>/dev/null
  fi

  # Build a find predicate: \( -name node_modules -o -name vendor \)
  local -a find_expr=()
  local n first=1
  for n in "${dep_dirs[@]}"; do
    (( first )) || find_expr+=(-o)
    find_expr+=(-name "$n")
    first=0
  done

  # Find each dep dir at any depth, but -prune so we never descend into one
  # (skips nested node_modules and keeps it fast).
  local src rel target count=0
  while IFS= read -r src; do
    src="${src#./}"
    [[ -z "$src" || "$src" == "." ]] && continue
    target="$dest/$src"
    [[ -e "$target" ]] && continue           # worktree already has it
    mkdir -p "${target:h}"
    if "${copy_cmd[@]}" "$repo/$src" "$target" 2>/dev/null; then
      echo "  📦 deps: $src"
      (( count++ ))
    fi
  done < <(cd "$repo" && find . -type d '(' "${find_expr[@]}" ')' -prune -print 2>/dev/null)

  (( count )) && echo "  ✅ ${count} dependency dir(s) cloned into worktree"
  return 0
}

_w_dev() {
  local dest="$1" branch="$2" repo="$3"
  local config_file="$repo/.worktree.toml"

  if ! command -v tmux &>/dev/null; then
    echo "tmux not installed — install with: brew install tmux"
    return 1
  fi

  _w_load_config "$config_file" "$branch" || {
    echo "No .worktree.toml found or no matching profile for '$branch'"
    return 1
  }

  local session_name
  session_name=$(_w_profile_session_name "$repo" "$branch")

  if tmux has-session -t "=$session_name" 2>/dev/null; then
    echo "🔌 Reattaching to $session_name"
    tmux attach-session -t "=$session_name"
    return 0
  fi

  echo "🚀 Starting dev session: $session_name (profile: ${W_PROFILE[name]})"

  # Pre-launch commands (and window commands below) only run on opt-in
  local allow=0
  _w_repo_commands_allowed && allow=1

  local cmd
  if (( allow )); then
    for cmd in "${W_PRE_CMDS[@]}"; do
      [[ -z "$cmd" ]] && continue
      echo "  ⚙️  $cmd"
      if ! (cd "$dest" && eval "$cmd"); then
        echo "  ❌ Failed — aborting session"
        return 1
      fi
    done
  else
    _w_repo_commands_skipped pre "${W_PRE_CMDS[@]}"
    _w_repo_commands_skipped window "${W_WINDOW_CMDS[@]}"
  fi

  # Window 0: shell
  tmux new-session -d -s "$session_name" -c "$(_w_tmux_dir "$dest")" -n "shell"

  local i
  for (( i = 1; i <= ${#W_WINDOW_NAMES[@]}; i++ )); do
    local wname="${W_WINDOW_NAMES[$i]:-win$i}"
    local wdir="${W_WINDOW_DIRS[$i]}"
    local wcmd="${W_WINDOW_CMDS[$i]}"

    if [[ -n "$wdir" && "$wdir" != /* ]]; then
      wdir="$dest/$wdir"
    fi
    wdir="${wdir:-$dest}"

    echo "  🪟 $wname"
    tmux new-window -t "=$session_name:" -n "$wname" -c "$(_w_tmux_dir "$wdir")"
    if [[ -n "$wcmd" ]] && (( allow )); then
      tmux send-keys -t "=$session_name:$wname" "$wcmd" Enter
    fi
  done

  tmux select-window -t "=${session_name}:shell"
  tmux attach-session -t "=$session_name"
}

# ── Core commands ──────────────────────────────────────────────────

worktree() {
  # clone doesn't need an existing repo context
  case "${1:-}" in
    help|--help|-h) _w_help; return ;;
    clone)          _w_clone "${2:-}" "${3:-}"; return ;;
    --all)          _w_fzf_all; return ;;
  esac

  # Subcommand help needs no repository.
  case "${2:-}" in
    --help|-h)
      case "${1:-}" in
        add) _w_add "" "" "$2"; return ;;
        rm)  _w_rm "" "" "$2"; return ;;
        ls)  _w_ls "" "$2"; return ;;
        cd)  _w_cd "" "$2"; return ;;
        dev) _w_dev_cmd "" "" "$2"; return ;;
      esac ;;
  esac

  local W_MAIN_REPO W_WORKTREES_DIR
  if ! _w_repo_info 2>/dev/null; then
    # Not in a repo — fall back to cross-repo behavior where it makes sense
    case "${1:-}" in
      "")  _w_fzf_all; return ;;
      ls)  _w_ls "" "${2:-}"; return ;;
    esac
    echo "Not in a git repository" >&2
    return 1
  fi

  case "${1:-}" in
    add)      _w_add "$W_MAIN_REPO" "$W_WORKTREES_DIR" "${2:-}" ;;
    rm)       _w_rm "$W_MAIN_REPO" "$W_WORKTREES_DIR" "${2:-}" ;;
    ls)       _w_ls "$W_MAIN_REPO" "${2:-}" ;;
    cd)       _w_cd "$W_MAIN_REPO" "${2:-}" ;;
    dev)      _w_dev_cmd "$W_MAIN_REPO" "$W_WORKTREES_DIR" "${2:-}" ;;
    "")       _w_fzf "$W_MAIN_REPO" "$W_WORKTREES_DIR" ;;
    *)        _w_go "$W_MAIN_REPO" "$W_WORKTREES_DIR" "$1" ;;
  esac
}

# ── Aliases ────────────────────────────────────────────────────────
# Set WORKTREE_NO_ALIASES=1 before sourcing to skip these.

if [[ -z "${WORKTREE_NO_ALIASES:-}" ]]; then
  (( ${+aliases[w]}  )) && unalias w
  (( ${+aliases[wt]} )) && unalias wt
  alias w='worktree'
  alias wt='worktree'
fi

_w_clone() {
  local url="$1" branch="${2:-}"

  if [[ "$url" == "--help" || "$url" == "-h" ]]; then
    cat <<'EOF'
Usage: w clone <repo-url> [branch]

Clone a repository in worktree-ready (bare) mode and optionally
create a first worktree.

  - Clones <repo-url> as a bare repo at ./<name>
  - Sets up the worktrees directory at ./<name>-worktrees
  - If [branch] is given, creates a worktree for it immediately

Examples:
  w clone git@github.com:org/project.git
  w clone git@github.com:org/project.git fe/my-feature

The bare repo has no working tree — all work happens in worktrees.
This is the recommended setup for worktree-heavy workflows.
EOF
    return 0
  fi

  [[ -z "$url" ]] && { echo "usage: w clone <repo-url> [branch]"; return 1; }

  local name
  name=$(_w_repo_name_from_url "$url")
  local bare_dir="$PWD/$name"
  local wt_dir="$PWD/${name}-worktrees"

  if [[ -d "$bare_dir" ]]; then
    echo "📦 $name already exists at $bare_dir"
    return 1
  fi

  echo "📦 Cloning $name..."
  git clone --bare "$url" "$bare_dir" || { echo "  ❌ Clone failed"; return 1; }

  # Configure the bare repo so fetch works properly with worktrees
  git -C "$bare_dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  echo "  📡 Fetching remote refs..."
  git -C "$bare_dir" fetch origin >/dev/null 2>&1

  # Set origin HEAD so _w_base_branch can detect the default branch
  git -C "$bare_dir" remote set-head origin --auto >/dev/null 2>&1

  mkdir -p "$wt_dir"
  echo "  ✅ Ready — bare repo at $bare_dir"

  if [[ -n "$branch" ]]; then
    echo ""
    # Resolve base for new branches
    local base
    base=$(_w_base_branch "$bare_dir")
    local dest="$wt_dir/$branch"

    if git -C "$bare_dir" show-ref --verify --quiet "refs/heads/$branch" || \
       git -C "$bare_dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      echo "🌿 Creating worktree: $branch"
      git -C "$bare_dir" worktree add "$dest" "$branch"
    else
      echo "🌿 Creating worktree: $branch (from $base)"
      git -C "$bare_dir" worktree add -b "$branch" "$dest" "origin/$base" 2>/dev/null \
        || git -C "$bare_dir" worktree add -b "$branch" "$dest" "$base"
    fi

    if [[ $? -eq 0 ]]; then
      cd "$dest"

      # No-op for a bare clone (no working tree to copy from), kept for
      # symmetry so a non-bare source would still bootstrap.
      _w_bootstrap_deps "$bare_dir" "$dest" "$branch"

      # Run setup if .worktree.toml exists in the worktree
      if [[ -f "$dest/.worktree.toml" ]]; then
        _w_run_setup "$dest" "$bare_dir" "$branch"
      fi
    fi
  fi
}

_w_go() {
  local repo="$1" wtdir="$2" branch="$3"

  # Resolve GitHub branch tree URLs to branch names
  local resolved
  if resolved=$(_w_resolve_branch_url "$branch"); then
    echo "🔗 Resolved branch URL → $resolved"
    branch="$resolved"
  # Resolve GitHub PR URLs to branch names
  elif resolved=$(_w_resolve_pr_url "$branch"); then
    echo "🔗 Resolved PR → $resolved"
    branch="$resolved"
  elif [ $? -eq 2 ]; then
    # A PR URL that could not be resolved: stop, never use the URL as a name
    return 1
  fi

  # An existing checkout of the branch is wherever git has it; only a branch
  # with no worktree gets a new one (from _w_add).
  local dest rc=0
  dest=$(_w_switch_target "$repo" "$branch") || rc=$?
  case $rc in
    0) cd "$dest" ;;
    1) _w_add "$repo" "$wtdir" "$branch" ;;
    *) return 1 ;;
  esac
}

_w_add() {
  local repo="$1" wtdir="$2" branch="$3"

  if [[ "$branch" == "--help" || "$branch" == "-h" ]]; then
    cat <<'EOF'
Usage: w add <branch>
       w add <github-pr-url>
       w add <github-branch-url>
       w <branch>

Create a new worktree and cd into it.

  - If <branch> is a GitHub PR URL, resolves the branch via gh CLI
    (runs ${GITHUB_CMD:-${GH_CMD:-gh}}, so a gh wrapper can be used).
  - If <branch> is a GitHub branch tree URL, extracts the branch name.
  - If <branch> exists locally, checks it out in a new worktree.
  - If <branch> exists on origin, checks out the remote tracking branch.
  - If <branch> doesn't exist, creates a new branch based off the
    development branch (not your current HEAD). The base is resolved
    from: .worktree.toml base_branch → origin HEAD → main/master.

The worktree is created at ../<repo>-worktrees/<branch> relative to the
main repository.

If the branch is already checked out (in a worktree wherever its directory
is, or in the main working tree), just cd's into it.

If a .worktree.toml exists, the matching profile's setup commands run
after creation ONLY when WORKTREE_ALLOW_REPO_COMMANDS=1 is set; otherwise
they are listed and skipped.

If a .worktree.toml exists in the repo root, the matching profile's
setup commands will run automatically after creation.

Examples:
  w add feat/login
  w add https://github.com/org/repo/pull/42
  w add https://github.com/org/repo/tree/feat/my-branch
EOF
    return 0
  fi

  [[ -z "$branch" ]] && { echo "usage: w add <branch> (see w add --help)"; return 1; }

  # Resolve GitHub branch tree URLs to branch names
  local resolved
  if resolved=$(_w_resolve_branch_url "$branch"); then
    echo "🔗 Resolved branch URL → $resolved"
    branch="$resolved"
  # Resolve GitHub PR URLs to branch names
  elif resolved=$(_w_resolve_pr_url "$branch"); then
    echo "🔗 Resolved PR → $resolved"
    branch="$resolved"
  elif [ $? -eq 2 ]; then
    # A PR URL that could not be resolved: stop, never use the URL as a name
    return 1
  fi

  # git refuses to check one branch out twice: if it is checked out already
  # (in a worktree wherever it is, or in the main working tree), switch there.
  local dest rc=0
  dest=$(_w_switch_target "$repo" "$branch") || rc=$?
  case $rc in
    0) echo "↩️  Already exists — switching to $(_w_short_path "$dest")"
       cd "$dest"
       return 0 ;;
    1) ;;
    *) return 1 ;;
  esac

  # No worktree has the branch: create one at <worktrees>/<branch>, but never
  # in a path that is already taken (by another branch's worktree or anything
  # else).
  dest="$wtdir/$branch"
  if [[ -e "$dest" || -L "$dest" ]]; then
    echo "$dest already exists but does not have branch '$branch' checked out: not creating a worktree there"
    return 1
  fi

  mkdir -p "$wtdir"

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "🌿 Creating worktree: $branch"
    git -C "$repo" worktree add "$dest" "$branch"
  else
    # Fetch from origin to ensure we have the latest refs
    echo "  📡 Fetching from origin..."
    git -C "$repo" fetch origin 2>/dev/null

    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      echo "🌿 Creating worktree: $branch (tracking origin/$branch)"
      git -C "$repo" worktree add --track -b "$branch" "$dest" "origin/$branch"
    else
      local base
      base=$(_w_base_branch "$repo")
      echo "🌿 Creating worktree: $branch (new branch from $base)"
      git -C "$repo" worktree add -b "$branch" "$dest" "origin/$base" 2>/dev/null \
        || git -C "$repo" worktree add -b "$branch" "$dest" "$base"
    fi
  fi

  local wt_ok=$?

  if [[ $wt_ok -eq 0 ]]; then
    cd "$dest"
    echo "  ✅ $(_w_short_path "$dest")"
    _w_bootstrap_deps "$repo" "$dest" "$branch"
  fi

  # Run config-driven setup if .worktree.toml exists
  if [[ $wt_ok -eq 0 && -f "$repo/.worktree.toml" ]]; then
    _w_run_setup "$dest" "$repo" "$branch"
    if (( ${#W_WINDOW_NAMES[@]} > 0 )); then
      echo ""
      echo "Run 'worktree dev' to launch tmux session."
    fi
  fi
}

_w_dev_cmd() {
  local repo="$1" wtdir="$2" branch="$3"

  if [[ "$branch" == "--help" || "$branch" == "-h" ]]; then
    cat <<'EOF'
Usage: worktree dev [<branch>]

Launch a tmux dev session defined by .worktree.toml in the repo root.

  - If no <branch> is given and you're inside a worktree, uses that one.
  - The branch name is matched against profile `branches` globs.
  - First matching profile wins; falls back to [profile.default].
  - pre and window `run` commands execute only when
    WORKTREE_ALLOW_REPO_COMMANDS=1 is set; otherwise they are listed and
    skipped (the tmux windows are still created).

Config format (.worktree.toml):

  [profile.frontend]
  branches = "fe/*, frontend/*, ui/*"

  [[profile.frontend.setup]]
  run = "direnv allow ."

  [[profile.frontend.setup]]
  run = "make install-fe"

  [[profile.frontend.pre]]
  run = "cd src/tsx && npm install"

  [[profile.frontend.windows]]
  name = "proxy"
  dir = "src/tsx"
  run = "npm run proxy https://my-env.example.com/"

  [[profile.frontend.windows]]
  name = "fe"
  run = "make run-fe"

  [profile.default]
  branches = "*"

  [[profile.default.pre]]
  run = "cd src/tsx && npm install"

  [[profile.default.windows]]
  name = "proxy"
  dir = "src/tsx"
  run = "npm run proxy https://my-env.example.com/"

  [[profile.default.windows]]
  name = "fe"
  run = "make run-fe"

Profile fields:
  branches   comma-separated glob patterns matched against the branch
             name (e.g. "fe/*, frontend/*"). First matching profile wins.
  session    tmux session name override (default: <repo>-<branch>)

Setup entries ([[profile.<name>.setup]]):
  run        command to execute in the worktree root (runs once on worktree add)

Pre entries ([[profile.<name>.pre]]):
  run        command to run before tmux windows launch (runs every worktree dev)
             Use for installing deps, building, etc. Aborts on failure.

Window entries ([[profile.<name>.windows]]):
  name       tmux window name
  dir        working directory (relative to worktree root, or absolute)
  run        command to send to the window
EOF
    return 0
  fi

  if [[ ! -f "$repo/.worktree.toml" ]]; then
    echo "No .worktree.toml found in $repo"
    return 1
  fi

  # Without a branch, use the worktree we are in: the branch git has checked
  # out there, never a guess from the directory name.
  local dest
  if [[ -z "$branch" ]]; then
    dest=$(_w_current_worktree_path "$wtdir") || {
      echo "Not inside a worktree. Specify a branch: worktree dev <branch>"
      return 1
    }
    branch=$(_w_worktree_branch "$dest") || {
      echo "HEAD is detached in $dest (no branch). Specify a branch: worktree dev <branch>"
      return 1
    }
  else
    # The worktree git has this branch checked out in, wherever it is.
    dest=$(_w_branch_worktree_path "$repo" "$branch")
    case $? in
      0) ;;
      2) echo "Branch '$branch' is checked out in the main working tree ($dest), not in a worktree"
         return 1 ;;
      *) echo "No worktree has branch '$branch' checked out (see: worktree ls)"
         return 1 ;;
    esac
  fi
  if [[ ! -d "$dest" ]]; then
    echo "No worktree at $dest"
    return 1
  fi

  _w_dev "$dest" "$branch" "$repo"
}

_w_rm() {
  local repo="$1" wtdir="$2" branch="$3"

  if [[ "$branch" == "--help" || "$branch" == "-h" ]]; then
    cat <<'EOF'
Usage: w rm [<branch>]

Remove a worktree and delete the branch.

  - If no <branch> is given and you're inside a worktree (not the main
    repo), the current worktree is used.
  - You'll be asked to type the branch name to confirm.
  - Both the worktree and the local branch are deleted.
EOF
    return 0
  fi

  # Without a branch, use the worktree we are in: the branch git has checked
  # out there, never a guess from the directory name.
  local dest
  if [[ -z "$branch" ]]; then
    dest=$(_w_current_worktree_path "$wtdir") || {
      echo "Not inside a worktree. Specify a branch: worktree rm <branch>"
      return 1
    }
    branch=$(_w_worktree_branch "$dest") || {
      echo "HEAD is detached in $dest (no branch). Specify a branch: worktree rm <branch>"
      return 1
    }
  else
    # The worktree git has this branch checked out in, wherever it is.
    dest=$(_w_branch_worktree_path "$repo" "$branch")
    case $? in
      0) ;;
      2) echo "Branch '$branch' is checked out in the main working tree ($dest), not in a worktree"
         return 1 ;;
      *) echo "No worktree has branch '$branch' checked out (see: worktree ls)"
         return 1 ;;
    esac
  fi

  if [[ ! -d "$dest" ]]; then
    echo "No worktree at $dest"
    return 1
  fi

  echo "This will remove worktree AND delete branch '$branch'."
  echo -n "Type the name to confirm: "
  local confirm
  read confirm
  if [[ "$confirm" != "$branch" ]]; then
    echo "Aborted — name didn't match."
    return 1
  fi

  # The session w dev made for this branch (profile `session` override
  # included).
  local session_name
  session_name=$(_w_profile_session_name "$repo" "$branch")
  tmux kill-session -t "=$session_name" 2>/dev/null

  # Leave the worktree first if we are in it (or below it).
  [[ "${PWD:A}" == "$dest" || "${PWD:A}" == "$dest"/* ]] && cd "$repo"

  echo "🗑️  Removing worktree: $branch"
  git -C "$repo" worktree remove "$dest" || return 1
  git -C "$repo" branch -D "$branch"
  echo "  ✅ Done"
}

_w_cd() {
  local repo="$1" branch="$2"

  if [[ "$branch" == "--help" || "$branch" == "-h" ]]; then
    cat <<'EOF'
Usage: w cd <branch>

Change directory into an existing worktree.
EOF
    return 0
  fi

  [[ -z "$branch" ]] && { echo "usage: w cd <branch> (see w cd --help)"; return 1; }

  # The worktree git has the branch checked out in, wherever it is.
  local dest rc=0
  dest=$(_w_switch_target "$repo" "$branch") || rc=$?
  case $rc in
    0) cd "$dest" ;;
    1) echo "No worktree has branch '$branch' checked out (see: worktree ls)"
       return 1 ;;
    *) return 1 ;;
  esac
}

_w_ls() {
  local repo="${1:-}" flag="${2:-}"

  if [[ "$flag" == "--help" || "$flag" == "-h" ]]; then
    cat <<'EOF'
Usage: worktree ls [--all]

List worktrees for the current repository.
Use --all to list worktrees across all discovered repos.
Falls back to --all when run outside a git repository.
The current worktree is marked with ▶.
EOF
    return 0
  fi

  if [[ "$flag" == "--all" || -z "$repo" ]]; then
    _w_collect_all_worktrees | _w_ls_format
    return
  fi

  git -C "$repo" worktree list | _w_ls_format
}

# Format `git worktree list` output grouped by repo, with a blank line
# between each repo and a ▶ marker on the current worktree.
#
# Input lines (from git worktree list):
#   /path/to/repo                    abc1234 [main]
#   /path/to/repo-worktrees/feat/x   abc1234 [feat/x]
#
# Output:
#   repo-name
#     ▶ main          abc1234
#       feat/x        abc1234
#
_w_ls_format() {
  local current="$PWD"

  # Slurp all lines so we can group them
  local -a lines
  while IFS= read -r line; do
    lines+=("$line")
  done

  # Derive a repo key from a worktree path:
  #   /tmp/foo-worktrees/feat/x  →  foo
  #   /tmp/foo                   →  foo
  _w_ls_repo_key() {
    local path="$1"
    local parent="${path:h}"
    local pname="${parent:t}"
    if [[ "$pname" == *-worktrees ]]; then
      echo "${pname%-worktrees}"
    else
      echo "${path:t}"
    fi
  }

  # Group lines by repo key, preserving insertion order
  local -a repo_order
  local -A repo_lines  # repo_key → newline-separated raw lines

  local line path key
  for line in "${lines[@]}"; do
    path="${line%% *}"
    key=$(_w_ls_repo_key "$path")
    if [[ -z "${repo_lines[$key]+_}" ]]; then
      repo_order+=("$key")
      repo_lines[$key]="$line"
    else
      repo_lines[$key]+=$'\n'"$line"
    fi
  done

  # Render each group
  local first=1
  local grp_line grp_path branch rest marker
  for key in "${repo_order[@]}"; do
    (( first )) || printf '\n'
    first=0

    # Dim repo header
    printf '\033[2m%s\033[0m\n' "$key"

    while IFS= read -r grp_line; do
      [[ -z "$grp_line" ]] && continue
      grp_path="${grp_line%% *}"
      rest="${grp_line#* }"

      # Extract branch name from [brackets]
      branch=""
      if [[ "$rest" =~ '\[([^]]+)\]' ]]; then
        branch="${match[1]}"
      fi
      [[ -z "$branch" ]] && branch="${grp_path:t}"

      # Strip the commit hash — just show branch
      if [[ "$grp_path" == "$current" ]]; then
        marker="  ▶"
      else
        marker="   "
      fi

      printf '%s %-30s\n' "$marker" "$branch"
    done <<< "${repo_lines[$key]}"
  done
}

# ── Worktree discovery (shared by fzf and ls --all) ───────────────

# Collect worktree listings from all discoverable repos.
# Prints one `git worktree list` line per worktree, deduplicated.
_w_collect_all_worktrees() {
  local search_dirs=() seen=()
  local W_MAIN_REPO W_WORKTREES_DIR

  if _w_repo_info 2>/dev/null; then
    search_dirs+=("${W_MAIN_REPO:h}")
  fi
  [[ -d "$HOME/dev" ]] && search_dirs+=("$HOME/dev")
  search_dirs=(${(u)search_dirs})

  {
    local dir candidate
    for dir in "${search_dirs[@]}"; do
      for candidate in "$dir"/*(N/); do
        # Must be a git repo (regular or bare)
        [[ -d "$candidate/.git" || -f "$candidate/HEAD" ]] || continue
        # Skip if we've already listed this repo
        (( ${seen[(I)$candidate]} )) && continue
        seen+=("$candidate")
        git -C "$candidate" worktree list 2>/dev/null
      done
    done
  } | sort -u
}


# ── fzf integration ────────────────────────────────────────────────

# Transform `git worktree list` output into repo-grouped display lines.
# Each input line:  /path/to/repo-worktrees/branch  abc1234 [branch]
# Each output line: FULL_PATH <tab> REPO_NAME / BRANCH_NAME
#
# The repo name is derived by stripping the -worktrees suffix from the
# parent directory, or using the directory basename for the main repo.
# The branch name comes from the [bracket] field in git's output, or
# falls back to the directory basename.
_w_format_worktrees() {
  awk '{
    path = $1

    # Extract branch from [brackets] — POSIX awk compatible
    branch = ""
    idx = index($0, "[")
    if (idx > 0) {
      rest = substr($0, idx + 1)
      end = index(rest, "]")
      if (end > 0) branch = substr(rest, 1, end - 1)
    }

    # Derive repo name from path
    n = split(path, parts, "/")
    repo_name = ""
    is_worktree = 0
    for (i = n; i >= 1; i--) {
      p = parts[i]
      if (p ~ /-worktrees$/) {
        repo_name = p
        sub(/-worktrees$/, "", repo_name)
        is_worktree = 1
        wt_branch = ""
        for (j = i + 1; j <= n; j++) {
          if (wt_branch != "") wt_branch = wt_branch "/"
          wt_branch = wt_branch parts[j]
        }
        if (wt_branch != "") branch = wt_branch
        break
      }
    }
    if (repo_name == "") {
      repo_name = parts[n]
      if (branch == "") branch = parts[n]
    }

    dim   = "\033[2m"
    reset = "\033[0m"

    printf "%s\t%s%s ›%s %s\n", path, dim, repo_name, reset, branch
  }'
}

# Shared fzf picker. Reads worktree list lines from stdin, formats
# them as repo/branch for display, and cd's into the selection.
_w_fzf_pick() {
  if ! command -v fzf &>/dev/null; then
    echo "fzf not installed — use 'w ls' and 'w cd <branch>'"
    return 1
  fi

  local listing
  listing=$(cat)
  [[ -z "$listing" ]] && { echo "No worktrees found"; return 1; }

  local formatted
  formatted=$(echo "$listing" | _w_format_worktrees)

  local sel
  sel=$(echo "$formatted" | \
    fzf --height=40% --reverse --ansi \
        --delimiter=$'\t' --with-nth=2 \
        --preview="git -C {1} log --oneline -5 2>/dev/null" \
        --preview-window=right:50%)

  [[ -z "$sel" ]] && return
  cd "${sel%%	*}"
}

_w_fzf() {
  local repo="$1"
  git -C "$repo" worktree list | _w_fzf_pick
}

_w_fzf_all() {
  _w_collect_all_worktrees | _w_fzf_pick
}

_w_help() {
  local bold="\033[1m" cyan="\033[36m" yellow="\033[33m" dim="\033[2m" reset="\033[0m"
  printf "${bold}WORKTREE${reset}(1)                    Git Worktree Helper                   ${bold}WORKTREE${reset}(1)\n\n"
  printf "${bold}NAME${reset}\n"
  printf "       worktree — git worktree helper (aliases: w, wt)\n\n"
  printf "${bold}SYNOPSIS${reset}\n"
  printf "       ${cyan}worktree${reset} [command] [options]\n\n"
  printf "${bold}COMMANDS${reset}\n"
  printf "       ${cyan}worktree${reset}                    interactive worktree switcher ${dim}(requires fzf)${reset}\n"
  printf "       ${cyan}worktree${reset} ${yellow}--all${reset}              interactive switcher across all repos\n"
  printf "       ${cyan}worktree${reset} ${yellow}clone${reset} <url> [br]   clone a repo headless for worktree workflows\n"
  printf "       ${cyan}worktree${reset} ${yellow}add${reset} <branch>       create a new worktree and cd into it\n"
  printf "       ${cyan}worktree${reset} ${yellow}<branch>${reset}           cd into worktree if it exists, otherwise create it\n"
  printf "       ${cyan}worktree${reset} ${yellow}<pr-url>${reset}           resolve a GitHub PR URL to its branch, then add/cd\n"
  printf "       ${cyan}worktree${reset} ${yellow}<tree-url>${reset}         resolve a GitHub branch tree URL, then add/cd\n"
  printf "       ${cyan}worktree${reset} ${yellow}rm${reset}  [<branch>]     remove a worktree ${dim}(prompts to delete branch)${reset}\n"
  printf "       ${cyan}worktree${reset} ${yellow}ls${reset} [--all]         list worktrees ${dim}(--all for all repos)${reset}\n"
  printf "       ${cyan}worktree${reset} ${yellow}cd${reset}  <branch>       cd into an existing worktree\n"
  printf "       ${cyan}worktree${reset} ${yellow}dev${reset} [<branch>]     launch tmux dev session from .worktree.toml\n"
  printf "       ${cyan}worktree${reset} ${yellow}help${reset}               show this help\n\n"
  printf "${bold}ALIASES${reset}\n"
  printf "       ${bold}w${reset} and ${bold}wt${reset} are set up by default. To disable:\n"
  printf "       ${dim}WORKTREE_NO_ALIASES=1${reset} before sourcing, or ${dim}unalias w wt${reset} afterwards.\n\n"
  printf "${bold}WORKTREE LAYOUT${reset}\n"
  printf "       Worktrees are created at ${dim}../<repo>-worktrees/<branch>${reset} relative to the\n"
  printf "       main repository. This works from any git repo or existing worktree.\n\n"
  printf "${bold}CONFIG${reset}\n"
  printf "       Place a ${bold}.worktree.toml${reset} in your repo root to define setup commands\n"
  printf "       and tmux dev sessions per branch pattern.\n"
  printf "       Its setup, pre and window commands run only with ${yellow}WORKTREE_ALLOW_REPO_COMMANDS=1${reset}\n"
  printf "       ${dim}(a committed config is code from the repo: review it first)${reset}.\n"
  printf "       Run ${cyan}worktree${reset} ${yellow}dev --help${reset} for the full config format and examples.\n\n"
  printf "${bold}DEPENDENCY BOOTSTRAP${reset}\n"
  printf "       On ${cyan}add${reset}, gitignored dependency dirs (${dim}node_modules, vendor${reset}) are cloned\n"
  printf "       from the main repo into the new worktree via copy-on-write, so it is\n"
  printf "       buildable immediately. If the branch changes deps, a follow-up install\n"
  printf "       (e.g. ${dim}npm install${reset}) only fetches the delta.\n"
  printf "       Declare deps with a ${bold}dep_dirs${reset} key in .worktree.toml: a top-level value\n"
  printf "       replaces the built-in defaults, and each ${dim}[profile]${reset} extends the base.\n"
  printf "       ${yellow}WORKTREE_DEP_DIRS${reset}=\"a b c\"     replace the whole set ${dim}(venv is not relocatable)${reset}\n"
  printf "       ${yellow}WORKTREE_NO_DEP_BOOTSTRAP=1${reset}   disable\n\n"
  printf "${dim}Run any subcommand with --help for more detail, e.g. worktree add --help${reset}\n"
}
