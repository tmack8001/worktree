#!/usr/bin/env sh
# worktree — git worktree helper installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tmack8001/worktree/v0.1.1/install.sh | sh
#   or, from a clone: ./install.sh [--zsh | --sh] [--prefix <dir>]
#
# Options:
#   --zsh        force zsh variant (default when your login shell is zsh)
#   --sh         force POSIX sh variant
#   --prefix     install directory (default: ~/.local/bin)
#   --rc         shell rc file to add source line to (auto-detected)
#   --ref        git ref to download (default: the pinned release below)
#   --remote     always download, even when run from a clone
#   --dry-run    show what would happen without doing it

set -e

# Downloads are pinned to a release tag, never a moving branch. Override with
# --ref <ref> or WORKTREE_REF=<ref> (for example --ref main to track main).
DEFAULT_REF="v0.1.1"
REF="${WORKTREE_REF:-$DEFAULT_REF}"
REPO_RAW="https://raw.githubusercontent.com/tmack8001/worktree"
FORCE_REMOTE=0
INSTALL_PREFIX="${HOME}/.local/bin"
FORCE_VARIANT=""
RC_FILE=""
DRY_RUN=0
NO_ALIASES=0

# ── Argument parsing ───────────────────────────────────────────────

need_arg() {
  if [ -z "${2:-}" ]; then
    echo "Error: $1 requires a value" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --zsh)        FORCE_VARIANT="zsh"; shift ;;
    --sh)         FORCE_VARIANT="sh"; shift ;;
    --prefix)     need_arg "$1" "${2:-}"; INSTALL_PREFIX="$2"; shift 2 ;;
    --rc)         need_arg "$1" "${2:-}"; RC_FILE="$2"; shift 2 ;;
    --ref)        need_arg "$1" "${2:-}"; REF="$2"; shift 2 ;;
    --remote)     FORCE_REMOTE=1; shift ;;
    --no-aliases) NO_ALIASES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: install.sh [options]

Options:
  --zsh          install zsh variant (default when your login shell is zsh)
  --sh           install POSIX sh variant (default otherwise)
  --prefix DIR   install directory (default: ~/.local/bin)
  --rc FILE      shell rc file to add source line to (auto-detected)
  --ref REF      git ref (tag, branch or commit) to download; default is the
                 pinned release. Also settable as WORKTREE_REF.
  --remote       download even when run from a clone of the repository
  --no-aliases   skip setting up w and wt aliases
  --dry-run      show what would happen without doing it
  -h, --help     show this help

Run from a clone (./install.sh), the files next to install.sh are copied.
Piped from curl, the files are downloaded at the pinned ref. Files in your
current directory are never used.

By default, aliases w and wt are added alongside the worktree function.
Use --no-aliases if you want to define your own or use the full name only.
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$REF" in
  ""|-*|*[!A-Za-z0-9._/-]*|*..*)
    echo "Error: invalid ref '$REF' (allowed: letters, digits, . _ / -)" >&2
    exit 1 ;;
esac
REPO_URL="${REPO_RAW}/${REF}"

# ── Detect shell variant ───────────────────────────────────────────
#
# Use the user's login shell ($SHELL), not "is zsh installed somewhere":
# macOS and many Linux images ship zsh even when the user runs bash.

LOGIN_SHELL="$(basename "${SHELL:-sh}")"

if [ -z "$FORCE_VARIANT" ]; then
  case "$LOGIN_SHELL" in
    zsh) VARIANT="zsh" ;;
    *)   VARIANT="sh" ;;
  esac
else
  VARIANT="$FORCE_VARIANT"
fi

# ── Detect rc file ─────────────────────────────────────────────────

if [ -z "$RC_FILE" ]; then
  case "$VARIANT" in
    zsh)
      RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    sh)
      case "$LOGIN_SHELL" in
        bash)
          if [ -f "$HOME/.bashrc" ]; then
            RC_FILE="$HOME/.bashrc"
          elif [ -f "$HOME/.bash_profile" ]; then
            RC_FILE="$HOME/.bash_profile"
          else
            RC_FILE="$HOME/.bashrc"
          fi
          ;;
        *)
          RC_FILE="$HOME/.profile"
          ;;
      esac
      ;;
  esac
fi

SCRIPT_NAME="w.${VARIANT}"
INSTALL_PATH="${INSTALL_PREFIX}/${SCRIPT_NAME}"
SOURCE_LINE=". \"${INSTALL_PATH}\""
if [ "$NO_ALIASES" = "1" ]; then
  SOURCE_LINE="WORKTREE_NO_ALIASES=1 . \"${INSTALL_PATH}\""
fi

# ── Pick the source: a clone, or a pinned download ─────────────────
#
# Only copy locally when this script was run as a file named install.sh and
# the variant sits next to it. When piped (curl ... | sh) $0 is the shell's
# name, so we download instead of trusting whatever is in the current dir.

SOURCE_DIR=""
if [ "$FORCE_REMOTE" != "1" ]; then
  case "$0" in
    install.sh|*/install.sh)
      if [ -f "$0" ]; then
        candidate="$(cd "$(dirname "$0")" && pwd -P)"
        if [ -f "$candidate/$SCRIPT_NAME" ]; then
          SOURCE_DIR="$candidate"
        fi
      fi
      ;;
  esac
fi

if [ -n "$SOURCE_DIR" ]; then
  SOURCE_DESC="$SOURCE_DIR/$SCRIPT_NAME (local clone)"
else
  SOURCE_DESC="${REPO_URL}/${SCRIPT_NAME}"
fi

# ── Summary ────────────────────────────────────────────────────────

echo "worktree — git worktree helper installer"
echo ""
echo "  variant : $VARIANT"
echo "  install : $INSTALL_PATH"
echo "  source  : $SOURCE_DESC"
echo "  rc file : $RC_FILE"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] would install $SOURCE_DESC to $INSTALL_PATH"
  echo "[dry-run] would add to $RC_FILE: $SOURCE_LINE"
  exit 0
fi

# ── Install ────────────────────────────────────────────────────────

mkdir -p "$INSTALL_PREFIX"

if [ -n "$SOURCE_DIR" ]; then
  cp "$SOURCE_DIR/$SCRIPT_NAME" "$INSTALL_PATH"
else
  echo "Downloading $SCRIPT_NAME at $REF..."
  TMP_PATH="${INSTALL_PATH}.download.$$"
  trap 'rm -f "$TMP_PATH"' EXIT
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${REPO_URL}/${SCRIPT_NAME}" -o "$TMP_PATH"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_PATH" "${REPO_URL}/${SCRIPT_NAME}"
  else
    echo "Error: curl or wget required for remote install" >&2
    exit 1
  fi
  if [ ! -s "$TMP_PATH" ]; then
    echo "Error: download of ${REPO_URL}/${SCRIPT_NAME} was empty" >&2
    exit 1
  fi
  mv "$TMP_PATH" "$INSTALL_PATH"
fi

chmod +x "$INSTALL_PATH"
echo "  ✓ installed $INSTALL_PATH"

# ── Add source line to rc ──────────────────────────────────────────

if grep -qF "$INSTALL_PATH" "$RC_FILE" 2>/dev/null; then
  echo "  ✓ $RC_FILE already sources w (skipping)"
else
  printf '\n# worktree — git worktree helper\n%s\n' "$SOURCE_LINE" >> "$RC_FILE"
  echo "  ✓ added source line to $RC_FILE"
fi

echo ""
echo "Done. Restart your shell or run:"
echo "  $SOURCE_LINE"
