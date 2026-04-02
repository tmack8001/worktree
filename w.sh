#!/usr/bin/env sh
# worktree — git worktree helper (POSIX sh)
# Worktrees go in ../<repo-name>-worktrees/<branch>
#
# Usage:
#   worktree clone <repo> [branch]  clone a repo headless & optionally add worktree
#   worktree add <branch>           create worktree & cd into it
#   worktree <branch>               cd into worktree or create it
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

# ── Repo info ──────────────────────────────────────────────────────

_w_repo_info() {
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || {
    toplevel=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    toplevel="${toplevel%/.git}"
  }

  if [ -z "$toplevel" ]; then
    echo "Not in a git repository" >&2
    return 1
  fi

  local common_dir
  common_dir=$(git -C "$toplevel" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$common_dir" in
    */.git) W_MAIN_REPO="${common_dir%/.git}" ;;
    *)      W_MAIN_REPO="$toplevel" ;;
  esac

  local repo_name
  repo_name=$(basename "$W_MAIN_REPO")
  local parent
  parent=$(dirname "$W_MAIN_REPO")
  W_WORKTREES_DIR="${parent}/${repo_name}-worktrees"
}

# ── Helpers ────────────────────────────────────────────────────────

_w_repo_name_from_url() {
  local url="$1"
  local name
  name=$(basename "$url")
  name="${name%.git}"
  printf '%s' "$name"
}

# Return the last two path segments: parent/name
_w_short_path() {
  local p="$1"
  local name parent
  name="${p##*/}"
  parent="${p%/*}"
  parent="${parent##*/}"
  printf '%s/%s' "$parent" "$name"
}

_w_trim() {
  local s="$1"
  # strip leading whitespace
  s="${s#"${s%%[! 	]*}"}"
  # strip trailing whitespace
  s="${s%"${s##*[! 	]}"}"
  printf '%s' "$s"
}

# ── Base branch resolution ─────────────────────────────────────────

_w_base_branch() {
  local repo="$1"
  local config_file="$repo/.worktree.toml"

  if [ -f "$config_file" ]; then
    local line key val in_section
    in_section=0
    while IFS= read -r line; do
      # strip comments
      line="${line%%#*}"
      line=$(_w_trim "$line")
      # stop at first section header
      case "$line" in
        \[*) break ;;
      esac
      case "$line" in
        base_branch*=*)
          val="${line#*=}"
          val=$(_w_trim "$val")
          val="${val#\"}"
          val="${val%\"}"
          printf '%s' "$val"
          return 0
          ;;
      esac
    done < "$config_file"
  fi

  local remote_head
  remote_head=$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$remote_head" ]; then
    printf '%s' "${remote_head##refs/remotes/origin/}"
    return 0
  fi

  for candidate in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  printf 'HEAD'
}

# ── TOML config parser (minimal, POSIX sh) ─────────────────────────
#
# Writes results to temp files since sh can't use global arrays.
# Callers read: $W_CFG_DIR/profile, setup_cmds, pre_cmds,
#               window_names, window_dirs, window_cmds

