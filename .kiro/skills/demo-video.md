---
description: Instructions for regenerating the demo GIF using VHS after changes to w.zsh, w.sh, or the demo script
inclusion: manual
---

# Skill: Regenerating the Demo GIF

Use this skill whenever updating `demo/demo.gif` — after changing `w.zsh`/`w.sh`,
updating the demo script, or refreshing the README screenshot.

## Prerequisites

Install [VHS](https://github.com/charmbracelet/vhs) if not already present:

```bash
brew install vhs
```

VHS also requires `ttyd` and `ffmpeg` on macOS:

```bash
brew install ttyd ffmpeg
```

Verify:

```bash
vhs --version
```

## Files involved

| File | Purpose |
|---|---|
| `demo/demo.tape` | VHS tape — defines every keystroke, timing, and output path |
| `demo/setup.sh` | Sourced silently at the start; creates two throwaway repos in `/tmp` with pre-populated worktrees |
| `demo/demo.gif` | Generated output — committed to the repo so the README renders it |

## How the demo is structured

`setup.sh` creates **two independent git repos** in a temp dir:

- `api-service` — pre-loaded with worktrees: `feat/auth-tokens`, `feat/rate-limiting`, `fix/memory-leak`
- `web-app` — pre-loaded with worktrees: `feat/dark-mode`, `feat/dashboard`

The tape then runs from `web-app` and demonstrates:

1. `w help` — command overview
2. `w add <branch>` — creating a worktree
3. `w ls` — grouped per-repo listing
4. `w <branch>` — switching to an existing worktree by name
5. `w ls --all` — cross-repo view of every worktree on the machine
6. `w <branch>` — jumping into a worktree in a *different* repo entirely
7. `w rm <branch>` — removing a worktree with confirmation

## Regenerating the GIF

Always run from the **repo root** (not from inside `demo/`):

```bash
vhs demo/demo.tape
```

Output is written to `demo/demo.gif`. Commit it afterward:

```bash
git add demo/demo.gif
git commit -m "chore: regenerate demo gif"
```

## Editing the tape

### Timing guidelines

- After `w help`: 4 s — the output is tall, give viewers time to read
- After `w add`: 3 s — wait for the worktree creation output to settle
- After `w ls`: 4–5 s — grouped output is the key visual, hold it longer
- After cross-repo jumps: 3 s — let the new `pwd` sink in
- After `w rm` confirmation prompt: 0.6 s before typing the branch name

### Adding new commands to the demo

1. Add setup steps in `demo/setup.sh` if the command needs pre-existing state.
2. Add a comment block in `demo/demo.tape` explaining what's being shown.
3. Use `Sleep <N>s` generously after anything visually meaningful — viewers pause
   on the output, not the typing.

### Changing the repos / branch names

Edit `demo/setup.sh`. The two repo names (`api-service`, `web-app`) and their
pre-created branches are defined there. If you rename them, update the
corresponding `Type` commands in `demo/demo.tape` to match.

## Troubleshooting

**`vhs: command not found`** — install via `brew install vhs`.

**Blank or truncated GIF** — make sure you run from the repo root so
`source demo/setup.sh` can resolve `$PWD/w.zsh`.

**`short=<path>` lines appearing in `w ls` output** — this is a variable
collision bug in the awk block inside `_w_ls_format`. The `p` variable is used
as both an array (path split) and a scalar (path value). Rename the scalar to
`wpath` in the END block of the awk script in both `w.sh` and `w.zsh`.

**`w` command not found inside setup.sh** — `setup.sh` sources `w.zsh` relative
to `$REPO_ROOT` (captured as `$PWD` at VHS start). If you move the tape, update
the `source` path or pass `REPO_ROOT` explicitly.
