.DEFAULT_GOAL := help

BATS       := bats
SHELLCHECK := shellcheck
VHS        := vhs

TESTS      := tests/test-w.bats
ZSH_TESTS  := tests/test-w.zsh
DEMO_TAPE  := demo/demo.tape
DEMO_GIF   := demo/demo.gif

.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  test    run the BATS and zsh test suites"
	@echo "  lint    shellcheck both shell variants"
	@echo "  demo    regenerate $(DEMO_GIF) via VHS"
	@echo "  check   lint + test"
	@echo "  deps    install maintainer dependencies (brew bundle)"
	@echo ""

.PHONY: deps
deps:
	brew bundle

.PHONY: lint
lint:
	$(SHELLCHECK) --shell=sh   --severity=warning w.sh
	$(SHELLCHECK) --shell=bash --severity=warning install.sh

.PHONY: test
test:
	$(BATS) $(TESTS)
	zsh $(ZSH_TESTS)

.PHONY: demo
demo:
	$(VHS) $(DEMO_TAPE)

.PHONY: check
check: lint test
