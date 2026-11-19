## Commands

- run: n/a: collection of scripts, no single entry point
- test: `./lib/tests/run_all.sh`
- test-changed: `scripts/test_changed.sh`
- lint: `find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n 40 shellcheck`
- coverage: n/a: no coverage tooling for this stack
- coverage-gaps: n/a: no coverage tooling for this stack
- deploy: `scripts/deploy.sh` (fast-forwards ~/src/hosts-blocker, the checkout the browser wrappers, hosts-file-monitor and the maintenance timer run, keeping its local list edits; reruns `sudo -n install.sh`; exits non-zero unless /etc/hosts holds >= 100k blocked entries, every custom entry and no live unblocked domain; `--check` = health check only)
