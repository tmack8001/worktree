# Changelog

Each release has a `## [X.Y.Z]` section. The release workflow (`.github/workflows/release.yml`) refuses to
release a version without one, and uses the section as the GitHub release notes. A release's date is the date of
its tag.

## [Unreleased]

### Fixed

- `w rm` and `w dev` without a branch, run inside a worktree, now take the branch git has checked out there
  (`git symbolic-ref HEAD` in the worktree found by `git rev-parse --show-toplevel`) instead of the first path
  segment, so inside `feature/foo` they act on `feature/foo`, not `feature`. A detached HEAD fails with
  "HEAD is detached" instead of guessing (`w.sh`, `w.zsh`).
- tmux sessions are matched by exact name (`=name`, `=name:`, `=name:window` targets). Before, `w rm foo` could kill
  and `w dev foo` could attach a session whose name only starts with the guessed name (e.g. `repo-foo-bar` when
  there was no `repo-foo`) (`w.sh`, `w.zsh`).
- `w.sh`: `_w_load_config` no longer leaves `w-cfg.*` directories in `$TMPDIR`: none is created for a missing
  config, it is removed when no profile matches, and `w add`, `w clone`, `w dev` and the dependency-dir lookup
  remove it when done (no trap is set).

## [0.1.1]

Safety hotfix.

### Security

- `setup`, `pre` and window `run` commands from a repository's `.worktree.toml` are no longer run unless
  `WORKTREE_ALLOW_REPO_COMMANDS=1` (exactly `1`) is set; without it they are listed and skipped (`w.sh`, `w.zsh`).
- `install.sh` no longer copies `w.sh`/`w.zsh` from the current directory: piped from `curl`, `$0` is the shell, so
  the old code resolved the source to the current directory. It now copies only when run as a file named
  `install.sh` with the variant next to it; `--remote` forces a download.
- `install.sh` downloads a pinned release tag (`v0.1.1`) instead of `main`. `--ref <ref>` / `WORKTREE_REF` override
  it (validated charset). Downloads go to a temp file and an empty download is an error. An option missing its value
  is an error.

### Changed

- `install.sh` picks the variant from the login shell (`$SHELL`) instead of "zsh is installed"; for bash the rc file
  is `~/.bashrc`, else `~/.bash_profile`, else `~/.profile`.
- GitHub PR URLs are resolved with `${GITHUB_CMD:-${GH_CMD:-gh}}` (split into words) and an explicit
  `-R owner/repo`.
- `w <sub> --help` works outside a git repository.
- `w.sh` no longer uses `local`: `worktree` runs in a subshell and hands the directory change back to the calling
  shell, so no variable leaks into it. As a side effect, choosing a worktree in the fzf picker now changes directory
  in bash and dash too.

### Fixed

- A PR URL that cannot be resolved fails (exit 1) instead of creating a worktree named after the URL.
- `w.zsh`: `/pulls/` normalisation no longer inserts backslashes; `worktree dev` no longer fails on the
  `"$session_name:shell"` zsh modifier.

### Maintenance

- Tests no longer start a real tmux server (which hung `make test` when its output was a pipe); `make lint` covers
  `w.sh`, `install.sh` and the bats suites and passes.
- Reproducible release tarball (`scripts/build-release.sh`), release workflow, CI and Dependabot for GitHub Actions.

## [0.1.0]

Initial tagged release of the existing `main` at `d8689577fe2adce8a35bb06be92482fed98ddd68`, tagged after the fact
by the release workflow. No changes relative to that commit.

Known issues in this tree, fixed in 0.1.1:

- `.worktree.toml` `setup`, `pre` and window `run` commands run without any opt-in.
- `install.sh` downloads from `main`, not from the `v0.1.0` tag, so installing "v0.1.0" with the one-liner installs
  whatever is on `main` at that moment.
- `curl ... | sh` run in a directory containing a `w.sh`/`w.zsh` installs that local file.
