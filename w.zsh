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
#   worktree sync                   fast-forward the default-branch worktree to origin
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
# Returns 0 and prints the branch name on success, returns 1 if not a PR URL.
_w_resolve_pr_url() {
  local input="$1"

  # Match GitHub PR URL patterns
  if [[ "$input" =~ '^https?://github\.com/[^/]+/[^/]+/pulls?/[0-9]+/?$' ]]; then
    # Normalize: strip trailing slash, fix /pulls/ to /pull/
    local url="${input%/}"
    url="${url/\/pulls\//\/pull\/}"

    if ! command -v gh &>/dev/null; then
      echo "gh CLI not installed — install with: brew install gh" >&2
      return 1
    fi

    local branch
    branch=$(gh pr view "$url" --json headRefName --jq '.headRefName' 2>/dev/null)
    if [[ -z "$branch" ]]; then
      echo "Failed to resolve PR URL: $url" >&2
      return 1
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

# ── Scaffolding & tmux ─────────────────────────────────────────────

_w_run_setup() {
  local dest="$1" repo="$2" branch="$3"
  local config_file="$repo/.worktree.toml"

  _w_load_config "$config_file" "$branch" || return 0

  echo "📋 Matched profile: ${W_PROFILE[name]}"

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

  local session_name="${W_PROFILE[session]:-$(basename "$repo")-${branch//\//-}}"

  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "🔌 Reattaching to $session_name"
    tmux attach-session -t "$session_name"
    return 0
  fi

  echo "🚀 Starting dev session: $session_name (profile: ${W_PROFILE[name]})"

  # Pre-launch commands
  local cmd
  for cmd in "${W_PRE_CMDS[@]}"; do
    [[ -z "$cmd" ]] && continue
    echo "  ⚙️  $cmd"
    if ! (cd "$dest" && eval "$cmd"); then
      echo "  ❌ Failed — aborting session"
      return 1
    fi
  done

  # Window 0: shell
  tmux new-session -d -s "$session_name" -c "$dest" -n "shell"

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
    tmux new-window -t "$session_name" -n "$wname" -c "$wdir"
    [[ -n "$wcmd" ]] && tmux send-keys -t "$session_name:$wname" "$wcmd" Enter
  done

  tmux select-window -t "$session_name:shell"
  tmux attach-session -t "$session_name"
}

# ── Sync ───────────────────────────────────────────────────────────
# Fast-forward the default-branch worktree (<worktrees>/<default>) to
# origin so local work is never based on a stale tree.
#
# Exit codes: 0 synced / already current / nothing to sync
#             1 fetch failed (offline) or bad usage
#             2 invariant breach (worktree dirty, ahead, or off-branch);
#               nothing is fast-forwarded and nothing is discarded
_w_sync() {
  local repo="$1" wts_dir="$2" arg="${3:-}"

  case "$arg" in
    ""|--help|-h) ;;
    *) echo "usage: w sync" >&2; return 1 ;;
  esac
  if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
    cat <<'HELP'
Usage: w sync

Fetch origin and fast-forward the default-branch worktree
(../<repo>-worktrees/<default>) with `git merge --ff-only`.

  - Never merge-commits, resets, or discards work.
  - If that worktree is dirty, its changes are stashed ("w sync
    quarantine") and the fast-forward is skipped (exit 2).
  - If it is ahead of origin or on another branch, nothing is touched
    (exit 2).
  - If it does not exist, only the fetch runs.
HELP
    return 0
  fi

  local def
  def=$(_w_base_branch "$repo")
  if [ -z "$def" ] || [ "$def" = "HEAD" ]; then
    echo "  ❌ Cannot resolve the default branch (set base_branch in .worktree.toml)" >&2
    return 1
  fi

  echo "📡 Fetching origin..."
  if ! git -C "$repo" fetch --prune origin >/dev/null 2>&1; then
    echo "  ❌ Fetch failed (offline?)" >&2
    return 1
  fi

  local dest="$wts_dir/$def"
  if [ ! -d "$dest" ] || ! git -C "$dest" rev-parse --git-dir >/dev/null 2>&1; then
    echo "  ⏭  No '$def' worktree at $dest — fetched only"
    return 0
  fi

  local cur
  cur=$(git -C "$dest" symbolic-ref --short -q HEAD)
  if [ "$cur" != "$def" ]; then
    echo "  ❌ $dest is on '${cur:-detached HEAD}', expected '$def' — not touched" >&2
    return 2
  fi

  if [ -n "$(git -C "$dest" status --porcelain)" ]; then
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    if git -C "$dest" stash push -u -m "w sync quarantine $stamp" >/dev/null 2>&1; then
      echo "  ❌ $dest was dirty — quarantined to stash 'w sync quarantine $stamp'" >&2
      echo "     Recover: w add <branch>, then git stash pop there" >&2
    else
      echo "  ❌ $dest is dirty and could not be stashed — left as is" >&2
    fi
    return 2
  fi

  local ahead
  ahead=$(git -C "$dest" rev-list --count "origin/$def..HEAD" 2>/dev/null)
  if [ "${ahead:-1}" != "0" ]; then
    echo "  ❌ $dest has commits not on origin/$def — not fast-forwarded" >&2
    echo "     Move them with: w add <branch> (git branch <branch> $def)" >&2
    return 2
  fi

  if git -C "$dest" merge --ff-only "origin/$def" >/dev/null 2>&1; then
    echo "  ✅ $def is at $(git -C "$dest" rev-parse --short HEAD)"
  else
    echo "  ❌ Fast-forward of $def failed" >&2
    return 2
  fi
}

