.DEFAULT_GOAL := check

.PHONY: build
build:
	lake build

.PHONY: check
check: build
	lake test
	bash scripts/git-differential.sh

.PHONY: bench
bench: build
	bash scripts/bench.sh "$(BASELINE)"
