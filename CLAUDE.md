## Commands

- run: n/a: collection of scripts, no single entry point
- test: `./lib/tests/run_all.sh`
- test-changed: `scripts/test_changed.sh`
- lint: `find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n 40 shellcheck`
- coverage: n/a: no coverage tooling for this stack
- coverage-gaps: n/a: no coverage tooling for this stack