_w_load_config() {
  local config_file="$1" branch="$2"

  W_CFG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/w-cfg.XXXXXX")
  : > "$W_CFG_DIR/profile"
  : > "$W_CFG_DIR/setup_cmds"
  : > "$W_CFG_DIR/pre_cmds"
  : > "$W_CFG_DIR/window_names"
  : > "$W_CFG_DIR/window_dirs"
  : > "$W_CFG_DIR/window_cmds"

  [ -f "$config_file" ] || return 1

  # First pass: find matching profile
  local line current_profile matched_profile="" p patterns
  while IFS= read -r line; do
    line="${line%%#*}"
    line=$(_w_trim "$line")
    [ -z "$line" ] && continue

    case "$line" in
      \[profile.*)
        current_profile="${line#\[profile.}"
        current_profile="${current_profile%\]}"
        ;;
      branches*=*)
        if [ -z "$matched_profile" ] && [ -n "$current_profile" ]; then
          patterns="${line#*=}"
          patterns=$(_w_trim "$patterns")
          patterns="${patterns#\"}"
          patterns="${patterns%\"}"
          # split on comma and test each glob
          local IFS_SAVE="$IFS"
          IFS=","
          for p in $patterns; do
            IFS="$IFS_SAVE"
            p=$(_w_trim "$p")
            # POSIX case for glob matching
            case "$branch" in
              $p) matched_profile="$current_profile"; break ;;
            esac
            IFS=","
          done
          IFS="$IFS_SAVE"
        fi
        ;;
    esac
  done < "$config_file"

  # Fall back to default profile
  if [ -z "$matched_profile" ]; then
    if grep -q '^\[profile\.default\]' "$config_file" 2>/dev/null; then
      matched_profile="default"
    else
      return 1
    fi
  fi

  printf '%s\n' "$matched_profile" > "$W_CFG_DIR/profile"

  # Second pass: parse matched profile
  local reading=0 in_window="" key val window_idx=0
  current_profile=""

  while IFS= read -r line; do
    line="${line%%#*}"
    line=$(_w_trim "$line")
    [ -z "$line" ] && continue

    case "$line" in
      \[\[profile.*\.setup\]\])
        current_profile="${line#\[\[profile.}"
        current_profile="${current_profile%.setup\]\]}"
        in_window=""; reading=0
        [ "$current_profile" = "$matched_profile" ] && { reading=1; in_window="setup"; }
        continue ;;
      \[\[profile.*\.pre\]\])
        current_profile="${line#\[\[profile.}"
        current_profile="${current_profile%.pre\]\]}"
        in_window=""; reading=0
        [ "$current_profile" = "$matched_profile" ] && { reading=1; in_window="pre"; }
        continue ;;
      \[\[profile.*\.windows\]\])
        current_profile="${line#\[\[profile.}"
        current_profile="${current_profile%.windows\]\]}"
        in_window=""; reading=0
        if [ "$current_profile" = "$matched_profile" ]; then
          reading=1; in_window="window"
          window_idx=$((window_idx + 1))
          printf '\n' >> "$W_CFG_DIR/window_names"
          printf '\n' >> "$W_CFG_DIR/window_dirs"
          printf '\n' >> "$W_CFG_DIR/window_cmds"
        fi
        continue ;;
      \[profile.*)
        current_profile="${line#\[profile.}"
        current_profile="${current_profile%\]}"
        in_window=""; reading=0
        [ "$current_profile" = "$matched_profile" ] && reading=1
        continue ;;
      \[*)
        reading=0; in_window=""
        continue ;;
    esac

    [ "$reading" = "0" ] && continue

    case "$line" in
      *=*)
        key="${line%%=*}"
        key=$(_w_trim "$key")
        val="${line#*=}"
        val=$(_w_trim "$val")
        val="${val#\"}"
        val="${val%\"}"

        case "$in_window" in
          setup)
            [ "$key" = "run" ] && printf '%s\n' "$val" >> "$W_CFG_DIR/setup_cmds" ;;
          pre)
            [ "$key" = "run" ] && printf '%s\n' "$val" >> "$W_CFG_DIR/pre_cmds" ;;
          window)
            case "$key" in
              name) _w_file_set_line "$W_CFG_DIR/window_names" "$window_idx" "$val" ;;
              dir)  _w_file_set_line "$W_CFG_DIR/window_dirs"  "$window_idx" "$val" ;;
              run)  _w_file_set_line "$W_CFG_DIR/window_cmds"  "$window_idx" "$val" ;;
            esac ;;
          *)
            printf '%s=%s\n' "$key" "$val" >> "$W_CFG_DIR/profile" ;;
        esac
        ;;
    esac
  done < "$config_file"

  return 0
}