# ── Core commands ──────────────────────────────────────────────────

worktree() {
  # clone doesn't need an existing repo context
  case "${1:-}" in
    help|--help|-h) _w_help; return ;;
    clone)          _w_clone "${2:-}" "${3:-}"; return ;;
    --all)          _w_fzf_all; return ;;
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
    cd)       _w_cd "$W_WORKTREES_DIR" "${2:-}" ;;
    dev)      _w_dev_cmd "$W_MAIN_REPO" "$W_WORKTREES_DIR" "${2:-}" ;;
    sync)     _w_sync "$W_MAIN_REPO" "$W_WORKTREES_DIR" "${2:-}" ;;
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
  fi

  # If the worktree exists, cd into it; otherwise create it
  local dest="$wtdir/$branch"
  if [[ -d "$dest" ]]; then
    cd "$dest"
  else
    _w_add "$repo" "$wtdir" "$branch"
  fi
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

  - If <branch> is a GitHub PR URL, resolves the branch via gh CLI.
  - If <branch> is a GitHub branch tree URL, extracts the branch name.
  - If <branch> exists locally, checks it out in a new worktree.
  - If <branch> exists on origin, checks out the remote tracking branch.
  - If <branch> doesn't exist, creates a new branch based off the
    development branch (not your current HEAD). The base is resolved
    from: .worktree.toml base_branch → origin HEAD → main/master.

The worktree is created at ../<repo>-worktrees/<branch> relative to the
main repository.

If the worktree already exists, just cd's into it.

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
  fi

  local dest="$wtdir/$branch"

  if [[ -d "$dest" ]]; then
    echo "↩️  Already exists — switching to $(_w_short_path "$dest")"
    cd "$dest"
    return 0
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

  if [[ -z "$branch" ]]; then
    if [[ "$PWD" == "$wtdir"/* ]]; then
      branch="${PWD#$wtdir/}"
      branch="${branch%%/*}"
    else
      echo "Not inside a worktree. Specify a branch: worktree dev <branch>"
      return 1
    fi
  fi

  local dest="$wtdir/$branch"
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

  if [[ -z "$branch" ]]; then
    if [[ "$PWD" == "$wtdir"/* ]]; then
      branch="${PWD#$wtdir/}"
      branch="${branch%%/*}"
    else
      echo "Not inside a worktree. Specify a branch: worktree rm <branch>"
      return 1
    fi
  fi

  local dest="$wtdir/$branch"

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

  # Kill tmux session if one exists for this worktree
  local session_guess="${repo:t}-${branch//\//-}"
  tmux kill-session -t "$session_guess" 2>/dev/null

  [[ "$PWD" == "$dest"* ]] && cd "$repo"

  echo "🗑️  Removing worktree: $branch"
  git -C "$repo" worktree remove "$dest" || return 1
  git -C "$repo" branch -D "$branch"
  echo "  ✅ Done"
}

_w_cd() {
  local wtdir="$1" branch="$2"

  if [[ "$branch" == "--help" || "$branch" == "-h" ]]; then
    cat <<'EOF'
Usage: w cd <branch>

Change directory into an existing worktree.
EOF
    return 0
  fi

  [[ -z "$branch" ]] && { echo "usage: w cd <branch> (see w cd --help)"; return 1; }

  local dest="$wtdir/$branch"
  if [[ -d "$dest" ]]; then
    cd "$dest"
  else
    echo "No worktree at $dest"
    return 1
  fi
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
  printf "       ${cyan}worktree${reset} ${yellow}sync${reset}               fetch + fast-forward the default-branch worktree\n"
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
