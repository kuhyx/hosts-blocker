#!/usr/bin/env bash
# Tests for the shared kuhy credit shown by install.sh --help / -h.
#
# The credit script is vendored into lib/ from kuhyx/utils; this repo does not
# maintain it. Two things are checked:
#   1. `bash lib/kuhy-credit.sh` prints exactly one line.
#   2. install.sh's --help branch invokes lib/kuhy-credit.sh — asserted via grep
#      because install.sh re-exec's itself under sudo, so sourcing it would not
#      reach the help path inside the subprocess.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0

_t_pass() {
	PASS=$((PASS + 1))
	printf '  OK: %s\n' "$1"
}

_t_fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL: %s\n' "$1"
}

_t_eq() {
	local want="$1"
	local got="$2"
	local what="$3"
	if [[ "$got" == "$want" ]]; then
		_t_pass "$what"
	else
		_t_fail "$what (want '${want}', got '${got}')"
	fi
}

_t_contains() {
	local haystack="$1"
	local needle="$2"
	local what="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		_t_pass "$what"
	else
		_t_fail "$what (missing '$needle')"
	fi
}

_t_summary() {
	printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
	[[ $FAIL -eq 0 ]]
}

EXPECTED='Created by kuhy https://kuhy.duckdns.org'

echo "== lib/kuhy-credit.sh output =="
GOT="$(bash "${REPO_DIR}/lib/kuhy-credit.sh")"
_t_eq "$EXPECTED" "$GOT" "exact credit line"

echo "== install.sh --help branch invokes kuhy-credit.sh =="
help_branch="$(sed -n '/-h | --help)/,/;;/p' "${REPO_DIR}/install.sh")"
_t_contains "$help_branch" "lib/kuhy-credit.sh" "--help branch calls lib/kuhy-credit.sh"
_t_contains "$help_branch" "Usage:" "--help branch still prints Usage"

_t_summary