# Replace line N (1-based) in a file with a value
_w_file_set_line() {
  local file="$1" n="$2" val="$3"
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/w-line.XXXXXX")
  awk -v n="$n" -v v="$val" 'NR==n{print v; next} {print}' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Read a key from the profile key=value store
_w_cfg_get() {
  local key="$1"
  grep "^${key}=" "$W_CFG_DIR/profile" 2>/dev/null | head -1 | cut -d= -f2-
}

# Count non-empty lines in a file
_w_file_count() {
  grep -c . "$1" 2>/dev/null || printf '0'
}

# ── Scaffolding & tmux ─────────────────────────────────────────────

_w_run_setup() {
  local dest="$1" repo="$2" branch="$3"
  local config_file="$repo/.worktree.toml"

  _w_load_config "$config_file" "$branch" || return 0

  local profile_name
  profile_name=$(head -1 "$W_CFG_DIR/profile")
  echo "📋 Matched profile: $profile_name"

  local cmd
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    echo "  🔧 $cmd"
    (cd "$dest" && eval "$cmd")
  done < "$W_CFG_DIR/setup_cmds"
}

_w_dev() {
  local dest="$1" branch="$2" repo="$3"
  local config_file="$repo/.worktree.toml"

  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux not installed — install with: brew install tmux"
    return 1
  fi

  _w_load_config "$config_file" "$branch" || {
    echo "No .worktree.toml found or no matching profile for '$branch'"
    return 1
  }

  local session_override
  session_override=$(_w_cfg_get session)
  local repo_base
  repo_base=$(basename "$repo")
  local branch_safe
  branch_safe=$(printf '%s' "$branch" | tr '/' '-')
  local session_name="${session_override:-${repo_base}-${branch_safe}}"

  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "🔌 Reattaching to $session_name"
    tmux attach-session -t "$session_name"
    return 0
  fi

  local profile_name
  profile_name=$(head -1 "$W_CFG_DIR/profile")
  echo "🚀 Starting dev session: $session_name (profile: $profile_name)"

  # Pre-launch commands
  local cmd
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    echo "  ⚙️  $cmd"
    if ! (cd "$dest" && eval "$cmd"); then
      echo "  ❌ Failed — aborting session"
      return 1
    fi
  done < "$W_CFG_DIR/pre_cmds"

  # Window 0: shell
  tmux new-session -d -s "$session_name" -c "$dest" -n "shell"

  local total_windows
  total_windows=$(wc -l < "$W_CFG_DIR/window_names" | tr -d ' ')
  local i=1
  while [ "$i" -le "$total_windows" ]; do
    local wname wdir wcmd
    wname=$(sed -n "${i}p" "$W_CFG_DIR/window_names")
    wdir=$(sed -n "${i}p" "$W_CFG_DIR/window_dirs")
    wcmd=$(sed -n "${i}p" "$W_CFG_DIR/window_cmds")
    wname="${wname:-win${i}}"

    case "$wdir" in
      /*) : ;;
      ?*) wdir="$dest/$wdir" ;;
      *)  wdir="$dest" ;;
    esac

    echo "  🪟 $wname"
    tmux new-window -t "$session_name" -n "$wname" -c "$wdir"
    [ -n "$wcmd" ] && tmux send-keys -t "$session_name:$wname" "$wcmd" Enter
    i=$((i + 1))
  done

  tmux select-window -t "$session_name:shell"
  tmux attach-session -t "$session_name"
}

# ── Core commands ──────────────────────────────────────────────────

worktree() {
  case "${1:-}" in
    help|--help|-h) _w_help; return ;;
    clone)          _w_clone "${2:-}" "${3:-}"; return ;;
    --all)          _w_fzf_all; return ;;
  esac

  local W_MAIN_REPO W_WORKTREES_DIR
  if ! _w_repo_info 2>/dev/null; then
    case "${1:-}" in
      "")  _w_fzf_all; return ;;
      ls)  _w_ls "" "${2:-}"; return ;;
    esac
    echo "Not in a git repository" >&2
    return 1
  fi

  case "${1:-}" in
    add) _w_add "$W_MAIN_REPO" "$W_WORKTREES_DIR" "${2:-}" ;;
    rm)  _w_rm  "$W_MAIN_REPO" "$W_WORKTREES_DIR" "${2:-}" ;;
    ls)  _w_ls  "$W_MAIN_REPO" "${2:-}" ;;
    cd)  _w_cd  "$W_WORKTREES_DIR" "${2:-}" ;;
    dev) _w_dev_cmd "$W_MAIN_REPO" "$W_WORKTREES_DIR" "${2:-}" ;;
    "")  _w_fzf "$W_MAIN_REPO" "$W_WORKTREES_DIR" ;;
    *)   _w_go  "$W_MAIN_REPO" "$W_WORKTREES_DIR" "$1" ;;
  esac
}

# ── Aliases ────────────────────────────────────────────────────────
# Set WORKTREE_NO_ALIASES=1 before sourcing to skip these.

if [ -z "${WORKTREE_NO_ALIASES:-}" ]; then
  alias w='worktree'
  alias wt='worktree'
fi

_w_clone() {
  local url="$1" branch="${2:-}"

  case "$url" in
    --help|-h)
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
EOF
      return 0 ;;
  esac

  [ -z "$url" ] && { echo "usage: w clone <repo-url> [branch]"; return 1; }

  local name
  name=$(_w_repo_name_from_url "$url")
  local bare_dir="$PWD/$name"
  local wt_dir="$PWD/${name}-worktrees"

  if [ -d "$bare_dir" ]; then
    echo "📦 $name already exists at $bare_dir"
    return 1
  fi

  echo "📦 Cloning $name..."
  git clone --bare "$url" "$bare_dir" || { echo "  ❌ Clone failed"; return 1; }

  git -C "$bare_dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  echo "  📡 Fetching remote refs..."
  git -C "$bare_dir" fetch origin >/dev/null 2>&1
  git -C "$bare_dir" remote set-head origin --auto >/dev/null 2>&1

  mkdir -p "$wt_dir"
  echo "  ✅ Ready — bare repo at $bare_dir"

  if [ -n "$branch" ]; then
    echo ""
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

    if [ $? -eq 0 ]; then
      cd "$dest"
      [ -f "$dest/.worktree.toml" ] && _w_run_setup "$dest" "$bare_dir" "$branch"
    fi
  fi
}

_w_go() {
  local repo="$1" wtdir="$2" branch="$3"
  local dest="$wtdir/$branch"
  if [ -d "$dest" ]; then
    cd "$dest"
  else
    _w_add "$repo" "$wtdir" "$branch"
  fi
}

_w_add() {
  local repo="$1" wtdir="$2" branch="$3"

  case "$branch" in
    --help|-h)
      cat <<'EOF'
Usage: w add <branch>
       w <branch>

Create a new worktree and cd into it.

  - If <branch> exists locally, checks it out in a new worktree.
  - If <branch> exists on origin, checks out the remote tracking branch.
  - If <branch> doesn't exist, creates a new branch based off the
    development branch (not your current HEAD).

If a .worktree.toml exists, the matching profile's setup commands run
automatically after creation.
EOF
      return 0 ;;
  esac

  [ -z "$branch" ] && { echo "usage: w add <branch> (see w add --help)"; return 1; }

  local dest="$wtdir/$branch"

  if [ -d "$dest" ]; then
    echo "↩️  Already exists — switching to $(_w_short_path "$dest")"
    cd "$dest"
    return 0
  fi

  mkdir -p "$wtdir"

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "🌿 Creating worktree: $branch"
    git -C "$repo" worktree add "$dest" "$branch"
  elif git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    echo "🌿 Creating worktree: $branch (from origin)"
    git -C "$repo" worktree add "$dest" "$branch"
  else
    local base
    base=$(_w_base_branch "$repo")
    echo "🌿 Creating worktree: $branch (from $base)"
    git -C "$repo" fetch origin "$base" 2>/dev/null
    git -C "$repo" worktree add -b "$branch" "$dest" "origin/$base" 2>/dev/null \
      || git -C "$repo" worktree add -b "$branch" "$dest" "$base"
  fi

  local wt_ok=$?

  if [ "$wt_ok" -eq 0 ]; then
    cd "$dest"
    echo "  ✅ $(_w_short_path "$dest")"
  fi

  if [ "$wt_ok" -eq 0 ] && [ -f "$repo/.worktree.toml" ]; then
    _w_run_setup "$dest" "$repo" "$branch"
    local win_count
    win_count=$(wc -l < "$W_CFG_DIR/window_names" 2>/dev/null | tr -d ' ')
    if [ "${win_count:-0}" -gt 0 ]; then
      echo ""
      echo "Run 'worktree dev' to launch tmux session."
    fi
  fi
}

_w_dev_cmd() {
  local repo="$1" wtdir="$2" branch="$3"

  case "$branch" in
    --help|-h)
      cat <<'EOF'
Usage: w dev [<branch>]

Launch a tmux dev session defined by .worktree.toml in the repo root.

  - If no <branch> is given and you're inside a worktree, uses that one.
  - The branch name is matched against profile `branches` globs.
  - First matching profile wins; falls back to [profile.default].

See worktree.toml.example for the full config format.
EOF
      return 0 ;;
  esac

  if [ ! -f "$repo/.worktree.toml" ]; then
    echo "No .worktree.toml found in $repo"
    return 1
  fi

  if [ -z "$branch" ]; then
    case "$PWD" in
      "$wtdir"/*)
        branch="${PWD#$wtdir/}"
        branch="${branch%%/*}"
        ;;
      *)
        echo "Not inside a worktree. Specify a branch: worktree dev <branch>"
        return 1 ;;
    esac
  fi

  local dest="$wtdir/$branch"
  if [ ! -d "$dest" ]; then
    echo "No worktree at $dest"
    return 1
  fi

  _w_dev "$dest" "$branch" "$repo"
}

_w_rm() {
  local repo="$1" wtdir="$2" branch="$3"

  case "$branch" in
    --help|-h)
      cat <<'EOF'
Usage: w rm [<branch>]

Remove a worktree and delete the branch.

  - If no <branch> is given and you're inside a worktree, uses that one.
  - You'll be asked to type the branch name to confirm.
  - Both the worktree and the local branch are deleted.
EOF
      return 0 ;;
  esac

  if [ -z "$branch" ]; then
    case "$PWD" in
      "$wtdir"/*)
        branch="${PWD#$wtdir/}"
        branch="${branch%%/*}"
        ;;
      *)
        echo "Not inside a worktree. Specify a branch: worktree rm <branch>"
        return 1 ;;
    esac
  fi

  local dest="$wtdir/$branch"
  if [ ! -d "$dest" ]; then
    echo "No worktree at $dest"
    return 1
  fi

  echo "This will remove worktree AND delete branch '$branch'."
  printf 'Type the name to confirm: '
  local confirm
  read -r confirm
  if [ "$confirm" != "$branch" ]; then
    echo "Aborted — name didn't match."
    return 1
  fi

  local repo_base branch_safe session_guess
  repo_base=$(basename "$repo")
  branch_safe=$(printf '%s' "$branch" | tr '/' '-')
  session_guess="${repo_base}-${branch_safe}"
  tmux kill-session -t "$session_guess" 2>/dev/null

  case "$PWD" in
    "$dest"*) cd "$repo" ;;
  esac

  echo "🗑️  Removing worktree: $branch"
  git -C "$repo" worktree remove "$dest" || return 1
  git -C "$repo" branch -D "$branch"
  echo "  ✅ Done"
}

_w_cd() {
  local wtdir="$1" branch="$2"

  case "$branch" in
    --help|-h)
      echo "Usage: w cd <branch>"
      echo "Change directory into an existing worktree."
      return 0 ;;
  esac

  [ -z "$branch" ] && { echo "usage: w cd <branch>"; return 1; }

  local dest="$wtdir/$branch"
  if [ -d "$dest" ]; then
    cd "$dest"
  else
    echo "No worktree at $dest"
    return 1
  fi
}

_w_ls() {
  local repo="${1:-}" flag="${2:-}"

  case "$flag" in
    --help|-h)
      echo "Usage: worktree ls [--all]"
      echo "List worktrees. Use --all for all repos."
      echo "The current worktree is marked with ▶."
      return 0 ;;
  esac

  if [ "$flag" = "--all" ] || [ -z "$repo" ]; then
    _w_collect_all_worktrees | _w_ls_format
    return
  fi

  git -C "$repo" worktree list | _w_ls_format
}

# Format `git worktree list` output grouped by repo, with a blank line
# between each repo and a ▶ marker on the current worktree.
_w_ls_format() {
  local current="$PWD"
  awk -v current="$current" '
  BEGIN { n = 0 }
  {
    path = $1
    # Extract branch from [brackets]
    branch = ""
    idx = index($0, "[")
    if (idx > 0) {
      rest = substr($0, idx + 1)
      end = index(rest, "]")
      if (end > 0) branch = substr(rest, 1, end - 1)
    }
    if (branch == "") {
      split(path, p, "/"); branch = p[length(p)]
    }

    # Derive repo key
    split(path, parts, "/")
    np = length(parts)
    key = ""
    for (i = np; i >= 1; i--) {
      if (parts[i] ~ /-worktrees$/) {
        key = parts[i]
        sub(/-worktrees$/, "", key)
        break
      }
    }
    if (key == "") key = parts[np]

    # Store in order
    if (!(key in seen)) {
      seen[key] = 1
      order[++n] = key
    }
    groups[key] = groups[key] path "\t" branch "\n"
  }
  END {
    dim   = "\033[2m"
    reset = "\033[0m"
    for (gi = 1; gi <= n; gi++) {
      k = order[gi]
      if (gi > 1) printf "\n"
      printf "%s%s%s\n", dim, k, reset
      split(groups[k], entries, "\n")
      for (ei = 1; ei <= length(entries); ei++) {
        if (entries[ei] == "") continue
        split(entries[ei], f, "\t")
        wpath = f[1]; b = f[2]
        marker = (wpath == current) ? "  \342\226\266" : "   "
        printf "%s %-30s\n", marker, b
      }
    }
  }
  '
}

# ── Worktree discovery ─────────────────────────────────────────────

_w_collect_all_worktrees() {
  local W_MAIN_REPO W_WORKTREES_DIR
  local search_dirs=""

  if _w_repo_info 2>/dev/null; then
    search_dirs="$(dirname "$W_MAIN_REPO")"
  fi
  [ -d "$HOME/dev" ] && search_dirs="$search_dirs $HOME/dev"

  local seen="" dir candidate
  for dir in $search_dirs; do
    for candidate in "$dir"/*/; do
      candidate="${candidate%/}"
      [ -d "$candidate/.git" ] || [ -f "$candidate/HEAD" ] || continue
      case " $seen " in
        *" $candidate "*) continue ;;
      esac
      seen="$seen $candidate"
      git -C "$candidate" worktree list 2>/dev/null
    done
  done | sort -u
}

