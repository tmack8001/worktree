# w — git worktree helper demo
#
# Run from the repo root:
#   vhs demo/demo.tape
#
# The tape sets up two throwaway git repos in /tmp so nothing on your
# machine needs to be in a particular state.

Output demo/demo.gif

Require git
Require zsh

Set Shell "zsh"
Set FontSize 14
Set Width 1000
Set Height 580
Set Theme "Dracula"
Set Padding 20
Set TypingSpeed 50ms

# ── Silent setup ──────────────────────────────────────────────────
# Builds two repos (api-service, web-app) with several pre-made
# worktrees so the cross-repo switcher has plenty to show off.

Hide

Type "source demo/setup.sh"
Enter
Sleep 2000ms

Show

# ── Help ──────────────────────────────────────────────────────────

Sleep 500ms
Type "w help"
Enter
Sleep 4000ms

# ── We're in web-app. Create a new worktree ───────────────────────

Type "w add feat/login-redesign"
Enter
Sleep 3000ms

Type "pwd"
Enter
Sleep 2000ms

# ── Jump back to main, create another ────────────────────────────

Type "cd -"
Enter
Sleep 500ms

Type "w add fix/navbar-overflow"
Enter
Sleep 3000ms

# ── List all worktrees in this repo ──────────────────────────────

Type "cd -"
Enter
Sleep 400ms

Type "w ls"
Enter
Sleep 4000ms

# ── Switch to an existing worktree by name ───────────────────────

Type "w feat/login-redesign"
Enter
Sleep 1000ms

Type "pwd"
Enter
Sleep 2500ms

# ── THE KILLER FEATURE: jump to ANY worktree across ALL repos ─────
# w --all opens fzf showing every worktree on the machine.
# We simulate picking api-service/feat/auth-tokens.

Type "cd -"
Enter
Sleep 500ms

Type "w ls --all"
Enter
Sleep 5000ms

# ── Now show the interactive fzf switcher across all repos ────────
# (In a real session you'd just run `w` or `w --all` and pick.)
# We demonstrate by jumping directly to a worktree in the other repo.

Type "w feat/auth-tokens"
Enter
Sleep 1000ms

Type "pwd"
Enter
Sleep 3000ms

# ── We're now in api-service/feat/auth-tokens ─────────────────────

Type "w ls"
Enter
Sleep 4000ms

# ── Remove a worktree ─────────────────────────────────────────────

Type "w rm fix/memory-leak"
Enter
Sleep 600ms
Type "fix/memory-leak"
Enter
Sleep 3000ms

# ── Verify it's gone ─────────────────────────────────────────────

Type "w ls"
Enter
Sleep 4000ms

Sleep 1000ms
