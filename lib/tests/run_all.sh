#!/usr/bin/env bash
# lib/tests/run_all.sh — run every hosts/install.sh test in one process tree.
#
# Scope note: these cover the two anti-tamper guards and the cache helpers, not
# the install phases. The phases write /etc/hosts, unmount the guard's bind
# mount and restart systemd-resolved, so executing them under test would take
# down the protection they exist to install. They are verified textually
# instead — see the evidence artifact for this split.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=0
for test_script in "${SCRIPT_DIR}"/test_hosts_*.sh; do
	printf '\n### %s\n' "$(basename "$test_script")"
	if ! "$test_script"; then
		failed=$((failed + 1))
	fi
done

if [[ $failed -gt 0 ]]; then
	printf '\n%d test file(s) FAILED\n' "$failed"
	exit 1
fi

printf '\nAll hosts install test files passed.\n'