# ── fzf integration ────────────────────────────────────────────────

_w_format_worktrees() {
  awk '{
    path = $1
    branch = ""
    idx = index($0, "[")
    if (idx > 0) {
      rest = substr($0, idx + 1)
      end = index(rest, "]")
      if (end > 0) branch = substr(rest, 1, end - 1)
    }
    n = split(path, parts, "/")
    repo_name = ""
    for (i = n; i >= 1; i--) {
      p = parts[i]
      if (p ~ /-worktrees$/) {
        repo_name = p
        sub(/-worktrees$/, "", repo_name)
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
    dim = "\033[2m"; reset = "\033[0m"
    printf "%s\t%s%s \342\200\272%s %s\n", path, dim, repo_name, reset, branch
  }'
}

_w_fzf_pick() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not installed — use 'w ls' and 'w cd <branch>'"
    return 1
  fi

  local listing
  listing=$(cat)
  [ -z "$listing" ] && { echo "No worktrees found"; return 1; }

  local formatted sel
  formatted=$(printf '%s\n' "$listing" | _w_format_worktrees)

  sel=$(printf '%s\n' "$formatted" | \
    fzf --height=40% --reverse --ansi \
        --delimiter='	' --with-nth=2 \
        --preview='git -C {1} log --oneline -5 2>/dev/null' \
        --preview-window=right:50%)

  [ -z "$sel" ] && return
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
  printf "       ${cyan}worktree${reset} ${yellow}<branch>${reset}            cd into worktree if it exists, otherwise create it\n"
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
  printf "       Run ${cyan}worktree${reset} ${yellow}dev --help${reset} for the full config format and examples.\n\n"
  printf "${dim}Run any subcommand with --help for more detail, e.g. worktree add --help${reset}\n"
}
