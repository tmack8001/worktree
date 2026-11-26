.DEFAULT_GOAL := help

BATS       := bats
SHELLCHECK := shellcheck
VHS        := vhs

TESTS      := tests/test-w.bats tests/test-install.bats tests/test-release.bats
ZSH_TESTS  := tests/test-w.zsh
DEMO_TAPE  := demo/demo.tape
DEMO_GIF   := demo/demo.gif

# Shells for `make shells`: comma separated, each a command plus its arguments; the command may be an absolute
# path (SHELLS="/bin/sh,/bin/bash"). Each runs the bats suites with TEST_SH set to it, so w.sh, install.sh and
# build-release.sh run under that shell while bats itself runs under bash (tests/shell-under-test.bash).
SHELLS     ?= dash,bash --posix,busybox ash,bash

.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  test    run the BATS and zsh test suites"
	@echo "  shells  run the BATS suites with the code under test in each shell in SHELLS"
	@echo "          (default \"$(SHELLS)\"; a missing shell is skipped, a failure with CI=true or REQUIRE_SHELLS=\"busybox dash\")"
	@echo "  test-tmux  run only the real-tmux tests, with TMUX_BIN (default tmux on PATH); never skipped"
	@echo "  lint    shellcheck the scripts and the bats suites"
	@echo "  demo    regenerate $(DEMO_GIF) via VHS"
	@echo "  check   lint + test"
	@echo "  deps    install maintainer dependencies (brew bundle)"
	@echo ""

.PHONY: deps
deps:
	brew bundle

.PHONY: lint
lint:
	$(SHELLCHECK) --shell=sh --severity=warning w.sh install.sh scripts/build-release.sh tests/shell-under-test.sh
	$(SHELLCHECK) --severity=warning $(TESTS) tests/shell-under-test.bash

.PHONY: test
test:
	$(BATS) $(TESTS)
	zsh $(ZSH_TESTS)

# Every shell runs to the end; the failing shells are listed and the target fails. A shell whose command is not
# installed is skipped, unless CI=true or its command name is in REQUIRE_SHELLS (space or comma separated).
# An empty SHELLS is a usage error (exit 2).
.PHONY: shells
shells:
	@failed=""; ran=""; req=" $$(echo "$$REQUIRE_SHELLS" | tr ',' ' ') "; \
	list='$(SHELLS)'; oifs=$$IFS; \
	n=0; IFS=,; set -f; for sh in $$list; do IFS=$$oifs; set -- $$sh; [ $$# -eq 0 ] || n=$$((n + 1)); done; set +f; IFS=$$oifs; \
	if [ "$$n" -eq 0 ]; then echo "shells: SHELLS is empty: name at least one shell (comma separated)" >&2; exit 2; fi; \
	IFS=,; set -f; set -- $$list; set +f; IFS=$$oifs; \
	for sh in "$$@"; do \
	  set -- $$sh; [ $$# -gt 0 ] || continue; sh="$$*"; \
	  if ! command -v $$1 >/dev/null 2>&1; then \
	    if [ "$$CI" = "true" ]; then echo "shells: $$1 missing in CI (CI=true: the shell is required)" >&2; exit 1; fi; \
	    case "$$req" in *" $$1 "*) echo "shells: $$1 missing but listed in REQUIRE_SHELLS" >&2; exit 1;; esac; \
	    echo "shells: SKIPPED $$sh: $$1 is not installed (set CI=true or REQUIRE_SHELLS=$$1 to make this a failure)"; continue; \
	  fi; \
	  echo "== bats (TEST_SH=$$sh)"; \
	  TEST_SH="$$sh" $(BATS) $(TESTS) || failed="$$failed [$$sh]"; \
	  ran="$$ran$${ran:+, }$$sh"; \
	done; \
	if [ -n "$$failed" ]; then echo "shells: FAILED:$$failed" >&2; exit 1; fi; \
	echo "shells: all passed ($${ran:-none ran: every listed shell was skipped})"

# Only the tests that drive a real tmux (named "tmux exact:" and "tmux names:"), with TMUX_BIN first on PATH as
# `tmux` and WORKTREE_TEST_REQUIRE_TMUX=1, so a missing tmux fails instead of skipping. CI runs it once per tmux
# version it tests.
TMUX_BIN   ?= tmux
.PHONY: test-tmux
test-tmux:
	@t=$$(command -v "$(TMUX_BIN)") || { echo "test-tmux: $(TMUX_BIN) not found" >&2; exit 1; }; \
	echo "== tmux tests with $$t ($$("$$t" -V))"; \
	WORKTREE_TEST_TMUX="$$t" WORKTREE_TEST_REQUIRE_TMUX=1 $(BATS) -f '^tmux (exact|names):' tests/test-w.bats

.PHONY: demo
demo:
	$(VHS) $(DEMO_TAPE)

.PHONY: check
check: lint test
