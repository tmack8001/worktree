# Changelog

Each release has a `## [X.Y.Z]` section. The release workflow (`.github/workflows/release.yml`) refuses to
release a version without one, and uses the section as the GitHub release notes. A release's date is the date of
its tag.

## [Unreleased]

### Changed

- GitHub Actions moved to their latest releases, pinned by full commit SHA: `actions/checkout` v7.0.1,
  `actions/upload-artifact` v7.0.2, `actions/download-artifact` v8.0.2, `actions/attest-build-provenance` v4.2.2
  (each SHA is the commit its tag points to; every input the workflows use still exists in the action). Not yet run
  on GitHub.

### Added

- README "Supported environments": POSIX sh and bash 3.2+ (the macOS system bash) for `w.sh`, zsh 5.x for
  `w.zsh`, macOS 15+, Ubuntu 24.04 LTS and newer, tmux 2.1+, git 2.31+ (not verified at that floor), each with
  what tests it and where; native Windows, Intel macOS and other distributions are not covered.
- `make shells`: the bats suites with `w.sh`, `install.sh` and `scripts/build-release.sh` run under each shell in
  `SHELLS` (default dash, `bash --posix`, busybox ash, bash) through `TEST_SH`, as in ghid; bats itself runs under
  bash. A missing shell is skipped, and fails with `CI=true` or `REQUIRE_SHELLS`. `make test` is unchanged.
- `make test-tmux TMUX_BIN=<tmux>`: only the tests that drive a real tmux, failing (not skipping) when tmux is
  missing. tmux 2.1, 2.2, 2.6, 2.9a, 3.0a, 3.2a, 3.3a, 3.4, 3.5a and 3.8 pass; 1.9a and 2.0 fail (no `=name`
  exact targets), hence the 2.1 floor.
- CI jobs `shells` (ubuntu-24.04, ubuntu-latest), `shells-macos` (macos-15, macos-latest: `/bin/sh`, `/bin/bash`
  3.2, `/bin/bash --posix`, dash, and the zsh suite) and `tmux` (2.1 built from source by
  `scripts/build-tmux.sh` with a pinned SHA-256, the Ubuntu 24.04 and ubuntu-latest packages, Homebrew's tmux).
  macOS 14 and Ubuntu 22.04 are not in the support floor or the CI matrix: GitHub retired the macos-14 runner
  image on 2026-11-02 and Apple no longer supports macOS 14; the ubuntu-22.04 image is deprecated (unsupported
  from 2027-04-17). The tmux 2.1 build keeps the old-tmux floor tested on any runner.

### Fixed

- Tests no longer depend on the machine's git config. The bats suites and the zsh suite set a fake identity
  (`GIT_AUTHOR_*`/`GIT_COMMITTER_*`: `worktree test`, `test@example.invalid`), ignore the system and global
  config (`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`) and point the test remotes' `HEAD` at `main`.
  On the GitHub runners, which have no `user.name`/`user.email`, every test that commits failed in setup
  ("Author identity unknown"); with git's default `init.defaultBranch` (master) two clones of the test remote
  had no checkout. With no global or system git config: `make test` 192/192 bats and 280/280 zsh checks (was
  42/192, 199/280), `make shells` 4 x 192/192, `make test-tmux` 12/12 with tmux 3.4 and 2.1 (was 0/12).
- The tests that kill a running `worktree` (or `_w_load_config`) no longer leave processes behind. Killing the
  shell left its subshells and the setup command's `sleep` loop running; the loop waited for a release file that
  teardown deleted, so it never ended, and it held fds inherited from bats. The tests now record the process tree
  before the kill, stop it and wait until it is gone (also in teardown when a test fails), start background
  commands with fds 3 to 9 closed, and the waiting setup command ends by itself after 120s or once the test
  directory is gone. This is the likely cause of the macOS CI jobs that printed every result and then hung until
  their timeout ("Terminate orphan process: sleep", "bash"); not yet verified on macOS.
- CI timeouts raised to fit the measured run times: `test` 30 min (step 25), `shells` and `shells-macos` 50 min
  (`make shells` step 40, zsh suite step 10), `tmux` 30 min (step 15).
- `w.sh`: `worktree` no longer leaves a `w-cd.*` file in `$TMPDIR` when it is killed mid-run. The file that
  carries the directory to `cd` into out of the command's subshell is now opened (to write on fd 9, to read back
  on fd 8) and removed before the command starts, so it has no name while the command runs; no trap is set and
  the caller's traps and fds 8 and 9 are kept. A pipe was not used because it would wait for every process that
  inherits it (a tmux server started by `w dev`, a detached `git gc`, a background setup command). `w dev`
  starts tmux with fd 9 closed. `w.zsh` runs in the caller's shell and never used such a file.
