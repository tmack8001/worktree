#!/usr/bin/env sh
# worktree — git worktree helper installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tmack8001/worktree/main/install.sh | sh
#   or: ./install.sh [--zsh | --sh] [--prefix <dir>]
#
# Options:
#   --zsh        force zsh variant (default if zsh is available)
#   --sh         force POSIX sh variant
#   --prefix     install directory (default: ~/.local/bin)
#   --rc         shell rc file to add source line to (auto-detected)
#   --dry-run    show what would happen without doing it

set -e

REPO_URL="https://raw.githubusercontent.com/tmack8001/worktree/main"
INSTALL_PREFIX="${HOME}/.local/bin"
FORCE_VARIANT=""
RC_FILE=""
DRY_RUN=0
NO_ALIASES=0

# ── Argument parsing ───────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --zsh)        FORCE_VARIANT="zsh"; shift ;;
    --sh)         FORCE_VARIANT="sh"; shift ;;
    --prefix)     INSTALL_PREFIX="$2"; shift 2 ;;
    --rc)         RC_FILE="$2"; shift 2 ;;
    --no-aliases) NO_ALIASES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: install.sh [options]

Options:
  --zsh          install zsh variant (default if zsh is available)
  --sh           install POSIX sh variant
  --prefix DIR   install directory (default: ~/.local/bin)
  --rc FILE      shell rc file to add source line to (auto-detected)
  --no-aliases   skip setting up w and wt aliases
  --dry-run      show what would happen without doing it
  -h, --help     show this help

By default, aliases w and wt are added alongside the worktree function.
Use --no-aliases if you want to define your own or use the full name only.
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Detect shell variant ───────────────────────────────────────────

if [ -z "$FORCE_VARIANT" ]; then
  if command -v zsh >/dev/null 2>&1; then
    VARIANT="zsh"
  else
    VARIANT="sh"
  fi
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
      if [ -f "$HOME/.bashrc" ]; then
        RC_FILE="$HOME/.bashrc"
      elif [ -f "$HOME/.bash_profile" ]; then
        RC_FILE="$HOME/.bash_profile"
      elif [ -f "$HOME/.profile" ]; then
        RC_FILE="$HOME/.profile"
      else
        RC_FILE="$HOME/.profile"
      fi
      ;;
  esac
fi

SCRIPT_NAME="w.${VARIANT}"
INSTALL_PATH="${INSTALL_PREFIX}/${SCRIPT_NAME}"
SOURCE_LINE=". \"${INSTALL_PATH}\""
if [ "$NO_ALIASES" = "1" ]; then
  SOURCE_LINE="WORKTREE_NO_ALIASES=1 . \"${INSTALL_PATH}\""
fi

# ── Summary ────────────────────────────────────────────────────────

echo "worktree — git worktree helper installer"
echo ""
echo "  variant : $VARIANT"
echo "  install : $INSTALL_PATH"
echo "  rc file : $RC_FILE"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] would install $SCRIPT_NAME to $INSTALL_PATH"
  echo "[dry-run] would add to $RC_FILE: $SOURCE_LINE"
  exit 0
fi

# ── Install ────────────────────────────────────────────────────────

mkdir -p "$INSTALL_PREFIX"

# If running from a local clone, copy directly; otherwise fetch
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/$SCRIPT_NAME" ]; then
  cp "$SCRIPT_DIR/$SCRIPT_NAME" "$INSTALL_PATH"
else
  echo "Downloading $SCRIPT_NAME..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${REPO_URL}/${SCRIPT_NAME}" -o "$INSTALL_PATH"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$INSTALL_PATH" "${REPO_URL}/${SCRIPT_NAME}"
  else
    echo "Error: curl or wget required for remote install" >&2
    exit 1
  fi
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