- `w dev` sends each window's `run` command to that window, and selects the `shell` window, by the window id
  tmux prints when it creates the window (`new-session`/`new-window -P -F '#{window_id}'`, targets `@N`) instead
  of `=session:name`. A window name containing `.` (a pane separator in a target) got no command, and a name
  repeating another window's (e.g. a second `shell`) could get the wrong one. Window names are kept as written.
  Checked with tmux 2.1, 3.4 and 3.8 (`w.sh`, `w.zsh`).
- `w rm` kills the tmux session named by the matched profile's `session` override, looked up in
  `.worktree.toml` the same way as `w dev` (one helper, `_w_profile_session_name`). Before, it always killed
  `<repo>-<branch>`, so it left the session `w dev` had made and could kill an unrelated session that had the
  default name (`w.sh`, `w.zsh`).
- `w cd <branch>`, `w <branch>` and `w add <branch>` take an existing branch's worktree from
  `git worktree list --porcelain` (as `w rm` and `w dev` do) instead of assuming `<worktrees>/<branch>`. Before,
  `w cd` failed for a worktree in a directory not named after its branch and went into a directory of the
  branch's name that had another branch (or none) checked out; `w <branch>` and `w add` then tried to create a
  second checkout, which git refuses, and the main working tree's branch (e.g. `w main` from a worktree) failed
  in `git worktree add`. Now a branch checked out in a worktree switches there, one checked out in the main
  working tree switches to it (saying so), and one git lists in a missing or unusable worktree fails with a
  message naming that path. `w cd` of a branch with no worktree fails with "No worktree has branch '<branch>'
  checked out". Only a branch with no worktree gets a new one at `<worktrees>/<branch>`, and `w add`/`w <branch>`
  now refuse to create it when that path already exists (`w.sh`, `w.zsh`).
- A branch (or `session` override) containing `#` or `;` now gets a tmux session that `w dev` and `w rm` find:
  tmux expands formats such as `#S`, `#{...}` and `##` in a new session's name (2.9a and later; 3.8 also drops a
  trailing `#`) and takes an argument ending in `;` as a command separator, so `w dev` created a new session
  every time and `w rm` never killed it. `#` and `;` now map to `_` like `.` and `:`; other session names are
  unchanged. A session made for such a branch by an earlier version is not found by the new name
  (`w.sh`, `w.zsh`).
- tmux windows of `w dev` start in their directory when its path contains `#` or ends in `;`: tmux expands
  formats in `-c` too (every version checked), so `#` is now doubled and a trailing `;` followed by `/`
  (`w.sh`, `w.zsh`).

- `w rm` and `w dev` without a branch, run inside a worktree, now take the branch git has checked out there
  (`git symbolic-ref HEAD` in the worktree found by `git rev-parse --show-toplevel`) instead of the first path
  segment, so inside `feature/foo` they act on `feature/foo`, not `feature`. A detached HEAD fails with
  "HEAD is detached" instead of guessing (`w.sh`, `w.zsh`).
- tmux sessions are matched by exact name (`=name`, `=name:`, `=name:window` targets). Before, `w rm foo` could kill
  and `w dev foo` could attach a session whose name only starts with the guessed name (e.g. `repo-foo-bar` when
  there was no `repo-foo`) (`w.sh`, `w.zsh`).
- `w.sh`: `_w_load_config` no longer leaves `w-cfg.*` directories in `$TMPDIR`. It keeps the parsed config in shell
  variables (`W_CFG_*`, newline-separated lists) instead of a `w-cfg.*` directory and `w-line.*` files, so it
  creates no file at all and nothing is left behind even when it is interrupted mid-parse; no trap is set. Window
  `name`, `dir` and `run` values are now kept verbatim, as in `w.zsh` (they went through `awk -v`, which
  interpreted backslash escapes).
- tmux session names are now the form tmux stores: tmux 3.4 replaces `.` and `:` with `_` and escapes `\`, `$`
  and control characters, so a repo or branch containing them (e.g. `fix/v1.2`) never matched its own session and
  `w dev` tried to create it again (`duplicate session`), put its windows nowhere and attached nothing, and
  `w rm` did not kill it. One helper (`_w_session_name`) maps `.`, `:`, `\`, `$` and every byte outside printable
  ASCII to `_`, including a profile's `session` override, and is used for new-session, has-session,
  attach-session, kill-session and the window targets (`w.sh`, `w.zsh`).
- `w rm <branch>` and `w dev <branch>` take the worktree from `git worktree list --porcelain` (the entry with
  `branch refs/heads/<branch>`, checked to be a worktree of the same repository with that branch checked out)
  instead of assuming `<worktrees>/<branch>`. Before, a worktree in a directory not named after its branch was not
  found, a plain directory of that name was used for `w dev`, and `w rm foo` removed whatever worktree was in the
  directory `foo` even when it had another branch checked out. A branch with no worktree now fails with
  "No worktree has branch '<branch>' checked out", and the main working tree's branch with "checked out in the main
  working tree", both before the confirmation prompt (`w.sh`, `w.zsh`).

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
